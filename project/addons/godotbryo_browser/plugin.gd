@tool
extends EditorPlugin

const BrowserScript := preload("res://addons/godotbryo_browser/browser_dock.gd")
const LoaderScript := preload("res://addons/godotbryo_browser/esm_resource_loader.gd")
var browser: Control
var loader: ResourceFormatLoader

func _enter_tree() -> void:
	browser = BrowserScript.new()
	browser.name = "GodotBryo"
	loader = LoaderScript.new()
	ResourceLoader.add_resource_format_loader(loader, false)
	add_control_to_dock(DOCK_SLOT_BOTTOM, browser)

func _exit_tree() -> void:
	if loader != null: ResourceLoader.remove_resource_format_loader(loader)
	if browser != null:
		remove_control_from_docks(browser)
		browser.queue_free()
