extends Node

var failures := 0
func check(cond: bool, msg: String) -> void:
	if cond: print("  OK   ", msg)
	else: print("  FAIL ", msg); failures += 1

func _ready() -> void:
	var resolver := GamebryoMeshResolver.new()
	for pair in [["characters\\head\\headhuman.nif", "human"], ["characters\\head\\headghoul.nif", "ghoul"]]:
		var tri: TriReader = resolver.load_tri(pair[0])
		check(tri != null, "%s TRI loads" % pair[1])
		if tri == null: continue
		var expected_name := "headghoul.tri" if pair[1] == "ghoul" else "headhuman.tri"
		check(tri.get_source_path().ends_with(expected_name), "%s TRI source path is paired" % pair[1])
		check(tri.get_vertex_count() == 1211, "%s TRI has 1211 base vertices" % pair[1])
		check(tri.get_triangles().size() % 3 == 0, "%s TRI has valid triangle topology" % pair[1])
		check(tri.get_delta_morph_count() == 38, "%s TRI has 38 delta morphs" % pair[1])
		check(tri.get_statistical_morph_count() == 8, "%s TRI has 8 statistical morphs" % pair[1])
		check(tri.get_statistical_vertex_count() == 238, "%s TRI has 238 statistical vertices" % pair[1])
		for i in tri.get_delta_morph_count():
			check(tri.get_delta_morph_deltas(i).size() == 1211 * 3, "%s morph %d matches head vertex count" % [pair[1], i])
	_finish()

func _finish() -> void:
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
