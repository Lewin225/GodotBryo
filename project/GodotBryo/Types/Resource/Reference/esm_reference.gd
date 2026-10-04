@tool
class_name EsmReference
extends EsmResource

## XPRM primitive types (xEdit's enum).
enum PrimitiveType { NONE, BOX, SPHERE, PORTAL_BOX }

## Emitted when current_cell_form_id changes because space or position changed.
## EsmServer.reference_cell_changed carries the same change for every reference.
signal cell_changed(old_cell_form_id: int, new_cell_form_id: int)
## Emitted when ScriptServer applies a move of this reference (a teleport, as
## opposed to movement synced from a physics body).
@warning_ignore("unused_signal")
signal teleported(old_space_form_id: int, new_space_form_id: int)
## Emitted when `disabled` changes. A reference with an enable parent follows
## its parent's state without emitting; listen on the parent chain
## (get_enable_parent()) for that.
signal enable_state_changed
## Emitted when swap_texture() changes a block's texture.
signal texture_swapped(block_name: String)

## XESP flags (xEdit's names).
const ENABLE_PARENT_OPPOSITE := 0x01
const ENABLE_PARENT_POP_IN := 0x02

## NAME's base record, resolved. Set by EsmServer; used for everything the
## base defines (model, scripts, activation). Visible for inspection but not
## saved; base_form_id is the persisted identity.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EsmBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var base: EsmBase
## NAME: the base record's FormID. Read; the persisted link to `base`.
@export var base_form_id: int = 0
## Not an ESM field: the reference's identity in EsmServer's index.
## `authored:<FormID>` for a placed REFR/ACHR/ACRE (its record header FormID),
## `player`, `base:<FormID>` for one created from a base, `inventory:...` for
## a carried item. Set; used by get_reference(), saves and the debug tools.
@export var instance_id: String = ""
## Not an ESM field: the space containing this reference, the WRLD for an
## exterior position or the CELL for an interior one, from the CELL that files
## the placement; 0 when not placed. Set; used by the streamers and
## transitions, and with `position` to derive the cell.
@export var current_space_form_id: int = 0:
	set(value):
		current_space_form_id = value
		_refresh_cell()
## DATA position, converted to metres, Gamebryo Z-up axes. Read; used for
## placement and to derive the cell. Movement writes it at runtime.
@export var position: Vector3 = Vector3.ZERO:
	set(value):
		position = value
		_refresh_cell()
## DATA rotation: radians about X, Y, Z, Gamebryo axes. Read; used for
## placement.
@export var rotation: Vector3 = Vector3.ZERO
## XSCL: the scale; 1.0 when absent. Read; used for placement.
@export var scale: float = 1.0
## Record header flag 0x8000 (Visible When Distant). Read; used by
## WorldStreamerV2's distant-object policy. It is authored placement
## data, not a request to load the companion model: WorldStreamer owns that
## spatial policy.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var visible_when_distant: bool = false
## Presence of XSRF or XSRD. Read (presence only; their bytes are
## undocumented); used by EsmNode to select the begin-only visibility policy
## for persistent skyline stand-ins.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var has_xsrf_or_xsrd: bool = false
## XLKR: the placed reference this one is linked to (e.g. the door a terminal
## controls), as its FormID; 0 when absent. Read, on REFR, ACHR and ACRE; used
## by ConditionEvaluator for Condition.RunOn.LINKED_REFERENCE (130 conditions,
## 115 of them on terminals).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var linked_reference_form_id: int = 0
## Record header flag 0x800 (Initially Disabled). Read, on REFR, ACHR and ACRE
## (1567, 1449 and 512 in FalloutNV.esm); used as the starting value of
## `disabled`.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var initially_disabled: bool = false
## XESP: the enable parent reference's FormID; 0 when absent. Read, on REFR,
## ACHR and ACRE (3337 in FalloutNV.esm; parents are REFRs, ACHRs and ACREs,
## chains at most two deep); used by is_disabled(), which follows the parent
## instead of `disabled`.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var enable_parent_form_id: int = 0
## XESP flags. Read; Opposite of Parent used by is_disabled(), Pop In (118
## references) not used yet.
@export_custom(PROPERTY_HINT_FLAGS, "Opposite of Parent,Pop In", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var enable_parent_flags: int = 0
## XPRM: the primitive volume placed with this reference -- triggers,
## acoustic spaces, sound emitters, room portals. Read; 5677 REFRs in
## FalloutNV.esm carry one (Box 2436, Sphere 130, Portal Box 3111). Used by
## EsmNode, which builds an EsmPrimitiveVolume for it.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var primitive_type: PrimitiveType = PrimitiveType.NONE
## XPRM bounds, in metres, Gamebryo axes. Read; used by EsmPrimitiveVolume as
## half-extents (a sphere's radius in X). xEdit displays them doubled, which
## suggests half-extents; not verified in play.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var primitive_bounds: Vector3 = Vector3.ZERO
## XPRM colour (RGBA floats), presumably the editor's display colour. Read;
## not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var primitive_color: Color = Color(0, 0, 0, 0)
## Not an ESM field: the CELL containing this reference, derived from
## current_space_form_id and position by EsmServer.cell_at(). Written only by
## _refresh_cell(); used by the streamers, NpcSimulationServer and Game.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_DEFAULT | PROPERTY_USAGE_READ_ONLY) var current_cell_form_id: int = 0

## Not an ESM field: this reference's object script state (locals), created
## by ScriptServer the first time the script runs or a variable is written.
## Null when the base has no script or it has not run yet. Saved.
@export var script_instance: ScriptInstance

## Not an ESM field: set by MarkForDelete. The streamers do not spawn a marked
## reference again; its current node, if any, stays until its CELL unloads.
## Saved.
@export var marked_for_delete: bool = false

## Not an ESM field: whether Disable has hidden this reference; starts as
## `initially_disabled`. Set by set_disabled() (Enable, Disable); ignored while
## the reference has an enable parent. Saved. Use is_disabled() for the state
## in effect.
@export var disabled: bool = false

## Runtime state with no ESM source: SwapTexture's swaps, NIF block name ->
## texture path relative to textures\, without extension. Set by
## swap_texture(); applied by EsmNode. Not saved: per the GECK wiki, loading a
## save reverts swapped textures.
var texture_swaps: Dictionary = {}

## Runtime state with no ESM source: the actor using this reference, for
## references used by one actor at a time (terminals, containers, a door being
## lockpicked). Set only by ScriptServer.begin_use / end_use; not saved.
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

## Whether this reference is disabled: its enable parent's state (inverted
## with Opposite of Parent) when it has one, otherwise `disabled`. A disabled
## reference is not shown and has no collision; an actor's script does not
## run while it is disabled.
func is_disabled() -> bool:
	var parent := get_enable_parent()
	if parent == null:
		return disabled
	return parent.is_disabled() != ((enable_parent_flags & ENABLE_PARENT_OPPOSITE) != 0)

## Enable / Disable. Does nothing on a reference with an enable parent, whose
## state is always its parent's.
func set_disabled(value: bool) -> void:
	if enable_parent_form_id != 0 or disabled == value:
		return
	disabled = value
	mark_dirty()
	enable_state_changed.emit()

## SwapTexture: the NIF block `block_name` shows `texture_path` (relative to
## textures\, no extension) in place of its diffuse texture.
func swap_texture(block_name: String, texture_path: String) -> void:
	texture_swaps[block_name] = texture_path
	texture_swapped.emit(block_name)

## The XESP enable parent, or null when there is none.
func get_enable_parent() -> EsmReference:
	if enable_parent_form_id == 0:
		return null
	var server := get_esm_server()
	return server.get_reference("authored:%08X" % enable_parent_form_id) if server != null else null

## This reference's actor values, or null when it is not an actor.
func get_actor_values() -> ActorValues:
	return null

## Built-in activation of this reference: its base type's activate(). The
## dispatch point for ScriptServer; a reference type may override it.
func default_activate(activator: EsmReference) -> void:
	if base != null:
		base.activate(self, activator)
