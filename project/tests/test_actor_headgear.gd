extends Node3D

## Headgear on GoodspringsSettler04Ref (CowboyHat3, an unskinned NIF on the
## Hat slot): the hair shows its Hat variant, and the hat hangs from a bone
## attachment under the skeleton and turns with the head while the head tracks
## a look target.

const MAX_DEGREES_OFF_HEAD := 1.0
const TRACKING_SECONDS := 3.0

var failures := 0

func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var reference := EsmServer.find_reference_by_editor_id("GoodspringsSettler04Ref") as ActorReference
	var controller := EsmReferencePhysicaliser.new().physicalise(reference, self) as NpcController
	var node: EsmActorNode = controller.actor
	var done := [false]
	node.visual_load_completed.connect(func() -> void: done[0] = true)
	for frame in 3000:
		await get_tree().process_frame
		if done[0] and not node.equipment.is_loading():
			break
	var skeleton := node.find_child("Skeleton3D", true, false) as Skeleton3D
	_check_hair_variant(node)
	var attachments := node.find_children("EquipmentAttachment_*", "BoneAttachment3D", true, false)
	check(attachments.size() == 1, "one equipment attachment, for the hat (%d)" % attachments.size())
	if attachments.size() != 1:
		_finish()
		return
	var hat := attachments[0] as BoneAttachment3D
	check(hat.get_parent() == skeleton and not hat.use_external_skeleton, "the hat's attachment is a child of the skeleton")
	check(hat.bone_name == "HeadAnims", "it follows HeadAnims (%s)" % hat.bone_name)
	_place_look_target(reference, node)
	var worst := await _worst_degrees_off_bone(skeleton, hat)
	check(worst < MAX_DEGREES_OFF_HEAD, "while the head tracks a target to the side, the hat stays within %.1f deg of the posed head (%.1f deg)" % [MAX_DEGREES_OFF_HEAD, worst])
	reference.look_target = null
	_finish()

## Wearing a Hat-slot item, only the hair's Hat variant is visible.
func _check_hair_variant(node: EsmActorNode) -> void:
	check(node.wearing_hat, "wearing a Hat-slot item sets wearing_hat")
	var hat_visible := node.hair_hat_meshes.filter(func(mesh: MeshInstance3D) -> bool: return mesh.visible)
	var no_hat_visible := node.hair_no_hat_meshes.filter(func(mesh: MeshInstance3D) -> bool: return mesh.visible)
	check(not node.hair_hat_meshes.is_empty() and hat_visible.size() == node.hair_hat_meshes.size(), "the Hat hair is visible (%d of %d)" % [hat_visible.size(), node.hair_hat_meshes.size()])
	check(no_hat_visible.is_empty(), "the NoHat hair is hidden (%d visible)" % no_hat_visible.size())

## Places the player's reference 2 m to the actor's side and makes it the
## actor's look target.
func _place_look_target(reference: ActorReference, node: EsmActorNode) -> void:
	var player := EsmServer.get_player_reference()
	var side := node.global_transform.basis.x.normalized() * 2.0
	player.current_space_form_id = reference.current_space_form_id
	player.position = EsmReferencePhysicaliser.GAMEBRYO_TO_GODOT_BASIS.inverse() * (node.global_position + side)
	reference.look_target = player

## The largest angle between `attachment` and its bone's pose as posed with
## modifiers (read in skeleton_updated), over TRACKING_SECONDS.
func _worst_degrees_off_bone(skeleton: Skeleton3D, attachment: BoneAttachment3D) -> float:
	var bone := skeleton.find_bone(attachment.bone_name)
	var posed := [Basis()]
	var record := func() -> void:
		posed[0] = (skeleton.global_transform * skeleton.get_bone_global_pose(bone)).basis
	skeleton.skeleton_updated.connect(record)
	var worst := 0.0
	var until := Time.get_ticks_msec() + int(TRACKING_SECONDS * 1000.0)
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame
		var pose := (posed[0] as Basis).orthonormalized().get_rotation_quaternion()
		var actual := attachment.global_basis.orthonormalized().get_rotation_quaternion()
		worst = maxf(worst, rad_to_deg(actual.angle_to(pose)))
	skeleton.skeleton_updated.disconnect(record)
	return worst

func _finish() -> void:
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
