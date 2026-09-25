extends Node

## Stage A gate (Plans/Completed Plans/server_stack_build_order.md): BsaArchive::read_at() is
## positional (pread / ReadFile+OVERLAPPED), so one shared reader is safe for
## concurrent extraction with no per-thread reader and no mutex.

const DATA_DIR := "../fresh_nv_copy/Data/" ## relative to the project dir (the process CWD), not to this script
const THREADS := 8

var failures := 0
var _shared: BsaReader
var _paths: PackedStringArray = []
var _serial: Dictionary = {}          # path -> sha256 of extracted bytes
var _concurrent: Array = []           # per-task {path -> sha256}
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


# --- serial baseline -------------------------------------------------------

func build_baseline(archive: String, sample: int) -> void:
	print("--- baseline: ", archive, " ---")
	_shared = BsaReader.new()
	var opened := _shared.open(DATA_DIR + archive)
	check(opened, "open() succeeded (error: %s)" % _shared.get_last_error())
	if not opened:
		return
	var entries := _shared.list_entries()
	check(entries.size() > 0, "entry count > 0 (got %d)" % entries.size())

	# Spread the sample across the archive so both compressed and
	# uncompressed records are covered.
	var step: int = maxi(1, entries.size() / sample)
	_paths = PackedStringArray()
	var i := 0
	while i < entries.size() and _paths.size() < sample:
		_paths.append(String(entries[i]))
		i += step

	var total := 0
	for p in _paths:
		var b: PackedByteArray = _shared.extract(p)
		_serial[p] = _digest(b)
		total += b.size()
	check(_serial.size() == _paths.size(), "serial extraction produced %d digests" % _serial.size())
	check(total > 0, "serial extraction returned %d bytes total" % total)


# --- concurrent comparison -------------------------------------------------

func _task(task_index: int) -> void:
	var mine := {}
	for p in _paths:
		mine[p] = _digest(_shared.extract(p))
	_mutex.lock()
	_concurrent.append(mine)
	_mutex.unlock()


func test_concurrent() -> void:
	print("--- concurrent extraction, %d threads x %d entries, one shared reader ---" % [THREADS, _paths.size()])
	_concurrent.clear()
	var ids := []
	for t in THREADS:
		ids.append(WorkerThreadPool.add_task(_task.bind(t)))
	for id in ids:
		WorkerThreadPool.wait_for_task_completion(id)

	check(_concurrent.size() == THREADS, "all %d tasks completed" % THREADS)
	var mismatches := 0
	var compared := 0
	for mine in _concurrent:
		for p in _serial.keys():
			compared += 1
			if not mine.has(p) or mine[p] != _serial[p]:
				mismatches += 1
				if mismatches <= 3:
					print("      mismatch on ", p)
	check(mismatches == 0, "%d/%d concurrent digests byte-identical to serial" % [compared - mismatches, compared])


# --- content coverage ------------------------------------------------------

func test_coverage() -> void:
	print("--- coverage: compressed, uncompressed, embedded names, empty ---")
	var r := BsaReader.new()
	if not r.open(DATA_DIR + "Fallout - Meshes.bsa"):
		check(false, "Fallout - Meshes.bsa opened")
		return
	var entries := r.list_entries()

	# Embedded file names: FO3/NV mesh archives prefix each blob with a
	# BZString copy of its own path. If read_at()/extract() mishandled that
	# prefix the NIF magic would not be at offset 0.
	var nif := ""
	for e in entries:
		if String(e).to_lower().ends_with(".nif"):
			nif = String(e)
			break
	check(not nif.is_empty(), "found a .nif entry to probe (%s)" % nif)
	if not nif.is_empty():
		var data: PackedByteArray = r.extract(nif)
		var head := data.slice(0, 20).get_string_from_ascii()
		check(head.findn("gamebryo") != -1 or head.findn("netimmerse") != -1,
			"embedded-name prefix skipped; magic at offset 0 ('%s')" % head.strip_edges())

	# Size spread: the sample above already crosses the compressed/uncompressed
	# boundary; assert we saw both a small and a large payload decode cleanly.
	var smallest := 1 << 30
	var largest := 0
	for p in _paths:
		var n: int = _shared.extract(p).size()
		smallest = mini(smallest, n)
		largest = maxi(largest, n)
	check(largest > 100000, "largest sampled payload %d bytes" % largest)
	check(smallest >= 0, "smallest sampled payload %d bytes" % smallest)


# --- error paths -----------------------------------------------------------

func test_errors() -> void:
	print("--- error paths ---")
	var r := BsaReader.new()
	r.open(DATA_DIR + "Fallout - Misc.bsa")
	var missing: PackedByteArray = r.extract("no/such/file.xyz")
	check(missing.size() == 0, "missing path extracts to 0 bytes")

	var bad := BsaReader.new()
	check(not bad.open(DATA_DIR + "definitely_not_here.bsa"),
		"opening a nonexistent archive fails")
	check(not bad.get_last_error().is_empty(), "nonexistent archive reports an error")

	# Malformed archives must be written to a real filesystem path: the native
	# reader uses std::fopen and cannot resolve Godot's "user://" scheme, so a
	# user:// path would fail at open() and prove nothing about truncation.
	var tmp_dir := OS.get_user_data_dir()
	var src := FileAccess.open(DATA_DIR + "Fallout - Misc.bsa", FileAccess.READ)
	check(src != null, "opened a real archive to derive a truncated copy")
	if src == null:
		return
	var head := src.get_buffer(64)
	src.close()

	var trunc_path := tmp_dir.path_join("truncated_test.bsa")
	var out := FileAccess.open(trunc_path, FileAccess.WRITE)
	check(out != null, "wrote truncated archive to %s" % trunc_path)
	if out != null:
		out.store_buffer(head)
		out.close()
	var trunc := BsaReader.new()
	var trunc_opened := trunc.open(trunc_path)
	var trunc_err := trunc.get_last_error()
	check(not trunc_opened, "truncated archive fails to open")
	check(trunc_err.findn("could not open") == -1,
		"truncation error is about structure, not file access ('%s')" % trunc_err)

	var junk_path := tmp_dir.path_join("junk_test.bsa")
	var junk := FileAccess.open(junk_path, FileAccess.WRITE)
	if junk != null:
		junk.store_buffer("NOTABSA_and_then_some_padding_bytes_here".to_ascii_buffer())
		junk.close()
	var bogus := BsaReader.new()
	var bogus_opened := bogus.open(junk_path)
	var bogus_err := bogus.get_last_error()
	check(not bogus_opened, "bad-magic archive fails to open")
	check(bogus_err.findn("magic") != -1,
		"bad magic is reported as bad magic ('%s')" % bogus_err)
	check(bogus_err != trunc_err,
		"bad magic and truncation are distinguishable")


func test_zero_length() -> void:
	print("--- zero-length entries across the shipped archives ---")
	var found := ""
	var scanned := 0
	for name in ["Fallout - Misc.bsa", "Update.bsa", "Fallout - Meshes.bsa", "Fallout - Textures.bsa"]:
		var r := BsaReader.new()
		if not r.open(DATA_DIR + name):
			continue
		scanned += 1
		for e in r.list_entries():
			if r.extract(String(e)).size() == 0:
				found = name + " :: " + String(e)
				break
		if not found.is_empty():
			break
	if found.is_empty():
		print("  note: no zero-length entry exists in %d scanned archives; the empty-read path is covered by the shim's size==0 early return, not by real data" % scanned)
	else:
		check(true, "zero-length entry extracts to 0 bytes (%s)" % found)

func _ready() -> void:
	build_baseline("Fallout - Meshes.bsa", 40)
	test_concurrent()
	test_coverage()
	test_zero_length()
	test_errors()

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
