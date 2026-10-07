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

@export var player: PlayerController
@export var cell_streamer: CellStreamerV2
@export var world_streamer: WorldStreamerV2
@export var terrain_streamer: TerrainStreamer

## Space the body is currently in, or 0 before the first transition.
var loaded_space_form_id := 0
var _target_space_form_id := 0
var _generation := 0
## Set when a CenterOnCell destination has no COC marker: the body is placed
## above the loaded CELL's geometry instead of at the reference.
var _drop_into_cell := false

func _process(delta: float) -> void:
	if is_transitioning():
		$ColorRect.modulate.a = 1.0
	else:
		$ColorRect.modulate.a = lerpf($ColorRect.modulate.a, 0, delta*2.0)

func _ready() -> void:
	ScriptServer.reference_teleported.connect(_on_reference_teleported)
	cell_streamer.load_completed.connect(_on_load_completed)

func is_transitioning() -> bool:
	return _target_space_form_id != loaded_space_form_id or _settling

## An interior has loaded and the body waits, frozen, for it to settle.
var _settling := false

## CenterOnCell / COC: moves the possessed actor to an interior CELL's
## COCMarkerHeading. Returns the CELL FormID, or {"error": ...}.
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
	var marker: EsmReference = null
	for reference in EsmServer.get_references_in_cell(cell):
		if reference.base != null and reference.base.editor_id == COC_MARKER_BASE_EDITOR_ID:
			marker = reference
			break
	_drop_into_cell = marker == null
	ScriptServer.move_reference(player.possessed, cell,
			marker.position if marker != null else Vector3.ZERO,
			marker.rotation if marker != null else Vector3.ZERO)
	return cell

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
		terrain_streamer.set_paused(true)
		world_streamer.set_paused(true)
		cell_streamer.load_cell(new_space_form_id)
	else:
		_enter_worldspace(new_space_form_id, _generation)

func _on_load_completed(cell_form_id: int, success: bool) -> void:
	if cell_form_id != _target_space_form_id or not success:
		return
	loaded_space_form_id = cell_form_id
	entered_interior.emit(cell_form_id)
	if _drop_into_cell:
		_drop_into_cell = false
		_drop_body_into_current_cell()
	else:
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
		terrain_streamer.set_paused(false)
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

## Places the body above the current CELL's geometry, for a CELL with no COC
## marker. The body's own sync then writes where it lands back to the actor.
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
