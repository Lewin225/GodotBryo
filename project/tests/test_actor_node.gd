extends Node3D

## What the actor node builds for Doc Mitchell (DocMitchellREF): skeleton,
## skinned body and head parts, facial attachments, equipment and locomotion
## animation. The expected numbers are the node's output before stage C of
## Plans/Actors split it into child nodes; every step of that split must
## reproduce them.

const EXPECTED := {
	"bones": 65,
	"meshes": 58,
	"skin_bound_meshes": 49,
	"nude_body_meshes": 25,
	"skinned_head_meshes": 2,
	"facial_attached_meshes": 8,
	"equipment_meshes": 22,
	"hair_variant_meshes": 2,
	"dismember_partitions": 49,
	"animation_clips": 121,
}

var failures := 0

## With the ragdoll off, no PhysicalBone3D hitbox is in a physics space; on,
## every one is.
func _check_hitboxes(node: EsmActorNode) -> void:
	var bones := node.find_children("*", "PhysicalBone3D", true, false)
	check(not bones.is_empty() and bones.all(func(bone: PhysicalBone3D) -> bool: return not _in_space(bone)), "with the ragdoll off, none of Doc's %d hitboxes is in the physics space" % bones.size())
	node.ragdoll_simulator_enabled = true
	check(bones.all(func(bone: PhysicalBone3D) -> bool: return _in_space(bone)), "with the ragdoll on, all of them are")
	node.ragdoll_simulator_enabled = false

func _in_space(bone: PhysicalBone3D) -> bool:
	return PhysicsServer3D.body_get_space(bone.get_rid()).is_valid()

func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1

func _ready() -> void:
	var esm_server = get_node("/root/EsmServer")
	if not esm_server.is_ready():
		await esm_server.esm_ready
	var doc: EsmReference = esm_server.find_reference_by_editor_id("DocMitchellREF")
	var controller := EsmReferencePhysicaliser.new().physicalise(doc, self) as NpcController
	check(controller != null and EsmNode.node_for(doc) == controller, "Doc is physicalised as an NpcController, the node registered for him")
	var node: EsmActorNode = controller.actor
	var visual_done := [false]
	var animation_clips := [-1]
	node.visual_load_completed.connect(func() -> void: visual_done[0] = true)
	node.animation_load_completed.connect(func(count: int) -> void: animation_clips[0] = count)
	for frame in 3000:
		await get_tree().process_frame
		if visual_done[0] and animation_clips[0] >= 0 and _equipment_settled(node):
			break
	check(visual_done[0], "Doc's visual load completes")
	var measured := _measure(node, animation_clips[0])
	print("       measured ", measured)
	for key: String in EXPECTED:
		var expected: int = EXPECTED[key]
		check(measured[key] == expected, "%s: %d (expected %d)" % [key, measured[key], expected])
	var player := node.find_child("LocomotionAnimationPlayer", true, false) as AnimationPlayer
	check(player != null and player.current_animation == "locomotion__mtidle.kf", "the idle clip plays (%s)" % (player.current_animation if player != null else "no player"))
	_check_hitboxes(node)
	await _check_motion(node, player)
	await _check_creature(esm_server)
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)

## The animator follows the node's ActorMotion: each motion state plays its
## clip after a physics frame.
func _check_motion(node: EsmActorNode, player: AnimationPlayer) -> void:
	if node == null or player == null:
		check(false, "Doc has an actor node and an animation player for the motion checks")
		return
	var motion := ActorMotion.new()
	node.motion = motion
	var cases := [
		[Vector3(0.0, 0.0, -3.0), 0.0, true, "locomotion__male__mtfastforward.kf"],
		[Vector3(0.0, 0.0, 1.2), 0.0, false, "locomotion__male__mtbackward.kf"],
		[Vector3(-1.2, 0.0, 0.0), 0.0, false, "locomotion__male__mtleft.kf"],
		[Vector3(3.0, 0.0, -0.5), 0.0, true, "locomotion__male__mtfastright.kf"],
		[Vector3.ZERO, 2.0, false, "locomotion__mtturnleft.kf"],
		[Vector3.ZERO, -2.0, false, "locomotion__mtturnright.kf"],
		[Vector3.ZERO, 0.0, false, "locomotion__mtidle.kf"],
	]
	for case in cases:
		motion.velocity = case[0]
		motion.turn_rate = case[1]
		motion.running = case[2]
		await get_tree().physics_frame
		await get_tree().physics_frame
		check(player.current_animation == case[3], "velocity %s, turn %.1f, running %s plays %s (%s)" % [case[0], case[1], case[2], case[3], player.current_animation])
	node.motion = null

func _equipment_settled(node: Node) -> bool:
	var equipment := node.get_node_or_null("ActorEquipment") as ActorEquipment
	return equipment != null and not equipment.is_loading()

func _measure(node: Node, animation_clips: int) -> Dictionary:
	var body := node.get_node_or_null("Body")
	var skeleton := body.find_child("Skeleton3D", true, false) as Skeleton3D if body != null else null
	var meshes: Array = body.find_children("*", "MeshInstance3D", true, false) if body != null else []
	var counts := {"bones": skeleton.get_bone_count() if skeleton != null else 0, "meshes": meshes.size(),
		"skin_bound_meshes": 0, "nude_body_meshes": 0, "skinned_head_meshes": 0, "facial_attached_meshes": 0,
		"equipment_meshes": 0, "hair_variant_meshes": 0, "dismember_partitions": 0, "animation_clips": animation_clips}
	for mesh: MeshInstance3D in meshes:
		if not mesh.skeleton.is_empty():
			counts["skin_bound_meshes"] += 1
		if mesh.get_meta("gamebryo_nude_body", false):
			counts["nude_body_meshes"] += 1
		if mesh.get_meta("gamebryo_equipment", false):
			counts["equipment_meshes"] += 1
		if mesh.has_meta("gamebryo_hair_variant"):
			counts["hair_variant_meshes"] += 1
		if mesh.has_meta("nif_dismember_part_id"):
			counts["dismember_partitions"] += 1
		var path := String(body.get_path_to(mesh))
		if path.contains("SkinnedHeadParts"):
			counts["skinned_head_meshes"] += 1
		if path.contains("FacialHeadAssembly"):
			counts["facial_attached_meshes"] += 1
	return counts

## A creature gets the same controller and actor node. CreatureBase lists no model parts until the
## actors plan's stage J, so Rex (CREA 0x118E71) builds his skeleton and
## nothing else.
func _check_creature(esm_server) -> void:
	var rex: EsmReference = esm_server.create_reference_for_base(0x118E71)
	var controller := EsmReferencePhysicaliser.new().physicalise(rex, self) as NpcController
	check(controller != null and controller.actor != null, "a CreatureReference is physicalised as an NpcController with an EsmActorNode")
	if controller == null or controller.actor == null:
		return
	var node := controller.actor
	var finished := [false]
	node.visual_load_completed.connect(func() -> void: finished[0] = true)
	node.visual_load_failed.connect(func(_reason: String) -> void: finished[0] = true)
	for frame in 600:
		await get_tree().process_frame
		if finished[0]:
			break
	var body := node.get_node_or_null("Body")
	var skeleton := body.find_child("Skeleton3D", true, false) as Skeleton3D if body != null else null
	check(skeleton != null and skeleton.get_bone_count() > 0, "Rex's skeleton is built (%d bones)" % (skeleton.get_bone_count() if skeleton != null else 0))
	controller.queue_free()
