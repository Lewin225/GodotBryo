class_name TerrainGrassParticles
extends Node3D

## Owns the Terrain3D GPU-particle grass variants for one active worldspace.
## This deliberately begins by discovering only variants actually referenced
## by streamed LAND data; it never pre-creates particle grids for all 17
## vanilla NIF/material combinations.

var terrain: Terrain3D
var bridge: Terrain3DBridge
var esm: EsmReader
var resolver: GamebryoMeshResolver

## grass FormID -> { data: GRAS dictionary, ltex_slots: PackedInt32Array }
## The later emitter build uses `ltex_slots` in the N=7 GPU filter shader.
var active_variants: Dictionary = {}
## "grass FormID:LTEX slot" -> { material: ShaderMaterial, node: GPUParticles3D }
## One emitter per actual GNAM relationship makes the GPU filter a scalar
## comparison, rather than relying on a fixed-length array uniform.
var _emitters: Dictionary = {}
var _last_grid_origin := Vector3.INF
var _last_observed_cell_form_id := 0
var _last_observed_ltex_ids: Array[int] = []
var _debug_coverage_origin := Vector3.INF
var _debug_coverage := {}
var _particle_shader := preload("res://gamebryo/terrain_grass_particles.gdshader") as Shader

# The restart origin must move in an integral number of particle-lattice steps.
# 16 × √½ m preserves every candidate's world position after a grid rebase.
const CANDIDATE_SPACING_METERS := 0.70710678
const GRID_RESTART_SNAP_METERS := CANDIDATE_SPACING_METERS * 16.0

func _init(p_terrain: Terrain3D, p_bridge: Terrain3DBridge, p_esm: EsmReader, p_resolver: GamebryoMeshResolver) -> void:
	terrain = p_terrain
	bridge = p_bridge
	esm = p_esm
	resolver = p_resolver
	name = "TerrainGrassParticles"

## Called immediately after Terrain3DBridge.import_cell().  It records every
## real BTXT/ATXT LTEX used by the cell and every GRAS it links via GNAM.  A
## grass definition can be linked by more than one terrain texture, hence the
## per-variant slot set rather than one guessed source texture.
func observe_cell(cell_form_id: int, source_coord: Vector2i) -> void:
	var land: Dictionary = esm.get_land_data(cell_form_id)
	if land.is_empty():
		return
	var ltex_ids: Dictionary = {}
	for ltex_id: int in land.get("quadrant_base_ltex", PackedInt64Array()):
		if ltex_id != 0:
			ltex_ids[ltex_id] = true
	for layer: Dictionary in land.get("alpha_layers", []):
		var ltex_id: int = int(layer.get("ltex_form_id", 0))
		if ltex_id != 0:
			ltex_ids[ltex_id] = true
	for ltex_id: int in ltex_ids:
		var slot: int = bridge.get_ltex_slot(ltex_id)
		if slot < 0:
			continue
		var linked_grass_ids: Array = esm.get_ltex_grass_form_ids(ltex_id)
		for choice_index in range(linked_grass_ids.size()):
			var grass_id: int = linked_grass_ids[choice_index]
			if not active_variants.has(grass_id):
				var grass: Dictionary = esm.get_grass_data(grass_id)
				if grass.is_empty():
					continue
				active_variants[grass_id] = { "data": grass, "ltex_slots": PackedInt32Array() }
			var slots: PackedInt32Array = active_variants[grass_id]["ltex_slots"]
			if not slots.has(slot):
				slots.append(slot)
				active_variants[grass_id]["ltex_slots"] = slots
			_ensure_emitter(grass_id, slot, choice_index, linked_grass_ids.size(), source_coord, false)
			_ensure_emitter(grass_id, slot, choice_index, linked_grass_ids.size(), source_coord, true)
	# Terrain3D replaces/updates its 32x32 region lookup as LAND tiles stream.
	# A shader uniform receives the PackedInt32Array by value, so all existing
	# variants must be rebound after each import rather than retaining the map
	# that happened to exist when their emitter was first created.
	for record: Dictionary in _emitters.values():
		_bind_variant(record["material"], record["grass"], record["ltex_slot"], record["choice_index"], record["choice_count"], record["outer_lod"])
	var camera := terrain.get_camera()
	if camera != null:
		_update_local_emitter_visibility(camera)
	_last_observed_cell_form_id = cell_form_id
	_last_observed_ltex_ids.clear()
	for ltex_id: int in ltex_ids:
		_last_observed_ltex_ids.append(ltex_id)

func get_active_variant_count() -> int:
	return active_variants.size()

func get_debug_summary() -> PackedStringArray:
	var lines := PackedStringArray()
	var expected_slots: Dictionary = {}
	var readback_slots: Dictionary = {}
	var selector_mismatches := 0
	for record: Dictionary in _emitters.values():
		var expected: int = record["ltex_slot"]
		var readback_value = (record["material"] as ShaderMaterial).get_shader_parameter("target_slot")
		var readback: int = int(readback_value) if readback_value != null else -9999
		expected_slots[expected] = true
		readback_slots[readback] = true
		if readback != expected:
			selector_mismatches += 1
	lines.append("grass: %d live emitters / %d GRAS variants / %d prewarmed LTEX slots" % [_emitters.size(), active_variants.size(), bridge.get_ltex_slot_count()])
	lines.append("selector readback: %d expected slots / %d actual slots / %d mismatches" % [expected_slots.size(), readback_slots.size(), selector_mismatches])
	var camera := terrain.get_camera()
	if camera != null:
		var sample_pos := Vector3(camera.global_position.x, 0.0, camera.global_position.z)
		var ids_a: Color = terrain.data.get_pixel(Terrain3DRegion.TYPE_TEX_ID_A, sample_pos)
		var ids_b: Color = terrain.data.get_pixel(Terrain3DRegion.TYPE_TEX_ID_B, sample_pos)
		var weights_a: Color = terrain.data.get_pixel(Terrain3DRegion.TYPE_WEIGHT_A, sample_pos)
		var weights_b: Color = terrain.data.get_pixel(Terrain3DRegion.TYPE_WEIGHT_B, sample_pos)
		lines.append("camera N=7 IDs: [%d, %d, %d, %d, %d, %d, %d]" % [roundi(ids_a.r * 255.0), roundi(ids_a.g * 255.0), roundi(ids_a.b * 255.0), roundi(ids_a.a * 255.0), roundi(ids_b.r * 255.0), roundi(ids_b.g * 255.0), roundi(ids_b.b * 255.0)])
		lines.append("camera N=7 weights: [1.00, %.2f, %.2f, %.2f, %.2f, %.2f, %.2f]" % [weights_a.r, weights_a.g, weights_a.b, weights_a.a, weights_b.r, weights_b.g])
		lines.append("64m CPU terrain coverage for live grass slots: %s" % _get_debug_coverage(camera))
	if _last_observed_cell_form_id == 0:
		return lines
	lines.append("last grass-scanned cell: 0x%08X" % _last_observed_cell_form_id)
	for ltex_id: int in _last_observed_ltex_ids:
		var grass_names := PackedStringArray()
		for grass_id: int in esm.get_ltex_grass_form_ids(ltex_id):
			var grass: Dictionary = esm.get_grass_data(grass_id)
			grass_names.append(String(grass.get("editor_id", "%08X" % grass_id)))
		lines.append("  LTEX 0x%08X (slot %d): %s" % [ltex_id, bridge.get_ltex_slot(ltex_id), ", ".join(grass_names) if not grass_names.is_empty() else "no GRAS"])
	return lines

func _get_debug_coverage(camera: Camera3D) -> String:
	var origin := Vector3(camera.global_position.x, 0.0, camera.global_position.z).snapped(Vector3(GRID_RESTART_SNAP_METERS, 1.0, GRID_RESTART_SNAP_METERS))
	if origin != _debug_coverage_origin:
		_debug_coverage_origin = origin
		_debug_coverage.clear()
		var targets: Dictionary = {}
		for record: Dictionary in _emitters.values():
			targets[record["ltex_slot"]] = true
		# Match the particle grid's one-metre candidate spacing, rather than
		# Terrain3D's coarser vertex spacing, so narrow painted strips cannot
		# be missed by this CPU diagnostic.
		var spacing := 1.0
		var half_width := 32.0
		for x in range(ceili(-half_width / spacing), ceili(half_width / spacing) + 1):
			for z in range(ceili(-half_width / spacing), ceili(half_width / spacing) + 1):
				var pos := origin + Vector3(float(x) * spacing, 0.0, float(z) * spacing)
				var ids_a: Color = terrain.data.get_pixel(Terrain3DRegion.TYPE_TEX_ID_A, pos)
				var ids_b: Color = terrain.data.get_pixel(Terrain3DRegion.TYPE_TEX_ID_B, pos)
				var weights_a: Color = terrain.data.get_pixel(Terrain3DRegion.TYPE_WEIGHT_A, pos)
				var weights_b: Color = terrain.data.get_pixel(Terrain3DRegion.TYPE_WEIGHT_B, pos)
				var ids := PackedInt32Array([roundi(ids_a.r * 255.0), roundi(ids_a.g * 255.0), roundi(ids_a.b * 255.0), roundi(ids_a.a * 255.0), roundi(ids_b.r * 255.0), roundi(ids_b.g * 255.0), roundi(ids_b.b * 255.0)])
				var alpha := PackedFloat32Array([1.0, weights_a.r, weights_a.g, weights_a.b, weights_a.a, weights_b.r, weights_b.g])
				for i in range(7):
					var contribution := 1.0 if i == 0 else clampf(alpha[i], 0.0, 1.0)
					for later in range(i + 1, 7):
						contribution *= 1.0 - clampf(alpha[later], 0.0, 1.0)
					if targets.has(ids[i]) and contribution > 0.01:
						_debug_coverage[ids[i]] = float(_debug_coverage.get(ids[i], 0.0)) + contribution
	if _debug_coverage.is_empty():
		return "none"
	var entries := PackedStringArray()
	for slot: int in _debug_coverage:
		entries.append("slot %d=%.1f" % [slot, _debug_coverage[slot]])
	return ", ".join(entries)

func _process(_delta: float) -> void:
	var camera := terrain.get_camera()
	if camera == null:
		return
	var origin := Vector3(camera.global_position.x, 0.0, camera.global_position.z).snapped(Vector3(8.0, 1.0, 8.0))
	if origin == _last_grid_origin:
		return
	_last_grid_origin = origin
	_update_local_emitter_visibility(camera)
	for record: Dictionary in _emitters.values():
		var material: ShaderMaterial = record["material"]
		RenderingServer.material_set_param(material.get_rid(), "emitter_origin", origin)
		# `start()` evaluates only when particles are emitted.  Restarting at an
		# 8 m snapped camera move makes this one local grid follow the player,
		# rather than leaving it at the spawn position forever.
		(record["node"] as GPUParticles3D).restart(true)

func _update_local_emitter_visibility(camera: Camera3D) -> void:
	# This is deliberately based on the imported N=7 maps around the camera,
	# not an emitter's source cell.  A grass definition discovered elsewhere is
	# still valid if its LTEX is painted here; conversely, a globally-known
	# variant with zero local texture coverage must not submit its particles.
	_get_debug_coverage(camera)
	for record: Dictionary in _emitters.values():
		(record["node"] as GPUParticles3D).visible = _debug_coverage.has(record["ltex_slot"])

func _ensure_emitter(grass_id: int, ltex_slot: int, choice_index: int, choice_count: int, source_coord: Vector2i, outer_lod: bool) -> void:
	var emitter_key := "%08X:%d:%s" % [grass_id, ltex_slot, "outer" if outer_lod else "inner"]
	if _emitters.has(emitter_key):
		var existing: Dictionary = _emitters[emitter_key]
		existing["source_cells"][source_coord] = true
		_bind_variant(existing["material"], existing["grass"], ltex_slot, choice_index, choice_count, outer_lod)
		return
	var grass: Dictionary = active_variants[grass_id]["data"]
	var model_path := String(grass.get("model_path", ""))
	var nif := resolver.load_nif(model_path)
	if nif == null:
		push_warning("TerrainGrassParticles: failed to load %s" % model_path)
		return
	var geometry := resolver.build_geometry_entries(resolver.resolve_raw_geometry(nif, model_path))
	var entries: Array = geometry.get("mesh_entries", [])
	if entries.is_empty():
		push_warning("TerrainGrassParticles: %s has no renderable mesh entries" % model_path)
		return
	var material := ShaderMaterial.new()
	material.shader = _particle_shader
	_bind_variant(material, grass, ltex_slot, choice_index, choice_count, outer_lod)
	var emitter := GPUParticles3D.new()
	emitter.name = "Grass_%s%s" % [String(grass.get("editor_id", "%08X" % grass_id)), "_Outer" if outer_lod else ""]
	# Dense local ring plus a much sparser outer ring provide a useful fade
	# radius without multiplying transparent card cost by four.
	emitter.amount = 1024 if outer_lod else 8464
	emitter.lifetime = 600.0
	emitter.explosiveness = 1.0
	emitter.process_material = material
	emitter.draw_pass_1 = _to_billboard_y_up_mesh(entries[0]["mesh"], entries[0]["transform"])
	# Particle positions are generated in world coordinates in the process
	# shader while this emitter remains parented at the world origin.  Godot
	# cannot infer that volume from the cube mesh, so a tight/default AABB would
	# cull every particle once the player is away from origin.
	emitter.custom_aabb = AABB(Vector3(-100000.0, -1000.0, -100000.0), Vector3(200000.0, 2000.0, 200000.0))
	emitter.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Grass is dynamic alpha-tested detail and should neither cast shadows nor
	# participate in SDFGI.  Be explicit rather than relying on the particle
	# node's default GeometryInstance mode.
	emitter.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	emitter.use_fixed_seed = true
	emitter.emitting = true
	add_child(emitter)
	_emitters[emitter_key] = { "material": material, "node": emitter, "grass": grass, "ltex_slot": ltex_slot, "choice_index": choice_index, "choice_count": choice_count, "outer_lod": outer_lod, "source_cells": { source_coord: true } }
	if _last_grid_origin.is_finite():
		RenderingServer.material_set_param(material.get_rid(), "emitter_origin", _last_grid_origin)
		emitter.restart(true)

func _to_billboard_y_up_mesh(source: ArrayMesh, source_transform: Transform3D) -> ArrayMesh:
	# Ordinary NIF nodes live under WorldStreamer's -90° RefrRoot.  Particle
	# draw meshes do not, so first bake the NIF submesh's flattened transform,
	# then rotate its stored Z-up vertices once here rather than rotating the
	# emitter (which would also rotate GPU world placement).
	var arrays := source.surface_get_arrays(0)
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for i in range(positions.size()):
		var p := source_transform * positions[i]
		positions[i] = Vector3(p.x, p.z, -p.y)
	var lowest_y := INF
	for p: Vector3 in positions:
		lowest_y = minf(lowest_y, p.y)
	# Particle placement is the sampled terrain height.  Rebase the fully
	# transformed clump there so an authored NIF root/negative local extent
	# cannot leave its grass visibly floating above the ground.
	for i in range(positions.size()):
		positions[i].y -= lowest_y
	arrays[Mesh.ARRAY_VERTEX] = positions
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	for i in range(normals.size()):
		var n := source_transform.basis * normals[i]
		normals[i] = Vector3(n.x, n.z, -n.y)
	arrays[Mesh.ARRAY_NORMAL] = normals
	var result := ArrayMesh.new()
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var source_material := source.surface_get_material(0)
	if source_material is StandardMaterial3D:
		# Preserve the real DDS diffuse/alpha-scissor material.  The clump mesh
		# is kept in its authored orientation rather than billboarded.
		var grass_material := (source_material as StandardMaterial3D).duplicate() as StandardMaterial3D
		grass_material.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED
		grass_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		# Retain the material's real NiAlphaProperty mapping.  The actual
		# Alpha hash with the visually tuned zero scale preserves fine foliage
		# coverage.  Alpha scissor was profiled as only a marginal improvement,
		# so it is not worth sacrificing this material's edge quality.
		grass_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_HASH
		grass_material.alpha_hash_scale = 0.0
		grass_material.alpha_antialiasing_edge = 0.05
		grass_material.alpha_antialiasing_mode = BaseMaterial3D.ALPHA_ANTIALIASING_ALPHA_TO_COVERAGE
		grass_material.texture_repeat = false
		# Cheap foliage transmission: backlight is a single material feature
		# intended to approximate light through thin surfaces.  It keeps the
		# shadow-facing side of grass readable without screen-space SSS and its
		# transmittance/depth-prepass cost.
		grass_material.subsurf_scatter_enabled = false
		grass_material.subsurf_scatter_transmittance_enabled = false
		grass_material.backlight_enabled = true
		grass_material.backlight = Color(0.3, 0.3, 0.25, 1.0)
		result.surface_set_material(0, grass_material)
	else:
		result.surface_set_material(0, source_material)
	return result

func _bind_variant(material: ShaderMaterial, grass: Dictionary, ltex_slot: int, choice_index: int, choice_count: int, outer_lod: bool = false) -> void:
	# These are per-emitter scalar shader parameters.  Use ShaderMaterial's
	# owning API as the authoritative write (the RenderingServer calls below
	# are still required for Terrain3D's RID-backed texture arrays).
	material.set_shader_parameter("target_slot", ltex_slot)
	material.set_shader_parameter("grass_choice_index", choice_index)
	material.set_shader_parameter("grass_choice_count", choice_count)
	# Deliberately denser than the original authored setting for this first
	# Terrain3D particle pass.  Keep the multiplier here (not in ESM parsing)
	# so the verified GRAS.DATA density remains available unchanged.
	material.set_shader_parameter("grass_density", float(grass.get("density", 0)) / 5.0)
	RenderingServer.material_set_param(material.get_rid(), "target_slot", ltex_slot)
	RenderingServer.material_set_param(material.get_rid(), "grass_choice_index", choice_index)
	RenderingServer.material_set_param(material.get_rid(), "grass_choice_count", choice_count)
	RenderingServer.material_set_param(material.get_rid(), "grass_density", float(grass.get("density", 0)) / 5.0)
	RenderingServer.material_set_param(material.get_rid(), "min_slope_degrees", float(grass.get("min_slope", 0)))
	RenderingServer.material_set_param(material.get_rid(), "max_slope_degrees", float(grass.get("max_slope", 90)))
	RenderingServer.material_set_param(material.get_rid(), "fit_to_slope", (int(grass.get("flags", 0)) & 4) != 0)
	RenderingServer.material_set_param(material.get_rid(), "position_range", float(grass.get("position_range", 0.0)) * Terrain3DBridge.GAMEBRYO_UNITS_TO_METERS)
	if outer_lod:
		# 32×32 at 4 m: only the 24–64 m annulus survives in the shader.
		RenderingServer.material_set_param(material.get_rid(), "instance_spacing", 4.0)
		RenderingServer.material_set_param(material.get_rid(), "instance_rows", 32)
		RenderingServer.material_set_param(material.get_rid(), "ring_inner_distance", 24.0)
		RenderingServer.material_set_param(material.get_rid(), "fade_start_distance", 24.0)
		RenderingServer.material_set_param(material.get_rid(), "fade_end_distance", 64.0)
	else:
		# 92×92 at √½ m: dense 0–32 m local ring.
		RenderingServer.material_set_param(material.get_rid(), "instance_spacing", CANDIDATE_SPACING_METERS)
		RenderingServer.material_set_param(material.get_rid(), "instance_rows", 92)
		RenderingServer.material_set_param(material.get_rid(), "ring_inner_distance", 0.0)
		RenderingServer.material_set_param(material.get_rid(), "fade_start_distance", 30.0)
		RenderingServer.material_set_param(material.get_rid(), "fade_end_distance", 32.0)
	# A deterministic fractional grid phase per real LTEX slot.  This is not
	# a visual random seed: every GRAS choice belonging to this LTEX receives
	# the exact same phase, preserving their shader-side exclusive selection.
	var phase := Vector2(fposmod(float(ltex_slot) * 0.754877666, 1.0), fposmod(float(ltex_slot) * 0.569840291, 1.0))
	material.set_shader_parameter("placement_phase", phase)
	RenderingServer.material_set_param(material.get_rid(), "placement_phase", phase)
	RenderingServer.material_set_param(material.get_rid(), "vertex_spacing", terrain.vertex_spacing)
	RenderingServer.material_set_param(material.get_rid(), "region_size", terrain.region_size)
	RenderingServer.material_set_param(material.get_rid(), "region_map", terrain.data.get_region_map())
	RenderingServer.material_set_param(material.get_rid(), "height_maps", terrain.data.get_height_maps_rid())
	RenderingServer.material_set_param(material.get_rid(), "tex_id_a_maps", terrain.data.get_tex_id_a_maps_rid())
	RenderingServer.material_set_param(material.get_rid(), "tex_id_b_maps", terrain.data.get_tex_id_b_maps_rid())
	RenderingServer.material_set_param(material.get_rid(), "weight_a_maps", terrain.data.get_weight_a_maps_rid())
	RenderingServer.material_set_param(material.get_rid(), "weight_b_maps", terrain.data.get_weight_b_maps_rid())
