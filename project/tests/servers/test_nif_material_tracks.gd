extends Node

## NifServer's material tracks: an NiAlphaController float link on a shape in
## a NIF's own sequences becomes a value track on the shape's `nif_alpha`
## instance uniform (`<shape's node path>:instance_shader_parameters/nif_alpha`,
## NifTreeBuilder._make_animation()), and playing the
## sequence sets that uniform on the shape's MeshInstance3D, not on its shared
## material. The NIF's own sequences also carry its NiVisController
## visibility, built by the same NifAnimationConverter as KFs.

## The Fat Man explosion: GlowFloat:0's alpha is keyed over the sequence.
const EXPLOSION := "meshes/effects/explosionlarge01.nif"
const SHAPE := "GlowFloat:0"
const ALPHA_SUFFIX := ":instance_shader_parameters/nif_alpha"

var failures := 0
var _tree: Node3D = null


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
	_finish()


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
