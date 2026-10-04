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

func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1

func _ready() -> void:
	var esm_server = get_node("/root/EsmServer")
	if not esm_server.is_ready():
		await esm_server.esm_ready
	var doc: EsmReference = esm_server.find_reference_by_editor_id("DocMitchellREF")
	var node: EsmNode = EsmReferencePhysicaliser.new().physicalise(doc, self)
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
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)

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
