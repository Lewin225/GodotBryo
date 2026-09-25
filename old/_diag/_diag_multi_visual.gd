extends Node3D

const GameDataConfigScript := preload("res://game_data_config.gd")
func _ready() -> void:
	var esm := EsmReader.new()
	esm.open(String(GameDataConfigScript.resolve().get("data_dir", "")) + GameDataConfigScript.ESM_FILE)
	var resolver := GamebryoMeshResolver.new()
	var wrld = esm.find_worldspace_by_editor_id("WastelandNV")
	var wrld_id := int(wrld["form_id"])

	var terrain := Terrain3DBridge.create_terrain(self)
	var pool := Terrain3DTexturePool.new(terrain)
	var bridge := Terrain3DBridge.new(esm, resolver, pool)

	# Import a 5x5 grid one cell at a time, same as real streaming -- some
	# will share regions with earlier ones, some will need new regions.
	var imported := 0
	for dx in range(-2, 3):
		for dy in range(-2, 3):
			var cell = esm.find_exterior_cell(wrld_id, -17 + dx, dy)
			if cell.is_empty():
				continue
			if bridge.import_cell(terrain, int(cell["form_id"])):
				imported += 1
	print("imported ", imported, " cells, regions: ", terrain.data.region_locations.size())

	var cam := Camera3D.new()
	add_child(cam)
	var center := Terrain3DBridge.cell_terrain3d_global_position(-17, 0) + Vector3(0.0, 120.0, -30.0)
	cam.global_position = center + Vector3(-100.0, 220.0, -100.0)
	cam.look_at(center, Vector3.UP)
	cam.make_current()
	terrain.set_camera(cam)

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

	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute("/tmp/nv_test_screenshots/")
	img.save_png("/tmp/nv_test_screenshots/terrain3d_multi_cell_visual.png")
	print("saved")
	get_tree().quit()
