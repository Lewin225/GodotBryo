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
		var name_form_id := _u32(_subrecord(raw, "NAME"))
		if name_form_id == 0: continue
		var reference: EsmReference = server.get_reference("authored:%08X" % int(row.get("form_id", 0)))
		if reference is NpcReference:
			found_actor = true
			var actor_base := reference.base as NpcBase
			_check(reference.contents is Inventory, "an NpcReference owns a typed Inventory")
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
	_check(found_actor, "an ACHR resolves as NpcReference")
	_check_authored_reference_cache(server, index)
	_check_xemi_reference_fields(server)
	await _check_xemi_visual_tint(server)
	_check_reference_location(server)
	_check_door_links_and_locks(server)
	_check_reference_index(server, index)
	_check_base_scripts(server, index)
	_check_referenced_types(server, index)
	_check_actor_bases(server, index)
	_check_actor_references(server, index)
	_check_package_bases(server, index)
	_check_typed_container_inventory(server, index)
	_check_inventory_contract(server)
	_check_armor_slot_conflicts()
	_check_armor_fields(server)
	_check_hair_and_head_part_fields(server, index)
	_check_texture_sets(server, index)
	await _check_door_resources(server, index)
	await _check_open_door_full_visual_state(server)
	_check_item_resources(server, index)
	await _check_static_resource(server, index)
	await _check_lod_visual_handover(server)
	_check_persistent_imposter_policy(server)
	_check_interactive_resources(server, index)
	await _check_collection_and_movable_resources(server, index)
	_check_talking_activator_and_terminal_resources(server, index)
	_check_dropped_item_resources(server, index)
	_check_leveled_item_resources(server, index)
	_check(server.get_reference("runtime:000E3778:1") == null, "runtime ID is deferred")
	_check(server.get_reference("not-an-id") == null, "malformed ID returns null")
	_check_relocated_references(server)
	_check_player_reference(server)
	_check_terminal_locks(server, index)
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

## FalloutNV.esm's XEMI census finds this subrecord only on these five REFR
## base types. The native placement already carries its raw FormID; the typed
## reference must preserve the same value, including the Goodsprings beam.
func _check_xemi_reference_fields(server) -> void:
	var cases := [
		[0x0014AF3E, ActivatorReference],
		[0x0013DD64, DoorReference],
		[0x0014BD54, LightReference],
		[0x0014EA0F, MovableStaticReference],
		[0x0016B5EB, StaticReference],
	]
	for entry in cases:
		var refr_form_id: int = int(entry[0])
		var placement: Dictionary = server.reader.get_reference_placement(refr_form_id)
		var emittance_form_id: int = int(placement.get("emittance_form_id", 0))
		_check(emittance_form_id != 0, "REFR %08X has authored XEMI" % refr_form_id)
		var reference: EsmReference = server.get_reference("authored:%08X" % refr_form_id)
		_check(reference != null and reference.get_script() == entry[1],
			"REFR %08X resolves to its XEMI-capable reference type" % refr_form_id)
		if reference != null:
			_check(int(reference.get("emittance_form_id")) == emittance_form_id,
				"REFR %08X preserves its XEMI FormID" % refr_form_id)
	_check(int(server.reader.get_reference_placement(0x0016B5EB).get("emittance_form_id", 0)) == 0x00171CDF,
		"Goodsprings beam links its authored REGN emittance source")


func _check_xemi_visual_tint(server) -> void:
	var cases := [
		[0x00103E26, "NVCraftsmanRmWallGlassB:10", "NVCraftsmanRmWallGlassB:7"],
		[0x001062B5, "IndFXLightRays01:0", ""],
		[0x0016B5EB, "FXLightBeamBrtW02:1", "EditorMarker:0"],
	]
	for entry in cases:
		var reference: EsmReference = server.get_reference("authored:%08X" % int(entry[0]))
		var node := _physicalise_in_tree(reference)
		var visual := await _await_nif_visual(node) if node != null else null
		_check(visual != null, "REFR %08X receives its XEMI visual" % int(entry[0]))
		if visual == null:
			if node != null:
				node.queue_free()
			continue
		var emittance_form_id := int(reference.get("emittance_form_id"))
		var authored_color: Color = server.reader.get_emittance_data(emittance_form_id).get("color", Color.WHITE)
		var color := authored_color.linear_to_srgb()
		var found_marked := false
		var found_unmarked := String(entry[2]).is_empty()
		for child in visual.find_children("*", "MeshInstance3D", true, false):
			var instance := child as MeshInstance3D
			var authored_name := String(instance.get_meta("nif_name", ""))
			if authored_name == String(entry[1]):
				found_marked = true
				var override := instance.get_surface_override_material(0) as StandardMaterial3D
				var shared := instance.mesh.surface_get_material(0) as StandardMaterial3D
				_check(override != null and override != shared,
					"%s has a placement-local material" % authored_name)
				if override != null and shared != null:
					var expected_albedo := Color(color.r, color.g, color.b, shared.albedo_color.a)
					_check(override.albedo_color.is_equal_approx(expected_albedo) and override.emission_enabled
						and override.emission.is_equal_approx(color),
						"%s uses XEMI for albedo and emission without changing alpha" % authored_name)
					_check(shared.albedo_color.is_equal_approx(Color(1, 1, 1, shared.albedo_color.a)),
						"%s leaves the cached material untinted" % authored_name)
			elif authored_name == String(entry[2]):
				found_unmarked = true
				_check(instance.get_surface_override_material(0) == null,
					"%s has no XEMI override" % authored_name)
		_check(found_marked and found_unmarked, "REFR %08X targets only authored shapes" % int(entry[0]))
		node.queue_free()


## Exhaustive shipped-master validation for the typed PACK path. The native
## package_census diagnostic establishes the complete byte-shape census; this
## test additionally checks EsmServer mapped every field it claims to expose.
## Exterior grid index, cell_at(), space lookup and cell-change signalling.
func _check_reference_location(server) -> void:
	var wasteland := int(server.reader.find_worldspace_by_editor_id("WastelandNV").get("form_id", 0))
	_check(wasteland != 0, "WastelandNV resolves")

	# Every indexed grid CELL reports the same XCLC coordinate natively.
	var total := 0
	var mismatched := 0
	for wrld: int in server._grid_cells:
		var cells: Dictionary = server._grid_cells[wrld]
		for coord: Vector2i in cells:
			total += 1
			var grid: Dictionary = server.reader.get_exterior_cell_grid(cells[coord])
			if Vector2i(int(grid.get("x", 0x7fffffff)), int(grid.get("y", 0x7fffffff))) != coord:
				mismatched += 1
	_check(total == 30096, "grid index holds every FalloutNV.esm exterior grid CELL (%d)" % total)
	_check(mismatched == 0, "every indexed grid CELL matches its own XCLC (%d mismatched)" % mismatched)
	var persistent: int = server._persistent_cell_by_worldspace.get(wasteland, 0)
	_check(persistent != 0, "WastelandNV has a persistent CELL")
	_check(server.get_space_form_id_for_cell(persistent) == wasteland, "persistent CELL maps to its WRLD")

	# Grid references: the CELL that files a REFR is the one under its position.
	var checked := 0
	var off_cell := 0
	for x in range(-24, -10):
		for y in range(-6, 8):
			var cell: int = server.get_exterior_cell_form_id(wasteland, Vector2i(x, y))
			if cell == 0:
				continue
			_check(server.get_space_form_id_for_cell(cell) == wasteland, "grid CELL (%d, %d) maps to WastelandNV" % [x, y])
			for reference: EsmReference in server.get_references_in_cell(cell):
				checked += 1
				if reference.current_space_form_id != wasteland or reference.current_cell_form_id != server.cell_at(wasteland, reference.position):
					_fail("reference %s has space %X cell %X, cell_at gives %X" % [reference.instance_id, reference.current_space_form_id, reference.current_cell_form_id, server.cell_at(wasteland, reference.position)])
				elif reference.current_cell_form_id != cell:
					off_cell += 1
	_check(checked > 5000, "grid-reference sample is substantial (%d references)" % checked)
	_check(off_cell * 100 < checked, "under 1%% of grid references sit outside their filing CELL (%d of %d)" % [off_cell, checked])

	# Persistent references are placed in the grid CELL under them.
	var on_grid := 0
	var persistent_refs: Array[EsmReference] = server.get_persistent_references_for_worldspace(wasteland)
	for reference in persistent_refs:
		var expected: int = server.cell_at(wasteland, reference.position)
		if reference.current_space_form_id != wasteland or reference.current_cell_form_id != expected:
			_fail("persistent %s has space %X cell %X, expected %X" % [reference.instance_id, reference.current_space_form_id, reference.current_cell_form_id, expected])
		elif expected != persistent:
			on_grid += 1
	_check(persistent_refs.size() == 4468, "WastelandNV has 4468 persistent references (%d)" % persistent_refs.size())
	_check(on_grid == persistent_refs.size(), "every WastelandNV persistent reference lies on a grid CELL (%d of %d)" % [on_grid, persistent_refs.size()])

	# Interiors: the space is the CELL.
	var interior := int(server.reader.find_cell_by_editor_id("GSDocMitchellHouse").get("form_id", 0))
	var interior_refs: Array[EsmReference] = server.get_references_in_cell(interior)
	_check(not interior_refs.is_empty(), "GSDocMitchellHouse has references")
	var interior_ok := true
	for reference in interior_refs:
		interior_ok = interior_ok and reference.current_space_form_id == interior and reference.current_cell_form_id == interior
	_check(interior_ok, "interior references use the CELL as space and cell")
	_check(server.get_space_form_id_for_cell(interior) == interior, "interior CELL is its own space")

	# Signals fire once per cell change, never for movement inside a cell.
	var probe: EsmReference = interior_refs[0]
	var start_space := probe.current_space_form_id
	var start_position := probe.position
	var server_events: Array = []
	var own_events: Array = []
	var on_server := func(reference, old_cell, new_cell): if reference == probe: server_events.append([old_cell, new_cell])
	var on_own := func(old_cell, new_cell): own_events.append([old_cell, new_cell])
	server.reference_cell_changed.connect(on_server)
	probe.cell_changed.connect(on_own)
	probe.position = start_position + Vector3(1, 1, 0)
	_check(server_events.is_empty(), "moving inside an interior emits nothing")
	var size: float = server.EXTERIOR_CELL_SIZE_METERS
	var cell_a: int = server.get_exterior_cell_form_id(wasteland, Vector2i(-18, 0))
	var cell_b: int = server.get_exterior_cell_form_id(wasteland, Vector2i(-17, 0))
	probe.set_location(wasteland, Vector3(-18 * size + 5.0, 5.0, 0))
	_check(server_events == [[interior, cell_a]], "set_location into WastelandNV emits one change (%s)" % [server_events])
	probe.position = Vector3(-18 * size + 20.0, 20.0, 0)
	_check(server_events.size() == 1, "moving inside a grid CELL emits nothing")
	probe.position = Vector3(-17 * size + 5.0, 20.0, 0)
	_check(server_events.size() == 2 and server_events[1] == [cell_a, cell_b], "crossing a grid line emits old and new CELL")
	probe.set_location(start_space, start_position)
	_check(server_events.size() == 3 and server_events[2] == [cell_b, interior], "set_location back to the interior emits one change")
	_check(own_events == server_events, "the reference's own cell_changed matches EsmServer.reference_cell_changed")
	server.reference_cell_changed.disconnect(on_server)
	probe.cell_changed.disconnect(on_own)

## Terminal lock state starts from every TERM base's DNAM.
func _check_terminal_locks(server, index: Array) -> void:
	var locked := 0
	var by_level := {}
	var with_note := 0
	for row: Dictionary in index:
		if String(row.get("record_type", "")) != "TERM":
			continue
		var terminal := server.create_reference_for_base(int(row["form_id"])) as TerminalReference
		if terminal == null or not terminal.is_locked:
			continue
		locked += 1
		by_level[terminal.lock_level] = int(by_level.get(terminal.lock_level, 0)) + 1
		if (terminal.base as TerminalBase).password_note_form_id != 0:
			with_note += 1
	_check(locked == 151, "151 TERM bases start locked (%d)" % locked)
	_check(by_level == {0: 44, 1: 19, 2: 44, 3: 21, 4: 18, 5: 5}, "locked terminals by difficulty match the census (%s)" % [by_level])
	_check(with_note == 21, "21 locked terminals name a password note (%d)" % with_note)

## The player's reference is one canonical NpcReference.
func _check_player_reference(server) -> void:
	var player: ActorReference = server.get_player_reference()
	_check(player != null and player.base is NpcBase and player.base.form_id == 0x7, "the player reference is an NpcReference on the Player NPC_ record")
	_check(server.get_player_reference() == player and server.get_reference("player") == player, "every lookup returns the same player reference")
	_check(player.instance_id == "player" and player.current_space_form_id == 0, "the player reference starts unplaced")
	var instance := ScriptInstance.new()
	instance.set_local("who", player)
	_check(instance.get_local("who") == player, "a ref local holding the player reads back as the same reference")

## A reference is listed under the CELL it is currently in.
func _check_relocated_references(server) -> void:
	var wasteland := int(server.reader.find_worldspace_by_editor_id("WastelandNV").get("form_id", 0))
	var interior := int(server.reader.find_cell_by_editor_id("GSDocMitchellHouse").get("form_id", 0))
	var cell_a: int = server.get_exterior_cell_form_id(wasteland, Vector2i(-18, 0))
	var cell_b: int = server.get_exterior_cell_form_id(wasteland, Vector2i(-17, 0))
	var size: float = server.EXTERIOR_CELL_SIZE_METERS
	var moved: EsmReference = server.get_references_in_cell(interior)[0]
	var home_position := moved.position
	moved.set_location(wasteland, Vector3(-18 * size + 3.0, 3.0, 0))
	_check(server.is_relocated(moved), "a reference that changed CELL is relocated")
	_check(not server.get_references_in_cell(interior).has(moved), "it is no longer listed in the CELL it left")
	_check(server.get_references_in_cell(cell_a).count(moved) == 1, "it is listed once in the CELL it entered")
	moved.set_location(interior, home_position)
	_check(server.get_references_in_cell(interior).count(moved) == 1 and not server.get_references_in_cell(cell_a).has(moved),
			"moved back, it is listed once in its own CELL again")

	var persistent: EsmReference = null
	for reference in server.get_persistent_references_for_worldspace(wasteland):
		if not reference.has_xsrf_or_xsrd:
			persistent = reference
			break
	persistent.position = Vector3(-17 * size + 3.0, 3.0, 0)
	_check(not server.get_persistent_references_for_worldspace(wasteland).has(persistent), "a relocated persistent reference leaves the persistent list")
	_check(server.get_references_in_cell(cell_b).count(persistent) == 1, "and is listed under its current grid CELL")

## Every QUST resolves as a QuestBase whose DATA and stages match the census.
func _check_quest_bases(server, index: Array) -> void:
	var counts := {"quests": 0, "enabled": 0, "stages": 0, "entries": 0, "scripts": 0, "conditioned": 0, "complete": 0, "fail": 0}
	for row: Dictionary in index:
		if String(row.get("record_type", "")) != "QUST":
			continue
		var quest := server.get_base(int(row["form_id"])) as QuestBase
		if quest == null:
			continue
		counts["quests"] += 1
		counts["enabled"] += int(quest.starts_enabled)
		counts["stages"] += quest.stages.size()
		for stage in quest.stages:
			for entry in stage.log_entries:
				counts["entries"] += 1
				counts["scripts"] += int(not entry.script_source.is_empty())
				counts["conditioned"] += int(not entry.conditions.is_empty())
				counts["complete"] += int((entry.flags & QuestLogEntryCollection.FLAG_COMPLETE_QUEST) != 0)
				counts["fail"] += int((entry.flags & QuestLogEntryCollection.FLAG_FAIL_QUEST) != 0)
	_check(counts == {"quests": 436, "enabled": 281, "stages": 1028, "entries": 969, "scripts": 737, "conditioned": 20, "complete": 150, "fail": 126},
			"every QUST resolves as a QuestBase matching the census (%s)" % [counts])
	_check_quest_objectives(server, index)

## Every QUST's objectives match native/tools/quest_objective_census, and
## VMQ01's match its record.
func _check_quest_objectives(server, index: Array) -> void:
	var counts := {"quests": 0, "objectives": 0, "empty_text": 0, "with_targets": 0, "targets": 0,
		"flag_01": 0, "other_flags": 0, "conditioned": 0, "conditions": 0, "duplicate_indexes": 0}
	for row: Dictionary in index:
		if String(row.get("record_type", "")) != "QUST":
			continue
		var quest := server.get_base(int(row["form_id"])) as QuestBase
		if quest == null or quest.objectives.is_empty():
			continue
		counts["quests"] += 1
		var seen := {}
		for objective in quest.objectives:
			counts["objectives"] += 1
			counts["empty_text"] += int(objective.text.is_empty())
			counts["with_targets"] += int(not objective.targets.is_empty())
			counts["duplicate_indexes"] += int(seen.has(objective.index))
			seen[objective.index] = true
			for target in objective.targets:
				counts["targets"] += 1
				counts["flag_01"] += int(target.flags == QuestObjectiveTargetCollection.FLAG_COMPASS_MARKER_IGNORES_LOCKS)
				counts["other_flags"] += int(target.flags > QuestObjectiveTargetCollection.FLAG_COMPASS_MARKER_IGNORES_LOCKS)
				counts["conditioned"] += int(not target.conditions.is_empty())
				counts["conditions"] += target.conditions.size()
	_check(counts == {"quests": 125, "objectives": 1045, "empty_text": 17, "with_targets": 892, "targets": 1469,
			"flag_01": 105, "other_flags": 1, "conditioned": 772, "conditions": 1229, "duplicate_indexes": 0},
			"every QUST's objectives match the census (%s)" % [counts])

	var vmq01 := server.find_quest_by_editor_id("VMQ01") as QuestBase
	var indexes: Array[int] = []
	for objective in vmq01.objectives:
		indexes.append(objective.index)
	_check(indexes == [20, 10, 30, 40, 50, 60, 25, 45, 34, 36, 46, 38], "VMQ01's 12 objectives in authored order (%s)" % [indexes])
	var first := vmq01.objectives[0]
	_check(first.text == "(Optional) Ask around the saloon in Goodsprings for information about your attackers."
			and first.targets.size() == 1 and first.targets[0].reference_form_id == 0x00104C6D
			and first.targets[0].flags == 1 and first.targets[0].conditions.is_empty(),
			"VMQ01 objective 20: NNAM text and one ACHR target, flag 0x01, no conditions")
	var novac := vmq01.get_objective(40)
	var shape: Array = []
	for target in novac.targets:
		shape.append([target.reference_form_id, target.flags, target.conditions.size()])
	_check(novac.text == "Head to Novac through Nipton. Ask around Novac about your attackers."
			and shape == [[0x0009289B, 1, 2], [0x000CDF13, 0, 1], [0x00177D36, 1, 2]],
			"VMQ01 objective 40: three REFR targets with their flags and CTDA counts (%s)" % [shape])
	_check(vmq01.get_objective(10).targets.is_empty() and vmq01.get_objective(15) == null,
			"VMQ01 objective 10 has no targets; 15 is not defined")

## Every base record carrying SCRI exposes it, across every scripted type.
func _check_base_scripts(server, index: Array) -> void:
	var expected := {"NPC_": 1046, "ACTI": 992, "CCRD": 270, "CREA": 260, "MISC": 178, "DOOR": 136, "CONT": 124,
		"ARMO": 47, "TERM": 20, "TACT": 18, "WEAP": 17, "FURN": 16, "KEYM": 7, "LIGH": 4, "AMMO": 2, "ALCH": 2}
	var scripted := {}
	var started := Time.get_ticks_msec()
	for row: Dictionary in index:
		var record_type := String(row.get("record_type", ""))
		if not expected.has(record_type):
			continue
		var base: EsmBase = server.get_base(int(row["form_id"]))
		if base != null and base.script_form_id != 0 and base.script_record is ScriptBase and base.script_record.form_id == base.script_form_id:
			scripted[record_type] = int(scripted.get(record_type, 0)) + 1
	var mismatched: PackedStringArray = []
	for record_type: String in expected:
		if int(scripted.get(record_type, 0)) != int(expected[record_type]):
			mismatched.append("%s %d/%d" % [record_type, int(scripted.get(record_type, 0)), expected[record_type]])
	_check(mismatched.is_empty(), "every scripted base record exposes its SCRI, resolved to its ScriptBase (%s) [%d ms]" % [", ".join(mismatched) if not mismatched.is_empty() else "all types match", Time.get_ticks_msec() - started])
	var doc: EsmReference = server.find_reference_by_editor_id("DocMitchellREF")
	_check(doc != null and doc.base.script_form_id != 0, "Doc Mitchell's NPC record has an object script")

## The record types actor records point at (Plans/Completed Plans/Actors/fields.md): every
## record of each resolves to its typed Base; VTYP flags and GLOB type and value
## match their subrecords; every FLST entry resolves.
func _check_referenced_types(server, index: Array) -> void:
	var classes := {"VTYP": "VoiceTypeBase", "GLOB": "GlobalBase", "LVLN": "LeveledNpcBase", "LVLC": "LeveledCreatureBase",
		"HDPT": "HeadPartBase", "IPDS": "ImpactDatasetBase", "SOUN": "SoundBase", "FACT": "FactionBase",
		"ENCH": "EnchantmentBase", "SPEL": "SpellBase", "CSTY": "CombatStyleBase", "SCPT": "ScriptBase",
		"NOTE": "NoteBase", "EXPL": "ExplosionBase", "DEBR": "DebrisBase", "ECZN": "EncounterZoneBase",
		"IDLE": "IdleBase", "FLST": "FormListBase"}
	var totals := {}
	var wrong: PackedStringArray = []
	var field_errors: PackedStringArray = []
	var flst_entries := 0
	for row: Dictionary in index:
		var record_type := String(row.get("record_type", ""))
		if not classes.has(record_type):
			continue
		var form_id := int(row["form_id"])
		totals[record_type] = int(totals.get(record_type, 0)) + 1
		var base: EsmBase = server.get_base(form_id)
		if base == null or base.get_script().get_global_name() != classes[record_type]:
			if wrong.size() < 5: wrong.append("%08X %s" % [form_id, record_type])
			continue
		var raw: Dictionary = server.reader.get_record_data(form_id)
		match record_type:
			"VTYP":
				var dnam := _subrecord(raw, "DNAM")
				if (base as VoiceTypeBase).flags != (dnam[0] if dnam.size() > 0 else 0): field_errors.append("%08X DNAM" % form_id)
			"GLOB":
				var glob := base as GlobalBase
				var fnam := _subrecord(raw, "FNAM")
				if glob.global_type != (char(fnam[0]) if fnam.size() > 0 else "f") or not is_equal_approx(glob.value, _subrecord(raw, "FLTV").decode_float(0)):
					field_errors.append("%08X FNAM/FLTV" % form_id)
			"FLST":
				var lnam := _all_subrecords(raw, "LNAM")
				flst_entries += lnam.size()
				var form_list := base as FormListBase
				if form_list.entries.size() != lnam.size(): field_errors.append("%08X LNAM %d/%d" % [form_id, form_list.entries.size(), lnam.size()])
	_check(wrong.is_empty(), "every VTYP, GLOB, LVLN, LVLC, HDPT, IPDS, SOUN, FACT, ENCH, SPEL, CSTY, SCPT, NOTE, EXPL, DEBR, ECZN, IDLE and FLST resolves to its typed Base (%s)" % [totals if wrong.is_empty() else wrong])
	_check(field_errors.is_empty(), "VTYP flags, GLOB type and value, and every FLST's %d entries match their subrecords (%s)" % [flst_entries, field_errors.slice(0, 5)])

## ActorBase, NpcBase and CreatureBase (Plans/Completed Plans/Actors/fields.md): over every
## NPC_ and CREA, each FormID field resolves when set, Items match CNTO and
## COED, DEST, NIFZ and CSDT match their subrecords; census A1 counts hold; a
## seeded inventory carries COED's condition.
func _check_actor_bases(server, index: Array) -> void:
	var counts := {"NPC_": 0, "CREA": 0, "items": 0, "coed": 0, "destructible": 0, "nifz": 0, "sounds": 0, "packages": 0, "templates": 0}
	var errors: PackedStringArray = []
	for row: Dictionary in index:
		var record_type := String(row.get("record_type", ""))
		if record_type != "NPC_" and record_type != "CREA":
			continue
		var form_id := int(row["form_id"])
		var actor := server.get_base(form_id) as ActorBase
		var typed := actor is NpcBase if record_type == "NPC_" else actor is CreatureBase
		if not typed:
			errors.append("%08X is not typed" % form_id)
			continue
		counts[record_type] += 1
		_tally_actor_base(counts, actor)
		for problem in _actor_base_errors(actor, server.reader.get_record_data(form_id)):
			errors.append("%08X %s" % [form_id, problem])
	_check(errors.is_empty(), "every NPC_ and CREA reads into its ActorBase, every FormID resolved (%s)" % [counts if errors.is_empty() else errors.slice(0, 6)])
	var census_a1 := {"NPC_": 3816, "CREA": 1578, "items": 16166 + 1568, "coed": 1345 + 16, "destructible": 7 + 55, "nifz": 1059, "sounds": 735}
	var matches := true
	for key: String in census_a1:
		matches = matches and counts[key] == census_a1[key]
	_check(matches, "census A1 counts: 3,816 NPC_, 1,578 CREA, 17,734 items, 1,361 with COED, 62 destructible, 1,059 with NIFZ, 735 sounds")
	_check_seeded_item_condition(server, index)

## Adds `actor`'s items, COED entries, packages, template, destructible data,
## NIFZ and sounds to `counts`.
func _tally_actor_base(counts: Dictionary, actor: ActorBase) -> void:
	counts["items"] += actor.items.size()
	for entry in actor.items:
		if entry.condition >= 0.0:
			counts["coed"] += 1
	counts["packages"] += actor.packages.size()
	if actor.template != null:
		counts["templates"] += 1
	if actor.destructible != null:
		counts["destructible"] += 1
	var creature := actor as CreatureBase
	if creature != null:
		if not creature.model_list.is_empty():
			counts["nifz"] += 1
		counts["sounds"] += creature.sounds.size()

## Where `actor` differs from its record `raw`: a list whose length is not its
## subrecord's count, or a FormID field without its resolved resource.
func _actor_base_errors(actor: ActorBase, raw: Dictionary) -> PackedStringArray:
	var problems := PackedStringArray()
	var lists := {"CNTO": actor.items.size(), "PKID": actor.packages.size(), "SPLO": actor.actor_effects.size()}
	if actor.destructible != null:
		lists["DSTD"] = actor.destructible.stages.size()
	if actor is CreatureBase:
		lists["CSDT"] = (actor as CreatureBase).sounds.size()
	else:
		lists["PNAM"] = (actor as NpcBase).head_parts.size()
	for tag: String in lists:
		var authored := _all_subrecords(raw, tag).size()
		if lists[tag] != authored:
			problems.append("%s %d/%d" % [tag, lists[tag], authored])
	for entry in actor.items:
		if entry.item == null:
			problems.append("item %08X unresolved" % entry.item_form_id)
	if actor.template_form_id != 0 and actor.template == null:
		problems.append("TPLT unresolved")
	if actor.voice_type_form_id != 0 and actor.voice_type == null:
		problems.append("VTCK unresolved")
	if actor.death_item_form_id != 0 and actor.death_item == null:
		problems.append("INAM unresolved")
	if actor.combat_style_form_id != 0 and actor.combat_style == null:
		problems.append("ZNAM unresolved")
	if actor.unarmed_attack_effect_form_id != 0 and actor.unarmed_attack_effect == null:
		problems.append("EITM unresolved")
	var creature := actor as CreatureBase
	if creature != null and creature.body_part_data_form_id != 0 and creature.body_part_data == null:
		problems.append("PNAM unresolved")
	return problems

## A seeded inventory carries COED's condition: the first NPC_ (taking its own
## inventory) with a COED entry naming a plain item, not a leveled list.
func _check_seeded_item_condition(server, index: Array) -> void:
	for row: Dictionary in index:
		if String(row.get("record_type", "")) != "NPC_":
			continue
		var npc := server.get_base(int(row["form_id"])) as NpcBase
		if (npc.template_flags & ActorBase.TEMPLATE_USE_INVENTORY) != 0:
			continue
		var entry := _first_conditioned_plain_item(npc)
		if entry == null:
			continue
		var reference: EsmReference = server.create_reference_for_base(npc.form_id)
		var carried := false
		for item: InventoryItem in reference.contents.get_items():
			var same_item := item.item_reference != null and item.item_reference.base_form_id == entry.item_form_id
			if same_item and is_equal_approx(item.health_percent, entry.condition):
				carried = true
		_check(carried, "%s's inventory item %s carries COED condition %.2f" % [npc.editor_id, entry.item.editor_id, entry.condition])
		return
	_check(false, "an NPC_ with a COED entry naming a plain item exists")

func _first_conditioned_plain_item(actor: ActorBase) -> InitialItemCollection:
	for entry in actor.items:
		if entry.condition >= 0.0 and not entry.item is LeveledItemBase:
			return entry
	return null

## Every ACHR is an NpcReference and every ACRE a CreatureReference, both
## ActorReferences. The placement subrecords they carry match census A1's
## counts, and every FormID field among them has its resolved resource.
func _check_actor_references(server, index: Array) -> void:
	const TAGS := ["XLCM", "XEZN", "XMRC", "XRGD", "XATO", "XIBS", "XOWN"]
	var expected := {"ACHR XLCM": 178, "ACRE XLCM": 119, "ACHR XEZN": 5, "ACRE XEZN": 11, "ACHR XMRC": 76, "ACRE XMRC": 1,
		"ACHR XRGD": 278, "ACRE XRGD": 109, "ACHR XATO": 3, "ACRE XATO": 1, "ACHR XIBS": 6, "ACRE XOWN": 10}
	var counts := {}
	var errors: PackedStringArray = []
	var started := Time.get_ticks_msec()
	for row: Dictionary in index:
		var record_type := String(row.get("record_type", ""))
		if record_type != "ACHR" and record_type != "ACRE":
			continue
		var form_id := int(row["form_id"])
		var reference: EsmReference = server.get_reference("authored:%08X" % form_id)
		if reference == null:
			continue
		var typed := reference is NpcReference if record_type == "ACHR" else reference is CreatureReference
		if not typed:
			errors.append("%08X %s is a %s" % [form_id, record_type, reference.get_script().get_global_name()])
			continue
		var raw: Dictionary = server.reader.get_record_data(form_id)
		for tag: String in TAGS:
			if _has_subrecord(raw, tag):
				var key := "%s %s" % [record_type, tag]
				counts[key] = int(counts.get(key, 0)) + 1
		for field in _unresolved_actor_reference_fields(reference as ActorReference):
			errors.append("%08X %s unresolved" % [form_id, field])
	for key: String in expected:
		if int(counts.get(key, 0)) != int(expected[key]):
			errors.append("%s %d/%d" % [key, int(counts.get(key, 0)), expected[key]])
	_check(errors.is_empty(), "every ACHR is an NpcReference and every ACRE a CreatureReference; their placement subrecords match census A1 and resolve (%s) [%d ms]" % [", ".join(errors.slice(0, 6)) if not errors.is_empty() else "all match", Time.get_ticks_msec() - started])

## The ActorReference FormID fields that are set but have no resolved resource.
func _unresolved_actor_reference_fields(actor: ActorReference) -> PackedStringArray:
	var unresolved := PackedStringArray()
	if actor.encounter_zone_form_id != 0 and actor.encounter_zone == null:
		unresolved.append("XEZN")
	if actor.merchant_container_form_id != 0 and actor.get_merchant_container() == null:
		unresolved.append("XMRC")
	var creature := actor as CreatureReference
	if creature != null and creature.owner_form_id != 0 and creature.owner == null:
		unresolved.append("XOWN")
	return unresolved

## FormID -> filing CELL, single-record placements, and editor-ID lookup.
func _check_reference_index(server, index: Array) -> void:
	var placed := 0
	for row: Dictionary in index:
		var record_type := String(row.get("record_type", ""))
		if record_type == "REFR" or record_type == "ACHR" or record_type == "ACRE":
			placed += 1
	_check(server._placed_reference_ids.size() == placed, "the reference index holds every placed REFR/ACHR/ACRE (%d of %d)" % [server._placed_reference_ids.size(), placed])

	# Filing CELL and single-record placement agree with the CELL walkers.
	var wasteland := int(server.reader.find_worldspace_by_editor_id("WastelandNV").get("form_id", 0))
	var compared := 0
	var cell_mismatch := 0
	var placement_mismatch := 0
	var cells: Array[int] = [int(server._persistent_cell_by_worldspace[wasteland])]
	for x in range(-24, -10):
		for y in range(-6, 8):
			var cell: int = server.get_exterior_cell_form_id(wasteland, Vector2i(x, y))
			if cell != 0:
				cells.append(cell)
	for cell in cells:
		for placement: Dictionary in server.reader.get_cell_references(cell) + server.reader.get_cell_actors(cell):
			var form_id := int(placement["refr_form_id"])
			compared += 1
			if server.get_filing_cell_form_id(form_id) != cell:
				cell_mismatch += 1
			if server.reader.get_reference_placement(form_id) != placement:
				placement_mismatch += 1
	_check(compared > 12000, "reference-index sample is substantial (%d references)" % compared)
	_check(cell_mismatch == 0, "every sampled reference's filing CELL matches the CELL that lists it (%d mismatched)" % cell_mismatch)
	_check(placement_mismatch == 0, "every sampled single-record placement equals the CELL walker's (%d mismatched)" % placement_mismatch)

	# Editor IDs named by real scripts.
	var doc: EsmReference = server.find_reference_by_editor_id("DocMitchellREF")
	_check(doc is ActorReference and doc.base.editor_id == "DocMitchell", "DocMitchellREF resolves to Doc Mitchell's actor")
	_check(server.find_reference_by_editor_id("docmitchellref") == doc, "editor-ID lookup is case-insensitive and cached")
	var marker: EsmReference = server.find_reference_by_editor_id("REPHQ2ndTeleport1")
	_check(marker != null and marker.current_space_form_id != 0, "REPHQ2ndTeleport1 (a MoveTo target) resolves with a location")
	_check(server.find_reference_by_editor_id("NoSuchReferenceEditorID") == null, "an unknown editor ID resolves to null")
	var quests := 0
	for row: Dictionary in index:
		if String(row.get("record_type", "")) == "QUST":
			quests += 1
	_check(server._quest_by_editor_id.size() == quests, "every QUST is indexed by editor ID (%d)" % quests)
	_check_quest_bases(server, index)
	_check_owner_conditions(server, index)
	_check_linked_references(server, index)
	_check_condition_parameters(server, index)
	_check_dialogue(server, index)
	_check_voice_types_and_quest_flags(server, index)
	var global_count := 0
	for row: Dictionary in index:
		if String(row.get("record_type", "")) == "GLOB":
			global_count += 1
	_check(server._global_by_editor_id.size() == global_count and global_count == 218, "every GLOB is indexed by editor ID (%d)" % global_count)
	var heal_timer: Dictionary = server.find_global_by_editor_id("cghealtimer")
	_check(String(heal_timer.get("type", "")) == "s" and is_equal_approx(float(heal_timer.get("value", 0.0)), 120.0),
			"CGHealTimer resolves case-insensitively as a short global of 120")
	_check(server.find_global_by_editor_id("NoSuchGlobal").is_empty(), "an unknown global resolves to {}")
	var repcon: EsmBase = server.find_quest_by_editor_id("repconhqfreeform")

	_check(repcon != null and repcon.record_type == "QUST" and repcon.editor_id.to_lower() == "repconhqfreeform" and repcon.script_form_id != 0,
			"RepconHQFreeform resolves, case-insensitively, to its QUST record (REPCONHQFreeform) with a script")

	# A reference filed in a worldspace persistent CELL builds from its own
	# record: time one nothing has built yet, outside WastelandNV.
	var freeside := int(server.reader.find_worldspace_by_editor_id("FreesideWorld").get("form_id", 0))
	var freeside_persistent := int(server._persistent_cell_by_worldspace.get(freeside, 0))
	var unbuilt := 0
	for i in server._placed_reference_ids.size():
		var id := "authored:%08X" % server._placed_reference_ids[i]
		if server._placed_reference_cells[i] == freeside_persistent and not server._authored_reference_cache.has(id):
			unbuilt = server._placed_reference_ids[i]
			break
	_check(unbuilt != 0, "FreesideWorld's persistent CELL has an unbuilt reference")
	var started := Time.get_ticks_usec()
	var built: EsmReference = server.get_reference("authored:%08X" % unbuilt)
	var elapsed_ms := (Time.get_ticks_usec() - started) / 1000.0
	_check(built != null and built.current_space_form_id == freeside, "it resolves into FreesideWorld")
	_check(elapsed_ms < 50.0, "building one persistent-CELL reference reads only its own record (%.1f ms)" % elapsed_ms)

## XTEL links and XLOC lock state across every base-game XTEL door.
func _check_door_links_and_locks(server) -> void:
	var doors: Array[DoorReference] = server.get_all_xtel_door_references()
	_check(doors.size() == 1108, "every FalloutNV.esm XTEL door has a link (%d)" % doors.size())
	var by_id := {}
	for door in doors:
		by_id[door.instance_id] = door
	var reciprocal := 0
	var destination_known := 0
	var landing_on_grid := 0
	var exterior_landings := 0
	var no_alarm := 0
	var locked := 0
	var locked_level_zero_keyless := 0
	for door in doors:
		var target: DoorReference = by_id.get(door.get_teleport_destination_id())
		if target != null:
			destination_known += 1
			if target.get_teleport_destination_id() == door.instance_id:
				reciprocal += 1
		var space := door.get_teleport_destination_space_form_id()
		if space != 0 and server._persistent_cell_by_worldspace.has(space):
			exterior_landings += 1
			if server.cell_at(space, door.teleport_position) != server._persistent_cell_by_worldspace[space]:
				landing_on_grid += 1
		if door.teleport_no_alarm:
			no_alarm += 1
		if door.is_locked:
			locked += 1
			if door.lock_level == 0 and door.lock_key_form_id == 0:
				locked_level_zero_keyless += 1
	_check(destination_known == doors.size(), "every XTEL destination is itself an XTEL door (%d)" % destination_known)
	_check(reciprocal == 1106, "1106 XTEL links lead to a door that leads straight back (%d)" % reciprocal)
	_check(exterior_landings == 491, "491 XTEL links land in a worldspace (%d)" % exterior_landings)
	_check(landing_on_grid == exterior_landings, "every worldspace landing lies on a grid CELL (%d of %d)" % [landing_on_grid, exterior_landings])
	_check(no_alarm == 0, "no base-game XTEL sets the no-alarm flag (%d)" % no_alarm)
	_check(locked == 65, "65 XTEL doors are locked (%d)" % locked)
	_check(locked_level_zero_keyless == 6, "6 locked XTEL doors are Very Easy with no key (%d)" % locked_level_zero_keyless)

	# One link resolved all the way to its destination door.
	var back_door: DoorReference = by_id.get("authored:0010901D")
	_check(back_door != null and back_door.is_locked and back_door.lock_level == 0, "Prospector Saloon back door (0010901D) is locked at Very Easy")
	var interior := int(server.reader.find_cell_by_editor_id("GSProspectorSaloonInterior").get("form_id", 0))
	var inside: DoorReference = back_door.get_teleport_destination() if back_door != null else null
	_check(inside != null and inside.instance_id == back_door.get_teleport_destination_id(), "the back door's link resolves its destination door")
	_check(inside != null and inside.current_space_form_id == interior and back_door.get_teleport_destination_space_form_id() == interior, "the back door lands in the saloon interior")
	_check(inside == null or inside == by_id.get(inside.instance_id), "a resolved destination is the shared cached DoorReference")

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
		for problem in _package_errors(package, raw):
			errors.append("0x%08X %s" % [form_id, problem])
		_check_package_events(form_id, raw, package, errors)
	_check(package_count > 0, "the shipped master contains PACK records")
	_check(errors.is_empty(), "all %d shipped PACK records populate their typed fields%s" % [package_count, "" if errors.is_empty() else ": " + "; ".join(errors.slice(0, 4))])

## Where `package` differs from its record `raw`.
func _package_errors(package: PackageBase, raw: Dictionary) -> PackedStringArray:
	var problems := PackedStringArray()
	var general := _subrecord(raw, "PKDT")
	if general.size() != 8 and general.size() != 12:
		problems.append("unexpected PKDT size %d" % general.size())
	elif package.general_flags != _u32(general) or package.package_type != _u8(general, 4):
		problems.append("PKDT general fields differ")
	elif general.size() == 12 and (package.fallout_behavior_flags != _u16(general, 6) or package.type_specific_flags != _u16(general, 8)):
		problems.append("PKDT FNV flag words differ")
	var schedule := _subrecord(raw, "PSDT")
	var schedule_matches := schedule.size() == 8 and package.schedule_month == _i8(schedule) \
			and package.schedule_day_of_week == _i8(schedule, 1) and package.schedule_date == _i8(schedule, 2) \
			and package.schedule_time == _i8(schedule, 3) and package.schedule_duration_hours == _u32(schedule, 4)
	if not schedule_matches:
		problems.append("PSDT fields differ")
	problems.append_array(_package_location_errors("PLDT", _subrecord(raw, "PLDT"), package.has_location_1, package.location_1_type, package.location_1_form_id, package.location_1_object, package.location_1_object_type, package.location_1_radius))
	problems.append_array(_package_location_errors("PLD2", _subrecord(raw, "PLD2"), package.has_location_2, package.location_2_type, package.location_2_form_id, package.location_2_object, package.location_2_object_type, package.location_2_radius))
	problems.append_array(_package_target_errors("PTDT", _subrecord(raw, "PTDT"), package.has_target_1, package.target_1_type, package.target_1_form_id, package.target_1_object, package.target_1_count_or_distance))
	problems.append_array(_package_target_errors("PTD2", _subrecord(raw, "PTD2"), package.has_target_2, package.target_2_type, package.target_2_form_id, package.target_2_object, package.target_2_count_or_distance))
	var raw_conditions := _all_subrecords(raw, "CTDA")
	if package.conditions.size() != raw_conditions.size():
		problems.append("CTDA count differs")
	else:
		for condition_index in raw_conditions.size():
			if not _condition_matches(package.conditions[condition_index], raw_conditions[condition_index]):
				problems.append("CTDA %d differs" % condition_index)
				break
	var idle_count := 0
	for idle_data in _all_subrecords(raw, "IDLA"):
		@warning_ignore("integer_division")
		idle_count += idle_data.size() / 4
	if package.idle_animations.size() != idle_count:
		problems.append("IDLA %d/%d resolved" % [package.idle_animations.size(), idle_count])
	var collection_count := _subrecord(raw, "IDLC")
	var expected_count := 0
	if collection_count.size() >= 4:
		expected_count = _u32(collection_count)
	elif collection_count.size() == 1:
		expected_count = _u8(collection_count)
	var collection_flags := _subrecord(raw, "IDLF")
	var collection_timer := _subrecord(raw, "IDLT")
	var expected_flags := _u8(collection_flags) if collection_flags.size() == 1 else 0
	var expected_timer := _f32(collection_timer) if collection_timer.size() == 4 else 0.0
	if package.idle_count != expected_count or package.idle_collection_flags != expected_flags or package.idle_timer != expected_timer:
		problems.append("IDLC/IDLF/IDLT differ")
	if package.combat_style_form_id != 0 and package.combat_style == null:
		problems.append("CNAM unresolved")
	var markers_match := package.has_eat_marker == _has_subrecord(raw, "PKED") \
			and package.has_use_item_marker == _has_subrecord(raw, "PUID") and package.has_ambush_marker == _has_subrecord(raw, "PKAM")
	if not markers_match:
		problems.append("marker fields differ")
	var use_weapon := _subrecord(raw, "PKW3")
	if package.has_use_weapon_data != (not use_weapon.is_empty()):
		problems.append("PKW3 presence differs")
	elif package.has_use_weapon_data and (package.use_weapon_flags != _u32(use_weapon) or package.use_weapon_pause_between_volleys_max != _f32(use_weapon, 16)):
		problems.append("PKW3 fields differ")
	var dialogue := _subrecord(raw, "PKDD")
	if package.has_dialogue_data != (not dialogue.is_empty()):
		problems.append("PKDD presence differs")
	elif package.has_dialogue_data:
		var dialogue_matches := package.dialogue_field_of_view == _f32(dialogue) and package.dialogue_topic_form_id == _u32(dialogue, 4) \
				and package.dialogue_flags == _u32(dialogue, 8) and package.dialogue_type == _u32(dialogue, 16)
		if not dialogue_matches:
			problems.append("PKDD fields differ")
		elif package.dialogue_topic_form_id != 0 and package.dialogue_topic == null:
			problems.append("PKDD topic unresolved")
	return problems

## A PLDT / PLD2 against its subrecord `data`: present when the subrecord is;
## type and radius match; the named FormID kept for reference, cell and object
## kinds; an Object ID resolved; an Object Type decoded.
func _package_location_errors(tag: String, data: PackedByteArray, present: bool, type: int, form_id: int, object: EsmBase, object_type: int, radius: int) -> PackedStringArray:
	if present != (not data.is_empty()):
		return PackedStringArray(["%s presence differs" % tag])
	if not present:
		return PackedStringArray()
	var value := _u32(data, 4)
	var names_record := type == PackageBase.LocationType.NEAR_REFERENCE or type == PackageBase.LocationType.IN_CELL or type == PackageBase.LocationType.OBJECT_ID
	if type != _i32(data) or radius != _i32(data, 8) or form_id != (value if names_record else 0):
		return PackedStringArray(["%s fields differ" % tag])
	if type == PackageBase.LocationType.OBJECT_ID and (object == null or object.form_id != value):
		return PackedStringArray(["%s object unresolved" % tag])
	if type == PackageBase.LocationType.OBJECT_TYPE and object_type != value:
		return PackedStringArray(["%s object type differs" % tag])
	return PackedStringArray()

## A PTDT / PTD2 against its subrecord `data`, as for locations.
func _package_target_errors(tag: String, data: PackedByteArray, present: bool, type: int, form_id: int, object: EsmBase, count_or_distance: int) -> PackedStringArray:
	if present != (not data.is_empty()):
		return PackedStringArray(["%s presence differs" % tag])
	if not present:
		return PackedStringArray()
	var value := _u32(data, 4)
	var names_record := type == PackageBase.TargetType.SPECIFIC_REFERENCE or type == PackageBase.TargetType.OBJECT_ID
	if type != _i32(data) or count_or_distance != _i32(data, 8) or form_id != (value if names_record else 0):
		return PackedStringArray(["%s fields differ" % tag])
	if type == PackageBase.TargetType.OBJECT_ID and (object == null or object.form_id != value):
		return PackedStringArray(["%s object unresolved" % tag])
	return PackedStringArray()

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
		var event: PackageEventCollection = event_data[1]
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

## ARMO DATA, DNAM, BMDT and ETYP on authored armour: the combat armour's
## value, weight and DT; a DR in hundredths; a power armour helmet whose DNAM
## Modulates Voice flag must not leak into its DR; a hat's slots and type.
func _check_armor_fields(server) -> void:
	var combat := server.find_base_by_editor_id("ArmorCombatReinforcedMark2") as ArmorBase
	_check(combat != null and combat.value == 8000 and is_equal_approx(combat.weight, 25.0), "ArmorCombatReinforcedMark2 reads DATA value 8000 and weight 25")
	_check(combat != null and combat.damage_threshold == 20 and combat.armor_rating == 0, "ArmorCombatReinforcedMark2 reads DNAM DT 20 and DR 0")
	_check(combat != null and combat.equipment_type == ArmorBase.EQUIPMENT_TYPE_BODY_WEAR, "ArmorCombatReinforcedMark2 is Body Wear")
	var trooper := server.find_base_by_editor_id("DamWarTrooper") as ArmorBase
	_check(trooper != null and trooper.armor_rating == 20, "DamWarTrooper reads DNAM DR 2000 as 20 percent")
	var helmet := server.find_base_by_editor_id("ArmorPowerT51bHelmet") as ArmorBase
	_check(helmet != null and helmet.armor_rating == 0, "ArmorPowerT51bHelmet's Modulates Voice flag stays out of its DR")
	var hat := server.find_base_by_editor_id("CowboyHat03") as ArmorBase
	_check(hat != null and hat.equipment_type == ArmorBase.EQUIPMENT_TYPE_HEAD_WEAR, "CowboyHat03 is Head Wear")
	_check(hat != null and hat.biped_flags == ArmorBase.BIPED_HAIR | ArmorBase.BIPED_HEADBAND | ArmorBase.BIPED_HAT, "CowboyHat03 covers Hair, Headband and Hat")

func _check_hair_and_head_part_fields(server, index: Array) -> void:
	var hair_count := 0
	var hair_with_texture := 0
	var head_part_count := 0
	var head_parts_with_model := 0
	var extra_part_count := 0
	var unresolved_extra_parts := 0
	for row: Dictionary in index:
		var record_type := String(row.get("record_type", ""))
		if record_type == "HAIR":
			hair_count += 1
			var hair := server.get_base(int(row["form_id"])) as HairBase
			if hair != null and hair.texture_path.to_lower().ends_with(".dds"):
				hair_with_texture += 1
		elif record_type == "HDPT":
			head_part_count += 1
			var head_part := server.get_base(int(row["form_id"])) as HeadPartBase
			if head_part == null:
				continue
			if not head_part.model_path.is_empty():
				head_parts_with_model += 1
			extra_part_count += head_part.extra_part_form_ids.size()
			unresolved_extra_parts += head_part.extra_part_form_ids.size() - head_part.extra_parts.size()
	_check(hair_count == 67 and hair_with_texture == 67, "every HAIR reads an ICON texture (%d of %d)" % [hair_with_texture, hair_count])
	_check(head_part_count == 61 and head_parts_with_model == 46, "46 of 61 HDPT read a MODL (%d of %d)" % [head_parts_with_model, head_part_count])
	_check(extra_part_count == 33 and unresolved_extra_parts == 0, "33 HDPT HNAM extra parts read and resolved (%d, %d unresolved)" % [extra_part_count, unresolved_extra_parts])

	var balding := server.find_base_by_editor_id("HairBalding") as HairBase
	_check(balding != null and balding.model_path.to_lower() == "characters\\hair\\hairbase.nif", "HairBalding uses HairBase.NIF")
	_check(balding != null and balding.texture_path.to_lower() == "characters\\hair\\hairbalding.dds", "HairBalding reads its own ICON texture")
	var curly := server.find_base_by_editor_id("HairCurlyF") as HairBase
	_check(curly != null and curly.flags == HairBase.FLAG_PLAYABLE | HairBase.FLAG_NOT_MALE, "HairCurlyF is Playable and Not Male")
	var brow := server.find_base_by_editor_id("EyebrowM") as HeadPartBase
	_check(brow != null and not brow.model_path.is_empty() and brow.extra_parts.is_empty(), "EyebrowM reads a MODL and no extra parts")
	var mix := server.find_base_by_editor_id("BeardMix01a") as HeadPartBase
	var mix_parts: PackedStringArray = []
	if mix != null:
		for part in mix.extra_parts:
			mix_parts.append(part.editor_id)
	_check(mix != null and mix.model_path.is_empty() and mix_parts == PackedStringArray(["BeardMustacheThin", "BeardGoateeThin"]),
		"BeardMix01a has no MODL and resolves its extra parts (%s)" % [mix_parts])

func _check_texture_sets(server, index: Array) -> void:
	var texture_set_count := 0
	var field_errors: PackedStringArray = []
	for row: Dictionary in index:
		if String(row.get("record_type", "")) != "TXST":
			continue
		texture_set_count += 1
		var form_id := int(row["form_id"])
		var texture_set := server.get_base(form_id) as TextureSetBase
		if texture_set == null:
			field_errors.append("%08X type" % form_id)
			continue
		var raw: Dictionary = server.reader.get_record_data(form_id)
		var expected := [_string(_subrecord(raw, "TX00")), _string(_subrecord(raw, "TX01")), _string(_subrecord(raw, "TX02")),
			_string(_subrecord(raw, "TX03")), _string(_subrecord(raw, "TX04")), _string(_subrecord(raw, "TX05"))]
		var actual := [texture_set.diffuse_path, texture_set.normal_path, texture_set.environment_mask_path,
			texture_set.glow_path, texture_set.parallax_path, texture_set.environment_path]
		if actual != expected and field_errors.size() < 5:
			field_errors.append("%08X TXnn" % form_id)
	_check(texture_set_count == 493 and field_errors.is_empty(), "every TXST reads its TX00-TX05 (%d, errors %s)" % [texture_set_count, field_errors])

	var counts := {}
	var entry_count := 0
	var unresolved := 0
	for row: Dictionary in index:
		var record_type := String(row.get("record_type", ""))
		if not record_type in ["ACTI", "ARMA", "ARMO", "DOOR", "HDPT", "STAT", "TERM", "WEAP"]:
			continue
		var base: EsmBase = server.get_base(int(row["form_id"]))
		for entries in _alternate_texture_lists(base):
			if entries.is_empty():
				continue
			counts[record_type] = int(counts.get(record_type, 0)) + 1
			for entry: AlternateTextureCollection in entries:
				entry_count += 1
				if entry.texture_set == null:
					unresolved += 1
	var expected_counts := {"ACTI": 12, "ARMA": 7, "ARMO": 162, "DOOR": 21, "HDPT": 26, "STAT": 289, "TERM": 14, "WEAP": 1}
	_check(counts == expected_counts, "Alternate Textures subrecords per record type match the census (%s)" % [counts])
	_check(entry_count == 1838 and unresolved == 0, "all 1838 Alternate Textures entries resolve to a TXST (%d, %d unresolved)" % [entry_count, unresolved])

	var circle := server.find_base_by_editor_id("BeardGoateeCircle") as HeadPartBase
	var entry: AlternateTextureCollection = circle.alternate_textures[0] if circle != null and circle.alternate_textures.size() == 1 else null
	_check(entry != null and entry.shape_name == "BeardGoatee:0" and entry.shape_index == 0, "BeardGoateeCircle swaps shape BeardGoatee:0, index 0")
	var beard_set: TextureSetBase = entry.texture_set if entry != null else null
	_check(beard_set != null and beard_set.editor_id == "BeardCircleT", "BeardGoateeCircle's swap resolves to BeardCircleT")
	_check(beard_set != null and beard_set.diffuse_path == "Characters\\Hair\\BeardCircle.dds" and beard_set.glow_path == "Characters\\Hair\\BeardCircle_hl.dds",
		"BeardCircleT reads TX00 and TX03")
	var curly := server.find_base_by_editor_id("BeardMustacheCurlyFull") as HeadPartBase
	var indices: Array[int] = []
	if curly != null:
		for curly_entry in curly.alternate_textures:
			indices.append(curly_entry.shape_index)
	_check(indices == [-1, 0], "BeardMustacheCurlyFull reads 3D indices -1 and 0 (%s)" % [indices])

## The Alternate Textures lists a record carries, one per model.
func _alternate_texture_lists(base: EsmBase) -> Array:
	if base is ArmorBase:
		var armor: ArmorBase = base
		return [armor.male_biped_alternate_textures, armor.male_world_alternate_textures,
			armor.female_biped_alternate_textures, armor.female_world_alternate_textures]
	if base is ArmorAddonBase:
		var addon: ArmorAddonBase = base
		return [addon.male_biped_alternate_textures, addon.female_biped_alternate_textures]
	if base is ActivatorBase:
		return [(base as ActivatorBase).alternate_textures]
	if base is DoorBase:
		return [(base as DoorBase).alternate_textures]
	if base is HeadPartBase:
		return [(base as HeadPartBase).alternate_textures]
	if base is StaticBase:
		return [(base as StaticBase).alternate_textures]
	if base is TerminalBase:
		return [(base as TerminalBase).alternate_textures]
	if base is WeaponBase:
		return [(base as WeaponBase).alternate_textures]
	return []

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
			_check(not reference.has_teleport or not reference.get_teleport_destination_id().is_empty(), "DoorReference XTEL link names its destination")
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
	_check_activation(get_node("/root/EsmServer"), get_node("/root/ScriptServer"))
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

## Built-in activation of doors, furniture and terminals, and script gating.
func _check_activation(esm_server, script_server) -> void:
	var interior := int(esm_server.reader.find_cell_by_editor_id("GSDocMitchellHouse").get("form_id", 0))
	var plain_door: DoorReference = null
	var load_door: DoorReference = null
	var actors: Array[ActorReference] = []
	for reference in esm_server.get_references_in_cell(interior):
		if reference is DoorReference and not reference.is_locked:
			if not reference.has_teleport and plain_door == null:
				plain_door = reference
			elif reference.has_teleport and load_door == null:
				load_door = reference
		elif reference is ActorReference:
			actors.append(reference)
	var actor := NpcReference.new()
	actor.instance_id = "test:actor"
	actor.contents = Inventory.new()
	var other_actor := NpcReference.new()
	other_actor.instance_id = "test:other"

	# A plain door toggles with no node loaded.
	_check(plain_door != null and EsmNode.node_for(plain_door) == null, "GSDocMitchellHouse has an unloaded plain door")
	if plain_door != null:
		var was_open := plain_door.is_open
		script_server.activate(plain_door, actor)
		_check(plain_door.is_open != was_open, "activating a plain door with no node toggles is_open")
		script_server.activate(plain_door, actor)

	# A load door queues a move of the activator to its landing.
	_check(load_door != null, "GSDocMitchellHouse has an unlocked load door")
	if load_door != null:
		script_server.activate(load_door, actor)
		var move: Dictionary = script_server.get_pending_move(actor)
		_check(int(move.get("space_form_id", 0)) == load_door.get_teleport_destination_space_form_id()
				and move.get("position") == load_door.teleport_position and move.get("rotation") == load_door.teleport_rotation,
				"activating a load door queues the activator's move to its landing")

	# Locks, over every locked XTEL door.
	var keyed: DoorReference = null
	var requires_key: DoorReference = null
	var pickable: DoorReference = null
	var player_only: Array[DoorReference] = []
	for door: DoorReference in esm_server.get_all_xtel_door_references():
		if door.base != null and door.base.form_id == 0x000463CE:
			player_only.append(door)
		if not door.is_locked:
			continue
		if door.lock_key != null and keyed == null:
			keyed = door
		elif door.lock_key == null and door.lock_level >= 255 and requires_key == null:
			requires_key = door
		elif door.lock_key == null and door.lock_level < 255 and pickable == null:
			pickable = door
	_check(keyed != null and requires_key != null and pickable != null, "locked XTEL doors cover keyed, key-only and pickable locks")
	if keyed != null:
		script_server.activate(keyed, other_actor)
		var expected_use: DoorReference = keyed if keyed.lock_level < 255 else null
		_check(keyed.is_locked and script_server.get_pending_move(other_actor).is_empty() and other_actor.using == expected_use,
				"a keyed door without its key stays locked (lockpicking below level 255)")
		script_server.end_use(other_actor)
		actor.contents.add_item(keyed.lock_key.form_id)
		script_server.activate(keyed, actor)
		_check(not keyed.is_locked and int(script_server.get_pending_move(actor).get("space_form_id", 0)) == keyed.get_teleport_destination_space_form_id(),
				"carrying the key unlocks the door and goes through it")
		script_server.lock(keyed)
	if requires_key != null:
		script_server.activate(requires_key, other_actor)
		_check(requires_key.is_locked and other_actor.using == null and script_server.get_pending_move(other_actor).is_empty(),
				"a level-255 lock without its key does nothing")
	if pickable != null:
		script_server.activate(pickable, other_actor)
		_check(other_actor.using == pickable and pickable.used_by == other_actor, "a pickable lock makes the activator use the door")
		script_server.end_use(other_actor)
		_check(other_actor.using == null and pickable.used_by == null, "end_use clears both sides")

	# `Begin OnActivate Player / Activate`: the player goes through by script,
	# anyone else through the built-in activation.
	_check(player_only.size() == 24, "24 IndDoorSmAnim01 load doors (%d)" % player_only.size())
	player_only = player_only.filter(func(d: DoorReference) -> bool: return not d.is_locked)
	if not player_only.is_empty():
		var door := player_only[0]
		script_server.player_reference = actor
		script_server.activate(door, actor)
		_check(int(script_server.get_pending_move(actor).get("space_form_id", 0)) == door.get_teleport_destination_space_form_id(),
				"the player goes through an OnActivate Player door via its script")
		script_server.activate(door, other_actor)
		_check(int(script_server.get_pending_move(other_actor).get("space_form_id", 0)) == door.get_teleport_destination_space_form_id(),
				"another actor goes through it via the built-in activation")
		script_server.player_reference = null

	# Script `Activate` performs the built-in activation without re-running OnActivate.
	if plain_door != null:
		var was_open := plain_door.is_open
		var program := ScriptParser.new(ScriptLexer.new("begin GameMode\nActivate\nend").tokenize()).parse()
		var ctx := ScriptExecutionContext.new(plain_door)
		ctx.action_ref = actor
		ScriptInterpreter.new(program, script_server.function_registry).run_block("GameMode", ctx)
		_check(plain_door.is_open != was_open, "script Activate runs the target's built-in activation")
		script_server.default_activate(plain_door, actor)

	# Furniture with two active markers seats two actors, then refuses a third.
	var bench: FurnitureBase = null
	for row in esm_server.get_record_index():
		if String(row.get("record_type", "")) == "FURN":
			var base := esm_server.get_base(int(row["form_id"])) as FurnitureBase
			if base != null and base.get_active_markers().size() == 2:
				bench = base
				break
	_check(bench != null, "a FURN base has exactly two active markers")
	if bench != null:
		var seat := FurnitureReference.new()
		seat.base = bench
		var third := NpcReference.new()
		script_server.activate(seat, actor)
		script_server.activate(seat, other_actor)
		script_server.activate(seat, third)
		_check(actor.using == seat and other_actor.using == seat and actor.using_marker != other_actor.using_marker,
				"two actors sit at different markers of one piece of furniture")
		_check(third.using == null, "a third actor finds no free marker")
		script_server.end_use(actor)
		script_server.activate(seat, third)
		_check(third.using == seat and third.using_marker == bench.get_active_markers()[0], "a freed marker can be taken")
		script_server.end_use(other_actor)
		script_server.end_use(third)

	# A terminal has one user at a time.
	var terminal := TerminalReference.new()
	terminal.base = esm_server.get_base(0x00166B56)
	var used_signals: Array = []
	actor.using_changed.connect(func(previous, current): used_signals.append([previous, current]))
	script_server.activate(terminal, actor)
	script_server.activate(terminal, other_actor)
	_check(actor.using == terminal and terminal.used_by == actor and other_actor.using == null, "a terminal has one user")
	script_server.end_use(actor)
	_check(used_signals == [[null, terminal], [terminal, null]], "using_changed reports start and end of use")

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
		get_node("/root/ScriptServer").default_activate(reference, null)
		_check(not reference.is_open and player.current_animation == "Close" and player.is_playing(),
			"first activation of an authored-open gate plays Close")
		player.stop()
		var picker := NpcReference.new()
		reference.is_locked = true
		get_node("/root/ScriptServer").default_activate(reference, picker)
		_check(not player.is_playing() and not reference.is_open and picker.using == reference,
			"activating it locked starts lockpicking and plays nothing")
		get_node("/root/ScriptServer").end_use(picker)
		reference.is_locked = false
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
					_check(terminal.menu_items[0] is TerminalMenuItemCollection, "TERM menu entries use the typed convenience resource")
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
			var entry: LeveledItemEntryCollection = list.entries[0]
			_check(entry.item_form_id != 0, "LVLI entry exposes referenced FormID")
			_check(entry.item_base == server.get_base(entry.item_form_id), "LVLI entry reuses cached item Base")
		break
	_check(found, "a real LVLI resolves as LeveledItemBase")
	if not found:
		return

	var synthetic := LeveledItemBase.new()
	synthetic.form_id = 0x7FFF0001
	var first := LeveledItemEntryCollection.new()
	first.level = 1
	first.item_form_id = 0x000E3778
	first.item_base = server.get_base(first.item_form_id)
	first.count = 2
	var second := LeveledItemEntryCollection.new()
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

## Whether the record carries subrecord `tag`, including an empty marker
## (PKED, PUID, PKAM, XIBS).
func _has_subrecord(raw: Dictionary, tag: String) -> bool:
	for sub in raw.get("subrecords", []):
		if String(sub.get("type", "")) == tag:
			return true
	return false

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


## Whether a ConditionSubrecord holds exactly the fields of its raw CTDA bytes.
func _condition_matches(condition: ConditionSubrecord, data: PackedByteArray) -> bool:
	if condition == null:
		return false
	var type := _u8(data)
	if condition.comparison != (type >> 5) or condition.flags != (type & 0x1F) or condition.function_index != _u16(data, 8) \
			or condition.parameter_1 != _u32(data, 12) or condition.parameter_2 != _u32(data, 16) or condition.has_run_on != (data.size() >= 24):
		return false
	if condition.uses_global() and condition.comparison_global_form_id != _u32(data, 4):
		return false
	if not condition.uses_global() and not is_equal_approx(condition.comparison_value, _f32(data, 4)) and not is_nan(_f32(data, 4)):
		return false
	if data.size() >= 24 and condition.run_on != _u32(data, 20):
		return false
	return data.size() < 28 or condition.reference_form_id == _u32(data, 24)


## Every CTDA on QUST, TERM and MESG records becomes a ConditionSubrecord on its owner,
## in order, field for field: 1501 on QUST (quest, log entry and objective
## target conditions), 405 on TERM menu items and 259 on MESG buttons in
## FalloutNV.esm.
func _check_owner_conditions(server, index: Array) -> void:
	var totals := {"QUST": 0, "TERM": 0, "MESG": 0}
	var mismatches: Array[String] = []
	for row: Dictionary in index:
		var type := String(row.get("record_type", ""))
		if not totals.has(type):
			continue
		var base: EsmBase = server.get_base(int(row["form_id"]))
		var parsed: Array[ConditionSubrecord] = []
		if base is QuestBase:
			parsed.append_array(base.conditions)
			for stage: QuestStageCollection in base.stages:
				for entry: QuestLogEntryCollection in stage.log_entries:
					parsed.append_array(entry.conditions)
			for objective: QuestObjectiveCollection in base.objectives:
				for target: QuestObjectiveTargetCollection in objective.targets:
					parsed.append_array(target.conditions)
		elif base is TerminalBase:
			for item: TerminalMenuItemCollection in base.menu_items:
				parsed.append_array(item.conditions)
		elif base is MessageBase:
			for button: MessageButtonCollection in base.buttons:
				parsed.append_array(button.conditions)
		var raw: Array = server.reader.get_record_data(int(row["form_id"])).get("subrecords", [])
		var raw_conditions: Array[PackedByteArray] = []
		for sub: Dictionary in raw:
			if String(sub.get("type", "")) == "CTDA":
				raw_conditions.append(sub["data"])
		totals[type] += parsed.size()
		if parsed.size() != raw_conditions.size():
			mismatches.append("%s 0x%08X: %d parsed, %d CTDA" % [type, base.form_id, parsed.size(), raw_conditions.size()])
			continue
		for i in parsed.size():
			if not _condition_matches(parsed[i], raw_conditions[i]):
				mismatches.append("%s 0x%08X CTDA %d differs" % [type, base.form_id, i])
				break
	_check(mismatches.is_empty() and totals["QUST"] == 1501 and totals["TERM"] == 405 and totals["MESG"] == 259,
			"every QUST, TERM and MESG CTDA is a ConditionSubrecord on its owner, field for field (%s; %s)" % [totals, mismatches.slice(0, 3)])


## XLKR reaches the reference: placed terminal REFR 00143990 is linked to
## 0013DC47 (terminal_link_census.cpp: all 4 placed terminals whose base has
## linked-reference conditions carry an XLKR).
func _check_linked_references(server, _index: Array) -> void:
	var terminal: EsmReference = server.get_reference("authored:00143990")
	_check(terminal != null and terminal.linked_reference_form_id == 0x0013DC47,
			"a placed reference carries its XLKR linked reference (%s)" % ("0x%08X" % terminal.linked_reference_form_id if terminal != null else "missing"))


## Every parsed condition (PACK, QUST, TERM, MESG) names a known function, and each
## parameter resolves to the kind its xEdit type says: a reference, a base
## resource, or an int. A FormID parameter naming nothing is counted.
func _check_condition_parameters(server, index: Array) -> void:
	var conditions: Array[ConditionSubrecord] = []
	for row: Dictionary in index:
		var type := String(row.get("record_type", ""))
		if type != "PACK" and type != "QUST" and type != "TERM" and type != "MESG":
			continue
		var base: EsmBase = server.get_base(int(row["form_id"]))
		if base is PackageBase:
			conditions.append_array(base.conditions)
		elif base is QuestBase:
			conditions.append_array(base.conditions)
			for stage: QuestStageCollection in base.stages:
				for entry: QuestLogEntryCollection in stage.log_entries:
					conditions.append_array(entry.conditions)
			for objective: QuestObjectiveCollection in base.objectives:
				for target: QuestObjectiveTargetCollection in objective.targets:
					conditions.append_array(target.conditions)
		elif base is TerminalBase:
			for item: TerminalMenuItemCollection in base.menu_items:
				conditions.append_array(item.conditions)
		elif base is MessageBase:
			for button: MessageButtonCollection in base.buttons:
				conditions.append_array(button.conditions)
	var unknown := {}
	var wrong_kind: Array[String] = []
	var unresolved := 0
	for condition in conditions:
		var function_name := ScriptConditionFunctions.name_for_index(condition.function_index)
		if function_name.is_empty():
			unknown[condition.function_index] = true
			continue
		var types: Array = ScriptConditionFunctions.BY_INDEX[condition.function_index][1]
		var values := ScriptConditionFunctions.resolve_parameters(condition)
		for i in types.size():
			var kind := String(types[i])
			var value: Variant = values[i]
			var raw: int = condition.parameter_1 if i == 0 else condition.parameter_2
			if ScriptConditionFunctions.INTEGER_PARAMETERS.has(kind) or ScriptConditionFunctions.FORM_ID_PARAMETERS.has(kind):
				if not value is int:
					wrong_kind.append("%s %s" % [function_name, kind])
			elif value == null:
				unresolved += int(raw != 0)
			elif ScriptConditionFunctions.REFERENCE_PARAMETERS.has(kind) and not value is EsmReference:
				wrong_kind.append("%s %s" % [function_name, kind])
			elif ScriptConditionFunctions.BASE_PARAMETERS.has(kind) and not value is EsmBase:
				wrong_kind.append("%s %s" % [function_name, kind])
	_check(unknown.is_empty() and wrong_kind.is_empty(),
			"every PACK/QUST/TERM/MESG condition names a known function with parameters of its xEdit kind (%d conditions; unknown %s; wrong %s; %d FormID parameters name nothing)"
			% [conditions.size(), unknown.keys(), wrong_kind.slice(0, 3), unresolved])
	var get_stage: Variant = ScriptConditionFunctions.resolve_parameter("ptQuest", server.find_quest_by_editor_id("VCG01").form_id)
	_check(get_stage is QuestBase and get_stage.editor_id == "VCG01", "a quest parameter resolves to its QuestBase")
	_check(ScriptConditionFunctions.resolve_parameter("ptReference", 0x14) == server.get_player_reference(), "reference 0x14 resolves to the player's reference")


## Every DIAL and INFO parses field for field against its raw subrecords, and
## the totals match dialogue_census.cpp: 18,215 topics holding 23,247 INFOs in
## file order, 29,674 responses, 59,664 conditions, 2,827 begin and 4,544 end
## scripts, and the INFOs with links, prompts and speakers.
func _check_dialogue(server, index: Array) -> void:
	var topics := 0
	var infos_in_topics := 0
	var totals := {"responses": 0, "conditions": 0, "begin": 0, "end": 0, "link_to": 0, "link_from": 0,
			"follow_up": 0, "add_topics": 0, "prompt": 0, "speaker": 0}
	var mismatches: Array[String] = []
	for row: Dictionary in index:
		if String(row.get("record_type", "")) != "DIAL":
			continue
		topics += 1
		var topic: DialogueTopicBase = server.get_base(int(row["form_id"]))
		var raw_topic: Dictionary = server.reader.get_record_data(topic.form_id)
		var topic_data := PackedByteArray()
		var raw_quests: Array[int] = []
		for sub: Dictionary in raw_topic.get("subrecords", []):
			match String(sub.get("type", "")):
				"DATA": topic_data = sub["data"]
				"QSTI": raw_quests.append(_u32(sub["data"]))
		if topic.topic_type != _u8(topic_data) or topic.flags != _u8(topic_data, 1) or topic.quest_form_ids != raw_quests:
			mismatches.append("DIAL 0x%08X" % topic.form_id)
		for info: DialogueInfoBase in topic.infos:
			infos_in_topics += 1
			if info.topic_form_id != topic.form_id:
				mismatches.append("INFO 0x%08X topic" % info.form_id)
			var problem := _dialogue_info_mismatch(server, info, totals)
			if not problem.is_empty():
				mismatches.append("INFO 0x%08X %s" % [info.form_id, problem])
	_check(topics == 18215 and infos_in_topics == 23247, "18,215 topics hold the 23,247 INFOs (%d, %d)" % [topics, infos_in_topics])
	_check(mismatches.is_empty(), "every DIAL and INFO matches its raw subrecords (%d mismatches: %s)" % [mismatches.size(), mismatches.slice(0, 3)])
	_check(totals == {"responses": 29674, "conditions": 59664, "begin": 2827, "end": 4544, "link_to": 6348, "link_from": 645,
			"follow_up": 1107, "add_topics": 420, "prompt": 1411, "speaker": 11355}, "INFO totals match the census (%s)" % [totals])

	var intro: DialogueTopicBase = server.find_base_by_editor_id("VCG01Intro")
	var all_say_once := true
	for info in intro.infos:
		all_say_once = all_say_once and info.has_flag(DialogueInfoBase.FLAG_SAY_ONCE)
	_check(intro.topic_type == DialogueTopicBase.Type.CONVERSATION and intro.infos.size() == 15 and intro.infos[0].form_id == 0x00104BEE and all_say_once,
			"VCG01Intro is a Conversation topic of 15 Say Once INFOs, 00104BEE first")
	var first: DialogueInfoBase = intro.infos[0]
	_check(first.quest != null and first.quest.editor_id == "VCG01" and first.responses[0].text.begins_with("You're awake")
			and first.end_script_source.contains("SetStage VCG01 5"), "its first INFO says \"You're awake\" and sets VCG01 stage 5")

## What differs between `info` and its raw subrecords, or "" when nothing does.
## Adds the INFO's counts to `totals`.
func _dialogue_info_mismatch(server, info: DialogueInfoBase, totals: Dictionary) -> String:
	var raw: Array = server.reader.get_record_data(info.form_id).get("subrecords", [])
	var texts: Array[String] = []
	var numbers: Array[int] = []
	var conditions: Array[PackedByteArray] = []
	var lists := {"TCLT": [] as Array[int], "TCLF": [] as Array[int], "TCFU": [] as Array[int], "NAME": [] as Array[int]}
	var begin_script := ""
	var end_script := ""
	var after_next := false
	var data := PackedByteArray()
	var prompt := ""
	var speaker := 0
	var quest := 0
	for sub: Dictionary in raw:
		var tag := String(sub.get("type", ""))
		var bytes: PackedByteArray = sub.get("data", PackedByteArray())
		match tag:
			"DATA": data = bytes
			"QSTI": quest = _u32(bytes)
			"TRDT": numbers.append(_u8(bytes, 12))
			"NAM1": texts.append(_string(bytes))
			"CTDA": conditions.append(bytes)
			"TCLT", "TCLF", "TCFU", "NAME": lists[tag].append(_u32(bytes))
			"NEXT": after_next = true
			"SCTX":
				if after_next: end_script = _string(bytes)
				else: begin_script = _string(bytes)
			"RNAM": prompt = _string(bytes)
			"ANAM": speaker = _u32(bytes)
	var parsed_texts: Array[String] = []
	var parsed_numbers: Array[int] = []
	for response in info.responses:
		parsed_texts.append(response.text)
		parsed_numbers.append(response.response_number)
	totals["responses"] += info.responses.size()
	totals["conditions"] += info.conditions.size()
	totals["begin"] += int(not info.begin_script_source.is_empty())
	totals["end"] += int(not info.end_script_source.is_empty())
	totals["link_to"] += int(not info.link_to_form_ids.is_empty())
	totals["link_from"] += int(not info.link_from_form_ids.is_empty())
	totals["follow_up"] += int(not info.follow_up_form_ids.is_empty())
	totals["add_topics"] += int(not info.add_topic_form_ids.is_empty())
	totals["prompt"] += int(not info.prompt.is_empty())
	totals["speaker"] += int(info.speaker_form_id != 0)
	if parsed_texts != texts or parsed_numbers != numbers:
		return "responses"
	if info.conditions.size() != conditions.size():
		return "condition count"
	for i in conditions.size():
		if not _condition_matches(info.conditions[i], conditions[i]):
			return "condition %d" % i
	if info.link_to_form_ids != lists["TCLT"] or info.link_from_form_ids != lists["TCLF"] or info.follow_up_form_ids != lists["TCFU"] or info.add_topic_form_ids != lists["NAME"]:
		return "links"
	if info.begin_script_source != begin_script or info.end_script_source != end_script:
		return "scripts"
	if info.flags != _u8(data, 2) or info.flags_2 != _u8(data, 3) or info.info_type != _u8(data) or info.quest_form_id != quest:
		return "data"
	if info.prompt != prompt or info.speaker_form_id != speaker:
		return "prompt or speaker"
	return ""

## Voice types: VTCK on every NPC_ (3,816) and 1,045 of 1,578 CREA; Doc
## Mitchell's is MaleUniqueDocMitchell, whose folder holds his voice files. QUST
## DATA flags: Allow Repeated Conversation Topics on 94 quests, Allow Repeated
## Stages on 34, Default Script Processing Delay on 282.
func _check_voice_types_and_quest_flags(server, index: Array) -> void:
	var voiced := {"NPC_": 0, "CREA": 0}
	var quest_flags := {"topics": 0, "stages": 0, "delay": 0}
	for row: Dictionary in index:
		var type := String(row.get("record_type", ""))
		if type == "NPC_" or type == "CREA":
			voiced[type] += int(server.get_base(int(row["form_id"])).voice_type_form_id != 0)
		elif type == "QUST":
			var quest: QuestBase = server.get_base(int(row["form_id"]))
			quest_flags["topics"] += int(quest.allows_repeated_topics)
			quest_flags["stages"] += int(quest.allows_repeated_stages)
			quest_flags["delay"] += int(quest.uses_default_script_delay)
	_check(voiced == {"NPC_": 3816, "CREA": 1045}, "VTCK on every NPC_ and 1,045 CREA (%s)" % [voiced])
	var doc: NpcBase = server.find_base_by_editor_id("DocMitchell")
	var voice: EsmBase = server.get_base(doc.voice_type_form_id)
	_check(voice != null and voice.editor_id == "MaleUniqueDocMitchell", "Doc Mitchell's voice type is MaleUniqueDocMitchell (%s)" % (voice.editor_id if voice != null else "none"))
	_check(quest_flags == {"topics": 94, "stages": 34, "delay": 282}, "QUST DATA flags match the census (%s)" % [quest_flags])
