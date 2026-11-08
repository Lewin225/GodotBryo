extends Node3D

## Weapon slots through a save and load. Doc Mitchell equips the 10mm pistol
## from a stack (a runtime reference) and picks up and equips a placed weapon
## REFR (a placed reference); the pistol is loaded, jammed and drawn. EsmServer
## saves, the save goes through JSON text, EsmServer is cleared and loads it.
## The loaded Doc's slots resolve to the weapon references with their state,
## held by him and out of his inventory; his rebuilt body hangs them; saving
## again gives the same save.

const PISTOL := "Weap10mmPistol"
const FRAMES := 900

var failures := 0


func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1


func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var doc := EsmServer.find_reference_by_editor_id("DocMitchellREF") as ActorReference
	var pistol_base := EsmServer.find_base_by_editor_id(PISTOL) as WeaponBase

	ScriptServer.run_debug_line("DocMitchellREF.EquipItem %s" % PISTOL)
	var pistol := doc.weapon_right_hip
	check(pistol != null and String(pistol.instance_id).begins_with("runtime:"), "the 10mm from a stack is a runtime reference (%s)" % (pistol.instance_id if pistol != null else "none"))
	pistol.loaded_ammo_count = 7
	pistol.is_jammed = true
	doc.draw_weapon(ActorReference.WeaponSlot.RIGHT_HIP)

	var placed := _placed_long_gun()
	check(placed != null, "a placed long gun REFR exists (%s)" % (placed.base.editor_id if placed != null else "none"))
	if placed == null:
		_finish()
		return
	check(doc.pick_up(placed), "Doc picks it up")
	var placed_entry: InventoryItem = null
	for entry in doc.contents.get_items():
		if entry.item_reference == placed:
			placed_entry = entry
	doc.contents.equip_item(placed_entry)
	check(doc.weapon_back == placed, "and equips it on his back")
	var pistol_id := String(pistol.instance_id)
	var placed_id := String(placed.instance_id)
	var pistols_in_inventory := doc.contents.get_item_count(pistol_base.form_id)

	var text := JSON.stringify(EsmServer.save_state(), "\t", true)
	var parsed: Dictionary = JSON.parse_string(text)
	var doc_entry: Dictionary = parsed["references"].get(String(doc.instance_id), {})
	check(str(doc_entry.get("weapon_right_hip", "")) == pistol_id and str(doc_entry.get("weapon_back", "")) == placed_id,
			"Doc's saved entry names his slots' weapons by instance_id")
	check((parsed["runtime"]["references"] as Dictionary).has(pistol_id), "the runtime pistol is saved in the runtime references")
	check((parsed["references"] as Dictionary).has(placed_id), "the placed weapon is saved in the references")

	EsmServer.clear_game_state()
	EsmServer.load_state(parsed)
	var loaded_doc := EsmServer.find_reference_by_editor_id("DocMitchellREF") as ActorReference
	check(loaded_doc != null and loaded_doc != doc, "Doc loads as a new reference")
	var loaded_pistol := loaded_doc.weapon_right_hip
	var loaded_placed := loaded_doc.weapon_back
	check(loaded_pistol is WeaponReference and String(loaded_pistol.instance_id) == pistol_id, "his right hip slot resolves to the pistol's reference")
	check(loaded_pistol != null and loaded_pistol.base == pistol_base, "with its base")
	check(loaded_pistol != null and loaded_pistol.loaded_ammo_count == 7 and loaded_pistol.is_jammed, "with its state: 7 loaded, jammed")
	check(loaded_placed is WeaponReference and String(loaded_placed.instance_id) == placed_id, "his back slot resolves to the placed weapon's reference")
	check(loaded_pistol != null and loaded_pistol.get_holder() == loaded_doc and loaded_placed != null and loaded_placed.get_holder() == loaded_doc,
			"both weapons are held by the loaded Doc")
	check(loaded_doc.drawn_weapon_slot == ActorReference.WeaponSlot.RIGHT_HIP and loaded_doc.last_drawn_weapon_slot == ActorReference.WeaponSlot.BACK,
			"the drawn and last drawn slots load")
	check(loaded_doc.contents.get_item_count(pistol_base.form_id) == pistols_in_inventory, "his inventory holds no extra pistol")
	check(EsmServer.get_reference(StringName(pistol_id)) == loaded_pistol, "EsmServer's reference for the id is the slot's")

	var difference := SaveCompare.first_difference(parsed, JSON.parse_string(JSON.stringify(EsmServer.save_state(), "\t", true)))
	check(difference.is_empty(), "saving after the load gives the same save (%s)" % difference)

	var controller := EsmReferencePhysicaliser.new().physicalise(loaded_doc, self) as NpcController
	await _wait_until(func() -> bool: return controller.actor != null and controller.actor.find_child("Skeleton3D", true, false) != null)
	var slots := controller.actor.weapon_slots
	var pistol_node := await _node_of(slots, loaded_pistol)
	var placed_node := await _node_of(slots, loaded_placed)
	check(_bone_of(pistol_node) == "Weapon", "the rebuilt body holds the drawn pistol on the Weapon bone (%s)" % _bone_of(pistol_node))
	check(_bone_of(placed_node) == "Bip01 Spine2", "and the long gun on its back (%s)" % _bone_of(placed_node))
	_finish()


## A placed REFR of a WEAP that holsters on the back.
func _placed_long_gun() -> WeaponReference:
	for row: Dictionary in EsmServer.get_record_index():
		if String(row.get("record_type", "")) != "REFR":
			continue
		var reference := EsmServer.get_reference_by_form_id(int(row.get("form_id", 0))) as WeaponReference
		if reference == null or reference.base == null or reference.get_holder() != null:
			continue
		if (reference.base as WeaponBase).holsters_on_back():
			return reference
	return null


func _node_of(slots: ActorWeaponSlots, weapon: WeaponReference) -> EsmWeaponNode:
	for frame in FRAMES:
		var node := slots.get_weapon_node(weapon)
		if node != null and node.get_parent() != null:
			return node
		await get_tree().process_frame
	return null


func _bone_of(node: Node) -> String:
	if node == null or not node.get_parent() is BoneAttachment3D:
		return ""
	return (node.get_parent() as BoneAttachment3D).bone_name


func _wait_until(condition: Callable) -> void:
	for frame in FRAMES:
		if condition.call():
			return
		await get_tree().process_frame


func _finish() -> void:
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
