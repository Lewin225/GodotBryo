extends Node3D

# Issue #56 ("Find and Implement reading near fade"): persistent-cell
# distant/skyline LOD tiles (meshes\landscape\lod\<world>\blocks\...,
# e.g. the Strip wall / McCarran) had no near-distance cutoff at all, so
# they stayed fully visible and occluded LOD0 geometry up close. Verifies:
# GamebryoMeshResolver.is_terrain_only_lod_tile_path()/
# is_distant_object_lod_tile_path() classify real BSA paths correctly
# (including the confirmed-safe exclusions: ordinary objects and the
# Strip's "always visible" glow card), and that
# populate_mesh_children()/_apply_distant_lod_visibility_range() actually
# write a begin-only (no far bound) visibility range onto a distant tile's
# MeshInstance3D children.

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func _ready() -> void:
	print("=== path classification (real BSA path shapes, confirmed via issue #56 investigation) ===")
	var terrain_only_paths := [
		"Landscape\\LOD\\TheStripWorldNew\\TheStripWorldNew.Level4.X0.Y0.nif",
		"Landscape\\LOD\\WastelandNVMini\\WastelandNVMini.Level16.X0.Y-16.nif",
		"landscape\\lod\\freesidenorthworld\\freesidenorthworld.level32.x-1.y1.nif",
	]
	for p in terrain_only_paths:
		check(GamebryoMeshResolver.is_terrain_only_lod_tile_path(p), "%s classified as terrain-only (skip)" % p)
		check(not GamebryoMeshResolver.is_distant_object_lod_tile_path(p), "%s NOT classified as a distant object tile" % p)

	var distant_object_paths := [
		"Landscape\\LOD\\TheStripWorldNew\\Blocks\\TheStripWorldNew.Level4.X0.Y0.nif",
		"landscape\\lod\\freesideworld\\blocks\\freesideworld.level4.x-2.y-4.nif",
	]
	for p in distant_object_paths:
		check(GamebryoMeshResolver.is_distant_object_lod_tile_path(p), "%s classified as a distant object tile (near-fade)" % p)
		check(not GamebryoMeshResolver.is_terrain_only_lod_tile_path(p), "%s NOT classified as terrain-only" % p)

	# Confirmed-safe exclusions (per issue #56 investigation): an ordinary
	# object, and the Strip's "always visible" glow card -- neither lives
	# under landscape\lod\, so neither should ever be touched by this
	# near-fade mechanism.
	var excluded_paths := [
		"Architecture\\Barracks\\Barracks01.nif",
		"Architecture\\Strip\\Imposter\\FXGlowSimpleFillHalf01Imposter.nif",
	]
	for p in excluded_paths:
		check(not GamebryoMeshResolver.is_terrain_only_lod_tile_path(p), "%s NOT classified as terrain-only" % p)
		check(not GamebryoMeshResolver.is_distant_object_lod_tile_path(p), "%s NOT classified as a distant object tile" % p)

	print("=== populate_mesh_children() applies a begin-only near-fade range to a distant tile's MeshInstance3D children ===")
	var resolver := GamebryoMeshResolver.new()
	resolver.set_distant_lod_range(300.0, 20.0)
	var parent := Node3D.new()
	add_child(parent)
	var geometry := {
		"mesh_entries": [{ "mesh": BoxMesh.new(), "transform": Transform3D.IDENTITY, "submesh_index": 0, "is_unlit": false }],
		"shape_entries": [],
		"lod_mesh_entries": [],
	}
	resolver.populate_mesh_children(parent, null, "Landscape\\LOD\\TheStripWorldNew\\Blocks\\TheStripWorldNew.Level4.X0.Y0.nif", geometry)
	var mi: MeshInstance3D = null
	for c in parent.get_children():
		if c is MeshInstance3D:
			mi = c
	check(mi != null, "populate_mesh_children() built a MeshInstance3D for the distant tile")
	if mi != null:
		check(mi.visibility_range_begin == 300.0, "distant tile visibility_range_begin == near cutoff (got %s)" % mi.visibility_range_begin)
		check(mi.visibility_range_begin_margin == 20.0, "distant tile visibility_range_begin_margin == near margin (got %s)" % mi.visibility_range_begin_margin)
		check(mi.visibility_range_end == 0.0, "distant tile visibility_range_end == 0.0 (unbounded -- stays visible at any distance, like the skyline it is)" % [])
	parent.queue_free()

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
