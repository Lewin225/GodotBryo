extends Node

const ESM_PATH := "/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/FalloutNV.esm"

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func _ready() -> void:
	print("--- FalloutNV.esm ---")
	var reader := EsmReader.new()
	var opened := reader.open(ESM_PATH)
	check(opened, "open() succeeded (error: %s)" % reader.get_last_error())
	if not opened:
		_finish()
		return

	var header: Dictionary = reader.get_header_info()
	print("  version: ", header.get("version"))
	print("  num_records (header claim): ", header.get("num_records"))
	print("  next_object_id: ", header.get("next_object_id"))
	print("  masters: ", header.get("masters"))
	check(header.get("masters", ["x"]).size() == 0, "FalloutNV.esm has no masters (it's the base master file)")
	check(float(header.get("version", 0.0)) > 0.0, "header version is non-zero")

	print("--- record-type histogram ---")
	var histogram: Dictionary = reader.get_record_type_histogram()
	check(histogram.size() > 0, "histogram is non-empty (%d distinct types)" % histogram.size())
	check(histogram.get("TES4", 0) == 1, "exactly one TES4 record (the file header itself)")

	# Print sorted by count desc, top 15, as the human-checkable cross-reference
	# against an external inspector (see phases/0/02-esm-parser.md follow-up).
	var keys: Array = histogram.keys()
	keys.sort_custom(func(a, b): return histogram[a] > histogram[b])
	var total_records := 0
	for k in histogram.keys():
		total_records += int(histogram[k])
	print("  total records counted by walk: ", total_records)
	for i in range(min(15, keys.size())):
		var k = keys[i]
		print("  %-6s %d" % [k, histogram[k]])

	check(histogram.has("STAT"), "STAT record type present")
	check(histogram.has("CELL"), "CELL record type present")
	check(histogram.has("NPC_"), "NPC_ record type present")

	print("--- STAT -> MODL resolution ---")
	var stat: Dictionary = reader.find_first_stat_model()
	check(not stat.is_empty(), "found a STAT record with a non-empty MODL subrecord")
	if not stat.is_empty():
		print("  form_id: 0x%08X" % int(stat.get("form_id")))
		print("  editor_id: ", stat.get("editor_id"))
		print("  model: ", stat.get("model"))
		check(String(stat.get("model", "")).to_lower().ends_with(".nif"), "resolved model path ends with .nif")

	print("--- compressed record decompression ---")
	var compressed: Dictionary = reader.find_first_compressed_record()
	if compressed.is_empty():
		print("  (no compressed records found in FalloutNV.esm — not exercised by this file)")
	else:
		print("  type: ", compressed.get("type"), " form_id: 0x%08X" % int(compressed.get("form_id")))
		print("  compressed_size: ", compressed.get("compressed_size"), " decompressed_size: ", compressed.get("decompressed_size"))
		check(int(compressed.get("decompressed_size")) > int(compressed.get("compressed_size")), "decompressed size is larger than compressed size")

	print("--- CELL.XCLL (per-cell lighting) ---")
	var cell: Dictionary = reader.find_cell_by_editor_id("GSDocMitchellHouse")
	check(not cell.is_empty(), "found GSDocMitchellHouse")
	if not cell.is_empty():
		var lighting: Dictionary = reader.get_cell_lighting_data(int(cell["form_id"]))
		check(not lighting.is_empty(), "GSDocMitchellHouse has an XCLL subrecord")
		if not lighting.is_empty():
			var ambient: Color = lighting["ambient_color"]
			print("  ambient_color: ", ambient)
			# Confirmed via a real scratch dump against this exact cell earlier
			# this task: raw XCLL ambient bytes (47, 70, 69, 0).
			check(is_equal_approx(ambient.r, 47.0 / 255.0), "ambient.r matches known real XCLL byte value (47)")
			check(is_equal_approx(ambient.g, 70.0 / 255.0), "ambient.g matches known real XCLL byte value (70)")
			check(is_equal_approx(ambient.b, 69.0 / 255.0), "ambient.b matches known real XCLL byte value (69)")

	_finish()

func _finish() -> void:
	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
