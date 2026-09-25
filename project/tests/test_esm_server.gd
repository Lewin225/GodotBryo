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
	_check_authored_reference_cache(server, index)
	_check_package_bases(server, index)
	_check_typed_container_inventory(server, index)
	_check_inventory_contract(server)
	_check_armor_slot_conflicts()
	await _check_door_resources(server, index)
	await _check_open_door_full_visual_state(server)
	await _check_item_resources(server, index)
	await _check_static_resource(server, index)
	await _check_lod_visual_handover(server)
	_check_persistent_imposter_policy(server)
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

func _check_authored_reference_cache(server, index: Array) -> void:
	for record_type in ["REFR", "ACHR", "ACRE"]:
		var cached := false
		for row in index:
			if String(row.get("record_type", "")) != record_type:
				continue
			var instance_id := "authored:%08X" % int(row.get("form_id", 0))
			var first: EsmReference = server.get_reference(instance_id)
			var second: EsmReference = server.get_reference(instance_id)
			if first == null:
				continue
			_check(first == second, "%s references reuse their authored Resource" % record_type)
			cached = true
			break
		_check(cached, "a real %s reference is available for cache validation" % record_type)

## Exhaustive shipped-master validation for the typed PACK path. The native
## package_census diagnostic establishes the complete byte-shape census; this
## test additionally checks EsmServer mapped every field it claims to expose.
func _check_package_bases(server, index: Array) -> void:
	var package_count := 0
	var errors: PackedStringArray = []
	for row in index:
		if String(row.get("record_type", "")) != "PACK":
			continue
		package_count += 1
		var form_id := int(row.get("form_id", 0))
		var package := server.get_base(form_id) as PackageBase
		if package == null:
			errors.append("0x%08X did not resolve as PackageBase" % form_id)
			continue
		var raw: Dictionary = server.reader.get_record_data(form_id)
		var general := _subrecord(raw, "PKDT")
		if general.size() != 8 and general.size() != 12:
			errors.append("0x%08X unexpected PKDT size %d" % [form_id, general.size()])
		elif package.general_flags_raw != _u32(general) or package.package_type != _u8(general, 4):
			errors.append("0x%08X PKDT general fields differ" % form_id)
		elif general.size() == 12 and (package.fallout_behavior_flags_raw != _u16(general, 6) or package.type_specific_flags_raw != _u16(general, 8)):
			errors.append("0x%08X PKDT FNV fields differ" % form_id)
		_check_decoded_package_flags(form_id, package, errors)
		var schedule := _subrecord(raw, "PSDT")
		if schedule.size() != 8 or package.schedule == null:
			errors.append("0x%08X PSDT was not populated" % form_id)
		elif package.schedule.month != _i8(schedule) or package.schedule.day_of_week != _i8(schedule, 1) or package.schedule.date != _i8(schedule, 2) or package.schedule.time != _i8(schedule, 3) or package.schedule.duration_hours != _u32(schedule, 4):
			errors.append("0x%08X PSDT fields differ" % form_id)
		_check_package_location(form_id, "PLDT", _subrecord(raw, "PLDT"), package.location_1, errors)
		_check_package_location(form_id, "PLD2", _subrecord(raw, "PLD2"), package.location_2, errors)
		_check_package_target(form_id, "PTDT", _subrecord(raw, "PTDT"), package.target_1, errors)
		_check_package_target(form_id, "PTD2", _subrecord(raw, "PTD2"), package.target_2, errors)
		var raw_conditions := _all_subrecords(raw, "CTDA")
		if package.conditions.size() != raw_conditions.size():
			errors.append("0x%08X CTDA count differs" % form_id)
		else:
			for condition_index in raw_conditions.size():
				var condition_data: PackedByteArray = raw_conditions[condition_index]
				var condition: PackageCondition = package.conditions[condition_index]
				if condition == null or condition.type_flags != _u8(condition_data) or condition.function_id != _u16(condition_data, 8) or condition.parameter_1 != _u32(condition_data, 12) or condition.parameter_2 != _u32(condition_data, 16) or condition.has_run_on != (condition_data.size() == 28):
					errors.append("0x%08X CTDA %d differs" % [form_id, condition_index])
					break
				if condition_data.size() == 28 and (condition.run_on != _u32(condition_data, 20) or condition.reference_form_id != _u32(condition_data, 24)):
					errors.append("0x%08X CTDA %d run-on differs" % [form_id, condition_index])
					break
		var raw_idles := _all_subrecords(raw, "IDLA")
		var idle_count := 0
		for idle_data in raw_idles:
			idle_count += idle_data.size() / 4
		if package.idle_animation_form_ids.size() != idle_count:
			errors.append("0x%08X IDLA count differs" % form_id)
		if package.has_eat_marker != _has_subrecord(raw, "PKED") or package.has_use_item_marker != _has_subrecord(raw, "PUID") or package.has_ambush_marker != _has_subrecord(raw, "PKAM"):
			errors.append("0x%08X marker fields differ" % form_id)
		var use_weapon := _subrecord(raw, "PKW3")
		if (not use_weapon.is_empty()) != (package.use_weapon_data != null):
			errors.append("0x%08X PKW3 presence differs" % form_id)
		elif package.use_weapon_data != null and (package.use_weapon_data.flags != _u32(use_weapon) or package.use_weapon_data.pause_between_volleys_max != _f32(use_weapon, 16)):
			errors.append("0x%08X PKW3 fields differ" % form_id)
		var dialogue := _subrecord(raw, "PKDD")
		if (not dialogue.is_empty()) != (package.dialogue_data != null):
			errors.append("0x%08X PKDD presence differs" % form_id)
		elif package.dialogue_data != null and (package.dialogue_data.field_of_view != _f32(dialogue) or package.dialogue_data.topic_form_id != _u32(dialogue, 4) or package.dialogue_data.dialogue_type != _u32(dialogue, 16)):
			errors.append("0x%08X PKDD fields differ" % form_id)
		_check_package_events(form_id, raw, package, errors)
	_check(package_count > 0, "the shipped master contains PACK records")
	_check(errors.is_empty(), "all %d shipped PACK records populate their typed fields%s" % [package_count, "" if errors.is_empty() else ": " + "; ".join(errors.slice(0, 4))])

func _check_decoded_package_flags(form_id: int, package: PackageBase, errors: PackedStringArray) -> void:
	if package.general_flags == null or package.fallout_behavior_flags == null or package.type_specific_flags == null:
		errors.append("0x%08X decoded flag resource is absent" % form_id)
		return
	_check_flag_properties(form_id, package.general_flags_raw, package.general_flags, {
		"offers_services": 0x00000001, "must_reach_location": 0x00000002, "must_complete": 0x00000004,
		"lock_doors_at_package_start": 0x00000008, "lock_doors_at_package_end": 0x00000010, "lock_doors_at_location": 0x00000020,
		"unlock_doors_at_package_start": 0x00000040, "unlock_doors_at_package_end": 0x00000080, "unlock_doors_at_location": 0x00000100,
		"continue_if_player_near": 0x00000200, "once_per_day": 0x00000400, "skip_fallout_behavior": 0x00001000,
		"always_run": 0x00002000, "always_sneak": 0x00020000, "allow_swimming": 0x00040000,
		"allow_falls": 0x00080000, "head_tracking_off": 0x00100000, "weapons_unequipped": 0x00200000,
		"defensive_combat": 0x00400000, "weapon_drawn": 0x00800000, "no_idle_animations": 0x01000000,
		"pretend_in_combat": 0x02000000, "continue_during_combat": 0x04000000, "no_combat_alert": 0x08000000,
		"no_warn_or_attack_behavior": 0x10000000
	}, errors)
	_check_flag_properties(form_id, package.fallout_behavior_flags_raw, package.fallout_behavior_flags, {
		"hellos_to_player": 0x0001, "random_conversations": 0x0002, "observe_combat_behavior": 0x0004,
		"reaction_to_player_actions": 0x0010, "friendly_fire_comments": 0x0020, "aggro_radius_behavior": 0x0040,
		"allow_idle_chatter": 0x0080, "avoid_radiation": 0x0100
	}, errors)
	var type_masks := {}
	match package.package_type:
		PackageBase.PackageType.FIND, PackageBase.PackageType.ESCORT, PackageBase.PackageType.EAT:
			type_masks = {"allow_buying": 0x0100, "allow_killing": 0x0200, "allow_stealing": 0x0400}
		PackageBase.PackageType.WANDER, PackageBase.PackageType.SANDBOX:
			type_masks = {"no_eating": 0x0001, "no_sleeping": 0x0002, "no_conversation": 0x0004, "no_idle_markers": 0x0008, "no_furniture": 0x0010, "no_wandering": 0x0020}
		PackageBase.PackageType.USE_ITEM_AT:
			type_masks = {"sit_down": 0x0004, "allow_buying": 0x0100, "allow_killing": 0x0200, "allow_stealing": 0x0400}
		PackageBase.PackageType.AMBUSH:
			type_masks = {"hide_while_ambushing": 0x0001}
		PackageBase.PackageType.GUARD:
			type_masks = {"remain_near_reference_to_guard": 0x0008}
	_check_flag_properties(form_id, package.type_specific_flags_raw, package.type_specific_flags, type_masks, errors)

func _check_flag_properties(form_id: int, raw_flags: int, flags: Resource, masks: Dictionary, errors: PackedStringArray) -> void:
	for property_name in masks:
		var expected := (raw_flags & int(masks[property_name])) != 0
		if bool(flags.get(property_name)) != expected:
			errors.append("0x%08X %s differs" % [form_id, property_name])
			return

func _check_package_location(form_id: int, tag: String, data: PackedByteArray, location: PackageLocation, errors: PackedStringArray) -> void:
	if data.is_empty():
		if location != null: errors.append("0x%08X %s should be absent" % [form_id, tag])
		return
	if location == null or location.location_type != _i32(data) or location.location_value == null or location.location_value.raw_value != _u32(data, 4) or location.radius != _i32(data, 8):
		errors.append("0x%08X %s fields differ" % [form_id, tag])
		return
	var raw_value := _u32(data, 4)
	match location.location_type:
		PackageLocation.LocationType.NEAR_REFERENCE:
			if location.location_value.value_kind != PackageLocationValue.ValueKind.REFERENCE or location.location_value.reference_instance_id != "authored:%08X" % raw_value: errors.append("0x%08X %s reference union differs" % [form_id, tag])
		PackageLocation.LocationType.IN_CELL:
			if location.location_value.value_kind != PackageLocationValue.ValueKind.CELL or location.location_value.cell_form_id != raw_value: errors.append("0x%08X %s cell union differs" % [form_id, tag])
		PackageLocation.LocationType.NEAR_CURRENT_LOCATION:
			if location.location_value.value_kind != PackageLocationValue.ValueKind.CURRENT_LOCATION: errors.append("0x%08X %s current-location union differs" % [form_id, tag])
		PackageLocation.LocationType.NEAR_EDITOR_LOCATION:
			if location.location_value.value_kind != PackageLocationValue.ValueKind.EDITOR_LOCATION: errors.append("0x%08X %s editor-location union differs" % [form_id, tag])
		PackageLocation.LocationType.OBJECT_ID:
			if location.location_value.value_kind != PackageLocationValue.ValueKind.OBJECT_BASE or location.location_value.object_base_form_id != raw_value: errors.append("0x%08X %s object union differs" % [form_id, tag])
		PackageLocation.LocationType.OBJECT_TYPE:
			if location.location_value.value_kind != PackageLocationValue.ValueKind.OBJECT_TYPE or location.location_value.object_type != raw_value: errors.append("0x%08X %s object-type union differs" % [form_id, tag])
		PackageLocation.LocationType.NEAR_LINKED_REFERENCE:
			if location.location_value.value_kind != PackageLocationValue.ValueKind.LINKED_REFERENCE: errors.append("0x%08X %s linked-reference union differs" % [form_id, tag])
		PackageLocation.LocationType.AT_PACKAGE_LOCATION:
			if location.location_value.value_kind != PackageLocationValue.ValueKind.PACKAGE_LOCATION: errors.append("0x%08X %s package-location union differs" % [form_id, tag])

func _check_package_target(form_id: int, tag: String, data: PackedByteArray, target: PackageTarget, errors: PackedStringArray) -> void:
	if data.is_empty():
		if target != null: errors.append("0x%08X %s should be absent" % [form_id, tag])
		return
	if target == null or target.target_type != _i32(data) or target.target_value != _u32(data, 4) or target.count_or_distance != _i32(data, 8) or target.unknown != _f32(data, 12):
		errors.append("0x%08X %s fields differ" % [form_id, tag])

func _check_package_events(form_id: int, raw: Dictionary, package: PackageBase, errors: PackedStringArray) -> void:
	var expected := {"POBA": {}, "POEA": {}, "POCA": {}}
	var marker := ""
	for subrecord in raw.get("subrecords", []):
		var tag := String(subrecord.get("type", ""))
		if expected.has(tag):
			marker = tag
			expected[marker] = {"idle": 0, "topic": 0, "script_header": PackedByteArray(), "compiled": PackedByteArray(), "source": "", "locals": 0, "names": 0, "references": 0, "local_references": 0}
			continue
		if marker.is_empty():
			continue
		var data: PackedByteArray = subrecord.get("data", PackedByteArray())
		if tag == "INAM": expected[marker]["idle"] = _u32(data)
		elif tag == "TNAM": expected[marker]["topic"] = _u32(data)
		elif tag == "SCHR": expected[marker]["script_header"] = data
		elif tag == "SCDA": expected[marker]["compiled"] = data
		elif tag == "SCTX": expected[marker]["source"] = _string(data)
		elif tag == "SLSD": expected[marker]["locals"] = int(expected[marker]["locals"]) + 1
		elif tag == "SCVR": expected[marker]["names"] = int(expected[marker]["names"]) + 1
		elif tag == "SCRO": expected[marker]["references"] = int(expected[marker]["references"]) + 1
		elif tag == "SCRV": expected[marker]["local_references"] = int(expected[marker]["local_references"]) + 1
	for event_data in [["POBA", package.on_begin], ["POEA", package.on_end], ["POCA", package.on_change]]:
		var marker_name: String = event_data[0]
		var event: PackageEvent = event_data[1]
		if expected[marker_name].is_empty():
			if event != null: errors.append("0x%08X unexpected %s event" % [form_id, marker_name])
		elif event == null or event.idle_form_id != int(expected[marker_name]["idle"]) or event.topic_form_id != int(expected[marker_name]["topic"]) or event.script_header != expected[marker_name]["script_header"] or event.compiled_script != expected[marker_name]["compiled"] or event.script_source != String(expected[marker_name]["source"]) or event.local_variables.size() != int(expected[marker_name]["locals"]) or event.local_variable_names.size() != int(expected[marker_name]["names"]) or event.script_references.size() != int(expected[marker_name]["references"]) or event.script_local_reference_indices.size() != int(expected[marker_name]["local_references"]):
			errors.append("0x%08X %s event fields differ" % [form_id, marker_name])

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
			var node: EsmNode = _physicalise_in_tree(reference)
			_check(node is EsmDoorNode, "Door physicalizer returns its semantic node immediately")
			_check_interact_ray_resolves_esm_node(node)
			var converted_position := Basis(Vector3.RIGHT, -PI / 2.0) * reference.position
			_check(node.position.is_equal_approx(converted_position), "Physicalizer converts placement translation into NifServer's Godot space")
			_check(node.get_authored_transform().origin.is_equal_approx(reference.position), "Physicalizer retains authored placement for save/dirty comparisons")
			var visual := await _await_nif_visual(node)
			_check(visual != null, "Door EsmNode receives its NifServer visual asynchronously")
			_check(node.get_nif_animation_player() != null, "Door visual exposes its AnimationPlayer through NifVisual")
			node.queue_free()
			break
	_check(found_door_reference, "a real DOOR placement resolves as DoorReference")
	_check_typed_door_activation_receipt()
	_check_misc_physicaliser(server)

## NifServer returns ordinary Node3D/StaticBody3D descendants. Interaction
## must recover the owning placement, not expose implementation children to
## the player controller or Game.
func _check_interact_ray_resolves_esm_node(door: EsmNode) -> void:
	var nif_child := Node3D.new()
	var collision_body := StaticBody3D.new()
	door.add_child(nif_child)
	nif_child.add_child(collision_body)
	_check(InteractRay.semantic_target(collision_body) == door, "InteractRay resolves a NIF collision child to its EsmNode")
	_check(InteractRay.new().get_interaction_type(door) == &"door", "InteractRay identifies semantic EsmDoorNode interaction type")
	_check(InteractRay.new().get_interaction_action(door).contains("Open") or InteractRay.new().get_interaction_action(door).contains("Close"), "InteractRay supplies EsmDoorNode action text")
	nif_child.queue_free()

## This does not depend on a particular authored test door having XTEL: it
## asserts the exact receipt Game consumes to select the destination loader.
func _check_typed_door_activation_receipt() -> void:
	var reference := DoorReference.new()
	reference.has_teleport_destination = true
	reference.teleport_destination_cell_form_id = 0x00123456
	reference.teleport_position = Vector3(1.0, 2.0, 3.0)
	reference.teleport_rotation = Vector3(0.1, 0.2, 0.3)
	var door := EsmDoorNode.new()
	door.configure(reference)
	var outcome := door.activate()
	_check(int(outcome.get("dest_cell_form_id", 0)) == reference.teleport_destination_cell_form_id, "EsmDoorNode activation returns its XTEL destination cell")
	_check(outcome.get("dest_position", Vector3.ZERO) == reference.teleport_position and outcome.get("dest_rotation", Vector3.ZERO) == reference.teleport_rotation, "EsmDoorNode activation preserves XTEL spawn transform")
	door.free()


## REFR 0010757E is the open-by-default gate outside Doc Mitchell's house.
## It starts as a distant LOD in WorldStreamer, so the full NIF can arrive
## after the semantic DoorReference already knows that it is open.
func _check_open_door_full_visual_state(server) -> void:
	var reference := server.get_reference("authored:0010757E") as DoorReference
	_check(reference != null, "Doc Mitchell exterior gate resolves as a DoorReference")
	if reference == null:
		return
	_check(reference.is_open_by_default and reference.is_open,
		"Doc Mitchell exterior gate retains its authored open state")
	var host := Node3D.new()
	add_child(host)
	var node := EsmReferencePhysicaliser.new().physicalise(reference, host) as EsmDoorNode
	var visual := await _await_nif_visual(node)
	var player := node.get_nif_animation_player() if node != null else null
	_check(visual != null and player != null and player.has_animation("Open"),
		"open gate's full NIF arrives with its Open sequence")
	if player != null and player.has_animation("Open"):
		var gate := visual.find_child("BGate", true, false) as Node3D
		var open_turn := Quaternion.IDENTITY.angle_to(gate.quaternion) if gate != null else 0.0
		_check(open_turn > 1.0, "full NIF is immediately posed open (%.3f rad)" % open_turn)
		_check(not player.is_playing(), "open-state pose is held rather than replaying after stream-in")
		node.activate()
		_check(not reference.is_open and player.current_animation == "Close" and player.is_playing(),
			"first activation of an authored-open gate plays Close")
	host.queue_free()

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
	var node := _physicalise_in_tree(reference)
	_check(node is EsmItemNode, "MISC physicalises as EsmItemNode")
	var debug_description := node.get_debug_description()
	_check(debug_description.contains(reference.instance_id) and debug_description.contains("0x%08X" % reference.base.form_id),
		"EsmNode exposes typed REFR/Base identity for the look-at HUD")
	var visual := await _await_nif_visual(node)
	_check(visual != null, "MISC receives its NifServer visual asynchronously")
	_check(not visual.find_children("*", "CollisionShape3D", true, false).is_empty() if visual != null else false, "MISC NifServer visual includes authored collision")
	_check(node is EsmItemNode, "MISC resource path does not construct legacy ItemNode")
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
	var visual := await _await_nif_visual(loaded_item)
	_check(visual != null, "packed EsmItemNode rebuilds its NifServer visual after tree entry")
	_check(visual != null and visual.owner == null, "generated NifVisual remains unowned for editor/runtime regeneration")
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
			var node := EsmReferencePhysicaliser.new().physicalise(reference)
			_check(node is EsmItemNode, "%s physicalises as EsmItemNode" % type_tag)
			_check(node is EsmItemNode and (node as EsmItemNode).reference == reference, "%s EsmItemNode retains its typed reference" % type_tag)
			_check(node.get_child_count() == 0, "%s physicalises without synchronously constructing legacy children" % type_tag)
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
		var node := _physicalise_in_tree(reference)
		_check(node is EsmStaticNode, "STAT physicalises as EsmStaticNode")
		_check(await _await_nif_visual(node) != null, "STAT receives an individual NifServer visual")
		node.queue_free()
		break
	_check(found_reference, "a real STAT reference is available")


## NifServer deliberately paces its callbacks, so EsmNode must hold the
## currently rendered tree through both directions of a paired-model swap.
func _check_lod_visual_handover(server) -> void:
	var reference: EsmReference = null
	var worldspace: Dictionary = server.reader.find_worldspace_by_editor_id("WastelandNV")
	if not worldspace.is_empty():
		var worldspace_form_id := int(worldspace.get("form_id", 0))
		for gx in range(-40, 40):
			if reference != null:
				break
			for gy in range(-40, 40):
				var cell: Dictionary = server.reader.find_exterior_cell(worldspace_form_id, gx, gy)
				if cell.is_empty():
					continue
				for placement in server.reader.get_cell_references(int(cell.get("form_id", 0))):
					var model := String(placement.get("model", "")).replace("\\", "/").to_lower()
					if not model.ends_with("architecture/barracks/barracks01.nif"):
						continue
					reference = server.get_reference("authored:%08X" % int(placement.get("refr_form_id", 0)))
					break
				if reference != null:
					break
	_check(reference != null, "a real Barracks01 REFR is available for paired LOD handover")
	if reference == null:
		return
	_check(reference.visible_when_distant, "EsmServer retains the REFR Visible When Distant flag on its typed resource")
	var host := Node3D.new()
	add_child(host)
	var node := EsmReferencePhysicaliser.new().physicalise(reference, host, EsmNode.VisualDetail.LOD) as EsmNode
	_check(node != null and node.visual_detail == EsmNode.VisualDetail.LOD,
		"Physicalizer assigns the requested initial visual tier before tree entry")
	var lod := await _await_visual(node, "NifLodVisual")
	_check(lod != null and node.get_node_or_null("NifVisual") == null,
		"an initial LOD tier requests only the paired LOD tree")
	if lod == null:
		host.queue_free()
		return
	node.visual_detail = EsmNode.VisualDetail.FULL
	_check(node.get_node_or_null("NifLodVisual") == lod,
		"LOD stays visible while the full-detail request is pending")
	var full := await _await_visual(node, "NifVisual")
	_check(full != null and node.get_node_or_null("NifLodVisual") == null,
		"full-detail delivery atomically replaces the paired LOD tree")
	if full != null:
		node.visual_detail = EsmNode.VisualDetail.LOD
		_check(node.get_node_or_null("NifVisual") == full,
			"full detail stays visible while a downgrade request is pending")
		lod = await _await_visual(node, "NifLodVisual")
		_check(lod != null and node.get_node_or_null("NifVisual") == null,
			"LOD delivery atomically replaces the full-detail tree")
	host.queue_free()


func _check_persistent_imposter_policy(server) -> void:
	var worldspace: Dictionary = server.reader.find_worldspace_by_editor_id("WastelandNV")
	var imposter: EsmReference = null
	if not worldspace.is_empty():
		for reference: EsmReference in server.get_persistent_references_for_worldspace(int(worldspace.get("form_id", 0))):
			if reference.base != null and reference.base.editor_id == "McCarranWallLongImposter":
				imposter = reference
				break
	_check(imposter != null and imposter.has_xsrf_or_xsrd,
		"EsmServer retains the XSRF/XSRD stand-in marker on a persistent imposter")
	if imposter == null:
		return
	_check(not imposter.visible_when_distant, "persistent imposter is not misclassified as a paired VWD model")
	var node := EsmNode.new()
	node.configure(imposter)
	var visual := Node3D.new()
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	visual.add_child(mesh)
	var body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	collision.shape = BoxShape3D.new()
	body.add_child(collision)
	visual.add_child(body)
	node._on_nif_visual_ready(visual)
	_check(mesh.visibility_range_begin == 300.0 and mesh.visibility_range_end == 0.0,
		"persistent imposter uses the standalone begin-only near visibility range")
	_check(collision.disabled, "persistent imposter collision is disabled with its near-hidden visual")
	visual.free()
	node.free()

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
			var node := EsmReferencePhysicaliser.new().physicalise(reference)
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
			var node := _physicalise_in_tree(reference)
			_check(node.get_script() == expected[tag]["node"], "%s physicalises as typed Node" % tag)
			if tag == "SCOL":
				await get_tree().process_frame
				_check((node as EsmStaticCollectionNode).is_batch_candidate, "SCOL exposes future batch-candidate metadata")
				_check(node.get_child_count() > 0, "SCOL synchronously expands into semantic part nodes")
			else:
				_check((reference as MovableStaticReference).emittance_form_id >= 0, "MSTT preserves emittance identity")
			node.queue_free()
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
			var node := EsmReferencePhysicaliser.new().physicalise(reference)
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
			var node := EsmReferencePhysicaliser.new().physicalise(reference)
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
	var preview_node := EsmReferencePhysicaliser.new().physicalise(preview_reference)
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

## NifServer deliberately paces callbacks over frames. This helper asserts the
## EsmNode contract without making physicalisation itself await asset work.
func _await_nif_visual(node: EsmNode, max_frames := 180) -> Node3D:
	return await _await_visual(node, "NifVisual", max_frames)


func _await_visual(node: EsmNode, node_name: String, max_frames := 180) -> Node3D:
	for _frame in max_frames:
		var visual := node.get_node_or_null(node_name) as Node3D
		if visual != null:
			return visual
		await get_tree().process_frame
	return null

func _physicalise_in_tree(reference: EsmReference) -> EsmNode:
	var host := Node3D.new()
	add_child(host)
	var node := EsmReferencePhysicaliser.new().physicalise(reference, host) as EsmNode
	if node != null:
		node.tree_exiting.connect(host.queue_free, CONNECT_ONE_SHOT)
	return node

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

func _all_subrecords(raw: Dictionary, tag: String) -> Array[PackedByteArray]:
	var result: Array[PackedByteArray] = []
	for sub in raw.get("subrecords", []):
		if String(sub.get("type", "")) == tag: result.append(sub.get("data", PackedByteArray()))
	return result

func _has_subrecord(raw: Dictionary, tag: String) -> bool:
	return not _subrecord(raw, tag).is_empty() or (tag in ["PKED", "PUID", "PKAM"] and _all_subrecords(raw, tag).size() > 0)

func _u8(data: PackedByteArray, offset := 0) -> int:
	return int(data[offset]) if data.size() > offset else 0

func _i8(data: PackedByteArray, offset := 0) -> int:
	var value := _u8(data, offset)
	return value - 256 if value >= 128 else value

func _u16(data: PackedByteArray, offset := 0) -> int:
	return int(data.decode_u16(offset)) if data.size() >= offset + 2 else 0

func _u32(data: PackedByteArray, offset := 0) -> int:
	return int(data.decode_u32(offset)) if data.size() >= offset + 4 else 0

func _i32(data: PackedByteArray, offset := 0) -> int:
	return int(data.decode_s32(offset)) if data.size() >= offset + 4 else 0

func _f32(data: PackedByteArray, offset := 0) -> float:
	return data.decode_float(offset) if data.size() >= offset + 4 else 0.0

func _string(data: PackedByteArray) -> String:
	var end := data.size()
	for index in data.size():
		if data[index] == 0:
			end = index
			break
	return data.slice(0, end).get_string_from_ascii()

func _count_pkid(raw: Dictionary) -> int:
	var count := 0
	for sub in raw.get("subrecords", []):
		if String(sub.get("type", "")) == "PKID": count += 1
	return count
