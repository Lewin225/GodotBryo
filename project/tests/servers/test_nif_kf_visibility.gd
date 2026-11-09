extends Node

## NifServer.request_kf(): NiVisController bool blocks become discrete
## `<target>:visible` bool tracks with their priority; a block with no keys is
## one key holding its static value; bool blocks on other controllers stay
## unhandled.

## Static visibility on four heavy weapon parts (no keys).
const HOLSTER_KF := "meshes/characters/_male/2hhholster.kf"
## ##NifRound's visibility is keyed over the reload.
const RELOAD_KF := "meshes/characters/_male/1hpreloadb.kf"

var failures := 0
var _libraries: Dictionary = {}


func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1


func _ready() -> void:
	NifServer.request_kf(HOLSTER_KF, self, _on_kf.bind(HOLSTER_KF))
	NifServer.request_kf(RELOAD_KF, self, _on_kf.bind(RELOAD_KF))
	for i in 600:
		if _libraries.size() == 2:
			break
		await get_tree().process_frame
	check(_libraries.size() == 2, "both KFs delivered")

	var holster := _first_animation(HOLSTER_KF)
	var gun_track := _track(holster, "##MinigunGun:visible")
	check(gun_track != -1, "2hhholster has a ##MinigunGun:visible track")
	if gun_track != -1:
		check(holster.track_get_type(gun_track) == Animation.TYPE_VALUE, "the visibility track is a value track")
		check(holster.value_track_get_update_mode(gun_track) == Animation.UPDATE_DISCRETE, "the visibility track is discrete")
		check(holster.track_get_key_count(gun_track) == 1 and holster.track_get_key_value(gun_track, 0) is bool,
				"a static visibility block is one bool key")
	var priorities: Dictionary = holster.get_meta("nif_track_priorities", {}) if holster != null else {}
	check(priorities.has("##MinigunGun:visible"), "the visibility track's priority is recorded under its path")
	var unhandled: PackedStringArray = holster.get_meta("nif_unhandled_controller_targets", PackedStringArray()) if holster != null else PackedStringArray()
	check(not unhandled.has("##MinigunGun:bool"), "a visibility block is no longer unhandled")

	var reload := _first_animation(RELOAD_KF)
	var round_track := _track(reload, "##NifRound:visible")
	check(round_track != -1 and reload.track_get_key_count(round_track) > 1, "1hpreloadb keys ##NifRound's visibility over time")
	if round_track != -1:
		var values := {}
		for key in reload.track_get_key_count(round_track):
			values[reload.track_get_key_value(round_track, key)] = true
		check(values.has(true) and values.has(false), "##NifRound is both shown and hidden during the reload")

	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _on_kf(library: AnimationLibrary, path: String) -> void:
	_libraries[path] = library


func _first_animation(path: String) -> Animation:
	var library: AnimationLibrary = _libraries.get(path)
	if library == null or library.get_animation_list().is_empty():
		return null
	return library.get_animation(library.get_animation_list()[0])


func _track(animation: Animation, path: String) -> int:
	if animation == null:
		return -1
	for track in animation.get_track_count():
		if String(animation.track_get_path(track)) == path:
			return track
	return -1
