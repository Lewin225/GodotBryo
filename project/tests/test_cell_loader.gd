extends Node3D

# 2.7 Step 2 — Runtime Cell Loader. See phases/2/07-runtime-cell-loader.md.
# Headless functional test: load an interior cell, swap to an exterior
# cell, swap back to a second interior cell (proving the old-cell-freed-
# immediately swap doesn't leave stale/renamed nodes), then test
# cancel_load() mid-stream.

const DATA_DIR := "/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/"

var failures := 0
var _progress_events := 0
var _completed_events: Array = []

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func _on_progress(_fraction: float) -> void:
	_progress_events += 1

func _on_completed(cell_form_id: int, success: bool) -> void:
	_completed_events.append([cell_form_id, success])

func await_load(loader: CellLoader, cell_form_id: int) -> void:
	_completed_events.clear()
	loader.load_cell(cell_form_id)
	while loader._loading:
		await get_tree().process_frame

func _ready() -> void:
	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened FalloutNV.esm")

	var loader := CellLoader.new()
	add_child(loader)
	loader.load_progress.connect(_on_progress)
	loader.load_completed.connect(_on_completed)
	await get_tree().process_frame # let loader's own _ready() run (opens its ESM)

	var doc_house: Dictionary = esm.find_cell_by_editor_id("GSDocMitchellHouse")
	var wrld: Dictionary = esm.find_worldspace_by_editor_id("WastelandNV")
	var goodsprings: Dictionary = esm.find_exterior_cell(int(wrld["form_id"]), -17, 0)
	var ranch_house: Dictionary = esm.find_cell_by_editor_id("RanchHouseInterior03")

	print("=== load 1: interior (GSDocMitchellHouse) ===")
	await await_load(loader, int(doc_house["form_id"]))
	check(_completed_events.size() == 1 and _completed_events[0][1] == true, "load completed successfully")
	check(_progress_events > 1, "streamed across multiple frames (%d progress events)" % _progress_events)
	check(loader._current != null, "CurrentCell exists")
	check(loader._current.name == "CurrentCell", "root is named CurrentCell after swap")
	var refr_root_1: Node = loader._current.get_node("RefrRoot")
	check(refr_root_1.get_child_count() > 200, "interior cell placed a real number of objects (%d)" % refr_root_1.get_child_count())
	var first_current := loader._current

	print("=== load 2: exterior (Goodsprings -17,0), swapping out the interior ===")
	_progress_events = 0
	await await_load(loader, int(goodsprings["form_id"]))
	check(_completed_events.size() == 1 and _completed_events[0][1] == true, "load completed successfully")
	check(loader._current != first_current, "CurrentCell is a new node, not the old interior root")
	check(not is_instance_valid(first_current) or first_current.get_parent() == null, "old interior root was actually freed, not just hidden")
	var terrain_root: Node = loader._current.get_node("TerrainRoot")
	check(terrain_root.get_child_count() > 0, "exterior cell built terrain (%d terrain children)" % terrain_root.get_child_count())
	var refr_root_2: Node = loader._current.get_node("RefrRoot")
	check(refr_root_2.get_child_count() > 50, "exterior cell placed real objects (%d)" % refr_root_2.get_child_count())
	# Node-name collision check (the exact bug class already found once this
	# session): confirm the live root is genuinely "CurrentCell", not a
	# Godot-mangled "CurrentCell2".
	check(loader.get_node("CurrentCell") == loader._current, "get_node(\"CurrentCell\") resolves cleanly, no name collision")
	var second_current := loader._current

	print("=== load 3: a second interior (RanchHouseInterior03), swapping out the exterior ===")
	await await_load(loader, int(ranch_house["form_id"]))
	check(_completed_events.size() == 1 and _completed_events[0][1] == true, "load completed successfully")
	check(loader._current != second_current, "CurrentCell is a new node again")
	check(loader.get_node("CurrentCell") == loader._current, "get_node(\"CurrentCell\") still resolves cleanly after a second swap")

	print("=== cancel mid-load ===")
	_completed_events.clear()
	loader.load_cell(int(goodsprings["form_id"]))
	for i in range(3):
		await get_tree().process_frame
	check(loader._loading, "load is still in flight after 3 frames (streaming confirmed)")
	var current_before_cancel := loader._current
	loader.cancel_load()
	check(not loader._loading, "cancel_load stopped the coroutine")
	check(loader._current == current_before_cancel, "CurrentCell (RanchHouseInterior03) untouched by the cancelled load")
	check(_completed_events.is_empty(), "cancelled load never fired load_completed")

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
