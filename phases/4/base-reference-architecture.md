# Base / Reference Record Architecture

Parent: [Phase 4](README.md) · Revises: Phase 1's
[architecture.md](../1/architecture.md) placed-object layer, and extends it to
cover the ESM record layer (`EsmRecordResource` and its children), which
`architecture.md` didn't originally scope. Filed under Phase 4 rather than
Phase 1 since Phase 3's actor/inventory/equipment work is the build currently in
progress that this will actually land against — see Phase 4's own "Typed ESM
resource references" and "Equipment visual handoff" sections
([README.md](README.md)), which this document supersedes/formalizes.

This is a design decision, written up after a long investigation and discussion
settled on it. **No implementation/conversion plan yet — that's deliberately a later
document.** This one exists so the *why* survives independently of whoever writes
the conversion plan, and doesn't have to be re-derived.

## How this came up

Started from a concrete bug: NPCs (and the player) spawn with nothing equipped,
because nothing ever sets `is_equipped` on an inventory entry. Chasing *why* that
field was missing led to the real Fallout NV/Gamebryo object model — `NAME`
subrecords pointing at shared base records, `REFR`s carrying sparse per-instance
override data (`XHLP` health, `XCHG` charge, `XCNT` count, `XOWN` owner) — verified
against [fopdoc](https://github.com/TES5Edit/fopdoc)'s real `REFR.md` subrecord
table and cross-checked against OpenMW's actual (working, playable) implementation
of the equivalent Morrowind-era system. That, in turn, exposed that this project's
existing `GamebryoReference` (the placed-object Node base,
[architecture.md](../1/architecture.md)) and `EsmRecordResource` (the ESM-record-resource
base, `project/gamebryo/esm_record_resource.gd`) were each built to solve a narrower
problem than the one the real format actually poses, without a shared plan tying
them together. This document is that plan.

## Terminology: Base vs. Reference

Sourced, not invented — the [GECK Wiki Glossary](https://geckwiki.com/index.php?title=Main_Page)
draws exactly this line:

> "References are instances of Base Objects... Extra data can look like position
> data for forms placed in the world, or health data for forms like Weapons, and are
> unique to each reference." "The Form IDs in the Object Window are Base IDs. The
> Form IDs in the Cell View Window are Reference IDs."

- **Base** — the shared, authored, immutable record (`WEAP`, `ARMO`, `NPC_`, ...).
  Identified by its own `form_id`. Never points at anything else.
- **Reference** — one specific instance of a Base, placed in a cell or held in an
  inventory. Identified by `base_form_id` (which Base it's an instance of) plus its
  own instance identity. Carries whatever sparse override data has diverged from
  the Base's defaults (condition, position, ownership, ...).

Two parallel class families, both renamed for the same reason: the current code's
parent/child naming is inconsistent (`EsmRecordResource` the parent,
`WeaponRecord` the child — drops "Resource"). Both families below share their
parent's suffix instead:

```
EsmBase        →  WeaponBase, ArmorBase, NpcBase, StaticBase, LightBase, ...
                   (replaces EsmRecordResource / WeaponRecord etc.)
EsmReference   →  WeaponReference, ArmorReference, DoorReference, ...
                   (new)
```

## Why not one `Reference` type for everything

The real engine's own equivalent — OpenMW's `CellRef` (Morrowind-era, but the same
lineage) — is a single flat struct: `mDoorDest`, `mTeleport`, `mLockLevel` sitting
alongside `mChargeInt`, `mCount`, `mOwner`, all always present, most of them
irrelevant dead weight for any given instance (a picked-up dagger's `mDoorDest` is
meaningless; a placed door's `mChargeInt` is meaningless). This project's own native
`ReferencePlacement` struct (`native/src/esm/esm_types.h:84-162`) independently
converged on the same shape, for the same reason: it's cheap and simple in C++,
where a handful of always-present, mostly-zero fields cost nothing.

That reasoning doesn't carry over to a GDScript-facing `Resource` hierarchy, for
three separate reasons:

- **Memory.** A C++ struct's unused `float`/`bool` fields are free (stack-allocated,
  no indirection). A Godot `Resource` is a heavier, heap-allocated `RefCounted`
  object; a single `Reference` type wide enough to cover doors, lights, weapons,
  and NPCs at once means every placed rock in the world carries fields for
  ragdoll data, lock state, and weapon condition it will never use.
- **Type checking.** One wide type means every consumer has to duck-type its way
  to what it actually needs (`if result.has("emittance_color")`, the pattern
  already used ad hoc in `object_registry.gd` for `XEMI` tinting) instead of
  `if reference is WeaponReference`. Nothing stops a `DoorNode` from being handed
  a `Reference` that never had door fields populated, and finding out only at
  runtime. A type hierarchy makes "this doesn't apply to this kind of object"
  a compile-time-adjacent fact instead of a runtime dictionary miss.
- **Editor visibility** — the concrete complaint that started the naming
  discussion. A single flat `Reference` `Resource` shows every field (health,
  door destination, lock data, tint, ragdoll...) in the Inspector for every
  placement, regardless of what kind it is. Per-kind subclasses mean the
  Inspector only ever shows fields that are actually meaningful for the object
  being edited.

So: a thin `EsmReference` base carrying only what's genuinely universal (see
below), with per-kind subclasses adding only their own relevant override fields —
mirroring the pattern the codebase already uses successfully for the Base layer,
rather than copying OpenMW's/the native struct's "one wide struct" shape wholesale
into GDScript.

Deliberately **flat**, not deeply tiered: an earlier draft of this document
grouped `WeaponReference`/`ArmorReference` under an abstract `ItemReference` →
`DegradableItemReference` chain to share `count`/`condition`. Rejected — the whole
point of moving away from Bethesda's one-struct-for-everyone `CellRef` is to stop
fields riding along on types that don't need them; inventing abstract intermediate
tiers to avoid duplicating one or two fields between two or three concrete classes
just rebuilds a smaller version of the same problem one level up. A little
duplication between sibling `Reference` subclasses is the cheaper, more legible
trade than a tier that exists purely to avoid it.

## What `EsmReference` (the shared base) actually holds

Deliberately near-empty — but "near-empty" means *tested*, not *guessed*. See
"Promotion rule" below for the actual bar a field has to clear to live here.
Currently:

- `base_form_id: int` — which `EsmBase` this is an instance of. The one thing
  every Reference has by definition.
- `base: EsmBase` — the *resolved* form of `base_form_id`, not a second piece
  of data needing its own justification: every `Reference` points at exactly
  one `Base`, no exceptions, which is the same "true for 100% of subtypes" bar
  `base_form_id` itself already cleared. Resolved eagerly at construction (via
  `EsmServer.get_base()`, safe even on a `WorkerThreadPool` task since that
  call is required to be internally thread-safe regardless — see "Thread-safety"
  below), not lazily on first access. NOT `@export`ed / not persisted, same as
  everything in this document already established — only `base_form_id` is
  the actual save data; `base` is always cheaply re-derivable from it through
  the cache. A subclass narrows the type at the call site with a plain cast
  (`(reference.base as WeaponBase).damage`) rather than redeclaring the field
  with a narrower type.
- `instance_id` — this project's own synthetic identity (see below), not the raw
  Bethesda `RefNum`.
- Transform data: `position`, `rotation`, `scale`.
- `current_cell_form_id: int` — see "Save/load" below; sentinel `0` means
  "still wherever it was originally placed."

Transform needs its own justification, because it directly contradicts
`GamebryoReference`'s own doc comment (`gamebryo_reference.gd:4-7`), which argues
transform doesn't need separate fields because `Node3D` already has one. That's
true of the *Node*, not the *Record*. `EsmReference` is meant to exist as pure
data *before* any Node does — specifically so it can survive
`object_registry.gd`'s `resolve_placement()`/`resolve_tile()`, which is explicitly
documented (`object_registry.gd:101-119`, `:189-193`) to run on `WorkerThreadPool`
tasks and touch nothing Node/RenderingServer/PhysicsServer-related. A `Resource`
with only plain data fields is exactly as thread-safe there as the `Dictionary`
it would replace — but only if the transform actually lives on it as data,
since there's no `Node3D` yet for it to defer to at that point in the pipeline.
Only once a Reference is handed to `GamebryoReference` (a Node) at construct
time does its transform become that Node's actual `Transform3D`.

## Why `EsmBase` is a `Resource` at all, not just a cached `Dictionary`

Worth being precise about, since it's a different comparison than the Reference
one above, not a restatement of it: `EsmBase` doesn't replace a C++ struct —
`native/src/esm/esm_reader_gd.cpp`'s `get_record_data()` does real parse work on
*every* call (record lookup, byte-copy every subrecord into a fresh
`PackedByteArray`, build a `Dictionary`/`Array` tree), with no cache at the native
layer at all. So *some* cache, paid once per `form_id`, is unambiguously worth it
regardless of what it holds. The real question is why that cache holds typed
`Resource` instances (`esm_resource_factory.gd`'s existing `_cache`, feeding
`WeaponRecord`/`ArmorRecord`/etc.) rather than the same already-parsed
`Dictionary` cached as-is, skipping the `Resource` wrapper.

Answer: the same three reasons argued for per-kind `Reference` subclasses over
one generic bag, applied symmetrically. `InventoryComponent.editor_item_to_add:
EsmRecordResource` (`inventory_component.gd:12`) already depends on
drag-and-drop, type-constrained Inspector fields — a cached `Dictionary` can't be
dragged into an `@export` slot. `entry.item_record is ArmorRecord` (used
throughout `npc_actor.gd`) and typed arrays like `Array[ArmorRecord]` need real
class instances, not a `"record_type"` string to compare against. Keeping `Base`
as raw dictionaries while insisting `Reference` be typed would be the same
architecture applying its own reasoning inconsistently. The marginal cost of
`Resource` over `Dictionary` is real but secondary to the caching itself, which
is where the actual performance win comes from.

## Caching strategy: GDScript first, native only if profiling demands it

**Default: keep `EsmBase` caching exactly where it already lives** —
`esm_resource_factory.gd`'s `_cache: Dictionary`, keyed by `form_id`, returning
the same shared `Resource` instance on every hit. Not a placeholder to be
migrated on principle; a deliberate starting point, kept until real evidence says
otherwise.

**Non-negotiable regardless of where the cache ends up living: a hit must
return the existing shared reference, never reconstruct.** `Resource` in Godot
is `RefCounted` — a cache hit is a pointer/refcount bump, not a copy, and
nothing here should ever call `.duplicate()`. Ten `WeaponReference`s pointing at
the same `base_form_id` share exactly one `WeaponBase`; only `condition` (on
each `WeaponReference`) varies between them. This property is what makes the
factory's caching worth doing at all — a native implementation that quietly
rebuilds a fresh instance per call instead of returning the cached one would
silently reintroduce per-instance duplication while still looking like "a
cache" from the outside. Whoever implements a cache at any layer needs to
preserve this on purpose, not by accident.

**If profiling ever shows the GDScript-side parse/cache path is a real
bottleneck**, two escalation levels, cheapest first:

1. **Native-side raw-parse cache only.** `EsmReader::get_record_data()`
   currently reparses a record's subrecords from bytes on *every* call, with no
   cache at the native layer at all (`esm_reader_gd.cpp:564-588`). Caching that
   step in C++ (raw `Dictionary`/subrecord data, keyed by `form_id`) speeds up
   repeat native calls without touching where `WeaponBase`/`ArmorBase` are
   defined or how GDScript builds them — `esm_resource_factory.gd` keeps
   constructing the typed `Resource` exactly as it does today. Fully
   inspector-visible, no consumer-facing change, smallest possible step.
2. **Full native `EsmBase` classes**, only if step 1 isn't enough. Real
   `Resource`-derived classes registered from C++ (`GDREGISTER_CLASS`, bound
   properties) are just as Inspector-visible and `is`-checkable as GDScript
   ones — the earlier "loses tooling" worry was specifically about native code
   using reflection to instantiate a class GDScript owns, not about
   native-*defined* classes in general, which behave normally. The real cost
   here is porting the byte-decode logic (`_u32()`/`_string()`-style subrecord
   parsing, the per-type `_build_*()` functions) into C++ — proportional,
   known-shape work, the same kind already done for `nif_loader.cpp`/
   `esm_reader_gd.cpp` elsewhere in this codebase, not novel risk. It does
   trade away editing record fields without touching native code, which is
   why it's the second resort, not the first.

**Why starting in GDScript doesn't paint this into a corner:** consumers only
ever depend on the property-based interface (`weapon.damage`, `is ArmorBase`,
Inspector drag-and-drop) — which is identical whether a class is registered
from GDScript or from native code. That's what stays stable across either
escalation step; a `Dictionary`-first design would have made this migration
strictly harder; committing to typed `Resource`s now is what keeps it cheap
later.

**Cutover doesn't have to be all-or-nothing.** Godot's object model
interoperates transparently between native and GDScript-registered classes, so
a migration (if it ever happens) can go type-by-type — leaf types with no
cross-references first (`HairRecord`/`EyesRecord`), types that reference other
`Base`s last (`NpcRecord`) — rather than one big cutover of the whole `EsmBase`
family at once.

**One concrete, already-observed cost to remember, not hypothetical:**
`player.tscn` already bakes some of these as `SubResource` blocks referencing a
GDScript script path (`script = ExtResource(...)`). A class moving from
GDScript-defined to native-registered changes how it's referenced in
serialized `.tscn`/`.tres` data — any already-baked scene data holding one of
these needs a one-time re-save when its type migrates. Small, mechanical, but
real, worth remembering rather than rediscovering as a surprise.

## Editor integration: reference-only on-disk storage

`esm_resource_factory.gd`'s own doc comment (`:6-8`) says `EsmBase` resources
are "intentionally not written to disk" — which is right (no per-record `.tres`
files littering the repo, no staleness against the ESM), but it has a real,
already-observed side effect worth fixing: a `Resource` with no `resource_path`
gets embedded inline as a full `SubResource` wherever it's referenced, because
Godot only serializes something as a lightweight `ExtResource` (path reference)
when it has a real path to point at. `player.tscn` already shows the result —
`Resource_8rogd`/`Resource_ge24q` and the baked `LVLI` entries array are full
resolved ESM data sitting directly in the `.tscn` text, not references. Assigning
an `EsmBase` to any `@export` slot in the editor today (e.g. an actor dropped
onto the player's actor node) bakes a full copy of that ESM data into the
scene file.

**Fix: give `EsmBase` a real `resource_path`, using the `source_uri` it
already computes** (`esm_resource_factory.gd:86`:
`"esm://FalloutNV.esm/%s/%08X" % [record_type, form_id]` — already
present, just not wired into Godot's resource system yet), and register a
custom `ResourceFormatLoader` that recognizes that scheme. Verified directly
against the Godot 4.7.2 source (`enginedocs/godot-4.7.2 source/`), not assumed:

- `ResourceFormatLoader::recognize_path()`
  (`core/io/resource_loader.cpp:62-83`) tries a custom `_recognize_path`
  override first, falling back to extension-matching only if that's not
  implemented — a loader can claim an arbitrary scheme like `esm://` outright,
  this is a first-class mechanism, not a hack riding on file extensions.
- `ResourceLoader::_load()` (`core/io/resource_loader.cpp:275-293`) does
  nothing but ask each registered loader `recognize_path()` and hand off to
  whichever says yes — no filesystem-existence check anywhere in the dispatch.
- The `.tscn`/`.tres` text parser already special-cases this exact shape
  (`scene/resources/resource_format_text.cpp:509`):
  `if (!path.contains("://") && path.is_relative_path())` — a path containing
  `"://"` is treated as already scheme-qualified and handed to the loader
  as-is, never joined against the scene's own directory the way an ordinary
  relative path would be. Same mechanism `user://`/`res://` already use.

With that in place: referencing an `EsmBase` from a scene serializes as
`ExtResource(path="esm://FalloutNV.esm/NPC_/00001234")` — a path string,
functionally just the FormID, never the embedded data. Loading that scene back
triggers Godot's normal external-resource loading, which our custom loader
intercepts and hands off to `get_base()` — so what comes back is the real,
freshly-resolved resource through the same factory/cache as everything else,
not a stale deserialized copy. Drag-and-drop Inspector assignment stays exactly
as it is today (still a real, typed `Resource` the whole time) — only the
on-disk footprint changes, from a full data dump to a reference.

**Scope this correctly: this is editor tooling convenience, not a load-order
system, but the URI itself is fine as-is — the master name is a genuine,
permanent part of a `form_id`'s identity, not something that goes stale.**
Real Bethesda `form_id`s are already exactly this shape — confirmed earlier in
this document via `ESM::FormId { uint32_t mIndex; int32_t mContentFile; }`
(`components/esm/formid.hpp`): `mContentFile` records which plugin originally
*defined* a `form_id`'s slot, fixed at creation, and it never changes for that
record's whole existence. An override doesn't mint a new `form_id` — it
reuses the original one, supplying a different payload for the same,
permanently-`FalloutNV.esm`-anchored address. So `esm://FalloutNV.esm/NPC_/
00001234` stays correct and stable forever, override or not; there's no
"master goes stale" problem here to solve, and nothing about the path itself
needs to change.

What *would* need building, only if third-party `.esp` override support ever
gets added: given that same fixed, correctly-addressed `form_id`, `get_base()`
would need to check the currently active load order and return whichever
plugin's payload currently wins for it — falling back to `FalloutNV.esm`'s own
original data if nothing overrides it. That's entirely internal to
`get_base()`'s resolution — the address a scene stores never needs to change or be
reinterpreted; only which layer of *data* answers it can shift, invisibly to
anything holding the reference.

Not solved here, not pretended to be solved — this mechanism's real, current
value is a genuine one anyway: dragging a specific ESM record into a scene as
a lightweight reference for editor-side tooling (a NIF
workspace, machinima/cinematic scene-building), independent of whatever a
future load-order system ends up looking like.

Same mechanism doubles as the answer to "how does a dev pick a `base_form_id`
without typing a raw FormID" from the authoring-workflow discussion — a
search/picker tool (an `@export_tool_button`-based dialog over
`EsmReader.get_record_index()`, `esm_reader_gd.cpp:590-609`, matching the
existing pattern in `InventoryComponent._editor_add_item`/`NPCActor._editor_load`
rather than introducing a new one) resolves the pick via `get_base()`, which
returns a resource whose `resource_path` is already the right `esm://` URI —
dragging or assigning it from there just works, no separate serialization
concern to solve on top of the picker itself.

## Promotion rule: when does a field belong on the shared root?

Tripped over this getting `XEMI` wrong on a first pass (see worked example
below), which is exactly why the rule below is empirical, not intuitive:

> A field earns a spot on the shared `EsmReference` (or `EsmBase`) root only if a
> real survey of the actual `REFR` subrecord table
> ([fopdoc](https://github.com/TES5Edit/fopdoc/blob/master/FalloutNV/Records/REFR.md))
> shows it present across a clear majority of REFR-capable base types. "Could
> conceptually apply to almost anything" is not the test — actual presence across
> most types is. If a field is confined to one or a handful of specific types, it
> belongs on those types' own `Reference` subclasses, full stop, no matter how
> unrelated to any single type it feels in the abstract.

By this rule, only `base_form_id`/`instance_id`/transform currently clear the bar.
Everything surveyed so far — lock data, condition, ammo, ownership, and `XEMI`
tint — stays scoped to specific subclasses.

### Worked example: `XEMI` (emittance tint)

First pass reasoned: `XEMI` is "deliberately a reference-level field, not a
property of the shared STAT base record" (per its own native-code comment,
`esm_types.h:99-102`) *and* it can appear on more than one kind of placement — so
it looked "not type-gated" and a candidate for the shared root. Wrong test: being
untied to *one specific* type isn't the same as being common across *most*
types. In practice `XEMI` is confined to `STAT` and `MSTT` (movable statics) —
used to tie a static prop's own emissive glow to a specific `LIGH` (or,
per the same native comment, occasionally a `REGN`)'s artist-authored color, so
the prop's glow matches a nearby light without every artist re-authoring the
color by hand. That's two types out of the much larger set of REFR-capable
kinds — nowhere near "a clear majority." Corrected placement:

```
EsmReference
  ├─ StaticReference          (emittance_form_id: int → resolves to LightBase or a region-equivalent base)
  └─ MovableStaticReference   (emittance_form_id: int → same)
```

Flat, not a shared `TintableReference` intermediate for just these two — same
reasoning as rejecting `ItemReference` above. Note this also reverses an earlier
conclusion in this same discussion that `STAT`/`MSTT` wouldn't need subclasses at
all (they'd been assumed to have zero override fields) — `XEMI` is the
counterexample, found by actually checking rather than assuming, which is the
whole point of testing against the rule instead of intuiting it.

## Per-kind Reference subclasses (surveyed so far)

Flat off `EsmReference`, no forced intermediate tiers:

```
EsmReference
  ├─ WeaponReference        (count, condition, loaded ammo type/count — XAMT/XAMC, weapon-only)
  ├─ ArmorReference         (count, condition)
  ├─ DoorReference          (lock data — XLOC; teleport destination — XTEL; is_open)
  ├─ ContainerReference     (lock data; contents: Array[EsmReference])
  ├─ ActorReference         (health; contents: Array[EsmReference]; equipped-slot table; alive/dead)
  ├─ StaticReference        (emittance_form_id)
  └─ MovableStaticReference (emittance_form_id)
```

Not every kind needs a subclass. Anything with genuinely zero override fields —
after being checked against the promotion rule, not assumed — stays a bare,
directly-instantiable `EsmReference`. This is a real, deliberate difference from
`GamebryoReference` on the Node side: nothing ever instantiates a bare
`GamebryoReference` (confirmed, `object_registry.gd:160-187` — every placement
routes to a concrete leaf Node), because a Node always needs *some* concrete
rendering behavior to do anything at all. A bare `EsmReference` has no such
requirement — it's pure data, and "no extra fields" is a valid terminal state for
data in a way "no extra behavior" isn't for a Node.

`WeaponReference` as the fullest worked example, showing the Base/Reference
split in practice:

```gdscript
class_name WeaponReference
extends EsmReference

# base_form_id / base are inherited from EsmReference, not redeclared here —
# every Reference already has them; WeaponReference only adds what's actually
# weapon-specific.
var condition: float = -1.0      # persisted, mutable — the actual point of this class
```

`base` (inherited, `EsmBase`-typed) is a runtime convenience only, never
serialized — resolved from `base_form_id` through the same cache that already
guarantees every `WeaponReference` pointing at the same `base_form_id` shares
the *same* `WeaponBase` object, never a duplicate: `(reference.base as
WeaponBase).damage`. Not a new mechanism: this is the existing
`esm_resource_factory.gd` cache and the existing `InventoryEntryResource.item_form_id`
/ `.item_record` split, formalized under the new naming and extended with the one
thing `InventoryEntryResource` was missing — `condition`.

`condition` defaults to `-1.0`, following the same "sentinel means untouched"
convention as the real `XHLP` subrecord (confirmed via `fopdoc`: absent unless
diverged) — most items in a playthrough are never fired/damaged and shouldn't
need a real value written for them.

`ContainerReference`/`ActorReference`'s `contents: Array[EsmReference]` is
deliberately self-similar: a container's inventory and an actor's inventory are
both just arrays of References, same shape as `InventoryComponent.entries` today,
just holding the new typed References instead of `InventoryEntryResource`.
`ActorReference`'s equipped-slot table is the `equipped_instance_ids` design from
the equipment-slots discussion — a list of which of its own `contents` entries
are currently worn/wielded, not a flag living on the entries themselves.

## Which types need `Base` only vs. `Base` + `Reference`

Every currently-supported record type needs a `Base` — unconditional, already
established: `get_base()` must always return a properly typed resource for
whatever it resolves, since `Base` is just "what's actually in the file."
`Reference` is narrower, and the test for it is a durable, format-level fact,
not a snapshot of what this project happens to parse today: **does the format
permit this type to ever be a targeting-field target — a `REFR`'s `NAME`, or
the `ACHR`/`ACRE` sibling family actors use** — not "has this project actually
built support for placing one yet." A type earns `Reference` support the
moment support for placing it is ever added, whether or not that's happened
yet; re-deriving the test per type as new ones get built would be wasted work
when the format itself already answers it exhaustively, once.

Checked directly against [fopdoc's `REFR.md`](https://github.com/TES5Edit/fopdoc/blob/master/FalloutNV/Records/REFR.md)
`NAME` field, not assembled from memory of what this project currently
touches — its own list is exhaustive:

**Could be targeted — needs `Reference` (dedicated subclass or bare
`EsmReference`, per the promotion-rule survey) whenever placement support
exists, even if unbuilt today:**
`TREE`, `SOUN`, `ACTI`, `DOOR`, `STAT`, `FURN`, `CONT`, `ARMO`, `AMMO`,
`LVLN`, `LVLC`, `MISC`, `WEAP`, `BOOK`, `KEYM`, `ALCH`, `LIGH`, `GRAS`,
`ASPC`, `IDLM`, `ARMA`, `MSTT`, `NOTE`, `PWAT`, `SCOL`, `TACT`, `TERM`,
`TXST`, `CCRD`, `IMOD`, `CMNY` — plus `NPC_`/`CREA` via the `ACHR`/`ACRE`
sibling family (actors aren't placed via literal `REFR`, confirmed by native
code already having a separate `get_cell_actors()` distinct from
`get_cell_references()`, but `phases/1/architecture.md` already treats them as
one architectural family: *"REFR + whatever base record its NAME points
to"*).

Note `ARMA` belongs here, corrected from an earlier pass in this same
discussion that placed it in the "referenced-only" list below — every case
*this project* has built so far reaches an `ArmorAddonRecord` indirectly
(`ARMO.BIPL → FLST → ARMA`), never as a direct placement, but the format
itself explicitly permits `ARMA` as a standalone `REFR` target regardless of
current usage. The "could be" test is exactly what catches this kind of
scope-creep-by-assumption before it hides in the doc as a wrong assumption.

**Never in that list — `Base` only, never `Reference`, by format definition:**
`RACE`, `HAIR`, `EYES`, `CLAS`, `PACK`, `FLST`. These are reached exclusively
as fields on other `Base`s (`NpcBase.race → RaceBase`,
`WeaponBase.biped_model_list → BipedModelListBase`) — a `Base`-to-`Base`
pointer relationship, never a placement, so `Reference` isn't just unbuilt for
these, it's structurally inapplicable.

## `EsmServer`: one global singleton, five entry points

Named for what each unambiguously returns, not for a mechanism — a `"load_"`/
`"resolve_"` verb would wrongly commit to "always does real work" or leave it
unclear *what* comes back at all; `"get_"` says exactly what's returned and
stays honest that any call may be a cache hit or real construction underneath,
either way. `get_base()`/`get_reference()` can't share one polymorphic
function regardless of naming — a `REFR`'s own FormID and a `Base` record's own
FormID share the same numeric address space, so a bare `int` can never
self-disambiguate which kind of identity it is, and one function trying to
cover both could only ever declare a useless common return type:

- **`get_base(base_form_id: int) -> EsmBase`** — the base-record-only entry
  point discussed throughout this document (`fetch()` in earlier drafts of
  this discussion). `EsmResourceFactory`'s existing `load_weapon`/
  `load_armor`/`load_npc`/etc. become thin wrappers around it when that
  conversion happens — not touched now, per the deferred rename. Fully
  cacheable forever: a `Base` record is immutable ESM data, untouched by
  player action by definition, so this is the one call with zero session
  dependency.
- **`get_reference(instance_id: String) -> EsmReference`** — resolves one
  specific, already-known `Reference` without rescanning a whole cell.
  Takes `instance_id`, not a raw `REFR` FormID — a runtime-created reference
  (something dropped, or split off a stack) has no backing `REFR` record in
  the ESM at all, only a synthetic `"runtime:..."` id, so an `int` FormID
  parameter could never address it. `instance_id` already covers both
  authored and runtime references uniformly, which is the whole reason it
  exists.
- **`get_references_in_cell(cell_form_id: int) -> Array[EsmReference]`** —
  the highest-traffic entry point of the three: "what's in this cell" is
  always `Reference`-shaped (a cell is a list of placed instances, never a
  list of `Base`s), so this is what most world-streaming code actually
  calls. The typed replacement for today's `EsmReader.get_cell_references()`.
- **`get_base_type(base_form_id: int) -> Script`** — a cheap type check
  without paying for full resolution: skips subrecord parsing/`Resource`
  construction entirely, backed by an index-only `{type_tag: Script}` lookup
  (the *same* internal dispatch table `get_base()` already needs for
  construction, just projected to return the class instead of calling the
  builder). Returns the actual class (`WeaponBase`, `ArmorBase`, ...), not a
  raw `"WEAP"` string — a caller compares `result == WeaponBase` rather than
  string-matching, avoiding the exact duck-typed dispatch pattern
  (`object_registry.gd`'s `result["emittance_color"]`-style checks) this
  whole `Base`/`Reference` split exists to move away from. Record *type*
  never changes due to player action, so this is as pure and cacheable as
  `get_base()` itself — no session dependency.
- **`get_reference_type(refr_form_id: int) -> Script`** — same idea, one
  real subtlety: a `REFR`'s own `record_type` is always literally `"REFR"`,
  so a naive type lookup on the `REFR`'s own `form_id` would trivially
  return the same useless answer for everything. This has to dereference the
  `REFR`'s `NAME` subrecord to its `base_form_id` first, *then* look up
  *that* target's type — two hops, not one. Still cheap (only needs the
  target's type, not its full data), but a genuinely different mechanism
  than `get_base_type()`, not just the same lookup on a different id.

**All five live on one singleton, `EsmServer`, in the same vein as Godot's own
`RenderingServer`/`PhysicsServer3D`** — a global service any code can call
without threading a reference through constructors, may or may not use
background threads internally, not something a caller needs to know. This
isn't a nicety; it fixes an already-real risk in the current codebase.
`EsmResourceFactory.new()` is independently constructed in at least three
places today (`object_registry.gd:46`, `npc_actor.gd:759`,
`addons/esm_browser/esm_browser.gd:62`), each with its own separate `_cache`
— meaning the "a cache hit must return the existing shared reference, never
reconstruct" rule elsewhere in this document can already be silently violated
if two of those factories happen to resolve the same `form_id` independently.
`EsmReader.new()` is called from 15+ separate non-diagnostic call sites. One
`EsmServer` makes that impossible by construction: one cache, no way to end up
with two.

**`get_reference()`/`get_references_in_cell()` are not cacheable the way
`get_base()` is — their answers depend on live game state
(`CellSaveState.removed_instance_ids`/`changed_references`,
`CurrentLocationIndex`) that can change on any frame:** an item picked up, a
physics prop crossing a tile boundary. Returning a memoized answer risks
reporting a picked-up item as still lying on the floor. Both must recompute
against current state on every call — no caching layer at all for these two,
not even a short-lived one. (A *loaded, currently active* `Reference`'s object
identity is still stable and shared while resolved — mutations happen in
place on that one live object, not by re-fetching — the same sharing
guarantee `get_base()` has, just for something genuinely mutable rather than
frozen. An *unloaded* one still has to reconstruct from whatever the save's
current state says, every time, which is correct, not stale — the save data
*is* the current source of truth for anything not presently live.)

This does mean `EsmServer` needs to know which save is currently active for
those two calls to be correct — the one piece of real session-lifecycle
complexity worth designing for deliberately rather than glossing over. Concretely:
`EsmServer` holds one internal, nullable reference to the current
`GameSession` (see "Save/load" below for what that actually is — the live,
in-memory session object, not the `SaveGame` it serializes to), set on load
and cleared on return-to-menu. `get_base()` never
touches it — a `Base` record is correct with or without an active session,
which is exactly what lets a standalone tool with no save loaded at all (a NIF
viewer, an editor diagnostic — several of the 15+ `EsmReader.new()` sites
found above are exactly this) keep working unmodified. `get_reference()`/
`get_references_in_cell()` consult it when present, and fall back to pure ESM
baseline resolution when it's null, rather than needing a second service a
caller has to choose between.

**Thread-safety is `EsmServer`'s job, not the caller's, if it's ever called
from `object_registry.gd`'s existing `WorkerThreadPool` tasks** (`resolve_placement()`/
`resolve_tile()`, already documented as safe specifically because they touch
no shared mutable state, `object_registry.gd:101-119`). A global singleton
with one shared, mutable cache being called concurrently from multiple worker
threads needs real internal synchronization (a `Mutex` around cache reads/
writes) — GDScript `Dictionary` mutation isn't safe across threads without it.
"The caller doesn't need to know if it uses reader threads internally" has to
be earned by `EsmServer` doing that locking itself, the same way
`RenderingServer` is safe to call from any thread because Godot's own engine
code does that work — not something that comes for free from being a
singleton.

## Factory contract: References only, never a bare `EsmBase`

The object factory (`object_registry.gd`'s `_construct_*()`/`_resolve_*()`
functions) takes **only** `EsmReference` (or a subclass) as input — never a bare
`EsmBase` directly, even for kinds like `StaticReference` that carry no override
data most of the time. One uniform call signature for every placement kind, and
since `base: EsmBase` is already resolved and sitting on every `Reference` by
the time it reaches the factory (see "What `EsmReference` holds" above), the
factory doesn't even need to call `EsmServer.get_base()` itself — it just reads
`reference.base.model_path`/damage/whatever directly, and never branches on
"was I handed a Base or a Reference this time." Handing the factory a
`StaticReference` whose `emittance_form_id` happens to be unset is simply a
no-op for that one field — cheap, and it keeps every entry point identical
regardless of how rich a given kind's override data is.

## `instance_id`: why it doesn't need to be reissued (unlike the real `RefNum`)

Traced precisely why OpenMW unsets and re-mints a `RefNum` whenever an object is
dropped into a different cell than the one it came from
(`Class::copyToCell()`, `apps/openmw/mwworld/class.cpp:387-395`:
`newPtr.getCellRef().unsetRefNum(); // This RefNum is only valid within the
original cell of the reference`). The reason is structural, not a design
preference worth copying: `RefNum` is `ESM::FormId`
(`components/esm/formid.hpp`), which packs `mContentFile` (which load-order file
authored this) and `mIndex` (this object's index within that file) into one
value. A `RefNum` is a claim of the form "object #N, as declared by file X" — a
claim that stops being true the moment an object leaves the cell that file X
actually placed it in. Reissuing on relocation is the engine refusing to let a
runtime action forge a false authorship claim; it's also the well-documented
source of "dynamic FormID"/orphaned-reference complaints in the modding
community, because that reserved-namespace bookkeeping is fragile.

This project's `instance_id` is already a synthetic string
(`inventory_entry_resource.gd`'s `_new_instance_id()`:
`"runtime:%08X:%d"` / `"authored:%08X:%d"`), decoupled from any load-order
concept. Nothing about it claims authorship by a specific content file, so
nothing forces reissue. **Decision: `instance_id`, once minted, is permanent for
a Reference's entire lifecycle** — spawn, pickup, any number of drops into any
cell, forever. This is a deliberate improvement over the original engine's
behavior, not an attempt to faithfully reproduce a limitation whose only
purpose was solving a problem (load-order-relative addressing) this project
doesn't have.

Caveat for later: this only holds as long as `instance_id` stays a synthetic
token decoupled from raw ESM-authored `REFR` FormIDs. If third-party `.esp`
loading is ever added and something reuses a raw authored FormID as its own
`instance_id` once the object starts diverging, the same fragility comes back.

## Pickup/drop semantics this implies

Traced directly from OpenMW's real pickup path
(`ActionTake::executeImp`, `mwworld/actiontake.cpp:20-41`, and
`ContainerStore::addNewStack`'s own comment, `containerstore.cpp:525-530`): pickup
is copy-then-delete, and the copy explicitly preserves the same `RefNum`/identity.
Applied here: picking up a placed `WeaponReference` means constructing (or
relocating) an `InventoryComponent`/`ActorReference.contents` entry carrying
forward the *same* `instance_id` and the *same* `condition`/override data the
world-placed instance had — not a fresh pristine copy of `WeaponBase`. The
world-side `GamebryoReference` Node is then freed. A degraded gun found on a
table is still degraded once it's in your pocket.

**Stacking rule**, following from the same "sentinel = untouched" pattern:
`mRefNum` is explicitly "currently unused for items in containers" until an item
diverges from pristine (per `CellRef.mRefNum`'s own comment). Two freshly-spawned,
untouched pistols can be one `WeaponReference` with `count = 2` — matching how
`InventoryComponent.add_item()` already stacks by empty `instance_id` today. The
moment one is fired, `condition` diverges, and *that's* the point it must split
off into its own `WeaponReference` with `count = 1` — the original stack keeps
its count and its still-pristine state; the fired one peels off as a newly
distinct instance.

## Save/load

No compatibility with the real game's save format is a goal — freeing this
design from Bethesda's own `RefNum`-reissue machinery (see above), which exists
to solve a load-order problem this project doesn't have. `EsmReference`
subclasses are the natural persisted-data unit: `EsmBase` never needs saving
(always re-resolved from `base_form_id` through the existing cache), so a
`Reference`'s `@export`ed fields (`base_form_id`, `instance_id`, `condition`,
`count`, ...) are the entire save surface.

### Top-level shape

Building on Phase 4's own already-sketched `GameSession`/`SaveState` skeleton
(`README.md`'s "Quest-state decision") rather than inventing parallel
terminology. Naming the two halves explicitly, since this document uses both
and the relationship matters: **`GameSession` is the live, in-memory, currently-
active object** — the thing `EsmServer` holds its nullable reference to (see
"`EsmServer`" above). **`SaveGame` is the on-disk shape a `GameSession` reads
from and writes to** on load/save — not a separate runtime concept, just its
serialized form:

```
SaveGame
├── version: int
├── player: ActorReference          — full snapshot
├── actors: Dictionary[instance_id, ActorReference]   — only actors ever diverged from spawn
├── cells: Dictionary[cell_form_id, CellSaveState]
├── quest_state: QuestStateStore
└── world_state: WorldState
```

### Reconciliation: diff cells against the ESM baseline, snapshot inventories

Cells can hold hundreds of placements, almost none of which a given playthrough
ever touches — saving all of them regardless would be wasteful. On load,
resolve a cell's `REFR` list fresh from the ESM (as already happens today) to
get baseline `Reference`s with deterministic `"authored:<form_id>:<index>"`
instance ids, then apply:

```
CellSaveState
├── removed_instance_ids: PackedStringArray             — authored refs picked up / destroyed
└── changed_references: Dictionary[instance_id, EsmReference]   — diverged, or newly dropped here
```

Drop anything in `removed_instance_ids`; replace baseline instances whose id
appears in `changed_references`; add anything in `changed_references` whose id
wasn't in the baseline at all (a `"runtime:..."` id — something dropped here
that didn't start here). Functionally the same delete/modify/create shape
Bethesda's own format uses, minus the fragile part — no reissue dance needed,
because `instance_id` was already decoupled from load order.

Actor and container inventories (`ActorReference.contents`,
`ContainerReference.contents`) are **full snapshots**, not diffed against their
authored `CNTO` baseline — the same delta logic could apply recursively, but
inventories are small enough that the save-size motivation justifying the extra
complexity for whole cells doesn't carry over. Revisit only if a large
faction/vendor inventory ever makes this a real problem.

### `current_cell_form_id` lives on the shared `EsmReference` base

Not kind-gated the way `XEMI` was — this is placement data, the same category
as `position`/`rotation`/`scale` already on the shared base, just at
cell-granularity. `position` alone is ambiguous without knowing which cell's
coordinate space it's expressed in (interior REFR coordinates are local to the
cell; exterior ones are worldspace-absolute), and any physics-live object —
not just actors — can end up somewhere other than the cell that structurally
owns its save entry (a dropped weapon shoved or blown across a `WastelandNV`
tile boundary is exactly as real a case as a wandering companion). Sentinel
default `0` — "still wherever it was originally placed, nothing to say" — costs
nothing for the overwhelming majority of immobile scenery; only gets written
once something with a live physics body or AI actually crosses a cell boundary.
`cells[cell_form_id]` bucketing itself stays keyed by *origin* cell always —
`current_cell_form_id` is what tells later logic a given entry's data doesn't
match where the object currently sits.

### `CurrentLocationIndex`: a separate, small, hot index — not a scan

`current_cell_form_id` living on every `Reference` doesn't by itself answer
"what's near the player right now" cheaply — that would mean scanning every
saved `Reference` to check one field. Keep the two concerns separate:

```
CurrentLocationIndex: Dictionary[cell_form_id, PackedStringArray]   # cell -> [instance_id, ...]
```

Only needs entries for the divergent subset — anything whose
`current_cell_form_id` was never written stays findable the normal way
(resolve the cell fresh, apply `changed_references`), so this index's size
tracks "how many things are currently physics-drifted or actor-wandered away
from their origin," not total world-object count — small by construction.
Maintained incrementally: whenever code writes a new `current_cell_form_id`
onto a `Reference`, that's the same moment it removes the `instance_id` from
its old bucket and adds it to the new one — one cheap update per divergence
event, never a rebuild. Worth keeping this as its own lightweight artifact
(plain serialized `Dictionary`, not routed through `ResourceSaver` alongside
every full `Reference`) — small enough to stay resident in memory for the
whole play session, so `WorldStreamer` can query it constantly without
touching the much larger main save payload.

### What counts as "changed," and detecting it the Godoty way

A `Reference` needs a `changed_references`/`actors` entry if either: it has a
`"runtime:..."` instance id (it doesn't exist in any ESM baseline at all, so
it's changed by definition, no comparison needed), or — for an `"authored:..."`
id — any of its `@export`ed fields differs from what freshly re-resolving that
same instance id from the ESM/factory would produce right now.

That second case has a genuinely generic, per-class-boilerplate-free way to
check, using Godot's own reflection rather than hand-writing an `is_dirty()`
per subclass: `Object.get_property_list()` (filtered to storage-flagged
properties — the same set `ResourceSaver` would actually persist) plus
`Object.get(name)`, diffed field-by-field against a freshly-built pristine
instance of the same `base_form_id`. Correct automatically for any newly added
field on any subclass, no per-field maintenance, no risk of forgetting to wire
a new field into a hand-written comparison.

The real cost is *when* that comparison runs. Doing a full re-resolve-and-diff
for every currently-loaded `Reference` at save time is bounded (only
currently-streamed cells are live objects at all, not the whole game world),
but still real work. Cheaper alternative if profiling ever calls for it: an
incremental dirty flag, set the moment a mutation happens rather than
discovered later — GDScript's `set(value):` syntax already intercepts *any*
assignment to an `@export`ed property, including from outside the class
(`weapon.condition = x` still runs a custom setter), so `_dirty = true` inside
each mutable field's setter is both cheap and hard to bypass accidentally.
Same escalation shape as the caching section above: **start with the generic
reflective diff, since it's self-maintaining and can't drift out of sync with
new fields; move to per-field dirty flags only for specific classes where
profiling actually shows the reflective pass is too slow**, not as a default.

### Serialization mechanics

`EsmReference.base` was deliberately made a plain, non-`@export`ed `var`
(see "What `EsmReference` holds" above) specifically because it isn't meant
to be persisted — and Godot's `ResourceSaver`/`ResourceLoader` only serialize
`@export`ed properties by default, so a straight `ResourceSaver.save()` on the
whole nested tree already produces the right save shape for free, no
hand-written `serialize_state()`/`restore_state()` walker needed per class the
way `InventoryComponent` currently hand-rolls it. On load, `base` is simply
re-resolved from `base_form_id` through `EsmServer.get_base()` at construction,
same as any other `Reference`.

Two things worth flagging rather than assuming away:

- **Keep `Reference` classes pure data, no side-effecting setters.** Some
  existing Node scripts in this codebase (`NPCActor.equipment_state`'s setter
  calling `_connect_equipment_state_signals()`) do real work on assignment —
  fine for a live scene `Node`, wrong if that pattern leaked into a `Resource`
  Godot's deserializer sets properties on directly while reconstructing a save.
- This is a single-player save read back by its own game, not arbitrary
  untrusted input — Godot `Resource` deserialization isn't hardened against
  maliciously crafted files the way a purpose-built parser would be, which
  matters for multiplayer/user-generated-content scenarios and doesn't really
  matter here. Worth knowing as a general caution, not worth designing around
  for this project.

### Still open

- Save versioning/migration across game updates (a field gets added to
  `WeaponReference` after players already have saves).
- Whether `world_state` needs more structure than a flat flag bag yet.
- Binary `.res` vs. text `.tres` for the main save payload — note this can
  legitimately differ from `CurrentLocationIndex`'s own format, since one wants
  to be fast-to-load-and-keep-resident and the other wants to be compact.

## Where this leaves the existing Node-side architecture

`GamebryoReference` (`gamebryo_reference.gd`, a `Node3D`) is not being replaced
by `EsmReference` — they're siblings, not the same thing renamed. The open
question this document deliberately leaves open: does `GamebryoReference` hold
its matching `EsmReference` as a field (Node wraps Resource, same relationship
`NPCActor` already has with `npc_record: NpcRecord`), and does
`object_registry.gd`'s `Dictionary`-based `resolve_placement()` output become the
`EsmReference` itself instead of a loosely-typed `Dictionary` (which would also
resolve the untyped-string-key round-trip between `_resolve_*()` and
`_construct_*()` that exists today)? Both look like the right direction given
everything above, but wiring them up is conversion-plan work, not architecture
work — deliberately left for later.

## Explicitly deferred

- Full rename/conversion list for every existing `EsmRecordResource` subclass.
- Whether `object_registry.gd`'s Dictionary intermediate becomes a typed
  `EsmReference` outright, or gets ported incrementally.
- Remaining REFR-capable kinds not yet surveyed against the promotion rule
  (`LIGH` itself — a placed light may need its own on/off instance state,
  distinct from the `XEMI` tint other kinds borrow from it; `ACTI`, `FURN`,
  `TACT`, `TERM`, `SCOL`).
- `ItemNode.pickup()`'s current untyped `Dictionary` return
  (`item_node.gd:15-18`) becoming a real `EsmReference` handoff into
  `InventoryComponent`/`ActorReference.contents`.
- Save/load's own open items are listed under "Still open" at the end of that
  section above, not repeated here.
