class_name DebugStats
extends RefCounted

## Rendering-issues list #2/#5: exterior FPS pinned flat around ~45,
## independent of view direction, and doesn't recover on an interior
## transition -- can't fix what isn't measured. A pure formatting function
## (no Node dependency, no state of its own) so it's trivially callable from
## game.gd's own periodic refresh without this class needing to know
## anything about *when* or *how often* to run.

static func build_report(cell_loader: CellLoader, world_streamer: WorldStreamer) -> String:
	var lines := PackedStringArray()

	lines.append("FPS: %d  (frame: %.2f ms)" % [
		Engine.get_frames_per_second(),
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
	])
	lines.append("draw calls: %d  primitives: %d  objects: %d" % [
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
	])
	lines.append("physics objects: %d  collision pairs: %d" % [
		Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS),
		Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS),
	])
	lines.append("node count: %d" % Performance.get_monitor(Performance.OBJECT_NODE_COUNT))

	lines.append("")
	lines.append("-- WorldStreamer --")
	if world_streamer != null:
		lines.append("active: %s  resident tiles: %d  pending: %d  in-flight: %d" % [
			world_streamer.is_active(),
			world_streamer._resident.size(),
			world_streamer._pending.size(),
			world_streamer._in_flight_count,
		])
		lines.append("persistent root: %s" % (world_streamer._persistent_root != null))
	else:
		lines.append("(not available)")

	lines.append("")
	lines.append("-- Resource caches (CellLoader / WorldStreamer) --")
	lines.append(_cache_stats_line("CellLoader", cell_loader.resolver if cell_loader != null else null))
	lines.append(_cache_stats_line("WorldStreamer", world_streamer.resolver if world_streamer != null else null))

	return "\n".join(lines)

static func _cache_stats_line(label: String, resolver: GamebryoMeshResolver) -> String:
	if resolver == null:
		return "%s: (not available)" % label
	var s: Dictionary = resolver.get_cache_stats()
	return "%s: mesh %d/%d  tex %d/%d  mat %d/%d  (nifs=%d tex=%d)" % [
		label,
		s.get("mesh_cache_hits", 0), s.get("mesh_cache_hits", 0) + s.get("mesh_cache_misses", 0),
		s.get("texture_cache_hits", 0), s.get("texture_cache_hits", 0) + s.get("texture_cache_misses", 0),
		s.get("material_cache_hits", 0), s.get("material_cache_hits", 0) + s.get("material_cache_misses", 0),
		s.get("unique_nifs_loaded", 0), s.get("unique_textures_loaded", 0),
	]
