extends Node3D

# 1.4 — Exterior Cell + Terrain. Headless screenshot check, same pattern as
# test_collision.gd/test_interior_cell.gd: build Goodsprings' terrain +
# placed objects, screenshot, quit. See phases/1/04-exterior-cell-terrain.md.

const DATA_DIR := "/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/"
const OUT_DIR := "/home/lewin/.claude/jobs/47d486ae/tmp/screenshots/"
const WORLDSPACE_EDITOR_ID := "WastelandNV"
const CELL_GRID_X := -17
const CELL_GRID_Y := 0
const CELL_SIZE_UNITS := 4096.0
const GAMEBRYO_UNITS_TO_METERS := 1.0 / 70.0

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened FalloutNV.esm")

	var wrld: Dictionary = esm.find_worldspace_by_editor_id(WORLDSPACE_EDITOR_ID)
	check(not wrld.is_empty(), "found worldspace " + WORLDSPACE_EDITOR_ID)

	var cell: Dictionary = esm.find_exterior_cell(int(wrld.get("form_id", 0)), CELL_GRID_X, CELL_GRID_Y)
	check(not cell.is_empty(), "found exterior cell (%d, %d)" % [CELL_GRID_X, CELL_GRID_Y])
	if cell.is_empty():
		finish()
		return
	var cell_form_id := int(cell["form_id"])

	var world := Node3D.new()
	world.rotation_degrees.x = -90
	add_child(world)

	var resolver := GamebryoMeshResolver.new()

	var land: Dictionary = esm.get_land_data(cell_form_id)
	check(not land.is_empty(), "found LAND record")
	var heights: PackedFloat32Array = land.get("heights", PackedFloat32Array())
	check(heights.size() == 33 * 33, "heights array is 33x33 (%d)" % heights.size())

	var quadrant_ltex: PackedInt64Array = land.get("quadrant_base_ltex", PackedInt64Array())
	check(quadrant_ltex.size() == 4, "quadrant_base_ltex has 4 entries")
	var quadrant_textures: Array = []
	var textures_resolved := 0
	for i in range(quadrant_ltex.size()):
		var ltex_id := int(quadrant_ltex[i])
		var tex: Texture2D = null
		if ltex_id != 0:
			var tex_path := esm.resolve_ltex_texture_path(ltex_id)
			if tex_path != "":
				tex = resolver.load_texture("textures\\" + tex_path)
				if tex != null:
					textures_resolved += 1
		quadrant_textures.append(tex)
	check(textures_resolved > 0, "resolved at least one quadrant texture (%d/4)" % textures_resolved)

	var terrain := GamebryoTerrainBuilder.build(land, quadrant_textures)
	check(terrain != null, "terrain builder produced a node")
	if terrain != null:
		# Terrain is built natively Y-up (see terrain_builder.gd) — a sibling
		# of "world", NOT a child of it (world's -90 X rotation is only for
		# the Bethesda-Z-up REFR/NIF pipeline).
		terrain.position = Vector3(
				CELL_GRID_X * CELL_SIZE_UNITS * GAMEBRYO_UNITS_TO_METERS,
				0.0,
				-(CELL_GRID_Y * CELL_SIZE_UNITS * GAMEBRYO_UNITS_TO_METERS))
		add_child(terrain)

	var registry := GamebryoObjectRegistry.new(resolver, esm)
	var refs: Array = esm.get_cell_references(cell_form_id)
	check(refs.size() > 0, "cell has REFRs (%d)" % refs.size())
	var placed := 0
	for p in refs:
		var node := registry.build(p)
		if node == null:
			continue
		world.add_child(node)
		placed += 1
	print("  placed ", placed, "/", refs.size())
	check(placed > 0, "at least one object placed")

	var avg_height := 0.0
	for v in heights:
		avg_height += v
	if heights.size() > 0:
		avg_height /= heights.size()
	var world_x := CELL_GRID_X * CELL_SIZE_UNITS * GAMEBRYO_UNITS_TO_METERS
	var world_z := -(CELL_GRID_Y * CELL_SIZE_UNITS * GAMEBRYO_UNITS_TO_METERS)
	var half_cell := (CELL_SIZE_UNITS * 0.5) * GAMEBRYO_UNITS_TO_METERS
	var center := Vector3(world_x + half_cell, avg_height, world_z - half_cell)

	var cam := Camera3D.new()
	add_child(cam)
	cam.global_position = center + Vector3(0, 90, 80)
	cam.look_at(center, Vector3.UP)
	cam.far = 4000.0
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

	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	var out_path := OUT_DIR + "goodsprings_terrain.png"
	var save_err := img.save_png(out_path)
	check(save_err == OK, "saved screenshot to " + out_path)

	finish()

func finish() -> void:
	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
