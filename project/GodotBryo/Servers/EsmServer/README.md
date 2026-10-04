# EsmServer

Reads the game's ESM/ESP records and hands back typed Godot `Resource`s.
Autoloaded singleton.

Every other system asks this for record data; nothing else parses ESM bytes.

---

## This folder is never modified as part of other work

**Changes to EsmServer are their own task, never a step inside another one.**
Every record type in the game funnels through the two dispatch tables below, and
a caller that needs one more field is the worst position from which to judge
what a change does to the other 50. The failure is not visible from inside the
task that caused it.

If work elsewhere needs a record field EsmServer does not expose:

1. Stop. Do not patch this folder in passing.
2. Say what is missing and what it is needed for.
3. Land it as its own change, with a test in `project/tests/`.

The record classes it instantiates live in `GodotBryo/Types/Resource/` (`Base/`, `Reference/`,
`Collection/`) and are
data, not behaviour. Adding a field there is part of the same task as teaching
EsmServer to populate it — the two are one change, not two.

---

## Contract

```gdscript
EsmServer.is_ready() -> bool                         # parse finished
EsmServer.get_record_index() -> Array
EsmServer.get_base(form_id) -> EsmBase               # the authored record
EsmServer.get_base_from_uri(uri) -> EsmBase
EsmServer.get_base_type(form_id) -> Script
EsmServer.get_reference(instance_id) -> EsmReference # a placed instance
EsmServer.get_reference_type(refr_form_id) -> Script
EsmServer.create_reference_for_base(base_form_id) -> EsmReference
EsmServer.create_inventory_item_reference(base_form_id, instance_id := "") -> EsmReference
EsmServer.get_references_in_cell(cell_form_id) -> Array[EsmReference]   # currently in it
EsmServer.is_relocated(reference) -> bool
EsmServer.get_all_placed_actor_references() -> Array[ActorReference]   # ACHR only, for now
EsmServer.get_all_xtel_door_references() -> Array[DoorReference]
EsmServer.get_space_form_id_for_cell(cell_form_id) -> int
EsmServer.get_space_form_id_for_reference(instance_id) -> int
EsmServer.get_filing_cell_form_id(refr_form_id) -> int
EsmServer.find_reference_by_editor_id(editor_id) -> EsmReference
EsmServer.get_player_reference() -> NpcReference                # also get_reference("player")
EsmServer.find_quest_by_editor_id(editor_id) -> EsmBase
EsmServer.find_global_by_editor_id(editor_id) -> Dictionary     # GLOB type and authored value
EsmServer.find_base_by_editor_id(editor_id) -> EsmBase          # any non-placement record
EsmServer.find_form_id_by_editor_id(editor_id) -> int           # indexed; CELL, WRLD and other non-placements
EsmServer.add_inventory_items(owner, item_base, count) -> int   # typed items; leveled lists resolve
EsmServer.get_game_setting(editor_id) -> Variant                # GMST value; null when the ESM has none
EsmServer.get_exterior_cell_form_id(worldspace_form_id, coord: Vector2i) -> int
EsmServer.cell_at(space_form_id, position: Vector3) -> int
EsmServer.exterior_grid_coord(position: Vector3) -> Vector2i   # static
EsmServer.rehydrate(resource: EsmBase) -> bool
```

Signals `esm_ready`, `failed(message)` and
`reference_cell_changed(reference, old_cell_form_id, new_cell_form_id)`. `state` is `"loading"` until the
background parse completes — the reader opens on its own `Thread` in `_ready()`,
so nothing blocks startup.

**Actor records.** NPC_ and CREA are `NpcBase` and `CreatureBase`, both extending
`ActorBase`, which holds the 20 subrecords they share with the same meaning (ACBS, AIDT, TPLT,
SNAM, VTCK, PKID, CNTO + COED as `items`, DEST as `destructible`, ...). Each subclass reads its
own DATA, RNAM, PNAM, CNAM, NAM5 and LNAM, and names the ACBS flags its own way.
`ActorBase.template_source(record, flag)` follows TPLT while the flag says a part comes from the
template. Placed ACHR and ACRE are `NpcReference` and `CreatureReference`, both extending
`ActorReference`, which reads the placement subrecords they share (XLCM, XEZN, XMRC, ragdoll
data, XATO, XAPD, XIBS); `CreatureReference` adds XOWN. Every actor and creature reference is
created with its `ActorValues`, which derive
from the record supplying its stats, and its inventory, seeded from `items` (the template's with
the Inventory flag) with each COED's owner and condition. `get_game_setting()` reads a GMST by
editor ID on first use; FalloutNV.esm omits settings left at their engine default, which
`ActorValue.DEFAULT_SETTINGS` supplies.

**Every FormID field resolves.** A field holding a FormID has its resolved resource beside it
(`race_form_id`, `race`), built by `get_base()` and typed from `TYPE_TO_BASE`. A field naming a
placed reference keeps only its FormID, with a method that builds the reference on demand
(`ActorReference.get_merchant_container()`, `PackageBase.get_location_reference(n)`), since
placed references are world state rather than record data. SCRI resolves to
`script_record` (a `ScriptBase`) on every record. The record types actor records point at have
Base classes even where nothing reads their subrecords yet (VTYP, GLOB, LVLN, LVLC, HDPT, IPDS,
SOUN, FACT, ENCH, SPEL, CSTY, SCPT, NOTE, EXPL, DEBR, ECZN, IDLE); each class's doc comment lists
the subrecords it does not read. FLST is `FormListBase`, a general list whose `entries` resolve to
each record's own Base.

**Base versus Reference.** An `EsmBase` is the authored record: what a Nuka-Cola
*is*. An `EsmReference` is one placed or carried instance of it. Two dispatch
tables map a record type to each — `TYPE_TO_BASE` and `TYPE_TO_REFERENCE`,
resolved out of `GodotBryo/Types/Resource/Base/` and `Reference/`. A type present in one and absent
from the other is deliberate: not every record type can be placed in a cell.

**Dirty.** Both extend `EsmResource`. A clean one mirrors the ESM, and a base is
rehydrated from its record (`source_uri`). One changed at runtime is marked dirty
(`mark_dirty()`): it is rehydrated from save data instead, never again from the ESM, and
`EsmBase._auto_rehydrate()` skips it. The name menu (the player NPC_'s FULL) and the race
menu and `SexChange` (its ACBS Female flag) mark the player's NPC_ dirty. Saving and
loading dirty resources is not built yet; references are not rehydrated from the ESM yet.

**Where a reference is.** Every `EsmReference` has a space (its WRLD when
exterior, its CELL when interior), a position (metres, Gamebryo Z-up axes) and
a cell. Assigning `position` or `current_space_form_id`, or calling
`set_location()`, recomputes the cell through `cell_at()` and emits
`reference_cell_changed` when it changes. `cell_at()`,
`get_exterior_cell_form_id()` and `get_space_form_id_for_cell()` read an
in-memory index of every worldspace's grid and persistent CELLs, built once on
the load thread, and never touch the ESM file. Exterior references, including
those filed in a worldspace's persistent CELL, get the grid CELL under their
position.

**Listings follow references.** `get_references_in_cell()` returns the references
currently in the CELL: those filed in it that have not moved to another CELL, plus those
that have moved in. A reference whose cell has changed since it was built is relocated
and is listed only under its current CELL; `get_persistent_references_for_worldspace()`
leaves it out.

**Finding a reference.** Every placed REFR/ACHR/ACRE's filing CELL and every
placed reference's editor ID are indexed on the load thread (native
`EsmReader.get_placed_reference_cells()` and the record index).
`get_reference("authored:%08X")` builds a reference from its own record
(`EsmReader.get_reference_placement()`) without reading the rest of its CELL.
`find_reference_by_editor_id()` is case-insensitive and returns the same cached
instance.

**Quests.** QUST records are `QuestBase`: DATA flags, priority, script delay, stages
with their log entries and result scripts, and objectives. Stages come before the first
QOBJ; from it on, each QOBJ opens a `QuestObjectiveCollection` with its NNAM text, each QSTA a
`QuestObjectiveTargetCollection` (reference FormID, flags byte) and each CTDA counts toward the
current target. `native/tools/quest_objective_census.cpp` is the census this layout is
checked against. Quest runtime state is `QuestServer`'s.

**Doors.** A `DoorReference` with XTEL has `has_teleport`, the destination door's FormID, the
landing position and rotation, and the no-alarm flag. `get_teleport_destination()` and
`get_teleport_destination_space_form_id()` resolve the destination door and its space through
this server on demand; the door is never stored, since most XTEL doors lead to each other. A door with XLOC is locked at any level; level 0 is Very Easy.

**Resources, not dictionaries.** The return is a typed `Resource` with real
properties, inspectable in the editor and serialisable. `rehydrate()` refills
one whose fields were dropped, for a resource loaded from disk rather than
built from the ESM.

**Turning a reference into a node is not this server's job.** That belongs to
`GodotBryo/Pipeline/esm_reference_physicaliser.gd`, which composes this server
with the mesh and texture path.

---

## Tests

`project/tests/test_esm_server.gd` — runs against the real shipped ESM, not
fixtures.

```
cd project
../tools/Godot_v4.7.1-stable_linux.x86_64 --headless --path . tests/test_esm_server.tscn
```
