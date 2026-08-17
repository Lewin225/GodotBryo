# 1.3 — Light Sources (`LIGH` → real Godot lights)

Parent: [Phase 1](README.md)

## Goal

`LIGH` records become real, correctly-placed Godot light sources — an
`OmniLight3D`/`SpotLight3D`, plus the fixture mesh if the record has one (per
[object-types.md](object-types.md) Tier 2). Benchmark is correct placement and
plausible color/range, not 1:1 falloff-curve fidelity to Gamebryo's lighting model —
already agreed as the bar for this task.

## Format notes

`LIGH.DATA` layout confirmed via fopdoc:

| Field | Type |
|---|---|
| Time | int32 |
| Radius | uint32 |
| Color | rgba |
| Flags | uint32 |
| Falloff Exponent | float32 |
| FOV | float32 |
| Value | uint32 |
| Weight | float32 |

`Flags` almost certainly carries a spot-vs-point bit (and likely
flicker/pulse/negative-light bits) — not yet decoded to exact bit positions; do that
during implementation by cross-referencing fopdoc's enum breakdown for this field
specifically (not fetched in Phase 1 planning, since it wasn't needed to confirm the
overall approach).

`LIGH` also has its own `EDID`→`OBND`→model-data leading structure like the rest of
Tier 1, confirmed present — a `LIGH` with a fixture mesh (e.g. a lamp) needs the same
`GamebryoVisual` mesh+collider treatment *in addition to* the light itself.

## Steps

1. Decode `LIGH.DATA`, including the `Flags` bit for spot vs. point (and any other
   bits worth respecting — flicker/pulse can be ignored for Phase 1's benchmark).
2. Map `Radius`→light range, `Color`→`light_color`, `Falloff Exponent`→attenuation
   (approximate mapping is fine), `FOV`→spot angle for spotlights.
3. Register `LightNode`'s factory in 1.1's registry: builds the shared
   `GamebryoVisual` shape (mesh+collider) if the record has model data, plus the
   `OmniLight3D`/`SpotLight3D` sibling from `DATA`.
4. Test against real `LIGH` placements in the target interior cell(s) — Doc
   Mitchell's house almost certainly has several (lamps, ceiling fixtures).

## Deliverables

- `LightNode` factory registered into 1.1's registry.
- `DATA` decoding (shared/reusable if a pure-C++ `esm`-side helper makes sense, or
  inline in the factory if it's simple enough — judgment call at implementation
  time).
- Test scene showing correctly-placed, correctly-colored lights in a real cell.

## Acceptance criteria

- [x] Point lights confirmed against real data: all 25 `LIGH` refs in
      `GSDocMitchellHouse` are point lights (`Flags & 0x200` unset), all built as
      `LightNode`/`OmniLight3D`, correct position, plausible color/range. **Spot
      lights not exercised end-to-end** — none present in either test cell
      (`GSDocMitchellHouse`, `SLGoldMine01INT`); confirmed the `is_spot()`
      bit-decode and `SpotLight3D` construction path compiles and the flag logic is
      correct, but haven't run it against a real spot-light placement. Flagging
      honestly rather than claiming full coverage — revisit if a real cell with a
      spot light is needed for something later.
- [~] A `LIGH` with a fixture mesh shows both mesh and light — the factory handles
      this case (mesh children built first, then the light, both optional
      independently), and confirmed via direct ESM inspection that fixture-bearing
      lights exist in the game (`Barrel02Firebright`/`Barrel02Fire256aNoSound`, a
      burning-barrel fire light + mesh; `FXLightElectricArc02FillSM`). **Not run
      end-to-end** — neither test cell happens to contain one. Code path exists and
      is structurally exercised (mesh-optional logic is the same as every other
      Tier 1 factory, which is tested); the light+mesh *combination* specifically
      isn't.
- [x] Visual confirmation via real render: `GSDocMitchellHouse` screenshot shows
      visible warm glow patches from the room's own point lights (subtle against the
      demo scene's flat directional sun, but present and correctly positioned) where
      the previous 1.1 render (before this task) was uniformly flat.

## Explicit non-goals for this task

- Flicker/pulse animation.
- Shadow-casting quality/performance tuning.
- Exact falloff-curve translation from Havok/Gamebryo's lighting model to Godot's —
  approximate mapping is the explicitly agreed bar.
