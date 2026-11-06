extends Node3D

## PlayIdle through ScriptServer's ActorIdles (Plans/Completed Plans/Actors/stage_f.md step 1):
## Doc Mitchell, physicalised in his house, plays VCG01DocGiveMirror (VCG01's
## stage script line) in place of locomotion and returns to it when the clip
## ends; an actor without a node ends the idle at once; a seated actor does not
## play it. Package events (step 2): VCG01PlayerSection1's On Begin idle plays
## when it becomes his package, and its On Change idle when it is added again
## while it runs (VCG01 stage 7's trick). Both clips move only Camera1st, so on
## Doc nothing shows; the idle state is what is checked. Loops (step 3): an
## idle's StartLoop - EndLoop section plays its IDLE's loop count (3 for
## LooseHandsOnHeart, about 4.7 s against its 2.03 s clip), and forever for 255
## (BartenderTalk) until something ends it. Package idle collections (step 4):
## standing idle under a package with IDLA, Doc plays its idles every IDLT
## seconds, in order with Run In Sequence and one pass only with Do Once.
## Ambient idles (step 5): standing, the movement and current-state condition
## functions read as he is; he is in no faction GeneralIdles' items need, so his
## pick plays nothing; Johnson Nash, a smoker, picks NPCSmokingIdle at its 30%;
## PickIdle plays the pick. Dialogue gestures (5c): saying his farewell, Doc
## reports IsTalking, GetCurrentAIProcedure DIALOGUE (4) and
## GetCurrentAIPackage 6, his response's emotion, and plays a gesture from
## under DialogueIdles (or the response's own SNAM idle) that ends with the
## line. Face tracks: NPCSmokingIdle's KF drives his mouth through its
## HeadAnims morph keys (Completed Plans/Actors/faces.md step 5's gate).

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

	var standing_pelvis := _pelvis_height(doc_node)
	var standing_heading := doc_node.rotation.y
	ScriptServer.run_debug_line("DocMitchellREF.PlayIdle LooseHandsOnHeart")
	var started := Time.get_ticks_msec()
	var highest := 0.0
	var standing_torso := animator._torso_yaw()
	var widest_turn := 0.0
	await get_tree().process_frame
	while doc.special_idle != null and Time.get_ticks_msec() - started < 10000:
		highest = maxf(highest, _pelvis_height(doc_node))
		widest_turn = maxf(widest_turn, absf(angle_difference(standing_torso, animator._torso_yaw())))
		await get_tree().process_frame
	check(highest < standing_pelvis + 0.05, "playing a gesture his pelvis stays at standing height (at most %.2f m, standing %.2f m): Bip01 held in the clips' frame" % [highest, standing_pelvis])
	check(rad_to_deg(widest_turn) < 15.0, "and his torso keeps facing ahead (LooseHandsOnHeart keys no NonAccum rotation; at most %.0f degrees off)" % rad_to_deg(widest_turn))
	var seconds := (Time.get_ticks_msec() - started) / 1000.0
	check(seconds > 4.0 and seconds < 6.0, "LooseHandsOnHeart (loop 3-3, its 1.33 s section 3 times) plays %.1f s, not its 2.03 s clip once" % seconds)
	check(absf(_pelvis_height(doc_node) - standing_pelvis) < 0.05 and absf(angle_difference(standing_heading, doc_node.rotation.y)) < 0.01, "and leaves him at his standing height facing as he did (pelvis %.2f m against %.2f m; turned %.0f degrees)" % [_pelvis_height(doc_node), standing_pelvis, rad_to_deg(angle_difference(standing_heading, doc_node.rotation.y))])
	ScriptServer.run_debug_line("DocMitchellREF.PlayIdle BartenderTalk")
	var forever := Time.get_ticks_msec() + 9000
	while Time.get_ticks_msec() < forever:
		await get_tree().process_frame
	check(doc.special_idle != null and doc.special_idle.editor_id == "BartenderTalk" and _player_clip(doc_node) == ActorAnimator.IDLE_CLIP_NAME, "BartenderTalk (loop 255) is still playing after 9 s, past its 6.73 s clip")
	ScriptServer.actor_idles.finish(doc)
	check(doc.special_idle == null and animator.get_idle() == null, "until it is ended")

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
	# LooseVCG01PlayerBedsit loops forever (255) until something ends it.
	ScriptServer.actor_idles.finish(doc)

	await _check_collections(doc)
	await _check_ambient(doc)
	await _check_dialogue(doc)
	await _check_face_tracks(doc, doc_node)

	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)

## Package idle collections, on test packages Doc runs with no runner, of
## idles without conditions: VCG01DocGiveMirror (3 s) and LooseHandsOnHeart
## (4.7 s with its loops). The player stands where Doc does
## (fAIIdleAnimationDistance).
func _check_collections(doc: ActorReference) -> void:
	ScriptServer.move_reference(ScriptServer.player_reference, doc.current_space_form_id, doc.position, Vector3.ZERO)
	ScriptServer.apply_pending_moves()
	var mirror := EsmServer.find_base_by_editor_id("VCG01DocGiveMirror") as IdleBase
	var hands := EsmServer.find_base_by_editor_id("LooseHandsOnHeart") as IdleBase

	ScriptServer.actor_idles.finish(doc)
	doc.active_package = _collection_package([hands, mirror], 0, 0.5)
	var played := await _record_idles(doc, 2, 14000)
	check(played.size() == 2, "standing idle under a package with an idle collection, he plays its idles (%s)" % ", ".join(played))

	ScriptServer.actor_idles.finish(doc)
	doc.active_package = _collection_package([hands, mirror], PackageBase.IDLE_COLLECTION_FLAG_RUN_IN_SEQUENCE, 0.5)
	played = await _record_idles(doc, 3, 20000)
	check(played == ["LooseHandsOnHeart", "VCG01DocGiveMirror", "LooseHandsOnHeart"], "Run In Sequence plays them in list order, round again (%s)" % ", ".join(played))

	ScriptServer.actor_idles.finish(doc)
	doc.active_package = _collection_package([mirror], PackageBase.IDLE_COLLECTION_FLAG_DO_ONCE, 0.5)
	played = await _record_idles(doc, 2, 8000)
	check(played == ["VCG01DocGiveMirror"], "Do Once plays the list once (%s)" % ", ".join(played))

	ScriptServer.move_reference(ScriptServer.player_reference, doc.current_space_form_id, doc.position + Vector3(40.0, 0.0, 0.0), Vector3.ZERO)
	ScriptServer.apply_pending_moves()
	ScriptServer.actor_idles.finish(doc)
	doc.active_package = _collection_package([mirror], 0, 0.5)
	played = await _record_idles(doc, 1, 3000)
	check(played.is_empty(), "farther than fAIIdleAnimationDistance (28.6 m) from the player, none plays (%s)" % ", ".join(played))

	var travel := EsmServer.find_base_by_editor_id("VCG01DocMitchellTravelToSkullTestSpot") as PackageBase
	var smoking := travel.idle_animations[0]
	var passes := 0
	for attempt in 400:
		if ScriptServer.actor_idles._may_play(doc, smoking):
			passes += 1
	print("       INFO Doc's %s may play %s on %d of 400 tries" % [travel.editor_id, smoking.editor_id, passes])
	doc.active_package = null

## Ambient idles: conditions, the tree pick, PickIdle and the timer.
func _check_ambient(doc: ActorReference) -> void:
	ScriptServer.actor_idles.finish(doc)
	doc.active_package = null
	ScriptServer.move_reference(ScriptServer.player_reference, doc.current_space_form_id, doc.position, Vector3.ZERO)
	ScriptServer.apply_pending_moves()
	var values := []
	for line in ["IsMoving", "IsRunning", "IsSneaking", "GetHitLocation", "GetKnockedState", "IsInCombat", "GetCurrentAIProcedure"]:
		values.append(ScriptServer.run_debug_line("DocMitchellREF.%s" % line).get("result"))
	check(values == [0, 0, 0, -1, 0, 0, ActorAICodes.PROCEDURE_DO_NOTHING], "standing with no package, Doc's IsMoving, IsRunning, IsSneaking, GetHitLocation, GetKnockedState, IsInCombat, GetCurrentAIProcedure are %s (24: DO_NOTHING)" % [values])

	# Doc is in neither SmokerFaction nor GeneralIdleFaction, which every
	# GeneralIdles item a standing NPC without a weapon can reach needs, so the
	# pick stops at GeneralIdles itself: a group with no KF that need not return
	# a file, so no idle plays (GECK).
	var doc_picks := {}
	for attempt in 40:
		var picked := ScriptServer.idle_tree.pick_for(doc)
		var name := picked.editor_id if picked != null else "none"
		doc_picks[name] = int(doc_picks.get(name, 0)) + 1
	check(doc_picks.keys() == ["GeneralIdles"], "Doc's pick is the GeneralIdles group, which plays nothing (%s over 40)" % [doc_picks])
	check(is_equal_approx(ScriptServer.actor_idles.ambient_seconds(doc), 4.0), "his ambient picks come every %.1f s (20 s at energy 50, his is 10)" % ScriptServer.actor_idles.ambient_seconds(doc))
	var ambient := await _record_idles(doc, 1, 10000)
	check(ambient.is_empty(), "so standing with no package for 10 s he plays no ambient idle (%s)" % ", ".join(ambient))

	# Johnson Nash (Primm) is in SmokerFaction: NPCSmokingIdle, 30% of picks.
	var johnson := EsmServer.find_reference_by_editor_id("PrimmJohnsonNashRef") as ActorReference
	var johnson_picks := {}
	for attempt in 400:
		var picked := ScriptServer.idle_tree.pick_for(johnson)
		var name := picked.editor_id if picked != null else "none"
		johnson_picks[name] = int(johnson_picks.get(name, 0)) + 1
	var smoking := int(johnson_picks.get("NPCSmokingIdle", 0))
	check(smoking > 80 and smoking < 160, "Johnson Nash, a smoker, picks NPCSmokingIdle on %d of 400 (its GetRandomPercent < 30) %s" % [smoking, johnson_picks])
	var played := false
	for attempt in 40:
		if int(ScriptServer.run_debug_line("PrimmJohnsonNashRef.PickIdle").get("result", 0)) == 1:
			played = true
			break
	check(played, "PickIdle on him plays the pick (with no 3D node it ends at once)")

## Dialogue gestures while Doc says his farewell (VCG01DocMitchellTopic076,
## INFO 001057E7, four responses) to the player.
func _check_dialogue(doc: ActorReference) -> void:
	ScriptServer.actor_idles.finish(doc)
	var npc := doc.base as NpcBase
	var race_result := int(ScriptServer.run_debug_line("DocMitchellREF.GetIsRace %s" % npc.race.editor_id).get("result", 0))
	var child_result := int(ScriptServer.run_debug_line("DocMitchellREF.IsChild").get("result", -1))
	check(race_result == 1 and child_result == 0, "GetIsRace %s is 1 and IsChild is 0 for Doc" % npc.race.editor_id)

	var topic := EsmServer.find_base_by_editor_id("VCG01DocMitchellTopic076") as DialogueTopicBase
	var farewell: DialogueInfoBase = null
	for info in topic.infos:
		if info.form_id == 0x001057E7:
			farewell = info
	var gestures: Array[String] = []
	var states: Array[String] = []
	var on_response := func(line: DialogueLine, _text: String) -> void:
		if line.speaker != doc:
			return
		states.append("talking %s procedure %s package %s emotion %s/%d" % [
			ScriptServer.run_debug_line("DocMitchellREF.IsTalking").get("result"),
			ScriptServer.run_debug_line("DocMitchellREF.GetCurrentAIProcedure").get("result"),
			ScriptServer.run_debug_line("DocMitchellREF.GetCurrentAIPackage").get("result"),
			ScriptServer.run_debug_line("DocMitchellREF.GetDialogueEmotion").get("result"),
			int(line.current_response().emotion)])
	DialogueServer.response_started.connect(on_response)
	var line := DialogueServer.say(doc, topic, ScriptServer.player_reference, farewell)
	DialogueServer.wait_for_loads()
	var last: IdleBase = null
	var deadline := Time.get_ticks_msec() + 60000
	var voice_off := -1.0
	var voice_volume := -100.0
	while DialogueServer.get_line(doc) == line and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		if line.voice_player != null and voice_off < 0.0:
			var eyes := (EsmNode.node_for(doc) as NpcController).actor.head_tracking.get_eye_position()
			voice_off = line.voice_player.global_position.distance_to(eyes)
			voice_volume = line.voice_player.volume_db
		if doc.special_idle != null and doc.special_idle != last:
			gestures.append("%s (%s)" % [doc.special_idle.editor_id, _top_of(doc.special_idle).editor_id])
		last = doc.special_idle
	DialogueServer.response_started.disconnect(on_response)
	await get_tree().process_frame
	check(not states.is_empty() and states.all(func(state: String) -> bool: return state.begins_with("talking 1 procedure 4 package 6") and state.get_slice(" ", 7).get_slice("/", 0) == state.get_slice(" ", 7).get_slice("/", 1)), "saying each response he is talking, procedure DIALOGUE, package 6, with the response's emotion (%s)" % "; ".join(states))
	var named := farewell.responses.any(func(response: DialogueResponseCollection) -> bool: return response.speaker_idle_form_id != 0)
	check(not gestures.is_empty() and gestures.all(func(gesture: String) -> bool: return gesture.ends_with("(DialogueIdles)") or named), "he gestures from DialogueIdles while he speaks (%s)" % ", ".join(gestures))
	check(doc.special_idle == null or doc.special_idle.editor_id.is_empty() or not gestures.has("%s (DialogueIdles)" % doc.special_idle.editor_id), "and the gesture ends with the line (%s)" % (doc.special_idle.editor_id if doc.special_idle != null else "none"))
	check(voice_off >= 0.0 and voice_off < 0.05 and voice_volume == 0.0, "his voice plays from his eyes (an AudioStreamPlayer3D %.3f m from them, %.0f dB)" % [voice_off, voice_volume])
	_check_voice_without_node()
	quests_stop_timer()

## A speaker with no 3D node is heard from its reference's position plus
## voice_height; one in another space than the player is silent.
func _check_voice_without_node() -> void:
	var sunny := EsmServer.find_reference_by_editor_id("SunnyRef") as ActorReference
	var expected := EsmReferencePhysicaliser.GAMEBRYO_TO_GODOT_BASIS * sunny.position + Vector3.UP * DialogueServer.voice_height
	var line := DialogueLine.new()
	line.speaker = sunny
	line.voice_player = AudioStreamPlayer3D.new()
	add_child(line.voice_player)
	DialogueServer._place_voice(line)
	var off := line.voice_player.global_position.distance_to(expected)
	check(EsmNode.node_for(sunny) == null and off < 0.01, "Sunny, with no node, is heard from her position plus eye height (%.3f m off)" % off)
	check(sunny.current_space_form_id != ScriptServer.player_reference.current_space_form_id and line.voice_player.volume_db <= -80.0, "and, in another space than the player, not at all (%.0f dB)" % line.voice_player.volume_db)
	line.voice_player.queue_free()

## The farewell's End script starts VGenericTimer; stop it again.
func quests_stop_timer() -> void:
	QuestServer.stop_quest(EsmServer.find_quest_by_editor_id("VGenericTimer"))

## The pelvis's height above the controller's origin, metres.
func _pelvis_height(node: NpcController) -> float:
	var skeleton := node.actor.find_child("Skeleton3D", true, false) as Skeleton3D
	var pelvis := skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone("Bip01 Pelvis"))
	return pelvis.origin.y - node.global_position.y

func _top_of(idle: IdleBase) -> IdleBase:
	var top := idle
	while top.parent != null:
		top = top.parent
	return top

## A PACK with only an idle collection.
func _collection_package(idles: Array[IdleBase], flags: int, timer: float) -> PackageBase:
	var package := PackageBase.new()
	package.editor_id = "TestIdleCollection"
	package.idle_animations = idles
	package.idle_count = idles.size()
	package.idle_collection_flags = flags
	package.idle_timer = timer
	return package

## The idles `doc` starts playing, up to `count`, within `milliseconds`.
func _record_idles(doc: ActorReference, count: int, milliseconds: int) -> Array[String]:
	var played: Array[String] = []
	var last: IdleBase = null
	var deadline := Time.get_ticks_msec() + milliseconds
	while played.size() < count and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		if doc.special_idle != last and doc.special_idle != null:
			played.append(doc.special_idle.editor_id)
		last = doc.special_idle
	while doc.special_idle != null and Time.get_ticks_msec() < deadline + 10000:
		await get_tree().process_frame
	return played

## While NPCSmokingIdle plays, its KF's face tracks reach the animator and the
## facial player sets them on his face: Oh, the lips round on the cigarette
## (keyed to 0.94 at 1.1 s), rises above 0.5.
func _check_face_tracks(doc: ActorReference, doc_node: NpcController) -> void:
	var animator := doc_node.actor.animator
	var facial_player := doc_node.actor.facial_player
	ScriptServer.run_debug_line("DocMitchellREF.PlayIdle NPCSmokingIdle")
	await _wait_until(func() -> bool: return _player_clip(doc_node) == ActorAnimator.IDLE_CLIP_NAME)
	var clip_largest := 0.0
	var face_largest := 0.0
	var deadline := Time.get_ticks_msec() + TIMEOUT_MSEC
	while doc.special_idle != null and Time.get_ticks_msec() < deadline:
		var weights := animator.face_weights()
		clip_largest = maxf(clip_largest, float(weights.get("Oh", 0.0)))
		face_largest = maxf(face_largest, facial_player.get_weight("Oh"))
		await get_tree().process_frame
	ScriptServer.actor_idles.finish(doc)
	check(clip_largest > 0.5, "NPCSmokingIdle's clip sets Oh (up to %.2f)" % clip_largest)
	check(face_largest > 0.5, "and his face shows it (Oh up to %.2f)" % face_largest)

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
