extends Node

## World items: a placed item reference in Doc Mitchell's house taken into the
## player's inventory and placed again. Taking it sets its holder, clears its
## space and cell and reports the cell change; its world location is the
## player's; the holder survives a write and read of its saved fields; placing
## it again clears the holder. A stack of three dropped by the player becomes
## three runtime references placed in the player's cell, and the stack is gone.

var failures := 0

func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var item := _first_item_in("GSDocMitchellHouse")
	check(item != null, "Doc Mitchell's house has a placed item reference")
	if item == null:
		get_tree().quit(1)
		return
	var player := EsmServer.get_player_reference()
	var space := item.current_space_form_id
	var cell := item.current_cell_form_id
	var position := item.position
	check(cell != 0 and item.world_location() == item, "a placed item is in a cell and is its own world location")

	var changes: Array = []
	var record_change := func(reference: EsmReference, old_cell: int, new_cell: int) -> void:
		if reference == item:
			changes.append([old_cell, new_cell])
	EsmServer.reference_cell_changed.connect(record_change)
	item.set_holder(player)
	check(item.current_space_form_id == 0 and item.current_cell_form_id == 0, "a held item has no space and no cell")
	check(changes == [[cell, 0]], "taking it reports its cell changing to 0 (%s)" % [changes])
	check(item.get_holder() == player, "its holder is the player")
	check(item.world_location() == player, "its world location is the player")
	check(item.dirty, "taking it marks it dirty")

	var data := SaveFields.write(item, ["instance_id", "base_form_id"])
	var copy := (item.get_script() as Script).new() as EsmReference
	SaveFields.read(copy, JSON.parse_string(JSON.stringify(data)))
	check(copy.holder_instance_id == player.instance_id, "the holder reads back from its saved fields")

	changes.clear()
	item.set_location(space, position)
	check(item.holder_instance_id.is_empty() and item.get_holder() == null, "placing it again clears the holder")
	check(item.current_cell_form_id == cell and changes == [[0, cell]], "and reports its cell changing back")
	EsmServer.reference_cell_changed.disconnect(record_change)

	player.set_location(space, position)
	var stimpak := EsmServer.find_base_by_editor_id("Stimpak")
	var stack := InventoryItem.make_stack(stimpak, 3)
	player.contents.add_inventory_item(stack)
	var dropped := player.drop_entry(stack)
	check(dropped == 3 and not player.contents.get_items().has(stack), "dropping a stack of 3 drops 3 and removes the stack")
	var runtime := EsmServer.get_references_in_cell(cell).filter(func(reference: EsmReference) -> bool:
		return String(reference.instance_id).begins_with("runtime:") and reference.base_form_id == stimpak.form_id)
	check(runtime.size() == 3, "each unit is a runtime reference in the player's cell (%d)" % runtime.size())

	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(1 if failures > 0 else 0)


## The first placed MISC reference in the interior CELL `editor_id`.
func _first_item_in(editor_id: String) -> EsmReference:
	var cell_form_id := EsmServer.find_form_id_by_editor_id(editor_id)
	for reference in EsmServer.get_references_in_cell(cell_form_id):
		if reference is MiscReference:
			return reference
	return null
