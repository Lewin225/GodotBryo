extends Node3D

# Issue #56 ("Find and Implement reading near fade"): persistent-cell
# distant/skyline stand-in props (the Strip wall / McCarran skyline
# imposters etc, architecture\...\Imposter\...NIF) stayed fully visible up
# close, occluding real geometry. Real root cause, confirmed against live
# ESM data: these are standalone placements (not VWD-flagged, no
# _lod.nif pairing of their own) whose REFR carries the undocumented-but-
# real XSRF/XSRD subrecords -- confirmed 100%-consistent across a real
# 4468-ref WastelandNV persistent-cell census (every "*Imposter*"-model
# ref has one, zero without; the only other refs that carry it are the
# same conceptual class of distant Strip-skyline dressing under a
# different naming scheme). See ReferencePlacement::
# has_distant_skyline_marker's own doc comment (native/src/esm/esm_types.h)
# for the full census.
#
# Verifies: EsmReader actually surfaces has_distant_skyline_marker on a
# real REFR carrying XSRF/XSRD and NOT on an ordinary one, and that
# GamebryoMeshResolver.populate_mesh_children()'s is_distant_tile param
# actually writes a begin-only (no far bound) visibility range.

const DATA_DIR := "../fresh_nv_copy/Data/"

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

	print("=== real ESM data: an Imposter-model REFR carries has_distant_skyline_marker, an ordinary wall REFR doesn't ===")
	var wrld: Dictionary = esm.find_worldspace_by_editor_id("WastelandNV")
	check(not wrld.is_empty(), "found WastelandNV")
	var wrld_id := int(wrld["form_id"])

	var imposter_placement: Dictionary = {}
	var refs: Array = esm.get_persistent_refs_for_worldspace(wrld_id)
	for r in refs:
		if String(r.get("editor_id", "")) == "McCarranWallLongImposter":
			imposter_placement = r
			break
	check(not imposter_placement.is_empty(), "found a real McCarranWallLongImposter persistent placement")
	if not imposter_placement.is_empty():
		check(bool(imposter_placement.get("has_distant_skyline_marker", false)), "McCarranWallLongImposter has has_distant_skyline_marker == true")
		check(not bool(imposter_placement.get("visible_when_distant", false)), "McCarranWallLongImposter is NOT VWD-flagged (confirms it has no fade mechanism of its own via the usual per-object pairing)")

	var ordinary_placement: Dictionary = {}
	var cell: Dictionary = esm.find_exterior_cell(wrld_id, -5, 16)
	var cell_refs: Array = esm.get_cell_references(int(cell["form_id"]))
	for r in cell_refs:
		if String(r.get("editor_id", "")) == "NVMcCarranWall02":
			ordinary_placement = r
			break
	check(not ordinary_placement.is_empty(), "found a real NVMcCarranWall02 placement (the ordinary, non-imposter wall)")
	if not ordinary_placement.is_empty():
		check(not bool(ordinary_placement.get("has_distant_skyline_marker", false)), "NVMcCarranWall02 does NOT have has_distant_skyline_marker (it's an ordinary VWD-paired wall, not a skyline stand-in)")

	print("=== populate_mesh_children() applies a begin-only near-fade range when is_distant_tile is true ===")
	var resolver := GamebryoMeshResolver.new()
	resolver.set_distant_lod_range(300.0, 20.0)
	var parent := Node3D.new()
	add_child(parent)
	var geometry := {
		"mesh_entries": [{ "mesh": BoxMesh.new(), "transform": Transform3D.IDENTITY, "submesh_index": 0, "is_unlit": false }],
		"shape_entries": [],
		"lod_mesh_entries": [],
	}
	resolver.populate_mesh_children(parent, null, "", geometry, true)
	var mi: MeshInstance3D = null
	for c in parent.get_children():
		if c is MeshInstance3D:
			mi = c
	check(mi != null, "populate_mesh_children() built a MeshInstance3D for the distant tile")
	if mi != null:
		check(mi.visibility_range_begin == 300.0, "distant tile visibility_range_begin == near cutoff (got %s)" % mi.visibility_range_begin)
		check(mi.visibility_range_begin_margin == 20.0, "distant tile visibility_range_begin_margin == near margin (got %s)" % mi.visibility_range_begin_margin)
		check(mi.visibility_range_end == 0.0, "distant tile visibility_range_end == 0.0 (unbounded -- stays visible at any distance, like the skyline it is)")
	parent.queue_free()

	print("=== is_distant_tile == false (the default) leaves visibility_range untouched ===")
	var parent2 := Node3D.new()
	add_child(parent2)
	var geometry2 := {
		"mesh_entries": [{ "mesh": BoxMesh.new(), "transform": Transform3D.IDENTITY, "submesh_index": 0, "is_unlit": false }],
		"shape_entries": [],
		"lod_mesh_entries": [],
	}
	resolver.populate_mesh_children(parent2, null, "", geometry2)
	var mi2: MeshInstance3D = null
	for c in parent2.get_children():
		if c is MeshInstance3D:
			mi2 = c
	check(mi2 != null, "populate_mesh_children() built a MeshInstance3D for the ordinary case")
	if mi2 != null:
		check(mi2.visibility_range_begin == 0.0, "ordinary MeshInstance3D has NO visibility range set (got begin=%s)" % mi2.visibility_range_begin)
		check(mi2.visibility_range_end == 0.0, "ordinary MeshInstance3D has NO visibility range set (got end=%s)" % mi2.visibility_range_end)
	parent2.queue_free()

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
