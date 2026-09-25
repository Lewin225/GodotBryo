extends Node

## Stage B gate (Plans/Completed Plans/server_stack_build_order.md): ArchiveServer owns archive
## discovery, BSA priority and byte reads, with an immutable catalog that is
## safe for concurrent reads.

const DATA_DIR := "../fresh_nv_copy/Data/" ## relative to the project dir (the process CWD)
const THREADS := 8

var failures := 0
var _probe_paths: PackedStringArray = []
var _serial: Dictionary = {}
var _concurrent: Array = []
var _mutex := Mutex.new()


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


func test_initialization() -> void:
	print("--- initialization ---")
	check(ArchiveServer.is_ready(), "ArchiveServer initialized (error: '%s')" % ArchiveServer.get_init_error())
	var stats: Dictionary = ArchiveServer.get_stats()
	var on_disk := 0
	var dir := DirAccess.open(DATA_DIR)
	if dir != null:
		for f in dir.get_files():
			if f.to_lower().ends_with(".bsa"):
				on_disk += 1
	check(int(stats["archive_count"]) == on_disk,
		"opened every archive on disk (%d of %d)" % [stats["archive_count"], on_disk])
	check(PackedStringArray(stats["failed_archives"]).is_empty(),
		"no archive failed to open (%s)" % str(stats["failed_archives"]))
	check(int(stats["entry_count"]) > 100000, "catalog indexed %d entries" % stats["entry_count"])


func test_priority_full_census() -> void:
	print("--- priority parity: full entry census vs the existing resolver ---")
	# Test-only, explicitly allowlisted: compare against the real heuristic in
	# GamebryoMeshResolver._build_bsa_order() rather than a reimplementation.
	var old := GamebryoMeshResolver.new(DATA_DIR)
	var order: Array = old._bsa_order
	check(order.size() > 0, "resolver order has %d archives" % order.size())
	check(Array(ArchiveServer.get_stats()["archive_order"]) == order,
		"catalog archive order matches the resolver's exactly")

	var expected := {}
	var duplicates := 0
	for archive_name in order:
		var r := BsaReader.new()
		if not r.open(DATA_DIR + String(archive_name)):
			continue
		for e in r.list_entries():
			var p := String(e)
			if expected.has(p):
				duplicates += 1
			else:
				expected[p] = String(archive_name)
	check(expected.size() > 0, "census built: %d unique paths, %d duplicate occurrences" % [expected.size(), duplicates])
	check(duplicates > 0, "corpus actually contains duplicates to arbitrate (%d)" % duplicates)

	var mismatches := 0
	var first_bad := ""
	for p in expected.keys():
		var got: String = ArchiveServer.winning_archive(p)
		if got != expected[p]:
			mismatches += 1
			if first_bad.is_empty():
				first_bad = "%s: expected %s, got %s" % [p, expected[p], got]
	check(mismatches == 0, "winner matches for all %d paths%s"
		% [expected.size(), "" if mismatches == 0 else (" (%d wrong, e.g. %s)" % [mismatches, first_bad])])


func _task(_i: int) -> void:
	var mine := {}
	for p in _probe_paths:
		mine[p] = _digest(PackedByteArray(ArchiveServer.read(p)["data"]))
	_mutex.lock()
	_concurrent.append(mine)
	_mutex.unlock()


func test_concurrent_reads() -> void:
	print("--- serial vs concurrent reads (nif / dds / wav) ---")
	_probe_paths = PackedStringArray()
	for prefix in ["meshes/architecture/", "textures/architecture/", "sound/fx/"]:
		var listed := ArchiveServer.list_files_with_prefix(prefix)
		var taken := 0
		for p in listed:
			var low := String(p)
			if low.ends_with(".nif") or low.ends_with(".dds") or low.ends_with(".wav"):
				_probe_paths.append(low)
				taken += 1
				if taken >= 6:
					break
	check(_probe_paths.size() >= 6, "collected %d probe paths across asset types" % _probe_paths.size())

	for p in _probe_paths:
		var r: Dictionary = ArchiveServer.read(p)
		check(bool(r["found"]), "serial read found %s (%d bytes)" % [p, PackedByteArray(r["data"]).size()]) if false else null
		_serial[p] = _digest(PackedByteArray(r["data"]))

	var before: Dictionary = ArchiveServer.get_stats()
	_concurrent.clear()
	var ids := []
	for t in THREADS:
		ids.append(WorkerThreadPool.add_task(_task.bind(t)))
	for id in ids:
		WorkerThreadPool.wait_for_task_completion(id)
	check(_concurrent.size() == THREADS, "all %d worker tasks completed" % THREADS)

	var mismatches := 0
	var compared := 0
	for mine in _concurrent:
		for p in _serial.keys():
			compared += 1
			if not mine.has(p) or mine[p] != _serial[p]:
				mismatches += 1
	check(mismatches == 0, "%d/%d concurrent digests byte-identical to serial" % [compared - mismatches, compared])

	# No lazy opening and no catalog mutation from a worker.
	var after: Dictionary = ArchiveServer.get_stats()
	check(int(before["entry_count"]) == int(after["entry_count"]),
		"entry count unchanged by concurrent reads (%d)" % after["entry_count"])
	check(Array(before["archive_order"]) == Array(after["archive_order"]),
		"archive order unchanged by concurrent reads")


func test_path_identity_and_rejects() -> void:
	print("--- path normalization and rejects ---")
	var a: Dictionary = ArchiveServer.read("meshes\\Architecture\\Barracks\\Barracks01.NIF")
	var b: Dictionary = ArchiveServer.read("meshes/architecture/barracks/barracks01.nif")
	check(bool(a["found"]) and bool(b["found"]), "both spellings resolve")
	check(String(a["archive"]) == String(b["archive"]), "both spellings pick the same archive (%s)" % a["archive"])
	check(_digest(PackedByteArray(a["data"])) == _digest(PackedByteArray(b["data"])),
		"both spellings return identical bytes")

	var seen := {}
	for bad in ["", "/abs/path.nif", "../escape.nif", "res://x.nif"]:
		var r: Dictionary = ArchiveServer.read(bad)
		check(not bool(r["found"]), "rejected '%s'" % bad)
		seen[String(r["error"])] = true
	check(seen.size() == 4, "each reject reports a distinct reason (%d distinct)" % seen.size())


func test_result_kinds() -> void:
	print("--- the four distinguishable result kinds ---")
	var missing: Dictionary = ArchiveServer.read("meshes/definitely/not/here.nif")
	check(not bool(missing["found"]) and String(missing["error"]).findn("not found") != -1,
		"not found: '%s'" % missing["error"])

	# The corpus contains exactly one genuinely empty entry and exactly one
	# whose deflate stream lacks a trailer but whose declared bytes all
	# recover. Both were previously reported as empty by the legacy reader.
	var empty: Dictionary = ArchiveServer.read("menus/do_not_delete.txt")
	check(bool(empty["found"]) and PackedByteArray(empty["data"]).size() == 0 and String(empty["error"]).is_empty(),
		"successful zero-length read is found=true with no error")

	var trailerless: Dictionary = ArchiveServer.read("menus/s.txt")
	var tdata := PackedByteArray(trailerless["data"])
	check(bool(trailerless["found"]) and String(trailerless["error"]).is_empty(),
		"trailer-less stream reads successfully ('%s')" % trailerless["error"])
	check(tdata.size() == 4 and tdata.get_string_from_ascii() == "@#$%",
		"trailer-less stream recovers all 4 declared bytes (got %d: '%s')"
		% [tdata.size(), tdata.get_string_from_ascii()])

	var bad_cat := ArchiveCatalog.new()
	var opened := bad_cat.open_data_dir("/definitely/not/a/data/dir")
	check(not opened, "initialization failure on a bad directory")
	var uninit: Dictionary = bad_cat.read("meshes/x.nif")
	check(not bool(uninit["found"]) and String(uninit["error"]) != String(missing["error"]),
		"init failure is distinguishable from not-found: '%s'" % uninit["error"])

	# Extraction failure: intact header and index, corrupted payload region.
	var tmp_dir := OS.get_user_data_dir().path_join("archive_corrupt_test")
	DirAccess.make_dir_recursive_absolute(tmp_dir)
	var src := FileAccess.open(DATA_DIR + "Fallout - Misc.bsa", FileAccess.READ)
	if src == null:
		check(false, "opened Fallout - Misc.bsa to derive a corrupted copy")
		return
	var bytes := src.get_buffer(src.get_length())
	src.close()
	for i in range(int(bytes.size() * 0.6), bytes.size(), 7):
		bytes[i] = (bytes[i] + 137) % 256
	var dst := FileAccess.open(tmp_dir.path_join("Corrupt.bsa"), FileAccess.WRITE)
	dst.store_buffer(bytes)
	dst.close()

	var corrupt := ArchiveCatalog.new()
	check(corrupt.open_data_dir(tmp_dir), "corrupted archive still opens (header and index intact)")
	var extract_failures := 0
	var sample := 0
	for p in corrupt.list_files_with_prefix(""):
		sample += 1
		var r: Dictionary = corrupt.read(String(p))
		if not bool(r["found"]) and String(r["error"]).findn("extraction failed") != -1:
			extract_failures += 1
		if sample >= 120:
			break
	check(extract_failures > 0,
		"corrupted payload produces 'extraction failed' distinct from not-found (%d of %d sampled)"
		% [extract_failures, sample])


func test_prefix_enumeration() -> void:
	print("--- prefix enumeration ---")
	var listed := ArchiveServer.list_files_with_prefix("meshes/architecture/barracks")
	check(listed.size() > 0, "prefix returned %d paths" % listed.size())
	var all_match := true
	var sorted_ok := true
	var prev := ""
	var dupes := {}
	var dupe_count := 0
	for p in listed:
		if not String(p).begins_with("meshes/architecture/barracks"):
			all_match = false
		if prev != "" and String(p) < prev:
			sorted_ok = false
		prev = String(p)
		if dupes.has(String(p)):
			dupe_count += 1
		dupes[String(p)] = true
	check(all_match, "every returned path matches the prefix")
	check(sorted_ok, "results are sorted")
	check(dupe_count == 0, "results are deduplicated by the winner rule")
	if listed.size() > 0:
		check(bool(ArchiveServer.read(listed[0])["found"]), "first enumerated path reads back (%s)" % listed[0])
	check(ArchiveServer.list_files_with_prefix("../nope").is_empty(), "rejected prefix returns nothing")


func _ready() -> void:
	test_initialization()
	test_priority_full_census()
	test_concurrent_reads()
	test_path_identity_and_rejects()
	test_result_kinds()
	test_prefix_enumeration()

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
