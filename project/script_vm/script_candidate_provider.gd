class_name ScriptCandidateProvider
extends RefCounted

## Dynamically generates, aggregates, and caches autocomplete candidate lists
## for the Scripting Debug Console.
##
## All candidates are harvested dynamically at runtime from registered engine
## state (ScriptFunctionRegistry, TeleportDebugTab presets, live inventory entries,
## and live script instances) without hardcoded static lists.


## Returns the dynamically aggregated list of all executable commands & keywords.
## Only functions registered in ScriptFunctionRegistry are included.
static func get_command_candidates(engine: Node = null, instances: Array = []) -> Array[String]:
	var candidates: Array[String] = []

	# Get registered functions from active engine registry (or default registry)
	var reg_names: Array[String] = []
	if engine != null and engine.function_registry != null:
		reg_names = engine.function_registry.get_registered_function_names()
	else:
		var default_reg := ScriptFunctionRegistry.new()
		reg_names = default_reg.get_registered_function_names()

	for fn_name in reg_names:
		if not candidates.has(fn_name):
			candidates.append(fn_name)
		var player_scoped := "Player." + fn_name
		if not candidates.has(player_scoped):
			candidates.append(player_scoped)

	# GECK basic variable assignment keyword
	if not candidates.has("Set"):
		candidates.append("Set")

	# Dynamically include live script instance nodes & FormIDs
	for entry in instances:
		var node_name := String(entry.get("name", ""))
		var script_name := String(entry.get("script_name", ""))
		var form_hex := "0x%X" % int(entry.get("script_form_id", 0))
		if not node_name.is_empty() and not candidates.has(node_name):
			candidates.append(node_name)
		if not script_name.is_empty() and not candidates.has(script_name):
			candidates.append(script_name)
		if not candidates.has(form_hex):
			candidates.append(form_hex)

	return candidates


## Returns the dynamically aggregated list of all location/cell destinations.
static func get_cell_candidates(esm: EsmReader = null) -> Array[String]:
	var cells: Array[String] = []

	# 1. Dynamically harvest all real cell EditorIDs from active ESM
	if esm != null and esm.has_method("get_all_cell_candidates"):
		var esm_cells: PackedStringArray = esm.get_all_cell_candidates()
		for c in esm_cells:
			if not cells.has(c):
				cells.append(c)

	# 2. Dynamically harvest from Teleport tab presets
	var teleport_script: GDScript = load("res://teleport_debug_tab.gd")
	if teleport_script != null:
		var presets_arr: Variant = teleport_script.get("PRESETS")
		if presets_arr is Array:
			for entry in (presets_arr as Array):
				if entry is Dictionary and entry.has("edid"):
					var edid: String = String(entry["edid"]).strip_edges()
					if not edid.is_empty() and not cells.has(edid):
						cells.append(edid)

	return cells


## Returns the dynamically aggregated list of all item candidates from active ESM and inventory.
static func get_item_candidates(engine_or_game: Object = null, optional_game_node: Object = null) -> Array[String]:
	var items: Array[String] = []

	var engine: Node = null
	var game_node: Object = null

	if engine_or_game != null and "function_registry" in engine_or_game:
		engine = engine_or_game as Node
		game_node = optional_game_node
	else:
		game_node = engine_or_game if engine_or_game != null else optional_game_node

	# 1. Dynamically extract all items (WEAP, ARMO, AMMO, ALCH, MISC, KEYM, BOOK) from active ESM
	var esm: EsmReader = engine.function_registry.esm if engine != null else null
	if esm == null and game_node != null and "esm" in game_node and game_node.esm != null:
		esm = game_node.esm as EsmReader

	if esm != null and esm.has_method("get_all_item_candidates"):
		var esm_items: PackedStringArray = esm.get_all_item_candidates()
		for itm in esm_items:
			if not items.has(itm):
				items.append(itm)

	# 2. Dynamically inspect player/game inventory if available
	var inv: Object = null
	if game_node is Inventory:
		inv = game_node
	elif game_node != null:
		var inv_prop: Variant = game_node.get("inventory")
		if inv_prop is Object:
			inv = inv_prop as Object
		elif game_node.has_meta("inventory"):
			var meta_inv: Variant = game_node.get_meta("inventory")
			if meta_inv is Object:
				inv = meta_inv as Object

	if inv != null and inv.has_method("get_entries"):
		var entries: Array = inv.call("get_entries")
		for e in entries:
			var form_id: int = int(e.get("base_form_id", 0))
			var edid: String = String(e.get("editor_id", "")).strip_edges()
			var full_name: String = String(e.get("full_name", "")).strip_edges()
			var hex_str := "0x%08X" % form_id
			if not edid.is_empty() and not items.has(edid):
				items.append(edid)
			if not full_name.is_empty() and not items.has(full_name):
				items.append(full_name)
			if form_id != 0 and not items.has(hex_str):
				items.append(hex_str)

	return items


## Returns message candidates extracted from live script instances
static func get_message_candidates(_engine: Node = null, instances: Array = []) -> Array[String]:
	var messages: Array[String] = []
	for entry in instances:
		var source_text: String = String(entry.get("source_text", ""))
		if source_text.containsn("ShowMessage"):
			var lines := source_text.split("\n")
			for line in lines:
				var trimmed := line.strip_edges()
				if trimmed.begins_with(";") or trimmed.is_empty():
					continue
				var idx := trimmed.findn("ShowMessage")
				if idx != -1:
					var after := trimmed.substr(idx + 11).strip_edges()
					var tokens := after.split(" ", false)
					if not tokens.is_empty():
						var msg_name := tokens[0].strip_edges()
						if not msg_name.is_empty() and not messages.has(msg_name):
							messages.append(msg_name)

	return messages


## Returns placeable candidates from items and live instances
static func get_placeable_candidates(game_node: Node = null, instances: Array = []) -> Array[String]:
	var list: Array[String] = get_item_candidates(game_node)
	for entry in instances:
		var node_name := String(entry.get("name", ""))
		if not node_name.is_empty() and not list.has(node_name):
			list.append(node_name)
	return list


## Returns local variables for the selected node from actual script locals
static func get_variable_candidates(selected_reference: EsmReference = null, instances: Array = []) -> Array[String]:
	var vars: Array[String] = []
	for entry in instances:
		if selected_reference == null or entry.get("reference") == selected_reference:
			var locals_dict: Dictionary = entry.get("locals", {})
			for k in locals_dict:
				if not vars.has(k):
					vars.append(k)
	return vars


## Returns live references from instances and Player
static func get_reference_candidates(instances: Array = []) -> Array[String]:
	var refs: Array[String] = ["Player"]
	for entry in instances:
		var node_name := String(entry.get("name", ""))
		if not node_name.is_empty() and not refs.has(node_name):
			refs.append(node_name)
	return refs


## Resolves contextual candidates based on line tokens and argument position
static func get_contextual_candidates(
	left_text: String,
	engine: Node = null,
	selected_reference: EsmReference = null,
	instances: Array = [],
	game_node: Node = null
) -> Array[String]:
	var trimmed := left_text.lstrip(" \t")
	var ends_with_space := left_text.ends_with(" ") or left_text.ends_with("\t")
	var tokens := trimmed.split(" ", false)

	if tokens.is_empty():
		return get_command_candidates(engine, instances)

	var cmd := tokens[0].to_lower()
	var arg_idx: int = tokens.size() - 1
	if ends_with_space:
		arg_idx += 1

	if arg_idx == 0:
		return get_command_candidates(engine, instances)

	if arg_idx == 1:
		match cmd:
			"coc", "centeroncell":
				return get_cell_candidates(engine.function_registry.esm if engine != null else null)
			"showmessage":
				return get_message_candidates(engine, instances)
			"additem", "removeitem", "player.additem", "player.removeitem", "equipitem", "unequipitem", "getitemcount":
				return get_item_candidates(engine, game_node)
			"placeatme", "player.placeatme":
				return get_placeable_candidates(game_node, instances)
			"setopenstate", "setdestroyed", "sethardcore", "player.sethardcore":
				return ["0", "1"]
			"set", "player.set":
				return get_variable_candidates(selected_reference, instances)
			"kill", "resurrect", "enable", "disable", "getdisabled", "getdead":
				return get_reference_candidates(instances)

	if arg_idx == 2:
		match cmd:
			"set", "player.set":
				return ["to"]

	return get_command_candidates(engine, instances)
