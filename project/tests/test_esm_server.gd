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
	_check_xemi_reference_fields(server)
	await _check_xemi_visual_tint(server)
	_check_reference_location(server)
	_check_door_links_and_locks(server)
	_check_reference_index(server, index)
	_check_base_scripts(server, index)
	_check_package_bases(server, index)
	_check_typed_container_inventory(server, index)
	_check_inventory_contract(server)
	_check_armor_slot_conflicts()
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

## The player's reference is one canonical ActorReference.
func _check_player_reference(server) -> void:
	var player: ActorReference = server.get_player_reference()
	_check(player != null and player.base is NpcBase and player.base.form_id == 0x7, "the player reference is an ActorReference on the Player NPC_ record")
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
				counts["complete"] += int((entry.flags & QuestLogEntry.FLAG_COMPLETE_QUEST) != 0)
				counts["fail"] += int((entry.flags & QuestLogEntry.FLAG_FAIL_QUEST) != 0)
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
				counts["flag_01"] += int(target.flags == QuestObjectiveTarget.FLAG_COMPASS_MARKER_IGNORES_LOCKS)
				counts["other_flags"] += int(target.flags > QuestObjectiveTarget.FLAG_COMPASS_MARKER_IGNORES_LOCKS)
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
		if base != null and base.script_form_id != 0:
			scripted[record_type] = int(scripted.get(record_type, 0)) + 1
	var mismatched: PackedStringArray = []
	for record_type: String in expected:
		if int(scripted.get(record_type, 0)) != int(expected[record_type]):
			mismatched.append("%s %d/%d" % [record_type, int(scripted.get(record_type, 0)), expected[record_type]])
	_check(mismatched.is_empty(), "every scripted base record exposes its SCRI (%s) [%d ms]" % [", ".join(mismatched) if not mismatched.is_empty() else "all types match", Time.get_ticks_msec() - started])
	var doc: EsmReference = server.find_reference_by_editor_id("DocMitchellREF")
	_check(doc != null and doc.base.script_form_id != 0, "Doc Mitchell's NPC record has an object script")

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
		var link := door.teleport
		var target: DoorReference = by_id.get(link.destination_id)
		if target != null:
			destination_known += 1
			if target.teleport.destination_id == door.instance_id:
				reciprocal += 1
		var space := link.get_destination_space_form_id()
		if space != 0 and server._persistent_cell_by_worldspace.has(space):
			exterior_landings += 1
			if server.cell_at(space, link.position) != server._persistent_cell_by_worldspace[space]:
				landing_on_grid += 1
		if link.no_alarm:
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
	var inside: DoorReference = back_door.teleport.destination if back_door != null else null
	_check(inside != null and inside.instance_id == back_door.teleport.destination_id, "the back door's link resolves its destination door")
	_check(inside != null and inside.current_space_form_id == interior and back_door.teleport.get_destination_space_form_id() == interior, "the back door lands in the saloon interior")
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
				var condition: Condition = package.conditions[condition_index]
				if not _condition_matches(condition, condition_data):
					errors.append("0x%08X CTDA %d differs" % [form_id, condition_index])
					break
		var raw_idles := _all_subrecords(raw, "IDLA")
		var idle_count := 0
		for idle_data in raw_idles:
			@warning_ignore("integer_division")
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
			_check(reference.teleport == null or not reference.teleport.destination_id.is_empty(), "DoorReference XTEL link names its destination")
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
			if reference.teleport == null and plain_door == null:
				plain_door = reference
			elif reference.teleport != null and load_door == null:
				load_door = reference
		elif reference is ActorReference:
			actors.append(reference)
	var actor := ActorReference.new()
	actor.instance_id = "test:actor"
	actor.contents = Inventory.new()
	var other_actor := ActorReference.new()
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
		_check(int(move.get("space_form_id", 0)) == load_door.teleport.get_destination_space_form_id()
				and move.get("position") == load_door.teleport.position and move.get("rotation") == load_door.teleport.rotation,
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
		_check(not keyed.is_locked and int(script_server.get_pending_move(actor).get("space_form_id", 0)) == keyed.teleport.get_destination_space_form_id(),
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
		_check(int(script_server.get_pending_move(actor).get("space_form_id", 0)) == door.teleport.get_destination_space_form_id(),
				"the player goes through an OnActivate Player door via its script")
		script_server.activate(door, other_actor)
		_check(int(script_server.get_pending_move(other_actor).get("space_form_id", 0)) == door.teleport.get_destination_space_form_id(),
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
		var third := ActorReference.new()
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
		var picker := ActorReference.new()
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


## Whether a Condition holds exactly the fields of its raw CTDA bytes.
func _condition_matches(condition: Condition, data: PackedByteArray) -> bool:
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


## Every CTDA on QUST and TERM records becomes a Condition on its owner, in
## order, field for field: 1501 on QUST (quest, log entry and objective target
## conditions) and 405 on TERM menu items in FalloutNV.esm.
func _check_owner_conditions(server, index: Array) -> void:
	var totals := {"QUST": 0, "TERM": 0}
	var mismatches: Array[String] = []
	for row: Dictionary in index:
		var type := String(row.get("record_type", ""))
		if not totals.has(type):
			continue
		var base: EsmBase = server.get_base(int(row["form_id"]))
		var parsed: Array[Condition] = []
		if base is QuestBase:
			parsed.append_array(base.conditions)
			for stage: QuestStage in base.stages:
				for entry: QuestLogEntry in stage.log_entries:
					parsed.append_array(entry.conditions)
			for objective: QuestObjective in base.objectives:
				for target: QuestObjectiveTarget in objective.targets:
					parsed.append_array(target.conditions)
		elif base is TerminalBase:
			for item: TerminalMenuItem in base.menu_items:
				parsed.append_array(item.conditions)
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
	_check(mismatches.is_empty() and totals["QUST"] == 1501 and totals["TERM"] == 405,
			"every QUST and TERM CTDA is a Condition on its owner, field for field (%s; %s)" % [totals, mismatches.slice(0, 3)])


## XLKR reaches the reference: placed terminal REFR 00143990 is linked to
## 0013DC47 (terminal_link_census.cpp: all 4 placed terminals whose base has
## linked-reference conditions carry an XLKR).
func _check_linked_references(server, _index: Array) -> void:
	var terminal: EsmReference = server.get_reference("authored:00143990")
	_check(terminal != null and terminal.linked_reference_form_id == 0x0013DC47,
			"a placed reference carries its XLKR linked reference (%s)" % ("0x%08X" % terminal.linked_reference_form_id if terminal != null else "missing"))
