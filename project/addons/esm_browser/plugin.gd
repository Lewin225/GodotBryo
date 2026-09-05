@tool
extends EditorPlugin

const BrowserScript := preload("res://addons/esm_browser/esm_browser.gd")
const LoaderScript := preload("res://addons/esm_browser/esm_record_loader.gd")
const GameDataConfigScript := preload("res://game_data_config.gd")
var browser: Control
## Keep the plugin's loader untyped for the same startup-order reason as the
## loader's EsmReader field: global classes are not guaranteed during the
## first editor class-cache scan.
var loader
var loader_registered := false

func _enter_tree() -> void:
	browser = BrowserScript.new()
	browser.name = "ESM Resources"
	browser.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	browser.size_flags_vertical = Control.SIZE_EXPAND_FILL
	loader = LoaderScript.new()
	var reader = ClassDB.instantiate("EsmReader")
	if reader == null:
		push_warning("ESM browser: EsmReader GDExtension class is not registered yet")
		return
	var config := GameDataConfigScript.resolve()
	var esm_path := String(config.get("data_dir", "")) + GameDataConfigScript.ESM_FILE
	if reader.open(esm_path):
		_register_loader(reader)
	browser.loader_ready.connect(_register_loader)
	add_control_to_dock(DOCK_SLOT_LEFT_UL, browser)

func _exit_tree() -> void:
	if browser != null:
		if loader_registered:
			ResourceLoader.remove_resource_format_loader(loader)
		remove_control_from_docks(browser)
		browser.queue_free()

func _register_loader(reader) -> void:
	if loader_registered:
		return
	loader.configure(reader)
	# This loader is scoped to .nvrecord paths. Appending it leaves Godot's
	# built-in PackedScene/resource loaders authoritative for every other file.
	ResourceLoader.add_resource_format_loader(loader, false)
	loader_registered = true
