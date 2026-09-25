extends Node

const InventoryComponentScript := preload("res://gamebryo/inventory_component.gd")

var failures := 0

func check(condition: bool, message: String) -> void:
	if condition:
		print("  OK   ", message)
	else:
		print("  FAIL ", message)
		failures += 1

func _ready() -> void:
	var inventory = InventoryComponentScript.new()
	add_child(inventory)
	var first := InventoryEntryResource.new()
	first.item_form_id = 0x100
	first.count = 2
	var second := InventoryEntryResource.new()
	second.item_form_id = 0x100
	second.count = 1
	inventory.set_authored_entries([first, second])
	check(inventory.get_entries().size() == 2, "authored entries retain duplicates and order")
	check(inventory.get_item_count(0x100) == 3, "authored quantities aggregate for queries")
	inventory.add_item(0x100, null, 2)
	check(inventory.get_entries().size() == 3, "runtime addition receives a distinct instance entry")
	check(inventory.get_item_count(0x100) == 5, "runtime quantity is included")
	var runtime_entry: InventoryEntryResource = inventory.get_entries()[2]
	check(inventory.set_equipped(runtime_entry.instance_id, true), "runtime entry can be marked equipped")
	check(runtime_entry.is_equipped, "equipped state is held on the inventory entry")
	var saved := inventory.serialize_state()
	check(int(saved.get("version", 0)) == 1, "save state has an explicit schema version")
	var restored = InventoryComponentScript.new()
	add_child(restored)
	check(restored.restore_state(saved), "save state restores successfully")
	check(restored.get_entries().size() == 3, "save round-trip preserves entry count")
	check(restored.get_item_count(0x100) == 5, "save round-trip preserves quantity")
	check(restored.get_entries()[2].is_equipped, "save round-trip preserves equipped state")
	check(String(restored.get_entries()[0].instance_id) == String(inventory.get_entries()[0].instance_id), "save round-trip preserves instance identity")
	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
