# NifServer: alpha blend and alpha test on one shape

Effect cards (muzzle flashes, impacts, beams, smoke, sparks) render as hard-edged alpha cutouts
instead of additive or blended glows. The cause is one rule in the material builder, not missing
flag decoding: the flags are read and mapped, but a shape that sets both alpha blend and alpha
test is always made an alpha scissor material, whatever its blend function.

## The code

- `native/src/nif/nif_loader.cpp` decodes NiAlphaProperty `flags`: bit 0 blend enable, bits 1–4
  source function, bits 5–8 destination function, bit 9 test enable, and `threshold` / 255.
  The (source, destination) pair becomes `alpha_blend_func`: `mix` (SRC_ALPHA, INV_SRC_ALPHA),
  `add` (SRC_ALPHA, ONE), `multiply` (ZERO, SRC_COLOR); any other pair falls back to `mix`.
- `project/GodotBryo/Servers/NifServer/nif_material_builder.gd` `_apply_alpha()`:
  - blend only: `TRANSPARENCY_ALPHA`, blend mode by `alpha_blend_func` (add, multiply, mix);
  - test only: `TRANSPARENCY_ALPHA_SCISSOR` at the threshold (0.5 when it is 0);
  - **both: `TRANSPARENCY_ALPHA_SCISSOR` at the threshold (at least 1/255), and the blend
    function is never read.**
- The both-set rule came in with eacacd3 ("Read BSShaderProperty flags…"). Before it, blend took
  precedence when both were set ("scissoring a blended gradient throws away the gradient"). The
  NifServer README records it as "an explicit approximation: StandardMaterial3D cannot combine
  both authored operations, so the authored edge blending is lost".
- `tests/servers/test_nif_material_paths.gd` `test_dual_alpha_scissor()` asserts the current
  rule.

## The census

Every NiAlphaProperty in the BSAs' 20,542 NIFs:

| Bits set | Properties | Mapped to |
|---|---|---|
| test only | 9,524 | scissor, correct |
| blend only | 4,483 | blended with its function, correct |
| both | 1,052 | scissor, blend function dropped |

The 1,052 both-set properties by blend function (flag value):

| Function | Flags | Count | Where |
|---|---|---|---|
| mix (SRC_ALPHA, INV_SRC_ALPHA) | 0x12ED | 818 | architecture 178, clutter 125, dungeons 90, landscape 72, weapons 38, trees 35 (of 344), effects 44 |
| add (SRC_ALPHA, ONE) | 0x120D | 201 | effects 81, nvdlc03/04 53, mps 10, projectiles 5 |
| other (ONE/ONE 0x1201, ONE/ZERO 0x1221, multiply-like 0x1243 and 0x1245) | | 33 | effects, nvdlc03 |

Test function is GREATER on all of them (bits 10–12 = 4). Thresholds on the additive effect
cards are 1 to 3 out of 255.

Weapon effects specifically:

- Every muzzle flash NIF (`effects\muzzleflashes\*`, the gauss rifle's, the alien blaster's,
  the lasers') is `0x120D`: additive with a test at threshold 1 or 2. Under the both rule each
  flash is an opaque cutout of every texel above 1/255, which is the hard-edged, too-bright card
  seen in game.
- `mps\mpsplasmaprojectile.nif`, `dlc03teslachainbeam.nif` and one of `dlc03flamerprojectile.nif`'s
  shapes are `0x120D` too.
- The energy impacts (`impactenergy*01.nif`) and the 762mm tracer are `0x100D` (blend only,
  additive) and already render additive. Most ballistic impacts are blend only (`0x10ED` or
  `0x100D`); dirt, bug blood and snow are `0x12ED` and blood `0x1221`, so those cut out.

Vegetation: of the trees folder's 344 properties, 309 are test only (`0x12EC`, blend bit clear)
and 35 both-set mix. In landscape, 577 test only, 74 both-set mix, 13 blend only. The Joshua
trees' cutout look comes from the test-only path, which the both rule does not change; the both
rule only affects the 35 + 74 dual-bit foliage shapes.

## Why it was done, and what it costs

A both-set mix shape rendered with `TRANSPARENCY_ALPHA` is sorted per object and writes no
depth, so overlapping foliage cards sort wrongly and leaves show through each other. Scissor
writes depth and sorts correctly, at the cost of the soft edge. That trade is reasonable for
dual-bit mix foliage, but the rule applies to every both-set shape. Additive shapes have no
sorting problem: additive blending is order independent and writes no depth. Cutting them out
loses the only thing they are for.

## Fix options

1. **Switch on the blend function in the both case.** Both-set `add` (and the ONE/ONE `0x1201`)
   and `multiply`: `TRANSPARENCY_ALPHA` with that blend mode, depth write off, as the blend-only
   path does. Both-set `mix` stays scissor. Small change; fixes every additive effect card; keeps
   the foliage as it is.
2. **Both-set `mix`: depth pre-pass instead of scissor.** `TRANSPARENCY_ALPHA_DEPTH_PRE_PASS`
   keeps the blended edge and writes depth for the opaque part. Needs checking on the foliage it
   was meant to fix.
3. **Exact match: a shader that tests then blends.** A ShaderMaterial (or a material path) that
   discards at the authored threshold and then blends with the authored function. Matches the
   original for every combination; costs a shader per blend mode and leaves StandardMaterial3D,
   which the XEMI tint and other consumers assume (EsmNode's XEMI tint handles only
   StandardMaterial3D).

Option 1 is the smallest change that fixes the effects; 2 or 3 can follow for the dual-bit mix
foliage if its edges matter.

## Work

A NifServer change, so per the project rule: this census, then the fix with a test in
`tests/servers/` (`test_nif_material_paths.gd`'s `test_dual_alpha_scissor()` changes with it:
dual-bit add and multiply shapes blend, dual-bit mix shapes keep scissor), and the NifServer
README's alpha paragraph updated.

Related, not this issue:
- NiBillboardNode `rotate_about_up` spinning about the world up axis
  ([../Weapons/projectiles.md](../Weapons/projectiles.md), Not known): why flashes and tracers
  stand upright.
- Particle systems (NiParticleSystem, ADDN master particle systems) are not built at all; they
  are not the cutouts seen here (projectiles.md, Particles).

Census: a one-off native tool (nifly over every BSA NIF's NiAlphaProperty, by folder, with a
path filter to list one file's flags); not committed.

## Built

Option 1. `_apply_alpha()`: a dual-bit `add` (including ONE/ONE, which the loader already decodes
as `add`) or `multiply` shape takes the blend-only path; a dual-bit `mix` shape keeps scissor.
Depth write still follows the shader flags (the muzzle flashes' flags2 is clear, so none).
`test_nif_tree_builder.gd` `test_dual_alpha_scissor()` adds the assault rifle flash's
`Plane01:0` (0x120D: additive, no depth write); the NifServer README's alpha paragraph says
the same. Options 2 and 3 are open for the dual-bit mix foliage.
