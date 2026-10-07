extends Node3D

## PlayIdle through ScriptServer's ActorIdles (Plans/Actors/stage_f.md step 1):
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
## PickIdle plays the pick.

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

	ScriptServer.run_debug_line("DocMitchellREF.PlayIdle LooseHandsOnHeart")
	var started := Time.get_ticks_msec()
	await _wait_until(func() -> bool: return doc.special_idle == null)
	var seconds := (Time.get_ticks_msec() - started) / 1000.0
	check(seconds > 4.0 and seconds < 6.0, "LooseHandsOnHeart (loop 3-3, its 1.33 s section 3 times) plays %.1f s, not its 2.03 s clip once" % seconds)
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
	check(values == [0, 0, 0, -1, 0, 0, -1], "standing, Doc's IsMoving, IsRunning, IsSneaking, GetHitLocation, GetKnockedState, IsInCombat, GetCurrentAIProcedure are %s" % [values])

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
