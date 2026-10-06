extends Node3D

## Furniture use (Plans/Actors/stage_g.md steps 1 and 3): the idle tree picks
## the chair's enter, sitting and stand-up idles for Doc in his chair by sit
## state and marker ID; using the chair seats him at its marker (GetSitting 3,
## GetFurnitureMarkerID 14) and leaving it stands him; his VCG01 stage 80 Travel
## package ends with him seated, off screen.

const SPEED_SCALE := 10.0
const FRAMES := 30 * 60

var failures := 0

func check(condition: bool, message: String) -> void:
	if condition:
		print("  OK   ", message)
	else:
		print("  FAIL ", message)
		failures += 1

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	NpcSimulationServer.records_per_frame = 512
	NpcSimulationServer.seed()
	if not NpcSimulationServer.is_seeded:
		await NpcSimulationServer.seed_finished
	NpcSimulationServer.low_level_travel.speed_scale = SPEED_SCALE
	ScriptServer.player_reference = EsmServer.get_player_reference()
	var doc := EsmServer.find_reference_by_editor_id("DocMitchellREF") as ActorReference
	var chair := EsmServer.find_reference_by_editor_id("DocMitchellChairREF") as FurnitureReference
	NpcSimulationServer.package_runner.untrack(doc)

	check(ScriptServer.begin_use(doc, chair), "Doc starts using his chair")
	await _wait_until(func() -> bool: return doc.sit_state == FurnitureSeating.SITTING)
	ScriptServer.apply_pending_moves()
	var placement := ScriptServer.furniture_seating.get_placement(chair, doc.using_marker)
	check(not placement.is_empty() and doc.position.distance_to(placement["position"]) < 0.01, "he is seated at the chair's marker (%s, marker at %s)" % [doc.position, placement.get("position")])
	check(_run("DocMitchellREF.GetSitting") == 3 and _run("DocMitchellREF.GetFurnitureMarkerID") == 14, "GetSitting is 3 and GetFurnitureMarkerID 14 (%s, %s)" % [_run("DocMitchellREF.GetSitting"), _run("DocMitchellREF.GetFurnitureMarkerID")])

	var root := ScriptServer.idle_tree.get_root(IdleTree.FURNITURE_ROOT)
	var expected := [[2, "ChairFrontSit", "Chair_ForwardEnter.kf"], [1, "ChairDynamicIdle", "DynamicIdle_ChairSit.kf"], [4, "ChairFrontStand", "Chair_ForwardExit.kf"]]
	for row in expected:
		doc.sit_state = row[0]
		var picked := ScriptServer.idle_tree.pick(doc, root)
		check(picked != null and picked.editor_id == row[1] and picked.model_path.get_file() == row[2], "sit state %d picks %s, %s (%s)" % [row[0], row[1], row[2], _describe(picked)])
	var quest := EsmServer.find_base_by_editor_id("VCG01")
	var state := QuestServer.get_quest_state(quest)
	QuestServer.start_quest(quest)
	state.stage = 40
	var early := ScriptServer.idle_tree.pick(doc, root)
	check(early != null and early.editor_id == "NVchairStandDoc", "at VCG01 stage 40 standing up picks NVchairStandDoc first (%s)" % _describe(early))
	state.stage = 0
	doc.sit_state = FurnitureSeating.SITTING

	ScriptServer.end_use(doc)
	check(doc.sit_state == FurnitureSeating.NOT_SITTING and doc.using == null and _run("DocMitchellREF.GetFurnitureMarkerID") == 0, "leaving the chair stands him (sit state %d)" % doc.sit_state)

	NpcSimulationServer.package_runner.track(doc)
	state.stage = 80
	state.stages_done[80] = true
	NpcSimulationServer.package_runner.evaluate_now(doc)
	await _wait_until(func() -> bool: return doc.package_completed and doc.sit_state == FurnitureSeating.SITTING)
	ScriptServer.apply_pending_moves()
	check(doc.using == chair and doc.sit_state == FurnitureSeating.SITTING and doc.position.distance_to(placement["position"]) < 0.01, "at VCG01 stage 80 his Travel package ends with him seated at the marker (sit state %d, %.2f m off)" % [doc.sit_state, doc.position.distance_to(placement["position"])])

	await _check_on_screen(doc, chair, placement)
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)

## Physicalised (NpcController, holding the lease in his house's local
## navigation), Doc is moved onto the seat and stays there.
func _check_on_screen(doc: ActorReference, chair: FurnitureReference, placement: Dictionary) -> void:
	NpcSimulationServer.package_runner.untrack(doc)
	ScriptServer.end_use(doc)
	ScriptServer.move_reference(doc, doc.current_space_form_id, doc.position + Vector3(2.0, 0.0, 0.0), doc.rotation)
	ScriptServer.apply_pending_moves()
	NpcSimulationServer.local_navigation.set_local_cells(doc.current_space_form_id, PackedInt32Array([doc.current_space_form_id]))
	var controller := EsmReferencePhysicaliser.new().physicalise(doc, self) as NpcController
	for frame in 30:
		await get_tree().physics_frame
	ScriptServer.begin_use(doc, chair)
	await _wait_until(func() -> bool: return doc.sit_state == FurnitureSeating.SITTING)
	ScriptServer.apply_pending_moves()
	var seat := EsmReferencePhysicaliser.GAMEBRYO_TO_GODOT_BASIS * Vector3(placement["position"])
	for frame in 120:
		await get_tree().physics_frame
	check(controller.global_position.distance_to(seat) < 0.05 and doc.position.distance_to(placement["position"]) < 0.05, "on screen his controller moves to the seat and stays there for 2 s (%.3f m off)" % controller.global_position.distance_to(seat))

func _wait_until(condition: Callable) -> void:
	for frame in FRAMES:
		if condition.call():
			return
		await get_tree().physics_frame

func _run(line: String) -> int:
	return int(ScriptServer.run_debug_line(line).get("result", -1))

func _describe(idle: IdleBase) -> String:
	return "%s, %s" % [idle.editor_id, idle.model_path.get_file()] if idle != null else "none"
