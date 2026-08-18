class_name DoorNode
extends GamebryoVisual

## DOOR. phases/2/07-runtime-cell-loader.md: teleport destination (if any) is
## resolved once and cached here at build time, not looked up lazily on
## interaction — the ESM-side lookup (EsmReader.get_door_destination()) is
## cheap (a byte-range-pruned walk, not a file scan), but resolving once here
## means a door with a missing/broken destination fails visibly when the
## cell loads, not silently the first time a player tries to use it, and
## avoids repeating an identical lookup on every use.

## True if this door teleports (has an XTEL) rather than just swinging open.
## Most doors do; some (e.g. a plain room door) don't — that's a normal,
## valid case, not a missing-data error.
var has_destination: bool = false
var dest_cell_form_id: int = 0
var dest_position: Vector3 = Vector3.ZERO
var dest_rotation: Vector3 = Vector3.ZERO

## Called by GamebryoObjectRegistry._build_door() right after this node's
## own form_id (GamebryoReference.form_id, this door's own REFR) is set —
## see object_registry.gd.
func resolve_destination(esm: EsmReader) -> void:
	var dest: Dictionary = esm.get_door_destination(form_id)
	has_destination = not dest.is_empty()
	if has_destination:
		dest_cell_form_id = int(dest["dest_cell_form_id"])
		dest_position = dest["dest_position"]
		dest_rotation = dest["dest_rotation"]
