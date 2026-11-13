extends Control

## Play-mode viewer for lit NIF shapes with the Specular shader flag
## (BSShaderPPLightingProperty flags1 bit 0), to look at what their textures'
## channels hold. The left list fills in the background with every NIF that
## has such a shape; picking one builds it with NifTreeBuilder in the 3D view
## and lists its shapes. Picking a shape shows its normal map and diffuse map,
## each split into its RGB and its alpha, with the DDS format.
##
## 3D view: left-drag orbits, wheel zooms. Run it with
## `../tools/Godot_v4.7.1-stable_linux.x86_64 --path . specular_viewer.tscn`.

const NifTreeBuilderScript := preload("res://GodotBryo/Servers/NifServer/nif_tree_builder.gd")
## BSShaderPPLightingProperty flags1 bit 0: Specular.
const SPECULAR_FLAG := 0x1
const LIT_SHADER := "BSShaderPPLightingProperty"
## NIFs scanned per frame while the list fills.
const SCAN_PER_FRAME := 40
const ORBIT_SENSITIVITY := 0.01
const ZOOM_STEP := 1.15

@onready var _filter: LineEdit = %Filter
@onready var _scan_label: Label = %ScanLabel
@onready var _nif_list: ItemList = %NifList
@onready var _shape_list: ItemList = %ShapeList
@onready var _model_root: Node3D = %ModelRoot
@onready var _camera: Camera3D = %Camera
@onready var _view: SubViewportContainer = %View
@onready var _normal_rgb: TextureRect = %NormalRGB
@onready var _normal_alpha: TextureRect = %NormalAlpha
@onready var _diffuse_rgb: TextureRect = %DiffuseRGB
@onready var _diffuse_alpha: TextureRect = %DiffuseAlpha
@onready var _normal_label: Label = %NormalLabel
@onready var _diffuse_label: Label = %DiffuseLabel

## Every NIF path still to scan.
var _pending: Array[String] = []
## The NIFs found with a specular-flagged lit shape, in scan order.
var _found: Array[String] = []
## The loaded NIF's shape dictionaries, in the shape list's order.
var _shapes: Array[Dictionary] = []
var _yaw := 0.6
var _pitch := -0.3
var _distance := 3.0
var _focus := Vector3.ZERO


func _ready() -> void:
	for path in ArchiveServer.list_files_with_prefix("meshes/"):
		var sp := String(path)
		if sp.ends_with(".nif") and not sp.contains("/lod/") and not sp.ends_with("_lod.nif"):
			_pending.append(sp)
	_filter.text_changed.connect(func(_text: String) -> void: _refresh_nif_list())
	_nif_list.item_selected.connect(_on_nif_selected)
	_shape_list.item_selected.connect(_on_shape_selected)
	_view.gui_input.connect(_on_view_input)
	_update_camera()


func _process(_delta: float) -> void:
	if _pending.is_empty():
		return
	var added := false
	for i in mini(SCAN_PER_FRAME, _pending.size()):
		var path: String = _pending.pop_back()
		if _has_specular_shape(path):
			_found.append(path)
			added = true
	_scan_label.text = "%d NIFs with specular shapes, %d left to scan" % [_found.size(), _pending.size()]
	if added:
		_refresh_nif_list()


func _has_specular_shape(path: String) -> bool:
	var src := _load(path)
	if src == null:
		return false
	for nd in src.get_nodes():
		if _is_specular(nd):
			return true
	return false


func _is_specular(nd: Dictionary) -> bool:
	if not nd.has("positions"):
		return false
	if String(nd.get("shader_type", "")) != LIT_SHADER:
		return false
	return (int(nd.get("shader_flags1", 0)) & SPECULAR_FLAG) != 0


func _refresh_nif_list() -> void:
	var selected := _selected_text(_nif_list)
	var wanted := _filter.text.to_lower()
	_nif_list.clear()
	for path in _found:
		if wanted.is_empty() or path.contains(wanted):
			_nif_list.add_item(path)
			if path == selected:
				_nif_list.select(_nif_list.item_count - 1)


func _on_nif_selected(index: int) -> void:
	var path := _nif_list.get_item_text(index)
	var src := _load(path)
	if src == null:
		return
	for child in _model_root.get_children():
		child.queue_free()
	_shapes.clear()
	_shape_list.clear()
	for nd in src.get_nodes():
		if not nd.has("positions") or String(nd.get("shader_type", "")) != LIT_SHADER:
			continue
		_shapes.append(nd)
		var slots: Array = nd.get("texture_slots", [])
		var normal := String(slots[1]) if slots.size() > 1 else ""
		var flag := "specular" if _is_specular(nd) else "no specular"
		_shape_list.add_item("%s  [%s, normal %s]" % [nd["name"], flag, _dds_format(normal)])
	var root: Node3D = await NifTreeBuilderScript.build(src)
	if root == null:
		return
	# Havok-dynamic shapes (clutter) are built as rigid bodies; with no floor
	# they would fall, so they are frozen in place, as a STAT's are.
	for body in root.find_children("*", "RigidBody3D", true, false):
		(body as RigidBody3D).freeze = true
	_model_root.add_child(root)
	_frame(root)
	if not _shapes.is_empty():
		_shape_list.select(0)
		_on_shape_selected(0)


func _on_shape_selected(index: int) -> void:
	var nd: Dictionary = _shapes[index]
	var slots: Array = nd.get("texture_slots", [])
	var diffuse := String(slots[0]) if slots.size() > 0 else ""
	var normal := String(slots[1]) if slots.size() > 1 else ""
	_show_texture(normal, _normal_rgb, _normal_alpha, _normal_label, "Normal")
	_show_texture(diffuse, _diffuse_rgb, _diffuse_alpha, _diffuse_label, "Diffuse")


## Shows a texture's RGB and alpha in the two rects (each has the channel
## shader; its `show_alpha` picks the channel) and its path and format.
func _show_texture(path: String, rgb: TextureRect, alpha: TextureRect, label: Label, title: String) -> void:
	var texture := _texture(path)
	rgb.texture = texture
	alpha.texture = texture
	label.text = "%s: %s (%s)" % [title, path if not path.is_empty() else "none", _dds_format(path)]


func _texture(path: String) -> Texture2D:
	var data := _dds_data(path)
	if data.is_empty():
		return null
	var image := Image.new()
	if image.load_dds_from_buffer(data) != OK:
		return null
	if image.is_compressed():
		image.decompress()
	return ImageTexture.create_from_image(image)


## A DDS file's pixel format: its FourCC, or rgba<bits> / rgb<bits> for an
## uncompressed one; "missing" when no archive has it.
func _dds_format(path: String) -> String:
	if path.is_empty():
		return "none"
	var data := _dds_data(path)
	if data.size() < 128:
		return "missing"
	var flags := data.decode_u32(80)
	if (flags & 0x4) != 0:
		return data.slice(84, 88).get_string_from_ascii()
	var bits := data.decode_u32(88)
	if (flags & 0x1) != 0:
		return "rgba%d" % bits
	return "rgb%d" % bits


func _dds_data(path: String) -> PackedByteArray:
	if path.is_empty():
		return PackedByteArray()
	var archive_path := path.to_lower().replace("\\", "/")
	if not archive_path.begins_with("textures/"):
		archive_path = "textures/" + archive_path
	var raw: Dictionary = ArchiveServer.read(archive_path)
	if not bool(raw["found"]):
		return PackedByteArray()
	return PackedByteArray(raw["data"])


func _load(path: String) -> NifSource:
	var raw: Dictionary = ArchiveServer.read(path)
	if not bool(raw["found"]):
		return null
	var src := NifSource.new()
	if not src.load(PackedByteArray(raw["data"])):
		return null
	return src


## Points the orbit camera at the model's bounds.
func _frame(root: Node3D) -> void:
	var bounds := AABB()
	var first := true
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		var box := mesh.global_transform * mesh.get_aabb()
		if first:
			bounds = box
			first = false
		else:
			bounds = bounds.merge(box)
	_focus = bounds.get_center()
	_distance = maxf(bounds.size.length() * 1.2, 0.3)
	_update_camera()


func _on_view_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		_yaw -= event.relative.x * ORBIT_SENSITIVITY
		_pitch = clampf(_pitch - event.relative.y * ORBIT_SENSITIVITY, -1.5, 1.5)
		_update_camera()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_distance /= ZOOM_STEP
			_update_camera()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_distance *= ZOOM_STEP
			_update_camera()


func _update_camera() -> void:
	var offset := Vector3(sin(_yaw) * cos(_pitch), -sin(_pitch), cos(_yaw) * cos(_pitch)) * _distance
	_camera.position = _focus + offset
	_camera.look_at(_focus)


func _selected_text(list: ItemList) -> String:
	var selected := list.get_selected_items()
	if selected.is_empty():
		return ""
	return list.get_item_text(selected[0])
