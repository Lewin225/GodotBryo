extends Node

## Stage E gate (Plans/server_stack_build_order.md): NifServer's contract layer
## -- canonical paths, the cache, in-flight dedup, the admission cap, the
## per-frame build budget, and the section 3.2 ownership rules.
##
## Tree CONTENT is covered by test_nif_tree_builder; this is about delivery.

const BARRACKS := "meshes/architecture/barracks/barracks01.nif"
const BOTTLE := "meshes/clutter/junk/milkbottle01.nif"
const DOOR := "meshes/dungeons/vaultruined/doors/vdoorslidingvault22.nif"
const MTFORWARD := "meshes/characters/_male/locomotion/male/mtforward.kf"
## Corpus-census fixture: this standalone KF has two sequences, proving why
## request_kf() returns AnimationLibrary rather than one Animation.
const MULTI_SEQUENCE_KF := "meshes/characters/_male/idleanims/1stp_stooldynamicidle.kf"
## 710 blocks / 2,111 built nodes, 12.8 ms per duplicate -- and an SCOL, so it
## is on the World Streamer's own path rather than a pathological outlier.
const HEAVY_SCOL := "meshes/scol/villatest.nif"

var failures := 0
var _received: Array = []
var _received_kf: Array[AnimationLibrary] = []
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


func _on_kf_result(library: AnimationLibrary) -> void:
	_received_kf.append(library)


func _drain_kf(expected: int, max_frames: int = 600) -> void:
	var frames := 0
	while _received_kf.size() < expected and frames < max_frames:
		await get_tree().process_frame
		frames += 1


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


func test_lod_request() -> void:
	print("--- paired _lod.nif request contract ---")
	NifServer.purge_all()
	NifServer.reset_stats()
	_received.clear()
	var lod_path := NifServer.lod_companion_path(BARRACKS)
	check(lod_path == "architecture/barracks/barracks01_lod.nif",
		"the full model resolves its canonical paired LOD path (%s)" % lod_path)
	NifServer.request_lod(BARRACKS, self, _on_result)
	await _drain(1)
	check(_received.size() == 1 and _received[0] is Node3D,
		"request_lod delivers the paired LOD tree")
	var s: Dictionary = NifServer.get_stats()
	check(int(s["lod_request_count"]) == 1, "one LOD request is counted")
	check(int(s["lod_path_cache_misses"]) == 1, "first paired-path lookup is a cache miss")
	check(int(s["document_cache_misses"]) == 1,
		"only the LOD document was parsed, not the full model")
	_free_received()

	var repeated := NifServer.lod_companion_path("Architecture\\Barracks\\Barracks01.NIF")
	check(repeated == lod_path, "alternate full-path spelling resolves the same companion")
	check(int(NifServer.get_stats()["lod_path_cache_hits"]) == 2,
		"paired-path lookup is cached by canonical full path")

	_received.clear()
	NifServer.request_lod("meshes/does/not/exist.nif", self, _on_result)
	await _drain(1)
	check(_received.size() == 1 and _received[0] == null,
		"a missing companion calls back once with null, never the full model")
	check(int(NifServer.get_stats()["lod_missing_count"]) == 1,
		"missing companion is counted without a parse attempt")
	_received.clear()


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


func test_kf_delivery_and_cache() -> void:
	print("--- standalone KF: callback, raw tracks, and persistent cache ---")
	NifServer.purge_all()
	NifServer.reset_stats()
	_received_kf.clear()
	var key := NifServer.canonical(MTFORWARD)
	var disk_path := NifServer._kf_cache_path(key)
	if FileAccess.file_exists(disk_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(disk_path))
	for i in 4:
		NifServer.request_kf(MTFORWARD, self, _on_kf_result)
	await _drain_kf(4)
	check(_received_kf.size() == 4, "all 4 KF callbacks fired (got %d)" % _received_kf.size())
	if _received_kf.size() == 4:
		var library := _received_kf[0]
		check(library != null, "KF callback delivered an AnimationLibrary")
		check(library != null and library.has_animation("Forward"), "mtforward keeps its authored Forward sequence")
		var animation := library.get_animation("Forward") if library != null else null
		var has_bare_root_track := false
		if animation != null:
			for track_index in animation.get_track_count():
				if String(animation.track_get_path(track_index)) == "Bip01":
					has_bare_root_track = true
					break
		check(has_bare_root_track, "KF tracks retain bare authored targets, not an inferred skeleton path")
		var shared := true
		for delivered in _received_kf:
			shared = shared and delivered == library
		check(shared, "simultaneous KF waiters share one immutable library")
	var stats: Dictionary = NifServer.get_stats()
	check(int(stats["kf_build_count"]) == 1, "one KF library build for 4 simultaneous requests (%d)" % stats["kf_build_count"])
	check(int(stats["kf_duplicate_waiter_count"]) == 3, "3 KF waiters coalesced (%d)" % stats["kf_duplicate_waiter_count"])
	check(int(stats["document_cache_misses"]) == 1, "KF cache miss parsed one document (%d)" % stats["document_cache_misses"])
	check(FileAccess.file_exists(disk_path), "converted KF library persisted under user://")

	NifServer.purge_all()
	NifServer.reset_stats()
	_received_kf.clear()
	NifServer.request_kf("Characters\\_Male\\Locomotion\\Male\\MTForward.KF", self, _on_kf_result)
	await _drain_kf(1)
	stats = NifServer.get_stats()
	check(_received_kf.size() == 1 and _received_kf[0] != null, "persistent KF cache delivers a library")
	check(int(stats["kf_disk_cache_hits"]) == 1, "second run hit the disk cache (%d)" % stats["kf_disk_cache_hits"])
	check(int(stats["document_cache_misses"]) == 0, "disk hit avoided reparsing the KF (%d misses)" % stats["document_cache_misses"])

	NifServer.purge_all()
	NifServer.reset_stats()
	_received_kf.clear()
	var corrupt := FileAccess.open(disk_path, FileAccess.WRITE)
	if corrupt != null:
		corrupt.store_string("not a Godot resource")
		corrupt.close()
	NifServer.request_kf(MTFORWARD, self, _on_kf_result)
	await _drain_kf(1)
	stats = NifServer.get_stats()
	check(_received_kf.size() == 1 and _received_kf[0] != null, "invalid KF cache rebuilds successfully")
	check(int(stats["kf_disk_cache_misses"]) == 1 and int(stats["kf_build_count"]) == 1,
		"invalid cache was ignored and rebuilt")
	_received_kf.clear()

	NifServer.purge_all()
	_received_kf.clear()
	NifServer.request_kf(MULTI_SEQUENCE_KF, self, _on_kf_result)
	await _drain_kf(1)
	check(_received_kf.size() == 1 and _received_kf[0] != null
		and _received_kf[0].get_animation_list().size() == 2,
		"multi-sequence KF returns both authored clips in one AnimationLibrary")
	_received_kf.clear()

	NifServer.purge_all()
	NifServer.reset_stats()
	if FileAccess.file_exists(disk_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(disk_path))
	var dead_owner := Node.new()
	add_child(dead_owner)
	NifServer.request_kf(MTFORWARD, dead_owner, dead_owner.queue_free)
	dead_owner.free() # gone before its cache probe/parse can lead to a build
	for i in 60:
		await get_tree().process_frame
	stats = NifServer.get_stats()
	check(int(stats["owner_gone_count"]) >= 1, "dead KF owner cancels its unclaimed build")
	check(int(stats["kf_build_count"]) == 0, "no KF library is built for a dead owner")


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


## Issue #11: the tree cache. The point is not the clock -- it is that every
## delivered instance shares the template's resource RIDs, which is what lets
## Godot coalesce them into one instanced draw.
func test_tree_cache_shares_resources() -> void:
	print("--- tree cache: instances share resources, never the template ---")
	NifServer.purge_all()
	NifServer.reset_stats()

	for i in 4:
		NifServer.request(BARRACKS, self, _on_result)
	await _drain(4)
	check(_received.size() == 4, "4 instances delivered (got %d)" % _received.size())
	if _received.size() < 4:
		_free_received()
		return

	var stats: Dictionary = NifServer.get_stats()
	check(int(stats["tree_cache_misses"]) == 1,
		"exactly one build populated the template (misses=%d)" % int(stats["tree_cache_misses"]))
	check(int(stats["tree_cache_hits"]) == 3,
		"the other 3 came from the cache (hits=%d)" % int(stats["tree_cache_hits"]))
	check(int(stats["resident_tree_count"]) == 1,
		"1 resident template (got %d)" % int(stats["resident_tree_count"]))
	check(int(stats["resident_tree_node_count"]) > 0,
		"residency reports a node count (%d)" % int(stats["resident_tree_node_count"]))

	# Distinct nodes...
	var roots: Array = _received
	var distinct := {}
	for r in roots:
		distinct[r.get_instance_id()] = true
	check(distinct.size() == 4, "every instance is a distinct node (%d)" % distinct.size())

	# ...sharing one set of resources.
	var first := _mesh_ids(roots[0])
	check(not first.is_empty(), "instance carries meshes (%d)" % first.size())
	var all_shared := true
	for r in roots:
		if _mesh_ids(r) != first:
			all_shared = false
	check(all_shared, "all 4 instances share one set of mesh/material resources")

	# The template is never handed out.
	var template_is_parented := false
	for r in roots:
		if r.get_parent() == null:
			template_is_parented = true
	check(not template_is_parented, "every delivered instance was adopted, none left unparented")
	_free_received()


## Metadata is how section 5.3 extra data, block types and the flatten decision
## reach the caller. duplicate() must carry it or a cached tree silently loses
## everything a fresh build reported.
func test_tree_cache_preserves_metadata() -> void:
	print("--- tree cache: duplicated trees keep their metadata ---")
	NifServer.purge_all()
	NifServer.reset_stats()
	NifServer.request(DOOR, self, _on_result)
	await _drain(1)
	NifServer.request(DOOR, self, _on_result)
	await _drain(2)
	if _received.size() < 2:
		check(false, "2 door instances delivered (got %d)" % _received.size())
		_free_received()
		return
	var a: Node3D = _received[0]
	var b: Node3D = _received[1]
	check(int(NifServer.get_stats()["tree_cache_hits"]) == 1, "second door was a cache hit")
	var a_meta := _meta_of(a)
	var b_meta := _meta_of(b)
	check(not a_meta.is_empty(), "the built tree carries metadata (%d keys)" % a_meta.size())
	check(a_meta == b_meta, "the duplicated tree carries identical metadata")
	var a_anim := _has_class(a, "AnimationPlayer")
	check(a_anim == _has_class(b, "AnimationPlayer"),
		"the duplicated tree keeps its AnimationPlayer (%s)" % str(a_anim))
	_free_received()


## Section 10's cache identity is (path, flatten): the two forms are different
## artefacts from one document and must not collide.
func test_tree_cache_identity_includes_flatten() -> void:
	print("--- tree cache: (path, flatten) are separate entries ---")
	NifServer.purge_all()
	NifServer.reset_stats()
	NifServer.request(BARRACKS, self, _on_result, false)
	await _drain(1)
	NifServer.request(BARRACKS, self, _on_result, true)
	await _drain(2)
	var stats: Dictionary = NifServer.get_stats()
	check(int(stats["tree_cache_misses"]) == 2,
		"both forms built (misses=%d, not a collision)" % int(stats["tree_cache_misses"]))
	check(int(stats["resident_tree_count"]) == 2,
		"2 resident templates (got %d)" % int(stats["resident_tree_count"]))
	if _received.size() == 2 and _received[0] != null and _received[1] != null:
		check(_received[0].get_meta("nif_flattened", false) != _received[1].get_meta("nif_flattened", false)
				or String(_received[1].get_meta("nif_not_flattened_because", "")) != "",
			"the two forms differ, or the static one says why it could not flatten")
	_free_received()


## Residency has to fall again, or there is no pressure valve at all.
func test_tree_cache_purge() -> void:
	print("--- tree cache: purge releases templates ---")
	NifServer.purge_all()
	NifServer.reset_stats()
	NifServer.request(BOTTLE, self, _on_result)
	await _drain(1)
	check(int(NifServer.get_stats()["resident_tree_count"]) == 1, "1 template resident")
	NifServer.purge(BOTTLE)
	var after: Dictionary = NifServer.get_stats()
	check(int(after["resident_tree_count"]) == 0,
		"purge() dropped it (%d resident)" % int(after["resident_tree_count"]))
	check(int(after["resident_tree_node_count"]) == 0, "node residency fell to 0")
	check(int(after["tree_purge_count"]) == 1, "purge counted")
	# The delivered instance must survive its template being dropped.
	check(_received.size() == 1 and is_instance_valid(_received[0]),
		"the already-delivered instance is unaffected by the purge")
	_free_received()
	NifServer.purge_all()


## A cache hit duplicates synchronously, so the per-frame drain has to be
## bounded by wall clock rather than by count. Without that, 12 hits on a heavy
## SCOL is a quarter-second frame.
func test_tree_cache_frame_budget() -> void:
	print("--- tree cache: a frame of heavy cache hits stays budgeted ---")
	NifServer.purge_all()
	NifServer.reset_stats()
	check(NifServer.build_time_budget_usec > 0,
		"a wall-clock build budget is set (%d usec)" % NifServer.build_time_budget_usec)

	# Populate the template first, so every request below is a hit.
	NifServer.request(HEAVY_SCOL, self, _on_result)
	await _drain(1)
	if _received.size() != 1 or _received[0] == null:
		check(false, "heavy SCOL built")
		_free_received()
		return
	_free_received()

	const HITS := 24
	for i in HITS:
		NifServer.request(HEAVY_SCOL, self, _on_result)

	var worst := 0
	var frames := 0
	while _received.size() < HITS and frames < 600:
		var t0 := Time.get_ticks_usec()
		await get_tree().process_frame
		worst = maxi(worst, Time.get_ticks_usec() - t0)
		frames += 1
	check(_received.size() == HITS, "%d instances delivered (got %d)" % [HITS, _received.size()])
	check(frames > 1, "the drain spread across %d frames rather than one" % frames)
	# Generous against CI jitter: the point is that it is bounded at all, not
	# that it hits the budget exactly.
	var ceiling := NifServer.build_time_budget_usec * 4
	check(worst < ceiling,
		"worst frame %.1f ms is under the %.1f ms ceiling" % [worst / 1000.0, ceiling / 1000.0])
	print("     %d hits over %d frames, worst frame %.1f ms" % [HITS, frames, worst / 1000.0])
	_free_received()
	NifServer.purge_all()


func _mesh_ids(root: Node) -> Array:
	var out: Array = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.push_back(c)
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			out.append((n as MeshInstance3D).mesh.get_instance_id())
	out.sort()
	return out


func _meta_of(root: Node) -> Dictionary:
	var out := {}
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.push_back(c)
		for k in n.get_meta_list():
			out["%s/%s" % [n.name, k]] = n.get_meta(k)
	return out


func _has_class(root: Node, klass: String) -> bool:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.is_class(klass):
			return true
		for c in n.get_children():
			stack.push_back(c)
	return false


func _ready() -> void:
	check(ArchiveServer.is_ready(), "ArchiveServer available")
	test_canonical_paths()
	await test_delivery_and_cache()
	await test_lod_request()
	await test_inflight_dedup()
	await test_kf_delivery_and_cache()
	await test_build_budget()
	await test_missing_path()
	await test_owner_gone()
	await test_orphan_safety_net()
	await test_tree_cache_shares_resources()
	await test_tree_cache_preserves_metadata()
	await test_tree_cache_identity_includes_flatten()
	await test_tree_cache_purge()
	await test_tree_cache_frame_budget()

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
