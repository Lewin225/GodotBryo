extends Node3D

# phases/2/13-terrain3d-integration.md, implementation step 4 (second half):
# real ATXT/VTXT multi-layer data -> Terrain3D's 2-layer (base+overlay+blend)
# control map, via the opacity-priority reduction described in "Real-data findings":
# per quadrant, BTXT is always the base; the single ATXT layer with the highest
# TOTAL opacity mass across that quadrant becomes the overlay, with its own real
# per-vertex opacity as the blend weight. Any other ATXT layers in that quadrant are
# a documented, acknowledged lossy drop (same category of scope cut
# phases/1/04-exterior-cell-terrain.md already made for BTXT-only).
#
# Real census data (phases/2/13-terrain3d-integration.md): 85% of quadrants have no
# ATXT at all (this reduction is a no-op there, identical to
# test_terrain3d_texture_paint.gd); worst real case is 6 additional layers in one
# quadrant, here reduced to 1.

const DATA_DIR := "/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/"
const WORLDSPACE_EDITOR_ID := "WastelandNV"
const CELL_GRID_X := -17
const CELL_GRID_Y := 0
const GRID_SIZE := 33
const QUAD_HALF := 16
const QUAD_VERTS_PER_SIDE := 17

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

# fopdoc quadrant order 0=BL 1=BR 2=TL 3=TR, matching GamebryoTerrainBuilder's own
# ranges: row is Bethesda-Y (0=south), col is Bethesda-X (0=west).
const QUADRANT_RANGES := [
	[0, QUAD_HALF, 0, QUAD_HALF], # BL: row_start, row_end, col_start, col_end
	[0, QUAD_HALF, QUAD_HALF, GRID_SIZE - 1], # BR
	[QUAD_HALF, GRID_SIZE - 1, 0, QUAD_HALF], # TL
	[QUAD_HALF, GRID_SIZE - 1, QUAD_HALF, GRID_SIZE - 1], # TR
]

func _ready() -> void:
	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened FalloutNV.esm")

	var wrld: Dictionary = esm.find_worldspace_by_editor_id(WORLDSPACE_EDITOR_ID)
	var cell: Dictionary = esm.find_exterior_cell(int(wrld.get("form_id", 0)), CELL_GRID_X, CELL_GRID_Y)
	check(not cell.is_empty(), "found exterior cell (%d, %d)" % [CELL_GRID_X, CELL_GRID_Y])
	if cell.is_empty():
		finish()
		return
	var cell_form_id := int(cell["form_id"])

	var land: Dictionary = esm.get_land_data(cell_form_id)
	var heights: PackedFloat32Array = land.get("heights", PackedFloat32Array())
	check(heights.size() == GRID_SIZE * GRID_SIZE, "heights array is %dx%d" % [GRID_SIZE, GRID_SIZE])
	var quadrant_ltex: PackedInt64Array = land.get("quadrant_base_ltex", PackedInt64Array())
	var alpha_layers: Array = land.get("alpha_layers", [])
	check(alpha_layers.size() > 0, "cell has ATXT/VTXT alpha layers (%d)" % alpha_layers.size())
	if heights.size() != GRID_SIZE * GRID_SIZE or alpha_layers.is_empty():
		finish()
		return

	# --- Per-quadrant reduction: pick the single ATXT layer with the highest
	# total opacity mass as the overlay; everything else in that quadrant is
	# dropped (documented lossy approximation, see file header). ---
	var quadrant_overlay := [null, null, null, null] # Dictionary or null per quadrant
	var quadrant_overlay_mass := [0.0, 0.0, 0.0, 0.0]
	for layer in alpha_layers:
		var q: int = layer["quadrant"]
		if q < 0 or q >= 4:
			continue
		var opacity: PackedFloat32Array = layer["opacity"]
		var mass := 0.0
		for v in opacity:
			mass += v
		if mass > quadrant_overlay_mass[q]:
			quadrant_overlay_mass[q] = mass
			quadrant_overlay[q] = layer
	var quadrants_with_overlay := 0
	for q in range(4):
		if quadrant_overlay[q] != null:
			quadrants_with_overlay += 1
			print("  quadrant %d: overlay layer_index=%d ltex=0x%X total_opacity_mass=%.1f" % [
				q, quadrant_overlay[q]["layer_index"], quadrant_overlay[q]["ltex_form_id"], quadrant_overlay_mass[q]])
	check(quadrants_with_overlay > 0, "at least one quadrant got a real overlay layer (%d/4)" % quadrants_with_overlay)

	# --- Resolve textures: BTXT base per quadrant + the selected overlay LTEX ---
	var resolver := GamebryoMeshResolver.new()
	var texture_to_slot := {} # Texture2D -> int slot id
	var texture_list: Array[Terrain3DTextureAsset] = []

	var base_slot := [-1, -1, -1, -1]
	var overlay_slot := [-1, -1, -1, -1]
	for q in range(4):
		var base_ltex := int(quadrant_ltex[q]) if q < quadrant_ltex.size() else 0
		base_slot[q] = _resolve_to_slot(esm, resolver, base_ltex, texture_to_slot, texture_list)
		if quadrant_overlay[q] != null:
			overlay_slot[q] = _resolve_to_slot(esm, resolver, int(quadrant_overlay[q]["ltex_form_id"]), texture_to_slot, texture_list)

	check(texture_list.size() > 0, "resolved at least one texture asset (%d)" % texture_list.size())

	# --- Terrain3D setup: height import (same as prior tests) ---
	var terrain := Terrain3D.new()
	terrain.vertex_spacing = VERTEX_SPACING
	add_child(terrain)
	terrain.region_size = REGION_SIZE
	if terrain.data == null:
		check(false, "Terrain3D.data initialized")
		finish()
		return

	var height_img := Image.create(GRID_SIZE, GRID_SIZE, false, Image.FORMAT_RF)
	for row in range(GRID_SIZE):
		for col in range(GRID_SIZE):
			height_img.set_pixel(col, row, Color(heights[row * GRID_SIZE + col], 0.0, 0.0, 1.0))
	var images: Array[Image] = [height_img, null, null]
	terrain.data.import_images(images, Vector3.ZERO, 0.0, 1.0)

	terrain.assets.set_texture_list(texture_list)
	check(terrain.assets.get_texture_list().size() == texture_list.size(),
			"texture asset list has %d entries" % texture_list.size())

	# --- Paint control map: base id always set; overlay id + per-vertex blend
	# set only where that quadrant got a real overlay layer. ---
	for q in range(4):
		if base_slot[q] < 0:
			continue
		var r: Array = QUADRANT_RANGES[q]
		var row_start: int = r[0]
		var col_start: int = r[2]
		for row in range(r[0], r[1] + 1):
			for col in range(r[2], r[3] + 1):
				var world_pos := Vector3(col * VERTEX_SPACING, 0.0, row * VERTEX_SPACING)
				terrain.data.set_control_base_id(world_pos, base_slot[q])
				if overlay_slot[q] >= 0:
					var local_row := row - row_start
					var local_col := col - col_start
					var local_index := local_row * QUAD_VERTS_PER_SIDE + local_col
					var opacity: PackedFloat32Array = quadrant_overlay[q]["opacity"]
					var blend: float = opacity[local_index] if local_index < opacity.size() else 0.0
					terrain.data.set_control_overlay_id(world_pos, overlay_slot[q])
					terrain.data.set_control_blend(world_pos, blend)
	terrain.data.update_maps()

	# --- Numeric round-trip: for the quadrant with the largest overlay mass,
	# confirm at least one real painted vertex reads back the right overlay id
	# and a nonzero blend matching the source opacity. ---
	var best_q := -1
	var best_mass := 0.0
	for q in range(4):
		if quadrant_overlay_mass[q] > best_mass:
			best_mass = quadrant_overlay_mass[q]
			best_q = q
	check(best_q >= 0, "found a quadrant with a real overlay to verify")
	if best_q >= 0:
		var r: Array = QUADRANT_RANGES[best_q]
		var opacity: PackedFloat32Array = quadrant_overlay[best_q]["opacity"]
		var found_painted := false
		for local_row in range(QUAD_VERTS_PER_SIDE):
			for local_col in range(QUAD_VERTS_PER_SIDE):
				var idx := local_row * QUAD_VERTS_PER_SIDE + local_col
				if opacity[idx] > 0.05 and not found_painted:
					found_painted = true
					var row: int = r[0] + local_row
					var col: int = r[2] + local_col
					var world_pos := Vector3(col * VERTEX_SPACING, 0.0, row * VERTEX_SPACING)
					var got_overlay: int = terrain.data.get_control_overlay_id(world_pos)
					var got_blend: float = terrain.data.get_control_blend(world_pos)
					check(got_overlay == overlay_slot[best_q],
							"quadrant %d painted vertex overlay id round-trips (expected %d, got %d)" % [best_q, overlay_slot[best_q], got_overlay])
					check(absf(got_blend - opacity[idx]) < 0.01,
							"quadrant %d painted vertex blend round-trips (expected %.3f, got %.3f)" % [best_q, opacity[idx], got_blend])
		check(found_painted, "found at least one real painted vertex to verify in quadrant %d" % best_q)

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
		var out_path := OUT_DIR + "terrain3d_multilayer_paint_goodsprings.png"
		var save_err := img.save_png(out_path)
		check(save_err == OK, "saved screenshot to " + out_path)

	finish()

func _resolve_to_slot(esm: EsmReader, resolver: GamebryoMeshResolver, ltex_id: int, texture_to_slot: Dictionary, texture_list: Array[Terrain3DTextureAsset]) -> int:
	if ltex_id == 0:
		return -1
	var tex_path := esm.resolve_ltex_texture_path(ltex_id)
	if tex_path == "":
		return -1
	var tex := resolver.load_texture("textures\\" + tex_path)
	if tex == null:
		return -1
	if texture_to_slot.has(tex):
		return texture_to_slot[tex]
	var asset := Terrain3DTextureAsset.new()
	asset.set_name("tex_%d" % texture_list.size())
	asset.set_albedo_texture(tex)
	texture_list.append(asset)
	var slot: int = texture_list.size() - 1
	texture_to_slot[tex] = slot
	return slot

func finish() -> void:
	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
