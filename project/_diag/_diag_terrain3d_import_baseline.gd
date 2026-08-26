extends Node3D

# Deliberately bare issue-19 import benchmark. It imports a fixed real LAND
# sample through Terrain3DBridge, but never creates WorldStreamer, REFRs, grass,
# DirectGeometryBatch, physics, or a streaming queue. Its timings are therefore
# the current main-thread Terrain3D/LAND import baseline, not whole-tile cost.

const GameDataConfigScript := preload("res://game_data_config.gd")
const WORLDSPACE_EDITOR_ID := "WastelandNV"
const CENTER := Vector2i(-17, 0) # Goodsprings; fixed and repeatable real sample.
const RADIUS := 3 # 7x7 cells, matching the prior direct-stream benchmark.

func _percentile_report(label: String, values: Array) -> void:
	if values.is_empty():
		print(label, ": no samples")
		return
	var sorted: Array = values.duplicate()
	sorted.sort()
	var total := 0.0
	for value in sorted:
		total += value
	var n := sorted.size()
	print("%s: n=%d avg=%.2f median=%.2f p95=%.2f max=%.2f sum=%.2f" % [
		label, n, total / n, sorted[n / 2], sorted[int(n * 0.95)], sorted[n - 1], total,
	])

func _run_pass(label: String, esm: EsmReader, wrld_id: int, terrain: Terrain3D,
		bridge: Terrain3DBridge, grass: TerrainGrassParticles) -> void:
	var samples := {
		"LAND/grid lookup": [], "region preparation": [], "LTEX/texture resolution": [],
		"  diffuse DDS decode/upload": [], "  normal DDS decode/upload": [],
		"  Terrain3D texture-pool insert": [], "CPU map writes": [],
		"Terrain3D publication": [], "collision refresh": [], "grass binding": [],
		"bridge.import_cell total": [],
	}
	var imported := 0
	for dx in range(-RADIUS, RADIUS + 1):
		for dy in range(-RADIUS, RADIUS + 1):
			var coord := CENTER + Vector2i(dx, dy)
			var cell: Dictionary = esm.find_exterior_cell(wrld_id, coord.x, coord.y)
			if cell.is_empty():
				continue
			if bridge.import_cell(terrain, int(cell["form_id"])):
				imported += 1
				var timings: Dictionary = bridge.last_import_timings
				samples["LAND/grid lookup"].append(float(timings.get("land_lookup_ms", 0.0)))
				samples["region preparation"].append(float(timings.get("region_prepare_ms", 0.0)))
				samples["LTEX/texture resolution"].append(float(timings.get("ltex_resolution_ms", 0.0)))
				samples["  diffuse DDS decode/upload"].append(float(timings.get("diffuse_load_ms", 0.0)))
				samples["  normal DDS decode/upload"].append(float(timings.get("normal_load_ms", 0.0)))
				samples["  Terrain3D texture-pool insert"].append(float(timings.get("texture_pool_insert_ms", 0.0)))
				samples["CPU map writes"].append(float(timings.get("cpu_map_writes_ms", 0.0)))
				samples["Terrain3D publication"].append(float(timings.get("publish_ms", 0.0)))
				samples["bridge.import_cell total"].append(float(timings.get("total_ms", 0.0)))
				var started_us := Time.get_ticks_usec()
				terrain.collision.update(true)
				samples["collision refresh"].append(float(Time.get_ticks_usec() - started_us) / 1000.0)
				started_us = Time.get_ticks_usec()
				grass.observe_cell(int(cell["form_id"]), coord)
				samples["grass binding"].append(float(Time.get_ticks_usec() - started_us) / 1000.0)
	print("=== %s bare Terrain3D LAND import baseline ===" % label)
	print("real cells imported: %d / %d requested" % [imported, (RADIUS * 2 + 1) * (RADIUS * 2 + 1)])
	for stage in samples:
		_percentile_report("%s (ms)" % stage, samples[stage])

func _ready() -> void:
	var configuration: Dictionary = GameDataConfigScript.resolve()
	var data_dir := String(configuration.get("data_dir", ""))
	if data_dir.is_empty():
		push_error("No game data directory: " + String(configuration.get("error", "")))
		get_tree().quit(1)
		return

	var esm := EsmReader.new()
	if not esm.open(data_dir + GameDataConfigScript.ESM_FILE):
		push_error("Could not open " + data_dir + GameDataConfigScript.ESM_FILE)
		get_tree().quit(1)
		return
	var wrld: Dictionary = esm.find_worldspace_by_editor_id(WORLDSPACE_EDITOR_ID)
	if wrld.is_empty():
		push_error("Missing worldspace " + WORLDSPACE_EDITOR_ID)
		get_tree().quit(1)
		return

	var terrain := Terrain3DBridge.create_terrain(self)
	var camera := Camera3D.new()
	add_child(camera)
	camera.global_position = Terrain3DBridge.cell_terrain3d_global_position(CENTER.x, CENTER.y) + Vector3(25.0, 20.0, 25.0)
	camera.make_current()
	terrain.set_camera(camera)
	var pool := Terrain3DTexturePool.new(terrain)
	var bridge := Terrain3DBridge.new(esm, GamebryoMeshResolver.new(data_dir), pool)
	bridge.collect_import_timings = true
	terrain.collision_mode = Terrain3DCollision.DYNAMIC_GAME
	var grass := TerrainGrassParticles.new(terrain, bridge, esm, bridge.resolver)
	add_child(grass)

	var wrld_id := int(wrld["form_id"])
	_run_pass("cold", esm, wrld_id, terrain, bridge, grass)
	_run_pass("warm", esm, wrld_id, terrain, bridge, grass)
	print("published Terrain3D regions: %d" % terrain.data.region_locations.size())
	print("real render-texture slots used: %d" % pool.used_slot_count())
	get_tree().quit()
