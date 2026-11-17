class_name TransitionCoordinator
extends Node

## Keeps the loaded space equal to the space of the actor the player
## possesses. Reacts to that actor's teleports (ScriptServer.reference_teleported):
## a teleport within the loaded space repositions the body; one into another
## space freezes the body, loads the destination (CellStreamerV2 for an
## interior CELL, WorldStreamerV2 and TerrainStreamer for a worldspace), then
## places the body from the actor's reference and releases it. A teleport that
## arrives while a load is in progress retargets it.

## Emitted once an interior CELL is loaded and the body placed in it.
signal entered_interior(cell_form_id: int)
## Emitted when the destination is a worldspace, before its streaming starts.
signal entered_exterior(worldspace_form_id: int)

const COC_MARKER_BASE_EDITOR_ID := "COCMarkerHeading"
## Metres CenterOnCell searches from a CELL's centre for a navmesh point.
const NAVMESH_SNAP_DISTANCE := 1000.0
## Seconds a transition runs before the loading screen offers Force finish.
const FORCE_FINISH_AFTER_SECONDS := 5.0

@export var player: PlayerController
@export var cell_streamer: CellStreamerV2
@export var world_streamer: WorldStreamerV2
@export var terrain_streamer: TerrainStreamer

## Space the body is currently in, or 0 before the first transition.
var loaded_space_form_id := 0
var _target_space_form_id := 0
var _generation := 0
## Set when a CenterOnCell destination has no arrival_spot(): once the CELL
## has settled, the body is placed above its geometry instead of at the
## reference.
var _drop_into_cell := false
## Seconds the current transition has been running.
var _transition_seconds := 0.0
## Keeps the overlay up while set, though no transition runs: a save being
## applied before the player's space starts loading. Set by Game.
var holding_overlay := false
## The line under "Loading" that says what is loading; built on first use.
var _progress_label: Label = null

@onready var _force_finish_button: Button = $ColorRect/ForceFinishButton

func _process(delta: float) -> void:
	if is_transitioning() or holding_overlay:
		$ColorRect.modulate.a = 1.0
		_transition_seconds += delta
	else:
		$ColorRect.modulate.a = lerpf($ColorRect.modulate.a, 0, delta*2.0)
		_transition_seconds = 0.0
	var offer_force_finish := _transition_seconds >= FORCE_FINISH_AFTER_SECONDS
	if offer_force_finish and not _force_finish_button.visible:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_force_finish_button.visible = offer_force_finish

func _ready() -> void:
	# The overlay and its progress keep drawing while the game is paused for
	# a load.
	process_mode = Node.PROCESS_MODE_ALWAYS
	ScriptServer.reference_teleported.connect(_on_reference_teleported)
	cell_streamer.load_completed.connect(_on_load_completed)
	cell_streamer.load_progress.connect(_on_cell_load_progress)
	_force_finish_button.visible = false
	_force_finish_button.pressed.connect(force_finish)

## Unloads the world for loading a save into an open game: the interior and
## the exterior streamed in are freed (their nodes hold the replaced game's
## references), any transition in flight is dropped, and nothing counts as
## loaded, so the loaded player's move loads their space. Terrain is kept: it
## holds no game state.
func unload_world() -> void:
	_generation += 1
	_settling = false
	_drop_into_cell = false
	cell_streamer.unload_current()
	world_streamer.deactivate()
	terrain_streamer.set_streaming_paused(true)
	loaded_space_form_id = 0
	_target_space_form_id = 0

## Shows what is loading under the overlay's "Loading": `stage: detail`, with
## `done / total` when `total` is above 0. An empty stage clears it.
func show_progress(stage: String, detail: String, done: int, total: int) -> void:
	if _progress_label == null:
		_progress_label = Label.new()
		_progress_label.name = "ProgressLabel"
		_progress_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_progress_label.set_anchors_preset(Control.PRESET_CENTER)
		_progress_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
		_progress_label.position.y += 48.0
		$ColorRect.add_child(_progress_label)
	var text := stage
	if not detail.is_empty():
		text += ": " + detail
	if total > 0:
		text += "  (%d / %d)" % [done, total]
	_progress_label.text = text

func _on_cell_load_progress(fraction: float) -> void:
	if is_transitioning():
		show_progress("Loading cell", _space_name(_target_space_form_id), roundi(fraction * 100.0), 100)

func _space_name(space_form_id: int) -> String:
	var record := EsmServer.get_base(space_form_id) if space_form_id != 0 else null
	return record.editor_id if record != null else ""

## Ends the current transition without waiting for its loads: the destination
## counts as loaded, the body is placed from the actor's reference and
## released. A load still in flight carries on, but no longer holds the body.
func force_finish() -> void:
	if not is_transitioning():
		return
	_generation += 1
	_settling = false
	loaded_space_form_id = _target_space_form_id
	_place_body()
	player.set_frozen(false)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func is_transitioning() -> bool:
	return _target_space_form_id != loaded_space_form_id or _settling

## An interior has loaded and the body waits, frozen, for it to settle.
var _settling := false

## CenterOnCell / COC: moves the possessed actor into an interior CELL, at
## the first of: its COCMarkerHeading; the landing of a load door into it (the
## XTEL of the door a load door in the CELL leads to); the navmesh point
## nearest the centre of its references. A CELL with none of these drops the
## body above its geometry once it has settled. Returns the CELL FormID, or
## {"error": ...}.
func center_on_cell(args: Array) -> Variant:
	if args.is_empty():
		return { "error": "CenterOnCell requires a cell EditorID." }
	if player == null or player.possessed == null:
		return { "error": "No actor is possessed by the player." }
	var cell := EsmServer.find_form_id_by_editor_id(str(args[0]))
	if cell == 0:
		return { "error": "No CELL with EditorID '%s' in the loaded ESM." % str(args[0]) }
	if EsmServer.get_space_form_id_for_cell(cell) != cell:
		return { "error": "'%s' is exterior; CenterOnWorld is not implemented yet." % str(args[0]) }
	var spot := arrival_spot(cell)
	_drop_into_cell = spot.is_empty()
	ScriptServer.move_reference(player.possessed, cell,
			spot.get("position", Vector3.ZERO), spot.get("rotation", Vector3.ZERO))
	return cell

## Where CenterOnCell places the player in interior `cell`: {"position",
## "rotation", "source"} (Gamebryo axes, metres, radians), source being
## "coc_marker", "door_landing" or "navmesh"; empty when the CELL has none.
static func arrival_spot(cell: int) -> Dictionary:
	var references := EsmServer.get_references_in_cell(cell)
	var spot := _coc_marker_spot(references)
	if spot.is_empty():
		spot = _door_landing_spot(cell, references)
	if spot.is_empty():
		spot = _navmesh_spot(cell, references)
	return spot

static func _coc_marker_spot(references: Array[EsmReference]) -> Dictionary:
	for reference in references:
		if reference.base != null and reference.base.editor_id == COC_MARKER_BASE_EDITOR_ID:
			return {"position": reference.position, "rotation": reference.rotation, "source": "coc_marker"}
	return {}

## The landing of the first load door whose partner lands in `cell`: where
## the player arrives coming through it.
static func _door_landing_spot(cell: int, references: Array[EsmReference]) -> Dictionary:
	for reference in references:
		var door := reference as DoorReference
		if door == null or not door.has_teleport:
			continue
		var partner := door.get_teleport_destination()
		if partner == null or not partner.has_teleport or partner.get_teleport_destination_space_form_id() != cell:
			continue
		return {"position": partner.teleport_position, "rotation": partner.teleport_rotation, "source": "door_landing"}
	return {}

## The navmesh point nearest the centre of `cell`'s references, facing north.
static func _navmesh_spot(cell: int, references: Array[EsmReference]) -> Dictionary:
	var navmesh: NavmeshReader = NpcSimulationServer.navmesh
	if navmesh == null or not navmesh.is_loaded() or references.is_empty():
		return {}
	var centre := Vector3.ZERO
	for reference in references:
		centre += reference.position
	centre /= references.size()
	var snapped: Dictionary = navmesh.snap(cell, centre, NAVMESH_SNAP_DISTANCE, false)
	if not bool(snapped.get("found", false)):
		return {}
	return {"position": snapped["position"], "rotation": Vector3.ZERO, "source": "navmesh"}

func _on_reference_teleported(reference: EsmReference, _old_space_form_id: int, new_space_form_id: int) -> void:
	if player == null or reference != player.possessed:
		return
	_generation += 1
	_settling = false
	_target_space_form_id = new_space_form_id
	if new_space_form_id == loaded_space_form_id:
		_place_body()
		player.set_frozen(false)
		return
	player.set_frozen(true)
	if _is_interior(new_space_form_id):
		terrain_streamer.set_streaming_paused(true)
		world_streamer.set_streaming_paused(true)
		cell_streamer.load_cell(new_space_form_id)
	else:
		_enter_worldspace(new_space_form_id, _generation)

func _on_load_completed(cell_form_id: int, success: bool) -> void:
	if cell_form_id != _target_space_form_id or not success:
		return
	loaded_space_form_id = cell_form_id
	entered_interior.emit(cell_form_id)
	_place_body()
	# Held frozen until the cell's geometry, and so its floor, has arrived.
	_settling = true
	cell_streamer.settled.connect(_on_cell_settled.bind(_generation), CONNECT_ONE_SHOT)

## Releases the body into the interior once it has settled, unless a newer
## transition replaced this one.
func _on_cell_settled(_cell_form_id: int, generation: int) -> void:
	if generation != _generation:
		return
	_settling = false
	if _drop_into_cell:
		_drop_into_cell = false
		_drop_body_into_current_cell()
	player.set_frozen(false)

## Streams a worldspace in around the possessed actor. The body is placed
## first so the streamers' first check already sees the destination, and is
## released only once collision-safe terrain and the object tiles have settled.
func _enter_worldspace(worldspace_form_id: int, generation: int) -> void:
	var terrain_diagnostics := terrain_streamer.get_diagnostics()
	var same_worldspace := terrain_streamer.is_active() and int(terrain_diagnostics.get("worldspace_form_id", -1)) == worldspace_form_id
	if not same_worldspace:
		world_streamer.deactivate()
	cell_streamer.unload_current()
	entered_exterior.emit(worldspace_form_id)
	_place_body()

	var object_ready := [false]
	var settled := func() -> void: object_ready[0] = true
	world_streamer.streaming_settled.connect(settled)
	if same_worldspace:
		terrain_streamer.set_streaming_paused(false)
	else:
		terrain_streamer.activate(worldspace_form_id)
	world_streamer.activate(worldspace_form_id)
	var spawn := player.global_position
	var spawn_coord := Vector2i(floori(spawn.x / TerrainStreamer.CELL_SIZE_METERS), floori(-spawn.z / TerrainStreamer.CELL_SIZE_METERS))
	var terrain_status := await terrain_streamer.await_ready_for(worldspace_form_id, spawn_coord, terrain_streamer.get_generation())
	while not object_ready[0] and generation == _generation:
		await get_tree().process_frame
	if world_streamer.streaming_settled.is_connected(settled):
		world_streamer.streaming_settled.disconnect(settled)
	if not _can_release_exterior_transition(generation, terrain_status, object_ready[0]):
		return
	loaded_space_form_id = worldspace_form_id
	_place_body()
	player.set_frozen(false)

## Whether an exterior transition may release the body: it is still the
## newest transition, its terrain is collision-safe, and its tiles settled.
func _can_release_exterior_transition(generation: int, terrain_status: TerrainStreamer.ReadyStatus, object_ready: bool) -> bool:
	return generation == _generation \
			and terrain_status == TerrainStreamer.ReadyStatus.READY \
			and object_ready

func _place_body() -> void:
	var actor := player.possessed
	player.place_body(EsmReferencePhysicaliser.placement_transform(actor.position, actor.rotation).origin, -actor.rotation.z)

## Places the body above the current CELL's geometry, for a CELL with no
## arrival_spot(), once its geometry has arrived. The body's own sync then
## writes where it lands back to the actor.
func _drop_body_into_current_cell() -> void:
	var bounds: Variant = _current_cell_aabb()
	if bounds == null:
		_place_body()
		return
	var center: Vector3 = bounds.get_center()
	player.place_body(Vector3(center.x, bounds.position.y + bounds.size.y + 1.0, center.z), 0.0)

func _current_cell_aabb() -> Variant:
	if cell_streamer._current == null:
		return null
	var combined := AABB()
	var have := false
	for mesh_instance in _mesh_instances(cell_streamer._current):
		var bounds: AABB = mesh_instance.global_transform * mesh_instance.mesh.get_aabb()
		combined = bounds if not have else combined.merge(bounds)
		have = true
	if have:
		return combined
	return null

func _mesh_instances(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out.append(node)
	for child in node.get_children():
		out.append_array(_mesh_instances(child))
	return out

## An interior space is a CELL record; a worldspace is not.
func _is_interior(space_form_id: int) -> bool:
	return not EsmServer.reader.find_cell_by_form_id(space_form_id).is_empty()
