extends Node3D

# 1.1 — Object-Type Registry. See phases/1/01-object-type-registry.md.

const DATA_DIR := "/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/"
const OUT_DIR := "/tmp/nv_test_screenshots/" # stable, session-independent -- created fresh by make_dir_recursive_absolute() below regardless of who's running this

var failures := 0
var _cam: Camera3D
var _sun: DirectionalLight3D

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func ensure_view_nodes() -> void:
	if _cam != null:
		return
	_cam = Camera3D.new()
	add_child(_cam)
	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-45, -30, 0)
	_sun.light_energy = 1.3
	add_child(_sun)
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.5, 0.6, 0.75)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.65)
	env.ambient_light_energy = 0.8
	env_node.environment = env
	add_child(env_node)

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

func screenshot(root: Node3D, out_name: String) -> void:
	var info := aabb_of(root)
	if not info["have"]:
		check(false, "screenshot skipped, no AABB for " + out_name)
		return
	ensure_view_nodes()
	var aabb: AABB = info["aabb"]
	# aabb was built from global_transform, which already includes the root's
	# Z-up -> Y-up rotation — unlike test_interior_cell.gd's AABB (built from
	# local, pre-rotation transforms), this one does NOT need the (x,z,-y)
	# remap on top; it's already in world space.
	var center: Vector3 = aabb.get_center()
	var radius: float = max(aabb.size.length() * 0.5, 2.0) # floor was 50.0, tuned for the pre-units.h ~70x-oversized world
	_cam.global_position = center + Vector3(0.9, 0.7, 0.9).normalized() * radius * 1.2
	_cam.look_at(center, Vector3.UP)
	_cam.far = radius * 10.0 + 500.0
	_cam.make_current()

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

func _first_placement_of_type(esm: EsmReader, cell_editor_id: String, type_tag: String) -> Dictionary:
	var cell: Dictionary = esm.find_cell_by_editor_id(cell_editor_id)
	if cell.is_empty():
		return {}
	for placement in esm.get_cell_references(int(cell["form_id"])):
		if String(placement.get("base_type", "")) == type_tag:
			return placement
	return {}

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened FalloutNV.esm")

	var resolver := GamebryoMeshResolver.new()
	var registry := GamebryoObjectRegistry.new(resolver, esm)

	# --- GSDocMitchellHouse: full object-type breadth (STAT + 11 other
	# types, per 1.0's histogram), routed through the registry instead of
	# STAT-only. ---
	print("=== GSDocMitchellHouse (full registry) ===")
	var cell: Dictionary = esm.find_cell_by_editor_id("GSDocMitchellHouse")
	check(not cell.is_empty(), "cell found")
	var refs: Array = esm.get_cell_references(int(cell["form_id"]))

	var by_class := {} # class name -> count
	var built := 0
	var skipped := 0
	var skipped_types := {}
	var root := Node3D.new()
	root.rotation_degrees.x = -90
	add_child(root)

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

	print("  built=", built, " skipped=", skipped)
	print("  by class: ", by_class)
	print("  skipped types: ", skipped_types)

	check(built > 200, "most of the cell's 434 refs built something (got %d)" % built)
	check(by_class.get("DoorNode", 0) == 2, "both DOOR refs became DoorNode (got %d)" % by_class.get("DoorNode", 0))
	check(by_class.get("ContainerNode", 0) == 11, "all 11 CONT refs became ContainerNode (got %d)" % by_class.get("ContainerNode", 0))
	# 4 of GSDocMitchellHouse's 11 ACTI refs (VCG01DocMitchellCouchTrigger,
	# VCG01DocMitchellChairTrigger, GSDocMitchellExitTrigger,
	# VCG01VigorTesterTrigger) genuinely have no MODL — invisible
	# trigger-only activators, confirmed by direct inspection, not a
	# registry bug. Correctly skipped, not built as empty ActivatorNodes.
	check(by_class.get("ActivatorNode", 0) == 7, "7/11 ACTI refs (the mesh-bearing ones) became ActivatorNode (got %d)" % by_class.get("ActivatorNode", 0))
	check(skipped_types.get("ACTI", 0) == 4, "4/11 ACTI refs (meshless triggers) skipped cleanly (got %d)" % skipped_types.get("ACTI", 0))
	check(by_class.get("FurnitureNode", 0) == 14, "all 14 FURN refs became FurnitureNode (got %d)" % by_class.get("FurnitureNode", 0))
	# 1.3: all 25 LIGH refs in this cell are meshless (a pure ambient/fill/
	# key rig, confirmed by direct inspection — see phases/1/01's Implementation
	# notes) but now build as LightNode via a real light, not a mesh.
	check(by_class.get("LightNode", 0) == 25, "all 25 LIGH refs became LightNode (got %d)" % by_class.get("LightNode", 0))
	# Structural fallback, exercised by real unregistered types (WEAP/ARMO/
	# ALCH), not a contrived one — see object_registry.gd.
	check(by_class.get("GamebryoVisual", 0) > 0,
			"unregistered-but-visual types (WEAP/ARMO/ALCH/...) rendered via the structural fallback (got %d)" % by_class.get("GamebryoVisual", 0))
	# SOUN has no MODL — genuinely unhandled, should be skipped, not crash.
	check(skipped_types.get("SOUN", 0) == 2, "SOUN (no mesh) skipped cleanly (got %d)" % skipped_types.get("SOUN", 0))

	await screenshot(root, "registry_doc_mitchell.png")

	# --- Deliberately exercise the fallback tier on a *registered* type:
	# temporarily unregister DOOR, confirm a door reference still resolves
	# (via the structural fallback, as a plain GamebryoVisual) instead of
	# being dropped, then re-register and confirm it goes back to DoorNode. ---
	print("=== deliberate fallback test (DOOR) ===")
	var door_placement = null
	for p in refs:
		if p["base_type"] == "DOOR":
			door_placement = p
			break
	check(door_placement != null, "found a DOOR placement to test with")
	if door_placement != null:
		check(registry.is_registered("DOOR"), "DOOR starts registered")
		var normal_node := registry.build(door_placement)
		check(normal_node is DoorNode, "DOOR resolves to DoorNode while registered")

		registry.unregister("DOOR")
		check(not registry.is_registered("DOOR"), "DOOR successfully unregistered")
		var fallback_node := registry.build(door_placement)
		check(fallback_node != null, "DOOR still resolves after unregistering (via structural fallback)")
		check(fallback_node != null and not (fallback_node is DoorNode) and fallback_node is GamebryoVisual,
				"fallback result is a plain GamebryoVisual, not DoorNode")

		registry.register("DOOR", func(p, r): return registry._build_door(p, r))
		var restored_node := registry.build(door_placement)
		check(restored_node is DoorNode, "DOOR resolves to DoorNode again after re-registering")

	# Real shipped placements, found by an ESM census rather than invented
	# dictionaries: TACT and TERM share HooverDamIntPowerPlant01b; MSTT is
	# in HooverDamIntPowerPlant01. These must be typed Nodes on CellLoader's
	# synchronous build() path, never generic GamebryoVisual fallback.
	print("=== TACT / TERM / MSTT typed-node registry dispatch ===")
	var dynamic_fixtures := [
		{ "cell": "HooverDamIntPowerPlant01", "type": "MSTT", "class": "MovableStaticNode" },
		{ "cell": "HooverDamIntPowerPlant01b", "type": "TACT", "class": "TalkingActivatorNode" },
		{ "cell": "HooverDamIntPowerPlant01b", "type": "TERM", "class": "TerminalNode" },
	]
	for fixture in dynamic_fixtures:
		var type_tag: String = fixture["type"]
		var placement := _first_placement_of_type(esm, fixture["cell"], type_tag)
		check(not placement.is_empty(), "found a real %s placement in %s" % [type_tag, fixture["cell"]])
		if placement.is_empty():
			continue
		var node := registry.build(placement)
		check(node != null, "real %s placement builds a Node" % type_tag)
		if node != null:
			var cls: String = String(node.get_script().get_global_name()) if node.get_script() else node.get_class()
			check(cls == fixture["class"], "real %s placement builds %s (got %s)" % [type_tag, fixture["class"], cls])
			node.free()

	# --- SCOL: SLGoldMine01INT has 3 real SCOL refs. ---
	print("=== SLGoldMine01INT (SCOL unpacking) ===")
	var scol_cell: Dictionary = esm.find_cell_by_editor_id("SLGoldMine01INT")
	check(not scol_cell.is_empty(), "SCOL test cell found")
	if not scol_cell.is_empty():
		var scol_refs: Array = esm.get_cell_references(int(scol_cell["form_id"]))
		var scol_count := 0
		var scol_root := Node3D.new()
		scol_root.rotation_degrees.x = -90
		add_child(scol_root)
		for p in scol_refs:
			if p["base_type"] != "SCOL":
				continue
			scol_count += 1
			var node := registry.build(p)
			check(node != null, "SCOL placement built a node")
			if node != null:
				check(node.get_child_count() > 0, "SCOL node has unpacked part children (got %d)" % node.get_child_count())
				for part in node.get_children():
					check(part is GamebryoVisual, "SCOL part is a GamebryoVisual-shaped node")
				scol_root.add_child(node)
		check(scol_count == 3, "found 3 SCOL refs in SLGoldMine01INT (got %d)" % scol_count)
		await screenshot(scol_root, "registry_scol_test.png")

	print("=== world_transform_no_parent() matches build()'s real Node global_transform (2.9/2.10) ===")
	# Caught directly, not hypothetical: RID-based objects (2.9's
	# DirectGeometryBatch, 2.10's threaded resolve/construct path) have no
	# RefrRoot parent to inherit the Z-up -> Y-up axis conversion from via
	# ordinary Godot parent-child transform composition the way a Node-based
	# placement does -- an earlier version of this fix omitted that
	# conversion entirely, producing a full missing 90-degree rotation (Y/Z
	# swapped) for every direct-path object, visible in real play as "the
	# persistent cell's content rotated into one big flat sheet." Still load-
	# bearing after build_direct() itself was retired (2.10 step 4 replaced
	# it with GamebryoObjectRegistry._construct_direct(), same transform
	# math) -- this checks the transform math directly, not the
	# now-removed function.
	var direct_target: Dictionary = {}
	for p in refs:
		# Same predicate build_direct()'s own is_structural_fallback() used --
		# no registered factory for base_type, not a marker, has a model.
		if not MarkerNode.is_marker_model(p.get("model", "")) and not registry.is_registered(String(p.get("base_type", ""))) and String(p.get("model", "")) != "":
			direct_target = p
			break
	check(not direct_target.is_empty(), "found a structural-fallback placement to test the direct-path transform against")
	if not direct_target.is_empty():
		var direct_refr_root := Node3D.new()
		direct_refr_root.rotation_degrees.x = -90
		add_child(direct_refr_root)
		var direct_node_ref := registry.build(direct_target)
		direct_refr_root.add_child(direct_node_ref)
		var expected_transform: Transform3D = direct_node_ref.global_transform

		var pos: Vector3 = direct_target.get("position", Vector3.ZERO)
		var rot: Vector3 = direct_target.get("rotation", Vector3.ZERO)
		var scale: float = direct_target.get("scale", 1.0)
		var got_transform: Transform3D = GamebryoMeshResolver.world_transform_no_parent(pos, rot, scale)
		check(got_transform.is_equal_approx(expected_transform),
				"world_transform_no_parent() matches build()'s real Node global_transform exactly (got origin %s, expected %s)" % [got_transform.origin, expected_transform.origin])

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
