extends Node3D

## PlayIdle through ScriptServer's ActorIdles (Plans/Actors/stage_f.md step 1):
## Doc Mitchell, physicalised in his house, plays VCG01DocGiveMirror (VCG01's
## stage script line) in place of locomotion and returns to it when the clip
## ends; an actor without a node ends the idle at once; a seated actor does not
## play it. Package events (step 2): VCG01PlayerSection1's On Begin idle plays
## when it becomes his package, and its On Change idle when it is added again
## while it runs (VCG01 stage 7's trick). Both clips move only Camera1st, so on
## Doc nothing shows; the idle state is what is checked.

## How long any wait may take, milliseconds.
const TIMEOUT_MSEC := 30000

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
	ScriptServer.player_reference = EsmServer.get_player_reference()
	var doc := EsmServer.find_reference_by_editor_id("DocMitchellREF") as ActorReference
	var sunny := EsmServer.find_reference_by_editor_id("SunnyRef") as ActorReference
	for actor in [doc, sunny]:
		NpcSimulationServer.package_runner.untrack(actor)
	NpcSimulationServer.local_navigation.set_local_cells(doc.current_space_form_id, PackedInt32Array([doc.current_space_form_id]))
	var doc_node := EsmReferencePhysicaliser.new().physicalise(doc, self) as NpcController
	await _wait_until(func() -> bool: return doc_node.actor != null and doc_node.actor.is_visual_built() and doc_node.actor.animator.get_idle() == null and doc_node.actor.find_child("LocomotionAnimationPlayer", true, false) != null)
	var animator := doc_node.actor.animator
	var mirror := EsmServer.find_base_by_editor_id("VCG01DocGiveMirror") as IdleBase

	var result: Dictionary = ScriptServer.run_debug_line("DocMitchellREF.PlayIdle VCG01DocGiveMirror")
	check(bool(result.get("ok", false)) and doc.special_idle == mirror, "DocMitchellREF.PlayIdle VCG01DocGiveMirror sets his special idle (%s)" % _name(doc.special_idle))
	await _wait_until(func() -> bool: return _player_clip(doc_node) == ActorAnimator.IDLE_CLIP_NAME)
	check(animator.get_idle() == mirror and _player_clip(doc_node) == ActorAnimator.IDLE_CLIP_NAME, "his animator plays it in place of locomotion (%s)" % _player_clip(doc_node))
	await _wait_until(func() -> bool: return doc.special_idle == null)
	check(doc.special_idle == null and animator.get_idle() == null, "when the 3 s clip ends the idle is cleared and he returns to locomotion")
	await _wait_until(func() -> bool: return _player_clip(doc_node) != ActorAnimator.IDLE_CLIP_NAME and _player_clip(doc_node) != "")
	check(_player_clip(doc_node).begins_with("locomotion"), "and plays a locomotion clip again (%s)" % _player_clip(doc_node))

	ScriptServer.run_debug_line("SunnyRef.PlayIdle VCG01DocGiveMirror")
	check(EsmNode.node_for(sunny) == null and sunny.special_idle == null, "an actor without a node ends the idle at once")

	var chair := EsmServer.find_reference_by_editor_id("DocMitchellChairREF") as FurnitureReference
	ScriptServer.begin_use(doc, chair)
	await _wait_until(func() -> bool: return doc.sit_state == FurnitureSeating.SITTING)
	ScriptServer.run_debug_line("DocMitchellREF.PlayIdle VCG01DocGiveMirror")
	check(doc.sit_state == FurnitureSeating.SITTING and doc.special_idle == null and animator.get_idle() != mirror, "seated, he does not play it: the furniture idles own his body")
	ScriptServer.end_use(doc)
	await _wait_until(func() -> bool: return doc.sit_state == FurnitureSeating.NOT_SITTING)

	var runner := NpcSimulationServer.package_runner
	var section := EsmServer.find_base_by_editor_id("VCG01PlayerSection1") as PackageBase
	runner.set_script_package(doc, section)
	check(doc.active_package == section and doc.special_idle == section.on_begin.idle, "a package's On Begin idle plays when it becomes his package (%s)" % _name(doc.special_idle))
	runner.set_script_package(doc, section)
	check(doc.special_idle == section.on_change.idle, "added again while it runs, its On Change idle plays (%s)" % _name(doc.special_idle))
	runner.set_script_package(doc, null)
	runner.untrack(doc)

	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)

## The animation Doc's locomotion AnimationPlayer is playing, or "".
func _player_clip(node: NpcController) -> String:
	var player := node.actor.find_child("LocomotionAnimationPlayer", true, false) as AnimationPlayer
	return String(player.current_animation) if player != null else ""

func _name(base: EsmBase) -> String:
	return base.editor_id if base != null else "none"

func _wait_until(condition: Callable) -> void:
	var deadline := Time.get_ticks_msec() + TIMEOUT_MSEC
	while not condition.call() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
