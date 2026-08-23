extends SceneTree

## Verifies the new NifReader.get_animation_sequences() end-to-end through
## the real GDExtension binding, against real NIFs already characterized by
## native/tools/anim_survey.cpp -- confirms the GDScript-facing Dictionary
## shape matches the native extraction, not just that the C++ compiles.
## Also verifies get_scene_nodes()/get_submesh_owning_node_index() -- the
## general node-graph preservation added as a follow-up.

const DATA_DIR := "/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/"

func _dump(path: String) -> void:
	var resolver := GamebryoMeshResolver.new()
	var found := resolver.resolve_bytes(path)
	if found.is_empty():
		print(path, " -> NOT FOUND")
		return
	var nif := NifReader.new()
	if not nif.load(found["data"]):
		print(path, " -> LOAD FAILED")
		return
	var seqs: Array = nif.get_animation_sequences()
	print(path, " -> ", seqs.size(), " sequence(s)")
	for s in seqs:
		print("  '", s["name"], "' cycle_type=", s["cycle_type"], " start=", s["start_time"], " stop=", s["stop_time"], " tracks=", s["tracks"].size())
		for t in s["tracks"]:
			var line := "    target='%s' has_quat=%s has_axis=%s x=%d y=%d z=%d trans=%d scale=%d" % [
				t["target_node_name"], t["has_quaternion_keys"], t["has_axis_keys"],
				t["x_rotation_keys"].size(), t["y_rotation_keys"].size(), t["z_rotation_keys"].size(),
				t["translation_keys"].size(), t["scale_keys"].size()
			]
			print(line)
			# Spot-check one real key's full field shape.
			if t["has_axis_keys"] and t["x_rotation_keys"].size() > 0:
				var k: Dictionary = t["x_rotation_keys"][0]
				print("      x_rotation_keys[0]: time=", k["time"], " value=", k["value"], " interp=", k["interp"])
			if t["translation_keys"].size() > 0:
				var k: Dictionary = t["translation_keys"][0]
				print("      translation_keys[0]: time=", k["time"], " value=", k["value"], " interp=", k["interp"])
			if t["scale_keys"].size() > 0:
				var k: Dictionary = t["scale_keys"][0]
				print("      scale_keys[0]: time=", k["time"], " value=", k["value"], " forward=", k["forward"], " backward=", k["backward"], " interp=", k["interp"])

	var scene_nodes: Array = nif.get_scene_nodes()
	print("  scene_nodes: ", scene_nodes.size())
	for i in scene_nodes.size():
		var n: Dictionary = scene_nodes[i]
		print("    [", i, "] '", n["name"], "' parent_index=", n["parent_index"], " origin=", n["transform"].origin)
	for i in nif.get_submesh_count():
		print("    submesh[", i, "] '", nif.get_submesh_name(i), "' owning_node_index=", nif.get_submesh_owning_node_index(i))

func _init() -> void:
	# Door: pure rotation (XYZ axis keys), no translation/scale -- matches
	# the anim_survey.cpp finding exactly.
	_dump("meshes\\dlc04\\architecture\\backwoodshacks\\dlc04shackdooranim01.nif")
	# Elevator: pure translation, hundreds of linear keys, no rotation at
	# all -- proves the parser isn't door-specific. Real path confirmed via
	# anim_survey.cpp's own --list output, not guessed.
	_dump("meshes\\nvdlc04\\dungeons\\silo\\silo_elevator\\nvdlc04_silo-elevator-shaft.nif")
	quit()
