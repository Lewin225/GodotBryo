extends Node

const ActorAnimationComponentScript := preload("res://gamebryo/actor_animation_component.gd")

# Issue #52 follow-up: real-data verification that NPCActor wires:
# 1. A real LocomotionAnimationPlayer holding EVERY real .kf found under
#    characters\_male\locomotion\ (not a hand-picked subset -- NOT
#    self-contained embedded animation either, see nif_loader.cpp's own
#    extract_sequence() doc comment for the real bare-NiControllerSequence
#    shape this required a native fix for), each under its own real
#    relative path as its clip name (no remapping to invented aliases).
# 2. No generated AnimationTree is created yet: imported clips remain
#    directly inspectable/playable through AnimationPlayer while the real
#    partial-body animation behavior is being resolved.

const DATA_DIR := "../fresh_nv_copy/Data/"

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func has_blend_shape(mesh: ArrayMesh, target_name: String) -> bool:
	if mesh == null:
		return false
	for i in mesh.get_blend_shape_count():
		if mesh.get_blend_shape_name(i) == target_name:
			return true
	return false

func blend_shape_index(mesh: ArrayMesh, target_name: String) -> int:
	if mesh == null:
		return -1
	for i in mesh.get_blend_shape_count():
		if mesh.get_blend_shape_name(i) == target_name:
			return i
	return -1

func _ready() -> void:
	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened FalloutNV.esm")

	var resolver := GamebryoMeshResolver.new()
	var registry := GamebryoObjectRegistry.new(resolver, esm)

	var placement: Dictionary = esm.get_actor_by_form_id(0x00104C0C) # Doc Mitchell
	check(not placement.is_empty(), "resolved Doc Mitchell directly by FormID")

	var node: NPCActor = registry.build(placement)
	check(node != null and node is NPCActor, "registry built a real NPCActor")
	if node == null:
		_finish()
		return
	add_child(node)
	var render_meshes := node.find_children("*", "MeshInstance3D", true, false)
	check(not render_meshes.is_empty(), "actor has generated render meshes for possession-mode testing")
	var original_shadow_setting := int((render_meshes[0] as MeshInstance3D).cast_shadow) if not render_meshes.is_empty() else -1
	node.possessed_first_person = true
	var possession_applied := true
	for render_mesh in render_meshes:
		if (render_mesh as MeshInstance3D).cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY:
			possession_applied = false
	check(possession_applied, "possessed_first_person makes actor meshes shadow-only")
	node.possessed_first_person = false
	check(render_meshes.is_empty() or int((render_meshes[0] as MeshInstance3D).cast_shadow) == original_shadow_setting, "possession mode restores authored mesh shadow settings")
	var face_gen: FaceGenData = node.npc_record.face_gen if node.npc_record != null else null
	check(face_gen != null and face_gen.geometry_applied, "Doc Mitchell applies FaceGen geometry to the head")
	check(face_gen != null and face_gen.geometry_asset_path.ends_with("headhuman.egm"), "Doc Mitchell uses the real human EGM basis")
	check(face_gen != null and face_gen.geometry_applied_vertex_count == 1211 and face_gen.geometry_applied_mode_count == 80, "FaceGen application matches the real head vertex and mode counts")
	var head_meshes := node.find_children("*", "MeshInstance3D", true, false)
	var found_head := false
	for child in head_meshes:
		if String(child.get_meta("gamebryo_model_path", "")).to_lower().contains("characters\\head\\headhuman"):
			var head_mesh: ArrayMesh = child.mesh
			found_head = head_mesh != null and head_mesh.surface_get_material(0) != null
			check(found_head and head_mesh.get_blend_shape_count() == 38, "human head exposes all 38 named TRI blend shapes")
			if found_head:
				var head_arrays := head_mesh.surface_get_arrays(0)
				check(head_arrays[Mesh.ARRAY_BONES] != null and not (head_arrays[Mesh.ARRAY_BONES] as PackedInt32Array).is_empty(), "human head retains ARRAY_BONES")
				check(head_arrays[Mesh.ARRAY_WEIGHTS] != null and not (head_arrays[Mesh.ARRAY_WEIGHTS] as PackedFloat32Array).is_empty(), "human head retains ARRAY_WEIGHTS")
				for blend_index in head_mesh.get_blend_shape_count():
					check(head_mesh.get_blend_shape_name(blend_index) != "", "human TRI morph %d retains its authored name" % blend_index)
			break
	check(found_head, "FaceGen-built NPC contains a real human head mesh")
	var skeleton: Skeleton3D = node.get_node_or_null(^"Body/Skeleton3D")
	var facial_attachment := node.get_node_or_null(^"Body/Skeleton3D/FacialHeadAssembly")
	check(facial_attachment is BoneAttachment3D, "facial head parts use a real BoneAttachment3D")
	check(facial_attachment is BoneAttachment3D and (facial_attachment as BoneAttachment3D).bone_name == "HeadAnims", "facial attachment follows the real HeadAnims bone")
	for required_part in ["mouthhuman.nif", "teethlowerhuman.nif", "teethupperhuman.nif", "tonguehuman.nif", "eyelefthuman.nif", "eyerighthuman.nif"]:
		var found_part := false
		for child in head_meshes:
			if String(child.get_meta("gamebryo_model_path", "")).to_lower().ends_with("characters\\head\\" + required_part):
				found_part = true
				check(facial_attachment != null and child.get_parent() == facial_attachment, "%s is spatially attached to the facial assembly" % required_part)
				break
		check(found_part, "unskinned head component is assembled: %s" % required_part)
	var facial := node.get_facial_controller()
	check(facial != null, "NPC has a separate facial animation controller")
	check(facial != null and facial.get_animation_player() != null, "NPC has a separate FacialAnimationPlayer layer")
	check(facial != null and facial.has_morph("Aah") and facial.has_morph("Happy"), "human facial controller exposes real phoneme and expression targets")
	check(facial != null and facial.set_phoneme("Aah", 1.0), "human phoneme target accepts a runtime weight")
	for morph_part in [{"file": "mouthhuman.nif", "count": 5, "name": "Aah"}, {"file": "teethlowerhuman.nif", "count": 12, "name": "Aah"}, {"file": "tonguehuman.nif", "count": 8, "name": "Aah"}]:
		for child in head_meshes:
			if String(child.get_meta("gamebryo_model_path", "")).to_lower().ends_with("characters\\head\\" + morph_part["file"]):
				var part_mesh := child.mesh as ArrayMesh
				check(part_mesh != null and part_mesh.get_blend_shape_count() == morph_part["count"], "%s exposes all authored TRI blend shapes" % morph_part["file"])
				check(has_blend_shape(part_mesh, morph_part["name"]), "%s exposes the shared '%s' facial channel" % [morph_part["file"], morph_part["name"]])
				break
	check(facial != null and facial.set_expression("Happy", 0.5), "human expression target accepts a runtime weight")
	check(facial != null and facial.animate_morph("Aah", 0.8, 0.1), "human facial layer can animate a real TRI target")
	check(facial != null and facial.get_animation_player().name == "FacialAnimationPlayer", "human facial layer has the reserved authored-animation player")
	check(facial == null or not facial.supports_blink(), "blink remains unavailable until a real eyelid source is verified")
	check(facial == null or not facial.blink(), "blink has no visibility fallback when no authored eyelid morph exists")
	if facial != null:
		facial.clear_weights()

	var player: AnimationPlayer = node.get_node_or_null(^"Body/LocomotionAnimationPlayer")
	check(player != null, "a real LocomotionAnimationPlayer was built")
	if player == null:
		_finish()
		return

	# Real data: Doc Mitchell is male -- every real clip under
	# characters\_male\locomotion\ should be loaded, plus only the equipped
	# weapon family -- not every weapon family in the game.
	check(player.get_animation_list().size() > 20 and player.get_animation_list().size() < 150, "actor loads base locomotion plus a bounded equipped-family library (got %d)" % player.get_animation_list().size())
	for clip_name in ["mtidle.kf", "male__mtforward.kf", "male__mtbackward.kf", "male__mtleft.kf", "male__mtright.kf"]:
		check(player.has_animation(clip_name), "real clip '%s' resolved under its own real name" % clip_name)
	for alias in ["locomotion_idle", "locomotion_walk_forward", "locomotion_walk_backward", "locomotion_walk_left", "locomotion_walk_right"]:
		check(player.has_animation(alias), "per-actor animation alias '%s' is registered" % alias)
	check(player.has_animation("weapon_idle"), "unarmed actor exposes a neutral weapon_idle animation alias")
	check(player.has_animation("animation_noop"), "actor exposes the stable no-op animation alias")
	for alias in ["weapon_forward", "weapon_backward", "weapon_left", "weapon_right", "weapon_attack", "weapon_reload"]:
		check(player.has_animation(alias), "unarmed actor exposes weapon alias '%s'" % alias)
	check(player.has_animation("female__mtforward.kf"), "the OTHER gender's clips are also loaded (not just Doc Mitchell's own)")

	var anim: Animation = player.get_animation("male__mtforward.kf")
	check(anim != null and anim.get_track_count() > 0, "'male__mtforward.kf' clip has real bone tracks (got %d)" % (anim.get_track_count() if anim else -1))

	check(skeleton != null, "found the real Skeleton3D")
	if skeleton != null:
		var root_has_translation := false
		for i in anim.get_track_count():
			if anim.track_get_type(i) == Animation.TYPE_POSITION_3D and String(anim.track_get_path(i)).ends_with(":Bip01"):
				root_has_translation = true
		check(root_has_translation, "real root-bone (Bip01) translation remains authored in 'male__mtforward.kf'")
		var non_accum_has_translation := false
		for i in anim.get_track_count():
			if anim.track_get_type(i) == Animation.TYPE_POSITION_3D and String(anim.track_get_path(i)).ends_with(":Bip01 NonAccum"):
				non_accum_has_translation = true
		check(non_accum_has_translation, "real NonAccum translation remains authored in 'male__mtforward.kf'")
		var kf_reader := resolver.load_nif("characters\\_male\\locomotion\\male\\mtforward.kf")
		var kf_sequences: Array = kf_reader.get_animation_sequences() if kf_reader != null else []
		check(not kf_sequences.is_empty(), "native KF decoder exposes the real mtforward sequence")
		check(not kf_sequences.is_empty() and String(kf_sequences[0].get("accum_root_name", "")) == "Bip01", "native KF decoder preserves NiControllerSequence accumRootName")
		var holster_reader := resolver.load_nif("characters\\_male\\1hmholster.kf")
		var holster_sequences: Array = holster_reader.get_animation_sequences() if holster_reader != null else []
		check(not holster_sequences.is_empty() and not holster_sequences[0].get("bool_tracks", []).is_empty(), "native KF decoder exposes the real holster NiBoolInterpolator")
		if not holster_sequences.is_empty() and not holster_sequences[0].get("bool_tracks", []).is_empty():
			var visibility_animation: Animation = resolver._build_sequence_animation(holster_sequences[0], func(_target_name: String): return NodePath("Weapon"))
			var has_visibility_track := false
			for visibility_index in visibility_animation.get_track_count():
				if visibility_animation.track_get_type(visibility_index) == Animation.TYPE_VALUE and String(visibility_animation.track_get_path(visibility_index)) == "Weapon:visible":
					has_visibility_track = true
					break
			check(has_visibility_track, "holster NiBoolInterpolator converts to a Godot Weapon:visible track")
		var non_accum_index := skeleton.find_bone("Bip01 NonAccum")
		check(non_accum_index != -1, "human skeleton contains the authored Bip01 NonAccum sibling")
		if non_accum_index != -1:
			var bind_rotation := skeleton.get_bone_rest(non_accum_index).basis.get_rotation_quaternion().normalized()
			var checked_rotation_clips := 0
			for compiled_name in player.get_animation_list():
				var compiled: Animation = player.get_animation(compiled_name)
				var non_accum_rotation_tracks := []
				for track_index in compiled.get_track_count():
					if compiled.track_get_type(track_index) == Animation.TYPE_ROTATION_3D and String(compiled.track_get_path(track_index)).ends_with(":Bip01 NonAccum"):
						non_accum_rotation_tracks.append(track_index)
				if non_accum_rotation_tracks.is_empty():
					continue
				checked_rotation_clips += 1
				var rotation_track_index: int = non_accum_rotation_tracks[0]
				check(non_accum_rotation_tracks.size() == 1, "%s has one uniform NonAccum rotation track" % compiled_name)
				check(compiled.track_get_key_count(rotation_track_index) == 1, "%s pins NonAccum rotation with one bind-pose key" % compiled_name)
				if compiled.track_get_key_count(rotation_track_index) == 1:
					var compiled_rotation: Quaternion = compiled.track_get_key_value(rotation_track_index, 0)
					check(compiled_rotation.is_equal_approx(bind_rotation), "%s NonAccum rotation key equals skeleton bind pose" % compiled_name)
			check(checked_rotation_clips > 0, "compiled locomotion library contains normalized NonAccum rotation tracks")

	check(node.get_node_or_null(^"Body/LocomotionAnimationTree") == null, "no unfinished locomotion AnimationTree is created")
	# Clothing changes must not rebuild the actor's rig. Keep a live facial
	# weight and the current animation objects across the focused refresh.
	var facial_before_refresh := node.get_facial_controller()
	var equipment_before_refresh := node.get_node_or_null(^"Body/Equipment")
	var body_before_refresh := node.get_node(^"Body")
	var skeleton_before_refresh := skeleton
	var player_before_refresh := player
	check(node.set_facial_morph("Aah", 0.25), "facial morph has a live pre-refresh weight")
	node.equipment_state = EquipmentState.new()
	check(node.get_node(^"Body") == body_before_refresh, "equipment refresh preserves the actor Body")
	check(node.get_node(^"Body/Skeleton3D") == skeleton_before_refresh, "equipment refresh preserves the actor skeleton")
	check(node.get_facial_controller() == facial_before_refresh, "equipment refresh preserves the facial controller")
	check(node.get_node(^"Body/LocomotionAnimationPlayer") == player_before_refresh, "equipment refresh preserves the locomotion AnimationPlayer")
	check(node.get_node_or_null(^"Body/LocomotionAnimationTree") == null, "equipment refresh does not create a locomotion AnimationTree")
	check(not is_instance_valid(equipment_before_refresh) and node.get_node_or_null(^"Body/Equipment") != null, "equipment refresh replaces only the Equipment subtree")
	var facial_weight_preserved := false
	for facial_mesh in node.find_children("*", "MeshInstance3D", true, false):
		var facial_array_mesh := facial_mesh.mesh as ArrayMesh
		var aah_index := blend_shape_index(facial_array_mesh, "Aah")
		if aah_index != -1:
			facial_weight_preserved = is_equal_approx(facial_mesh.get_blend_shape_value(aah_index), 0.25)
			break
	check(facial_weight_preserved, "equipment refresh preserves facial morph weights")
	var weapon_state := EquipmentState.new()
	var weapon_factory := EsmResourceFactory.new(esm)
	var weapon_record: WeaponRecord = weapon_factory.load_weapon(0x000E3778) # WeapNV9mmPistol
	check(weapon_record != null and weapon_record.editor_id == "WeapNV9mmPistol", "factory resolves a real third-person WEAP resource")
	check(weapon_record != null and weapon_record.animation_type == WeaponRecord.ANIMATION_ONE_HANDED_BALLISTIC, "WEAP.DNAM resolves the pistol animation category")
	check(weapon_record != null and weapon_record.animation_family == "1hp", "pistol category resolves to the authored 1hp family")
	check(weapon_record != null and weapon_record.base_damage == 16 and is_equal_approx(weapon_record.weight, 1.5), "WEAP.DATA uses the verified 16-bit damage and weight offsets")
	weapon_state.weapon = weapon_record
	node.equipment_state = weapon_state
	check(player.has_animation("1hpforward.kf"), "the equipped pistol family is loaded on weapon-state refresh")
	check(not player.has_animation("1hmforward.kf"), "an unrelated weapon family is not loaded")
	var weapon_mesh_found := false
	for weapon_mesh in node.find_children("*", "MeshInstance3D", true, false):
		if bool(weapon_mesh.get_meta("gamebryo_weapon", false)):
			weapon_mesh_found = true
			var weapon_attachment := weapon_mesh.get_parent()
			while weapon_attachment != null and not weapon_attachment is BoneAttachment3D:
				weapon_attachment = weapon_attachment.get_parent()
			check(weapon_attachment is BoneAttachment3D, "third-person weapon mesh is under a BoneAttachment3D")
			if weapon_attachment is BoneAttachment3D:
				check((weapon_attachment as BoneAttachment3D).get_skeleton() == skeleton, "third-person weapon attachment resolves the actor skeleton")
				check((weapon_attachment as BoneAttachment3D).bone_name == "Weapon", "third-person weapon uses the authored Weapon bone")
			break
	check(weapon_mesh_found, "a real third-person weapon model is attached")
	var weapon_controller_player := node.find_child("DirectControllerAnimationPlayer", true, false) as AnimationPlayer
	check(weapon_controller_player != null and weapon_controller_player.has_animation("embedded"), "weapon NIF direct controllers produce a local animation player")
	var animation_component: Node = node.get_node(^"ActorAnimationComponent")
	check(animation_component.request_action(ActorAnimationComponentScript.ActorAction.EQUIP), "third-person weapon equip action resolves through ActorAnimationComponent")
	check(player.current_animation == "1hpequip.kf", "third-person weapon equip selects the exact authored family clip")
	var bipl_weapon: WeaponRecord = weapon_factory.load_weapon(0x00176E5A) # WeapPowerFistVeronica
	check(bipl_weapon != null and bipl_weapon.biped_model_list != null and not bipl_weapon.biped_model_list.entries.is_empty(), "factory resolves a real WEAP.BIPL equipped model list")
	var bipl_state := EquipmentState.new()
	bipl_state.weapon = bipl_weapon
	node.equipment_state = bipl_state
	var bipl_mesh_found := false
	for bipl_mesh in node.find_children("*", "MeshInstance3D", true, false):
		if bool(bipl_mesh.get_meta("gamebryo_weapon", false)):
			bipl_mesh_found = true
			check(String(bipl_mesh.get_meta("gamebryo_equipment_model_field", "")) == "BIPL", "WEAP.BIPL model is used for the equipped visual when present")
			break
	check(bipl_mesh_found, "a real BIPL weapon model is attached")
	# --- Real playback behavior: process a few frames and confirm the leg
	# pose actually changes over time while playing forward, proving the
	# AnimationPlayer directly drives the skeleton.
	player.play("male__mtforward.kf")
	await get_tree().process_frame
	await get_tree().process_frame
	var thigh_idx := skeleton.find_bone("Bip01 L Thigh") if skeleton != null else -1
	var pose_a := skeleton.get_bone_pose_rotation(thigh_idx) if thigh_idx != -1 else Quaternion.IDENTITY
	for i in 10:
		await get_tree().process_frame
	var pose_b := skeleton.get_bone_pose_rotation(thigh_idx) if thigh_idx != -1 else Quaternion.IDENTITY
	check(thigh_idx != -1 and not pose_a.is_equal_approx(pose_b), "the leg's actual bone pose changes over time while 'forward' plays (real animation, not a static parameter)")

	var raul_placement: Dictionary = esm.get_actor_by_form_id(0x000E60EF)
	var raul: NPCActor = registry.build(raul_placement)
	check(raul != null and raul.npc_record != null and raul.npc_record.face_gen.geometry_applied, "Raul applies FaceGen geometry to the ghoul head")
	check(raul != null and raul.npc_record.face_gen.geometry_asset_path.ends_with("headghoul.egm"), "Raul uses the real ghoul EGM basis")
	if raul != null:
		var ghoul_facial := raul.get_facial_controller()
		check(ghoul_facial != null and ghoul_facial.has_morph("Aah") and ghoul_facial.has_morph("Sad"), "ghoul facial controller exposes real phoneme and expression targets")
		check(ghoul_facial != null and ghoul_facial.set_phoneme("Aah", 1.0), "ghoul phoneme target accepts a runtime weight")
		check(ghoul_facial != null and ghoul_facial.set_expression("Sad", 0.5), "ghoul expression target accepts a runtime weight")
		for child in raul.find_children("*", "MeshInstance3D", true, false):
			if String(child.get_meta("gamebryo_model_path", "")).to_lower().ends_with("characters\\head\\headghoul.nif"):
				var ghoul_mesh: ArrayMesh = child.mesh
				check(ghoul_mesh != null and ghoul_mesh.get_blend_shape_count() == 38, "ghoul head exposes all 38 named TRI blend shapes")
				if ghoul_mesh != null:
					var ghoul_arrays := ghoul_mesh.surface_get_arrays(0)
					check(ghoul_arrays[Mesh.ARRAY_BONES] != null and not (ghoul_arrays[Mesh.ARRAY_BONES] as PackedInt32Array).is_empty(), "ghoul head retains ARRAY_BONES")
					check(ghoul_arrays[Mesh.ARRAY_WEIGHTS] != null and not (ghoul_arrays[Mesh.ARRAY_WEIGHTS] as PackedFloat32Array).is_empty(), "ghoul head retains ARRAY_WEIGHTS")
					break

	var hair_placement: Dictionary = esm.get_actor_by_form_id(0x0017B586) # NVProspectorFemaleT
	var hair_npc: NPCActor = registry.build(hair_placement)
	check(hair_npc != null and hair_npc.npc_record != null and hair_npc.npc_record.hair != null, "hair fixture builds with a resolved HairRecord")
	if hair_npc != null and hair_npc.npc_record != null and hair_npc.npc_record.hair != null:
		var hair_model := hair_npc.npc_record.hair.model_path.to_lower()
		var found_hair := false
		for child in hair_npc.find_children("*", "MeshInstance3D", true, false):
			if String(child.get_meta("gamebryo_model_path", "")).to_lower() == hair_model:
				found_hair = true
				check(child.transform.is_equal_approx(Transform3D.IDENTITY), "hair mesh uses HeadAnims attachment space without a duplicate NIF orientation")
				break
		check(found_hair, "hair fixture assembles the resolved HAIR model")
		check(hair_npc.hair_no_hat_meshes.size() > 0, "hair fixture tracks the authored Nohat mesh")
		check(hair_npc.hair_hat_meshes.size() > 0, "hair fixture tracks the authored Hat mesh")
		for mesh in hair_npc.hair_no_hat_meshes:
			check(mesh.visible, "Nohat hair is visible by default")
		for mesh in hair_npc.hair_hat_meshes:
			check(not mesh.visible, "Hat hair is hidden by default")
		hair_npc.wearing_hat = true
		for mesh in hair_npc.hair_no_hat_meshes:
			check(not mesh.visible, "Nohat hair hides when wearing_hat is enabled")
		for mesh in hair_npc.hair_hat_meshes:
			check(mesh.visible, "Hat hair shows when wearing_hat is enabled")
		hair_npc.wearing_hat = false
		check(hair_npc.gore_meshes.size() > 0, "hair fixture tracks the authored gore-cap meshes")
		for mesh in hair_npc.gore_meshes:
			check(not mesh.visible, "gore-cap meshes are hidden by default")
		hair_npc.show_gore = true
		for mesh in hair_npc.gore_meshes:
			check(mesh.visible, "gore-cap meshes can be explicitly shown")
		hair_npc.show_gore = false
		var found_eye := false
		for child in hair_npc.find_children("*", "MeshInstance3D", true, false):
			var model := String(child.get_meta("gamebryo_model_path", "")).to_lower()
			if model.contains("characters\\head\\eyelefthuman") or model.contains("characters\\head\\eyerighthuman"):
				found_eye = true
				break
		check(found_eye, "hair fixture assembles a real eye head component")
	var hair_facial := hair_npc.get_facial_controller() if hair_npc != null else null
	check(hair_facial != null and hair_facial.has_morph("Aah"), "female hair fixture exposes the shared Aah channel")
	if hair_facial != null:
		hair_facial.set_phoneme("Aah", 1.0)
		for facial_file in ["headfemale.nif", "mouthhuman.nif", "teethlowerhuman.nif", "tonguehuman.nif"]:
			for child in hair_npc.find_children("*", "MeshInstance3D", true, false):
				if String(child.get_meta("gamebryo_model_path", "")).to_lower().ends_with("characters\\head\\" + facial_file):
					var facial_mesh := child.mesh as ArrayMesh
					var aah_index := blend_shape_index(facial_mesh, "Aah")
					check(aah_index != -1 and is_equal_approx(child.get_blend_shape_value(aah_index), 1.0), "%s receives the female fixture Aah weight" % facial_file)
					break
		hair_facial.clear_weights()

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)

func _finish() -> void:
	print("=======================")
	print("FAILURES: ", failures)
	get_tree().quit(1)
