extends Node3D

# Visual check for phases/1/04-exterior-cell-terrain.md: Goodsprings'
# terrain (WastelandNV worldspace, exterior cell grid (-17, 0) — confirmed
# via 115 REFRs including GSSaloonExitTrigger) plus its placed objects, on
# top of the generated heightmap terrain. Same free-fly-camera pattern as
# cell_viewer.gd.

const DATA_DIR := "../fresh_nv_copy/Data/"
const WORLDSPACE_EDITOR_ID := "WastelandNV"
const CELL_GRID_X := -17
const CELL_GRID_Y := 0

# REFR.DATA positions are absolute worldspace coordinates (not cell-local —
# XCLC is just a spatial bucket), but a LAND record's heightmap only encodes
# height; each vertex's in-plane (X/Y) position is the cell's own grid
# origin plus a local row/col offset. Cell size is 32 quads * 128 units =
# 4096 Gamebryo units (GECK wiki) — must be added here so the generated
# terrain mesh lines up with the absolute-positioned REFRs on top of it.
const CELL_SIZE_UNITS := 4096.0
const GAMEBRYO_UNITS_TO_METERS := 1.0 / 70.0

func _ready() -> void:
	var esm := EsmReader.new()
	if not esm.open(DATA_DIR + "FalloutNV.esm"):
		push_error("could not open FalloutNV.esm")
		return

	var wrld: Dictionary = esm.find_worldspace_by_editor_id(WORLDSPACE_EDITOR_ID)
	if wrld.is_empty():
		push_error("worldspace not found: " + WORLDSPACE_EDITOR_ID)
		return

	var cell: Dictionary = esm.find_exterior_cell(int(wrld["form_id"]), CELL_GRID_X, CELL_GRID_Y)
	if cell.is_empty():
		push_error("exterior cell not found at (%d, %d)" % [CELL_GRID_X, CELL_GRID_Y])
		return
	var cell_form_id := int(cell["form_id"])

	var world := Node3D.new()
	world.rotation_degrees.x = -90 # NIF/REFR/LAND Z-up -> Godot Y-up
	add_child(world)

	var resolver := GamebryoMeshResolver.new()

	var land: Dictionary = esm.get_land_data(cell_form_id)
	if land.is_empty():
		push_warning("no LAND record for this cell — terrain will be missing")
	else:
		var quadrant_ltex: PackedInt64Array = land.get("quadrant_base_ltex", PackedInt64Array())
		var quadrant_textures: Array = []
		for i in range(quadrant_ltex.size()):
			var ltex_id := int(quadrant_ltex[i])
			var tex: Texture2D = null
			if ltex_id != 0:
				var tex_path := esm.resolve_ltex_texture_path(ltex_id)
				if tex_path != "":
					tex = resolver.load_texture("textures\\" + tex_path)
			quadrant_textures.append(tex)

		var terrain := GamebryoTerrainBuilder.build(land, quadrant_textures)
		if terrain != null:
			# Terrain is built natively Y-up (see terrain_builder.gd) — a
			# sibling of "world", NOT a child of it.
			terrain.position = Vector3(
					CELL_GRID_X * CELL_SIZE_UNITS * GAMEBRYO_UNITS_TO_METERS,
					0.0,
					-(CELL_GRID_Y * CELL_SIZE_UNITS * GAMEBRYO_UNITS_TO_METERS))
			add_child(terrain)

	var registry := GamebryoObjectRegistry.new(resolver, esm)
	var refs: Array = esm.get_cell_references(cell_form_id)
	print("placing ", refs.size(), " references from exterior cell (%d, %d)..." % [CELL_GRID_X, CELL_GRID_Y])

	var placed := 0
	for p in refs:
		var node := registry.build(p)
		if node == null:
			continue
		world.add_child(node)
		placed += 1
	print("placed ", placed, "/", refs.size())

	var cam := Camera3D.new()
	cam.set_script(load("res://free_cam.gd"))
	add_child(cam)
	# cam is a sibling of "world", not a child of it — it does NOT go through
	# world's -90 X rotation, so its position must be real Godot Y-up world
	# space, not the (x, north, height) local convention used above.
	# world's rotation.x=-90 maps a local point (x, y_local=north,
	# z_local=height) to world (x, height, -north) — derived by hand (see
	# terrain_builder.gd's collision comment for the same kind of
	# derive-don't-guess check), not assumed.
	var avg_height := 0.0
	if not land.is_empty():
		var h: PackedFloat32Array = land.get("heights", PackedFloat32Array())
		for v in h:
			avg_height += v
		if h.size() > 0:
			avg_height /= h.size()
	var world_x := CELL_GRID_X * CELL_SIZE_UNITS * GAMEBRYO_UNITS_TO_METERS
	var world_z := -(CELL_GRID_Y * CELL_SIZE_UNITS * GAMEBRYO_UNITS_TO_METERS)
	var half_cell := (CELL_SIZE_UNITS * 0.5) * GAMEBRYO_UNITS_TO_METERS
	var center := Vector3(world_x + half_cell, avg_height, world_z - half_cell)
	cam.global_position = center + Vector3(0, 80, 60)
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

	print("--- WASD to move, mouse to look, Space/Ctrl for up/down, Shift to go faster, Escape to release the mouse ---")
