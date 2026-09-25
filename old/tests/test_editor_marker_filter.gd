extends Node3D

# Rendering-issues punch-list item #4: EditorMarker submesh filtering. See
# GamebryoMeshResolver.resolve_raw_geometry()'s own doc comment.

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func _ready() -> void:
	check(GamebryoMeshResolver._is_editor_marker_submesh("EditorMarker:0"), "matches the real 'EditorMarker:0' naming seen in real data")
	check(GamebryoMeshResolver._is_editor_marker_submesh("EDITORMARKER:0"), "case-insensitive")
	check(GamebryoMeshResolver._is_editor_marker_submesh("EditorMarker"), "matches with no suffix too")
	check(not GamebryoMeshResolver._is_editor_marker_submesh("DustBillBoard01:0"), "does not match a real effect submesh's own name")
	check(not GamebryoMeshResolver._is_editor_marker_submesh("VulturesGroup03:0"), "does not match another real submesh's name")

	print("=== real data: resolve_raw_geometry() excludes EditorMarker outside editor-preview ===")
	check(not Engine.is_editor_hint(), "sanity: this headless test run is NOT editor-hint mode (the real-play case)")
	var resolver := GamebryoMeshResolver.new()
	var model := "Effects\\Ambient\\FXDustMeshSky01.NIF"
	var nif := resolver.load_nif(model)
	check(nif != null, "loaded the real dust-effect NIF")
	if nif != null:
		check(nif.get_submesh_count() == 2, "the NIF itself still has both submeshes (got %d)" % nif.get_submesh_count())
		var raw := resolver.resolve_raw_geometry(nif, model)
		check(raw["mesh_entries"].size() == 1, "resolve_raw_geometry() excluded the EditorMarker submesh (got %d mesh_entries)" % raw["mesh_entries"].size())

	print("=== a NIF that is ONLY an EditorMarker (no real effect geometry) resolves to zero mesh_entries ===")
	var marker_only_model := "Effects\\Ambient\\FXAmbDust02.NIF"
	var marker_only_nif := resolver.load_nif(marker_only_model)
	check(marker_only_nif != null, "loaded the marker-only NIF")
	if marker_only_nif != null:
		check(marker_only_nif.get_submesh_count() == 1, "the NIF itself has exactly 1 submesh (the marker)")
		var raw2 := resolver.resolve_raw_geometry(marker_only_nif, marker_only_model)
		check(raw2["mesh_entries"].size() == 0, "resolve_raw_geometry() excludes it entirely -- correctly renders nothing rather than a stray marker (got %d)" % raw2["mesh_entries"].size())

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
