extends Node

## One-off capture harness: boots nav_simulation_viewer.tscn for real (windowed,
## with a live renderer -- headless has no rasterizer and captures nothing),
## screenshots each requested view, and quits. Exists to confirm the viewer
## actually draws, which no headless assertion can establish.
##
## Deliberately forces the mouse back to visible every frame: the viewer's
## free_cam captures it in _ready(), which would otherwise grab the pointer of
## whoever is at the machine.

const OUT_DIR := "user://nav_viewer_capture"

func _ready() -> void:
	DisplayServer.window_set_size(Vector2i(1600, 900))
	var viewer: Node = load("res://nav_simulation_viewer.tscn").instantiate()
	add_child(viewer)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	await viewer.simulation.seed_finished
	# Let the built meshes actually reach the GPU before reading pixels back.
	for i in 30:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		await get_tree().process_frame

	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	await _capture(viewer, "01_mojave_framed")

	# Pull the camera down close to the mesh so triangle detail is legible
	# rather than a distant sheet.
	var bounds: Dictionary = viewer.simulation.navmesh.get_space_bounds(viewer.current_space)
	if bool(bounds.get("found", false)):
		var bounds_min: Vector3 = bounds["min"]
		var bounds_max: Vector3 = bounds["max"]
		var centre: Vector3 = viewer._to_godot((bounds_min + bounds_max) * 0.5)
		viewer.camera.global_position = centre + Vector3(0.0, 120.0, 120.0)
		viewer.camera.look_at(centre, Vector3.UP)
		await _capture(viewer, "02_mojave_close")

	# Coarse NVEX graph on its own, with the navmesh hidden -- the view that
	# shows connectivity rather than surface.
	viewer.navmesh_surface.visible = false
	viewer.coarse_graph_lines.visible = true
	await _capture(viewer, "03_coarse_graph_only")
	viewer.navmesh_surface.visible = true

	# A real route, drawn.
	viewer._route_between_random_actors()
	await viewer.simulation.route_ready
	for i in 10:
		await get_tree().process_frame
	await _capture(viewer, "04_route")

	# An interior space, which is where grounding corrections are most visible.
	var interior_index := -1
	for i in viewer.space_ids.size():
		var records: PackedInt32Array = viewer.simulation.navmesh.get_records_in_space(viewer.space_ids[i])
		if records.size() >= 1 and records.size() <= 4:
			var info: Dictionary = viewer.simulation.navmesh.get_record_info(records[0])
			if not bool(info.get("is_exterior", true)) and int(info.get("triangle_count", 0)) > 400:
				interior_index = i
				break
	if interior_index >= 0:
		viewer._show_space(interior_index)
		for i in 15:
			await get_tree().process_frame
		await _capture(viewer, "05_interior")

	# An interior with real XTEL doors, to check the portal boxes land on them.
	var portal_index := -1
	for i in viewer.space_ids.size():
		var records: PackedInt32Array = viewer.simulation.navmesh.get_records_in_space(viewer.space_ids[i])
		if records.size() < 1 or records.size() > 3:
			continue
		var info: Dictionary = viewer.simulation.navmesh.get_record_info(records[0])
		if bool(info.get("is_exterior", true)) or int(info.get("triangle_count", 0)) < 250:
			continue
		var doors := 0
		for portal in viewer.simulation.portals:
			if portal.source_space_form_id == viewer.space_ids[i] or portal.destination_space_form_id == viewer.space_ids[i]:
				doors += 1
		if doors >= 3:
			portal_index = i
			break
	if portal_index >= 0:
		viewer._show_space(portal_index)
		for i in 15:
			await get_tree().process_frame
		await _capture(viewer, "06_portals")

	# --- cross-space walk: the NPC pathing through a real door ---
	# Fast enough that a kilometre-scale leg completes inside the capture.
	viewer.walk_speed = 400.0
	viewer.camera_follows_walker = true
	# Start from an interior so both legs are short and the door transition is
	# quick to reach.
	if portal_index >= 0:
		viewer._show_space(portal_index)
	for i in 10:
		await get_tree().process_frame

	viewer._walk_random_cross_space_route()
	await viewer.simulation.cross_space_route_ready
	for i in 10:
		await get_tree().process_frame

	if viewer.walker.is_empty():
		print("  walk did not start: ", viewer.cross_route.get("note", viewer.cross_route))
	else:
		var legs: Array = viewer.walker["legs"]
		print("  walking %d legs, %d doors, %.0f m" % [
			legs.size(), int(viewer.cross_route.get("door_count", 0)),
			float(viewer.cross_route.get("total_length", 0.0))])
		await _capture(viewer, "07_walk_start")
		var last_leg := int(viewer.walker.get("leg_index", 0))
		var shots := 0
		for frame in 2000:
			await get_tree().process_frame
			if viewer.walker.is_empty():
				break
			var leg_now := int(viewer.walker.get("leg_index", 0))
			if leg_now != last_leg:
				last_leg = leg_now
				shots += 1
				# Right after stepping through a door, in the new space.
				await _capture(viewer, "08_walk_through_door_%d" % shots)
			if bool(viewer.walker.get("finished", false)):
				break
		await _capture(viewer, "09_walk_arrived")
		print("  walker finished=%s final leg=%d space=0x%08X" % [
			viewer.walker.get("finished", false), int(viewer.walker.get("leg_index", 0)),
			int(viewer.walker.get("space", 0))])

	# --- 100-route batch: measure the only thing that matters, main-thread hitch ---
	# Back to the largest space -- the walk left us in a tiny interior.
	var biggest := 0
	var biggest_count := -1
	for i in viewer.space_ids.size():
		var n: int = viewer.simulation.navmesh.get_records_in_space(viewer.space_ids[i]).size()
		if n > biggest_count:
			biggest_count = n
			biggest = i
	viewer._show_space(biggest)
	viewer.camera_follows_walker = false
	viewer.walker = {}
	for i in 30:
		await get_tree().process_frame
	var idle_worst := 0.0
	for i in 60:
		await get_tree().process_frame
		idle_worst = maxf(idle_worst, viewer._recent_frame_ms)
	print("  idle worst frame over 60 frames: %.2f ms" % idle_worst)

	viewer._stress_test_routes()
	var frames := 0
	while frames < 2000:
		await get_tree().process_frame
		frames += 1
		if not viewer.batch.is_empty() and not bool(viewer.batch.get("running", true)):
			break
	if viewer.batch.has("note"):
		print("  batch: ", viewer.batch["note"])
	else:
		print("  batch: %d issued, %d done, %d found in %d ms over %d frames" % [
			int(viewer.batch["issued"]), int(viewer.batch["done"]), int(viewer.batch["found"]),
			int(viewer.batch["finished_ms"]) - int(viewer.batch["started_ms"]), frames])
		print("  WORST MAIN-THREAD FRAME DURING BATCH: %.2f ms   (idle baseline %.2f ms)" % [
			float(viewer.batch["worst_frame_ms"]), idle_worst])
	await _capture(viewer, "10_batch_100_routes")

	# Confirm the crowd actually MOVES, rather than trusting the wiring.
	var walkers: Array = viewer.batch.get("walkers", [])
	print("  batch walkers: %d" % walkers.size())
	if not walkers.is_empty():
		var before: Array[Vector3] = []
		for w in walkers:
			before.append(w["position"])
		for i in 90:
			await get_tree().process_frame
		var moved := 0
		var total_distance := 0.0
		for i in walkers.size():
			var d: float = (walkers[i]["position"] as Vector3).distance_to(before[i])
			total_distance += d
			if d > 0.5:
				moved += 1
		print("  after 90 frames: %d of %d walkers moved, mean distance %.1f m" % [
			moved, walkers.size(), total_distance / walkers.size()])
		await _capture(viewer, "11_batch_walking")

	print("capture dir: ", ProjectSettings.globalize_path(OUT_DIR))
	get_tree().quit(0)

func _capture(viewer: Node, name: String) -> void:
	for i in 3:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, name]
	var error := image.save_png(path)
	print("  %s -> %s (%dx%d, err=%d) | %s" % [
		name, ProjectSettings.globalize_path(path), image.get_width(), image.get_height(), error,
		viewer.status_label.text.split("\n")[2] if viewer.status_label.text.split("\n").size() > 2 else "",
	])
