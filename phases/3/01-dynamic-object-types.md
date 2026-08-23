# Phase 3.1 — Dynamic Object Types

Parent: [Phase 3](README.md) · Builds on [enginedocs/nv_class_hierarchy.md](../../enginedocs/nv_class_hierarchy.md)'s
Dynamic/Static classification · Companion to [phases/1/object-types.md](../1/object-types.md)
(that doc tracks mesh **placement**, already "Done" for every type below — this doc
tracks the separate, harder bar: does the type have a real per-instance Godot `Node`
capable of one day running a script or diverging from the ESM at runtime).

## What "Dynamic" means here (from nv_class_hierarchy.md, restated precisely)

> **Dynamic**: can have a script, or can move (or both) — either capability makes an
> object's state potentially diverge from the ESM per-instance at runtime, which is
> exactly what a shared-RID batch (`DirectGeometryBatch`) can't represent. **Static**:
> neither — a shared RID is not just cheaper, it's correct.

A type being Dynamic isn't gradual or optional — it either always needs a real Node,
or it never does. **Which Dynamic types currently have one is what this table tracks.**
A Dynamic type with no registered factory doesn't "work indoors, missing outdoors" —
`GamebryoObjectRegistry`'s CellLoader-facing registry (`register()`/`_register_defaults()`)
and `WorldStreamer`'s separate, deliberately fixed threaded-resolve dispatch list
(`resolve_placement()`'s own `match` statement, which never consults the mutable
registry — see that function's own doc comment on why) are two genuinely separate
places; a type needs registering in **both** or it silently falls through to the
RID-batched Static path outdoors regardless of what CellLoader does with it indoors.

**Real-data method, not guesswork:** "does this base record type ever actually carry a
script in the shipped game" was checked directly against `FalloutNV.esm` — a native
scan (`native/tools/scri_scan.cpp`, add it if re-running this) counting real `SCRI`
subrecord presence per record type, not assumed from GECK Wiki prose (which turned out
to be an unreliable source for this specific fact — see "Confirmed NOT dynamic" below,
several types the wiki's own field-description text implies *could* have a script but
zero real instances in the base game + all DLC ever do).

## Already registered (both dispatch points) — proven WorldObject branch

These five prove the pattern (`GamebryoVisual` subclass, composed `StaticBody3D` child
for collision) — every remaining row below extends the same branch, no new base class
needed. **Script execution itself is blocked on Phase 5's interpreter for all five** —
having a real Node is necessary but not sufficient; none of these can run their real
`SCRI` script yet, only exist as a script-*capable* target once 5.0 lands.

| Type | Name | Real SCRI usage (FalloutNV.esm) | Node type | Status |
|---|---|---|---|---|
| `DOOR` | Door | 136/320 | `DoorNode` | Node done; animation/sound/flags done ([00-door-completion.md](00-door-completion.md)); script execution blocked on Phase 5 |
| `CONT` | Container | 124/2478 | `ContainerNode` | Node done (mesh-only); open/lock/inventory + script execution not started |
| `ACTI` | Activator | 992/1143 | `ActivatorNode` | Node done (mesh-only); script execution not started |
| `FURN` | Furniture | 16/234 | `FurnitureNode` | Node done (idle-anim mesh-only); script execution not started |
| `LIGH` | Light | 4/501 | `LightNode` | Node done (real light + mesh); script execution not started |

## Not yet registered — the actual remaining work

Every one of these currently falls through to `GamebryoVisual`'s generic structural
fallback outdoors (RID-batched, no Node, no way to ever ID an individual instance let
alone script it) and either the same fallback or nothing at all indoors. Needs
registering in both `GamebryoObjectRegistry._register_defaults()` and
`resolve_placement()`'s fixed match statement.

### WorldObject branch — same shape as the five above, no new base class

| Type | Name | Real SCRI usage | Why Dynamic | Proposed node type | Status |
|---|---|---|---|---|---|
| `TACT` | Talking Activator | 18/87 | Script + dialogue/Voice Type | `TalkingActivatorNode` | Node done (mesh-only); script execution blocked on Phase 5 |
| `TERM` | Terminal | 20/344 | Script (menu tree, per-item result scripts) | `TerminalNode` | Node done (mesh-only); terminal-menu behavior not started; script execution blocked on Phase 5 |
| `MSTT` | Movable Static | 0/241 | **No script ever** — Dynamic purely because Havok can reposition it per-instance at runtime (real edge case: proves Dynamic needs "or," not "and") | `MovableStaticNode` | Node done (mesh-only); Havok movement not started |

### Item branch — needs the dual in-world/in-inventory shape, not a bespoke Node per type

Per nv_class_hierarchy.md's own "Items — a sibling branch" section: don't give each of
these its own `GamebryoVisual` subclass — a picked-up Item's Reference *stops
existing* and becomes a plain inventory-entry Dictionary instead, so the design is one
shared `ItemNode` (in-world state) + a shared `ItemData`-shaped Dictionary (in-inventory
state) with an explicit conversion between them, not per-type subclassing. The
real-data surprise here: most Item-branch types have **effectively zero** real script
usage (safe to leave Static-batched indefinitely, script-wise) but a handful have
enough real instances that leaving them unregistered is a genuine, measurable gap:

| Type | Name | Real SCRI usage | Node type | Status |
|---|---|---|---|---|
| `MISC` | Misc. Item | 178/507 | `ItemNode` (shared) | Not started — largest real gap in this branch |
| `ARMO` | Armor | 47/389 | `ItemNode` (shared) | Not started |
| `KEYM` | Key | 7/283 | `ItemNode` (shared) | Not started |
| `WEAP` | Weapon | 17/261 | `ItemNode` (shared) | Not started |
| `CCRD` | Caravan Card | 270/270 (**all of them**) | `ItemNode` (shared) | Not started — every single real instance has a Pickup Script, confirmed real data, not the "moderate confidence" phases/1/object-types.md flagged it with |
| `ALCH` | Consumable | 2/189 | `ItemNode` (shared) | Not started — negligible but nonzero |
| `AMMO` | Ammunition | 2/92 | `ItemNode` (shared) | Not started — negligible but nonzero (also has a separate real `Impact Script` field on the base record itself, run on whatever Actor a projectile hits — orthogonal to placement-Node scripting, needs its own handling whenever Phase 6 combat lands) |

### Actor branch — doesn't exist as a branch at all yet

Per nv_class_hierarchy.md's own sketch: `GamebryoActor` as a sibling of
`GamebryoVisual` (same `GamebryoObject` root), composing an internal `CharacterBody3D`
child the same way `GamebryoVisual` composes `StaticBody3D`, with thin
`NPCNode`/`CreatureNode` leaves (most of the interesting shared data — Traits, Stats,
Factions, AI Data/Packages, Inventory, Animation, Sounds, Scripts — lives on the base,
not the leaves, per GECK's own "a lot of the data for the two types is identical").
Placement itself (via `ACHR`/`ACRE` REFR-equivalents) is also explicitly out of scope
for Phase 1 (no actors/AI) and not yet started — this is the single largest remaining
item in this whole doc, both in scope and in real record count.

| Type | Name | Real SCRI usage | Node type | Status |
|---|---|---|---|---|
| `NPC_` | Non-player character | 1046/3816 | `NPCNode` (extends `GamebryoActor`) | Not started — no placement, no base class, no node |
| `CREA` | Creature | 260/1578 | `CreatureNode` (extends `GamebryoActor`) | Not started — same |

## Confirmed NOT Dynamic (real data, closes several "needs research" flags from phases/1/object-types.md)

Checked directly against `FalloutNV.esm` rather than left as a guess — these have
**zero** real `SCRI` usage across the entire base game and never move at runtime, so
per the Dynamic/Static test they are correctly, permanently `DirectGeometryBatch`-eligible.
Not a gap to close:

| Type | Name | Real SCRI usage | Note |
|---|---|---|---|
| `STAT` | Static | 0/6785 | The baseline Static case, as expected |
| `SCOL` | Static Collection | 0/98 | Expands to `STAT` parts, same reasoning |
| `TREE` | Tree | 0/3 | |
| `BOOK` | Book/Magazine | 0/27 | GECK Wiki's own page implies books *can* carry a script ("not all books need scripts") — real data shows none in the shipped base game ever do. Still needs the Item-branch dual-representation treatment eventually for read/OnEquip behavior, just not for *this* (script-Node) reason |
| `NOTE` | Note/Holotape | 0/894 | Same caveat as `BOOK` |
| `IMOD` | Item Mod | 0/50 | |
| `CMNY` | Money (caps) | 0/6 | |
| `TXST` | Texture Set | 0/493 | Resolves the "needs research" flag from phases/1/object-types.md — fopdoc lists it as a valid `REFR.NAME` target (unusual), but zero real scripting and no plausible movement case. Whatever the real REFR-placed-TXST use case is (likely direct decal placement), it isn't script-driven |
| `ARMA` | Armor Addon | 0/131 | Resolves the other "needs research" flag — confirmed not independently script-capable |

## Cross-cutting blocker

**No Dynamic type can actually execute a script until Phase 5's interpreter
(`phases/5/00-script-interpreter-foundation.md`) is functional** — this doc tracks
"does the type have a real Node capable of one day hosting script state," which is the
prerequisite Phase 5 needs, not a substitute for it. The two workstreams are meant to
land in parallel per phases/5/README.md's own "started in parallel with the remaining
Phase 3 work" note: build the Nodes here so Phase 5 has real targets to wire
`OnActivate`/`OnLoad`/etc. events into as soon as it's ready, rather than sequencing
one fully after the other.
