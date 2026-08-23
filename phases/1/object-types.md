# Phase 1 — Placeable Object Types

Parent: [Phase 1](README.md) · Companion to [architecture.md](architecture.md)
(this doc is the type-by-type checklist; architecture.md is the node-design writeup;
[00-interior-cell-loader.md](00-interior-cell-loader.md)/[01-object-type-registry.md](01-object-type-registry.md)
are where these get implemented)

**What "Placement status" measures, in every table below:** whether the type resolves
its `REFR` to the right base record and places the right mesh at the right transform —
Phase 1's own bar, stated in the paragraph below. It does **not** mean
gameplay-functional. Pickup, inventory, equipping, consuming, reading, opening, locking,
usable state — none of that exists for anything in this doc yet, for any type, and none
of it is supposed to until later phases (inventory/equipment is Phase 7/8 per
[ROADMAP.md](../../ROADMAP.md)). "Done" means "correctly placed as a mesh," full stop —
nothing more.

Every record type a `REFR` (or `ACHR`/`ACRE` for actors) can point to via its `NAME`
subrecord, per the [fopdoc REFR reference list](https://tes5edit.github.io/fopdoc/FalloutNV/Records/REFR.html)
— the authoritative source for this table (accessible, unlike UESP which 403s from
this environment; see [phases/0/01-bsa-reader.md](../0/01-bsa-reader.md)'s note on the
same issue). This is the checklist for "what does 1.1 (all mesh-bearing static types)
actually need to cover."

All of these share the same underlying resolution mechanism proven in
[0.5](../0/05-integration-tool.md): `REFR.NAME` → base record → (usually) `MODL`
subrecord → NIF path → the existing BSA/NIF/DDS pipeline. The interesting differences
between types are (a) whether that mechanism applies at all, and (b) what, if
anything, needs to happen beyond placing a mesh.

## Tier 0 — proven

| Type | Name | Placement status |
|---|---|---|
| `STAT` | Static | **Done.** Full pipeline proven end-to-end in [0.2](../0/02-esm-parser.md)/[0.5](../0/05-integration-tool.md), 15 real objects round-tripped. |

## Tier 1 — same mechanism as STAT

Each of these has its own `EDID`+`MODL` pair in its own record body (not a reference
to a STAT — see the architecture discussion in this phase's planning). Resolving them
is the same code as STAT with the type filter widened; the interactive/gameplay
behavior each implies (openable, usable, lootable, ...) is out of scope for Phase 1,
which only needs correctly-placed geometry.

**All done**, confirmed against `object_registry.gd`'s real three-tier dispatch
(`build()`/`resolve_placement()`): `DOOR`/`CONT`/`ACTI`/`FURN`/`SCOL`/`LIGH` get an
explicit registered factory (`ContainerNode`/`ActivatorNode`/`FurnitureNode` are typed
`GamebryoVisual` subclasses with zero extra fields today — real extension points per
`architecture.md`'s "typed node vs. generic node" rule, not yet exercised beyond
placement); every other type below is deliberately *not* registered and falls through
to the generic structural fallback (`GamebryoVisual`, keyed on MODL presence alone, not
a base_type whitelist) — confirmed intentional via `_register_defaults()`'s own comment
in `object_registry.gd`, not an oversight.

| Type | Name | Notes | Placement status |
|---|---|---|---|
| `FURN` | Furniture | Idle-animation furniture (chairs, workbenches). Mesh-only for Phase 1. | Done |
| `CONT` | Container | Openable containers. Mesh-only; inventory contents out of scope. | Done |
| `ACTI` | Activator | Generic interactable (levers, switches, radios). Mesh-only. | Done |
| `DOOR` | Door | Mesh-only for Phase 1's own bar; teleport/open/animation/sound behavior landed in Phase 3 ([00-door-completion.md](../3/00-door-completion.md)). | Done |
| `MISC` | Misc. Item | Loose world items. | Done |
| `WEAP` | Weapon | World-placed weapon pickups. | Done |
| `ARMO` | Armor | World-placed armor pickups. | Done |
| `AMMO` | Ammunition | World-placed ammo pickups. | Done |
| `BOOK` | Book/Magazine | | Done |
| `KEYM` | Key | | Done |
| `ALCH` | Consumable (chem/food/drink) | | Done |
| `NOTE` | Note/Holotape | | Done |
| `TREE` | Tree | Static-equivalent; no special vegetation-system dependency at the REFR level (that's `GRAS`, see below). | Done |
| `MSTT` | Moveable Static | Physics-movable static (barrels, signs). Physics/movability out of scope for Phase 1 — treat identically to STAT. | Done |
| `TACT` | Talking Activator | `ACTI` + sound/dialogue trigger. Mesh-only for Phase 1. | Done |
| `TERM` | Terminal | Computer terminal. Mesh-only; UI/hacking out of scope. | Done |
| `CCRD` | Caravan Card | World-placed pickup, moderate confidence on MODL presence (standard item pattern). | Done |
| `IMOD` | Item Mod (weapon attachment) | World-placed pickup, moderate confidence (standard item pattern). | Done |
| `CMNY` | Money (caps) | World-placed pickup, moderate confidence (standard item pattern). | Done |

## Tier 2 — needs new Godot-side work

| Type | Name | What's new | Placement status |
|---|---|---|---|
| `LIGH` | Light | Has `MODL` for a fixture mesh (confirmed) **plus** a `DATA` subrecord, decoded into a real `OmniLight3D`/`SpotLight3D` in `object_registry.gd`. `DATA` layout confirmed via fopdoc: `Time (int32)`, `Radius (uint32)`, `Color (rgba)`, `Flags (uint32)`, `Falloff Exponent (float32)`, `FOV (float32)`, `Value (uint32)`, `Weight (float32)`. `Flags`' spot-vs-point bit is decoded (`kLightFlagSpot`/`LightData::is_spot()`, see [phases/1/03-light-sources.md](03-light-sources.md)). Benchmark is correctly-placed light sources, not 1:1 falloff-curve fidelity. | Done |

## Composite — needs one extra unpacking step

| Type | Name | Mechanism | Placement status |
|---|---|---|---|
| `SCOL` | Static Collection | Confirmed via fopdoc: bundles multiple `STAT` refs in one record. Each part = `ONAM` (FormID of a `STAT`) + `DATA` (its own position/rotation/scale, local to the `SCOL`). A `REFR` placing a `SCOL` expands into N STAT placements, composing the `SCOL` part's local transform with the outer `REFR`'s transform (`object_registry.gd`'s `_build_scol()`). Same STAT mesh pipeline underneath. | Done |

## Out of scope for Phase 1 (explicit, not oversights)

| Type | Name | Why deferred |
|---|---|---|
| `LVLN` | Leveled NPC list | Actor spawning — Phase 1 explicitly excludes NPCs/AI per [ROADMAP.md](../../ROADMAP.md). |
| `LVLC` | Leveled Creature list | Same — actor spawning. |
| `ASPC` | Acoustic Space | Audio-only (reverb/ambience region), no visual mesh. Later audio-phase work. |
| `GRAS` | Grass | Confirmed via fopdoc: **not** actually `REFR`-placed in practice — density-driven by `LAND`'s per-texture grass data, a separate system from object placement. Deferred to whichever phase handles landscape dressing detail (likely Phase 2). |
| `PWAT` | Placeable Water | Has a visual water-plane mesh, but ties into the water rendering/shader system, not plain static geometry. Defer until water rendering is addressed. |
| `IDLM` | Idle Marker | NPC idle-animation positioning marker, not really a render target. Tied to actor AI (out of scope). |

## Needs research before implementing (low confidence, flagged rather than guessed)

| Type | Name | Open question |
|---|---|---|
| `TXST` | Texture Set | Listed by fopdoc as a valid `REFR.NAME` target, which is unusual — `TXST` is normally referenced *by* other records (`LTEX`, shader properties), not placed directly. Possibly used for direct decal placement. Needs a source check before deciding how (or whether) to handle it. |
| `ARMA` | Armor Addon | Normally a sub-component `ARMO` uses to pick per-race/gender meshes, not typically placed directly. fopdoc lists it as valid; unclear how common this is in practice. Low priority — revisit only if it shows up in a real cell we're trying to load. |

## What's still explicitly out of Phase 1 regardless of type

- `ACHR`/`ACRE` (actor/creature placement) — no NPCs/AI, per ROADMAP.
- Interactive/gameplay state for any of the above (open/closed, locked, lootable,
  usable) — Phase 1's benchmark is correctly-placed geometry, not interaction.
- Leveled-list resolution logic in general (picking a level-appropriate entry) —
  not needed since Phase 1 doesn't spawn actors, and `LVLI` (leveled item, used by
  container contents) isn't a `REFR` target at all.
