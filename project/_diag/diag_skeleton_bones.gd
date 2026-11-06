extends Node3D

## For a few CREA: every bone of the built actor's skeleton with its parent,
## whether the playing clip has a track for it, and the skeleton NIF's
## non-bone nodes that hang from bones.

const CREATURES := ["Rex", "VStreetCrBrahmin2"]

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	for editor_id in CREATURES:
		var base := EsmServer.find_base_by_editor_id(editor_id) as CreatureBase
		var reference := EsmServer.create_reference_for_base(base.form_id)
		var controller := EsmReferencePhysicaliser.new().physicalise(reference, self) as NpcController
		var node := controller.actor
		var done := [false, false]
		node.visual_load_completed.connect(func() -> void: done[0] = true)
		node.animation_load_completed.connect(func(_count: int) -> void: done[1] = true)
		for frame in 900:
			await get_tree().process_frame
			if done[0] and done[1]:
				break
		for frame in 10:
			await get_tree().process_frame
		var skeleton := node.find_child("Skeleton3D", true, false) as Skeleton3D
		var player := node.find_child(ActorAnimator.PLAYER_NODE_NAME, true, false) as AnimationPlayer
		var tracked := {}
		if player != null and not player.current_animation.is_empty():
			var animation := player.get_animation(player.current_animation)
			for track in animation.get_track_count():
				tracked[String(animation.track_get_path(track).get_concatenated_subnames())] = animation.track_get_type(track)
		print("== %s %s, %d bones, %d tracked" % [editor_id, base.model_path, skeleton.get_bone_count(), tracked.size()])
		for bone in skeleton.get_bone_count():
			var parent := skeleton.get_bone_parent(bone)
			var name := skeleton.get_bone_name(bone)
			print("  %3d %-28s parent %-24s %s rest %s pose %s" % [bone, name, skeleton.get_bone_name(parent) if parent >= 0 else "-", "T" if tracked.has(name) else ".",
				skeleton.get_bone_rest(bone).origin.snappedf(0.01), skeleton.get_bone_pose_position(bone).snappedf(0.01)])
		if player != null and not player.current_animation.is_empty():
			var animation := player.get_animation(player.current_animation)
			for track in animation.get_track_count():
				var bone_name := String(animation.track_get_path(track).get_concatenated_subnames())
				var bone := skeleton.find_bone(bone_name)
				if bone == -1 or animation.track_get_key_count(track) == 0:
					continue
				var key = animation.track_get_key_value(track, 0)
				var rest := skeleton.get_bone_rest(bone)
				var type := animation.track_get_type(track)
				var differs := ""
				if type == Animation.TYPE_POSITION_3D:
					differs = "pos %s vs rest %s d=%.3f" % [(key as Vector3).snappedf(0.01), rest.origin.snappedf(0.01), (key as Vector3).distance_to(rest.origin)]
				elif type == Animation.TYPE_ROTATION_3D:
					differs = "rot angle to rest %.1f deg" % rad_to_deg((key as Quaternion).angle_to(rest.basis.get_rotation_quaternion()))
				elif type == Animation.TYPE_SCALE_3D:
					differs = "scale %s rest %s" % [key, rest.basis.get_scale().snappedf(0.01)]
				print("  track %-24s %s keys %d" % [bone_name, differs, animation.track_get_key_count(track)])
		var untracked := PackedStringArray()
		for path in tracked:
			if skeleton.find_bone(path) == -1:
				untracked.append(path)
		print("  tracks naming no bone: ", untracked)
		for attachment in skeleton.find_children("*", "BoneAttachment3D", false, false):
			for child in attachment.get_children():
				if child is Node3D and child.has_meta(NifNames.META_NIF_NAME):
					print("  node %s under bone %s" % [child.get_meta(NifNames.META_NIF_NAME), (attachment as BoneAttachment3D).bone_name])
		controller.queue_free()
	get_tree().quit()
