extends Label

## Shows a line of Godot's performance monitors: FPS, process time, static
## memory, node count, draw calls, video memory and 3D navigation agents.

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
	return "   ".join(parts)
