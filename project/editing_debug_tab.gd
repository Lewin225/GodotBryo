extends Control

## Debug-only editing controls. NifServer remains the one owner of the editor
## object classification and visibility policy; this tab only presents it.

@onready var _show_editor_markers: CheckBox = $Margin/VBox/ShowEditorMarkers

var _nif_server: Node = null


func _ready() -> void:
	_nif_server = get_tree().root.get_node_or_null("NifServer") if get_tree() != null else null
	_show_editor_markers.toggled.connect(_on_show_editor_markers_toggled)
	if _nif_server != null and _nif_server.has_signal("editor_object_visibility_changed"):
		_nif_server.editor_object_visibility_changed.connect(_on_editor_object_visibility_changed)
	_sync_from_nif_server()


func _on_show_editor_markers_toggled(visible: bool) -> void:
	if _nif_server == null or not _nif_server.has_method("set_editor_objects_visible"):
		push_warning("Editing debug tab: NifServer editor-object policy is unavailable")
		_sync_from_nif_server()
		return
	_nif_server.set_editor_objects_visible(visible)


func _on_editor_object_visibility_changed(visible: bool) -> void:
	_show_editor_markers.set_pressed_no_signal(visible)


func _sync_from_nif_server() -> void:
	var available := _nif_server != null and _nif_server.has_method("set_editor_objects_visible")
	_show_editor_markers.disabled = not available
	_show_editor_markers.set_pressed_no_signal(available and bool(_nif_server.editor_objects_visible))
