# NifServer: a NIF shader set

NifServer builds every shape's material as a `StandardMaterial3D` (`nif_material_builder.gd`
`_build_standard()`), shared through the material cache. Several issues come from that:
dual-bit alpha (`alpha_dual_bit.md`), bushes and light cards with no back faces, additive
particles, and material animation that cannot be per instance. Replace it with a small set of
shaders shaped to the NIF data: one shader source per NIF shader identity, compile-time variants
for the render state Godot fixes at compile time, and instance uniforms for what animates or
differs per reference.

The shaders start from Godot's own StandardMaterial3D output (converted to shader text), not from
scratch, so they keep Godot's modern renderer: its lighting, shadows, fog and GI.

## Census

Every shape in the BSAs' 20,542 NIFs: 67,170 shapes. Census: `project/_diag/diag_material_census.tscn`
(not committed); it builds each shape's stock material and records the NIF's shader block, its
property blocks, the render state built and whether a sequence's material controller drives it.

### NIF shader identity

| Block | bs_shader_type | Shapes |
|---|---|---|
| BSShaderPPLightingProperty | 1 | 57,630 |
| BSShaderNoLightingProperty | 33 | 7,936 |
| NiMaterialProperty only (no BS shader block) | | 618 |
| no property | | 572 |
| BSShaderPPLightingProperty | 14 (FaceGen skin) | 332 |
| TileShaderProperty | 32 | 49 |
| TallGrassShaderProperty | 0 | 18 |
| WaterShaderProperty | 17 | 8 |
| SkyShaderProperty | 10 | 7 |

`shader_file_name` is never a shader: on NoLighting (4,670), TileShader (49), TallGrass (18) and
Sky (6) it is always a `.dds` texture. The shader identity is the block type and its
`bs_shader_type`.

### Property blocks (shapes carrying one)

| Block | Shapes |
|---|---|
| NiMaterialProperty | 62,458 |
| BSShaderPPLightingProperty | 57,962 |
| NiAlphaProperty | 28,085 |
| BSShaderNoLightingProperty | 7,936 |
| NiTexturingProperty | 4,706 |
| NiStencilProperty | 2,017 |
| TileShaderProperty | 49 |
| TallGrassShaderProperty | 18 |
| WaterShaderProperty | 8 |
| SkyShaderProperty | 7 |

### Render state built today

34 combinations. The compile-time parts: path, transparency (opaque, scissor, blend), blend mode,
lit or unshaded, depth draw, depth test, cull, proximity and distance fade.

| Shapes | Render state |
|---|---|
| 32,063 | opaque lit, depth write, cull back |
| 19,555 | scissor lit, depth write |
| 4,159 | opaque lit, no depth write, no depth test |
| 1,776 | blend mix unshaded, depth write |
| 1,640 | blend add unshaded, no depth write |
| 1,503 | blend mix unshaded, no depth write |
| 1,176 | opaque lit, depth opaque only |
| 1,136 | opaque unshaded, depth write |
| 1,121 | blend mix lit, depth write |
| 745 | blend mul unshaded, depth write |
| 407 | blend add unshaded, depth write |
| 331 | skin opaque lit |
| 292 | blend add unshaded, no depth write, cull off, both fades (light shafts) |
| 262 | scissor unshaded, depth write |
| 194 | blend add lit, depth write |
| 161 | scissor lit, no depth write |
| 107 | hair blend mix lit |
| 92 | refraction (draws nothing) |
| 83 | blend mix lit, no depth write |
| 67 | opaque unshaded, no depth write, no depth test |
| 56 | blend add lit, no depth write |
| 54 | scissor unshaded, no depth write |
| 52 | hair scissor lit |
| 34 | blend mul lit, depth write |
| 34 | opaque unshaded, no depth write |
| 27 | opaque lit, no depth write |
| 14 | blend mix lit, depth opaque only |
| 9 | blend mul unshaded, no depth write |
| 7 | blend add unshaded, depth write, cull off, both fades |
| 5 | blend mix lit, no depth write, no depth test |
| 4 | blend add unshaded, no depth write, no depth test |
| 2 | scissor lit, no depth write, no depth test |
| 1 | skin scissor lit |
| 1 | blend mix lit, depth write, no depth test |

1,431 shapes are driven by a sequence's material controller (NiAlphaController,
NiMaterialColorController, BSMaterialEmittanceMultController, NiTextureTransformController,
BSRefractionStrengthController, BSRefractionFirePeriodController). They fall in
17 of the combinations; the largest is blend add unshaded with no depth write (397).  By controller type,
over every NIF's sequences (`native/tools/anim_survey --dump meshes`):

| Controller | Links | NIFs | Instance uniform |
|---|---|---|---|
| NiTextureTransformController | 1,811 | 301 | `nif_uv_offset`, `nif_uv_scale` |
| NiMaterialColorController | 1,260 | 327 | `nif_color` (or emission, by its target) |
| NiAlphaController | 1,182 | 228 | `nif_alpha` |
| BSMaterialEmittanceMultController | 879 | 195 | `nif_emission` |
| BSRefractionStrengthController | 106 | 57 | refraction (not built) |
| BSRefractionFirePeriodController | 57 | 17 | refraction (not built) |

Not material, for reference: NiTransformController 16,544 links in 754 NIFs, NiVisController
3,289 / 115 (both built), particle controllers (NiPSys*, 5,545 links), NiGeomMorpherController
317 / 34, NiLightColorController 20 / 13, NiLightDimmerController 8 / 4. Controllers attached
outside a sequence (a controller chain played on its own) are not counted here.

## Findings

- **NiStencilProperty was not read.** 2,017 shapes carry one, every one with flags `0x4D80`
  (stencil off, draw mode 3: both sides). Read now (step 1): those shapes are not culled. This is
  the bushes and light cards with no back faces. Census: `native/tools/stencil_census.cpp` (not
  committed).
- **4,159 opaque lit shapes write no depth and skip the depth test** (`_apply_shader_depth`, flags1
  bit 31 clear). By folder: 4,122 are distant LOD blocks (`meshes\landscape\lod`, flags1 `0x3000`
  flags2 `0x2` on 3,567, `0x2000`/`0x4` on 555); 32 `dungeons\audio_test` props and 5
  `interface\testload*` meshes (`0x2000000`/`0x0`), editor and test objects. NifServer does not
  load LOD blocks today (only the legacy `gamebryo/mesh_resolver.gd` does); when it does, their
  depth flags need checking against how the original draws LOD, before the shader set maps them.
- NiTexturingProperty (4,706) and NiMaterialProperty-only shapes (618) are the older material
  form; how each maps onto the shader set is not checked yet.

## Shape

### Shader sources

One source per NIF shader identity:

- **Lit**: BSShaderPPLightingProperty type 1 (57,630); its hair, skin and refraction paths stay
  paths over it.
- **Unlit**: BSShaderNoLightingProperty (7,936): effects, glows, light cards.
- **Tile**: TileShaderProperty (49): interface meshes.
- NiMaterialProperty-only and propertyless shapes: lit, once checked.

Out of scope for now:

- **Sky** (SkyShaderProperty, 7): the sky uses a modern Godot shader.
- **Water** (WaterShaderProperty, 8): water uses a modern Godot shader.
- **Grass** (TallGrassShaderProperty, 18): grass is not implemented now; v0 was too expensive.

Each source is one shader include: Godot 4.7.1's StandardMaterial3D output for the feature set it
needs, converted to shader text once and kept in the repo. Features that StandardMaterial3D
compiles in or out become uniforms where Godot allows: each texture's presence (a white or flat
default bound when absent), vertex colour as albedo, the scissor threshold value, normal map
strength, the fades. A Godot upgrade means converting again; one source per identity keeps that to
a few files.

### Compile-time variants

Small variant files hold only the `render_mode` line and `#define`s, then include the source.
Variants follow only from what Godot fixes at compile time:

- blend mode: mix, add, mul;
- the pass: opaque, alpha scissor, blended (writing `ALPHA`);
- depth draw: always, never, opaque only;
- depth test disabled;
- cull: back, disabled (from NiStencilProperty once it is read);
- unshaded (fixed by the source: lit or unlit).

From the census that is in the order of 15 to 20 pipelines for the whole corpus, against
StandardMaterial3D's per-feature permutations today.

### Instance uniforms

On the fields that animate or differ per reference, keyed by the animation builder as
`instance_shader_parameters/<name>` tracks on the mesh node, so a shared material still batches:

- `nif_alpha` (NiAlphaController);
- `nif_emission` (BSMaterialEmittanceMultController, and the XEMI tint, replacing EsmNode's
  StandardMaterial3D-only tint);
- `nif_color` (NiMaterialColorController);
- `nif_uv_offset`, `nif_uv_scale` (NiTextureTransformController).

Material colour and texture transform need their controller's target (which colour; which slot
and operation) from the native export, which does not carry it yet (`nif_source_gd.cpp` exports
`controller_type`, `controller_id`, `interpolator_id` per controlled block).

Instance uniforms live in Godot's global shader variable buffer, and every instance whose
material declares them reserves its slots (8 here) whether or not anything sets them. At
Godot's default buffer size, scenes of 40,000+ nodes ran out; later instances read unset slots and
rendered white ("Too many instances using shader instance variables"). `project.godot` sets
`rendering/limits/global_shader_variables/buffer_size=1048576` (16 MB of VRAM, a CPU copy of the
same size, about 200,000 instances), kept as cheap next to the terrain's reservation. The
alternative, declaring the instance uniforms only on XEMI-marked and controller-driven shapes
behind a compile-time define, is not built. The Compatibility (OpenGL) renderer's uniform buffer
limit likely rules this size out there; not checked.

Materials sharing one shader still draw separately in Godot when their uniforms differ (each
texture set is its own material); fewer shaders cut pipeline switches, and instance uniforms keep
animated and tinted shapes on their shared material instead of a copy per instance.

## Order

1. NiStencilProperty: read its draw mode into cull (census, test). Done.
2. Check the 4,159 opaque no-depth shapes over the whole population. Done: LOD blocks and editor
   test objects (Findings).
3. Count the material controllers by type. Done (Render state built today).
4. Convert the lit and unlit sources; variant files; a material path that builds them in place of
   `_build_standard()`, with the current tests passing.
   Unlit built: `PATH_UNLIT` (BSShaderNoLightingProperty, 7,936 shapes), body
   `project/GodotBryo/Servers/NifServer/shaders/nif_unlit.gdshaderinc`, written by hand after
   Godot's StandardMaterial3D maths (4.7.1 exposes neither its generated code nor the converter
   to scripts). Variants are generated from the render state (a `render_mode` line and defines)
   and cached: 23 over the corpus, all drawn with the real renderer without a shader error. Its
   render state still comes from `_build_standard()`'s rules. XEMI is the `nif_emittance`
   instance uniform.
   Lit built: `PATH_LIT` (BSShaderPPLightingProperty without Hair, FaceGen or Refraction, 57,379
   shapes), body `shaders/nif_lit.gdshaderinc`, the same generator and instance uniforms: 19
   variants, all drawn with the real renderer without a shader error. Hair and skin stay on
   StandardMaterial3D for now (actor code tints them as one). The normal map's alpha (the
   specular mask) is not sampled yet: parity with StandardMaterial3D first.
   Alpha tracks built: an NiAlphaController float link on a shape in a NIF's own sequences
   (NifTreeBuilder._make_animation()) is a value track on the shape's
   `instance_shader_parameters/nif_alpha`; the shaders clamp the alpha to 0..1 (keys run -0.5 to
   2, `# ASSUMPTION` that Gamebryo clamps). Test: `tests/servers/test_nif_material_tracks`. A NIF's
   own sequences build transform and alpha tracks only: NiVisController visibility is built for
   KFs (NifAnimationBuilder), not for a file's own sequences.
   Unified: `NifAnimationConverter` (`nif_animation_converter.gd`) holds every controlled block ->
   track rule; KFs (NifAnimationBuilder, bare escaped names) and a NIF's own sequences
   (NifTreeBuilder, built node paths) call it with their own target resolver. A NIF's own
   sequences now also get visibility tracks, static transform values, priorities, text keys and
   face morphs; KFs get alpha tracks on targets that are shapes. KF disk cache version
   `nifserver-kf-v7`. The remaining controllers are added once, there.
   Texture transform built: NiTextureTransformController float links become tracks on the base
   map's UV instance uniforms, one float each (`nif_uv_offset_u`/`_v`, `nif_uv_scale_u`/`_v`,
   `nif_uv_rotate`), by the operation in the controller ID (`<shaderMap>-<slot>-<operation>`;
   slot 0 on every link; KF links carry the ID but never reach their controller block). Order:
   scale, translate, rotate about (0.5, 0.5) in radians, `# ASSUMPTION`. Census tool:
   `native/tools/controller_census.cpp` (not committed). KF cache `nifserver-kf-v9`.
   NiMaterialColorController's target is in its controller ID too: SELF_ILLUM 1,218 and SPEC 42
   NIF links, 804 and 80 KF links.
   Not played yet: no code plays a static object's own sequences (signs' `Left`/`Right` loops);
   only doors, furniture, activators, containers and effects play clips. A NIF with two
   NiControllerManagers can repeat sequence names (`nv_freesidesign-large_lights.nif`, two
   `Left` and two `Right`); the tree builder does not de-duplicate clip names.
   Free controllers built: controllers no sequence link drives (1,441 manager-less files; clamp
   7,687, loop 1,499, reverse 14; active 8,401, inactive 799), exported by
   `NifSource.get_free_controllers()` with their timing (1,105 free texture transform blocks,
   matching the census; a property shared by several shapes exports its controller once per
   shape, 181). NifTreeBuilder adds one `FreeControllers<n>` clip per timing group to the
   AnimationPlayer library; a group that is active and drives no declared bone auto-plays through
   `NifObjectAnimator`: a KfAnimator child, one slot per clip from 1 (slot 0 is left for
   PlayGroup), speed the frequency, sought to the phase (`# ASSUMPTION` phase is seconds).
   Skeleton NIFs (61; 2,450 clamped transform controllers, 951 with unset times; 2 looping, both
   in `nvmrhouse\skeleton.nif`) keep their free controllers library-only; their bones are the
   actor animator's. KfAnimator now binds a track's node part as a path from `node_root` first,
   and sets any other value track's property as a float. Census tools: `manager_census.cpp`,
   `skeleton_controller_census.cpp` (not committed). Test: `tests/servers/test_nif_free_controllers`.
   A free controller starts at its own time at creation: app time x frequency + phase, with app
   time 0 when the object is created, so clip time phase - start (clamped, or wrapped when it
   loops). Weapon parts' free controllers (2,218 clamped transform controllers under weapons\)
   run from a displaced pose at -0.033 s to the part's NIF rest pose at 0 s: found by reading
   huntingrifle.nif's ##HRBolt, ##HRClip and ##HRTrigger keys against their rest transforms. At
   creation they are already at their end: their end value (the rest pose) is written once and
   the slot freed, so a later driver wins (the holster hide). Playing them from their first key
   had left the bolt, the .44's cylinder and the missile launcher's barrel a frame short of rest;
   fixed, `test_nif_free_controllers` checks the rifle's parts end exactly at rest. A clamped clip
   that ends later frees its slot one frame after its end, once KfAnimator has written its end
   value (it emits clip_finished before writing that frame). `# ASSUMPTION`: phase is in seconds.
   Not known: KfAnimator's frame cost with one per animated world object.
   Object groups built: NifObjectAnimator (renamed from the free-controller player) plays the
   object's group in KfAnimator slot 0. On spawn its default group: Idle, else SpecialIdle
   (census of records using a manager NIF: unscripted looping ones are Idle or SpecialIdle, 55 and
   48 STATs, 222 TERMs SpecialIdle, 21 MSTTs Idle; Open/Close, Forward/Backward, Left/Right are
   states). PlayGroup (111 scripts) records the group on the reference (`anim_group`, saved) and
   EsmNode plays it; IsAnimPlaying compares it (`# ASSUMPTION`). PlayGroup's flag (1 x291, 0 x169,
   2 x53) is not read. A clamped group holds its last frame and does not return to the default
   (`# ASSUMPTION`). Doors, furniture, activators and containers still play Open/Close/Use through
   the AnimationPlayer; moving them to slot 0 is to do. Test: `tests/servers/test_nif_object_animator`.
   Skinned actor parts keep their AnimationPlayer and ObjectAnimator through skin compaction
   (Securitron screens); not checked in game.
   Strip lights, open (2026-11-12): most are ACTIs running Lucky38LightScript (night Left, day
   Right), CasinoBaseLightScript (OnLoad and GameMode PlayGroup Left) or VVault21LightScript
   (Forward then Backward at night, Left then Right by day; timer on GetSecondsPassed); all parse.
   The Tops hotel neon's Left and Right hold nif_alpha at 1 and 0 (on and off; no animation). The
   Tops casino neon's Left scrolls nif_uv_offset_u 0 to 1 or 2 on Yellow_Neon1, Blue_Neon and
   Object01: its tree plays it (checked with a diag, `_diag/diag_tops_neon.tscn`), but in game the
   lights do not run. Next: trace the placed TopsCasinoLights reference: does its script run (OnLoad,
   GameMode), does PlayGroup reach EsmNode._play_anim_group, does the model's ObjectAnimator get it.
   Unscripted with Left/Right or Forward/Backward and no default group, so nothing plays them:
   GomorrahLightsAlwaysOn (STAT), NVGamSignGlo (ACTI), NVMonorailEngineLOWAnim (STAT). The Tops sign
   body (TheTopsSign01, NV_TheTops-Sign.NIF) has only two inactive material colour and emittance
   free controllers; material colour and emittance are not built.
   The Tops refs (2026-11-12): TheTopsSignLights (0011E498, NV_TheTops-Sign_Lights.NIF,
   VVault21LightScript) is placed twice (001201B6, 0013B9E6) and TopsCasinoLights (00152C89) once
   (0013B7F1); none has XESP or the initially-disabled flag, so no script enables them. The sign
   lights' four sequences hold only material controllers (22 links each: emittance mult and
   SELF_ILLUM colour on Neon:1-7, 14, 15 and Bulbs1_Backfaces:0-3), so the tree gets no
   AnimationPlayer and no ObjectAnimator.
5. Instance uniforms: alpha and emission (XEMI) first, then the native export and colour and UV
   tracks. Material colour and emittance census, every NIF and KF link
   (`_diag/diag_material_ctrl_census.tscn`, 25,307 files):

   | Where | Controller | Target | Interpolator | Links (on a shape) |
   |---|---|---|---|---|
   | NIF sequences | NiMaterialColorController | SELF_ILLUM | point3, keyed | 1,206 (1,150) |
   | NIF sequences | NiMaterialColorController | SELF_ILLUM | point3, static | 12 (12) |
   | NIF sequences | NiMaterialColorController | SPEC | point3, keyed | 42 (38) |
   | NIF sequences | BSMaterialEmittanceMultController | | float, keyed | 860 (805) |
   | NIF sequences | BSMaterialEmittanceMultController | | float, static | 19 (14) |
   | NIF free, active | NiMaterialColorController | not exported | point3, keyed | 354 (348) |
   | NIF free, active | NiMaterialColorController | not exported | blend | 2 (2) |
   | NIF free, active | BSMaterialEmittanceMultController | | float, keyed | 89 (85) |
   | NIF free, inactive | NiMaterialColorController | not exported | point3, keyed | 160 (155) |
   | NIF free, inactive | BSMaterialEmittanceMultController | | float, keyed | 5 (5) |
   | KF sequences | NiMaterialColorController | SELF_ILLUM | point3 407, none 397 | 804 |
   | KF sequences | NiMaterialColorController | SPEC | point3 | 80 |
   | KF sequences | BSMaterialEmittanceMultController | | float 236, none 55 | 291 |

   No link targets AMB or DIFF. KF links name no shape of their own file (they address the
   actor's or weapon's shapes). Missing to build them:
   - NiMaterialProperty's emissive colour, emit multiplier and specular colour are not exported or
     used: a shape's unanimated emission is its glow map only.
   - A free NiMaterialColorController's target is not exported (`controller_id` is empty; the
     target is in the controller's own flags).
   - A point3 interpolator's static value is not exported (12 static SELF_ILLUM links).
   - KfAnimator's property tracks write floats only; a colour track needs Color values.
   - `nif_emittance` is XEMI's (rgb replaces the material colour, `a` weights it); the lit
     shader's own inputs are `EmittanceColor` and `MatEmit` (Original shader packages), emission
     = emissive colour x emit multiplier.
   Built (2026-11-12): every shape carries its NiMaterialProperty emissive colour and emittance
   multiplier as the instance uniforms `nif_emissive` and `nif_emit_mult`, set by NifTreeBuilder
   (no split variant; 10 slots per instance). The native export now carries the material's
   emissive, emit multiplier, specular, glossiness and alpha, a free NiMaterialColorController's
   target as its controller ID, and a point3 interpolator's static value. SELF_ILLUM links are
   Color tracks on `nif_emissive`, emittance links float tracks on `nif_emit_mult`; KfAnimator
   writes a property track's value as it is (float or Color). Lit emission is the surface colour x
   emissive x multiplier x the glow map (white when absent), as OpenMW's bs/default shader; added
   on its own it lit glow-mapped shapes as a flat white. Lit shapes: glow map and coloured
   emissive 3,219; glow map and black emissive 1,079 (their glow map now adds nothing); coloured
   emissive, no glow map 772; XEMI (`nif_emittance`) replaces the emissive colour. The unlit
   shader does not draw them (`# ASSUMPTION`: 3,941 unlit shapes carry a black emissive colour and
   are visible; OpenMW's bs/nolighting does not use it either). Links by target shader: SELF_ILLUM
   1,131 on lit shapes, 525 on unlit; emittance 512 lit, 397 unlit; SPEC 33 lit, 16 unlit. Lit
   shapes with a coloured emissive: 3,991 of 53,840; they emit now. Some emissive colours are
   negative (TheTopsSignLights' Neon:1, -0.26, -0.11, 0); they are not clamped. Test:
   `tests/servers/test_nif_material_tracks`. Not built: SPEC colour links.
   Refraction built (2026-11-13): 92 lit shapes carry the Refraction flag (flags1 bit 15), 81 also
   Fire Refraction (bit 16); none has an NiAlphaProperty; each has a distortion normal map in slot
   1 (FXNormalDistort_n, FXFlatNormal_n, effectssphere01_n). BSShaderPPLightingProperty's strength
   is 0 to 0.25 on most (Helios laser 1.0) and its fire period an int, -22 to 200. Strength
   controllers on effects ramp 0 to 0.1-0.25; 58 strength and 57 period links on windows and
   cactus are keyed 0 on unflagged shapes. The original bends particles too (checked on the Xbox
   game). Its refraction pixel shaders (SLS2075, SLS2076, SM3032-3034) take only NormalMap and
   PSRefractionPower, and an image-space pass, ISREFRACT (Src0, Src1, Tint), distorts the frame:
   the shapes write a distortion buffer and a full-screen pass applies it. Built the same way:
   `nif_refraction.gdshader` writes 0.5 + offset and depth into a distortion buffer drawn by
   RefractionCapture (a camera copying the main one, seeing only layer 20), and RefractionEffect,
   a compositor effect after the transparent pass, offsets the frame by it where no opaque
   geometry is nearer. Sampling Godot's screen texture instead hid the transparents behind the
   shape (the copy is taken before the transparent pass). ISREFRACT's Tint is not read. Fire
   refraction scrolls the normal map by TIME / period (`# ASSUMPTION`, unit unknown). Census:
   `_diag/diag_refraction_census.tscn`. Test: `tests/servers/test_nif_refraction`.
   In game the distortion camera first picked up the WorldEnvironment's camera attributes (auto
   exposure scaled the buffer to ~0.4x: a grey dome sampling the sky, the effect clipping metres
   behind its shape) and its compositor (RefractionEffect distorting its own buffer), and the
   buffer's black background pulled filtered edges by -0.5. Each is overridden on the camera; see
   the NifServer README, "A second viewport in the main world". With those fixed the authored
   strength is used as the screen UV offset unscaled (a 0.25 scale tried while auto exposure was
   distorting the buffer is gone).
   NiFlipController: no file in the shipped corpus has one (no block in any of the 25,307 NIF and
   KF files, and no "NiFlipController" in their bytes); it was listed here in error. Animated
   sub-textures in this era are particle data (the NOLIGHT vertex shaders' SubTexOffsets input),
   with the particle systems, not built.
   Gaps closed (2026-11-13): the unread material interpolators were compressed B-splines, all in
   KFs: 397 NiBSplineCompPoint3Interpolator (SELF_ILLUM) and 55 NiBSplineCompFloatInterpolator
   (emittance). Resampled natively into linear keys within 1/255 (same control storage as the
   transform B-splines: bias + short x multiplier / 32767). Their values: colours mostly 0 to 1
   (B-spline overshoot to -0.1; a few first-person KFs -1 to 1), multipliers 4 to 6 on
   first-person attacks, 1 to 10 on the brainbot; 88 colour links are static only. Found with them:
   the KF resolver counted a target as a shape only if the KF held a shape of that name, which no
   KF does, so every KF material link (alpha, texture transform, colour, emittance) was dropped; a
   KF target now counts as a shape. Census: `_diag/diag_unread_interpolators.tscn`. Open: 2 free
   NiMaterialColorControllers in `scol/scolgsdochouse.nif` with NiBlendPoint3Interpolators (a blend
   interpolator holds no data of its own).
   Fat Man explosion (2026-11-13), three faults:
   - Smoke cut to its shape: SmokeGeo:0 has no NiAlphaProperty but BS shader flags1 bit 19
     (Dynamic Alpha), so it was drawn opaque; in the original it fades at its edges and over time
     (Xbox). A shape with Dynamic Alpha and no NiAlphaProperty is now drawn blended (mix). 81
     shapes outside LOD (38 unlit, 43 lit); the other 80 (consoles, Strip lights) follow the same
     rule, `# ASSUMPTION`. Unlit variants 29 -> 28.
   - Fireball rising sideways along the ground: ProjectileEffect replaced the delivered tree
     root's transform with its model turn, dropping NifTreeBuilder.ROOT_BASIS (the Z-up to Y-up
     turn NifServer puts on the root), so every effect model (explosions, muzzle flashes,
     impacts, tracers) lay in Gamebryo's axes; upright billboards hid it by facing in world
     space. The turn is now composed onto the root's basis. Test: `test_projectile_effects`.
     Also NifBillboardNode replaced the node's whole basis, losing a transform track's scale,
     and KfAnimator writing the track afterwards left the node in its authored orientation; the
     facing now replaces only the rotation, keeps the base scale, and is applied on
     frame_pre_draw, after animation (as OpenMW's AutoTransform). Test:
     `tests/servers/test_nif_billboard`.
   - White V on the ground: the particle emitter meshes (pCloudGroundEmit02:0, pCloudSkyEmit01:0)
     are hidden (NiAVObject flags bit 0); the flag is not read. Left for the particle work. 347
     hidden shapes and 143 hidden nodes (damage stages, blast and debris nodes) outside LOD.
   Unlit falloff (2026-11-13): BSShaderNoLightingProperty's falloff was read but not drawn. With
   flags1 bit 6 (the GECK's falloff enable; 1,520 unlit shapes, 1,320 with their own values) the
   unlit shader scales alpha by the falloff, linear in the cosine between the surface normal and
   the view (`# ASSUMPTION`). Light beams (replightbeams FXLightBeam06, cos 0.98 to 0.17, opacity 1
   to 0) fade as a card turns edge-on, so crossed cards do not double up: the authored form of the
   45 degree fade an earlier version hardcoded. The light-shaft rules' LIGHT_SHAFT_ALPHA_SCALE (0.2)
   still applies on top; it may now be too faint. Fat Man MeshGeoSphere01:0: cos 0.94 to 0.71.
   Unlit emissive colour: 3,941 visible unlit shapes carry a black emissive (1,952 mix with vertex
   colour, 746 multiply decals, 601 opaque), so the unlit colour is not multiplied by it. Found to
   be the correct behaviour: the Fat Man's MeshGeoSphere01:0 carries emissive (0.25, 0.8, 1) x 6
   and SELF_ILLUM / emittance tracks, and the original's explosion shows no blue (Xbox). With its
   falloff the shell is near invisible, as in the original.
   Billboard modes and muzzle flashes (2026-11-13): the .44 Magnum's flash (HandGunMuzzleFlash01)
   is authored along its NIF +Y (cross planes Plane12/13, flame card HorizontalFlash10, rotate
   about up, its local +Y along the barrel; glow Glow03, rigid face center). NifBillboardNode now
   faces per mode as niftools' nif.xml describes them (read through a summary, not verbatim):
   rotate_about_up spins about the node's own authored +Y (as OpenMW), not world up, so the flame
   stays along the barrel; always_* turn the authored +Z onto the target by the shortest arc;
   rigid_* snap into the camera's frame (camera up), *_camera facing the view plane, *_center the
   camera's position. `# ASSUMPTION`: bs_rotate_about_up as rotate_about_up (nif.xml: about local
   Z; shapes not checked). ProjectileServer's MUZZLE_FLASH_TURN (+90 degrees about up, made while
   ProjectileEffect dropped the root turn) sent flashes out of the gun's left; removed: NIF +Y is
   already the effect's -Z through the root turn. Found to be the correct behaviour in game.
   Instance materials closed: every material controller the original's shaders take plays.
   Not built, by reason: SPEC colour (no lit shader takes a specular colour), 2 blend-interpolator
   links (scolgsdochouse.nif), unlit emissive (unused in the original), hidden emitter meshes
   (particles). Open: the light-shaft LIGHT_SHAFT_ALPHA_SCALE (0.2) may be too faint with falloff.
6. Tile shader; NiTexturingProperty and NiMaterialProperty-only shapes.

### Texture channels

Textures of this era pack data into channels (normal maps carrying specular in alpha, and
similar). Where Godot's StandardMaterial3D wants a channel in a slot of its own, TextureServer
extracts it into a separate texture. With our own shaders, the original texture is bound once and
each input samples the channel it was authored in, so the extraction goes. Which textures
TextureServer splits today is to be listed before step 4.

## Original shader packages

`Data/Shaders/shaderpackage*.sdp` hold the game's compiled shaders. Only names and inputs are
read, to check the NIF fields and the uniforms planned here; the bytecode is not read or ported.

Format, all 16 packages read with no error: three little-endian ints (100 in every package, the
entry count, the data size = file size − 12), then per entry a 256-byte name padded with 0xFD, a
size and a D3D9 bytecode blob. Every blob has a CTAB constant table (shader model, constant names
and registers). The packages are hardware tiers: 818 to 1,003 entries each, the same names, split
across `vs_1_1`, `vs_2_0`, `ps_2_a` or `ps_2_b`, `vs_3_0` and `ps_3_0`; 1,003 distinct names.
Dump: a one-off script (not committed).

Families (vertex .vso / pixel .pso), by name prefix, the ones NIF shapes reach:

- `SLS` (327) and `SLS1S`: lit (PPLighting). `SM`/`SM3LL`: lit, shader model 3. `PAR`: parallax.
- `SKIN` (39), `HAIR` (14): the skin and hair paths.
- `NOLIGHT` (28 vertex) with pixel shaders `NOLIGHTTEX`, `NOLIGHTTEXVC`, `NOLIGHTTEXVCPMA`,
  `NOLIGHTMAT`, `NOLIGHTVCONLY`, `NOLIGHTWF`, `NOLIGHTWFAt`: unlit, split by texture / vertex
  colour / material only / premultiplied alpha.
- `TILE` (3): TileShaderProperty. `GDECAL`: decals. `DISTLOD`, `DISTTREE`: distant LOD.
- `PARTICLE`, `BEAM`, `BOLT`: particles, beams and lightning.
- Out of scope here: `WATER`, `GRASS`, `SKY*`, `ST*` (SpeedTree), `PRECIP`, `IS*` (image space,
  post-processing).

Inputs to check against what NifServer reads (the mapping column is by name, not checked):

| Input | Where | Covered by |
|---|---|---|
| `MaterialColor` | every NOLIGHT pixel shader | NiMaterialProperty; `nif_color` |
| `Toggles` | NOLIGHT, SKIN, SLS | unknown bit set |
| `TexCoordTranform` | 10 NOLIGHT vertex shaders | `nif_uv_offset`/`nif_uv_scale` |
| `Falloff` | 10 NOLIGHT vertex shaders | NoLighting falloff fields (read) |
| `SubTexOffsets` | 2 NOLIGHT vertex shaders | flipbook sub-textures `# ASSUMPTION`; not read |
| `MatAlpha` | 54 lit (SLS, SM, SM3LL, PAR, SKIN) | NiMaterialProperty alpha; `nif_alpha` |
| `EmittanceColor`, `MatEmit` | 43 and 8, lit | NiMaterialProperty emissive; `nif_emission` |
| `AlphaTestRef` | 19 (DISTLOD and others) | NiAlphaProperty threshold (read) |
| `GlowMap` | 66 | slot 2 glow (read) |
| `HeightMap`, `ParallaxData` | 49, 8 | slot 3 height `# ASSUMPTION`; not read |
| `EnvironmentCubeMap`, `CustomEnvMask` | 8, 6 | slots 4 and 5 `# ASSUMPTION`; not read |
| `FaceGenMap0`/`1`/`2` | SKIN | the `_sk` slot and FaceGen tints |
| `HairTint` | HAIR | the owner's hair colour tint |
| `TintColor` | TILE | not read |

The vertex shaders' inputs are transform, skinning, fog, lighting and shadow constants; Godot's
renderer supplies those.

## Not known

- Whether StandardMaterial3D's converted text is stable enough to patch with `#ifdef`s, or each
  source is better kept as one converted feature set with uniforms only.
- Godot's instance uniform limit per shader against the uniforms listed (6 now). `# ASSUMPTION`:
  16, not checked against 4.7.1.
