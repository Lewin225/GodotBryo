@tool
class_name EsmReference
extends Resource

## Emitted when current_cell_form_id changes because space or position changed.
## EsmServer.reference_cell_changed carries the same change for every reference.
signal cell_changed(old_cell_form_id: int, new_cell_form_id: int)
## Emitted when ScriptServer applies a move of this reference (a teleport, as
## opposed to movement synced from a physics body).
signal teleported(old_space_form_id: int, new_space_form_id: int)

## Runtime-resolved Base resource. It is visible for inspection but deliberately
## excluded from scene/resource storage; base_form_id is the persisted identity.
## Resolved base record for this placed REFR.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EsmBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var base: EsmBase
## REFR NAME base record FormID; persisted identity for the link.
@export var base_form_id: int = 0
## Stable authored or runtime instance identifier.
@export var instance_id: String = ""
## Space containing this reference: the WRLD for an exterior position, the
## CELL itself for an interior one. 0 when the reference is not placed.
@export var current_space_form_id: int = 0:
	set(value):
		current_space_form_id = value
		_refresh_cell()
## REFR DATA position: metres, Gamebryo Z-up axes.
@export var position: Vector3 = Vector3.ZERO:
	set(value):
		position = value
		_refresh_cell()
## REFR DATA rotation in engine coordinates.
@export var rotation: Vector3 = Vector3.ZERO
## REFR XSCL scale value.
@export var scale: float = 1.0
## Raw REFR "Visible When Distant" flag. It is authored placement data, not a
## request to load the companion model: WorldStreamer owns that spatial policy.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var visible_when_distant: bool = false
## Raw presence of the persistent skyline stand-in subrecords XSRF/XSRD. Their
## byte meaning is still undocumented; the confirmed observation is enough to
## select the separate begin-only visibility policy in EsmNode.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var has_xsrf_or_xsrd: bool = false
## CELL containing this reference, derived from current_space_form_id and
## position by EsmServer.cell_at(). Written only by _refresh_cell().
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_DEFAULT | PROPERTY_USAGE_READ_ONLY) var current_cell_form_id: int = 0

## This reference's object script state, created by ScriptServer the first
## time the script runs or a variable is written. Null when the base has no
## script or it has not run yet.
@export var script_instance: ScriptInstance

## The actor using this reference, for references used by one actor at a
## time (terminals, containers, a door being lockpicked). Set only by
## ScriptServer.begin_use / end_use. Runtime state, not saved.
var used_by: ActorReference = null

var _cell_refresh_suspended := false
static var _esm_server: Node

## Sets space and position together, refreshing the cell once. With `notify`
## false the cell is updated without emitting cell_changed or
## EsmServer.reference_cell_changed, for a reference being constructed.
func set_location(space_form_id: int, new_position: Vector3, notify := true) -> void:
	_cell_refresh_suspended = true
	current_space_form_id = space_form_id
	position = new_position
	_cell_refresh_suspended = false
	_refresh_cell(notify)

## Recomputes current_cell_form_id. Does nothing for an unplaced reference
## (space 0) or before EsmServer is ready, as while a resource is being loaded.
func _refresh_cell(notify := true) -> void:
	if _cell_refresh_suspended or current_space_form_id == 0:
		return
	var server := get_esm_server()
	if server == null or not server.is_ready():
		return
	var cell: int = server.cell_at(current_space_form_id, position)
	if cell == current_cell_form_id:
		return
	var old_cell := current_cell_form_id
	current_cell_form_id = cell
	if notify:
		cell_changed.emit(old_cell, cell)
		server.reference_cell_changed.emit(self, old_cell, cell)

## The EsmServer autoload, or null where it does not exist (the editor).
static func get_esm_server() -> Node:
	if is_instance_valid(_esm_server):
		return _esm_server
	var tree := Engine.get_main_loop() as SceneTree
	_esm_server = tree.root.get_node_or_null("EsmServer") if tree != null else null
	return _esm_server

## This reference's actor values, or null when it is not an actor.
func get_actor_values() -> ActorValues:
	return null

## Built-in activation of this reference: its base type's activate(). The
## dispatch point for ScriptServer; a reference type may override it.
func default_activate(activator: EsmReference) -> void:
	if base != null:
		base.activate(self, activator)
