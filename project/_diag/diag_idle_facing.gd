extends Node3D

## Physicalises Doc in his house, then compares which way his torso faces (Bip01
## Spine2's forward axis, in the controller's space, as a yaw in degrees):
## standing in locomotion, at the first frame of Chair_ForwardEnter.kf with
## Bip01 at its rest rotation (as ActorAnimator plays idles now), and the same
## with Bip01's rotation held at identity. The clip should start facing the way
## he stands.

const NifNamesScript := preload("res://GodotBryo/Servers/NifServer/nif_names.gd")

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	NpcSimulationServer.records_per_frame = 512
	NpcSimulationServer.seed()
	if not NpcSimulationServer.is_seeded:
		await NpcSimulationServer.seed_finished
	var doc := EsmServer.find_reference_by_editor_id("DocMitchellREF") as ActorReference
	NpcSimulationServer.package_runner.untrack(doc)
	var controller := EsmReferencePhysicaliser.new().physicalise(doc, self) as NpcController
	for frame in 7200:
		await get_tree().process_frame
		var player := controller.find_child(ActorAnimator.PLAYER_NODE_NAME, true, false) as AnimationPlayer
		if controller.actor.is_visual_built() and player != null and player.current_animation != "":
			break
	var skeleton := controller.find_child("Skeleton3D", true, false) as Skeleton3D
	for frame in 10:
		await get_tree().physics_frame
	print("standing in locomotion: %s" % _facing(controller, skeleton))
	var enter := EsmServer.find_base_by_editor_id("ChairFrontSit") as IdleBase
	controller.actor.animator.play_idle(enter)
	for frame in 30:
		await get_tree().physics_frame
	var player := controller.find_child(ActorAnimator.PLAYER_NODE_NAME, true, false) as AnimationPlayer
	player.pause()
	player.seek(0.0, true)
	await get_tree().physics_frame
	print("enter frame 0, Bip01 at rest rotation: %s" % _facing(controller, skeleton))
	var bip := skeleton.find_bone("Bip01")
	var animation := player.get_animation(ActorAnimator.IDLE_CLIP_NAME)
	var track := animation.add_track(Animation.TYPE_ROTATION_3D)
	animation.track_set_path(track, NodePath("%s:Bip01" % skeleton.get_parent().get_path_to(skeleton)))
	animation.track_set_path(track, NodePath("%s:Bip01" % player.get_node(player.root_node).get_path_to(skeleton)))
	animation.rotation_track_insert_key(track, 0.0, Quaternion.IDENTITY)
	player.seek(0.0, true)
	await get_tree().physics_frame
	print("enter frame 0, Bip01 rotation identity: %s" % _facing(controller, skeleton))
	player.seek(animation.length, true)
	await get_tree().physics_frame
	print("enter last frame, Bip01 rotation identity: %s" % _facing(controller, skeleton))
	get_tree().quit()

func _facing(controller: NpcController, skeleton: Skeleton3D) -> String:
	var parts := []
	for bone_name in ["Bip01 Spine2", "Bip01 Head"]:
		var bone := skeleton.find_bone(NifNamesScript.escape(bone_name))
		var global := skeleton.global_transform * skeleton.get_bone_global_pose(bone)
		var local := controller.global_transform.basis.inverse() * global.basis
		var parts_axes := []
		for axis in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
			var v: Vector3 = local * axis
			parts_axes.append("%.0f" % rad_to_deg(atan2(v.x, v.z)) if Vector2(v.x, v.z).length() > 0.5 else "vertical")
		parts.append("%s yaw of x/y/z axes %s" % [bone_name, parts_axes])
	return "; ".join(parts)
