extends Node

## Loads the selected test scenes after project autoloads have been registered.
## The external runner passes paths after the argument separator; loading is
## enough to compile each scene's attached script without running that test's
## _ready().

var failures := 0


func _ready() -> void:
	for scene_path in OS.get_cmdline_user_args():
		if not scene_path.ends_with(".tscn"):
			continue
		var scene := ResourceLoader.load(scene_path, "PackedScene")
		if scene == null:
			print("  FAIL could not load ", scene_path)
			failures += 1

	if failures == 0:
		print("ALL TEST SCENES PARSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
