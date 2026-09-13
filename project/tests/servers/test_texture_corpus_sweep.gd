extends Control

## Walks every .dds in the shipped archives through TextureServer, displays each
## one, and reports throughput. Runs windowed (watch it) or headless (timing
## only) -- the pipeline is identical either way.
##
##   ../tools/Godot_v4.7.1-stable_linux.x86_64 --path . tests/servers/test_texture_corpus_sweep.tscn
##   ../tools/Godot_v4.7.1-stable_linux.x86_64 --headless --path . tests/servers/test_texture_corpus_sweep.tscn
##
## Not a pass/fail gate: it prints a report and exits 0 unless the sweep could
## not run at all. The corpus is 26,907 textures / 3.0 GB compressed, so it
## purges behind itself -- TextureServer's V1 policy is resident-forever, which
## holds for gameplay but not for a full walk.

## 0 = every texture in the corpus.
@export var max_textures: int = 0
## How many textures stay resident behind the cursor before being purged.
@export var resident_window: int = 96
## How far ahead to warm(), so the pipeline stays saturated.
@export var lookahead: int = 48
## Raised for the sweep so the measurement is of decode+upload, not of an
## artificially small budget.
@export var sweep_upload_budget: int = 64
## Disable purging to measure the true resident footprint of a subset.
@export var disable_purge: bool = false

var _paths: PackedStringArray = []
var _latencies: PackedFloat32Array = []
var _ok := 0
var _failed := 0
var _peak_resident := 0
var _peak_tex_mem := 0
var _peak_static_mem := 0
var _warm_hits := 0   ## already resident when requested (lookahead paid off)
var _cold_waits := 0  ## request() actually had to wait for the pipeline
var _rect: TextureRect
var _label: Label


func _apply_cmdline() -> void:
	# Lets the sweep be run in variants without editing the scene:
	#   -- --max=6000 --no-purge
	for arg in OS.get_cmdline_user_args():
		var a := String(arg)
		if a.begins_with("--max="):
			max_textures = int(a.substr(6))
		elif a == "--no-purge":
			disable_purge = true
		elif a.begins_with("--window="):
			resident_window = int(a.substr(9))


func _ready() -> void:
	_apply_cmdline()
	_rect = $Texture
	_label = $Info
	if not ArchiveServer.is_ready():
		push_error("ArchiveServer not ready: " + ArchiveServer.get_init_error())
		get_tree().quit(1)
		return
	_run()


func _collect() -> void:
	var t0 := Time.get_ticks_msec()
	for p in ArchiveServer.list_files_with_prefix("textures/"):
		if String(p).ends_with(".dds"):
			_paths.append(String(p))
	print("enumerated %d .dds paths in %d ms" % [_paths.size(), Time.get_ticks_msec() - t0])
	if max_textures > 0 and _paths.size() > max_textures:
		_paths.resize(max_textures)
		print("limited to %d by max_textures" % max_textures)


func _run() -> void:
	_collect()
	if _paths.is_empty():
		push_error("no textures found")
		get_tree().quit(1)
		return

	var prev_budget: int = TextureServer.uploads_per_frame_budget
	TextureServer.uploads_per_frame_budget = sweep_upload_budget
	TextureServer.reset_stats()

	var sweep_start := Time.get_ticks_usec()
	var last_report := Time.get_ticks_msec()

	for i in _paths.size():
		# Keep the queue fed so the measurement reflects the pipeline, not
		# a stop-start round trip per texture.
		var ahead := i + lookahead
		while ahead < _paths.size() and ahead <= i + lookahead:
			TextureServer.warm(_paths[ahead], false)
			ahead += 1

		var was_resident := TextureServer.is_finished(_paths[i], false)
		var t0 := Time.get_ticks_usec()
		var tex: ImageTexture = await TextureServer.request(_paths[i], false)
		var dt := float(Time.get_ticks_usec() - t0) / 1000.0
		if was_resident:
			_warm_hits += 1
		else:
			_cold_waits += 1
			_latencies.append(dt)

		if tex != null:
			_ok += 1
			_rect.texture = tex
		else:
			_failed += 1

		var resident := int(TextureServer.get_stats()["resident_texture_count"])
		_peak_resident = maxi(_peak_resident, resident)
		_peak_tex_mem = maxi(_peak_tex_mem, int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED)))
		_peak_static_mem = maxi(_peak_static_mem, int(OS.get_static_memory_usage()))
		if not disable_purge and i >= resident_window:
			TextureServer.purge(_paths[i - resident_window], false)

		if Time.get_ticks_msec() - last_report > 500:
			last_report = Time.get_ticks_msec()
			var elapsed := float(Time.get_ticks_usec() - sweep_start) / 1_000_000.0
			var line := "%d / %d   %.1f tex/s   ok=%d failed=%d resident=%d" % [
				i + 1, _paths.size(), (i + 1) / maxf(elapsed, 0.001), _ok, _failed, resident]
			if _label != null:
				_label.text = "%s\n%s" % [_paths[i], line]
			print("  ", line)

	var total_s := float(Time.get_ticks_usec() - sweep_start) / 1_000_000.0
	TextureServer.uploads_per_frame_budget = prev_budget
	_report(total_s)


func _percentile(sorted: PackedFloat32Array, q: float) -> float:
	if sorted.is_empty():
		return 0.0
	var idx: int = clampi(int(sorted.size() * q), 0, sorted.size() - 1)
	return sorted[idx]


func _report(total_s: float) -> void:
	var sorted := _latencies.duplicate()
	sorted.sort()
	var stats: Dictionary = TextureServer.get_stats()
	print("\n=== texture corpus sweep ===")
	print("  mode                   %s, window %d, budget %d" % [
		"NO PURGE" if disable_purge else "purging", resident_window, sweep_upload_budget])
	print("  textures processed     %d" % _paths.size())
	print("  decoded ok             %d" % _ok)
	print("  failed                 %d" % _failed)
	print("  total time             %.2f s" % total_s)
	print("  throughput             %.1f textures/sec" % (_paths.size() / maxf(total_s, 0.001)))
	print("  lookahead hits         %d (%.1f%%) -- already resident when requested" % [
		_warm_hits, 100.0 * _warm_hits / maxi(1, _paths.size())])
	print("  cold waits             %d -- request() had to wait for the pipeline" % _cold_waits)
	if sorted.is_empty():
		print("  cold-wait latency      n/a (every request was a lookahead hit)")
	else:
		print("  cold-wait latency      min %.2f ms   p50 %.2f ms   p95 %.2f ms   max %.2f ms" % [
			sorted[0], _percentile(sorted, 0.5), _percentile(sorted, 0.95), sorted[sorted.size() - 1]])
	print("  peak resident textures %d (window %d)" % [_peak_resident, resident_window])
	print("  purges                 %d" % int(stats["purge_count"]))
	print("  peak texture memory    %.1f MB (RenderingServer)" % (_peak_tex_mem / 1048576.0))
	print("  peak static memory     %.1f MB (OS.get_static_memory_usage)" % (_peak_static_mem / 1048576.0))
	if _peak_resident > 0:
		print("  per resident texture   %.0f KB texture mem, %.0f KB static"
			% [_peak_tex_mem / _peak_resident / 1024.0, _peak_static_mem / _peak_resident / 1024.0])
	print("  decode failures        %d" % int(stats["decode_failure_count"]))
	print("  uploads                %d" % int(stats["total_upload_count"]))
	print("===========================")
	get_tree().quit(0)
