extends Node

## KfAnimator.set_stance_from: a rig's stance is NonAccum's yaw at the start of
## its idle. Expected yaws are the rigs' NonAccum yaw over every one of their
## KFs (constant per rig): humanoid 90 degrees, dog, Mr House and the penthouse
## mainframe 0, securitron 180.

const RIGS := {
	"meshes/characters/_male/locomotion/mtidle.kf": 90.0,
	"meshes/creatures/dog/mtidle.kf": 0.0,
	"meshes/creatures/nvmrhouse/mtidle.kf": 0.0,
	"meshes/creatures/nvpenthouemaincomputer/mtidle.kf": 0.0,
	"meshes/creatures/nvsecuritron/mtidle.kf": 180.0,
}

var failures := 0
var _libraries: Dictionary = {}


func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1


func _ready() -> void:
	for path: String in RIGS:
		NifServer.request_kf(path, self, _on_kf.bind(path))
	for i in 600:
		if _libraries.size() == RIGS.size():
			break
		await get_tree().process_frame
	var animator := KfAnimator.new()
	add_child(animator)
	for path: String in RIGS:
		_check_rig(animator, path, RIGS[path])
	check(not animator.set_stance_from(Animation.new()), "a clip with no NonAccum rotation sets no stance")
	_finish()


func _check_rig(animator: KfAnimator, path: String, expected_degrees: float) -> void:
	var library: AnimationLibrary = _libraries.get(path)
	check(library != null, path + " delivered")
	if library == null:
		return
	var clip := library.get_animation(library.get_animation_list()[0])
	animator.stance_yaw = 12345.0
	var set := animator.set_stance_from(clip)
	var difference := absf(wrapf(rad_to_deg(animator.stance_yaw) - expected_degrees, -180.0, 180.0))
	check(set and difference < 3.0, "%s: stance %.1f degrees, expected %.0f" % [path, rad_to_deg(animator.stance_yaw), expected_degrees])


func _on_kf(library: AnimationLibrary, path: String) -> void:
	_libraries[path] = library


func _finish() -> void:
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: %d" % failures)
	get_tree().quit(1 if failures > 0 else 0)
