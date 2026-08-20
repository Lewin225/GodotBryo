extends Node3D

# phases/2/13-terrain3d-integration.md, implementation step 4 (first half):
# control-map texture painting for the base-texture-only case -- one texture per
# quadrant (matching GamebryoTerrainBuilder's own current BTXT-only scope, see
# phases/1/04-exterior-cell-terrain.md's "Scope reduction" section), painted onto a
# real Terrain3D control map instead of a per-quadrant StandardMaterial3D.
#
# Real ATXT/VTXT multi-layer blending and the region_size=64 + 31-slot LRU +
# pink-fallback texture-budget design are NOT implemented here -- this only proves
# the base-texture control-map path works end to end against real LTEX/TXST data,
# same "smallest real slice first" approach test_terrain3d_spike.gd used for height.

const DATA_DIR := "/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/"
const WORLDSPACE_EDITOR_ID := "WastelandNV"
const CELL_GRID_X := -17
const CELL_GRID_Y := 0
const GRID_SIZE := 33 # esm::kLandGridSize
const QUAD_HALF := 16 # (GRID_SIZE - 1) / 2 -- each quadrant is 16x16 quads, 17x17 verts

const GAMEBRYO_UNITS_TO_METERS := 1.0 / 70.0
const VERTEX_SPACING := 128.0 * GAMEBRYO_UNITS_TO_METERS
const REGION_SIZE := 64

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func _ready() -> void:
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

	var land: Dictionary = esm.get_land_data(cell_form_id)
	check(not land.is_empty(), "found LAND record")
	var heights: PackedFloat32Array = land.get("heights", PackedFloat32Array())
	check(heights.size() == GRID_SIZE * GRID_SIZE, "heights array is %dx%d" % [GRID_SIZE, GRID_SIZE])
	if heights.size() != GRID_SIZE * GRID_SIZE:
		finish()
		return

	# --- Resolve each quadrant's BTXT -> LTEX -> TXST -> real texture, same
	# resolution path test_terrain.gd already exercises ---
	var quadrant_ltex: PackedInt64Array = land.get("quadrant_base_ltex", PackedInt64Array())
	check(quadrant_ltex.size() == 4, "quadrant_base_ltex has 4 entries")

	var resolver := GamebryoMeshResolver.new()
	var quadrant_textures: Array[Texture2D] = [null, null, null, null]
	var textures_resolved := 0
	for i in range(quadrant_ltex.size()):
		var ltex_id := int(quadrant_ltex[i])
		if ltex_id == 0:
			continue
		var tex_path := esm.resolve_ltex_texture_path(ltex_id)
		if tex_path == "":
			continue
		var tex := resolver.load_texture("textures\\" + tex_path)
		if tex != null:
			quadrant_textures[i] = tex
			textures_resolved += 1
	check(textures_resolved > 0, "resolved at least one quadrant texture (%d/4)" % textures_resolved)

	# --- Terrain3D setup: height import (same as test_terrain3d_spike.gd) ---
	var terrain := Terrain3D.new()
	terrain.vertex_spacing = VERTEX_SPACING
	add_child(terrain)
	terrain.region_size = REGION_SIZE
	check(terrain.data != null, "Terrain3D.data initialized after entering the tree")
	if terrain.data == null:
		finish()
		return

	var height_img := Image.create(GRID_SIZE, GRID_SIZE, false, Image.FORMAT_RF)
	for row in range(GRID_SIZE):
		for col in range(GRID_SIZE):
			height_img.set_pixel(col, row, Color(heights[row * GRID_SIZE + col], 0.0, 0.0, 1.0))
	var images: Array[Image] = [height_img, null, null]
	terrain.data.import_images(images, Vector3.ZERO, 0.0, 1.0)

	# --- Build the texture asset list: one slot per DISTINCT resolved texture
	# (dedup within this one cell -- a real preview of the path-dedup step from
	# "Real-data findings", even though full LRU slot management is a later step) ---
	var texture_to_slot := {} # Texture2D -> int slot id
	var texture_list: Array[Terrain3DTextureAsset] = []
	var quadrant_slot := [-1, -1, -1, -1]
	for i in range(4):
		var tex: Texture2D = quadrant_textures[i]
		if tex == null:
			continue
		if not texture_to_slot.has(tex):
			var asset := Terrain3DTextureAsset.new()
			asset.set_name("quadrant_tex_%d" % texture_list.size())
			asset.set_albedo_texture(tex)
			texture_list.append(asset)
			texture_to_slot[tex] = texture_list.size() - 1
		quadrant_slot[i] = texture_to_slot[tex]
	terrain.assets.set_texture_list(texture_list)
	check(terrain.assets.get_texture_list().size() == texture_list.size(),
			"texture asset list has %d entries" % texture_list.size())

	# --- Paint the control map: fopdoc quadrant order 0=BL 1=BR 2=TL 3=TR, row is
	# Bethesda-Y (0=south), col is Bethesda-X (0=west) -- same ranges
	# GamebryoTerrainBuilder uses, reused here for a direct behavioral comparison. ---
	var quadrant_ranges := [
		[0, QUAD_HALF, 0, QUAD_HALF], # BL
		[0, QUAD_HALF, QUAD_HALF, GRID_SIZE - 1], # BR
		[QUAD_HALF, GRID_SIZE - 1, 0, QUAD_HALF], # TL
		[QUAD_HALF, GRID_SIZE - 1, QUAD_HALF, GRID_SIZE - 1], # TR
	]
	for q in range(4):
		var slot: int = quadrant_slot[q]
		if slot < 0:
			continue
		var r: Array = quadrant_ranges[q]
		for row in range(r[0], r[1] + 1):
			for col in range(r[2], r[3] + 1):
				var world_pos := Vector3(col * VERTEX_SPACING, 0.0, row * VERTEX_SPACING)
				terrain.data.set_control_base_id(world_pos, slot)
	terrain.data.update_maps()

	# --- Numeric round-trip: one sample point well inside each quadrant reads
	# back the exact slot id assigned to it. ---
	var quadrant_sample_rc := [Vector2i(8, 8), Vector2i(8, 24), Vector2i(24, 8), Vector2i(24, 24)]
	for q in range(4):
		var slot: int = quadrant_slot[q]
		if slot < 0:
			continue
		var rc: Vector2i = quadrant_sample_rc[q]
		var world_pos := Vector3(rc.x * VERTEX_SPACING, 0.0, rc.y * VERTEX_SPACING)
		var got_id: int = terrain.data.get_control_base_id(world_pos)
		check(got_id == slot, "quadrant %d control base id round-trips (expected %d, got %d)" % [q, slot, got_id])

	# --- Visual check ---
	var cam := Camera3D.new()
	add_child(cam)
	var center := Vector3(16.0 * VERTEX_SPACING, 120.0, 16.0 * VERTEX_SPACING)
	cam.global_position = center + Vector3(15.0, 35.0, 30.0)
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
	if img == null:
		print("  (skipped screenshot -- no real viewport texture under --headless, expected)")
	else:
		const OUT_DIR := "/tmp/nv_test_screenshots/"
		DirAccess.make_dir_recursive_absolute(OUT_DIR)
		var out_path := OUT_DIR + "terrain3d_texture_paint_goodsprings.png"
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
