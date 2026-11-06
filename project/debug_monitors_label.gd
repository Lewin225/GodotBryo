extends Label

## Shows a line of Godot's performance monitors: FPS, process time, static
## memory, node count, draw calls, video memory and 3D navigation agents; and a
## physics line: the physics frame time, tick rate and step limit, the
## server's active bodies, collision pairs and islands, and the NIF rigid
## bodies awake, asleep, frozen and in total (NifRigidBody.counts()).

## Seconds between refreshes.
const REFRESH_SECONDS := 0.25

var _since_refresh := REFRESH_SECONDS


func _process(delta: float) -> void:
	_since_refresh += delta
	if _since_refresh < REFRESH_SECONDS:
		return
	_since_refresh = 0.0
	text = _monitors_text()


func _monitors_text() -> String:
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var process_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var static_memory := Performance.get_monitor(Performance.MEMORY_STATIC)
	var nodes := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var video_memory := Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)
	var nav_agents := Performance.get_monitor(Performance.NAVIGATION_3D_AGENT_COUNT)
	var parts: Array[String] = [
		"FPS %d" % fps,
		"Process %.2f ms" % process_ms,
		"Mem static %s" % String.humanize_size(int(static_memory)),
		"Nodes %d" % nodes,
		"Draw calls %d" % draw_calls,
		"Video mem %s" % String.humanize_size(int(video_memory)),
		"Nav agents %d" % nav_agents,
	]
	return "   ".join(parts) + "\n" + _physics_text()


func _physics_text() -> String:
	var physics_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var ticks := Engine.physics_ticks_per_second
	var max_steps := Engine.max_physics_steps_per_frame
	var active := Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)
	var pairs := Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)
	var islands := Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT)
	var bodies := NifRigidBody.counts()
	var parts: Array[String] = [
		"Physics %.2f ms" % physics_ms,
		"%d Hz, max %d steps" % [ticks, max_steps],
		"Active %d" % active,
		"Pairs %d" % pairs,
		"Islands %d" % islands,
		"Item bodies %d awake / %d asleep / %d frozen / %d total" % [bodies["awake"], bodies["asleep"], bodies["frozen"], bodies["total"]],
	]
	return "   ".join(parts)
