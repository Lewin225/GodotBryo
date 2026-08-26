extends Node

## Issue #26: real additive BSShaderNoLightingProperty effects must not be
## illuminated by nearby LIGH nodes. FXLightBeamW03 is placed in
## GSGeneralStore directly around a BasementLightKeyNeutral OmniLight.

var failures := 0

const ESM_PATH := "../fresh_nv_copy/Data/FalloutNV.esm"

func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1

func _ready() -> void:
	var esm := EsmReader.new()
	check(esm.open(ESM_PATH), "opened FalloutNV.esm for GSGeneralStore XEMI evidence")
	if esm.get_last_error() == "":
		var cell: Dictionary = esm.find_cell_by_editor_id("GSGeneralStore")
		var beam_ref: Dictionary = {}
		var ray_ref: Dictionary = {}
		var window_ref: Dictionary = {}
		for placement in esm.get_cell_references(int(cell.get("form_id", 0))):
			if int(placement.get("refr_form_id", 0)) == 0x124279:
				beam_ref = placement
			elif int(placement.get("refr_form_id", 0)) == 0x10AAD4:
				ray_ref = placement
			elif int(placement.get("refr_form_id", 0)) == 0x103E1D:
				window_ref = placement
		check(int(beam_ref.get("emittance_form_id", 0)) == 0x4DFDB,
			"FXLightBeamW03 retains its authored XEMI LIGH link")
		var beam_emittance: Dictionary = esm.get_emittance_data(int(beam_ref.get("emittance_form_id", 0)))
		var beam_color: Color = beam_emittance.get("color", Color.BLACK)
		check(is_equal_approx(beam_color.r, 173.0 / 255.0)
			and is_equal_approx(beam_color.g, 170.0 / 255.0)
			and is_equal_approx(beam_color.b, 160.0 / 255.0),
			"beam XEMI resolves OfficeLightKeyNeutral's real RGB")
		check(int(ray_ref.get("emittance_form_id", 0)) == 0x169BD1,
			"light-ray static retains its authored XEMI REGN link")
		check(not esm.get_emittance_data(int(ray_ref.get("emittance_form_id", 0))).is_empty(),
			"REGN XEMI resolves its authored RCLR colour")
		var registry := GamebryoObjectRegistry.new(GamebryoMeshResolver.new(), esm)
		var beam_node := registry.build(beam_ref)
		check(beam_node != null and beam_node.get_child_count() == 1,
			"editor/node construction retains the XEMI beam visual")
		if beam_node != null and beam_node.get_child_count() == 1:
			var mesh_child := beam_node.get_child(0) as MeshInstance3D
			var tint_material := mesh_child.material_override as ShaderMaterial if mesh_child != null else null
			var tint: Color = tint_material.get_shader_parameter("emittance_tint") if tint_material != null else Color.BLACK
			check(tint_material != null and is_equal_approx(tint.r, 173.0 / 255.0),
				"XEMI applies a per-reference material tint rather than changing the shared mesh material")
		var docs_cell: Dictionary = esm.find_cell_by_editor_id("GSDocMitchellHouse")
		for placement in esm.get_cell_references(int(docs_cell.get("form_id", 0))):
			if int(placement.get("refr_form_id", 0)) == 0x103E1D:
				window_ref = placement
		var window_node := registry.build(window_ref)
		var window_mesh_count := 0
		var tinted_window_mesh_count := 0
		if window_node != null:
			for child in window_node.get_children():
				if child is MeshInstance3D:
					window_mesh_count += 1
					if child.material_override is StandardMaterial3D:
						tinted_window_mesh_count += 1
		check(window_mesh_count > 1 and tinted_window_mesh_count == 1,
			"XEMI tints only the window model's authored NoLighting glass, not its construction submeshes")

	var resolver := GamebryoMeshResolver.new()
	const MODEL_PATH := "Effects\\Ambient\\FXLightBeamW03.NIF"
	var nif := resolver.load_nif(MODEL_PATH)
	check(nif != null, "loaded real GSGeneralStore light-beam NIF")
	if nif != null:
		var raw := resolver.resolve_raw_geometry(nif, MODEL_PATH)
		var raw_entries: Array = raw.get("mesh_entries", [])
		check(raw_entries.size() == 1, "runtime filtering retains only the visible beam shape")
		if raw_entries.size() == 1:
			var entry: Dictionary = raw_entries[0]
			var alpha: Dictionary = entry.get("alpha_info", {})
			check(bool(entry.get("is_unlit", false)), "beam is authored with BSShaderNoLightingProperty")
			check(bool(alpha.get("blend_enabled", false)) and int(alpha.get("blend_func", 0)) == 1,
				"beam retains authored additive SRC_ALPHA-to-ONE blend")
			var built := resolver.build_geometry_entries(raw)
			var mesh_entries: Array = built.get("mesh_entries", [])
			check(mesh_entries.size() == 1, "built one renderable beam mesh")
			if mesh_entries.size() == 1:
				var mesh: ArrayMesh = mesh_entries[0]["mesh"]
				var material := mesh.surface_get_material(0) as ShaderMaterial
				check(material != null, "beam has the authored-falloff ShaderMaterial")
				if material != null:
					check(is_equal_approx(float(material.get_shader_parameter("falloff_start_angle")), 0.98480773)
						and is_equal_approx(float(material.get_shader_parameter("falloff_stop_angle")), 0.17364822)
						and is_equal_approx(float(material.get_shader_parameter("falloff_stop_opacity")), 0.0),
						"beam preserves its real per-pixel NoLighting falloff values")

	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
