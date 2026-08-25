extends Node3D

const GameDataConfigScript := preload("res://game_data_config.gd")

# Interactive viewer, not a test — stays open with a free-fly camera instead
# of screenshotting and quitting. Now routes through the real
# GamebryoObjectRegistry (phases/1/01-object-type-registry.md) instead of
# the ad hoc "any REFR with a model" heuristic this started as — typed
# nodes (DoorNode/ContainerNode/...) show up correctly in the Scene dock.

const CELL_EDITOR_ID := "GSDocMitchellHouse"

func _ready() -> void:
	var esm := EsmReader.new()
	var data_dir := String(GameDataConfigScript.resolve().get("data_dir", ""))
	if not esm.open(data_dir + GameDataConfigScript.ESM_FILE):
		push_error("could not open FalloutNV.esm")
		return

	var cell: Dictionary = esm.find_cell_by_editor_id(CELL_EDITOR_ID)
	if cell.is_empty():
		push_error("cell not found: " + CELL_EDITOR_ID)
		return

	var world := Node3D.new()
	world.rotation_degrees.x = -90 # NIF Z-up -> Godot Y-up
	add_child(world)

	var resolver := GamebryoMeshResolver.new(data_dir)
	var registry := GamebryoObjectRegistry.new(resolver, esm)

	var refs: Array = esm.get_cell_references(int(cell["form_id"]))
	print("placing ", refs.size(), " references from ", CELL_EDITOR_ID, "...")

	var placed := 0
	var combined_aabb := AABB()
	var have_aabb := false

	for p in refs:
		var node := registry.build(p)
		if node == null:
			continue
		world.add_child(node)
		placed += 1
		for mi in _mesh_instances(node):
			var world_aabb: AABB = mi.global_transform * mi.mesh.get_aabb()
			combined_aabb = world_aabb if not have_aabb else combined_aabb.merge(world_aabb)
			have_aabb = true

	print("placed ", placed, "/", refs.size())

	var cam := Camera3D.new()
	cam.set_script(load("res://free_cam.gd"))
	add_child(cam)
	if have_aabb:
		# combined_aabb came from global_transform, already in world (Y-up)
		# space — no manual axis remap needed here (see
		# test_object_registry.gd's note on the same distinction).
		var center: Vector3 = combined_aabb.get_center()
		cam.global_position = center + Vector3(0, combined_aabb.size.y * 0.3 + 1.7, 0) # ~eye height headroom
		cam.look_at(center, Vector3.UP)
	cam.far = 2000.0
	cam.make_current()

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, -30, 0)
	sun.light_energy = 1.3
	add_child(sun)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.5, 0.6, 0.75)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.65)
	env.ambient_light_energy = 0.8
	env_node.environment = env
	add_child(env_node)

	print("--- WASD to move, mouse to look, Space/Ctrl for up/down, Shift to go faster, Escape to release the mouse ---")

func _mesh_instances(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D:
		out.append(node)
	for c in node.get_children():
		out.append_array(_mesh_instances(c))
	return out
