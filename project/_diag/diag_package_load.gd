extends Node

## Frame cost of every placed actor running DefaultFollowPlayerClose with the
## player in GSDocMitchellHouse: per-frame time of PackageRunner and
## LowLevelTravel's physics processing, and the frame time, over the first
## FRAMES physics frames.

const FRAMES := 300

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	NpcSimulationServer.records_per_frame = 512
	NpcSimulationServer.seed()
	if not NpcSimulationServer.is_seeded:
		await NpcSimulationServer.seed_finished
	var player := EsmServer.get_player_reference()
	ScriptServer.player_reference = player
	var house := EsmServer.find_form_id_by_editor_id("GSDocMitchellHouse")
	var doc := EsmServer.find_reference_by_editor_id("DocMitchellREF")
	ScriptServer.move_reference(player, house, doc.position + Vector3(2.0, 0.0, 0.0), Vector3.ZERO)
	ScriptServer.apply_pending_moves()
	var package := EsmServer.find_base_by_editor_id("DefaultFollowPlayerClose") as PackageBase
	var started := Time.get_ticks_usec()
	var count := NpcSimulationServer.package_runner.set_package_for_all(package)
	print("set_package_for_all: %d actors in %.1f ms" % [count, (Time.get_ticks_usec() - started) / 1000.0])
	var worst := 0.0
	var total := 0.0
	var last := Time.get_ticks_usec()
	for frame in FRAMES:
		await get_tree().physics_frame
		var now := Time.get_ticks_usec()
		var ms := (now - last) / 1000.0
		last = now
		total += ms
		worst = maxf(worst, ms)
		if frame < 5 or frame % 60 == 0:
			print("frame %d: %.1f ms; physics %.1f ms" % [frame, ms, Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0])
	print("%d frames: mean %.1f ms, worst %.1f ms" % [FRAMES, total / FRAMES, worst])
	await _time_route(house, doc.position, doc.position + Vector3(3.0, 0.0, 0.0))

## Frames until a single request_route answers, as a controller's would.
func _time_route(space: int, from: Vector3, to: Vector3) -> void:
	var answered := [false]
	var request_id: int = NpcSimulationServer.request_route(space, from, to, true)
	var on_ready := func(id: int, _result: Dictionary) -> void:
		if id == request_id:
			answered[0] = true
	NpcSimulationServer.route_ready.connect(on_ready)
	var frames := 0
	var started := Time.get_ticks_msec()
	while not answered[0] and frames < 6000:
		await get_tree().physics_frame
		frames += 1
	NpcSimulationServer.route_ready.disconnect(on_ready)
	print("a controller's route request with every actor planning: answered %s after %d frames (%.1f s); %d jobs queued on the simulation thread" % [answered[0], frames, (Time.get_ticks_msec() - started) / 1000.0, NpcSimulationServer.worker.get_pending_count()])
	NpcSimulationServer.package_runner.set_package_for_all(null)
	get_tree().quit()
