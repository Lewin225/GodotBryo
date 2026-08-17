extends Node

const DATA_DIR := "/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/"

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func test_archive(archive_name: String, sample_count: int) -> void:
	print("--- ", archive_name, " ---")
	var reader := BsaReader.new()
	var opened := reader.open(DATA_DIR + archive_name)
	check(opened, "open() succeeded (error: %s)" % reader.get_last_error())
	if not opened:
		return

	var entries := reader.list_entries()
	check(entries.size() > 0, "entry count > 0 (got %d)" % entries.size())
	print("  entry count: ", entries.size())

	# Extract a spread of sample_count entries across the archive (not just
	# the first few) to exercise both compressed and uncompressed records.
	var step: int = max(1, entries.size() / sample_count)
	var extracted_ok := 0
	var extracted_total := 0
	var i := 0
	while i < entries.size():
		var path: String = entries[i]
		var data := reader.extract(path)
		extracted_total += 1
		if data.size() > 0:
			extracted_ok += 1
		else:
			print("  FAIL extract returned empty: ", path)
		i += step

	check(extracted_ok == extracted_total, "%d/%d sampled entries extracted non-empty" % [extracted_ok, extracted_total])

func test_nif_magic() -> void:
	print("--- NIF magic check (Fallout - Meshes.bsa) ---")
	var reader := BsaReader.new()
	if not reader.open(DATA_DIR + "Fallout - Meshes.bsa"):
		check(false, "open Fallout - Meshes.bsa")
		return
	var entries := reader.list_entries()
	var nif_path := ""
	for p in entries:
		if String(p).ends_with(".nif"):
			nif_path = p
			break
	check(nif_path != "", "found at least one .nif entry")
	if nif_path == "":
		return
	var data := reader.extract(nif_path)
	check(data.size() > 4, "extracted nif non-trivial size: " + nif_path)
	# NetImmerse/Gamebryo NIF files start with an ASCII header string, e.g.
	# "Gamebryo File Format" or "NetImmerse File Format". Just check it's
	# printable ASCII text for the first bytes as a sanity signal that we
	# decompressed real NIF content, not garbage.
	var head := PackedByteArray()
	for j in range(min(20, data.size())):
		head.append(data[j])
	var text := head.get_string_from_ascii()
	print("  first bytes as text: '", text, "'")
	check(text.findn("gamebryo") != -1 or text.findn("netimmerse") != -1, "header text looks like a NIF magic string")

func _ready() -> void:
	test_archive("Fallout - Meshes.bsa", 25)
	test_archive("Fallout - Textures.bsa", 25)
	test_archive("Fallout - Sound.bsa", 15)
	test_archive("DeadMoney - Main.bsa", 15)
	test_nif_magic()

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
