extends Node3D

## KfAnimator with node targets: with no skeleton, a clip plays on the Node3Ds
## under node_root named as its tracks. 1hpreloadb (the dart gun's reload)
## moves ##dgDartPin and shows and hides ##NifRound.

const RELOAD_KF := "meshes/characters/_male/1hpreloadb.kf"
const ROUND := "##NifRound"
const PIN := "##dgDartPin"

var failures := 0
var _library: AnimationLibrary


func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1


func _ready() -> void:
	NifServer.request_kf(RELOAD_KF, self, _on_kf)
	for i in 600:
		if _library != null:
			break
		await get_tree().process_frame
	check(_library != null, "1hpreloadb delivered")
	if _library == null:
		_finish()
		return
	var clip := _library.get_animation(_library.get_animation_list()[0])

	var root := Node3D.new()
	root.name = "Weapon Root"
	add_child(root)
	var round_node := _add_part(root, ROUND)
	var pin := _add_part(root.get_child(0), PIN)
	var animator := KfAnimator.new()
	add_child(animator)
	animator.node_root = animator.get_path_to(root)

	var serial := animator.play(0, clip, 0.0, false, 1.0, RELOAD_KF, 0)
	check(serial != 0, "the clip binds to node targets with no skeleton")

	var round_track := _track(clip, NifNames.escape(ROUND) + ":visible", Animation.TYPE_VALUE)
	var pin_track := _track(clip, NifNames.escape(PIN), Animation.TYPE_POSITION_3D)
	check(round_track != -1 and pin_track != -1, "the clip has ##NifRound visibility and ##dgDartPin position tracks")
	if round_track == -1 or pin_track == -1:
		_finish()
		return

	var shown_seen := false
	var hidden_seen := false
	var visibility_matches := true
	var position_matches := true
	var steps := 20
	for step in steps + 1:
		var time := clip.length * step / steps
		animator.seek(0, time)
		animator.update_pose()
		var expected_visible: bool = clip.value_track_interpolate(round_track, time)
		visibility_matches = visibility_matches and round_node.visible == expected_visible
		shown_seen = shown_seen or round_node.visible
		hidden_seen = hidden_seen or not round_node.visible
		var expected_position := clip.position_track_interpolate(pin_track, time)
		position_matches = position_matches and pin.position.is_equal_approx(expected_position)
	check(visibility_matches, "##NifRound's visible follows its track at 21 times")
	check(shown_seen and hidden_seen, "##NifRound is shown and hidden over the reload")
	check(position_matches, "##dgDartPin (nested two levels down) follows its track")
	_finish()


func _on_kf(library: AnimationLibrary) -> void:
	_library = library


func _add_part(parent: Node, nif_name: String) -> Node3D:
	var part := Node3D.new()
	part.name = NifNames.escape(nif_name)
	part.set_meta(NifNames.META_NIF_NAME, nif_name)
	parent.add_child(part)
	return part


func _track(animation: Animation, path: String, type: Animation.TrackType) -> int:
	for track in animation.get_track_count():
		if String(animation.track_get_path(track)) == path and animation.track_get_type(track) == type:
			return track
	return -1


func _finish() -> void:
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
