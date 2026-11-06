extends MarginContainer

## The main scene. Says how much is missing, shows which FalloutNV.esm the
## servers loaded, lets the player pick another, and starts a new game in Doc
## Mitchell's house (game.tscn) or loads a save from the list (SaveServer's
## backend; game.gd's load_save_id). A drop-down picks the save storage
## from SaveServer's registered backends (SaveServer.set_storage()).
##
## The servers open the game data once, when they load, from
## GameDataConfig.resolve(). Choosing a different ESM saves its folder with
## GameDataConfig.save_data_dir() and restarts the application, so the servers
## load it.

const GameDataConfigScript := preload("res://game_data_config.gd")
const GameScript := preload("res://game.gd")
const GAME_SCENE := "res://game.tscn"

@onready var _data_label: Label = %DataLabel
@onready var _status_label: Label = %StatusLabel
@onready var _choose_button: Button = %ChooseButton
@onready var _new_game_button: Button = %NewGameButton
@onready var _custom_start_button: Button = %CustomStartButton
@onready var _startup_script_edit: CodeEdit = %StartupScriptEdit
@onready var _quit_button: Button = %QuitButton
@onready var _save_list: ItemList = %SaveList
@onready var _load_button: Button = %LoadButton
@onready var _storage_option: OptionButton = %StorageOption
@onready var _esm_dialog: FileDialog = %EsmDialog

var _loaded_data_dir := ""


func _ready() -> void:
	_loaded_data_dir = GameDataSettings.get_data_dir()
	_choose_button.pressed.connect(_on_choose_pressed)
	_new_game_button.pressed.connect(_on_new_game_pressed)
	_custom_start_button.pressed.connect(_on_custom_start_pressed)
	_quit_button.pressed.connect(get_tree().quit)
	_load_button.pressed.connect(_on_load_pressed)
	_save_list.item_activated.connect(func(_index: int) -> void: _on_load_pressed())
	_load_button.disabled = true
	_fill_storage_options()
	_storage_option.item_selected.connect(_on_storage_selected)
	_esm_dialog.file_selected.connect(_on_esm_selected)
	_new_game_button.disabled = true
	_custom_start_button.disabled = true
	_startup_script_edit.editable = false
	_show_configuration()
	if _loaded_data_dir.is_empty():
		return
	if EsmServer.is_ready():
		_on_esm_ready()
		return
	EsmServer.esm_ready.connect(_on_esm_ready)
	EsmServer.failed.connect(_on_esm_failed)


func _show_configuration() -> void:
	var config: Dictionary = GameDataSettings.get_config()
	if _loaded_data_dir.is_empty():
		_data_label.text = "No ESM picked yet."
		return
	_data_label.text = "ESM: " + (_loaded_data_dir + GameDataConfigScript.ESM_FILE).simplify_path()
	_status_label.text = "Loading..."
	if String(config.get("source", "")) == "environment":
		_choose_button.disabled = true
		_choose_button.tooltip_text = "Set by the GODOTBRYO_DATA_DIR environment variable."


func _on_esm_ready() -> void:
	_status_label.text = "Ready."
	_new_game_button.disabled = false
	_custom_start_button.disabled = false
	_startup_script_edit.editable = true
	_list_saves()


## Fills the save list, newest first: each save's name, the cell the player
## is in, and when it was saved (UTC).
func _list_saves() -> void:
	_save_list.clear()
	var saves := SaveServer.get_backend().list()
	saves.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a.get("saved_at", "")) > String(b.get("saved_at", "")))
	for header: Dictionary in saves:
		var text := "%s   %s   %s" % [header["save_id"], header.get("player_cell", ""), String(header.get("saved_at", "")).replace("T", " ")]
		var index := _save_list.add_item(text)
		_save_list.set_item_metadata(index, String(header["save_id"]))
	_load_button.disabled = saves.is_empty()
	if not saves.is_empty():
		_save_list.select(0)


## One entry per registered backend, named by its title, with the one in use
## selected.
func _fill_storage_options() -> void:
	_storage_option.clear()
	for backend_key: String in SaveServer.backends:
		var backend: SaveBackend = SaveServer.backends[backend_key]
		_storage_option.add_item(backend.title)
		var index := _storage_option.item_count - 1
		_storage_option.set_item_metadata(index, backend_key)
		if backend_key == SaveServer.backend_name:
			_storage_option.select(index)


## Switches storage and lists the saves kept there.
func _on_storage_selected(index: int) -> void:
	SaveServer.set_storage(String(_storage_option.get_item_metadata(index)))
	if EsmServer.is_ready():
		_list_saves()


func _on_load_pressed() -> void:
	var selected := _save_list.get_selected_items()
	if selected.is_empty():
		return
	GameScript.load_save_id = String(_save_list.get_item_metadata(selected[0]))
	get_tree().change_scene_to_file(GAME_SCENE)


func _on_esm_failed(message: String) -> void:
	_status_label.text = "The ESM failed to load: " + message


func _on_choose_pressed() -> void:
	if not _loaded_data_dir.is_empty():
		_esm_dialog.current_dir = _loaded_data_dir
	_esm_dialog.popup_centered_ratio(0.6)


## Saves the chosen ESM's folder and restarts so the servers load it.
func _on_esm_selected(path: String) -> void:
	if path.get_file().to_lower() != GameDataConfigScript.ESM_FILE.to_lower():
		_status_label.text = "Pick %s from the game's Data folder." % GameDataConfigScript.ESM_FILE
		return
	var data_dir := GameDataConfigScript.normalise_data_dir(path.get_base_dir())
	if not GameDataConfigScript.save_data_dir(data_dir):
		_status_label.text = "Could not save the game data folder."
		return
	if data_dir == _loaded_data_dir:
		return
	_status_label.text = "Restarting to load it..."
	OS.set_restart_on_exit(true, OS.get_cmdline_args())
	get_tree().quit()


func _on_new_game_pressed() -> void:
	GameScript.startup_script = ""
	get_tree().change_scene_to_file(GAME_SCENE)


func _on_custom_start_pressed() -> void:
	var script := _startup_script_edit.text.strip_edges()
	if script.is_empty():
		_status_label.text = "Enter a startup script."
		return
	GameScript.startup_script = script
	get_tree().change_scene_to_file(GAME_SCENE)
