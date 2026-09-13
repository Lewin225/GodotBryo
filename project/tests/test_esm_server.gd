extends Node

var failures := 0

func _ready() -> void:
	var server = get_node("/root/EsmServer")
	if not server.is_ready():
		await server.esm_ready
	var base: EsmBase = server.get_base(0x000E3778)
	_check(base != null, "known WEAP resolves")
	_check(base is WeaponBase, "known WEAP resolves as WeaponBase")
	if base is WeaponBase:
		_check(not base.editor_id.is_empty(), "Base exposes EditorID")
		_check(not (base as WeaponBase).model_path.is_empty(), "WeaponBase has model path")
		_check((base as WeaponBase).base_damage > 0, "WeaponBase has damage")
	_check(server.get_base(0x000E3778) == base, "Base cache returns same Resource")
	_check(server.get_base_type(0x000E3778) == WeaponBase, "Base type lookup returns WeaponBase")
	var base_reference: EsmReference = server.create_reference_for_base(0x000E3778)
	_check(base_reference is WeaponReference, "Base resource creates a typed WeaponReference")
	_check(base_reference != null and server.get_reference(base_reference.instance_id).base == base, "synthetic Base reference rehydrates through EsmServer")
	await _check_packed_base_reference(server, base_reference)
	var index: Array = server.get_record_index()
	_check(not index.is_empty(), "EsmServer exposes record index")
	var ccrd_count := 0
	var cmny_count := 0
	for row in index:
		if String(row.get("record_type", "")) == "CCRD": ccrd_count += 1
		if String(row.get("record_type", "")) == "CMNY": cmny_count += 1
	_check(ccrd_count > 0, "record index exposes base-game CCRD records")
	_check(cmny_count > 0, "record index exposes base-game CMNY records")
	var found_actor := false
	for row in index:
		if String(row.get("record_type", "")) != "ACHR": continue
		var raw: Dictionary = server.reader.get_record_data(int(row.get("form_id", 0)))
		var name := _u32(_subrecord(raw, "NAME"))
		if name == 0: continue
		var reference: EsmReference = server.get_reference("authored:%08X" % int(row.get("form_id", 0)))
		if reference is ActorReference:
			found_actor = true
			var actor_host := Node3D.new()
			add_child(actor_host)
			var actor_node := await EsmReferencePhysicaliser.new().physicalise(reference, actor_host)
			_check(actor_node is EsmNpcActor, "NPC ActorReference physicalises as EsmNpcActor")
			for _frame in 60:
				if actor_node != null and actor_node.get_node_or_null("Body") != null: break
				await get_tree().process_frame
			_check(actor_node != null and actor_node.get_node_or_null("Body") != null, "EsmNpcActor builds its generated Body")
			if actor_host != null: actor_host.free()
			var actor_base := reference.base as NpcBase
			_check(reference.contents is Inventory, "ActorReference owns a typed Inventory")
			if reference.contents is Inventory:
				for item in (reference.contents as Inventory).get_items():
					_check(item is InventoryItem and item.item_reference is EsmReference, "Actor inventory contains InventoryItem-wrapped references")
					break
			_check(actor_base != null and actor_base.race != null, "NPC Base resolves typed Race Base")
			_check(actor_base == null or actor_base.race == server.get_base(actor_base.race_form_id), "NPC Race Base is the shared cached instance")
			if actor_base != null and actor_base.race != null:
				var race := actor_base.race
				_check(not race.head_parts(false).is_empty() and not race.body_parts(false).is_empty(), "Race Base exposes male head and body parts")
				_check(not race.head_parts(true).is_empty() and not race.body_parts(true).is_empty(), "Race Base exposes female head and body parts")
				_check(race.head_parts(false)[0].part_type == "head", "RACE head INDX uses the documented role")
				_check(race.body_parts(false)[0].part_type == "upper_body", "RACE body INDX uses the documented role")
				_check(race.hairs.size() == race.hair_form_ids.size(), "RACE HNAM formid array resolves typed Hair Bases")
				_check(race.eyes.size() == race.eyes_form_ids.size(), "RACE ENAM formid array resolves typed Eyes Bases")
			_check(actor_base == null or actor_base.hair_form_id == 0 or actor_base.hair != null, "NPC Base resolves Hair Base when HNAM is present")
			_check(actor_base == null or actor_base.eyes_form_id == 0 or actor_base.eyes != null, "NPC Base resolves Eyes Base when ENAM is present")
			_check(actor_base == null or actor_base.class_form_id == 0 or actor_base.actor_class != null, "NPC Base resolves Class Base when CNAM is present")
			_check(actor_base == null or actor_base.packages.size() == _count_pkid(server.reader.get_record_data(actor_base.form_id)), "NPC Base resolves every Package Base")
			break
	_check(found_actor, "an ACHR resolves as ActorReference")
	_check_typed_container_inventory(server, index)
	_check_inventory_contract(server)
	_check_armor_slot_conflicts()
	await _check_door_resources(server, index)
	await _check_item_resources(server, index)
	await _check_static_resource(server, index)
	await _check_interactive_resources(server, index)
	await _check_collection_and_movable_resources(server, index)
	await _check_talking_activator_and_terminal_resources(server, index)
	await _check_dropped_item_resources(server, index)
	await _check_leveled_item_resources(server, index)
	_check(server.get_reference("runtime:000E3778:1") == null, "runtime ID is deferred")
	_check(server.get_reference("not-an-id") == null, "malformed ID returns null")
	await _check_saved_base_rehydrates(server)
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)

func _check_typed_container_inventory(server, index: Array) -> void:
	for row in index:
		if String(row.get("record_type", "")) != "REFR":
			continue
		var reference: EsmReference = server.get_reference("authored:%08X" % int(row.get("form_id", 0)))
		if reference is not ContainerReference:
			continue
		_check(reference.contents is Inventory, "ContainerReference owns a typed Inventory")
		if reference.contents is Inventory:
			for item in (reference.contents as Inventory).get_items():
				_check(item is InventoryItem and item.item_reference is EsmReference, "Container inventory contains InventoryItem-wrapped references")
				break
		return
	_check(false, "a real container reference is available for typed inventory validation")

func _check_inventory_contract(server) -> void:
	var inventory := Inventory.new()
	var item_reference: EsmReference = server.create_inventory_item_reference(0x000E3778, "test-weapon")
	var item := InventoryItem.new()
	item.item_reference = item_reference
	item.count = 2
	item.instance_id = "test-item"
	_check(inventory.add_inventory_item(item), "Inventory accepts a typed InventoryItem")
	_check(inventory.get_item_count(0x000E3778) == 2, "Inventory counts wrapped typed items")
	_check(inventory.set_equipped("test-item", true), "Inventory stores equipped state on InventoryItem")
	_check(inventory.get_equipped_items().size() == 1, "Inventory returns equipped InventoryItems")
	var saved := inventory.serialize_state()
	var restored := Inventory.new()
	var factory := func(form_id: int, instance_id: String) -> EsmReference:
		return server.create_inventory_item_reference(form_id, instance_id)
	_check(restored.restore_state(saved, factory), "Inventory restores typed item state")
	_check(restored.get_item_count(0x000E3778) == 2, "Inventory restore preserves count")
	_check(restored.get_equipped_items().size() == 1, "Inventory restore preserves equipped state")

func _check_armor_slot_conflicts() -> void:
	var first_base := ArmorBase.new()
	first_base.form_id = 0x1001
	first_base.biped_flags = 0x01
	var second_base := ArmorBase.new()
	second_base.form_id = 0x1002
	second_base.biped_flags = 0x01
	var legs_base := ArmorBase.new()
	legs_base.form_id = 0x1003
	legs_base.biped_flags = 0x02
	var first_ref := ArmorReference.new()
	first_ref.base_form_id = first_base.form_id
	first_ref.base = first_base
	var second_ref := ArmorReference.new()
	second_ref.base_form_id = second_base.form_id
	second_ref.base = second_base
	var legs_ref := ArmorReference.new()
	legs_ref.base_form_id = legs_base.form_id
	legs_ref.base = legs_base
	var inventory := Inventory.new()
	var first := InventoryItem.new()
	first.item_reference = first_ref
	first.instance_id = "first"
	var second := InventoryItem.new()
	second.item_reference = second_ref
	second.instance_id = "second"
	var legs := InventoryItem.new()
	legs.item_reference = legs_ref
	legs.instance_id = "legs"
	inventory.add_inventory_item(first)
	inventory.add_inventory_item(second)
	inventory.add_inventory_item(legs)
	inventory.equip_item(first)
	inventory.equip_item(legs)
	inventory.equip_item(second)
	_check(not first.is_equipped and second.is_equipped, "overlapping BMDT armor replaces the equipped item")
	_check(legs.is_equipped, "non-overlapping BMDT armor remains equipped")

func _check_door_resources(server, index: Array) -> void:
	var found_door_base := false
	for row in index:
		if String(row.get("record_type", "")) != "DOOR": continue
		var door: EsmBase = server.get_base(int(row.get("form_id", 0)))
		if door is DoorBase:
			found_door_base = true
			_check(not door.editor_id.is_empty(), "DoorBase exposes EditorID")
			_check(door.script_form_id >= 0, "DoorBase exposes script FormID")
			_check(door.flags >= 0, "DoorBase exposes documented flags")
			break
	_check(found_door_base, "a real DOOR resolves as DoorBase")

	var found_door_reference := false
	for row in index:
		var refr_type := String(row.get("record_type", ""))
		if refr_type != "REFR" and refr_type != "ACHR": continue
		var refr_raw: Dictionary = server.reader.get_record_data(int(row.get("form_id", 0)))
		var base_id := _u32(_subrecord(refr_raw, "NAME"))
		var base_raw: Dictionary = server.reader.get_record_data(base_id)
		if String(base_raw.get("record_type", "")) != "DOOR": continue
		var reference: EsmReference = server.get_reference("authored:%08X" % int(row.get("form_id", 0)))
		if reference is DoorReference:
			found_door_reference = true
			_check(reference.base is DoorBase, "DoorReference points to DoorBase")
			_check(reference.lock_key_form_id == 0 or reference.lock_key != null, "DoorReference resolves its lock key Base")
			_check(reference.teleport_destination_refr_form_id == 0 or reference.has_teleport_destination, "DoorReference XTEL state is consistent")
			var physicaliser := EsmReferencePhysicaliser.new()
			var node: EsmNode = await physicaliser.physicalise(reference)
			_check(node.get_child_count() > 0, "Door physicalizer builds visual children")
			_check(node.get_node_or_null("AnimationPlayer") != null, "Door physicalizer builds AnimationPlayer")
			break
	_check(found_door_reference, "a real DOOR placement resolves as DoorReference")
	_check_misc_physicaliser(server)

func _check_misc_physicaliser(server) -> void:
	var cell: Dictionary = server.reader.find_cell_by_editor_id("GSDocMitchellHouse")
	var placement: Dictionary = {}
	for candidate in server.reader.get_cell_references(int(cell.get("form_id", 0))):
		if String(candidate.get("base_type", "")) == "MISC":
			placement = candidate
			break
	_check(not placement.is_empty(), "a real MISC placement is available for physicalisation")
	if placement.is_empty():
		return
	var reference: EsmReference = server.get_reference("authored:%08X" % int(placement.get("refr_form_id", 0)))
	_check(reference is MiscReference, "MISC placement resolves as MiscReference")
	if not reference is MiscReference:
		return
	_check(reference.base is MiscBase, "MiscReference points to MiscBase")
	var node := await EsmReferencePhysicaliser.new().physicalise(reference)
	_check(node is EsmItemNode, "MISC physicalises as EsmItemNode")
	var body := node.get_node_or_null("RigidBody3D")
	_check(body is GamebryoRigidBody, "MISC uses authored rigid-body construction")
	var has_collision := false
	for child in body.get_children() if body is Node else []:
		if child is CollisionShape3D:
			has_collision = true
			break
	_check(has_collision, "MISC rigid body receives collision shapes")
	_check(not node is ItemNode, "MISC resource path does not construct legacy ItemNode")
	node.free()

func _check_packed_base_reference(server, source_reference: EsmReference) -> void:
	var scene_root := Node3D.new()
	var item := EsmItemNode.new()
	item.configure(source_reference)
	scene_root.add_child(item)
	item.owner = scene_root
	var packed := PackedScene.new()
	_check(packed.pack(scene_root) == OK, "synthetic Base reference packs into a scene")
	var instance := packed.instantiate()
	get_tree().root.add_child(instance)
	await get_tree().process_frame
	var loaded_item := instance.get_child(0) as EsmItemNode
	_check(loaded_item != null and loaded_item.reference != null, "packed EsmItemNode restores its reference slot")
	_check(loaded_item != null and loaded_item.reference.base == server.get_base(source_reference.base_form_id), "packed Base reference rehydrates its shared Base")
	instance.queue_free()
	scene_root.free()

func _check_item_resources(server, index: Array) -> void:
	var expected := {
		"ALCH": AlchemyBase,
		"AMMO": AmmoBase,
		"KEYM": KeyBase,
		"WEAP": WeaponBase,
	}
	for type_tag in expected:
		var found_base := false
		for row in index:
			if String(row.get("record_type", "")) != type_tag:
				continue
			var base: EsmBase = server.get_base(int(row.get("form_id", 0)))
			if base == null:
				continue
			found_base = true
			_check(base.get_script() == expected[type_tag], "%s resolves as its typed Base" % type_tag)
			_check(base.get("model_path") != null, "%s exposes model_path" % type_tag)
			_check(base.get("value") != null and base.get("weight") != null, "%s exposes common item data" % type_tag)
			break
		_check(found_base, "a real %s Base is available" % type_tag)

		var found_reference := false
		for row in index:
			var refr_type := String(row.get("record_type", ""))
			if refr_type != "REFR" and refr_type != "ACHR":
				continue
			var refr_raw: Dictionary = server.reader.get_record_data(int(row.get("form_id", 0)))
			var base_id := _u32(_subrecord(refr_raw, "NAME"))
			var base_raw: Dictionary = server.reader.get_record_data(base_id)
			if String(base_raw.get("record_type", "")) != type_tag:
				continue
			var reference: EsmReference = server.get_reference("authored:%08X" % int(row.get("form_id", 0)))
			if reference == null:
				continue
			found_reference = true
			var node := await EsmReferencePhysicaliser.new().physicalise(reference)
			_check(node is EsmItemNode, "%s physicalises as EsmItemNode" % type_tag)
			_check(node is EsmItemNode and (node as EsmItemNode).reference == reference, "%s EsmItemNode retains its typed reference" % type_tag)
			_check(node.get_node_or_null("RigidBody3D") is GamebryoRigidBody or node.get_child_count() == 0, "%s uses the shared item construction path" % type_tag)
			node.free()
			break
		_check(found_reference, "a real %s reference is available" % type_tag)

func _check_static_resource(server, index: Array) -> void:
	var found_base := false
	for row in index:
		if String(row.get("record_type", "")) != "STAT":
			continue
		var base: EsmBase = server.get_base(int(row.get("form_id", 0)))
		if base is StaticBase:
			found_base = true
			_check(not (base as StaticBase).model_path.is_empty(), "STAT Base exposes model path")
			break
	_check(found_base, "a real STAT Base is available")

	var found_reference := false
	for row in index:
		var refr_type := String(row.get("record_type", ""))
		if refr_type != "REFR" and refr_type != "ACHR":
			continue
		var refr_raw: Dictionary = server.reader.get_record_data(int(row.get("form_id", 0)))
		var base_id := _u32(_subrecord(refr_raw, "NAME"))
		var base_raw: Dictionary = server.reader.get_record_data(base_id)
		if String(base_raw.get("record_type", "")) != "STAT":
			continue
		var reference: EsmReference = server.get_reference("authored:%08X" % int(row.get("form_id", 0)))
		if reference == null:
			continue
		found_reference = true
		var node := await EsmReferencePhysicaliser.new().physicalise(reference)
		_check(node is EsmStaticNode, "STAT physicalises as EsmStaticNode")
		_check(node.get_node_or_null("CollisionBody") is GamebryoCollisionBody or node.get_child_count() > 0, "STAT uses individual static construction")
		node.free()
		break
	_check(found_reference, "a real STAT reference is available")

func _check_interactive_resources(server, index: Array) -> void:
	var expected_bases := {"ACTI": ActivatorBase, "CONT": ContainerBase, "FURN": FurnitureBase}
	var expected_refs := {"ACTI": ActivatorReference, "CONT": ContainerReference, "FURN": FurnitureReference}
	var expected_nodes := {"ACTI": EsmActivatorNode, "CONT": EsmContainerNode, "FURN": EsmFurnitureNode}
	for tag in expected_bases:
		var found_base := false
		for row in index:
			if String(row.get("record_type", "")) != tag: continue
			var base: EsmBase = server.get_base(int(row.get("form_id", 0)))
			if base == null: continue
			found_base = true
			_check(base.get_script() == expected_bases[tag], "%s resolves as typed Base" % tag)
			break
		_check(found_base, "a real %s Base is available" % tag)

		var found_reference := false
		for row in index:
			var refr_type := String(row.get("record_type", ""))
			if refr_type != "REFR" and refr_type != "ACHR": continue
			var raw: Dictionary = server.reader.get_record_data(int(row.get("form_id", 0)))
			var base_id := _u32(_subrecord(raw, "NAME"))
			var base_raw: Dictionary = server.reader.get_record_data(base_id)
			if String(base_raw.get("record_type", "")) != tag: continue
			var reference: EsmReference = server.get_reference("authored:%08X" % int(row.get("form_id", 0)))
			if reference == null: continue
			found_reference = true
			_check(reference.get_script() == expected_refs[tag], "%s resolves as typed Reference" % tag)
			var node := await EsmReferencePhysicaliser.new().physicalise(reference)
			_check(node.get_script() == expected_nodes[tag], "%s physicalises as typed EsmNode" % tag)
			if tag == "CONT":
				_check(reference is ContainerReference and (reference as ContainerReference).contents is Inventory, "CONT reference owns typed Inventory")
			node.free()
			break
		_check(found_reference, "a real %s reference is available" % tag)

func _check_collection_and_movable_resources(server, index: Array) -> void:
	var expected := {
		"SCOL": {"base": StaticCollectionBase, "reference": StaticCollectionReference, "node": EsmStaticCollectionNode},
		"MSTT": {"base": MovableStaticBase, "reference": MovableStaticReference, "node": EsmMovableStaticNode},
	}
	for tag in expected:
		var found_base := false
		for row in index:
			if String(row.get("record_type", "")) != tag: continue
			var base: EsmBase = server.get_base(int(row.get("form_id", 0)))
			if base == null: continue
			found_base = true
			_check(base.get_script() == expected[tag]["base"], "%s resolves as typed Base" % tag)
			break
		_check(found_base, "a real %s Base is available" % tag)

		var found_reference := false
		for row in index:
			var refr_type := String(row.get("record_type", ""))
			if refr_type != "REFR" and refr_type != "ACHR": continue
			var raw: Dictionary = server.reader.get_record_data(int(row.get("form_id", 0)))
			var base_id := _u32(_subrecord(raw, "NAME"))
			var base_raw: Dictionary = server.reader.get_record_data(base_id)
			if String(base_raw.get("record_type", "")) != tag: continue
			var reference: EsmReference = server.get_reference("authored:%08X" % int(row.get("form_id", 0)))
			if reference == null: continue
			found_reference = true
			_check(reference.get_script() == expected[tag]["reference"], "%s resolves as typed Reference" % tag)
			var node := await EsmReferencePhysicaliser.new().physicalise(reference)
			_check(node.get_script() == expected[tag]["node"], "%s physicalises as typed Node" % tag)
			if tag == "SCOL":
				_check((node as EsmStaticCollectionNode).is_batch_candidate, "SCOL exposes future batch-candidate metadata")
				_check(node.get_child_count() > 0, "SCOL expands into part nodes")
			else:
				_check((reference as MovableStaticReference).emittance_form_id >= 0, "MSTT preserves emittance identity")
			node.free()
			break
		_check(found_reference, "a real %s reference is available" % tag)

func _check_talking_activator_and_terminal_resources(server, index: Array) -> void:
	var expected := {
		"TACT": {"base": TalkingActivatorBase, "reference": TalkingActivatorReference, "node_script": "res://GodotBryo/Types/Node/esm_talking_activator_node.gd"},
		"TERM": {"base": TerminalBase, "reference": TerminalReference, "node_script": "res://GodotBryo/Types/Node/esm_terminal_node.gd"},
	}
	for tag in expected:
		var found_base := false
		for row in index:
			if String(row.get("record_type", "")) != tag: continue
			var base: EsmBase = server.get_base(int(row.get("form_id", 0)))
			if base == null: continue
			found_base = true
			_check(base.get_script() == expected[tag]["base"], "%s resolves as typed Base" % tag)
			if tag == "TACT":
				_check(not (base as TalkingActivatorBase).model_path.is_empty() or (base as TalkingActivatorBase).sound_form_id >= 0, "TACT exposes verified model/sound fields")
			else:
				var terminal := base as TerminalBase
				_check(terminal.welcome_text is String and terminal.menu_items is Array, "TERM exposes welcome text and ordered menu data")
				if not terminal.menu_items.is_empty():
					_check(terminal.menu_items[0] is TerminalMenuItem, "TERM menu entries use the typed convenience resource")
			break
		_check(found_base, "a real %s Base is available" % tag)

		var found_reference := false
		for row in index:
			var refr_type := String(row.get("record_type", ""))
			if refr_type != "REFR" and refr_type != "ACHR": continue
			var raw: Dictionary = server.reader.get_record_data(int(row.get("form_id", 0)))
			var base_id := _u32(_subrecord(raw, "NAME"))
			var base_raw: Dictionary = server.reader.get_record_data(base_id)
			if String(base_raw.get("record_type", "")) != tag: continue
			var reference: EsmReference = server.get_reference("authored:%08X" % int(row.get("form_id", 0)))
			if reference == null: continue
			found_reference = true
			_check(reference.get_script() == expected[tag]["reference"], "%s resolves as typed Reference" % tag)
			var node := await EsmReferencePhysicaliser.new().physicalise(reference)
			_check(node.get_script() == load(expected[tag]["node_script"]), "%s physicalises as dedicated EsmNode" % tag)
			node.free()
			break
		_check(found_reference, "a real %s reference is available" % tag)

func _check_dropped_item_resources(server, index: Array) -> void:
	var expected := {
		"ARMO": {"base": ArmorBase, "reference": ArmorReference},
		"BOOK": {"base": BookBase, "reference": BookReference},
	}
	for tag in expected:
		var found_base := false
		for row in index:
			if String(row.get("record_type", "")) != tag: continue
			var base: EsmBase = server.get_base(int(row.get("form_id", 0)))
			if base == null: continue
			found_base = true
			_check(base.get_script() == expected[tag]["base"], "%s resolves as typed dropped-item Base" % tag)
			_check(base.get("model_path") != null, "%s exposes dropped-item model path" % tag)
			break
		_check(found_base, "a real %s Base is available" % tag)

		var found_reference := false
		for row in index:
			var refr_type := String(row.get("record_type", ""))
			if refr_type != "REFR" and refr_type != "ACHR": continue
			var raw: Dictionary = server.reader.get_record_data(int(row.get("form_id", 0)))
			var base_id := _u32(_subrecord(raw, "NAME"))
			var base_raw: Dictionary = server.reader.get_record_data(base_id)
			if String(base_raw.get("record_type", "")) != tag: continue
			var reference: EsmReference = server.get_reference("authored:%08X" % int(row.get("form_id", 0)))
			if reference == null: continue
			found_reference = true
			_check(reference.get_script() == expected[tag]["reference"], "%s resolves as typed dropped-item Reference" % tag)
			var node := await EsmReferencePhysicaliser.new().physicalise(reference)
			_check(node is EsmItemNode, "%s physicalises as EsmItemNode" % tag)
			node.free()
			break
		_check(found_reference, "a real %s reference is available" % tag)

func _check_leveled_item_resources(server, index: Array) -> void:
	var found := false
	for row in index:
		if String(row.get("record_type", "")) != "LVLI":
			continue
		var list: EsmBase = server.get_base(int(row.get("form_id", 0)))
		if not list is LeveledItemBase:
			continue
		found = true
		_check(list.entries.size() > 0, "LVLI exposes typed entries")
		if not list.entries.is_empty():
			var entry: LeveledItemEntry = list.entries[0]
			_check(entry.item_form_id != 0, "LVLI entry exposes referenced FormID")
			_check(entry.item_base == server.get_base(entry.item_form_id), "LVLI entry reuses cached item Base")
		break
	_check(found, "a real LVLI resolves as LeveledItemBase")
	if not found:
		return

	var synthetic := LeveledItemBase.new()
	synthetic.form_id = 0x7FFF0001
	var first := LeveledItemEntry.new()
	first.level = 1
	first.item_form_id = 0x000E3778
	first.item_base = server.get_base(first.item_form_id)
	first.count = 2
	var second := LeveledItemEntry.new()
	second.level = 5
	second.item_form_id = first.item_form_id
	second.item_base = first.item_base
	synthetic.entries = [first, second]
	var resolver := LeveledItemResolver.new(server)
	var resolved := resolver.resolve(synthetic, 5, {"seed": 1234})
	_check(resolved.size() == 1, "LVLI nearest-level selection chooses the nearest eligible level")
	_check(resolved[0].count == 1, "LVLI selected entry produces a single inventory stack")
	synthetic.flags = 0x04
	resolved = resolver.resolve(synthetic, 5, {"seed": 1234})
	_check(resolved.size() == 2, "LVLI Use All emits one stack per entry")
	_check(resolved[0].count == 2, "LVLI Use All preserves entry count in the stack")
	var preview_reference := LeveledItemReference.new()
	preview_reference.base_form_id = synthetic.form_id
	preview_reference.base = synthetic
	var preview_node := await EsmReferencePhysicaliser.new().physicalise(preview_reference)
	_check(preview_node is EsmLeveledItemPreviewNode, "LVLI physicalises as a non-world preview node")
	preview_node.free()

func _check_saved_base_rehydrates(server) -> void:
	var source: NpcBase = null
	for row in server.get_record_index():
		if String(row.get("record_type", "")) != "NPC_": continue
		source = server.get_base(int(row.get("form_id", 0))) as NpcBase
		if source != null and source.race != null and not source.editor_id.is_empty(): break
	if source == null or source.race == null:
		_fail("real NpcBase available for serialization regression")
		return
	var save_path := "user://test_esm_base_serialization.tres"
	var save_error := ResourceSaver.save(source, save_path)
	_check(save_error == OK, "NpcBase saves")
	if save_error != OK: return
	var text := FileAccess.get_file_as_string(save_path)
	_check(text.contains("source_uri = \"esm://"), "saved NpcBase persists source_uri")
	_check(not text.contains("form_id = "), "saved NpcBase omits derived form_id")
	_check(not text.contains("editor_id = "), "saved NpcBase omits derived EditorID")
	_check(not text.contains("record_type = "), "saved NpcBase omits derived record_type")
	_check(not text.contains("full_name = "), "saved NpcBase omits derived full_name")
	_check(not text.contains("race = ExtResource"), "saved NpcBase omits derived typed links")
	var loaded := ResourceLoader.load(save_path, "", ResourceLoader.CACHE_MODE_IGNORE) as NpcBase
	_check(loaded != null, "saved NpcBase reloads")
	await get_tree().process_frame
	_check(loaded != null and loaded.form_id == source.form_id, "reloaded NpcBase rehydrates FormID")
	_check(loaded != null and loaded.editor_id == source.editor_id, "reloaded NpcBase rehydrates EditorID")
	_check(loaded != null and loaded.race != null, "reloaded NpcBase rehydrates typed Race Base")
	_check(loaded != null and loaded.race == server.get_base(loaded.race_form_id), "reloaded links use canonical cached Race Base")

func _check(condition: bool, message: String) -> void:
	if condition: print("  OK   ", message)
	else:
		print("  FAIL ", message)
		failures += 1

func _fail(message: String) -> void:
	_check(false, message)

func _subrecord(raw: Dictionary, tag: String) -> PackedByteArray:
	for sub in raw.get("subrecords", []):
		if String(sub.get("type", "")) == tag: return sub.get("data", PackedByteArray())
	return PackedByteArray()

func _u32(data: PackedByteArray) -> int:
	return int(data.decode_u32(0)) if data.size() >= 4 else 0

func _count_pkid(raw: Dictionary) -> int:
	var count := 0
	for sub in raw.get("subrecords", []):
		if String(sub.get("type", "")) == "PKID": count += 1
	return count
