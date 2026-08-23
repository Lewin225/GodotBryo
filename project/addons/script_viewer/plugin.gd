@tool
extends EditorPlugin

## Adds script_viewer.gd/.tscn as a real main-screen tab (same top tab row
## as 2D/3D/Script/AssetLib), not a side dock -- a scene merely open in the
## 2D viewport is in node-editing mode, so clicks there select/move nodes
## and never reach a Control's own input handling (search LineEdit,
## ItemList selection, RichTextLabel meta_clicked). A real EditorPlugin
## screen is also the only way to get EditorInterface access (edit_script(),
## for the Ctrl+Click jump-to-code feature) alongside genuine click
## interaction: Play-mode (F6) would give the second but not the first --
## EditorInterface only exists for code actually running inside the editor
## process, and a Play-mode scene is a separate process entirely.

const ScriptViewerScene := preload("res://addons/script_viewer/script_viewer.tscn")

var _main_control: Control

func _enter_tree() -> void:
	_main_control = ScriptViewerScene.instantiate()
	# The main screen container is a VBoxContainer -- a plain Control child
	# only takes its minimum content size there unless it's told to expand
	# and fill (confirmed real: without this it rendered as a ~75px sliver
	# pinned to the top instead of filling the screen). Set here, not just
	# on the scene's own root node, so this holds regardless of what the
	# .tscn itself has saved.
	_main_control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_control.size_flags_vertical = Control.SIZE_EXPAND_FILL
	get_editor_interface().get_editor_main_screen().add_child(_main_control)
	_make_visible(false)

func _exit_tree() -> void:
	if _main_control != null:
		_main_control.queue_free()

func _has_main_screen() -> bool:
	return true

func _make_visible(next_visible: bool) -> void:
	if _main_control != null:
		_main_control.visible = next_visible

func _get_plugin_name() -> String:
	return "Scripts"

func _get_plugin_icon() -> Texture2D:
	return get_editor_interface().get_base_control().get_theme_icon("Script", "EditorIcons")
