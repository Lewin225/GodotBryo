@tool
extends EditorPlugin

const BrowserScript := preload("res://addons/godotbryo_browser/browser_dock.gd")
const LoaderScript := preload("res://addons/godotbryo_browser/esm_resource_loader.gd")
const PhysicaliserScript := preload("res://GodotBryo/Pipeline/esm_reference_physicaliser.gd")
const DropTargetScript := preload("res://addons/godotbryo_browser/editor_drop_target.gd")
var browser: Control
var loader: ResourceFormatLoader
var drop_target: Control

func _enter_tree() -> void:
	browser = BrowserScript.new()
	browser.name = "GodotBryo"
	loader = LoaderScript.new()
	ResourceLoader.add_resource_format_loader(loader, false)
	add_control_to_bottom_panel(browser, "GodotBryo")
	var editor_viewport := EditorInterface.get_editor_viewport_3d()
	drop_target = DropTargetScript.new()
	drop_target.drop_received.connect(_on_viewport_drop)
	# The 3D editor's GUI surface is not the SubViewport returned by
	# get_editor_viewport_3d(). Godot keeps that SubViewport underneath a
	# Node3DEditorViewport Control, whose sibling surface owns drag/drop hit
	# testing. Put our target on that Control so it is evaluated before the
	# built-in surface rejects non-file payloads.
	var viewport_container := editor_viewport.get_parent()
	var editor_surface := viewport_container.get_parent() if viewport_container != null else null
	if editor_surface != null:
		editor_surface.add_child(drop_target)

func _exit_tree() -> void:
	if loader != null: ResourceLoader.remove_resource_format_loader(loader)
	if is_instance_valid(drop_target):
		drop_target.queue_free()
	if browser != null:
		remove_control_from_bottom_panel(browser)
		browser.queue_free()

func _on_viewport_drop(screen_position: Vector2, data: Variant) -> void:
	if not data is Dictionary:
		return
	var base = data.get("resource")
	if not base is EsmBase or base is LeveledItemBase:
		return
	var editor_viewport := EditorInterface.get_editor_viewport_3d()
	var camera := editor_viewport.get_camera_3d()
	if camera != null and _drop_base_into_scene(base as EsmBase, camera, screen_position):
		editor_viewport.gui_cancel_drag()

## Accept Base resources dragged from the GodotBryo browser into the edited
## 3D scene. The resource is deliberately turned into a synthetic REFR first,
## so this uses the same physicalisation path as Open As Scene and runtime
## reference construction.
func _forward_3d_gui_input(p_viewport_camera: Camera3D, p_event: InputEvent) -> AfterGUIInput:
	if not (p_event is InputEventMouseButton) or not p_event.is_released():
		return AFTER_GUI_INPUT_PASS
	if p_event.button_index != MOUSE_BUTTON_LEFT:
		return AFTER_GUI_INPUT_PASS

	var drag_data: Variant = p_viewport_camera.get_viewport().gui_get_drag_data()
	# Depending on the editor viewport container, the GUI drag can be owned by
	# the editor's root viewport rather than the 3D SubViewport.
	if not drag_data is Dictionary:
		drag_data = EditorInterface.get_base_control().get_viewport().gui_get_drag_data()
	if not (drag_data is Dictionary):
		return AFTER_GUI_INPUT_PASS
	if String(drag_data.get("type", "")) != "resource":
		return AFTER_GUI_INPUT_PASS
	var base = drag_data.get("resource")
	if not base is EsmBase or base is LeveledItemBase:
		return AFTER_GUI_INPUT_PASS

	if _drop_base_into_scene(base as EsmBase, p_viewport_camera, p_event.position):
		p_viewport_camera.get_viewport().gui_cancel_drag()
		return AFTER_GUI_INPUT_STOP
	return AFTER_GUI_INPUT_PASS

func _drop_base_into_scene(base: EsmBase, camera: Camera3D, screen_position: Vector2) -> bool:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null or not scene_root is Node3D:
		return false
	if base.form_id == 0 or base is LeveledItemBase:
		return false

	var server = get_tree().root.get_node_or_null("EsmServer")
	if server == null or not server.has_method("create_reference_for_base"):
		return false
	var reference: EsmReference = server.create_reference_for_base(base.form_id)
	if reference == null:
		return false

	var world_position := _drop_position(camera, screen_position)
	if world_position == null:
		return false

	# Deliberately not awaited, and this function stays synchronous: both
	# callers are engine virtuals, and _forward_3d_gui_input must return
	# AFTER_GUI_INPUT_STOP/PASS in the same call. The bool here answers "was
	# this drop accepted", which is known now; building the node is not, since
	_complete_drop(reference, scene_root as Node3D, world_position)
	return true


## Adds the semantic node immediately. Its @tool lifecycle requests and
## attaches NifServer content after UndoRedo inserts it into the edited scene.
func _complete_drop(reference: EsmReference, scene_root: Node3D, world_position: Vector3) -> void:
	var physicaliser := PhysicaliserScript.new()
	var generated: Node3D = physicaliser.physicalise(reference)
	if generated == null:
		return
	if not is_instance_valid(scene_root) or scene_root != EditorInterface.get_edited_scene_root():
		# The edited scene changed while the build was in flight.
		generated.queue_free()
		return
	generated.name = _unique_node_name(scene_root, generated.name)
	generated.position = world_position

	var undo := get_undo_redo()
	undo.create_action("Add ESM reference")
	undo.add_do_method(scene_root, "add_child", generated, true)
	undo.add_do_method(self, "_set_semantic_owner", generated, scene_root)
	undo.add_undo_method(scene_root, "remove_child", generated)
	undo.add_undo_method(self, "_clear_semantic_owner", generated)
	undo.commit_action()

func _drop_position(camera: Camera3D, screen_position: Vector2) -> Variant:
	var ray_origin := camera.project_ray_origin(screen_position)
	var ray_direction := camera.project_ray_normal(screen_position)
	if is_zero_approx(ray_direction.y):
		return null
	var distance := -ray_origin.y / ray_direction.y
	if distance < 0.0:
		return null
	return ray_origin + ray_direction * distance

func _unique_node_name(scene_root: Node, requested_name: String) -> String:
	var candidate := requested_name if not requested_name.is_empty() else "EsmReference"
	var suffix := 2
	while scene_root.has_node(NodePath(candidate)):
		candidate = "%s_%d" % [requested_name, suffix]
		suffix += 1
	return candidate

## The semantic node must be owned before its deferred @tool startup runs;
## EsmNode then assigns ownership recursively to generated editor children.
func _set_semantic_owner(node: Node, owner: Node) -> void:
	node.owner = owner

func _clear_semantic_owner(node: Node) -> void:
	node.owner = null
