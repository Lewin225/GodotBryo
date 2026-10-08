extends Node3D

## Physicalises Doc Mitchell in his house and, for each IDLE named on the
## command line, plays it (ActorIdles) and reports the pelvis's height above
## the actor's origin over the clip, against standing; the torso's yaw
## (ActorAnimator._torso_yaw) and the root bones' local yaws over the clip; and
## the body's heading before and after.

const FRAMES := 2400

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	NpcSimulationServer.records_per_frame = 512
	NpcSimulationServer.seed()
	if not NpcSimulationServer.is_seeded:
		await NpcSimulationServer.seed_finished
	ScriptServer.player_reference = EsmServer.get_player_reference()
	var doc := EsmServer.find_reference_by_editor_id("DocMitchellREF") as ActorReference
	NpcSimulationServer.package_runner.untrack(doc)
	NpcSimulationServer.local_navigation.set_local_cells(doc.current_space_form_id, PackedInt32Array([doc.current_space_form_id]))
	var node := EsmReferencePhysicaliser.new().physicalise(doc, self) as NpcController
	for frame in FRAMES:
		if node.actor != null and node.actor.is_visual_built() and node.actor.animator.is_loaded():
			break
		await get_tree().process_frame
	for frame in 60:
		await get_tree().process_frame
	var skeleton := node.actor.find_child("Skeleton3D", true, false) as Skeleton3D
	print("standing: pelvis %.3f m above the origin; torso yaw %.0f; NonAccum yaw %.0f" % [_pelvis_height(node, skeleton), rad_to_deg(node.actor.animator._torso_yaw()), _bone_yaw(skeleton, "Bip01 NonAccum")])
	for editor_id in OS.get_cmdline_user_args():
		var idle := EsmServer.find_base_by_editor_id(editor_id) as IdleBase
		var heading_before := node.rotation.y
		ScriptServer.actor_idles.play(doc, idle)
		var low := INF
		var high := -INF
		var yaw_low := INF
		var yaw_high := -INF
		var root_yaws := {}
		var deadline := Time.get_ticks_msec() + 20000
		while doc.special_idle == idle and Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
			var height := _pelvis_height(node, skeleton)
			low = minf(low, height)
			high = maxf(high, height)
			var yaw := rad_to_deg(node.actor.animator._torso_yaw())
			yaw_low = minf(yaw_low, yaw)
			yaw_high = maxf(yaw_high, yaw)
			root_yaws["%.0f/%.0f" % [_bone_yaw(skeleton, "Bip01"), _bone_yaw(skeleton, "Bip01 NonAccum")]] = true
		ScriptServer.actor_idles.finish(doc)
		print("%s (section %d, %s): pelvis %.3f to %.3f m; torso yaw %.0f to %.0f; Bip01/NonAccum yaws %s; heading turned %.0f degrees" % [editor_id, idle.animation_group_section & IdleBase.SECTION_MASK, idle.model_path.get_file(), low, high, yaw_low, yaw_high, ", ".join(PackedStringArray(root_yaws.keys().slice(0, 6))), rad_to_deg(angle_difference(heading_before, node.rotation.y))])
		for frame in 30:
			await get_tree().process_frame
	get_tree().quit()

## The yaw (degrees, about the skeleton's up axis) of a bone's local pose.
func _bone_yaw(skeleton: Skeleton3D, bone_name: String) -> float:
	var bone := skeleton.find_bone(bone_name)
	var forward := skeleton.get_bone_pose_rotation(bone) * Vector3.FORWARD
	return rad_to_deg(atan2(-forward.x, -forward.z))

func _pelvis_height(node: Node3D, skeleton: Skeleton3D) -> float:
	var bone := skeleton.find_bone("Bip01 Pelvis")
	var pelvis := skeleton.global_transform * skeleton.get_bone_global_pose(bone)
	return pelvis.origin.y - node.global_position.y
