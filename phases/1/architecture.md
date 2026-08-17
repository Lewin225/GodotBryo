# Phase 1 — Placed-Object Node Architecture

Parent: [Phase 1](README.md) · Companion to [object-types.md](object-types.md)
(implemented in [01-object-type-registry.md](01-object-type-registry.md))

How ESM-placed objects (`REFR` + whatever base record its `NAME` points to) become
Godot nodes. Written up after research + discussion settled on a layered design that
mirrors the format itself rather than inventing a Godot-side schema from scratch.
Naming below (`GamebryoReference`, `DoorNode`, etc.) is illustrative/pending — the
structure is the point, not the exact identifiers.

## Why translate, not replicate

Established earlier in Phase 1 planning: we translate Gamebryo data into Godot's own
node/resource types (as every Phase 0 task already did — BSA bytes → Godot-loadable
buffers, NIF geometry → `ArrayMesh`, `REFR` transform → `Transform3D`), rather than
mirroring `NiNode`/property/controller trees 1:1 inside Godot. Replicating Gamebryo's
scene graph would mean reimplementing its runtime *inside* Godot instead of using
Godot's own rendering/physics/animation systems — which defeats the reason to build on
Godot instead of writing a standalone engine (the source-port path this project
explicitly isn't taking; see [ROADMAP.md](../../ROADMAP.md)). One thing worth keeping
from the original structure purely for debuggability: NIF node names carry through to
the corresponding Godot node names, so a broken import is traceable without NifSkope
open side-by-side.

## The shared-field question

Do all these record types actually share anything, or does each need bespoke
handling? Checked directly against the format rather than assumed — fetched the
subrecord list for `STAT`, `DOOR`, `CONT`, `ACTI`, `FURN`, `MISC`, and `LIGH` (via
[fopdoc](https://tes5edit.github.io/fopdoc/FalloutNV/Records.html), the same source
used throughout Phase 0/1 research) and compared their leading subrecords:

| Type | EDID | OBND | FULL | Model | SCRI (script) | Destruction Data |
|---|---|---|---|---|---|---|
| `STAT` | ✓ (1st) | ✓ (2nd) | — | ✓ | — | — |
| `DOOR` | ✓ (1st) | ✓ (2nd) | ✓ | ✓ | ✓ | ✓ |
| `CONT` | ✓ (1st) | ✓ (2nd) | ✓ | ✓ | ✓ | ✓ |
| `ACTI` | ✓ (1st) | ✓ (2nd) | ✓ | ✓ | ✓ | ✓ |
| `FURN` | ✓ (1st) | ✓ (2nd) | ✓ | ✓ | ✓ | ✓ |
| `MISC` | ✓ (1st) | ✓ (2nd) | ✓ | ✓ | ✓ | ✓ |
| `LIGH` | ✓ | ✓ (per OBND-then-model convention) | — | ✓ | — | — |

This is a strong, sourced pattern, not a guess from two data points: **every
placeable "has a physical form" record leads with `EDID` → `OBND` → (optionally
`FULL`) → model data**, in that order, across all seven types checked. `SCRI`
(script attachment) and Destruction Data are near-universal on the *interactive*
subset (everything except `STAT`/`LIGH`) but absent from pure scenery — a second,
narrower shared trait, not a universal one.

Separately, every `REFR` (the placement instance, independent of what it places) has
its own universal layer: the record header FormID, `NAME` (base object FormID),
`DATA` (24-byte position+rotation), and optional `XSCL` (scale). This is a
**different layer from the base record's own fields** — `REFR.DATA` is about *where*
something is, `STAT.OBND`/`MODL` are about *what* it is. Conflating them was the
mistake to avoid.

## The layered class design

```
GamebryoReference            — every REFR: form_id, base_form_id, position, rotation, scale
  └─ GamebryoObject          — every base record with OBND: + editor_id, bounds
       └─ GamebryoVisual     — every base record with MODL: + mesh
            ├─ DoorNode
            ├─ ContainerNode
            ├─ ActivatorNode
            ├─ FurnitureNode
            ├─ LightNode     — + an actual Light3D (see object-types.md Tier 2)
            └─ (shared default node — everything else in Tier 1, until one needs to diverge)
       └─ GamebryoScriptable — mixin/trait for the SCRI-bearing subset (Door/Cont/Acti/Furn/Misc/...),
                               not yet meaningful (no scripting VM until Phase 5) but the right
                               place to hang script-driven behavior later without touching
                               GamebryoVisual's shape
```

Each layer corresponds to a real, confirmed subrecord boundary in the format — this
isn't a Godot-side abstraction invented for its own sake.

## Node composition per tier (what these become in the scene tree)

**`GamebryoVisual`-only types (most of Tier 1 — `STAT`, `MISC`, `WEAP`, `BOOK`, ...):**
```
StaticBody3D          (the node itself, whatever class it ends up as)
 ├── MeshInstance3D    — NIF submeshes + resolved DDS textures (0.3/0.4/0.5's pipeline)
 └── CollisionShape3D  — from NIF bhk data, or bbox/convex-hull fallback until that's built
```

**`LightNode` (`LIGH`):** same as above, plus an `OmniLight3D`/`SpotLight3D` sibling
driven by the confirmed `DATA` layout (`radius`→range, `color`→light_color, `falloff
exponent`/`FOV` for spot cone). See [object-types.md](object-types.md) for the full
field list.

**`SCOL` (Static Collection):** not a leaf type — a `Node3D` transform anchor whose
children are N ordinary `GamebryoVisual`-shaped nodes (one per bundled `STAT`, each
with its own local transform from the `SCOL`'s `ONAM`+`DATA` parts).

**Open question resolved by this research pass:** I'd flagged `ACTI` as a possible
case needing an `Area3D` trigger volume instead of plain mesh collision. Checked its
full subrecord list directly — no evidence for that. `XATO` is just an activation
prompt string; there's nothing structurally different from `STAT`'s shape. Treating
`ACTI` as `GamebryoVisual`-shape (`StaticBody3D`+mesh+collider) unless something
concrete surfaces later that contradicts it.

## Construction: factory dispatch, not one monolithic resolver

A registry keyed by record type tag, not a big switch statement or 19 hand-written
near-duplicate functions:

```
type_tag -> build_fn(resolved_record_data, refr_transform) -> Node3D
```

- One shared default factory covers every `GamebryoVisual`-shape type that hasn't
  diverged yet (right now: everything in Tier 1 except `LIGH`/`SCOL`).
- `LIGH` and `SCOL` get their own factories because their construction genuinely
  differs (extra light node; multi-part expansion), not because they're more
  "important."
- A type only gets pulled out of the shared default into its own factory when it
  actually needs to diverge — additive to the registry, not a refactor of what
  already works. `CONT` peeling off into `ContainerNode` later (say, for an
  open/closed visual state) doesn't touch `DoorNode` or the shared default at all.

### Registry extensibility

This project only targets FNV's own record set — we're not building cross-game
support for Oblivion/Skyrim/FO3/FO4's record types. But FNV's own DLCs already showed
in Phase 0 that the "known set" isn't perfectly closed (new BSA archives, new mesh
categories like `nvdlc42/`), and the wider Gamebryo family's habit of adding
game-specific record types each release is a good forcing example for a general
principle: **the registry should be open for extension by construction, not by
remembering to update a central dispatch function.**

Concretely: a runtime-populated map (`type_tag -> factory`), built via explicit
registration calls at startup, not a compiled `switch`/`if`-chain over type tags. A
new type is added by registering one more entry — nothing about the registry itself,
or any other type's factory, needs to change. This is the same additive property
already described above for peeling a type off the shared default; extensibility to
genuinely new/unknown tags is just the same property taken one step further.

Worth going one step further given the shared-field research above: since
"`OBND` + `MODL` present" is a *structural* signature we can detect directly from a
record's own subrecords, not something that requires knowing the type tag in advance,
an unregistered type doesn't have to mean "unrenderable." Resolution can fall back in
tiers:

1. Type tag has a registered factory (specific or shared-default) → use it.
2. No registered factory, but the base record structurally has `OBND`+`MODL` → fall
   back to the generic `GamebryoVisual` factory anyway. Loses whatever type-specific
   behavior a dedicated factory would've added, but still renders correctly.
3. Neither → skip with a log line (the same graceful-skip behavior already scoped for
   `ACHR`/leveled lists/etc. in [object-types.md](object-types.md)), not a crash.

That means encountering a record type not in the current [object-types.md](object-types.md)
checklist — a DLC-specific type we haven't cataloged, or something exotic like the
`TXST`/`ARMA`-as-REFR-target cases still flagged as needing research there — degrades
to "renders without its special behavior" rather than "breaks the loader."

## Typed node vs. generic node: the actual decision rule

Earlier framing ("type now" vs. "wait") was imprecise — a class's *field set* is
cheap to extend later (adding `is_locked: bool` to `DoorNode` when Phase 5 needs it is
routine incremental work, not a migration). What's actually costly to get wrong is the
**composition shape** — what the node is built out of. So the rule is:

> Give a type a real class now if `GamebryoVisual`'s shape (mesh + collider, and nothing
> structurally more) is sufficient for everything that type does *today*. Don't guess
> future fields — add them when the feature that needs them actually exists. Only hold
> off on a dedicated class when the composition shape itself is still unclear (not the
> field list).

Under that rule: `DoorNode`, `ContainerNode`, `ActivatorNode`, `FurnitureNode`, and
the rest of confirmed-shape Tier 1 can all be real typed classes today, each with
zero fields beyond what `GamebryoVisual` already provides. `LightNode` clearly needs
more than the shared shape (a real `Light3D`) and gets it now, sourced from the
confirmed `DATA` layout. Nothing in the current type list needs to stay generic
pending a shape decision — `ACTI`'s question was the only open one, and it resolved
in favor of the shared shape above.

## What this doc doesn't decide yet

- Exact class names/namespacing (`Gamebryo*` prefix is a placeholder).
- Whether these are GDExtension C++ classes (`GDCLASS`) or GDScript classes
  (`class_name`) — doesn't change the architecture, just where the code lives; can
  follow whatever native/ vs. project/ split makes sense when 1.0/1.1 are actually
  implemented.
- Collision extraction itself (`bhk*` → `CollisionShape3D`) — still the pending
  module flagged since [phases/0/results.md](../0/results.md); this doc assumes it
  exists, doesn't design it.
