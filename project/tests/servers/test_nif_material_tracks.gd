extends Node

## NifServer's material tracks: an NiAlphaController float link on a shape in
## a NIF's own sequences becomes a value track on the shape's `nif_alpha`
## instance uniform (`<shape's node path>:instance_shader_parameters/nif_alpha`,
## NifTreeBuilder._make_animation()), and playing the
## sequence sets that uniform on the shape's MeshInstance3D, not on its shared
## material. The NIF's own sequences also carry its NiVisController
## visibility, built by the same NifAnimationConverter as KFs. The Tops sign
## lights' sequences hold only material emissive colour (SELF_ILLUM) and
## emittance multiplier links: they become Color and float tracks on the
## shapes' nif_emissive and nif_emit_mult, each shape starts at its
## NiMaterialProperty values, and KfAnimator writes the Color track. A KF's
## material links build tracks too, its compressed B-spline colours and
## multipliers resampled into keys (1hpattack3.kf).

## The Fat Man explosion: GlowFloat:0's alpha is keyed over the sequence.
const EXPLOSION := "meshes/effects/explosionlarge01.nif"
const SHAPE := "GlowFloat:0"
const ALPHA_SUFFIX := ":instance_shader_parameters/nif_alpha"
## A Freeside sign: Line01:0's base map scrolls in U (NiTextureTransformController,
## controller ID 0-0-TT_TRANSLATE_U).
const SIGN := "meshes/architecture/freeside/nv_freesidesign-large_lights.nif"
const SIGN_SHAPE := "Line01:0"
const UV_OFFSET_U_SUFFIX := ":instance_shader_parameters/nif_uv_offset_u"
## TheTopsSignLights's model: Forward, Left, Backward and Right, all material
## emissive colour and emittance multiplier links (22 each).
const TOPS_LIGHTS := "meshes/architecture/strip/nv_thetops-sign_lights.nif"
const TOPS_SHAPE := "Neon:1"
const EMISSIVE_SUFFIX := ":instance_shader_parameters/nif_emissive"
const EMIT_MULT_SUFFIX := ":instance_shader_parameters/nif_emit_mult"
## A first-person attack KF: SELF_ILLUM colour on NiBSplineCompPoint3Interpolators
## and emittance on NiBSplineCompFloatInterpolators.
const ATTACK_KF := "meshes/characters/_1stperson/1hpattack3.kf"
const NifAnimationBuilderScript := preload("res://GodotBryo/Servers/NifServer/nif_animation_builder.gd")
const NifTreeBuilderScript := preload("res://GodotBryo/Servers/NifServer/nif_tree_builder.gd")
const NifObjectAnimatorScript := preload("res://GodotBryo/Servers/NifServer/nif_object_animator.gd")

var failures := 0
var _tree: Node3D = null
var _sign: Node3D = null


func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1


func _ready() -> void:
	NifServer.request(EXPLOSION, self, _on_tree)
	for i in 600:
		if _tree != null:
			break
		await get_tree().process_frame
	check(_tree != null, "%s delivered" % EXPLOSION)
	if _tree == null:
		_finish()
		return
	add_child(_tree)

	var player := _tree.find_child("AnimationPlayer", true, false) as AnimationPlayer
	check(player != null and player.get_animation_list().size() == 1, "the explosion has one sequence")
	if player == null or player.get_animation_list().is_empty():
		_finish()
		return
	var clip := String(player.get_animation_list()[0])
	var animation := player.get_animation(clip)
	var escaped := NifNames.escape(SHAPE)
	var track := _track_ending(animation, escaped + ALPHA_SUFFIX)
	check(track != -1, "%s has a .../%s%s track" % [clip, escaped, ALPHA_SUFFIX])
	if track == -1:
		_finish()
		return
	check(animation.track_get_key_count(track) > 1, "the alpha is keyed over time (%d keys)" % animation.track_get_key_count(track))
	# The NIF's own sequences share NifAnimationConverter with KFs, so its
	# NiVisController links are visibility tracks too (FireBallGeo's).
	var visibility := _track_ending(animation, NifNames.escape("FireBallGeo") + ":visible")
	check(visibility != -1, "the NIF's own sequence has FireBallGeo's visibility track")

	# Seek to a key whose value is not 1 and read the uniform back.
	var key := _key_not_one(animation, track)
	check(key != -1, "a key's alpha differs from 1")
	var mesh := _mesh(_tree, SHAPE)
	check(mesh != null, "%s is a MeshInstance3D in the tree" % SHAPE)
	if key != -1 and mesh != null:
		var time := animation.track_get_key_time(track, key)
		var expected := float(animation.track_get_key_value(track, key))
		player.play(clip)
		player.seek(time, true)
		var actual := float(mesh.get_instance_shader_parameter("nif_alpha"))
		check(is_equal_approx(actual, expected),
			"seeking to %.2f s sets nif_alpha to %.3f (got %.3f)" % [time, expected, actual])
		check(mesh.get_surface_override_material(0) == null, "the shared material is kept")
	await _check_texture_transform()
	await _check_emission()
	_check_kf_material_tracks()
	_finish()


## The sign's U scroll is a track on the shape's nif_uv_offset_u, and
## seeking sets that component.
func _check_texture_transform() -> void:
	NifServer.request(SIGN, self, func(tree: Node3D) -> void: _sign = tree)
	for i in 600:
		if _sign != null:
			break
		await get_tree().process_frame
	check(_sign != null, "%s delivered" % SIGN)
	if _sign == null:
		return
	add_child(_sign)
	var player := _sign.find_child("AnimationPlayer", true, false) as AnimationPlayer
	check(player != null and not player.get_animation_list().is_empty(), "the sign has a sequence")
	if player == null or player.get_animation_list().is_empty():
		return
	var clip := String(player.get_animation_list()[0])
	var animation := player.get_animation(clip)
	var track := _track_ending(animation, NifNames.escape(SIGN_SHAPE) + UV_OFFSET_U_SUFFIX)
	check(track != -1, "%s has a %s U-offset track" % [clip, SIGN_SHAPE])
	var mesh := _mesh(_sign, SIGN_SHAPE)
	if track == -1 or mesh == null:
		return
	# Mid-clip: a looping clip wraps a seek to its length back to 0.
	var time := animation.length * 0.37
	var expected := float(animation.value_track_interpolate(track, time))
	check(not is_zero_approx(expected), "the offset at %.2f s is not 0 (%.3f)" % [time, expected])
	player.play(clip)
	player.seek(time, true)
	var offset := float(mesh.get_instance_shader_parameter("nif_uv_offset_u"))
	check(is_equal_approx(offset, expected),
		"seeking to %.2f s sets nif_uv_offset_u to %.3f (got %.3f)" % [time, expected, offset])


## The Tops sign lights: emissive and emittance tracks, the material's values
## at build, and a played group writing a Color to nif_emissive.
func _check_emission() -> void:
	print("--- %s ---" % TOPS_LIGHTS)
	var raw: Dictionary = ArchiveServer.read(TOPS_LIGHTS)
	var src := NifSource.new()
	if not bool(raw["found"]) or not src.load(PackedByteArray(raw["data"])):
		check(false, "read %s" % TOPS_LIGHTS)
		return
	var material := {}
	for nd in src.get_nodes():
		if String(nd["name"]) == TOPS_SHAPE:
			material = nd
	check(bool(material.get("has_material_property", false)), "%s has an NiMaterialProperty" % TOPS_SHAPE)
	var root: Node3D = await NifTreeBuilderScript.build(src)
	add_child(root)
	var mesh := _mesh(root, TOPS_SHAPE)
	check(mesh != null, "%s is a MeshInstance3D" % TOPS_SHAPE)
	if mesh == null or material.is_empty():
		root.queue_free()
		return
	var emissive: Color = material["material_emissive"]
	var built: Color = mesh.get_instance_shader_parameter("nif_emissive")
	check(built.is_equal_approx(Color(emissive.r, emissive.g, emissive.b, 1.0)),
		"nif_emissive starts at the material's emissive colour (%s, got %s)" % [emissive, built])
	check(is_equal_approx(float(mesh.get_instance_shader_parameter("nif_emit_mult")), float(material["material_emit_mult"])),
		"nif_emit_mult starts at the material's multiplier (%s)" % material["material_emit_mult"])
	var player := root.get_node_or_null("AnimationPlayer") as AnimationPlayer
	check(player != null and player.has_animation("Forward"), "the sign lights have a Forward clip")
	var animator := root.get_node_or_null(NifObjectAnimatorScript.NODE_NAME)
	check(animator != null, "and an ObjectAnimator")
	if player == null or animator == null or not player.has_animation("Forward"):
		root.queue_free()
		return
	var animation := player.get_animation("Forward")
	var escaped := NifNames.escape(TOPS_SHAPE)
	var colour_track := _track_ending(animation, escaped + EMISSIVE_SUFFIX)
	var mult_track := _track_ending(animation, escaped + EMIT_MULT_SUFFIX)
	check(colour_track != -1, "Forward has a %s%s track" % [escaped, EMISSIVE_SUFFIX])
	check(mult_track != -1, "Forward has a %s%s track" % [escaped, EMIT_MULT_SUFFIX])
	check(animation.get_meta("nif_unhandled_controller_targets", PackedStringArray()).is_empty(),
		"Forward has no unhandled links (%s)" % str(animation.get_meta("nif_unhandled_controller_targets", [])))
	if colour_track == -1:
		root.queue_free()
		return
	check(animator.play_group("Forward"), "the ObjectAnimator plays Forward")
	var kf: KfAnimator = animator.get_animator()
	var time := animation.length * 0.5
	kf.set_paused(true)
	kf.seek(NifObjectAnimatorScript.GROUP_SLOT, time)
	kf.update_pose()
	var expected: Color = animation.value_track_interpolate(colour_track, time)
	var actual: Variant = mesh.get_instance_shader_parameter("nif_emissive")
	check(actual is Color and (actual as Color).is_equal_approx(expected),
		"at %.2f s KfAnimator sets nif_emissive to %s (got %s)" % [time, expected, actual])
	root.queue_free()


## The attack KF's clip carries Color tracks on nif_emissive and float tracks
## on nif_emit_mult, resampled from its B-splines into many keys.
func _check_kf_material_tracks() -> void:
	print("--- %s ---" % ATTACK_KF)
	var raw: Dictionary = ArchiveServer.read(ATTACK_KF)
	var src := NifSource.new()
	if not bool(raw["found"]) or not src.load(PackedByteArray(raw["data"])):
		check(false, "read %s" % ATTACK_KF)
		return
	var library: AnimationLibrary = NifAnimationBuilderScript.build_library(src)
	check(library != null and not library.get_animation_list().is_empty(), "it builds a clip")
	if library == null:
		return
	var colour_keys := 0
	var mult_keys := 0
	var colour_value: Variant = null
	for clip in library.get_animation_list():
		var animation := library.get_animation(clip)
		for track in animation.get_track_count():
			var path := String(animation.track_get_path(track))
			if path.ends_with(EMISSIVE_SUFFIX):
				colour_keys = maxi(colour_keys, animation.track_get_key_count(track))
				colour_value = animation.track_get_key_value(track, 0)
			elif path.ends_with(EMIT_MULT_SUFFIX):
				mult_keys = maxi(mult_keys, animation.track_get_key_count(track))
	check(colour_keys > 10, "a nif_emissive track is resampled from its B-spline (%d keys)" % colour_keys)
	check(colour_value is Color, "its keys are Colors (%s)" % type_string(typeof(colour_value)))
	check(mult_keys > 10, "a nif_emit_mult track is resampled from its B-spline (%d keys)" % mult_keys)


func _finish() -> void:
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _on_tree(tree: Node3D) -> void:
	_tree = tree


func _track_ending(animation: Animation, suffix: String) -> int:
	for track in animation.get_track_count():
		var path := String(animation.track_get_path(track))
		if path == suffix or path.ends_with("/" + suffix):
			return track
	return -1


func _key_not_one(animation: Animation, track: int) -> int:
	for key in animation.track_get_key_count(track):
		if not is_equal_approx(float(animation.track_get_key_value(track, key)), 1.0):
			return key
	return -1


func _mesh(root: Node, authored_name: String) -> MeshInstance3D:
	for node in root.find_children("*", "MeshInstance3D", true, false):
		if String(node.get_meta("nif_name", "")) == authored_name:
			return node as MeshInstance3D
	return null
