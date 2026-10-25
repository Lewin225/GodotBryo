extends Node3D

var DATA_DIR: String = GameDataConfig.resolve()["data_dir"] ## the launcher's data folder, or GODOTBRYO_DATA_DIR
const WASTELAND_USABLE_CELLS := 16388
const WASTELAND_TOUCHED_REGIONS := 292
const WASTELAND_DOMAIN_SIZE := Vector2i(18, 18)
var failures := 0

func check(condition: bool, message: String) -> void:
	if condition:
		print("  OK   ", message)
	else:
		print("  FAIL ", message)
		failures += 1

func _ready() -> void:
	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened real master")
	var world: Dictionary = esm.find_worldspace_by_editor_id("WastelandNV")
	var camera := Camera3D.new()
	add_child(camera)
	camera.global_position = Terrain3DBridge.cell_terrain3d_global_position(-17, 0) + Vector3(8, 40, 8)
	camera.make_current()
	var streamer := TerrainStreamer.new()
	streamer.configure(esm)
	add_child(streamer)
	streamer.activate(int(world.form_id))

	var deadline := Time.get_ticks_msec() + 180000
	while Time.get_ticks_msec() < deadline:
		var progress := streamer.get_diagnostics()
		if bool(progress.catalogue_ready) and int(progress.total_regions) > 0 \
				and int(progress.committed_regions) == int(progress.total_regions) \
				and int(progress.queued_regions) == 0 \
				and int(progress.preparing_regions) == 0 \
				and int(progress.prepared_regions) == 0:
			break
		await get_tree().process_frame

	var diagnostics := streamer.get_diagnostics()
	check(streamer._usable_cells.size() == WASTELAND_USABLE_CELLS, "WastelandNV catalogue has 16,388 usable LAND cells")
	check(int(diagnostics.total_regions) == WASTELAND_TOUCHED_REGIONS, "finite queue contains 292 touched regions")
	check(streamer._catalogue.get("region_bounds", {}).get("size", Vector2i.ZERO) == WASTELAND_DOMAIN_SIZE,
			"fixed allocation domain is the census-derived 18x18 rectangle")
	check(int(diagnostics.worker_count) == clampi(OS.get_processor_count() - 1, 1, 8),
			"runtime worker pool follows clamp(processor_count - 1, 1, 8)")
	check(int(diagnostics.committed_regions) == WASTELAND_TOUCHED_REGIONS, "stationary fill commits every real region")
	check(int(diagnostics.queued_regions) == 0 and int(diagnostics.preparing_regions) == 0 and int(diagnostics.prepared_regions) == 0,
			"terminal diagnostics contain no queued, preparing, or prepared work")

	var terrain_samples_before := (diagnostics.terrain_ms as Array).size()
	var staging_samples_before := (diagnostics.staging_ms as Array).size()
	var publication_samples_before := (diagnostics.publication_ms as Array).size()
	camera.global_position = Terrain3DBridge.cell_terrain3d_global_position(40, 40) + Vector3(8, 40, 8)
	for unused in range(20):
		await get_tree().process_frame
	diagnostics = streamer.get_diagnostics()
	check((diagnostics.terrain_ms as Array).size() == terrain_samples_before \
			and (diagnostics.staging_ms as Array).size() == staging_samples_before \
			and (diagnostics.publication_ms as Array).size() == publication_samples_before,
			"movement after completion causes no terrain staging or publication")

	streamer.deactivate()
	print("=======================")
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(1 if failures else 0)
