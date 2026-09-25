extends Node3D

# 1.5 — Integration: Both Default Cells. See phases/1/05-integration.md.
#
# Runs the complete 1.0-1.4 pipeline (via GamebryoObjectRegistry/
# GamebryoMeshResolver/GamebryoTerrainBuilder, not the ad-hoc per-task BSA/
# NIF code those earlier tasks' own tests used) against both Phase 1 default
# cells in one session, checks every item in phases/1/README.md's
# "Definition of done" list, demonstrates generic lookup beyond the two
# defaults, deliberately exercises both registry fallback tiers, and proves
# the free-fly camera (free_cam.gd) actually moves/looks via simulated
# input events rather than assuming a human will confirm it interactively.

const DATA_DIR := "../fresh_nv_copy/Data/"
const OUT_DIR := "/tmp/nv_test_screenshots/" # stable, session-independent -- created fresh by make_dir_recursive_absolute() below regardless of who's running this
const WORLDSPACE_EDITOR_ID := "WastelandNV"
const CELL_GRID_X := -17
const CELL_GRID_Y := 0
const CELL_SIZE_UNITS := 4096.0
const GAMEBRYO_UNITS_TO_METERS := 1.0 / 70.0

var failures := 0
var done := {} # definition-of-done key -> bool

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func mark(key: String, cond: bool) -> void:
	done[key] = done.get(key, true) and cond

func aabb_of(root: Node3D) -> Dictionary:
	var combined := AABB()
	var have := false
	for child in root.get_children():
		for mi in _mesh_instances(child):
			var world_aabb: AABB = mi.global_transform * mi.mesh.get_aabb()
			combined = world_aabb if not have else combined.merge(world_aabb)
			have = true
	return { "aabb": combined, "have": have }

func _mesh_instances(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D:
		out.append(node)
	for c in node.get_children():
		out.append_array(_mesh_instances(c))
	return out

func count_collision(node: Node) -> int:
	var n := 0
	if node is CollisionShape3D and node.shape != null:
		n += 1
	for c in node.get_children():
		n += count_collision(c)
	return n

# --- interior cell loading, via the registry (1.1-1.3's actual pipeline) ---
func load_interior(esm: EsmReader, registry: GamebryoObjectRegistry, lookup: Dictionary, offset: Vector3) -> Dictionary:
	if lookup.is_empty():
		return { "built": 0, "root": null }
	var cell_form_id := int(lookup["form_id"])
	var refs: Array = esm.get_cell_references(cell_form_id)

	var root := Node3D.new()
	root.rotation_degrees.x = -90
	root.position = offset
	add_child(root)

	var built := 0
	var skipped := 0
	var skipped_types := {}
	var by_class := {}
	for p in refs:
		var node := registry.build(p)
		if node == null:
			skipped += 1
			var bt: String = p["base_type"]
			skipped_types[bt] = skipped_types.get(bt, 0) + 1
			continue
		root.add_child(node)
		built += 1
		var cls: String = String(node.get_script().get_global_name()) if node.get_script() else node.get_class()
		by_class[cls] = by_class.get(cls, 0) + 1

	return { "built": built, "skipped": skipped, "skipped_types": skipped_types,
			"by_class": by_class, "root": root, "refs": refs.size() }

func load_exterior(esm: EsmReader, resolver: GamebryoMeshResolver, registry: GamebryoObjectRegistry,
		wrld_form_id: int, grid_x: int, grid_y: int) -> Dictionary:
	var cell: Dictionary = esm.find_exterior_cell(wrld_form_id, grid_x, grid_y)
	if cell.is_empty():
		return { "found": false }
	var cell_form_id := int(cell["form_id"])

	var world := Node3D.new()
	world.rotation_degrees.x = -90
	add_child(world)

	var land: Dictionary = esm.get_land_data(cell_form_id)
	var terrain: Node3D = null
	if not land.is_empty():
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
		terrain = GamebryoTerrainBuilder.build(land, quadrant_textures)
		if terrain != null:
			terrain.position = Vector3(
					grid_x * CELL_SIZE_UNITS * GAMEBRYO_UNITS_TO_METERS,
					0.0,
					-(grid_y * CELL_SIZE_UNITS * GAMEBRYO_UNITS_TO_METERS))
			add_child(terrain)

	var refs: Array = esm.get_cell_references(cell_form_id)
	var built := 0
	for p in refs:
		var node := registry.build(p)
		if node == null:
			continue
		world.add_child(node)
		built += 1

	return { "found": true, "cell_form_id": cell_form_id, "built": built, "refs": refs.size(),
			"world": world, "terrain": terrain, "land_found": not land.is_empty() }

func setup_lighting() -> void:
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

func screenshot(out_name: String) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	if img == null:
		print("  (skipped screenshot -- no real viewport texture under --headless, expected)")
	else:
		var out_path := OUT_DIR + out_name
		var save_err := img.save_png(out_path)
		check(save_err == OK, "saved screenshot to " + out_path)

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened FalloutNV.esm")

	var resolver := GamebryoMeshResolver.new()
	var registry := GamebryoObjectRegistry.new(resolver, esm)

	# ============================================================
	# 1. Default interior cell: GSDocMitchellHouse, by EDID AND FormID
	# ============================================================
	print("=== GSDocMitchellHouse (default interior) ===")
	var by_edid: Dictionary = esm.find_cell_by_editor_id("GSDocMitchellHouse")
	var by_formid: Dictionary = esm.find_cell_by_form_id(0x00103DF9)
	check(not by_edid.is_empty() and not by_formid.is_empty(), "found by both EDID and FormID")
	check(by_edid.get("form_id", -1) == by_formid.get("form_id", -2), "EDID and FormID lookups agree")

	var interior := load_interior(esm, registry, by_edid, Vector3.ZERO)
	print("  built=", interior.get("built", 0), "/", interior.get("refs", 0),
			" skipped=", interior.get("skipped", 0), " skipped_types=", interior.get("skipped_types", {}))
	var by_class: Dictionary = interior.get("by_class", {})
	check(int(interior.get("built", 0)) > 200, "most of the cell's refs built something")
	mark("interior_default_loads", int(interior.get("built", 0)) > 200)

	# Definition-of-done: FURN/CONT/ACTI/DOOR alongside STAT, each its own typed node.
	var has_breadth: bool = by_class.get("DoorNode", 0) > 0 and by_class.get("ContainerNode", 0) > 0 \
			and by_class.get("ActivatorNode", 0) > 0 and by_class.get("FurnitureNode", 0) > 0
	check(has_breadth, "FURN/CONT/ACTI/DOOR all present as their own typed node classes")
	mark("object_type_breadth", has_breadth)

	# Definition-of-done: LIGH -> real Light3D.
	check(by_class.get("LightNode", 0) > 0, "LIGH records produced LightNode instances")
	mark("lights", by_class.get("LightNode", 0) > 0)

	# Definition-of-done: walkable collision in the interior.
	var interior_collision_count := count_collision(interior["root"])
	check(interior_collision_count > 0, "interior cell has collision shapes (%d found)" % interior_collision_count)

	# Definition-of-done: unregistered/unhandled types skipped with a log line, not a crash.
	var interior_skipped_types: Dictionary = interior.get("skipped_types", {})
	check(interior_skipped_types.get("SOUN", 0) > 0, "SOUN (no MODL, genuinely unhandled) skipped cleanly, not crashed")
	check(by_class.get("GamebryoVisual", 0) > 0, "unregistered-but-visual types resolved via structural fallback")
	mark("fallback_paths", interior_skipped_types.get("SOUN", 0) > 0 and by_class.get("GamebryoVisual", 0) > 0)

	# ============================================================
	# 2. Default exterior cell: Goodsprings, WastelandNV (-17, 0)
	# ============================================================
	print("=== Goodsprings (default exterior, -17, 0) ===")
	var wrld: Dictionary = esm.find_worldspace_by_editor_id(WORLDSPACE_EDITOR_ID)
	check(not wrld.is_empty(), "found worldspace " + WORLDSPACE_EDITOR_ID)
	var wrld_form_id := int(wrld.get("form_id", 0))

	var ext := load_exterior(esm, resolver, registry, wrld_form_id, CELL_GRID_X, CELL_GRID_Y)
	check(bool(ext.get("found", false)), "found exterior cell (%d, %d)" % [CELL_GRID_X, CELL_GRID_Y])
	check(bool(ext.get("land_found", false)), "LAND record found -> heightmap terrain built")
	check(ext.get("terrain") != null, "terrain builder produced a node")
	check(int(ext.get("built", 0)) > 0, "at least one exterior object placed (%d/%d)" % [ext.get("built", 0), ext.get("refs", 0)])
	mark("exterior_default_loads", bool(ext.get("land_found", false)) and ext.get("terrain") != null and int(ext.get("built", 0)) > 0)

	var ext_collision_count := count_collision(self)
	check(ext_collision_count > interior_collision_count, "exterior scene adds its own collision (terrain + objects)")
	mark("collision_both_cells", interior_collision_count > 0 and ext_collision_count > interior_collision_count)

	# ============================================================
	# 3. Generic lookup beyond the two hardcoded defaults
	# ============================================================
	print("=== generic lookup: second interior + second exterior cell ===")
	var second_interior_lookup: Dictionary = esm.find_cell_by_editor_id("RanchHouseInterior03")
	check(not second_interior_lookup.is_empty(), "found a second interior cell by EDID (RanchHouseInterior03)")
	var second_interior := load_interior(esm, registry, second_interior_lookup, Vector3(500, 0, 0))
	check(int(second_interior.get("built", 0)) > 0, "second interior cell's generic lookup placed real objects (%d)" % second_interior.get("built", 0))
	mark("generic_lookup", not second_interior_lookup.is_empty() and int(second_interior.get("built", 0)) > 0)

	# Scan a small neighborhood of Goodsprings' own grid for a second real
	# exterior cell rather than assuming a specific coordinate exists.
	var second_ext_result := {}
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			if dx == 0 and dy == 0:
				continue
			var probe: Dictionary = esm.find_exterior_cell(wrld_form_id, CELL_GRID_X + dx, CELL_GRID_Y + dy)
			if not probe.is_empty():
				second_ext_result = load_exterior(esm, resolver, registry, wrld_form_id, CELL_GRID_X + dx, CELL_GRID_Y + dy)
				print("  second exterior cell found at (%d, %d)" % [CELL_GRID_X + dx, CELL_GRID_Y + dy])
				break
		if not second_ext_result.is_empty():
			break
	check(bool(second_ext_result.get("found", false)), "generic exterior lookup found a second real cell")
	mark("generic_lookup", done.get("generic_lookup", true) and bool(second_ext_result.get("found", false)))

	# ============================================================
	# 4. Deliberately exercise registry fallback tiers (in this session,
	#    not just cited from 1.1's own test)
	# ============================================================
	print("=== deliberate fallback exercise ===")
	var door_placement = null
	var refs_for_fallback: Array = esm.get_cell_references(int(by_edid["form_id"]))
	for p in refs_for_fallback:
		if p["base_type"] == "DOOR":
			door_placement = p
			break
	check(door_placement != null, "found a DOOR placement to test structural fallback with")
	if door_placement != null:
		check(registry.is_registered("DOOR"), "DOOR starts registered")
		registry.unregister("DOOR")
		var fallback_node := registry.build(door_placement)
		check(fallback_node != null and fallback_node is GamebryoVisual and not (fallback_node is DoorNode),
				"unregistering DOOR falls through to a plain GamebryoVisual, not dropped")
		registry.register("DOOR", func(p, r): return registry._instantiate_visual(DoorNode, p, r))
		check(registry.build(door_placement) is DoorNode, "re-registering DOOR restores DoorNode")

	# ACHR/ACRE (actor/creature placements, object-types.md) are filtered at
	# the ESM layer itself (EsmFile::get_cell_references()), one layer below
	# the registry, so the registry's own fallback tier never actually sees
	# one. Verified by comparing get_cell_child_type_counts() (every CELL
	# child, unfiltered) against get_cell_references() (REFR only) for a
	# cell independently known to contain one. Goodsprings' own cell turned
	# out to have no ACHR (human NPCs there apparently aren't placed via raw
	# ACHR in this cell) but does have a genuine ACRE (creature) — same
	# actor-placement family, same exclusion path, found by inspecting the
	# real census instead of assuming ACHR specifically would be present.
	var goodsprings_form_id := int(ext.get("cell_form_id", 0))
	var child_counts: Dictionary = esm.get_cell_child_type_counts(goodsprings_form_id)
	var actor_count := int(child_counts.get("ACHR", 0)) + int(child_counts.get("ACRE", 0))
	var refr_count := int(child_counts.get("REFR", 0))
	print("  Goodsprings cell child census: ", child_counts)
	check(actor_count > 0, "Goodsprings cell genuinely contains ACHR/ACRE (actor/creature) children (%d)" % actor_count)
	check(refr_count == int(ext.get("refs", -1)), "get_cell_references()'s REFR count matches the census's REFR count")
	check(actor_count > 0 and refr_count == int(ext.get("refs", -1)),
			"ACHR/ACRE children are silently and correctly excluded upstream of the registry, not dropped by accident")
	mark("fallback_paths", done.get("fallback_paths", true) and door_placement != null and actor_count > 0)

	# ============================================================
	# 5. Free-fly camera: prove it actually moves/looks via simulated input,
	#    not just "it exists and didn't crash".
	# ============================================================
	print("=== free-fly camera controller ===")
	var cam := Camera3D.new()
	cam.set_script(load("res://free_cam.gd"))
	add_child(cam)
	cam.global_position = Vector3(0, 1.7, 5)
	cam.rotation = Vector3.ZERO
	cam.far = 4000.0
	cam.make_current()
	setup_lighting()

	await get_tree().process_frame # let _ready() run and capture initial yaw/pitch

	var start_pos: Vector3 = cam.global_position
	var w_event := InputEventKey.new()
	w_event.keycode = KEY_W
	w_event.pressed = true
	Input.parse_input_event(w_event)
	# Frame-counted loops don't guarantee real elapsed time (frame delta
	# varies, especially right after heavy scene construction) — wait on a
	# real-time timer instead so the expected ~4m/s * 1s move is reliable.
	await get_tree().create_timer(1.0).timeout
	var moved_forward := cam.global_position.distance_to(start_pos) > 1.0
	check(moved_forward, "holding W moves the camera forward (moved %.2fm)" % cam.global_position.distance_to(start_pos))
	w_event.pressed = false
	Input.parse_input_event(w_event)

	var start_yaw: float = cam.rotation.y
	var mouse_event := InputEventMouseMotion.new()
	mouse_event.relative = Vector2(200, 0)
	Input.parse_input_event(mouse_event)
	await get_tree().process_frame
	var yaw_changed := absf(cam.rotation.y - start_yaw) > 0.01
	check(yaw_changed, "mouse motion changes camera look direction (delta yaw=%.3f)" % absf(cam.rotation.y - start_yaw))
	mark("free_fly_camera", moved_forward and yaw_changed)

	# Reposition for a screenshot of the interior cell it just "walked" through.
	var interior_root: Node3D = interior["root"]
	var interior_info := aabb_of(interior_root)
	if bool(interior_info.get("have", false)):
		var iaabb: AABB = interior_info["aabb"]
		var icenter: Vector3 = iaabb.get_center()
		var iradius: float = max(iaabb.size.length() * 0.5, 2.0)
		cam.global_position = icenter + Vector3(0.9, 0.7, 0.9).normalized() * iradius * 1.2
		cam.rotation = Vector3.ZERO
		cam.look_at(icenter, Vector3.UP)
		cam.far = iradius * 10.0 + 500.0
	await screenshot("phase1_integration_interior.png")

	# Reposition for a screenshot of the exterior cell.
	var ext_world: Node3D = ext.get("world")
	if ext_world != null:
		var world_x := CELL_GRID_X * CELL_SIZE_UNITS * GAMEBRYO_UNITS_TO_METERS
		var world_z := -(CELL_GRID_Y * CELL_SIZE_UNITS * GAMEBRYO_UNITS_TO_METERS)
		var half_cell := (CELL_SIZE_UNITS * 0.5) * GAMEBRYO_UNITS_TO_METERS
		var center := Vector3(world_x + half_cell, 90.0, world_z - half_cell)
		cam.global_position = center + Vector3(0, 90, 80)
		cam.look_at(center, Vector3.UP)
		await screenshot("phase1_integration_exterior.png")

	# ============================================================
	# Definition of done, checked item by item against this real run.
	# ============================================================
	print("=== Definition of done (phases/1/README.md) ===")
	for key in ["interior_default_loads", "object_type_breadth", "lights",
			"exterior_default_loads", "collision_both_cells", "generic_lookup",
			"fallback_paths", "free_fly_camera"]:
		var ok: bool = done.get(key, false)
		print("  [", "x" if ok else " ", "] ", key)
		check(ok, "definition-of-done: " + key)

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
