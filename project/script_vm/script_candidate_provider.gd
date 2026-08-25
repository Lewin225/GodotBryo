class_name ScriptCandidateProvider
extends RefCounted

## Dynamically generates, aggregates, and caches autocomplete candidate lists
## for the Scripting Debug Console.
##
## Whenever new commands are registered in ScriptFunctionRegistry, new cell
## presets are added to TeleportDebugTab, or new item definitions/inventories
## are registered, ScriptCandidateProvider automatically aggregates them.

# Baseline fallback commands and GECK keywords
const BASE_KEYWORDS: Array[String] = [
	"ShowMessage", "GetButtonPressed", "PlaceAtMe", "CenterOnCell", "COC",
	"AddItem", "RemoveItem", "GetItemCount", "EquipItem", "UnequipItem",
	"Disable", "Enable", "GetDisabled", "Kill", "GetDead", "Resurrect",
	"SetOpenState", "GetOpenState", "PlayGroup", "SetHardcore", "GetHardcore",
	"MarkForDelete", "SetDestroyed", "GetDestroyed", "SetScale", "GetScale",
	"MoveTo", "PositionCell", "StopCombat", "StartCombat", "ResetHealth",
	"tcl", "TCL", "ToggleCollision", "Activate", "IsActionRef", "GetActionRef", "Unlock",
	"Player.Disable", "Player.Enable", "Player.AddItem", "Player.RemoveItem",
	"Player.PlaceAtMe", "Player.MoveTo", "Player.Kill", "Player.Resurrect",
	"Player.SetHardcore", "Player.tcl", "Player.ToggleCollision",
	"Set bInitialized to", "Set fTimer to", "Set iCount to"
]

const BASE_ITEMS: Array[String] = [
	"Caps001", "0x0000000F", "BobbyPin", "PreWarMoney", "NCRMoney", "LegionMoney", "REPCONNKeycard", "0x000E2C80",
	"Stimpak", "0x00004334", "SuperStimpak", "DoctorBag", "0x00004332", "RadAway", "0x00004342", "RadX", "0x00004340",
	"MedX", "Buffout", "Mentats", "Psycho", "Jet", "PurifiedWater", "SunsetSarsaparilla", "NukaCola",
	"WeapNV9mmPistol", "WeapNV9mmSMG", "0x001465A6", "WeapNVServiceRifle", "0x000E377A", "WeapNVHuntingRifle",
	"WeapNVDynamite", "0x000E3778", "WeapNVFragGrenade", "WeapNVLaserRifle", "WeapNVPlasmaPistol", "WeapNVSuperSledge",
	"Ammo9mm", "Ammo556mm", "Ammo308", "Ammo10mm", "Ammo12Gauge", "Ammo20Gauge", "AmmoEnergyCell", "AmmoMicroFusionCell"
]

const BASE_MESSAGES: Array[String] = [
	"GSBrokenSMGMsg", "GenericDoorLocked", "VMS03Msg01", "VMS03Msg02"
]

const ANIM_GROUPS: Array[String] = [
	"Forward", "Backward", "Left", "Right", "Idle", "Attack", "Equip", "Unequip", "SpecialIdle"
]

const QUANTITY_PRESETS: Array[String] = [
	"1", "5", "10", "25", "50", "100"
]


## Returns the dynamically aggregated list of all executable commands & keywords.
static func get_command_candidates(engine: ScriptEngine = null, instances: Array = []) -> Array[String]:
	var candidates: Array[String] = BASE_KEYWORDS.duplicate()

	# Dynamically include all functions registered in ScriptFunctionRegistry
	if engine != null and engine.function_registry != null:
		for fn_name in engine.function_registry.get_registered_function_names():
			if not candidates.has(fn_name):
				candidates.append(fn_name)
			var player_scoped := "Player." + fn_name
			if not candidates.has(player_scoped):
				candidates.append(player_scoped)

	# Dynamically include live script instance nodes & FormIDs
	for entry in instances:
		var node_name := String(entry.get("node_name", ""))
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
static func get_cell_candidates(_esm: EsmReader = null) -> Array[String]:
	var cells: Array[String] = []

	# Dynamically harvest from Teleport tab presets
	var teleport_script: GDScript = load("res://teleport_debug_tab.gd")
	if teleport_script != null:
		var presets_arr: Variant = teleport_script.get("PRESETS")
		if presets_arr is Array:
			for entry in (presets_arr as Array):
				if entry is Dictionary and entry.has("edid"):
					var edid: String = String(entry["edid"]).strip_edges()
					if not edid.is_empty() and not cells.has(edid):
						cells.append(edid)

	# Baseline fallback cells if presets not loaded
	if cells.is_empty():
		for c in [
			"GSDocMitchellHouse", "GoodspringsGasStation", "GoodspringsSaloon",
			"NovacGiftShop", "NovacPlayersRoom", "TOPSCasino", "Lucky38CasinoFloor01",
			"DevArmory", "Vault21"
		]:
			cells.append(c)

	return cells


## Returns the dynamically aggregated list of all item candidates.
static func get_item_candidates(game_node: Node = null) -> Array[String]:
	var items: Array[String] = BASE_ITEMS.duplicate()

	# Dynamically inspect player inventory if available
	if game_node != null and "inventory" in game_node and game_node.inventory != null:
		if game_node.inventory.has_method("get_entries"):
			var entries: Array = game_node.inventory.get_entries()
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


## Returns message candidates
static func get_message_candidates(_esm: EsmReader = null) -> Array[String]:
	return BASE_MESSAGES.duplicate()


## Returns placeable candidates
static func get_placeable_candidates(game_node: Node = null) -> Array[String]:
	var list: Array[String] = get_item_candidates(game_node)
	for c in ["GSDocMitchellDoor", "GSRadio", "Caps001", "WeapNVDynamite", "Stimpak"]:
		if not list.has(c):
			list.append(c)
	return list


## Returns local variables for the selected node or common GECK variables
static func get_variable_candidates(selected_node: Node = null, instances: Array = []) -> Array[String]:
	var vars: Array[String] = ["bInitialized", "fTimer", "iCount", "bQuestDone", "bDoOnce", "iState"]
	for entry in instances:
		if selected_node != null and entry.get("node") == selected_node:
			var locals_dict: Dictionary = entry.get("locals", {})
			for k in locals_dict:
				if not vars.has(k):
					vars.append(k)
	return vars


## Returns live references
static func get_reference_candidates(instances: Array = []) -> Array[String]:
	var refs: Array[String] = ["Player"]
	for entry in instances:
		var node_name := String(entry.get("node_name", ""))
		if not node_name.is_empty() and not refs.has(node_name):
			refs.append(node_name)
	return refs


## Resolves contextual candidates based on line tokens and argument position
static func get_contextual_candidates(
	left_text: String,
	engine: ScriptEngine = null,
	selected_node: Node = null,
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
				return get_cell_candidates(engine.esm if engine != null else null)
			"showmessage":
				return get_message_candidates(engine.esm if engine != null else null)
			"additem", "removeitem", "player.additem", "player.removeitem", "equipitem", "unequipitem", "getitemcount":
				return get_item_candidates(game_node)
			"placeatme", "player.placeatme":
				return get_placeable_candidates(game_node)
			"playgroup":
				return ANIM_GROUPS.duplicate()
			"setopenstate", "setdestroyed", "sethardcore", "player.sethardcore":
				return ["0", "1"]
			"set", "player.set":
				return get_variable_candidates(selected_node, instances)
			"kill", "resurrect", "enable", "disable", "getdisabled", "getdead":
				return get_reference_candidates(instances)

	if arg_idx == 2:
		match cmd:
			"additem", "removeitem", "player.additem", "player.removeitem":
				return QUANTITY_PRESETS.duplicate()
			"set", "player.set":
				return ["to"]
			"placeatme", "player.placeatme":
				return ["1", "0,0,0"]

	return get_command_candidates(engine, instances)
