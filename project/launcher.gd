extends MarginContainer

## The main scene. Says how much is missing, shows which FalloutNV.esm the
## servers loaded, lets the player pick another, and starts a new game in Doc
## Mitchell's house (game.tscn).
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
@onready var _esm_dialog: FileDialog = %EsmDialog

var _loaded_data_dir := ""


func _ready() -> void:
	_loaded_data_dir = GameDataSettings.get_data_dir()
	_choose_button.pressed.connect(_on_choose_pressed)
	_new_game_button.pressed.connect(_on_new_game_pressed)
	_custom_start_button.pressed.connect(_on_custom_start_pressed)
	_quit_button.pressed.connect(get_tree().quit)
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
