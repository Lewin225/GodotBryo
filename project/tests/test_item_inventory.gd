extends Node

const DATA_DIR := "../fresh_nv_copy/Data/"
var failures := 0
func check(ok: bool, msg: String) -> void:
	print("  OK   " if ok else "  FAIL ", msg)
	if not ok: failures += 1

func first_of_type(esm: EsmReader, cell_editor_id: String, type_tag: String) -> Dictionary:
	var cell := esm.find_cell_by_editor_id(cell_editor_id)
	for placement in esm.get_cell_references(int(cell.get("form_id", 0))):
		if placement.get("base_type", "") == type_tag:
			return placement
	return {}

func check_pickup_drop_shape(registry: GamebryoObjectRegistry, placement: Dictionary, rigid: bool, label: String) -> void:
	var node := registry.build(placement)
	check(node is ItemNode, "%s builds as ItemNode" % label)
	if not node is ItemNode: return
	var picked: Dictionary = node.pickup()
	var data: Dictionary = picked["item_data"]
	check(data.get("full_name", "") != "" and data.has("value") and data.has("weight"), "%s pickup retains name/value/weight" % label)
	var dropped := placement.duplicate()
	dropped["base_type"] = data["base_type"]
	dropped["model"] = data["model_path"]
	var restored := registry.build(dropped)
	check((restored.get_node_or_null("RigidBody3D") is GamebryoRigidBody) == rigid, "%s drop restores %s physics" % [label, "rigid-body" if rigid else "static"])
	node.free()
	if restored != null: restored.free()

func _ready() -> void:
	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened FalloutNV.esm")
	var cell := esm.find_cell_by_editor_id("GSDocMitchellHouse")
	var misc := {}
	for p in esm.get_cell_references(int(cell.get("form_id", 0))):
		if p.get("base_type", "") == "MISC": misc = p; break
	check(not misc.is_empty(), "found a real MISC placement")
	if not misc.is_empty():
		var data := esm.get_item_data(int(misc["base_form_id"]))
		check(not data.is_empty() and float(data["weight"]) > 0.0 and int(data["value"]) >= 0, "MISC DATA yields sane real value and weight")
		var registry := GamebryoObjectRegistry.new(GamebryoMeshResolver.new(), esm)
		check(registry.is_registered("MISC"), "MISC registered for CellLoader path")
		var node := registry.build(misc)
		check(node is ItemNode, "synchronous MISC build produces ItemNode")
		if node is ItemNode:
			check(node.get_node_or_null("RigidBody3D") is GamebryoRigidBody, "ItemNode composes a RigidBody3D")
			var picked: Dictionary = node.pickup()
			var inventory := Inventory.new()
			inventory.add_item(int(picked["base_form_id"]), picked["item_data"])
			check(inventory.get_entries().size() == 1, "pickup data enters plain inventory")
			node.free()
		var ctx := GamebryoResolveContext.new()
		var result := registry.resolve_placement(misc, ctx)
		check(result.get("kind", "") == "item", "MISC resolves as item in WorldStreamer path")
		var key := first_of_type(esm, "RepconHQ01", "KEYM")
		check(not key.is_empty(), "found real REPCON keycard")
		if not key.is_empty(): check_pickup_drop_shape(registry, key, false, "KEYM")
		var alch := first_of_type(esm, "GSDocMitchellHouse", "ALCH")
		check(not alch.is_empty(), "found real ALCH placement")
		if not alch.is_empty(): check_pickup_drop_shape(registry, alch, true, "ALCH")
	_finish()

func _finish() -> void:
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
