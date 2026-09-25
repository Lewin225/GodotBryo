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

The record classes it instantiates live in `GodotBryo/Types/Resource/` and are
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
EsmServer.get_references_in_cell(cell_form_id) -> Array[EsmReference]
EsmServer.get_all_placed_actor_references() -> Array[ActorReference]
EsmServer.get_all_xtel_door_references() -> Array[DoorReference]
EsmServer.get_space_form_id_for_cell(cell_form_id) -> int
EsmServer.get_space_form_id_for_reference(instance_id) -> int
EsmServer.get_exterior_cell_form_id(worldspace_form_id, coord: Vector2i) -> int
EsmServer.cell_at(space_form_id, position: Vector3) -> int
EsmServer.exterior_grid_coord(position: Vector3) -> Vector2i   # static
EsmServer.rehydrate(resource: EsmBase) -> bool
```

Signals `esm_ready`, `failed(message)` and
`reference_cell_changed(reference, old_cell_form_id, new_cell_form_id)`. `state` is `"loading"` until the
background parse completes — the reader opens on its own `Thread` in `_ready()`,
so nothing blocks startup.

**Base versus Reference.** An `EsmBase` is the authored record: what a Nuka-Cola
*is*. An `EsmReference` is one placed or carried instance of it. Two dispatch
tables map a record type to each — `TYPE_TO_BASE` and `TYPE_TO_REFERENCE`,
resolved out of `GodotBryo/Types/Resource/`. A type present in one and absent
from the other is deliberate: not every record type can be placed in a cell.

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

**Doors.** A `DoorReference` with XTEL has `teleport: DoorTeleportLink`: the
destination door's instance id, the landing position and rotation, and the
no-alarm flag. The link resolves its destination door and space through this
server on demand and never stores the door, since most XTEL doors lead to each
other. A door with XLOC is locked at any level; level 0 is Very Easy.

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
