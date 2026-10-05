class_name NpcDebugLog
extends Node

## Debug: while `interval_seconds` is above 0 (the console's DebugNpcLog),
## prints one line per interval: where the player is, the frame rate over the
## interval, and the actors in the player's space (physicalised, visuals
## built, leased, moving, near the player), the simulation thread's queue and
## the routes that failed during the interval, and NifServer's work over the
## interval (requests, items finished, queues, drain time; it resets
## NifServer's counts each line). A child of NpcSimulationServer; idle while
## off.

## Actors within this many metres of the player count as near.
const NEAR_METRES := 30.0

## Seconds between lines; 0 is off.
var interval_seconds := 0.0:
	set(value):
		interval_seconds = maxf(value, 0.0)
		_restart_interval()
		set_process(interval_seconds > 0.0)

## Wall-clock time, not the frame delta: Godot clamps delta to
## max_physics_steps_per_frame physics ticks when a frame runs long, so a sum
## of deltas undercounts slow frames.
var _interval_start_usec := 0
var _frame_start_usec := 0
var _frames := 0
var _longest_frame_usec := 0
var _last_off_screen_failures := 0
var _last_on_screen_failures := 0

func _ready() -> void:
	set_process(false)

func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	_longest_frame_usec = maxi(_longest_frame_usec, now - _frame_start_usec)
	_frame_start_usec = now
	_frames += 1
	if now - _interval_start_usec < interval_seconds * 1000000.0:
		return
	print("NpcLog: " + _line())
	print("NpcLog: NifServer " + _nif_line())
	_restart_interval()

func _restart_interval() -> void:
	NifServer.reset_stats()
	_interval_start_usec = Time.get_ticks_usec()
	_frame_start_usec = _interval_start_usec
	_frames = 0
	_longest_frame_usec = 0

func _line() -> String:
	var server = get_parent()
	var player := ScriptServer.player_reference
	if player == null:
		return "no player"
	var space := player.current_space_form_id
	var counts := {"in space": 0, "with node": 0, "visual built": 0, "leased": 0, "low level": 0, "moving": 0, "near": 0}
	for actor: ActorReference in server.get_actors_in_space(space):
		counts["in space"] += 1
		if actor.simulation_mode == ActorReference.SimulationMode.PHYSICAL_LEASED:
			counts["leased"] += 1
		else:
			counts["low level"] += 1
		if actor.has_move_target:
			counts["moving"] += 1
		if actor.position.distance_to(player.position) <= NEAR_METRES:
			counts["near"] += 1
		var controller := EsmNode.node_for(actor) as NpcController
		if controller == null:
			continue
		counts["with node"] += 1
		if controller.actor != null and controller.actor.is_visual_built():
			counts["visual built"] += 1
	var off_screen_failures: int = server.low_level_travel.routes_not_found
	var on_screen_failures := NpcController.routes_not_found
	var line := "at %s in %s (%s); %.1f fps over %.0f s (longest frame %.0f ms), process %.1f ms, physics %.1f ms, %d nodes; actors in space %d: with node %d (visual built %d), leased %d, low level %d, moving %d, within %.0f m %d; queue %d; routes not found this interval: off screen %d, on screen %d" % [
		_format_position(player.position), _space_name(space), _cell_name(player),
		_frames / maxf(_elapsed_seconds(), 0.001), _elapsed_seconds(), _longest_frame_usec / 1000.0,
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		counts["in space"], counts["with node"], counts["visual built"], counts["leased"], counts["low level"], counts["moving"], NEAR_METRES, counts["near"],
		server.worker.get_pending_count(), off_screen_failures - _last_off_screen_failures, on_screen_failures - _last_on_screen_failures]
	_last_off_screen_failures = off_screen_failures
	_last_on_screen_failures = on_screen_failures
	return line

## NifServer since the last line: requests, items finished (built new, copied
## from the tree cache, dropped because the requester was gone), what is still
## queued, and its drain's average and longest frame.
func _nif_line() -> String:
	var stats: Dictionary = NifServer.get_stats()
	var finished := int(stats["build_count"]) + int(stats["tree_cache_hits"]) + int(stats["owner_gone_count"])
	var line := "requests %d; finished %d (built %d, cache copies %d, owner gone %d); queued %d to start, %d ready to build, %d loading; drain %.1f ms a frame on average, longest %.1f ms; per finished item %.2f ms copying, %.2f ms in delivery callbacks; slowest copy %.1f ms, %s (%d nodes)" % [
		stats["request_count"], finished, stats["build_count"], stats["tree_cache_hits"], stats["owner_gone_count"],
		stats["pending_build_count"], stats["ready_build_count"], int(stats["pending_admission_count"]) + int(stats["active_resolve_count"]),
		int(stats["drain_usec_total"]) / 1000.0 / maxi(_frames, 1), int(stats["drain_usec_max"]) / 1000.0,
		int(stats["duplicate_usec_total"]) / 1000.0 / maxi(finished, 1), int(stats["delivery_usec_total"]) / 1000.0 / maxi(finished, 1),
		int(stats["duplicate_usec_max"]) / 1000.0, stats["duplicate_max_key"], _template_nodes(String(stats["duplicate_max_key"]))]
	NifServer.reset_stats()
	return line

## Node count of a cached template, by NIF key (either tree variant).
func _template_nodes(key: String) -> int:
	for tree_key: String in NifServer._tree_nodes:
		if tree_key.begins_with(key):
			return NifServer._tree_nodes[tree_key]
	return 0

func _elapsed_seconds() -> float:
	return (Time.get_ticks_usec() - _interval_start_usec) / 1000000.0

func _format_position(position: Vector3) -> String:
	return "(%.0f, %.0f, %.0f)" % [position.x, position.y, position.z]

func _space_name(space_form_id: int) -> String:
	var base := EsmServer.get_base(space_form_id)
	if base != null and not base.editor_id.is_empty():
		return base.editor_id
	return "%08X" % space_form_id

## The player's cell: its editor ID, and for an exterior its grid coordinate.
func _cell_name(player: ActorReference) -> String:
	var cell := player.current_cell_form_id
	var name := String(EsmServer.reader.get_cell_editor_id(cell)) if cell != 0 else ""
	if name.is_empty():
		name = "%08X" % cell
	if cell != player.current_space_form_id:
		var grid := EsmServer.exterior_grid_coord(player.position)
		name += " grid %d,%d" % [grid.x, grid.y]
	return name

## Debug (DebugActorCost): for every physicalised actor, turns one part off at
## a time, lets SETTLE_FRAMES pass, takes the median process, physics and
## wall-clock frame time over MEASURE_FRAMES, turns it back on, and prints each part's
## figures beside a baseline measured first and last. `reverse` runs the
## parts in the opposite order; `only`, when not empty, names the parts to run.
func measure_actor_costs(reverse := false, only: Array = []) -> void:
	# Animation players go last: switching 150 back on raised process time to
	# about 35 ms for a stretch some 180 frames later (headless), which would
	# land on whichever part came next.
	var parts := [
		["animator clip choice", _set_animator_clip_choice],
		["look-at modifiers", _set_look_at_modifiers],
		["skeleton updates", _set_skeleton_updates],
		["actor visuals (hidden)", _set_actor_visuals],
		["controllers", _set_controllers],
		["avoidance", _set_avoidance],
		["animation players", _set_animation_players],
	]
	if reverse:
		parts.reverse()
	if not only.is_empty():
		parts = parts.filter(func(part: Array) -> bool: return only.has(part[0]))
	var controllers := get_tree().root.find_children("*", "NpcController", true, false)
	print("DebugActorCost: %d physicalised actors; median process / physics / frame ms over %d frames" % [controllers.size(), MEASURE_FRAMES])
	print("DebugActorCost:   baseline: %s" % await _measure_costs())
	for part in parts:
		var toggle: Callable = part[1]
		toggle.call(controllers, false)
		var figures := await _measure_costs()
		toggle.call(controllers, true)
		print("DebugActorCost:   without %s: %s" % [part[0], figures])
	print("DebugActorCost:   baseline again: %s" % await _measure_costs())

const SETTLE_FRAMES := 30
const MEASURE_FRAMES := 60

## Median process, physics and wall-clock frame time over MEASURE_FRAMES, after
## SETTLE_FRAMES: a median, so one slow stretch from something else does not
## skew the figure.
func _measure_costs() -> String:
	for frame in SETTLE_FRAMES:
		await get_tree().process_frame
	var process: Array[float] = []
	var physics: Array[float] = []
	var frames: Array[float] = []
	var last := Time.get_ticks_usec()
	for frame in MEASURE_FRAMES:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		frames.append((now - last) / 1000.0)
		last = now
		process.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		physics.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	return "%.1f / %.1f / %.1f" % [_median(process), _median(physics), _median(frames)]

static func _median(values: Array[float]) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]

func _actor_nodes(controllers: Array, type: String) -> Array:
	var found := []
	for controller in controllers:
		var actor: EsmActorNode = controller.actor
		if actor != null:
			found.append_array(actor.find_children("*", type, true, false))
	return found

func _set_animation_players(controllers: Array, on: bool) -> void:
	for player: AnimationPlayer in _actor_nodes(controllers, "AnimationPlayer"):
		player.active = on

func _set_animator_clip_choice(controllers: Array, on: bool) -> void:
	for controller in controllers:
		if controller.actor != null:
			controller.actor.animator.set_physics_process(on)

func _set_look_at_modifiers(controllers: Array, on: bool) -> void:
	for modifier: LookAtModifier3D in _actor_nodes(controllers, "LookAtModifier3D"):
		modifier.active = on

func _set_skeleton_updates(controllers: Array, on: bool) -> void:
	for skeleton: Skeleton3D in _actor_nodes(controllers, "Skeleton3D"):
		skeleton.process_mode = Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_DISABLED

func _set_actor_visuals(controllers: Array, on: bool) -> void:
	for controller in controllers:
		if controller.actor != null:
			controller.actor.visible = on

func _set_controllers(_controllers: Array, on: bool) -> void:
	NpcController.debug_enabled = on
	if not on:
		return
	for controller: NpcController in _controllers:
		controller._update_avoidance()

func _set_avoidance(controllers: Array, on: bool) -> void:
	for controller: NpcController in controllers:
		if on:
			controller._update_avoidance()
		else:
			controller.agent.avoidance_enabled = false
