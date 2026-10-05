extends Node3D

## Physicalises COUNT copies of Doc around the origin, waits for their visuals,
## then measures average process time with actors on the main thread and in
## sub-thread groups (DebugActorThreads), and prints any errors' absence.

const COUNT := 150
const FRAMES := 300

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	NpcSimulationServer.records_per_frame = 512
	NpcSimulationServer.seed()
	if not NpcSimulationServer.is_seeded:
		await NpcSimulationServer.seed_finished
	var wasteland := EsmServer.find_form_id_by_editor_id("WastelandNV")
	var actors := []
	for actor: ActorReference in NpcSimulationServer.get_actors_in_space(wasteland):
		if actor.is_disabled():
			continue
		actors.append(actor)
		if actors.size() >= COUNT:
			break
	var physicaliser := EsmReferencePhysicaliser.new()
	for actor: ActorReference in actors:
		physicaliser.physicalise(actor, self)
	var built := 0
	var settled_frames := 0
	for frame in 6000:
		await get_tree().process_frame
		var now := _built()
		settled_frames = settled_frames + 1 if now == built else 0
		built = now
		if settled_frames >= 600:
			break
	print("actors %d, visuals built %d" % [actors.size(), built])
	if OS.get_cmdline_user_args().has("cost"):
		var only := []
		if OS.get_cmdline_user_args().has("lookat"):
			only.append("look-at modifiers")
		if OS.get_cmdline_user_args().has("players"):
			only.append("animation players")
		await NpcSimulationServer.debug_log.measure_actor_costs(OS.get_cmdline_user_args().has("reverse"), only)
		get_tree().quit()
		return
	if OS.get_cmdline_user_args().has("nif"):
		print("NifServer stats: %s" % NifServer.get_stats())
		NifServer.construction_profiling_enabled = true
		for frame in 120:
			await get_tree().process_frame
		NifServer.construction_profiling_enabled = false
		print("NifServer stats after: %s" % NifServer.get_stats())
		get_tree().quit()
		return
	for round in 3:
		ScriptServer.run_debug_line("DebugActorThreads 0")
		for frame in 5:
			await get_tree().process_frame
		var main := await _measure()
		ScriptServer.run_debug_line("DebugActorThreads 1")
		for frame in 5:
			await get_tree().process_frame
		var threaded := await _measure()
		print("round %d: main thread %.2f ms, sub-thread groups %.2f ms (visuals built %d)" % [round, main, threaded, _built()])
	get_tree().quit()

func _built() -> int:
	var count := 0
	for actor in find_children("*", "EsmActorNode", true, false):
		if actor.is_visual_built():
			count += 1
	return count

func _measure() -> float:
	var total := 0.0
	for frame in FRAMES:
		await get_tree().process_frame
		total += Performance.get_monitor(Performance.TIME_PROCESS) + Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
	return total / FRAMES * 1000.0
