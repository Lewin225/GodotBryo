extends Node

## Stage E gate (Plans/server_stack_build_order.md): NifServer's contract layer
## -- canonical paths, the cache, in-flight dedup, the admission cap, the
## per-frame build budget, and the section 3.2 ownership rules.
##
## Tree CONTENT is covered by test_nif_tree_builder; this is about delivery.

const BARRACKS := "meshes/architecture/barracks/barracks01.nif"
const BOTTLE := "meshes/clutter/junk/milkbottle01.nif"
const DOOR := "meshes/dungeons/vaultruined/doors/vdoorslidingvault22.nif"

var failures := 0
var _received: Array = []
var _adopt: Node3D = null


func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1


func _on_result(node: Node3D) -> void:
	_received.append(node)
	if node != null:
		# Ownership transfers on delivery: park it so the safety net does not
		# reclaim it, and free it ourselves at the end of each check.
		add_child(node)


func _drain(expected: int, max_frames: int = 600) -> void:
	var frames := 0
	while _received.size() < expected and frames < max_frames:
		await get_tree().process_frame
		frames += 1


func _free_received() -> void:
	for n in _received:
		if n != null and is_instance_valid(n):
			n.free()
	_received.clear()


func test_canonical_paths() -> void:
	print("--- section 3.3: canonical paths ---")
	var forms := [
		"meshes/architecture/barracks/barracks01.nif",
		"Architecture\\Barracks\\Barracks01.NIF",
		"architecture/barracks/barracks01.nif",
		"/meshes/Architecture/Barracks/Barracks01.nif",
	]
	var keys := {}
	for f in forms:
		keys[NifServer.canonical(f)] = true
	check(keys.size() == 1, "%d spellings resolve to one cache identity (got %d)" % [forms.size(), keys.size()])
	check(NifServer.canonical("") == "", "an empty path stays empty and is refused")


func test_delivery_and_cache() -> void:
	print("--- delivery, then the document cache ---")
	NifServer.reset_stats()
	_received.clear()
	NifServer.request(BARRACKS, self, _on_result)
	await _drain(1)
	check(_received.size() == 1, "callback fired exactly once (got %d)" % _received.size())
	check(_received.size() == 1 and _received[0] is Node3D, "delivered a Node3D")
	var s: Dictionary = NifServer.get_stats()
	check(int(s["document_cache_misses"]) == 1, "first request was a cache miss")
	_free_received()

	# The same path in a different spelling must hit the cached document.
	NifServer.request("Architecture\\Barracks\\Barracks01.NIF", self, _on_result)
	await _drain(1)
	s = NifServer.get_stats()
	check(int(s["document_cache_hits"]) == 1, "a differently-spelled repeat hit the cache (%d)" % s["document_cache_hits"])
	check(int(s["document_cache_misses"]) == 1, "and caused no second parse (%d misses)" % s["document_cache_misses"])
	check(_received.size() == 1 and _received[0] is Node3D, "cache hit still delivers a real tree")
	_free_received()


func test_inflight_dedup() -> void:
	print("--- in-flight requests share one resolve ---")
	NifServer.reset_stats()
	NifServer.purge_all()
	_received.clear()
	for i in 5:
		NifServer.request(BOTTLE, self, _on_result)
	await _drain(5)
	var s: Dictionary = NifServer.get_stats()
	check(_received.size() == 5, "all 5 callbacks fired (got %d)" % _received.size())
	check(int(s["document_cache_misses"]) == 1, "one parse for 5 simultaneous requests (%d)" % s["document_cache_misses"])
	check(int(s["duplicate_waiter_count"]) == 4, "4 attached as waiters (%d)" % s["duplicate_waiter_count"])
	_free_received()


func test_build_budget() -> void:
	print("--- section 4.2: builds stay within the per-frame budget ---")
	NifServer.reset_stats()
	NifServer.purge_all()
	_received.clear()
	var prev: int = NifServer.builds_per_frame_budget
	NifServer.builds_per_frame_budget = 4
	# 100 requests for one path: one resolve, then 100 builds to drain.
	for i in 100:
		NifServer.request(BOTTLE, self, _on_result)
	var max_seen := 0
	var frames := 0
	while _received.size() < 100 and frames < 900:
		await get_tree().process_frame
		frames += 1
		max_seen = maxi(max_seen, int(NifServer.get_stats()["builds_this_frame"]))
	check(_received.size() == 100, "all 100 delivered (got %d)" % _received.size())
	check(max_seen <= 4, "never exceeded the budget of 4 in a frame (max %d)" % max_seen)
	check(frames >= 25, "the drain actually spanned frames (%d)" % frames)
	NifServer.builds_per_frame_budget = prev
	_free_received()


func test_missing_path() -> void:
	print("--- section 3.4: failure contract ---")
	_received.clear()
	NifServer.request("meshes/does/not/exist.nif", self, _on_result)
	await _drain(1)
	check(_received.size() == 1, "a missing path still calls back exactly once")
	check(_received.size() == 1 and _received[0] == null, "and delivers null")
	_received.clear()


func test_owner_gone() -> void:
	print("--- section 3.2: a dead owner gets no tree ---")
	NifServer.reset_stats()
	NifServer.purge_all()
	var host := Node.new()
	add_child(host)
	# A method on the host, per 3.2 -- not a closure capturing it.
	NifServer.request(DOOR, host, host.queue_free)
	host.free() # gone before the resolve can finish
	var frames := 0
	while frames < 240:
		await get_tree().process_frame
		frames += 1
	var s: Dictionary = NifServer.get_stats()
	check(int(s["owner_gone_count"]) >= 1, "the dead owner was noticed (%d)" % s["owner_gone_count"])
	check(int(s["build_count"]) == 0, "no tree was built for it (%d)" % s["build_count"])


func test_orphan_safety_net() -> void:
	print("--- section 3.2 / E7: the orphan net is deferred, not synchronous ---")
	NifServer.reset_stats()
	NifServer.purge_all()
	_adopt = null
	NifServer.request(BOTTLE, self, _on_result_parent_next_frame)
	var frames := 0
	while not is_instance_valid(_adopt) and frames < 300:
		await get_tree().process_frame
		frames += 1
	check(is_instance_valid(_adopt), "a result was delivered")
	if _adopt == null:
		return
	# Parent it a frame LATE, which is legitimate and must not have been freed.
	await get_tree().process_frame
	check(is_instance_valid(_adopt), "a caller parenting on the next frame is not freed underneath it")
	if is_instance_valid(_adopt):
		add_child(_adopt)
		_adopt.free()
	_adopt = null


func _on_result_parent_next_frame(node: Node3D) -> void:
	_adopt = node


func _ready() -> void:
	check(ArchiveServer.is_ready(), "ArchiveServer available")
	test_canonical_paths()
	await test_delivery_and_cache()
	await test_inflight_dedup()
	await test_build_budget()
	await test_missing_path()
	await test_owner_gone()
	await test_orphan_safety_net()

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
