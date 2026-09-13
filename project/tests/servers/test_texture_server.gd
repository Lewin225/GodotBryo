extends Node

## Stage C gate (Plans/server_stack_build_order.md): TextureServer is the one
## DDS decode/upload/cache primitive, with the DXT1 alpha-variant behaviour
##
## Calls `_decode()` directly in places. That is private -- the public surface is
## warm() and request() -- and reaching into it here is deliberate: these
## checks are about the decoder itself, including a parity check against the
## legacy resolver, which the public entry points would hide behind the cache.
## carried over intact from mesh_resolver.

const DATA_DIR := "../fresh_nv_copy/Data/" ## relative to the project dir (the process CWD)

var failures := 0
var _dxt1 := ""
var _dxt5 := ""
var _many: PackedStringArray = []
var _worker_saw_job := false
var _worker_done := false


func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1


func _digest(b: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(b)
	return ctx.finish().hex_encode()


func _collect_textures() -> void:
	var listed := ArchiveServer.list_files_with_prefix("textures/architecture/")
	for p in listed:
		var path := String(p)
		if not path.ends_with(".dds"):
			continue
		if _many.size() < 40:
			_many.append(path)
		if _dxt1.is_empty() or _dxt5.is_empty():
			var probe := TextureServer._decode(path, false)
			if probe == null:
				continue
			if probe.get_format() == Image.FORMAT_DXT1 and _dxt1.is_empty():
				_dxt1 = path
			elif probe.get_format() == Image.FORMAT_DXT5 and _dxt5.is_empty():
				_dxt5 = path
		if _many.size() >= 40 and not _dxt1.is_empty() and not _dxt5.is_empty():
			break
	check(not _dxt1.is_empty(), "found a DXT1 texture (%s)" % _dxt1)
	check(not _dxt5.is_empty(), "found a DXT5 texture (%s)" % _dxt5)
	check(_many.size() >= 20, "collected %d textures for the backlog test" % _many.size())


func test_dxt1_alpha_variant() -> void:
	print("--- DXT1 alpha-variant regression guard ---")
	var plain := TextureServer._decode(_dxt1, false)
	var alpha := TextureServer._decode(_dxt1, true)
	check(plain != null and alpha != null, "both variants decoded")
	check(plain.get_format() == Image.FORMAT_DXT1, "alpha_safe=false stays compressed (fmt %d)" % plain.get_format())
	check(alpha.get_format() != Image.FORMAT_DXT1, "alpha_safe=true is decompressed (fmt %d)" % alpha.get_format())
	check(alpha.has_mipmaps() == plain.has_mipmaps(), "mipmap chain survives the decompress (%s)" % alpha.has_mipmaps())
	check(alpha.get_data().size() > plain.get_data().size(),
		"decompressed variant is larger (%d vs %d bytes)" % [alpha.get_data().size(), plain.get_data().size()])

	var k_plain := TextureServer.cache_key(_dxt1, false)
	var k_alpha := TextureServer.cache_key(_dxt1, true)
	check(k_plain != k_alpha, "variant cache keys differ ('%s' vs '%s')" % [k_plain, k_alpha])
	check(k_alpha.ends_with("#rgba"), "alpha-safe key carries the '#rgba' suffix")

	# DXT5 alpha reaches the GPU intact and must NOT be decompressed.
	var d5_plain := TextureServer._decode(_dxt5, false)
	var d5_alpha := TextureServer._decode(_dxt5, true)
	check(d5_plain.get_format() == d5_alpha.get_format(),
		"DXT5 is untouched by alpha_safe (fmt %d both)" % d5_plain.get_format())


func test_parity_with_resolver() -> void:
	print("--- decode parity with the existing resolver ---")
	# Test-only, explicitly allowlisted: compare against the real decode path.
	var old := GamebryoMeshResolver.new(DATA_DIR)
	var cases := [[_dxt1, false], [_dxt1, true], [_dxt5, false], [_dxt5, true]]
	for c in cases:
		var path: String = c[0]
		var alpha: bool = c[1]
		var mine := TextureServer._decode(path, alpha)
		var theirs: Image = old._load_image(path, alpha)
		check(mine != null and theirs != null, "both decoded %s (alpha_safe=%s)" % [path.get_file(), alpha])
		if mine == null or theirs == null:
			continue
		check(mine.get_format() == theirs.get_format(),
			"format matches for %s (alpha_safe=%s): %d" % [path.get_file(), alpha, mine.get_format()])
		check(_digest(mine.get_data()) == _digest(theirs.get_data()),
			"pixel data byte-identical for %s (alpha_safe=%s)" % [path.get_file(), alpha])


func _warm_from_worker(path: String) -> void:
	TextureServer.warm(path, false)
	# The enqueue is marshalled through call_deferred, so the job must NOT be
	# visible on this thread immediately after the call returns.
	var stats: Dictionary = TextureServer.get_stats()
	_worker_saw_job = int(stats["pending_queue_count"]) > 0
	_worker_done = true


func _ready() -> void:
	print("--- setup ---")
	check(ArchiveServer.is_ready(), "ArchiveServer available")
	_collect_textures()
	if _dxt1.is_empty() or _dxt5.is_empty():
		print("FAILURES: ", failures)
		get_tree().quit(1)
		return

	test_dxt1_alpha_variant()
	test_parity_with_resolver()

	print("--- request / cache behaviour ---")
	TextureServer.reset_stats()
	var t1: ImageTexture = await TextureServer.request(_dxt1, false)
	check(t1 != null, "request() returned a texture")
	check(TextureServer.is_finished(_dxt1, false), "key is finished after request()")
	var after_first: Dictionary = TextureServer.get_stats()
	check(int(after_first["total_upload_count"]) == 1, "exactly one upload so far (%d)" % after_first["total_upload_count"])

	var t2: ImageTexture = await TextureServer.request(_dxt1, false)
	check(t2 == t1, "second request() returns the identical cached texture")
	var after_second: Dictionary = TextureServer.get_stats()
	check(int(after_second["total_upload_count"]) == 1, "no re-upload on cache hit (%d)" % after_second["total_upload_count"])
	check(int(after_second["upload_cache_hits"]) >= 1, "cache hit counted (%d)" % after_second["upload_cache_hits"])

	print("--- in-flight deduplication ---")
	TextureServer.reset_stats()
	var fresh := _many[5] if _many.size() > 5 else _dxt5
	for i in 8:
		TextureServer.warm(fresh, false)
	await get_tree().process_frame
	var dedup_tex: ImageTexture = await TextureServer.request(fresh, false)
	check(dedup_tex != null, "deduplicated request resolved")
	var dstats: Dictionary = TextureServer.get_stats()
	check(int(dstats["decode_cache_misses"]) == 1,
		"8 concurrent warm() calls caused exactly 1 decode (%d)" % dstats["decode_cache_misses"])
	check(int(dstats["warm_attach_count"]) >= 1,
		"request() attached to the queued job rather than starting a new one (%d)" % dstats["warm_attach_count"])

	print("--- warm() from a worker thread ---")
	_worker_saw_job = false
	_worker_done = false
	var unwarmed := _many[9] if _many.size() > 9 else _dxt1
	var tid := WorkerThreadPool.add_task(_warm_from_worker.bind(unwarmed))
	WorkerThreadPool.wait_for_task_completion(tid)
	check(_worker_done, "worker task completed")
	check(not _worker_saw_job, "warm() did not mutate queue state on the worker thread")
	await get_tree().process_frame
	check(int(TextureServer.get_stats()["pending_queue_count"]) > 0 or TextureServer.is_finished(unwarmed, false),
		"the deferred enqueue landed on the main thread")

	print("--- failure is terminal, not a blocker ---")
	var missing := "textures/definitely/not/here.dds"
	var missing_tex: ImageTexture = await TextureServer.request(missing, false)
	check(missing_tex == null, "missing texture resolves to null rather than hanging")
	check(TextureServer.is_finished(missing, false), "failed texture is finished, not pending forever")
	var still_good: ImageTexture = await TextureServer.request(_dxt5, false)
	check(still_good != null, "a failure did not poison unrelated keys")

	print("--- upload budget under backlog ---")
	TextureServer.reset_stats()
	var prev_budget: int = TextureServer.uploads_per_frame_budget
	TextureServer.uploads_per_frame_budget = 4
	# Keys already resident from earlier phases are no-ops, so the expected
	# upload count is the not-yet-finished subset, not the whole list.
	var expected_uploads := 0
	for p in _many:
		if not TextureServer.is_finished(String(p), false):
			expected_uploads += 1
	for p in _many:
		TextureServer.warm(String(p), false)
	var max_seen := 0
	var frames := 0
	while frames < 120:
		await get_tree().process_frame
		frames += 1
		max_seen = maxi(max_seen, int(TextureServer.get_stats()["uploads_this_frame"]))
		if int(TextureServer.get_stats()["pending_upload_count"]) == 0 and int(TextureServer.get_stats()["pending_queue_count"]) == 0:
			break
	check(max_seen <= 4, "uploads never exceeded the per-frame budget (max %d of 4)" % max_seen)
	check(max_seen > 0, "the backlog actually drained through the budgeted path (max %d)" % max_seen)
	var bstats: Dictionary = TextureServer.get_stats()
	check(int(bstats["total_upload_count"]) == expected_uploads,
		"backlog uploaded exactly the %d not-yet-resident of %d queued (got %d)"
		% [expected_uploads, _many.size(), bstats["total_upload_count"]])
	TextureServer.uploads_per_frame_budget = prev_budget

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
