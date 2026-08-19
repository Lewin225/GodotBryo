extends Node3D

# phases/2/07-runtime-cell-loader.md, Step 4. Headless physics test:
# raycast into a real, cell-loader-built DoorNode and confirm it's
# pickup-able and activate()-able exactly the way a player's own
# interaction code would use it.

const DATA_DIR := "/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/"

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func _ready() -> void:
	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened FalloutNV.esm")
	var doc_house: Dictionary = esm.find_cell_by_editor_id("GSDocMitchellHouse")

	var loader := CellLoader.new()
	add_child(loader)
	await get_tree().process_frame

	loader.load_cell(int(doc_house["form_id"]))
	while loader._loading:
		await get_tree().process_frame

	# Find the real GSDocMitchellDoor node the loader actually built (not a
	# synthetic one) inside CurrentCell/RefrRoot.
	var door: DoorNode = null
	var refr_root: Node = loader._current.get_node("RefrRoot")
	for c in refr_root.get_children():
		if c is DoorNode and c.name == "GSDocMitchellDoor":
			door = c
	check(door != null, "found the real GSDocMitchellDoor node built by the loader")
	if door == null:
		get_tree().quit(1)
		return
	check(door.has_destination, "door resolved a real destination at build time")

	# Real raycast, world-space, from outside the door straight through it —
	# no special-casing, exactly what a player's own camera-forward raycast
	# would do.
	await get_tree().physics_frame
	await get_tree().physics_frame
	var door_pos: Vector3 = door.global_position
	var from: Vector3 = door_pos + Vector3(0, 0, 5)
	var to: Vector3 = door_pos + Vector3(0, 0, -5)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	var space_state := get_world_3d().direct_space_state
	var result: Dictionary = space_state.intersect_ray(query)
	check(not result.is_empty(), "raycast toward the door's own position hit something")
	if not result.is_empty():
		print("  raycast hit: ", result.get("collider"))
		check(result["collider"] == door, "raycast collider IS the DoorNode itself -- no extra plumbing needed")

	# activate() -- the actual interaction entry point a caller would call
	# once it's confirmed `hit_collider is DoorNode`.
	var dest: Dictionary = door.activate()
	check(not dest.is_empty(), "activate() returned real destination data")
	check(int(dest.get("dest_cell_form_id", 0)) == door.dest_cell_form_id, "activate()'s dest_cell_form_id matches the door's own resolved data")
	check(dest.get("dest_position", Vector3.ZERO) == door.dest_position, "activate()'s dest_position matches")

	# A non-teleporting door (NVCraftsmanHomeDoor, confirmed earlier this
	# session to have no XTEL) must return {} cleanly, not garbage/crash.
	var non_tele: DoorNode = null
	for c in refr_root.get_children():
		if c is DoorNode and c.name == "NVCraftsmanHomeDoor":
			non_tele = c
	check(non_tele != null, "found the non-teleporting NVCraftsmanHomeDoor")
	if non_tele != null:
		check(not non_tele.has_destination, "non-teleporting door correctly has_destination=false")
		check(non_tele.activate().is_empty(), "activate() on a non-teleporting door returns {} cleanly")

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
