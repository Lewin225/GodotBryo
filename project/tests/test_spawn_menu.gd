extends Node

## The spawn menu (Plans/SpawnMenu/spawn_menu.md) against FalloutNV.esm.
## Step 1: SpawnCatalog's rows, tree, categories, names and search, checked
## against the census of 2026-11-09 (diag_spawn_menu_census.gd).
## Step 2: SpawnPlacer in Doc Mitchell's house, booted as a new game:
## `player.PlaceAtMe` of a MISC and a STAT makes a runtime reference in the
## player's cell that CellStreamerV2 builds a node for; undo frees the node and
## drops the reference from the runtime table; a crosshair spawn lands on what
## the camera looks at; AddItem undo takes the items back.
## Step 3: the Spawn tab in the same game: categories build on the worker,
## the tree selects groups, search narrows the grid, and clicks add to the
## inventory (Items) or place (Objects, Leveled).

## The census: records, records with a model, models in an archive, records
## with an ICON, for each type the menu shows.
const CENSUS := {
	"STAT": [6785, 6780, 6775, 0], "NPC_": [3816, 3808, 3808, 0], "LVLI": [2738, 0, 0, 0],
	"CONT": [2478, 2478, 2478, 0], "CREA": [1578, 1093, 1093, 0], "ACTI": [1143, 429, 429, 0],
	"NOTE": [894, 282, 282, 348], "MISC": [507, 461, 461, 489], "LIGH": [501, 29, 29, 0],
	"ARMO": [389, 345, 345, 372], "LVLN": [365, 0, 0, 0], "TERM": [344, 312, 312, 0],
	"LVLC": [343, 0, 0, 0], "DOOR": [320, 320, 318, 0], "KEYM": [283, 264, 264, 283],
	"CCRD": [270, 270, 270, 270], "WEAP": [261, 207, 207, 200], "MSTT": [241, 241, 240, 0],
	"FURN": [234, 234, 233, 0], "ALCH": [189, 189, 189, 189], "SCOL": [98, 98, 88, 0],
	"AMMO": [92, 91, 91, 92], "TACT": [87, 85, 85, 0], "IMOD": [50, 50, 50, 50],
	"BOOK": [27, 26, 26, 17], "CMNY": [6, 6, 6, 6], "CHIP": [5, 5, 5, 5],
}
const PISTOL_9MM := 0x000E3778

var failures := 0

func check(ok: bool, message: String) -> void:
	print("  OK   " if ok else "  FAIL ", message)
	if not ok:
		failures += 1

func _ready() -> void:
	var esm_server: Node = get_node("/root/EsmServer")
	if not esm_server.is_ready():
		await esm_server.esm_ready
	var catalog := SpawnCatalog.new(esm_server.reader, esm_server.get_record_index(), get_node("/root/ArchiveServer"))
	_check_catalog(catalog)
	await _check_placer(catalog)
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)

func _check_catalog(catalog: SpawnCatalog) -> void:
	var types := SpawnCatalog.all_types()
	check(types.size() == CENSUS.size() and CENSUS.keys().all(func(t: String) -> bool: return types.has(t)),
			"the categories cover exactly the census's spawnable types (%d)" % types.size())
	for absent in ["IDLM", "GRAS", "FLST", "TREE"]:
		check(not types.has(absent) and catalog.rows_for_type(absent).is_empty(), "%s is not in the menu" % absent)

	_check_creature_parts(catalog)
	_check_shown_assets(catalog)

	for type: String in CENSUS:
		var rows := catalog.rows_for_type(type)
		var with_model := rows.filter(func(r: Dictionary) -> bool: return not String(r["model"]).is_empty())
		var found := with_model.filter(func(r: Dictionary) -> bool: return not r["model_missing"])
		var with_icon := rows.filter(func(r: Dictionary) -> bool: return not String(r["icon"]).is_empty())
		var got := [rows.size(), with_model.size(), found.size(), with_icon.size()]
		check(got == CENSUS[type], "%s rows/model/in BSA/icon %s match the census %s (%.1f ms)" % [type, got, CENSUS[type], catalog.build_ms[type]])
	var slowest := ""
	for type: String in catalog.build_ms:
		if slowest.is_empty() or catalog.build_ms[type] > catalog.build_ms[slowest]:
			slowest = type
	print("  info  slowest first build: %s %.1f ms" % [slowest, catalog.build_ms[slowest]])

	var pistol := catalog.row_for_form_id("WEAP", PISTOL_9MM)
	check(pistol.get("display_name") == "9mm Pistol", "the 9mm pistol is named from FULL: %s" % pistol.get("display_name"))
	check(String(pistol.get("group")) == "weapons/1handpistol", "it is under weapons/1handpistol: %s" % pistol.get("group"))
	check(not String(pistol.get("icon", "")).is_empty(), "it has an ICON: %s" % pistol.get("icon"))
	var weapons := catalog.rows_for_type("WEAP")
	for needle in ["000e3778", "0xE3778", "9mm"]:
		var found := SpawnCatalog.filter(weapons, needle)
		check(found.any(func(r: Dictionary) -> bool: return int(r["form_id"]) == PISTOL_9MM), "search '%s' finds it (%d results)" % [needle, found.size()])
	check(SpawnCatalog.filter(weapons, "0xE3778").size() == 1, "a FormID search finds only that record")
	for type: String in ["WEAP", "STAT", "NPC_"]:
		for needle in ["9mm", "c", "crate", "0xE3778", "000e3778", "WEAP", "e37", "zzzz", "Pistol "]:
			var rows := catalog.rows_for_type(type)
			if catalog.search(type, needle) != SpawnCatalog.filter(rows, needle):
				check(false, "search() matches filter() for %s '%s'" % [type, needle])
	check(true, "search() (native find over the search blob) gives filter()'s rows, in order, for WEAP, STAT and NPC_")
	check(SpawnCatalog.filter(weapons, "", "weapons/1handpistol").has(pistol), "the weapons/1handpistol node holds it")
	check(not SpawnCatalog.filter(weapons, "", "weapons/1hand").has(pistol), "a node selects whole path segments, not prefixes")

	var tree := catalog.build_tree("WEAP")
	check(int(tree["count"]) == 261, "the WEAP tree's root counts every record (%d)" % tree["count"])
	var weapons_node := _child(tree, "weapons")
	var pistol_node := _child(weapons_node, "1handpistol")
	check(not pistol_node.is_empty() and pistol_node["path"] == "weapons/1handpistol"
			and int(pistol_node["count"]) == SpawnCatalog.filter(weapons, "", "weapons/1handpistol").size(),
			"weapons/1handpistol counts the rows below it (%d)" % pistol_node.get("count", -1))
	var no_model := _child(tree, SpawnCatalog.NO_MODEL_GROUP)
	check(int(no_model.get("count", 0)) == 261 - 207, "the 54 WEAP records without a model are in (no model)")
	check((tree["children"] as Array).back()["name"] == SpawnCatalog.NO_MODEL_GROUP, "(no model) sorts last")
	var sum := 0
	for child: Dictionary in catalog.build_tree("STAT")["children"]:
		sum += int(child["count"])
	check(sum == 6785, "the STAT top folders add up to every STAT (%d)" % sum)

	var npc_tree := catalog.build_tree("NPC_")
	var npc_races := (npc_tree["children"] as Array).map(func(n: Dictionary) -> String: return n["name"])
	check(npc_races.size() > 1 and npc_races.size() <= 21 and not npc_races.has("(no race)"), "NPC_ groups by race (%d): %s" % [npc_races.size(), npc_races])
	check((npc_tree["children"] as Array).all(func(n: Dictionary) -> bool: return not (n["children"] as Array).is_empty()),
			"each race node is split by faction")
	var lvli_groups := (catalog.build_tree("LVLI")["children"] as Array).map(func(n: Dictionary) -> String: return n["name"])
	check(lvli_groups.has("Loot") and lvli_groups.has("Vendor"), "LVLI groups by EditorID prefix (%d groups)" % lvli_groups.size())

	check(SpawnCatalog.default_action("WEAP") == SpawnCatalog.ACTION_INVENTORY, "an item's click adds it to the inventory")
	check(SpawnCatalog.default_action("STAT") == SpawnCatalog.ACTION_PLACE and SpawnCatalog.default_action("NPC_") == SpawnCatalog.ACTION_PLACE, "a STAT's and an NPC_'s click places it")
	check(SpawnCatalog.default_action("LVLN") == SpawnCatalog.ACTION_RESOLVE, "a leveled list's click resolves it")
	var stat_names := catalog.rows_for_type("STAT").filter(func(r: Dictionary) -> bool: return String(r["display_name"]).begins_with("0x"))
	check(stat_names.size() == 0, "every STAT has an EditorID name, since none has FULL (%d FormID-only)" % stat_names.size())
	check(SpawnCatalog.humanize("WeapNV9mmPistol") == "Weap NV 9 mm Pistol", "humanize splits (as the editor browser does) WeapNV9mmPistol: %s" % SpawnCatalog.humanize("WeapNV9mmPistol"))

func _check_placer(catalog: SpawnCatalog) -> void:
	var game := (load("res://game.tscn") as PackedScene).instantiate()
	add_child(game)
	var coordinator: TransitionCoordinator = game.transition_coordinator
	var house := int(EsmServer.reader.find_cell_by_editor_id("GSDocMitchellHouse").get("form_id", 0))
	var deadline := Time.get_ticks_msec() + 30000
	while (coordinator.loaded_space_form_id != house or coordinator.is_transitioning()) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	check(coordinator.loaded_space_form_id == house, "the game starts in Doc Mitchell's house")
	var placer: SpawnPlacer = game.spawn_placer
	check(placer != null and ScriptServer.function_registry.place_at_me_handler == Callable(placer, "place_at_me"),
			"PlaceAtMe is handled by the game's SpawnPlacer")
	var player: EsmReference = EsmServer.get_player_reference()

	var misc := _first_with_model(catalog, "MISC", "clutter/")
	var stat := _first_with_model(catalog, "STAT", "clutter/")
	for row in [misc, stat]:
		var before := placer.history_size()
		var result: Dictionary = ScriptServer.run_debug_line("player.PlaceAtMe %s 1" % row["editor_id"])
		var reference: EsmReference = result.get("result") as EsmReference
		check(result.get("ok") and reference != null and String(reference.instance_id).begins_with("runtime:"),
				"player.PlaceAtMe %s (%s) returns a runtime reference: %s" % [row["editor_id"], row["record_type"], result])
		if reference == null:
			continue
		check(reference.current_cell_form_id == player.current_cell_form_id and reference.current_cell_form_id == house,
				"it is in the player's cell")
		var expected: Vector3 = player.position
		if row["record_type"] == "MISC":
			expected += SpawnPlacer._ahead(player.rotation.z) * ActorReference.DROP_DISTANCE + Vector3(0.0, 0.0, ActorReference.DROP_HEIGHT)
		check(reference.position.is_equal_approx(expected), "%s, as PlaceAtMe with no distance places a %s" % [
				"in front of the player and above their feet, as dropped" if row["record_type"] == "MISC" else "at the player's position", row["record_type"]])
		check(placer.history_size() == before + 1, "and is one undo entry")
		var node := await _wait_for_node(reference)
		check(node != null and game.cell_streamer.is_ancestor_of(node), "CellStreamerV2 builds its node (%s)" % node)
		check(EsmServer.get_reference(reference.instance_id) == reference, "the runtime table holds it")
		check(placer.undo(), "undo takes it back")
		await get_tree().process_frame
		await get_tree().process_frame
		check(not is_instance_valid(node) or not node.is_inside_tree(), "its node is freed")
		check(EsmNode.node_for(reference) == null, "and no node is registered for it")
		check(EsmServer.get_reference(reference.instance_id) == null, "and it is gone from the runtime table")
		check(reference.current_space_form_id == 0 and reference.current_cell_form_id == 0, "it is unplaced (space 0, cell 0)")

	var target := placer.crosshair_target()
	check(not target.is_empty() and target["space"] == house, "the crosshair has a target in the house: %s" % target)
	var placed := placer.place_at_crosshair(int(misc["form_id"]), 3)
	check(placed.size() == 3, "a count of 3 places three references")
	if placed.size() == 3:
		var middle: Vector3 = placed[1].position
		check(middle.is_equal_approx(target["position"] + Vector3(0.0, 0.0, ActorReference.DROP_HEIGHT)), "the middle item is above the crosshair target, to fall onto it")
		check(is_equal_approx(placed[0].position.distance_to(placed[2].position), 2.0 * placer.spread), "they are spread %.2f m apart" % placer.spread)
		var camera := get_viewport().get_camera_3d()
		var to_camera := EsmReferencePhysicaliser.authored_position(camera.global_position) - middle
		var facing := SpawnPlacer._ahead(placed[1].rotation.z)
		check(Vector2(facing.x, facing.y).dot(Vector2(to_camera.x, to_camera.y)) > 0.0, "they face the camera")
	check(placer.clear() == 1 and placed.all(func(r: EsmReference) -> bool: return r.current_space_form_id == 0), "clear takes them all back")

	await _check_pick_up_one(placer, player, misc)

	var stimpak := EsmServer.find_base_by_editor_id("Stimpak")
	var inventory: Inventory = player.contents
	var had := _count_of(inventory, stimpak.form_id)
	check(placer.add_to_inventory(stimpak.form_id, player, 5) == 5 and _count_of(inventory, stimpak.form_id) == had + 5, "add_to_inventory adds 5 Stimpaks")
	check(placer.undo() and _count_of(inventory, stimpak.form_id) == had, "undo takes the 5 back")
	await _check_tab(game, placer, player)

func _check_tab(game: Node, placer: SpawnPlacer, player: EsmReference) -> void:
	var tab := game.get_node_or_null("Debug Tools/TabContainer/Spawn") as SpawnMenuTab
	check(tab != null and tab.placer == placer, "game.tscn's Debug Tools has the Spawn tab, wired to the SpawnPlacer")
	if tab == null:
		return
	# Favourites and Recent go to a file of the test's own, not the user's.
	var lists_path := "user://test_spawn_menu_lists.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(lists_path))
	tab.lists_path = lists_path
	check(tab.ensure_catalog(), "the tab builds its catalog once EsmServer is ready")
	await _check_spawnlists(tab, placer, lists_path)
	tab.select_category(1)
	check(await _wait_for_types(tab, SpawnCatalog.CATEGORIES[1]["types"]), "the Items types build on the worker")
	var weapons_node := tab.select_node("WEAP", "weapons/1handpistol")
	var pistols := SpawnCatalog.filter(tab.catalog.rows_for_type("WEAP"), "", "weapons/1handpistol")
	check(weapons_node and tab.shown_rows() == pistols, "selecting WEAP/weapons/1handpistol shows its %d rows" % pistols.size())
	var status: Label = tab.get_node("Margin/VBox/Split/Right/Status")
	check(status.text.begins_with("%d records in Weapon [WEAP] / weapons / 1handpistol" % pistols.size()), "the status line names the folder: %s" % status.text)
	var grid: ItemList = tab.get_node("Margin/VBox/Split/Right/Grid")
	check(grid.item_count == pistols.size() and grid.icon_mode == ItemList.ICON_MODE_TOP and grid.max_columns == 0, "in an icon grid of as many items")
	var pistol_index := tab.shown_rows().find(tab.catalog.row_for_form_id("WEAP", PISTOL_9MM))
	check(pistol_index >= 0, "the 9mm pistol is among them")
	tab.apply_search("9mm")
	check(not tab.shown_rows().is_empty() and tab.shown_rows().all(func(r: Dictionary) -> bool: return SpawnCatalog.matches(r, "9mm")),
			"searching 9mm narrows the grid to matches (%d)" % tab.shown_rows().size())
	tab.apply_search("0xE3778")
	check(tab.shown_rows().size() == 1 and int(tab.shown_rows()[0]["form_id"]) == PISTOL_9MM, "and 0xE3778, a FormID, narrows it to the pistol")
	tab.apply_search("")
	tab.select_node("WEAP", "weapons/1handpistol")
	pistol_index = tab.shown_rows().find(tab.catalog.row_for_form_id("WEAP", PISTOL_9MM))
	check(SpawnMenuTab.console_command(tab.shown_rows()[pistol_index], 1) == "player.AddItem WeapNV9mmPistol 1", "its console command is player.AddItem WeapNV9mmPistol 1")
	var weapon_item := tree_type_item(tab, "WEAP")
	check(weapon_item != null and weapon_item.get_text(0).begins_with("Weapon [WEAP] ("), "the tree names the type with its tag: %s" % (weapon_item.get_text(0) if weapon_item != null else "none"))
	check(weapon_item != null and weapon_item.get_custom_font(0) is FontVariation and (weapon_item.get_custom_font(0) as FontVariation).variation_embolden > 0.0, "in bold")
	var inventory: Inventory = player.contents
	var had := _count_of(inventory, PISTOL_9MM)
	var tools: CanvasItem = tab.fade_target
	var history_before := placer.history_size()
	grid.item_clicked.emit(pistol_index, Vector2.ZERO, MOUSE_BUTTON_LEFT)
	check(placer.history_size() == history_before and _count_of(inventory, PISTOL_9MM) == had, "a plain click on it spawns nothing")
	var added: Variant = await _shift_click(grid, pistol_index, placer)
	check(added == 1 and _count_of(inventory, PISTOL_9MM) == had + 1, "Shift and click gives one to the player")
	check(tools == game.get_node("Debug Tools") and tab.is_flashing(), "and Debug Tools starts to fade out and back in")
	var lowest := 1.0
	var started := Time.get_ticks_msec()
	while tab.is_flashing() and Time.get_ticks_msec() - started < 2000:
		await get_tree().process_frame
		lowest = minf(lowest, tools.modulate.a)
	var took := (Time.get_ticks_msec() - started) / 1000.0
	check(absf(lowest - tab.fade_alpha) < 0.05 and is_equal_approx(tools.modulate.a, 1.0),
			"it dips to %.0f%% opacity (%.2f) and comes back to opaque" % [tab.fade_alpha * 100.0, lowest])
	check(is_equal_approx(tab.fade_out_time + tab.fade_in_time, 0.4) and took < 0.6, "in 0.4 s (took %.2f s)" % took)
	check(placer.undo() and _count_of(inventory, PISTOL_9MM) == had, "and Undo takes it back")
	var actor := player as ActorReference
	var slots_before := [actor.weapon_right_hip, actor.weapon_left_hip, actor.weapon_back]
	var weapon := tab.equip_row(tab.shown_rows()[pistol_index])
	check(weapon != null and weapon.base_form_id == PISTOL_9MM and actor.get_weapon_slot(weapon) != ActorReference.WeaponSlot.NONE,
			"Equip item puts a 9mm pistol in one of the player's weapon slots (%s)" % (actor.get_weapon_slot(weapon) if weapon != null else "none"))
	check(_count_of(inventory, PISTOL_9MM) == had, "the equipped pistol is in its slot, not left in the inventory as well")
	check(placer.undo() and (weapon == null or actor.get_weapon_slot(weapon) == ActorReference.WeaponSlot.NONE)
			and [actor.weapon_right_hip, actor.weapon_left_hip, actor.weapon_back] == slots_before and _count_of(inventory, PISTOL_9MM) == had,
			"Undo takes it out of the slot and puts the slots back as they were")
	check(weapon == null or EsmServer.get_reference(weapon.instance_id) == null, "and drops it from the runtime table")
	await _check_wear_armor(tab, placer, actor)
	var menu: PopupMenu = tab.get_node("ContextMenu")
	tab._open_menu(pistol_index, Vector2.ZERO)
	check(not menu.is_item_disabled(menu.get_item_index(SpawnMenuTab.MENU_EQUIP)), "the context menu offers Equip item for a WEAP")
	menu.hide()
	var ammo_rows := tab.catalog.rows_for_type("AMMO")
	tab.select_node("AMMO")
	tab._open_menu(0, Vector2.ZERO)
	check(menu.is_item_disabled(menu.get_item_index(SpawnMenuTab.MENU_EQUIP)), "and not for an AMMO (%s)" % ammo_rows[0]["display_name"])
	menu.hide()
	tab.select_node("ARMO")
	tab._open_menu(0, Vector2.ZERO)
	check(not menu.is_item_disabled(menu.get_item_index(SpawnMenuTab.MENU_EQUIP)), "but for an ARMO (%s)" % tab.shown_rows()[0]["display_name"])
	menu.hide()
	tab.select_node("WEAP", "weapons/1handpistol")

	history_before = placer.history_size()
	grid.item_activated.emit(pistol_index)
	check(placer.history_size() == history_before + 1 and _count_of(inventory, PISTOL_9MM) == had, "a double click places it in the world")
	placer.undo()

	await _check_tree_click_expand(tab)
	await _check_icons(tab)

	tab.select_category(3)
	check(await _wait_for_types(tab, ["STAT"]), "the STAT rows build on the worker (%.0f ms there)" % tab.catalog.build_ms.get("STAT", -1.0))
	check(tab.select_node("STAT") and tab.shown_rows().size() == 6785, "the STAT node shows all 6785 STATs")
	# Overwriting a grid that already holds as many items can finish in one
	# frame, so how many frames it takes is reported, not checked.
	print("  info  first frame filled %d of 6785 grid items" % tab._grid_cursor)
	var frames := 0
	while tab.is_grid_filling() and frames < 600:
		await get_tree().process_frame
		frames += 1
	check(grid.item_count == 6785, "and holds all 6785 after %d frames" % frames)
	tab.apply_search("crate")
	var crates := tab.shown_rows().size()
	tab.apply_search("crates")
	check(tab.shown_rows().size() <= crates and tab.shown_rows().all(func(r: Dictionary) -> bool: return SpawnCatalog.matches(r, "crates")),
			"a longer search narrows the previous matches (%d -> %d)" % [crates, tab.shown_rows().size()])
	tab.apply_search("")
	var stat_index := tab.shown_rows().find(_first_with_model(tab.catalog, "STAT", "clutter/"))
	var before := placer.history_size()
	var placed: Variant = tab.place_row(stat_index)
	check(placed is Array and (placed as Array).size() == 1 and placer.history_size() == before + 1, "a double click on a STAT places one at the crosshair")
	var given: Variant = await _shift_click(grid, stat_index, placer)
	check(given == 0 and placer.history_size() == before + 1 and status.text.contains("can't be carried"),
			"Shift and click on a STAT gives nothing and says so (%s)" % status.text)
	if placed is Array and not (placed as Array).is_empty():
		var node := await _wait_for_node(placed[0])
		check(node != null, "and the streamer builds it")
	placer.undo()

	tab.select_category(5)
	check(await _wait_for_types(tab, ["LVLN"]), "the leveled lists build")
	tab.select_node("LVLN")
	var resolved: Array = []
	for i in tab.shown_rows().size():
		var result: Variant = tab.place_row(i)
		if result is Array and not (result as Array).is_empty():
			resolved = result
			break
	check(not resolved.is_empty() and resolved[0].base is NpcBase, "a double click on an LVLN places the NPC_ it resolves to (%s)" % (resolved[0].base.editor_id if not resolved.is_empty() else "none"))
	for _frame in 30:
		await get_tree().physics_frame
	check(is_instance_valid(tab), "the placed actor runs 30 physics frames without a crash")
	placer.clear()

## Creature parts, checked as rules over every CREA and LVLC row, not by
## record or count: parts are NIFs an archive has; a CREA with NIFZ uses its
## own, in its skeleton's (MODL's) folder; a CREA without, its TPLT
## template's; a leveled list's (an LVLC, or a CREA templated on one) are
## those of one creature it can give, and it has parts whenever any of those
## creatures has. The preview key is the parts, as an actor's.
func _check_creature_parts(catalog: SpawnCatalog) -> void:
	var reader: EsmReader = EsmServer.reader
	var archives = get_node("/root/ArchiveServer")
	var broken := []
	var with_parts := 0
	var leveled := 0
	for type: String in RecordVisuals.PART_TYPES:
		for row: Dictionary in catalog.rows_for_type(type):
			var parts: PackedStringArray = row["parts"]
			var raw: Dictionary = reader.get_record_data(int(row["form_id"]))
			var own_nifz: bool = raw["subrecords"].any(func(s: Dictionary) -> bool: return s["type"] == "NIFZ")
			var reachable := _reachable_parts(catalog, raw, 0)
			var problem := ""
			if not parts.is_empty() and not Array(parts).all(func(p: String) -> bool: return p.ends_with(".nif") and archives.contains("meshes/" + p)):
				problem = "a part no archive has"
			elif own_nifz and not Array(parts).all(func(p: String) -> bool: return p.get_base_dir() == String(row["model"]).get_base_dir()):
				problem = "own NIFZ part outside MODL's folder"
			elif own_nifz and row["shown_leveled"]:
				problem = "own NIFZ marked leveled"
			elif parts.is_empty() != reachable.is_empty():
				problem = "parts %s, reachable creatures with parts %d" % [parts, reachable.size()]
			elif not parts.is_empty() and not reachable.has(parts):
				problem = "parts not those of a creature it can give"
			elif not parts.is_empty() and SpawnMenuTab._preview_model(row) != RecordVisuals.ACTOR_PREFIX + "|".join(Array(parts).map(func(p: String) -> String: return "meshes/" + p)):
				problem = "preview key is not its parts"
			if not problem.is_empty():
				broken.append("%s %s: %s" % [type, row["editor_id"], problem])
			if not parts.is_empty():
				with_parts += 1
				if row["shown_leveled"]:
					leveled += 1
	check(broken.is_empty(), "every CREA and LVLC row's parts follow the rules (%d with parts, %d from a leveled list)%s"
			% [with_parts, leveled, "" if broken.is_empty() else ": %s" % str(broken.slice(0, 5))])

## The part sets a CREA or LVLC can give: its own NIFZ parts, else its
## template's, else (a list) every entry's, at any level.
func _reachable_parts(catalog: SpawnCatalog, raw: Dictionary, depth: int) -> Array:
	var type := String(raw.get("record_type", ""))
	if depth > 8 or not type in RecordVisuals.PART_TYPES:
		return []
	var result := []
	if type == "CREA" and raw["subrecords"].any(func(s: Dictionary) -> bool: return s["type"] == "NIFZ"):
		var parts: PackedStringArray = catalog.row_for_form_id("CREA", int(raw["form_id"]))["parts"]
		return [parts] if not parts.is_empty() else []
	for sub: Dictionary in raw["subrecords"]:
		var data: PackedByteArray = sub["data"]
		if (type == "CREA" and sub["type"] == "TPLT" or type == "LVLC" and sub["type"] == "LVLO") and data.size() >= 4:
			var target := data.decode_u32(0 if sub["type"] == "TPLT" else 4)
			result.append_array(_reachable_parts(catalog, EsmServer.reader.get_record_data(target), depth + 1))
	return result

## What every row shows, checked as rules rather than by record or count:
## what is shown is in an archive; a record with its own icon or world model
## in an archive shows it; otherwise a model it shows is one of its model
## subrecords (RecordVisuals.SHOWN_MODEL_TAGS); an LVLI shows the icon or model
## of an item it can give, and shows something whenever any of them has one.
func _check_shown_assets(catalog: SpawnCatalog) -> void:
	var reader: EsmReader = EsmServer.reader
	var archives = get_node("/root/ArchiveServer")
	var broken := []
	var fallbacks := 0
	var lists_shown := 0
	for type: String in SpawnCatalog.all_types():
		for row: Dictionary in catalog.rows_for_type(type):
			if type in RecordVisuals.PART_TYPES or type in RecordVisuals.NO_VISUAL_TYPES:
				continue
			var icon := String(row["shown_icon"])
			# A model key for one NIF is its path under meshes/.
			var model := String(row["shown_model"]).trim_prefix("meshes/")
			var raw: Dictionary = reader.get_record_data(int(row["form_id"]))
			var problem := ""
			if not String(row["shown_model"]).is_empty() and not String(row["shown_model"]).begins_with("meshes/"):
				problem = "a model key that is not one NIF: %s" % row["shown_model"]
			elif not icon.is_empty() and not archives.contains("textures/" + icon) or not model.is_empty() and not archives.contains("meshes/" + model):
				problem = "shows something no archive has"
			elif type == "LVLI":
				var reachable := _reachable_items(catalog, raw, 0)
				var shown := [icon, model]
				if row["shown_leveled"] == (icon.is_empty() and model.is_empty()):
					problem = "shown_leveled does not match what it shows"
				elif (icon.is_empty() and model.is_empty()) != reachable.is_empty():
					problem = "shows %s, items it can give with something to show %d" % [shown, reachable.size()]
				elif not reachable.is_empty() and not reachable.has(shown):
					problem = "shows %s, not an item it can give" % [shown]
				if not (icon.is_empty() and model.is_empty()):
					lists_shown += 1
			else:
				var own_icon := String(row["icon"])
				var own_model := String(row["model"])
				if not own_icon.is_empty() and archives.contains("textures/" + own_icon) and icon != own_icon:
					problem = "does not show its own icon"
				elif not own_model.is_empty() and not row["model_missing"] and model != own_model:
					problem = "does not show its own model"
				elif not model.is_empty() and model != own_model:
					var tags: Array = RecordVisuals.SHOWN_MODEL_TAGS.get(type, ["MODL"])
					var from: Array = raw["subrecords"].filter(func(s: Dictionary) -> bool:
						return s["type"] in tags and SpawnCatalog._asset_path(s["data"], "meshes/") == model)
					if from.is_empty():
						problem = "shows %s, not one of its %s" % [model, tags]
					fallbacks += 1
			if not problem.is_empty():
				broken.append("%s %s: %s" % [type, row["editor_id"], problem])
	check(broken.is_empty(), "every item and object row shows its own icon and model, a fallback model of its own (%d), or an item its list can give (%d LVLI)%s"
			% [fallbacks, lists_shown, "" if broken.is_empty() else ": %s" % str(broken.slice(0, 5))])

## [icon, model] of every item an LVLI can give that has either, at any level.
func _reachable_items(catalog: SpawnCatalog, raw: Dictionary, depth: int) -> Array:
	var type := String(raw.get("record_type", ""))
	if depth > 8 or type.is_empty():
		return []
	if type != "LVLI":
		var shown := RecordVisuals.new(EsmServer.reader, get_node("/root/ArchiveServer")).shown_assets(type, raw)
		return [] if String(shown[0]).is_empty() and String(shown[1]).is_empty() else [shown]
	var result := []
	for sub: Dictionary in raw["subrecords"]:
		var data: PackedByteArray = sub["data"]
		if sub["type"] == "LVLO" and data.size() >= 8:
			result.append_array(_reachable_items(catalog, EsmServer.reader.get_record_data(data.decode_u32(4)), depth + 1))
	return result

## The Spawnlists category: the default tab, with Favourites, Common and
## Recent in its tree. Common is the SpawnList data file's EditorIDs that the
## data has; Add to Favourites (the context menu) and spawning fill the other
## two, newest first in Recent, and both are read back by a new SpawnLists.
func _check_spawnlists(tab: SpawnMenuTab, placer: SpawnPlacer, lists_path: String) -> void:
	check(tab.is_lists_category() and tab._categories.current_tab == SpawnCatalog.LISTS_CATEGORY
			and SpawnCatalog.CATEGORIES[SpawnCatalog.LISTS_CATEGORY]["name"] == "Spawnlists",
			"the Spawnlists tab is the first and shows by default")
	# The tree is built in the tab's _process, after process_frame fires.
	for _frame in 10:
		if tab._tree.get_root() != null and not tab._tree_pending:
			break
		await get_tree().process_frame
	var names := []
	for item in tab._tree.get_root().get_children():
		names.append(item.get_text(0).get_slice(" (", 0))
	check(names == ["Favourites", "Common", "Recent"], "its tree is Favourites, Common, Recent (%s)" % [names])
	var common_ids := tab.lists.common.editor_ids
	var resolved := Array(common_ids).filter(func(e: String) -> bool: return tab.catalog.form_id_for_editor_id(e) != 0)
	check(tab.shown_rows().size() == resolved.size() and resolved.size() > 0 and tab.selection_path() == "Spawnlists / Common",
			"with no favourites it shows Common: %d records, every EditorID of the list the data has (%d of %d)"
			% [tab.shown_rows().size(), resolved.size(), common_ids.size()])
	var types := {}
	for row: Dictionary in tab.shown_rows():
		types[row["record_type"]] = true
	print("  info  Common's types: %s" % ", ".join(types.keys()))
	check(types.size() > 3, "Common holds records of several types (%d)" % types.size())

	var menu: PopupMenu = tab.get_node("ContextMenu")
	var first: Dictionary = tab.shown_rows()[0]
	tab._open_menu(0, Vector2.ZERO)
	check(menu.get_item_text(menu.get_item_index(SpawnMenuTab.MENU_FAVOURITE)) == "Add to Favourites", "the context menu offers Add to Favourites")
	tab._on_menu_id(SpawnMenuTab.MENU_FAVOURITE)
	menu.hide()
	tab._open_menu(0, Vector2.ZERO)
	check(tab.lists.is_favourite(int(first["form_id"])) and menu.get_item_text(menu.get_item_index(SpawnMenuTab.MENU_FAVOURITE)) == "Remove from Favourites",
			"which adds %s, and then offers Remove from Favourites" % first["display_name"])
	menu.hide()
	tab.select_list(SpawnLists.FAVOURITES)
	check(tab.shown_rows().size() == 1 and tab.shown_rows()[0]["form_id"] == first["form_id"], "Favourites shows it")

	tab.select_list(SpawnLists.COMMON)
	var placed: Variant = tab.place_row(1)
	var second: Dictionary = tab.shown_rows()[1]
	check(placed != null and tab.lists.ids(SpawnLists.RECENT)[0] == int(second["form_id"]), "spawning %s puts it first in Recent" % second["display_name"])
	tab.select_list(SpawnLists.RECENT)
	check(tab.shown_rows().size() >= 1 and tab.shown_rows()[0]["form_id"] == second["form_id"], "Recent shows it first")
	placer.clear()

	var reloaded := SpawnLists.new(lists_path)
	check(reloaded.is_favourite(int(first["form_id"])) and reloaded.ids(SpawnLists.RECENT).has(int(second["form_id"])),
			"a new SpawnLists reads Favourites and Recent back from %s" % lists_path)
	tab.lists.clear()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(lists_path))

## A real Shift press, a left click on grid item `index`, and the release;
## how many spawns the click added to the history (1, or 0).
func _shift_click(grid: ItemList, index: int, placer: SpawnPlacer) -> int:
	var key := InputEventKey.new()
	key.keycode = KEY_SHIFT
	key.physical_keycode = KEY_SHIFT
	key.pressed = true
	Input.parse_input_event(key)
	Input.flush_buffered_events()
	await get_tree().process_frame
	var before := placer.history_size()
	grid.item_clicked.emit(index, Vector2.ZERO, MOUSE_BUTTON_LEFT)
	var given := placer.history_size() - before
	key = key.duplicate()
	key.pressed = false
	Input.parse_input_event(key)
	Input.flush_buffered_events()
	await get_tree().process_frame
	return given

## A click on a collapsed node's arrow expands it. Tree refuses to create
## items inside its own mouse event, so the children are added just after it;
## the click goes through the viewport as a real one does.
func _check_tree_click_expand(tab: SpawnMenuTab) -> void:
	var tools: Control = tab.get_node("../..")
	var tabs: TabContainer = tab.get_parent()
	# Headless, the root window is 64x64 and the tab lays out to nothing.
	var window_size := get_tree().root.size
	get_tree().root.size = Vector2i(1920, 1080)
	tools.call("_set_open", true)
	tabs.current_tab = tabs.get_tab_idx_from_control(tab)
	tab.select_category(1)
	for _frame in 3:
		await get_tree().process_frame
	var tree: Tree = tab.get_node("Margin/VBox/Split/Tree")
	var armo: TreeItem = null
	for item in tree.get_root().get_children():
		if (item.get_metadata(0) as Dictionary).get("type") == "ARMO":
			armo = item
	check(armo != null and armo.collapsed and armo.get_child_count() == 1, "ARMO starts collapsed, with one placeholder child")
	if armo != null:
		tree.scroll_to_item(armo, true)
		await get_tree().process_frame
		var rect := tree.get_item_area_rect(armo)
		# The fold arrow sits at the start of the row, after the indent.
		# A top-level item's rect starts at the arrow, which fills its first
		# item_margin pixels.
		var margin := float(tree.get_theme_constant(&"item_margin"))
		var at := tree.get_global_transform() * Vector2(rect.position.x + margin * 0.5, rect.get_center().y)
		# The new game's opening message box dims the whole screen above
		# Debug Tools until it is dismissed; a player would have dismissed it.
		var dialog := tab.get_tree().root.find_child("DialogRoot", true, false) as CanvasItem
		var dialog_was_visible := dialog != null and dialog.visible
		if dialog != null:
			dialog.visible = false
		for pressed in [true, false]:
			var click := InputEventMouseButton.new()
			click.button_index = MOUSE_BUTTON_LEFT
			click.pressed = pressed
			click.position = at
			click.global_position = at
			Input.parse_input_event(click)
		await get_tree().process_frame
		await get_tree().process_frame
		if dialog != null:
			dialog.visible = dialog_was_visible
		var names := armo.get_children().map(func(c: TreeItem) -> String: return c.get_text(0))
		check(not armo.collapsed and armo.get_child_count() > 1 and not names.has("…"), "a click on its arrow expands it to its folders: %s" % [names])
	tools.call("_set_open", false)
	get_tree().root.size = window_size

## Equip item on armor: the player wears it. A second piece sharing a biped
## slot takes the first off; Undo puts the first back on, and a second Undo
## leaves the player dressed as before.
func _check_wear_armor(tab: SpawnMenuTab, placer: SpawnPlacer, actor: ActorReference) -> void:
	var worn_before := _worn(actor)
	var first := {}
	var second := {}
	for row: Dictionary in tab.catalog.rows_for_type("ARMO"):
		var base := EsmServer.get_base(int(row["form_id"])) as ArmorBase
		if base == null or base.biped_flags == 0 or row["model_missing"] or worn_before.has(int(row["form_id"])):
			continue
		if first.is_empty():
			first = row
		elif (base.biped_flags & (EsmServer.get_base(int(first["form_id"])) as ArmorBase).biped_flags) != 0:
			second = row
			break
	check(not second.is_empty(), "two ARMOs share a biped slot (%s, %s)" % [first.get("display_name", "none"), second.get("display_name", "none")])
	if second.is_empty():
		return
	var worn: Variant = tab.equip_row(first)
	check(worn is InventoryItem and (worn as InventoryItem).is_equipped and _worn(actor).has(int(first["form_id"])),
			"Equip item makes the player wear %s" % first["display_name"])
	tab.equip_row(second)
	check(_worn(actor).has(int(second["form_id"])) and not _worn(actor).has(int(first["form_id"])),
			"equipping %s takes it off" % second["display_name"])
	check(placer.undo() and _worn(actor).has(int(first["form_id"])) and not _worn(actor).has(int(second["form_id"]))
			and _count_of(actor.contents, int(second["form_id"])) == 0, "Undo puts %s back on and takes the second away" % first["display_name"])
	check(placer.undo() and _worn(actor) == worn_before and _count_of(actor.contents, int(first["form_id"])) == 0,
			"a second Undo leaves the player dressed as before: %s" % [_worn(actor)])

func _worn(actor: ActorReference) -> Array:
	var ids := []
	for item in actor.contents.get_equipped_items():
		if item.base is ArmorBase:
			ids.append(item.base_form_id)
	ids.sort()
	return ids

## Records with an ICON show it in the grid, as TextureServer gives it;
## others keep the category glyph. Only the visible rows (and a screen ahead)
## load: a row far below does not, until the grid scrolls to it.
func _check_icons(tab: SpawnMenuTab) -> void:
	var tools: Control = tab.get_node("../..")
	var tabs: TabContainer = tab.get_parent()
	var window_size := get_tree().root.size
	get_tree().root.size = Vector2i(1920, 1080)
	var dialog := tab.get_tree().root.find_child("DialogRoot", true, false) as CanvasItem
	var dialog_was_visible := dialog != null and dialog.visible
	if dialog != null:
		dialog.visible = false
	tools.call("_set_open", true)
	tabs.current_tab = tabs.get_tab_idx_from_control(tab)
	tab.select_category(1)
	tab.select_node("WEAP", "weapons/1handpistol")
	await _settle_icons(tab)
	var glyph := tab._glyph(1)
	var pistol_index := tab.shown_rows().find(tab.catalog.row_for_form_id("WEAP", PISTOL_9MM))
	var pistol_icon: Texture2D = await TextureServer.request("textures/" + String(tab.shown_rows()[pistol_index]["icon"]))
	check(pistol_icon != null and tab.item_icon(pistol_index) == pistol_icon, "the 9mm pistol shows its inventory icon, as TextureServer gives it (%s)" % pistol_icon)
	var range_ := tab.visible_range()
	var with_icons := 0
	for i in range(range_.x, range_.y + 1):
		if not String(tab.shown_rows()[i]["icon"]).is_empty() and tab.item_icon(i) != glyph:
			with_icons += 1
	check(with_icons > 0, "the visible pistols show icons (%d of rows %d-%d)" % [with_icons, range_.x, range_.y])

	tab.select_node("WEAP")
	await _settle_icons(tab)
	var no_icon := -1
	range_ = tab.visible_range()
	for i in range(range_.x, range_.y + 1):
		if String(tab.shown_rows()[i]["icon"]).is_empty():
			no_icon = i
			break
	if no_icon >= 0:
		var model := SpawnMenuTab.thumbnail_model(tab.shown_rows()[no_icon])
		var render := ThumbnailServer.cached_render(model)
		check((render != null or DisplayServer.get_name() == "headless") and tab.item_icon(no_icon) == (render if render != null else glyph),
				"a WEAP with no ICON shows a render of its model (%s, %s)" % [tab.shown_rows()[no_icon]["display_name"], model])
	else:
		print("  info  no WEAP without an ICON on the first screen")

	tab.select_category(1)
	await _settle_icons(tab)
	var rows := tab.shown_rows()
	var last := rows.size() - 1
	while last > 0 and String(rows[last]["icon"]).is_empty():
		last -= 1
	range_ = tab.visible_range()
	check(last > range_.y and tab.item_icon(last) == glyph and not ThumbnailServer.has_icon(String(rows[last]["shown_icon"])),
			"All Items (%d rows) loads only the first %d rows' icons, not row %d's" % [rows.size(), range_.y + 1, last])
	var bar := tab._grid.get_v_scroll_bar()
	bar.value = bar.max_value
	await _settle_icons(tab)
	check(tab.item_icon(last) != glyph, "scrolled to the bottom, row %d (%s) shows its icon" % [last, rows[last]["display_name"]])
	check(tab.visible_range().x > rows.size() - 200, "and the visible range starts near the end, not at row 0 (%s)" % tab.visible_range())

	await _check_thumbnails(tab)
	await _check_preview(tab)

	var slider: HSlider = tab.get_node("Margin/VBox/Split/Right/Toolbar/Size")
	var size_before := slider.value
	slider.value = slider.max_value
	var largest := int(slider.max_value)
	check(largest >= 384 and tab._grid.fixed_icon_size == Vector2i(largest, largest), "the Size slider goes up to %d px icons (%s)" % [largest, tab._grid.fixed_icon_size])
	slider.value = size_before

	tools.call("_set_open", false)
	if dialog != null:
		dialog.visible = dialog_was_visible
	get_tree().root.size = window_size
	tab.select_category(1)

## Step 6: a STAT, a CONT and a WEAP with no ICON show a render of their
## model that is neither empty nor one colour; rows sharing a model share one
## texture; the render is saved, and with the memory cache dropped (a new
## session) it loads from disk instead of rendering again. ThumbnailServer
## and RecordIcon give the same pictures by form id, for any UI.
func _check_thumbnails(tab: SpawnMenuTab) -> void:
	if DisplayServer.get_name() == "headless":
		print("  info  thumbnail renders skipped: --headless draws nothing (run with a window)")
		return
	var renderer: Node = ThumbnailServer
	for spec: Array in [[3, "STAT"], [4, "CONT"], [1, "WEAP"]]:
		tab.select_category(spec[0])
		await _wait_for_types(tab, SpawnCatalog.CATEGORIES[spec[0]]["types"])
		tab.select_node(spec[1])
		await _settle_icons(tab)
		var range_ := tab.visible_range()
		var rows := tab.shown_rows()
		var index := -1
		for i in range(range_.x, range_.y + 1):
			if not SpawnMenuTab.thumbnail_model(rows[i]).is_empty():
				index = i
				break
		if index < 0:
			check(false, "%s has a row with no ICON on the first screen" % spec[1])
			continue
		var model := SpawnMenuTab.thumbnail_model(rows[index])
		var texture := tab.item_icon(index)
		var image := texture.get_image() if texture != null and texture != tab._glyph(spec[0]) else null
		if image != null:
			check(image.is_compressed() and image.has_mipmaps() and image.get_data_size() <= 24 * 1024,
					"%s's render is DXT5 with mipmaps: %s, %d bytes (256 KB raw at 256 px)" % [spec[1], image.get_format(), image.get_data_size()])
			image = image.duplicate()
			image.decompress()
			image.clear_mipmaps()
		var used := image.get_used_rect() if image != null else Rect2i()
		var colours := {}
		if image != null:
			for y in range(0, image.get_height(), 2):
				for x in range(0, image.get_width(), 2):
					var c := image.get_pixel(x, y)
					if c.a > 0.5:
						colours[c.to_rgba32() & 0xF0F0F0F0] = true
		check(image != null and used.size.x > 16 and used.size.y > 16 and colours.size() > 4,
				"%s %s shows a render of %s (%s, drawn %s, %d colours)" % [spec[1], rows[index]["display_name"], model, image, used.size, colours.size()])
		check(FileAccess.file_exists(renderer.cache_path(model)), "and it is saved as %s" % renderer.cache_path(model))
		# Every visible row on the same model shows the same texture.
		var sharing := 0
		var same := true
		for i in range(range_.x, mini(range_.y + 1, tab._grid_cursor)):
			if SpawnMenuTab.thumbnail_model(rows[i]) == model and i != index:
				sharing += 1
				same = same and tab.item_icon(i) == texture
		if sharing > 0:
			check(same, "the %d other visible %s rows on %s share its texture" % [sharing, spec[1], model])

	# An LVLI shows its lowest-level entry's inventory icon.
	tab.select_category(5)
	await _wait_for_types(tab, ["LVLI"])
	tab.select_node("LVLI")
	await _settle_icons(tab)
	var list_index := -1
	for i in range(tab.visible_range().x, tab.visible_range().y + 1):
		if not String(tab.shown_rows()[i]["shown_icon"]).is_empty():
			list_index = i
			break
	if list_index >= 0:
		var list_row: Dictionary = tab.shown_rows()[list_index]
		var entry_icon: Texture2D = await TextureServer.request("textures/" + String(list_row["shown_icon"]))
		check(entry_icon != null and tab.item_icon(list_index) == entry_icon,
				"an LVLI (%s) shows its lowest-level entry's icon (%s)" % [list_row["display_name"], list_row["shown_icon"]])
	else:
		check(false, "an LVLI with an entry icon is on the first screen")

	# Records sharing a model: one render, one texture.
	var by_model := {}
	var shared_model := ""
	for row: Dictionary in tab.catalog.rows_for_type("CONT"):
		var model := SpawnMenuTab.thumbnail_model(row)
		if model.is_empty():
			continue
		by_model[model] = int(by_model.get(model, 0)) + 1
		if by_model[model] >= 5:
			shared_model = model
			break
	var renders_before: int = renderer.renders_done + renderer.disk_loads
	var first: Texture2D = await renderer.request_render(shared_model)
	var second: Texture2D = await renderer.request_render(shared_model)
	check(first != null and first == second and renderer.renders_done + renderer.disk_loads - renders_before <= 1,
			"5+ CONT on %s get one texture from at most one render or load" % shared_model)

	# A new session: the memory cache dropped, the saved PNG loads rather than
	# being drawn again.
	renderer.drop_cached_renders()
	var loads_before: int = renderer.disk_loads
	var drawn_before: int = renderer.renders_done
	var from_disk: Texture2D = await renderer.request_render(shared_model)
	check(from_disk != null and renderer.disk_loads == loads_before + 1 and renderer.renders_done == drawn_before
			and from_disk.get_size() == Vector2(ThumbnailServer.THUMBNAIL_SIZE, ThumbnailServer.THUMBNAIL_SIZE),
			"with the memory cache dropped, %s loads from user://thumbnails without rendering (%s)" % [shared_model, from_disk])

	await _check_record_icon(tab)
	tab.select_category(1)

## ThumbnailServer by form id, and RecordIcon, for any UI: a record with an
## icon gives the icon the grid shows; one with only a model gives its
## render; one with neither (an NPC_, for now) gives null and the placeholder.
func _check_record_icon(tab: SpawnMenuTab) -> void:
	var with_icon: Dictionary = tab.catalog.rows_for_type("WEAP").filter(func(r: Dictionary) -> bool:
		return not String(r["shown_icon"]).is_empty())[0]
	var with_model: Dictionary = tab.catalog.rows_for_type("STAT").filter(func(r: Dictionary) -> bool:
		return not String(r["shown_model"]).is_empty())[0]
	var npc: Dictionary = tab.catalog.rows_for_type("NPC_")[0]
	check(ThumbnailServer.record_visual(int(with_icon["form_id"]))["icon"] == with_icon["shown_icon"]
			and ThumbnailServer.record_visual(int(with_model["form_id"]))["model"] == with_model["shown_model"],
			"ThumbnailServer.record_visual() agrees with the catalog's rows (%s, %s)" % [with_icon["editor_id"], with_model["editor_id"]])
	var icon_picture: Texture2D = await ThumbnailServer.request(int(with_icon["form_id"]))
	var model_picture: Texture2D = await ThumbnailServer.request(int(with_model["form_id"]))
	check(icon_picture != null and icon_picture == ThumbnailServer.cached_icon(String(with_icon["shown_icon"])),
			"request(%s) gives its inventory icon" % with_icon["editor_id"])
	check(model_picture != null and model_picture == ThumbnailServer.cached_render(String(with_model["shown_model"])),
			"request(%s) gives its model's render" % with_model["editor_id"])
	check(await ThumbnailServer.request(int(npc["form_id"])) == null and not ThumbnailServer.has_picture(int(npc["form_id"])),
			"an NPC_ (%s) has no picture yet" % npc["editor_id"])

	var placeholder := tab._glyph(1)
	var icon := RecordIcon.new()
	icon.placeholder = placeholder
	tab.add_child(icon)
	icon.form_id = int(with_model["form_id"])
	check(icon.has_picture() and icon.texture == model_picture, "a RecordIcon given a cached record shows its picture at once")
	icon.form_id = int(npc["form_id"])
	await get_tree().process_frame
	check(not icon.has_picture() and icon.texture == placeholder, "given an NPC_, it shows its placeholder")
	ThumbnailServer.drop_cached_renders()
	icon.form_id = int(with_model["form_id"])
	check(icon.texture == placeholder, "a record not cached shows the placeholder while it loads")
	var shown: Texture2D = await icon.picture_shown
	check(shown != null and icon.texture == shown and icon.has_picture(), "then its picture (%s)" % shown)
	icon.queue_free()

## Hovering a record with a model shows its model live over its icon, 20%
## larger about the same centre; a quick sweep loads only where the pointer
## stops; records with no model (and actors, for now) show none.
func _check_preview(tab: SpawnMenuTab) -> void:
	var preview: ModelPreview = tab.get_node("ModelPreview")
	tab.select_category(1)
	tab.select_node("WEAP", "weapons/1handpistol")
	await _settle_icons(tab)
	var pistol := tab.shown_rows().find(tab.catalog.row_for_form_id("WEAP", PISTOL_9MM))
	tab.hover_row(pistol)
	var model: Node3D = await _wait_for_preview(preview)
	check(preview.visible and preview.showing() == "meshes/weapons/1handpistol/9mm.nif" and model != null,
			"hovering the 9mm pistol shows its model (%s)" % preview.showing())
	_check_preview_place(tab, preview, pistol)
	var pistol_icon := tab._row_icon(tab.shown_rows()[pistol], null)
	check(tab.item_icon(pistol) != pistol_icon and tab.item_icon(pistol).get_width() == 1, "its icon is blanked under the see-through preview")
	tab.hover_row(pistol + 1 if pistol + 1 < tab.shown_rows().size() else pistol - 1)
	check(tab.item_icon(pistol) == pistol_icon, "and comes back when the hover moves on")
	tab.hover_row(pistol)
	model = await _wait_for_preview(preview)
	var bounds := ThumbnailServer.model_bounds(model, model.get_parent()) if model != null else AABB()
	check(bounds.size.length() > 0.05 and bounds.get_center().length() < 0.01, "framed about its centre (%s)" % bounds)
	await _check_orbit(tab, preview, pistol)
	await _check_orbit_turns_meshes(tab, preview)
	var bodies: Array = model.find_children("*", "CollisionObject3D", true, false) if model != null else []
	check(bodies.is_empty(), "its collision bodies are removed (%d left)" % bodies.size())

	# A sweep: three rows hovered within one frame load only the last.
	var others := []
	for i in tab.shown_rows().size():
		if i != pistol and not SpawnMenuTab._preview_model(tab.shown_rows()[i]).is_empty():
			others.append(i)
		if others.size() == 3:
			break
	for i in others:
		tab.hover_row(i)
	await _wait_for_preview(preview)
	var last_model := SpawnMenuTab._preview_model(tab.shown_rows()[others[2]])
	check(preview.showing() == last_model and preview._requested.is_empty(), "a quick sweep loads only the row it stops on (%s)" % preview.showing())

	tab.select_node("WEAP", SpawnCatalog.NO_MODEL_GROUP)
	await _settle_icons(tab)
	tab.hover_row(0)
	check(not preview.visible, "a WEAP with no model shows no preview (%s)" % tab.shown_rows()[0]["display_name"])

	tab.select_node("STAT", "")
	tab.select_category(3)
	await _wait_for_types(tab, ["STAT"])
	tab.select_node("STAT")
	await _settle_icons(tab)
	var bar := tab._grid.get_v_scroll_bar()
	bar.value = bar.max_value * 0.5
	await _settle_icons(tab)
	var row := tab.visible_range().x + 3
	print("  info  STAT grid scroll %.0f of %.0f; first visible row %d" % [bar.value, bar.max_value, tab.visible_range().x])
	tab.hover_row(row)
	await _wait_for_preview(preview)
	check(tab.visible_range().x > 1000 and preview.visible and preview.showing() == SpawnMenuTab._preview_model(tab.shown_rows()[row]),
			"scrolled halfway down the STATs, row %d (%s) shows" % [row, tab.shown_rows()[row]["display_name"]])
	_check_preview_place(tab, preview, row)
	tab._grid.mouse_exited.emit()
	check(not preview.visible and tab.item_icon(row) == tab._row_icon(tab.shown_rows()[row], tab._glyph(3)), "leaving the grid hides it and gives the icon back")

	tab.select_category(2)
	await _wait_for_types(tab, ["NPC_", "CREA"])
	tab.select_node("NPC_")
	await _settle_icons(tab)
	tab.hover_row(0)
	check(not preview.visible, "an NPC_ shows no preview yet (its MODL is a shared skeleton)")
	tab.select_node("CREA")
	# Any creature built of several parts, found in the data, searched by its
	# EditorID so it is on the first screen.
	var several := tab.catalog.rows_for_type("CREA").filter(func(r: Dictionary) -> bool:
		return (r["parts"] as PackedStringArray).size() > 1 and not String(r["editor_id"]).is_empty())
	if several.is_empty():
		print("  info  no CREA built of several parts; skipped")
	else:
		tab.apply_search(String(several[0]["editor_id"]))
		await _settle_icons(tab)
		var index := tab.shown_rows().find(several[0])
		var key := SpawnMenuTab._preview_model(several[0])
		tab.hover_row(index)
		var creature := await _wait_for_preview(preview)
		check(index >= 0 and creature != null and preview.showing() == key and creature.get_child_count() == key.split("|").size()
				and is_equal_approx(creature.rotation.y, PI),
				"a CREA (%s) previews its %d NIFZ parts together, not its skeleton, turned 180° to face the camera" % [several[0]["display_name"], key.split("|").size()])
		tab._grid.mouse_exited.emit()
	tab.apply_search("")
	tab.select_category(1)

## Moving the pointer over the hovered cell turns the model to face it:
## orbit_degrees of yaw at the cell's right and left edges, of pitch at its
## top and bottom, eased.
func _check_orbit(tab: SpawnMenuTab, preview: ModelPreview, index: int) -> void:
	var spin_from := preview.orbit()
	for _frame in 30:
		await get_tree().process_frame
	check(absf(angle_difference(spin_from.x, preview.orbit().x)) > 0.05 and absf(preview.orbit().y) < 0.01,
			"without Shift the model spins, level (yaw %.0f° -> %.0f°)" % [rad_to_deg(spin_from.x), rad_to_deg(preview.orbit().x)])
	preview.force_orbit = true
	var cell := tab._grid.get_item_rect(index)
	cell.position.y -= tab._grid.get_v_scroll_bar().value
	var reach := deg_to_rad(preview.orbit_degrees)
	var base := ThumbnailServer.start_pose().x
	# Points on the cell's very edge belong to the next cell, so the far
	# points are 10% in from it: 0.8 of the reach.
	for case in [[Vector2(0.9, 0.5), Vector2(0.8, 0)], [Vector2(0.1, 0.1), Vector2(-0.8, -0.8)], [Vector2(0.5, 0.9), Vector2(0, 0.8)]]:
		var at: Vector2 = cell.position + cell.size * case[0]
		var motion := InputEventMouseMotion.new()
		motion.position = at
		tab._on_grid_gui_input(motion)
		for _frame in 60:
			await get_tree().process_frame
		var want: Vector2 = case[1]
		var got := preview.orbit()
		check(absf(got.x - (base + want.x * reach)) < 0.03 and absf(got.y - want.y * reach) < 0.03,
				"the pointer at %s of the cell turns the model to yaw %.0f°, pitch %.0f° (got %.0f°, %.0f°)" % [
				case[0], rad_to_deg(base + want.x * reach), rad_to_deg(want.y * reach), rad_to_deg(got.x), rad_to_deg(got.y)])
	var centre := InputEventMouseMotion.new()
	centre.position = cell.get_center()
	tab._on_grid_gui_input(centre)
	preview.force_orbit = false
	# Shift through the real input path: held, the pointer at the cell's top
	# steers; released, the spin carries on and the pitch eases level.
	var top := InputEventMouseMotion.new()
	top.position = cell.position + cell.size * Vector2(0.5, 0.1)
	tab._on_grid_gui_input(top)
	var shift := InputEventKey.new()
	shift.keycode = KEY_SHIFT
	shift.physical_keycode = KEY_SHIFT
	shift.pressed = true
	Input.parse_input_event(shift)
	for _frame in 60:
		await get_tree().process_frame
	check(preview.is_orbiting() and absf(preview.orbit().y + 0.8 * reach) < 0.03, "holding Shift steers it with the pointer (pitch %.0f°)" % rad_to_deg(preview.orbit().y))
	shift = shift.duplicate()
	shift.pressed = false
	Input.parse_input_event(shift)
	var held := preview.orbit()
	for _frame in 60:
		await get_tree().process_frame
	check(not preview.is_orbiting() and absf(angle_difference(held.x, preview.orbit().x)) > 0.05 and absf(preview.orbit().y) < 0.03,
			"letting go of Shift spins it again and levels it (pitch %.0f°)" % rad_to_deg(preview.orbit().y))

## The meshes themselves turn with the pointer, for every WEAP and ARMO on the
## first screen of each: a NifRigidBody left in the tree used to pin its
## model in place while the pointer turned the pivot.
func _check_orbit_turns_meshes(tab: SpawnMenuTab, preview: ModelPreview) -> void:
	var still := []
	var turned := 0
	for type in ["WEAP", "ARMO"]:
		tab.select_node(type)
		await _settle_icons(tab)
		var range_ := tab.visible_range()
		for index in range(range_.x, mini(range_.y, range_.x + 24) + 1):
			if SpawnMenuTab._preview_model(tab.shown_rows()[index]).is_empty():
				continue
			tab.hover_row(index)
			var model := await _wait_for_preview(preview)
			if model == null:
				continue
			var meshes := model.find_children("*", "MeshInstance3D", true, false)
			if meshes.is_empty():
				continue
			var mesh: MeshInstance3D = meshes[0]
			var pivot := model.get_parent() as Node3D
			preview.force_orbit = true
			preview.set_pointer(Vector2(-1, -1))
			for _frame in 40:
				await get_tree().process_frame
			var first := mesh.global_basis
			preview.set_pointer(Vector2(1, 1))
			for _frame in 40:
				await get_tree().process_frame
			preview.force_orbit = false
			var relative := pivot.global_basis.inverse() * mesh.global_basis
			if mesh.global_basis.is_equal_approx(first) or not relative.is_equal_approx(pivot.global_basis.inverse() * mesh.global_basis):
				still.append(tab.shown_rows()[index]["display_name"])
			else:
				turned += 1
	check(turned > 10 and still.is_empty(), "the meshes of %d WEAP and ARMO previews turn with the pointer (still: %s)" % [turned, still])
	tab.select_node("WEAP", "weapons/1handpistol")
	await _settle_icons(tab)

## The preview is centred on row `index`'s icon and PREVIEW_SCALE times its size.
func _check_preview_place(tab: SpawnMenuTab, preview: ModelPreview, index: int) -> void:
	var icon := Vector2(tab._grid.fixed_icon_size)
	var centre_in_grid := preview.get_global_rect().get_center() - tab._grid.global_position
	check(tab._grid.get_item_at_position(centre_in_grid, true) == index and preview.size.is_equal_approx(icon * SpawnMenuTab.PREVIEW_SCALE),
			"over row %d's icon, %s px (the icon is %s)" % [index, preview.size, icon])

func _wait_for_preview(preview: ModelPreview) -> Node3D:
	var deadline := Time.get_ticks_msec() + 5000
	while preview.visible and (preview.model_root() == null or preview.showing() != preview._wanted) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	return preview.model_root()

## Waits until the tab has no icons waiting or loading.
func _settle_icons(tab: SpawnMenuTab) -> void:
	for _frame in 3:
		await get_tree().process_frame
	var deadline := Time.get_ticks_msec() + 10000
	while (tab.is_grid_filling() or tab.is_loading_thumbnails()) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	await get_tree().process_frame

func tree_type_item(tab: SpawnMenuTab, record_type: String) -> TreeItem:
	var tree: Tree = tab.get_node("Margin/VBox/Split/Tree")
	for item in tree.get_root().get_children():
		if (item.get_metadata(0) as Dictionary).get("type") == record_type:
			return item
	return null

## Waits until each of `types` is built in the tab's catalog.
func _wait_for_types(tab: SpawnMenuTab, types: Array) -> bool:
	var deadline := Time.get_ticks_msec() + 20000
	while not types.all(func(t: String) -> bool: return tab.catalog.is_type_ready(t)) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	return types.all(func(t: String) -> bool: return tab.catalog.is_type_ready(t))

## PlaceAtMe of 3 items, then picking up one: only that one is taken, and the
## other two stay on the floor. They were once placed at the player's feet,
## inside the floor, and fell out of the world when the pick-up woke them.
func _check_pick_up_one(placer: SpawnPlacer, player: ActorReference, misc: Dictionary) -> void:
	var had := _count_of(player.contents, int(misc["form_id"]))
	var result: Dictionary = ScriptServer.run_debug_line("player.PlaceAtMe %s 3" % misc["editor_id"])
	var placed: Array = placer.get_history().back()["references"] if result.get("ok") else []
	check(placed.size() == 3, "player.PlaceAtMe %s 3 places three" % misc["editor_id"])
	if placed.size() != 3:
		return
	for reference: EsmReference in placed:
		await _wait_for_node(reference)
	for _frame in 60:
		await get_tree().physics_frame
	check(player.pick_up(placed[0]), "the player picks one up")
	for _frame in 120:
		await get_tree().physics_frame
	check(_count_of(player.contents, int(misc["form_id"])) == had + 1, "the inventory gains exactly one")
	var floor_y := EsmReferencePhysicaliser.placement_transform(player.position, Vector3.ZERO).origin.y
	for reference: EsmReference in placed.slice(1):
		var node := EsmNode.node_for(reference)
		var body: Node3D = node.get("body") if node != null else null
		check(reference.current_space_form_id != 0 and reference.holder_instance_id.is_empty(), "%s is still placed" % reference.instance_id)
		check(body != null and body.global_position.y > floor_y - 0.25,
				"and its body rests on the floor, not below it (y %.2f, the player's feet %.2f)" % [body.global_position.y if body != null else NAN, floor_y])
	player.contents.remove_item(int(misc["form_id"]), 1)
	placer.undo()

func _first_with_model(catalog: SpawnCatalog, record_type: String, folder: String) -> Dictionary:
	for row: Dictionary in catalog.rows_for_type(record_type):
		if String(row["model"]).begins_with(folder) and not row["model_missing"] and not String(row["editor_id"]).is_empty():
			return row
	return {}

func _wait_for_node(reference: EsmReference) -> EsmNode:
	for _frame in 120:
		await get_tree().process_frame
		var node := EsmNode.node_for(reference)
		if node != null:
			return node
	return null

func _count_of(inventory: Inventory, form_id: int) -> int:
	var n := 0
	for item in inventory.get_items():
		if item.base_form_id == form_id:
			n += item.count
	return n

func _child(node: Dictionary, child_name: String) -> Dictionary:
	for child: Dictionary in node.get("children", []):
		if child["name"] == child_name:
			return child
	return {}
