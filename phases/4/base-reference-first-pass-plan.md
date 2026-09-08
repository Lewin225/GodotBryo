# EsmServer + Base/Reference resource types + GodotBryo browser (isolated first pass)

Parent: [Phase 4](README.md) · Implements a scoped first slice of
[base-reference-architecture.md](base-reference-architecture.md).

**Approved, not yet started.** This is the plan as agreed; implementation begins
in a separate session/pass.

## Deliverables

- `project/esm_server.gd`, registered as the `EsmServer` autoload.
- New typed resources under `project/GodotBryo/Types/Resource/`.
- One new native `find_cell_containing_ref()` binding.
- The separate `project/addons/godotbryo_browser/` editor addon.
- Automated real-data coverage for base lookup, reference lookup, exhaustive
  reference search, caching, and failure cases.

## Non-goals

- No conversion of `object_registry.gd`, `cell_loader.gd`,
  `world_streamer.gd`, or `esm_resource_factory.gd`.
- No removal, adaptation, or inheritance relationship between the new resource
  family and the legacy `EsmRecordResource` family.
- No `GameSession`, save-state integration, runtime-created reference
  resolution, load-order support, or worker-thread use.
- No new format coverage beyond the Base type scope below.

## Context

`base-reference-architecture.md` is a full architecture for splitting ESM data
into `EsmBase` (immutable, cacheable, one per FormID) and `EsmReference`
(mutable, per-instance, one per placement) resource families, served through a
global `EsmServer` singleton with five entry points (`get_base`, `get_reference`,
`get_references_in_cell`, `get_base_type`, `get_reference_type`). That document
deliberately deferred the *conversion* of the existing pipeline
(`object_registry.gd`, `cell_loader.gd`, `esm_resource_factory.gd`) to this new
shape — too risky to do in one pass.

This plan is explicitly **not** that conversion. It's a scoped, isolated first
step: build `EsmServer` and the new resource types standalone, wired to nothing
else in the existing pipeline, plus a new in-editor browser so the types are
inspectable and provable before anything depends on them. The existing gameplay
pipeline (`object_registry.gd`, `cell_loader.gd`, `world_streamer.gd`) is
untouched by this work. One deliberate, explicit exception to "no new native
code": `get_reference()` needs one small native binding exposing an
already-fully-implemented C++ function — see Component 1 below — a
correctness requirement, not scope creep.

The repository previously contained an `esm_browser` addon and generated
`project/esm_mount/` `.nvrecord` paths for the old `EsmRecordResource` family.
That mount workflow has been removed from this branch; the new browser and
`esm://` loader are the sole editor-facing ESM resource workflow.

## Decisions

- **New, separate addon** (`project/addons/godotbryo_browser/`), not a
  modification of the existing `esm_browser` addon — keeps this pass fully
  isolated, zero risk to the currently-working old-family browser.
- **Base type scope**: create one `*Base` for each type in the table below.
  This covers existing pipeline support plus the referenced-only types. Types
  outside the table remain out of scope. Thin stubs may contain only shared
  identity fields and `model_path`; `WeaponBase`, `ArmorBase`, and `DoorBase`
  receive their already-verified fields. Unverified fields must be marked for
  later completion, not guessed.

  | ESM tags | Base classes | Completeness |
  |---|---|---|
  | `NPC_`, `RACE`, `HAIR`, `EYES`, `CLAS`, `PACK`, `ARMO`, `ARMA`, `FLST`, `WEAP`, `ALCH`, `LVLI`, `AMMO`, `BOOK`, `CCRD`, `CMNY`, `KEYM`, `MISC`, `DOOR`, `SCOL`, `LIGH`, `CONT`, `ACTI`, `FURN`, `TACT`, `MSTT`, `TERM`, `STAT`, `CREA` | One corresponding `*Base` class per tag | Fully populated only where fields are verified; otherwise a documented stub |

  Types not covered here include `TREE`, `SOUN`, `GRAS`, `ASPC`, `IDLM`,
  `NOTE`, `PWAT`, `TXST`, `IMOD`, `LVLN`, and `LVLC`.
- **Reference type scope**: every placeable type in the Base table gets its own
  Reference subclass. The six referenced-only types (`RACE`, `HAIR`, `EYES`,
  `CLAS`, `PACK`, `FLST`) get no Reference class. No placeable resolves to a
  bare `EsmReference`.

  | Reference classes with verified fields | Reference stub classes |
  |---|---|
  | `WeaponReference`, `ArmorReference`, `DoorReference`, `ContainerReference`, `ActorReference`, `CreatureReference`, `StaticReference`, `MovableStaticReference` | `ActivatorReference`, `TerminalReference`, `StaticCollectionReference`, `LightReference`, `FurnitureReference`, `TalkingActivatorReference`, `ArmorAddonReference`, `AlchemyReference`, `LeveledItemReference`, `AmmoReference`, `BookReference`, `CaravanCardReference`, `CaravanMoneyReference`, `KeyReference`, `MiscReference` |

  `ActorReference` represents `ACHR` → `NpcBase`; `CreatureReference`
  represents `ACRE` → `CreatureBase`. Keep them distinct. `CreatureReference`
  additionally carries the verified `XOWN`/`XRNK` fields. Final class names
  use the descriptive record names: `StaticCollectionBase`/
  `StaticCollectionReference` for `SCOL`, `CaravanCardBase`/
  `CaravanCardReference` for `CCRD`, and `CaravanMoneyBase`/
  `CaravanMoneyReference` for `CMNY`.
- **Browser UX**: Base records are the default, filterable-by-type list (same
  UI shape as the existing `esm_browser.gd`: type `OptionButton`, text
  `LineEdit` filter, `ItemList`). Right-clicking a Base entry opens a context
  menu with **"Find References"**, which finds every placement targeting
  that Base's `form_id` and shows them in the same list (with a way back).

  **This is a query over records, not over cells — cells never belong in the
  design at all.** "Find References" means "does this `REFR`/`ACHR`/`ACRE`'s
  `NAME` match the target," which has nothing to do with which cell (if any)
  a candidate happens to sit in. Earlier drafts of this plan built it around
  enumerating cells and scanning each one's contents, which was solving the
  wrong problem — cell iteration belongs to `get_references_in_cell()`
  (`WorldStreamer`/`CellLoader`'s actual need, answering "what's in *this*
  cell"), not to this feature. Persistent refs specifically only became a
  problem because of that wrong framing: `get_references_in_cell(cell_form_id)`
  correctly does **not** include them — they structurally belong to the
  worldspace's own separate persistent cell, never the geographic cell
  passed in, so they're out of scope for it by definition, not a gap
  (matching what `cell_loader.gd:201` already does today: it unions
  `get_cell_references()` and `get_persistent_refs_for_cell()` itself, at
  the call site, rather than either one silently including the other's
  data). None of that applies here at all.

  Correct design: filter `get_record_index()` (`esm_reader_gd.cpp:596-609`
  — already bound, already returns every record's `form_id`+`record_type`
  in one bulk call, unconditionally, regardless of `EDID`) for
  `record_type in ["REFR", "ACHR", "ACRE"]`, then check each candidate's own
  `NAME` subrecord against the target `base_form_id` (via the already-bound
  `get_record_data()`). This naturally includes persistent refs for free —
  they're ordinary `REFR`/`ACHR`/`ACRE` records sitting in the same index as
  everything else, nothing special to handle. `find_cell_containing_ref()`
  is still useful, but only *after* a match, to show/navigate to where a
  result actually is — it never drives the search itself.

  This still needs no new native code beyond the one `find_cell_containing_ref`
  binding already scoped for `get_reference()` above. Slower than a native
  index, acceptable for an on-demand editor action; note in a status label
  while running, matching the existing addon's `status: Label` pattern.
- **Dock placement**: bottom-middle mounted (`DOCK_SLOT_BOTTOM`), not
  left-upper like the existing addon's dock — keeps the two addons visually
  distinct too.
- **Naming**: no actual collisions exist today (confirmed — no
  `EsmBase`/`EsmReference`/`WeaponBase`/etc. files anywhere in the project
  currently). If one is ever hit, the agreed fallback is a `_new` suffix (e.g.
  `WeaponReference_new`) — documented as a stopgap for this experimental
  phase, not a permanent convention.

## Components to build

### 1. `EsmServer` — new global autoload

- New file at `project/esm_server.gd` (flat at project root, matching the
  existing autoload convention — `game_data_settings.gd`,
  `godot_bryo_settings.gd` both sit there ungrouped, not nested in a folder),
  registered in `project.godot`'s `[autoload]` section alongside
  `GameDataSettings`/`GodotBryoSettings`.
- Owns one internal `EsmReader`, opened via the same
  `GameDataConfigScript`/`GameDataSettings` path-resolution pattern the
  existing `esm_browser` addon already uses (`esm_browser.gd:52-58`) — no new
  config mechanism invented.
- Internal `_cache: Dictionary` keyed by plain `form_id` (not the old composite
  `"type:form_id"` key — no longer needed once type is read from the data
  itself rather than trusted from the caller, per the architecture doc).
- Internal `{type_tag: Callable}` (Base construction) and `{type_tag: Script}`
  (type-only lookups) dispatch tables, built once, replacing what would
  otherwise be per-type `if/elif` chains.
- Five methods per the doc: `get_base(form_id) -> EsmBase`,
  `get_reference(instance_id: String) -> EsmReference`,
  `get_references_in_cell(cell_form_id) -> Array[EsmReference]`,
  `get_base_type(form_id) -> Script`, `get_reference_type(refr_form_id) -> Script`
  (two-hop: dereference `NAME` first, per the doc's correction).
- **`get_reference()`'s authored-id resolution needs one new native binding —
  a real, scoped exception to "no new native code," not a gap.**
  `EsmFile::find_cell_containing_ref(refr_form_id)` already exists, fully
  implemented (`esm_file.cpp:212-227`) and already used in production for
  door-destination resolution (`resolve_refr_xtel`) — it just isn't exposed
  to GDScript yet (no binding anywhere in `esm_reader_gd.cpp`). Its C++
  return type, `std::optional<RecordInfo>`, can never cross the GDScript
  boundary directly — `RecordInfo` isn't a `Variant`, and there's no binding
  that exposes a raw file offset to GDScript either, nor should there be.
  The new `EsmReader`-level wrapper must follow the exact shape the
  near-identical `find_cell_by_form_id` already establishes
  (`esm_reader_gd.cpp:377-390`): unwrap the `optional` into a plain
  `Dictionary`, `{"cell_form_id": int}` on success, `{}` otherwise — nothing
  more. That binding's whole job is "does it exist, which cell owns it" —
  the `cell_form_id` it returns exists to *scope* the next step, not to be
  discarded after an existence check (an earlier version of this plan called
  it, checked for emptiness, then never actually used the value — a real
  gap, caught and fixed here). Getting the placement's actual data reuses
  `get_cell_references(cell_form_id)`/`get_cell_actors(cell_form_id)` —
  both already bound, both already return fully-parsed placement data
  (position/rotation/scale/`base_form_id`), scoped to the one cell just
  identified — **not** `get_record_data()` plus hand-parsed bytes:
  `get_record_data()` only returns raw subrecord bytes, and decoding
  `DATA`'s position/rotation/scale out of that would mean reimplementing
  parsing logic that already exists natively inside
  `get_cell_references()`/`get_cell_actors()`, for no reason. Canonical
  `instance_id` format for authored placements: `"authored:%08X" %
  refr_form_id` (the placement's own `form_id`, not `base_form_id`, no
  list-index — deliberately different from `InventoryEntryResource`'s
  `"authored:%08X:%d"`, since a `CNTO` entry has no independent `form_id` of
  its own and needs an index, while a `REFR`/`ACHR`/`ACRE` already has a
  genuinely unique one). Resolution checks `_game_session` first, ESM only as
  fallback (this pass: always null, so always falls through) — parse the hex
  suffix; `find_cell_containing_ref()` (one native call, the `Dictionary`
  shape above, empty means not found, stop); `get_cell_references()`/
  `get_cell_actors()` on that one cell, filtered for the matching `form_id`;
  the matched entry's `base_form_id` feeds the already-existing
  `get_base_type()` to pick the concrete `Reference` subclass. `"runtime:..."`
  ids have no backing record and nothing to resolve from without an active
  `GameSession` — always `null` in this pass, explicitly, not an
  accidentally-undefined case. Malformed/not-found ids: `null`, matching
  `get_base()`'s existing convention. Full detail in the architecture doc's
  "Resolving `instance_id`" section.
- Internal nullable `_game_session` field, present in the code structure but
  always `null` in this pass (no `GameSession` class exists yet) —
  `get_reference()`/`get_references_in_cell()` always fall through to pure ESM
  baseline resolution. `get_base()` never touches it.
- **No `Mutex` this pass — main-thread-only, explicitly, not a silent gap.**
  A cache-only `Mutex` was considered and rejected: it protects `EsmServer`'s
  own `Dictionary` but not the native `EsmReader`/`EsmFile` it calls into on
  every cache miss, which is itself documented as not thread-safe
  (`esm_file.h:18`: *"Not thread-safe (single `FILE*` with seek+read)"*) and
  carries its own unsynchronized internal caches
  (`form_id_index_`/`item_candidates_cache_`/`cell_candidates_cache_`,
  `esm_file.h:313-320`). A partial mutex here would look like real safety
  without providing it. This pass has no caller that runs off the main
  thread at all — nothing built here is wired to `WorkerThreadPool` — so
  real concurrency support is correctly out of scope, not a known-gap to
  retrofit blindly later. Whoever adds a threaded caller should reach for
  the architecture doc's "Thread-safety" section first — the real fix isn't
  a GDScript-side mutex at all, it's `EsmFile` itself: replacing `fseek`+
  `fread` (`esm_file.cpp:115-123`, the actual shared-cursor race) with
  `pread` or an `mmap`-based read, plus building `form_id_index_`/
  `item_candidates_cache_`/`cell_candidates_cache_` eagerly in `open()`
  instead of lazily — genuinely thread-safe with zero runtime locking
  overhead, rather than a mutex that only ever serializes access. A mutex
  spanning every native call, or a separate `EsmReader` per worker context,
  are the fallback options if that native work stays out of scope longer
  than expected. Whichever shape is chosen, it must not hold any lock across
  `get_base()`'s nested builder call — building `NpcBase` needs to resolve
  `RaceBase`/`HairBase`/`EyesBase` internally, so `get_base()` can recurse
  into itself, and a non-recursive lock held across that whole call would
  deadlock the first time nested resolution actually runs.

### 2. Resource types — `project/GodotBryo/Types/Resource/`

- Add `esm_base.gd` (`EsmBase`) and `esm_reference.gd` (`EsmReference`).

  | Resource | Required fields |
  |---|---|
  | `EsmBase` | `form_id`, `editor_id`, `record_type`, `source_uri`, raw subrecords |
  | `EsmReference` | `base_form_id`, resolved `base`, `instance_id`, transform, `current_cell_form_id` |

- Add one `*Base` and one `*Reference` file for every type in the
  tables above. The six referenced-only types get Base classes only.
- Port only already-verified fields from the current esm parser/dict generator and/or legacy resources. New types may
  be documented stubs with shared identity fields and `model_path` where
  applicable. The new and legacy resource families remain independent during
  this pass.
- Fully populate `WeaponBase`, `ArmorBase`, `DoorBase`, and the eight Reference
  classes listed as verified. Keep `ActorReference` and `CreatureReference`
  separate; the latter adds verified `owner_form_id`/`faction_rank` fields.
- Every placeable must resolve to its dedicated Reference class. No placeable
  may instantiate bare `EsmReference`.

### 3. `project/addons/godotbryo_browser/` — new editor addon

- `plugin.cfg`, `plugin.gd` (`EditorPlugin`, registers the dock at
  `DOCK_SLOT_BOTTOM`), `browser_dock.gd`, and a `ResourceFormatLoader`
  subclass for the virtual `esm://` scheme resolving through
  `EsmServer.get_base()`/`get_reference()`
  rather than constructing its own factory/reader per instance.
- "Find References" implemented as described above — `get_record_index()`
  filtered for `record_type in ["REFR", "ACHR", "ACRE"]`, each candidate's
  `NAME` checked via `get_record_data()` against the target `base_form_id`.
  No cell iteration, no `get_all_cell_candidates()`, no persistent-refs
  handling — none of that applies to this feature.

## Acceptance criteria

- [ ] The new bottom-mounted dock is the sole ESM browser/editor integration.
- [ ] The Base list populates and the type and text filters work.
- [ ] FormID `0x000E3778` opens a `WeaponBase` in the Inspector with real
      model/damage data; repeated lookup returns the same Resource instance.
- [ ] “Find References” searches `REFR`, `ACHR`, and `ACRE` records from the
      complete record index, including persistent-cell records.
- [ ] A known Doc Mitchell `NPC_` placement is found through the `ACHR` path.
- [ ] An authored result uses `authored:%08X` identity and resolves through
      `get_reference()` using one owning-cell lookup, not a full scan.
- [ ] Made-up `runtime:...` IDs and malformed/not-found IDs return `null`.
- [ ] The legacy `esm_browser`, `.nvrecord` loader, and `project/esm_mount/`
      workflow are absent.
- [ ] Only the new native `find_cell_containing_ref` API is added; the legacy
      pipeline files remain unchanged.
