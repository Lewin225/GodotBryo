extends Node3D

## An actor's node moved to another parent (WorldStreamerV2 reparents it to
## the tile under its reference when the reference changes CELL) keeps
## animating: after the move it still has a KfAnimator, the walk it was
## playing plays on, and its clock advances.

const WALK_CLIP := "locomotion__male__mtforward.kf"

var failures := 0


func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1


func _ready() -> void:
	var esm_server = get_node("/root/EsmServer")
	if not esm_server.is_ready():
		await esm_server.esm_ready
	var doc: EsmReference = esm_server.find_reference_by_editor_id("DocMitchellREF")
	var tile_a := Node3D.new()
	tile_a.name = "TileA"
	add_child(tile_a)
	var tile_b := Node3D.new()
	tile_b.name = "TileB"
	add_child(tile_b)
	var controller := EsmReferencePhysicaliser.new().physicalise(doc, tile_a) as NpcController
	var node: EsmActorNode = controller.actor
	var clips := [-1]
	node.animation_load_completed.connect(func(count: int) -> void: clips[0] = count)
	for frame in 3000:
		await get_tree().process_frame
		if clips[0] >= 0:
			break
	check(clips[0] > 0, "Doc's locomotion loads (%d clips)" % clips[0])
	# Doc's own controller would publish standing still over the motion set
	# here; the actor node takes this motion alone.
	controller.set_physics_process(false)
	var motion := ActorMotion.new()
	motion.velocity = Vector3(0.0, 0.0, -1.2)
	node.motion = motion
	await _frames(4)
	var animator := node.animator
	check(animator.playing_clip() == WALK_CLIP, "before the move Doc walks (%s)" % animator.playing_clip())

	controller.reparent(tile_b)
	await _frames(4)
	var kf := animator.get_kf_animator()
	check(kf != null, "after the move Doc still has a KfAnimator")
	check(animator.playing_clip() == WALK_CLIP, "after the move Doc walks (%s)" % animator.playing_clip())
	var time_before := kf.get_time(ActorAnimator.MOVEMENT_SLOT) if kf != null else -1.0
	await _frames(10)
	var time_after := kf.get_time(ActorAnimator.MOVEMENT_SLOT) if kf != null and is_instance_valid(kf) else -1.0
	check(kf != null and not is_equal_approx(time_before, time_after), "after the move the walk's clock advances (%.3f -> %.3f)" % [time_before, time_after])
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _frames(count: int) -> void:
	for i in count:
		await get_tree().physics_frame
