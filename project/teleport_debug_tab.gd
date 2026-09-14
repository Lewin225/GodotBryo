extends Control

## Debug Tools window (game.tscn) -> TabContainer -> "Teleport" tab.
## Provides quick CenterOnCell (COC) teleportation to curated preset cells
## across the Mojave Wasteland, plus custom cell EditorID execution.

const PRESETS: Array[Dictionary] = [
	# Goodsprings
	{"name": "Doc Mitchell's House", "edid": "GSDocMitchellHouse", "cat": "Goodsprings"},
	{"name": "Prospector Saloon", "edid": "GSProspectorSaloonInterior", "cat": "Goodsprings"},
	{"name": "Goodsprings General Store", "edid": "GSGeneralStore", "cat": "Goodsprings"},
	{"name": "Goodsprings Schoolhouse", "edid": "GSSchoolHouse", "cat": "Goodsprings"},
	{"name": "Goodsprings Gas Station", "edid": "GSGasStation", "cat": "Goodsprings"},
	{"name": "Victor's Shack", "edid": "GSShackVictorInt", "cat": "Goodsprings"},
	{"name": "Goodsprings Abandoned Shack", "edid": "GSAbandonedShack", "cat": "Goodsprings"},
	{"name": "Goodsprings Home 01", "edid": "GSHouseInterior01", "cat": "Goodsprings"},
	{"name": "Goodsprings Home 02", "edid": "GSHouseInterior02", "cat": "Goodsprings"},
	{"name": "Goodsprings Home 03", "edid": "GSHouseInterior03", "cat": "Goodsprings"},
	{"name": "Goodsprings Cave", "edid": "SLGoodspringsCaveINT", "cat": "Goodsprings"},

	# Primm & Mojave Outpost
	{"name": "Vikki and Vance Casino", "edid": "VikkiAndVance", "cat": "Primm & Outpost"},
	{"name": "Bison Steve Hotel (1st Floor)", "edid": "BisonSteve01", "cat": "Primm & Outpost"},
	{"name": "Bison Steve Hotel (2nd Floor)", "edid": "BisonSteve02", "cat": "Primm & Outpost"},
	{"name": "Primm Sheriff's Office", "edid": "PrimmSheriffStation", "cat": "Primm & Outpost"},
	{"name": "Nash Residence / Mojave Express", "edid": "PrimmNashResidence", "cat": "Primm & Outpost"},
	{"name": "Deputy Beagle's Residence", "edid": "PrimmDeputyResidence", "cat": "Primm & Outpost"},
	{"name": "Mojave Outpost HQ", "edid": "MojaveOutpostHQ01", "cat": "Primm & Outpost"},
	{"name": "Mojave Outpost Barracks", "edid": "MojaveOutpostBarracks01", "cat": "Primm & Outpost"},
	{"name": "NCR Correctional Administration", "edid": "NCRPrisonAdministration", "cat": "Primm & Outpost"},

	# Novac & Boulder City
	{"name": "Dino Bite Gift Shop", "edid": "NovacGiftShop", "cat": "Novac & Boulder"},
	{"name": "Novac Motel Room (Player)", "edid": "NovacPlayersRoom", "cat": "Novac & Boulder"},
	{"name": "Dino Dee-lite Front Desk", "edid": "NovacMotelLobby", "cat": "Novac & Boulder"},
	{"name": "Jeannie May's House", "edid": "NovacJeannieMayHouse", "cat": "Novac & Boulder"},
	{"name": "No-Bark's Shack", "edid": "NovacNoBarksShack", "cat": "Novac & Boulder"},
	{"name": "Boone's Room", "edid": "NovacBoonesRoom", "cat": "Novac & Boulder"},
	{"name": "Manny Vargas' Room", "edid": "NovacVargasRoom", "cat": "Novac & Boulder"},
	{"name": "Ranger Andy's Bungalow", "edid": "NovacAndysRoom", "cat": "Novac & Boulder"},
	{"name": "Gibson Scrap Yard Garage", "edid": "GibsonScrapYardInterior", "cat": "Novac & Boulder"},
	{"name": "Big Horn Saloon", "edid": "BCSaloonInterior", "cat": "Novac & Boulder"},
	{"name": "Boulder City Train Station", "edid": "BCTrainStationInterior", "cat": "Novac & Boulder"},

	# The Strip & Freeside
	{"name": "The Tops Casino Floor", "edid": "TOPSCasino", "cat": "The Strip & Freeside"},
	{"name": "The Tops Restaurant", "edid": "TOPSRestaurant", "cat": "The Strip & Freeside"},
	{"name": "The Aces Theater", "edid": "TOPSAcesTheater", "cat": "The Strip & Freeside"},
	{"name": "The Tops Benny's Floor (13th)", "edid": "2ETopsBennysFloor", "cat": "The Strip & Freeside"},
	{"name": "The Tops Presidential Suite", "edid": "2ETopsPresidentialSuite", "cat": "The Strip & Freeside"},
	{"name": "Ultra-Luxe Casino Floor", "edid": "ULCasino", "cat": "The Strip & Freeside"},
	{"name": "Ultra-Luxe Penthouse", "edid": "ULPenthouse", "cat": "The Strip & Freeside"},
	{"name": "The Gourmand at Ultra-Luxe", "edid": "ULGourmand", "cat": "The Strip & Freeside"},
	{"name": "Ultra-Luxe Bathhouse", "edid": "ULBath", "cat": "The Strip & Freeside"},
	{"name": "Gomorrah Main Level", "edid": "Gomorrah01", "cat": "The Strip & Freeside"},
	{"name": "Gomorrah Lower Lobby", "edid": "Gomorrah00", "cat": "The Strip & Freeside"},
	{"name": "Gomorrah Suites", "edid": "Gomorrah03", "cat": "The Strip & Freeside"},
	{"name": "Lucky 38 Casino Floor", "edid": "Lucky38CasinoFloor01", "cat": "The Strip & Freeside"},
	{"name": "Lucky 38 Penthouse", "edid": "Lucky38Penthouse", "cat": "The Strip & Freeside"},
	{"name": "Lucky 38 Floor 22 Suite", "edid": "Lucky38SuiteFloor22", "cat": "The Strip & Freeside"},
	{"name": "Lucky 38 Control Room", "edid": "Lucky38ControlRoom", "cat": "The Strip & Freeside"},
	{"name": "Vault 21 Gift Shop", "edid": "2EOVault21GiftShop", "cat": "The Strip & Freeside"},
	{"name": "Vault 21", "edid": "2EOVault21", "cat": "The Strip & Freeside"},
	{"name": "Michael Angelo's Workshop", "edid": "2EOMichaelAngelo", "cat": "The Strip & Freeside"},
	{"name": "NCR Embassy", "edid": "2ENCREmbassy01", "cat": "The Strip & Freeside"},
	{"name": "Atomic Wrangler Casino", "edid": "FreesideAtomicWrangler", "cat": "The Strip & Freeside"},
	{"name": "King's School of Impersonation", "edid": "FreesideKingsHouse", "cat": "The Strip & Freeside"},
	{"name": "Mick & Ralph's", "edid": "FreesideMickandRalphs", "cat": "The Strip & Freeside"},
	{"name": "Silver Rush", "edid": "FreesideSilverRush", "cat": "The Strip & Freeside"},
	{"name": "Old Mormon Fort", "edid": "FreesideFortInterior", "cat": "The Strip & Freeside"},
	{"name": "Cerulean Robotics", "edid": "FreesideRobotShop", "cat": "The Strip & Freeside"},
	{"name": "Miguel's Pawn Shop", "edid": "WestsidePawnShopInterior", "cat": "The Strip & Freeside"},
	{"name": "Casa Madrid Apartments", "edid": "WestsideCasaMadridApartments", "cat": "The Strip & Freeside"},
	{"name": "The Thorn", "edid": "OVWestSewers03", "cat": "The Strip & Freeside"},

	# Vaults
	{"name": "Vault 3 (Recreation Area)", "edid": "Vault3a", "cat": "Vaults"},
	{"name": "Vault 3 (Living Quarters)", "edid": "Vault3b", "cat": "Vaults"},
	{"name": "Vault 11 (Entrance)", "edid": "Vault11a", "cat": "Vaults"},
	{"name": "Vault 11 (Living Quarters)", "edid": "Vault11b", "cat": "Vaults"},
	{"name": "Vault 19 (1st Floor)", "edid": "Vault19a", "cat": "Vaults"},
	{"name": "Vault 22 (Entrance Hall)", "edid": "Vault22a", "cat": "Vaults"},
	{"name": "Vault 22 (Common Areas)", "edid": "Vault22d", "cat": "Vaults"},
	{"name": "Vault 34 (1st Floor)", "edid": "Vault34a", "cat": "Vaults"},
	{"name": "Vault 34 (Armory)", "edid": "Vault34c", "cat": "Vaults"},

	# Key Landmarks & Factions
	{"name": "Camp McCarran Concourse", "edid": "CampMCTermInt01", "cat": "Landmarks & Factions"},
	{"name": "Camp McCarran Terminal Building", "edid": "CampMCTermInt02", "cat": "Landmarks & Factions"},
	{"name": "Camp Golf House Resort", "edid": "2CCampGolfResort", "cat": "Landmarks & Factions"},
	{"name": "Camp Forlorn Hope Command", "edid": "CampForlornHopeCommandCenter", "cat": "Landmarks & Factions"},
	{"name": "Hoover Dam Visitor Center", "edid": "HooverDamIntODeck", "cat": "Landmarks & Factions"},
	{"name": "Hoover Dam Power Plant 01", "edid": "HooverDamIntPowerPlant01", "cat": "Landmarks & Factions"},
	{"name": "Hoover Dam Offices", "edid": "HooverDamIntPowerPlant01b", "cat": "Landmarks & Factions"},
	{"name": "HELIOS One Power Plant", "edid": "HELIOSOnePlant", "cat": "Landmarks & Factions"},
	{"name": "HELIOS One Solar Tower", "edid": "HELIOSOneTower", "cat": "Landmarks & Factions"},
	{"name": "REPCONN Office Main Floor", "edid": "RepconHQ01", "cat": "Landmarks & Factions"},
	{"name": "REPCONN Test Facility", "edid": "RocketLabMid", "cat": "Landmarks & Factions"},
	{"name": "REPCONN Facility Basement", "edid": "RocketLabBasement", "cat": "Landmarks & Factions"},
	{"name": "Sunset Sarsaparilla Factory", "edid": "SSHQ01", "cat": "Landmarks & Factions"},
	{"name": "Gun Runners Headquarters", "edid": "GunRunnerHQInterior", "cat": "Landmarks & Factions"},
	{"name": "Jacobstown Lodge", "edid": "JacobstownLodge", "cat": "Landmarks & Factions"},
	{"name": "Black Mountain Broadcast Station", "edid": "BlackMountainRadio", "cat": "Landmarks & Factions"},
	{"name": "Hidden Valley Bunker L1", "edid": "HiddenValley01", "cat": "Landmarks & Factions"},
	{"name": "Nellis Boomer Hangar", "edid": "NellisHangar1", "cat": "Landmarks & Factions"},
	{"name": "Nellis Boomer Museum", "edid": "NellisMuseum", "cat": "Landmarks & Factions"},
	{"name": "Great Khan Longhouse", "edid": "4BRRCPapasCabin", "cat": "Landmarks & Factions"},
	{"name": "Legate's War Tent", "edid": "LegateCampTent", "cat": "Landmarks & Factions"},

	# Dev & Test Cells
	{"name": "Dev Armory", "edid": "DevArmory", "cat": "Dev & Test"},
	{"name": "Mentats Test Level", "edid": "TestDance", "cat": "Dev & Test"},
	{"name": "Josh's Weapon Test", "edid": "TestJoshWeapons", "cat": "Dev & Test"},
	{"name": "Trap Testing Cell", "edid": "TestTraps", "cat": "Dev & Test"},
	{"name": "Endgame Slide Room", "edid": "Endgame", "cat": "Dev & Test"},
]

const CATEGORIES: Array[String] = [
	"All",
	"Goodsprings",
	"Primm & Outpost",
	"Novac & Boulder",
	"The Strip & Freeside",
	"Vaults",
	"Landmarks & Factions",
	"Dev & Test",
]

@onready var _cell_input: LineEdit = $Margin/VBox/QuickRow/CellInput
@onready var _teleport_btn: Button = $Margin/VBox/QuickRow/TeleportBtn
@onready var _current_btn: Button = $Margin/VBox/QuickRow/CurrentBtn
@onready var _status_label: RichTextLabel = $Margin/VBox/StatusLabel
@onready var _category_filter: OptionButton = $Margin/VBox/PresetsHeader/CategoryFilter
@onready var _search_filter: LineEdit = $Margin/VBox/PresetsHeader/SearchFilter
@onready var _preset_tree: Tree = $Margin/VBox/PresetTree
@onready var _teleport_selected_btn: Button = $Margin/VBox/ButtonsRow/TeleportSelectedBtn

var _engine: ScriptEngine


func _ready() -> void:
	_engine = get_tree().root.get_node_or_null("Game/ScriptEngine") as ScriptEngine
	_setup_tree()
	_setup_categories()

	_teleport_btn.pressed.connect(_on_teleport_pressed)
	_current_btn.pressed.connect(_on_current_cell_pressed)
	_cell_input.text_submitted.connect(func(_t: String) -> void: _on_teleport_pressed())
	_teleport_selected_btn.pressed.connect(_on_teleport_selected_pressed)

	_category_filter.item_selected.connect(func(_i: int) -> void: _refresh_tree())
	_search_filter.text_changed.connect(func(_t: String) -> void: _refresh_tree())

	_preset_tree.item_activated.connect(_on_tree_item_activated)
	_preset_tree.item_selected.connect(_on_tree_item_selected)

	_refresh_tree()


func _setup_tree() -> void:
	_preset_tree.columns = 3
	_preset_tree.column_titles_visible = true
	_preset_tree.hide_root = true
	_preset_tree.select_mode = Tree.SELECT_ROW

	_preset_tree.set_column_title(0, "Location / Destination")
	_preset_tree.set_column_expand(0, true)

	_preset_tree.set_column_title(1, "EditorID")
	_preset_tree.set_column_expand(1, false)
	_preset_tree.set_column_custom_minimum_width(1, 240)

	_preset_tree.set_column_title(2, "Category")
	_preset_tree.set_column_expand(2, false)
	_preset_tree.set_column_custom_minimum_width(2, 170)


func _setup_categories() -> void:
	_category_filter.clear()
	for cat in CATEGORIES:
		_category_filter.add_item(cat)


func _refresh_tree() -> void:
	_preset_tree.clear()
	var root := _preset_tree.create_item()

	var selected_cat_idx: int = _category_filter.selected
	var selected_cat := CATEGORIES[selected_cat_idx] if selected_cat_idx >= 0 and selected_cat_idx < CATEGORIES.size() else "All"
	var search_text := _search_filter.text.to_lower().strip_edges()

	var count := 0
	for preset in PRESETS:
		var name: String = preset["name"]
		var edid: String = preset["edid"]
		var cat: String = preset["cat"]

		if selected_cat != "All" and cat != selected_cat:
			continue

		if not search_text.is_empty():
			var matches_name := name.to_lower().find(search_text) != -1
			var matches_edid := edid.to_lower().find(search_text) != -1
			var matches_cat := cat.to_lower().find(search_text) != -1
			if not (matches_name or matches_edid or matches_cat):
				continue

		var item := _preset_tree.create_item(root)
		item.set_metadata(0, edid)

		item.set_text(0, name)
		item.set_custom_color(0, Color("#e5c07b"))

		item.set_text(1, edid)
		item.set_custom_color(1, Color("#61afef"))

		item.set_text(2, cat)
		item.set_custom_color(2, Color("#c678dd"))

		count += 1


func _on_tree_item_selected() -> void:
	var selected := _preset_tree.get_selected()
	if selected == null:
		return
	var edid: String = selected.get_metadata(0)
	if not edid.is_empty():
		_cell_input.text = edid


func _on_tree_item_activated() -> void:
	var selected := _preset_tree.get_selected()
	if selected == null:
		return
	var edid: String = selected.get_metadata(0)
	if not edid.is_empty():
		teleport_to(edid)


func _on_teleport_selected_pressed() -> void:
	var selected := _preset_tree.get_selected()
	if selected == null:
		_status_label.text = "[color=#e5c07b]Select a preset destination first[/color]"
		return
	var edid: String = selected.get_metadata(0)
	if not edid.is_empty():
		teleport_to(edid)


func _on_teleport_pressed() -> void:
	var edid := _cell_input.text.strip_edges()
	if edid.is_empty():
		_status_label.text = "[color=#e06c75]Please enter a Cell EditorID to teleport[/color]"
		return
	teleport_to(edid)


func _on_current_cell_pressed() -> void:
	var game: Node = get_tree().root.get_node_or_null("Game")
	if game == null:
		_status_label.text = "[color=#e06c75]Game root node not found[/color]"
		return
	var esm: EsmReader = game._typed_esm_reader() if game.has_method("_typed_esm_reader") else null
	if esm == null and _engine != null:
		esm = _engine.esm
	if esm == null:
		_status_label.text = "[color=#e06c75]ESM reader not available[/color]"
		return
	var current_id := 0
	if "cell_streamer" in game and game.cell_streamer != null:
		current_id = game.cell_streamer.get_current_cell_form_id()
	if current_id == 0 and "world_streamer" in game and game.world_streamer != null:
		current_id = game.world_streamer.get_current_cell_form_id()
	if current_id != 0:
		var edid := esm.get_cell_editor_id(current_id)
		_cell_input.text = edid if not edid.is_empty() else "0x%08X" % current_id
		_status_label.text = "[color=#98c379]Current cell: [b]%s[/b] (0x%08X)[/color]" % [_cell_input.text, current_id]
	else:
		_status_label.text = "[color=#7f848e]No active cell loaded[/color]"


func teleport_to(editor_id: String) -> void:
	if _engine == null:
		_engine = get_tree().root.get_node_or_null("Game/ScriptEngine") as ScriptEngine
	if _engine == null:
		_status_label.text = "[color=#e06c75]ScriptEngine not found[/color]"
		return

	# Send command directly to the scripting engine (matches scripting_debug_tab _run_line)
	var cmd := "coc " + editor_id
	var reply: Dictionary = _engine.run_debug_line(cmd)
	if not bool(reply.get("ok", false)):
		_status_label.text = "[color=#e06c75]✗ %s[/color]" % String(reply.get("message", "Teleport failed"))
	else:
		var cell_form_id := int(reply.get("result", 0))
		_status_label.text = "[color=#98c379]✓ Teleported to [b]%s[/b] [color=#61afef](0x%08X)[/color][/color]" % [editor_id, cell_form_id]
		_cell_input.text = editor_id
