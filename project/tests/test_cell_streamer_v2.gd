extends Node3D

const SETTLE_TIMEOUT_MSEC := 15000

var failures := 0
var completed: Array = []
var progress_events := 0

func check(condition: bool, message: String) -> void:
	if condition:
		print("  OK   ", message)
	else:
		print("  FAIL ", message)
		failures += 1

func _on_completed(cell_form_id: int, success: bool) -> void:
	completed.append([cell_form_id, success])

func _await_load(streamer: CellStreamerV2, cell_form_id: int) -> void:
	completed.clear()
	streamer.load_cell(cell_form_id)
	var deadline := Time.get_ticks_msec() + SETTLE_TIMEOUT_MSEC
	while streamer.is_loading() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame

func _ready() -> void:
	var esm_server = get_node("/root/EsmServer")
	if not esm_server.is_ready():
		await esm_server.esm_ready
	var doc_house: Dictionary = esm_server.reader.find_cell_by_editor_id("GSDocMitchellHouse")
	var ranch_house: Dictionary = esm_server.reader.find_cell_by_editor_id("RanchHouseInterior03")
	check(not doc_house.is_empty() and not ranch_house.is_empty(), "resolved real interior cells through EsmServer")
	if doc_house.is_empty() or ranch_house.is_empty():
		get_tree().quit(1)
		return

	var streamer := CellStreamerV2.new()
	streamer.objects_per_frame = 1
	add_child(streamer)
	streamer.load_completed.connect(_on_completed)
	streamer.load_progress.connect(func(_fraction: float) -> void: progress_events += 1)
	await get_tree().process_frame

	await _await_load(streamer, int(doc_house.form_id))
	check(completed.size() == 1 and bool(completed[0][1]), "typed interior population completes")
	check(progress_events > 1, "per-frame object budget yields incremental progress")
	check(streamer._current != null and streamer._current.name == "CurrentCell", "semantic root atomically becomes CurrentCell")
	check(streamer._current != null and streamer._current.get_node_or_null("RefrRoot") == null, "typed root does not create a legacy RefrRoot")
	check(streamer._current_refs.size() > 100, "current references are typed and populated from the real cell")
	var first_current := streamer._current
	var first_semantic := first_current.get_child(0) as EsmNode if first_current != null and first_current.get_child_count() > 0 else null
	check(first_semantic != null, "physicaliser creates EsmNode children rather than registry nodes")
	if first_semantic != null:
		check(first_semantic.visual_detail == EsmNode.VisualDetail.FULL, "interior requests full-detail models only")
		check(not first_semantic.has_meta("gamebryo_reference"), "typed node has no legacy registry metadata")
	var coc := streamer.find_ref_by_editor_id("COCMarkerHeading")
	check(coc != null, "typed reference lookup finds the authored COC marker")
	if coc != null:
		var coc_node: EsmNode = null
		for child in first_current.get_children():
			if child is EsmNode and child.reference != null and child.reference.instance_id == coc.instance_id:
				coc_node = child
				break
		var expected_coc := EsmReferencePhysicaliser.placement_transform(coc.position, coc.rotation)
		check(coc_node != null and coc_node.transform.is_equal_approx(expected_coc), "COC marker uses the physicaliser's shared authored transform")
		var game_transformer: Node = (load("res://game.gd") as Script).new()
		var spawn: Dictionary = game_transformer.call("_convert_authored_spawn_transform", coc.position, coc.rotation)
		check(Vector3(spawn["position"]).is_equal_approx(expected_coc.origin), "Game COC spawn uses the same physicaliser translation")
		game_transformer.free()
	var teleport_door: DoorReference = null
	for reference in streamer.get_current_refs():
		if reference is DoorReference and reference.has_teleport_destination:
			teleport_door = reference
			break
	if teleport_door != null:
		var expected_xtel := EsmReferencePhysicaliser.placement_transform(teleport_door.teleport_position, teleport_door.teleport_rotation)
		var game_transformer: Node = (load("res://game.gd") as Script).new()
		var spawn: Dictionary = game_transformer.call("_convert_authored_spawn_transform", teleport_door.teleport_position, teleport_door.teleport_rotation)
		check(Vector3(spawn["position"]).is_equal_approx(expected_xtel.origin), "Game XTEL spawn uses the same physicaliser translation")
		game_transformer.free()
	else:
		check(false, "Doc Mitchell's house contains a typed teleport door fixture")

	# A synthetic collision shape exercises the exact late-NIF callback hook:
	# while LoadingCell is active it inherits disabled state, after the semantic
	# swap it inherits enabled state without relying on NIF timing.
	streamer.load_cell(int(ranch_house.form_id))
	await get_tree().process_frame
	var loading := streamer._loading_root
	var old_late_shape := CollisionShape3D.new()
	first_current.add_child(old_late_shape)
	streamer.apply_streaming_state_to_subtree(old_late_shape)
	check(not old_late_shape.disabled, "an old-cell late NIF remains solid while LoadingCell populates")
	var late_shape := CollisionShape3D.new()
	if loading != null:
		loading.add_child(late_shape)
		streamer.apply_streaming_state_to_subtree(late_shape)
	check(late_shape.disabled, "late NIF collision is disabled while LoadingCell is hidden")
	var deadline := Time.get_ticks_msec() + SETTLE_TIMEOUT_MSEC
	while streamer.is_loading() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	streamer.apply_streaming_state_to_subtree(late_shape)
	check(not late_shape.disabled, "late NIF collision inherits active state after swap")
	check(streamer._current != first_current and (not is_instance_valid(first_current) or first_current.get_parent() == null), "atomic swap frees the old root only after new semantic population")
	check(streamer.get_current_cell_form_id() == int(ranch_house.form_id), "current-cell lookup follows the swapped typed root")

	streamer.load_cell(int(doc_house.form_id))
	for _frame in 3:
		await get_tree().process_frame
	var stable_current := streamer._current
	streamer.cancel_load()
	check(not streamer.is_loading() and streamer._current == stable_current, "cancellation discards LoadingCell and preserves active cell")
	check(streamer._loading_root == null, "cancellation leaves no hidden loading root")
	streamer.unload_current()
	check(streamer._current == null and streamer.get_current_refs().is_empty(), "unload frees typed current cell and reference lookup state")
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
