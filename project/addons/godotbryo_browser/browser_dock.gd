@tool
extends VBoxContainer

const BASE_TYPES := ["NPC_", "RACE", "HAIR", "EYES", "CLAS", "PACK", "ARMO", "ARMA", "FLST", "WEAP", "ALCH", "LVLI", "AMMO", "BOOK", "CCRD", "CMNY", "KEYM", "MISC", "DOOR", "SCOL", "LIGH", "CONT", "ACTI", "FURN", "TACT", "MSTT", "TERM", "STAT", "CREA"]
const CardScript := preload("res://addons/godotbryo_browser/base_card.gd")
const ReferenceCardScript := preload("res://addons/godotbryo_browser/reference_card.gd")
const PhysicaliserScript := preload("res://GodotBryo/Pipeline/esm_reference_physicaliser.gd")
const PreviewScript := preload("res://GodotBryo/Types/Node/esm_reference_preview.gd")
const CARD_WIDTH := 240.0
const GRID_H_SEPARATION := 10

var type_option: OptionButton
var type_tabs: TabBar
var filter_edit: LineEdit
var grid: GridContainer
var status: Label
var find_button: Button
var context_menu: PopupMenu
var rows: Array = []
var selected_card
var server
var _render_generation := 0
var _render_cursor := 0
var _render_count := 0
var _rendering := false
var _render_type := "All"
var _render_needle := ""

func _ready() -> void:
	if not Engine.is_editor_hint(): return
	set_process(true)
	_build_ui()
	server = get_node_or_null("/root/EsmServer")
	if server != null:
		server.esm_ready.connect(_on_server_ready)
		server.failed.connect(_on_server_failed)
		if server.is_ready(): _on_server_ready()
		else: status.text = "Loading FalloutNV.esm..."

func _build_ui() -> void:
	var title := Label.new(); title.text = "GodotBryo — ESM Base Resources"; add_child(title)
	type_tabs = TabBar.new()
	type_tabs.add_tab("Select Type")
	for type_tag in BASE_TYPES: type_tabs.add_tab(type_tag)
	type_tabs.current_tab = 0
	type_tabs.tab_selected.connect(_type_tab_selected)
	type_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(type_tabs)
	var controls := HBoxContainer.new(); add_child(controls)
	filter_edit = LineEdit.new(); filter_edit.placeholder_text = "Filter name, EditorID, or FormID..."
	filter_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	filter_edit.text_changed.connect(func(_t: String) -> void: _refresh_grid()); controls.add_child(filter_edit)
	find_button = Button.new(); find_button.text = "Find References"; find_button.disabled = true; find_button.pressed.connect(_find_selected); controls.add_child(find_button)
	var scroll := ScrollContainer.new(); scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL; add_child(scroll)
	grid = GridContainer.new(); grid.columns = 1; grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", GRID_H_SEPARATION)
	grid.add_theme_constant_override("v_separation", 10)
	scroll.add_child(grid)
	resized.connect(_update_grid_columns)
	scroll.resized.connect(_update_grid_columns)
	call_deferred("_update_grid_columns")
	context_menu = PopupMenu.new()
	context_menu.id_pressed.connect(_context_menu_pressed)
	add_child(context_menu)
	status = Label.new(); add_child(status)

func _update_grid_columns() -> void:
	if grid == null or not is_instance_valid(grid): return
	var available_width: float = float(grid.get_parent().size.x)
	if available_width <= 0.0: return
	var columns := maxi(1, int(floor((available_width + GRID_H_SEPARATION) / (CARD_WIDTH + GRID_H_SEPARATION))))
	if grid.columns != columns:
		grid.columns = columns

func _process(_delta: float) -> void:
	if _rendering:
		_render_grid_batch()

func _on_server_ready() -> void:
	rows = server.get_record_index()
	_prepare_display_names()
	_refresh_grid()

func _type_tab_selected(index: int) -> void:
	_clear_grid()
	if index == 0:
		_rendering = false
		status.text = "Select a record type"
		return
	_refresh_grid()

func _on_server_failed(message: String) -> void:
	status.text = "ESM unavailable: %s" % message

func _prepare_display_names() -> void:
	for row in rows:
		var full_name := String(row.get("full_name", "")).strip_edges()
		var editor_id := String(row.get("editor_id", "")).strip_edges()
		row["display_name"] = full_name if _is_meaningful_full_name(full_name, String(row.get("record_type", ""))) else (_humanize(editor_id) if not editor_id.is_empty() else "0x%08X" % int(row.get("form_id", 0)))

func _refresh_grid() -> void:
	if grid == null: return
	if type_tabs == null or type_tabs.current_tab == 0:
		_clear_grid()
		_rendering = false
		status.text = "Select a record type"
		return
	_render_generation += 1
	_render_cursor = 0
	_render_count = 0
	_render_type = type_tabs.get_tab_title(type_tabs.current_tab)
	_render_needle = filter_edit.text.to_lower().strip_edges() if filter_edit != null else ""
	_rendering = true
	selected_card = null
	find_button.disabled = true
	_clear_grid()
	status.text = "Filtering records..."

func _clear_grid() -> void:
	_render_generation += 1
	selected_card = null
	find_button.disabled = true
	if grid == null: return
	for child in grid.get_children():
		grid.remove_child(child)
		child.queue_free()

func _render_grid_batch() -> void:
	var generation := _render_generation
	var started := Time.get_ticks_usec()
	# Keep each editor frame's UI work bounded. A new filter increments the
	# generation; the current batch then stops before adding stale cards.
	while _render_cursor < rows.size() and Time.get_ticks_usec() - started < 4000:
		if generation != _render_generation:
			return
		var row: Dictionary = rows[_render_cursor]
		_render_cursor += 1
		var tag := String(row.get("record_type", ""))
		if tag not in BASE_TYPES or tag != _render_type: continue
		_ensure_display_name(row)
		var searchable := "%s %s %08X" % [String(row.get("display_name", "")), String(row.get("editor_id", "")), int(row.get("form_id", 0))]
		if _render_needle != "" and searchable.to_lower().find(_render_needle) < 0: continue
		var card = CardScript.new()
		card.configure(row)
		card.activated.connect(_activate_card)
		card.context_requested.connect(_context_card)
		grid.add_child(card)
		_render_count += 1
	if _render_cursor >= rows.size():
		_rendering = false
		status.text = "%d Base records shown / %d indexed" % [_render_count, rows.size()]
	else:
		status.text = "Filtering records... %d shown" % _render_count

func _ensure_display_name(row: Dictionary) -> void:
	var full_name := String(row.get("full_name", "")).strip_edges()
	var editor_id := String(row.get("editor_id", "")).strip_edges()
	if _is_meaningful_full_name(full_name, String(row.get("record_type", ""))) or not editor_id.is_empty():
		return
	if server == null or not server.is_ready():
		return
	var base: EsmBase = server.get_base(int(row.get("form_id", 0)))
	if base == null:
		return
	row["full_name"] = base.full_name
	row["editor_id"] = base.editor_id
	var hydrated_full_name := String(base.full_name).strip_edges()
	var hydrated_editor_id := String(base.editor_id).strip_edges()
	row["display_name"] = hydrated_full_name if _is_meaningful_full_name(hydrated_full_name, String(row.get("record_type", ""))) else (_humanize(hydrated_editor_id) if not hydrated_editor_id.is_empty() else "0x%08X" % int(row.get("form_id", 0)))

func _is_meaningful_full_name(full_name: String, record_type: String) -> bool:
	var value := full_name.strip_edges()
	var type_name := record_type.strip_edges()
	return not value.is_empty() and (type_name.is_empty() or value.to_lower() != type_name.to_lower())

func _activate_card(card) -> void:
	selected_card = card; find_button.disabled = false
	var resource: EsmBase = server.get_base(int(card.row.get("form_id", 0))) if server != null else null
	card.set_resource(resource)
	if resource != null: EditorInterface.inspect_object(resource)

func _context_card(card, screen_position: Vector2i) -> void:
	selected_card = card
	find_button.disabled = not card.has_method("get_reference_id")
	context_menu.clear()
	if card.has_method("get_reference_id"):
		context_menu.add_item("Open As Scene", 2)
	else:
		find_button.disabled = false
		context_menu.add_item("Find References", 1)
		context_menu.add_item("Open As Scene", 2)
	context_menu.position = screen_position
	context_menu.popup()

func _context_menu_pressed(id: int) -> void:
	if id == 1:
		_find_selected()
	elif id == 2:
		_open_selected_reference_scene()

func _find_selected() -> void:
	if selected_card == null or server == null or not server.is_ready(): return
	var target := int(selected_card.row.get("form_id", 0))
	var base_name := String(selected_card.row.get("display_name", ""))
	_rendering = false
	_clear_grid()
	status.text = "Scanning placement records..."
	var count := 0
	for candidate in rows:
		var tag := String(candidate.get("record_type", ""))
		if tag not in ["REFR", "ACHR", "ACRE"]: continue
		var raw: Dictionary = server.reader.get_record_data(int(candidate.get("form_id", 0)))
		if _u32(_subrecord(raw, "NAME")) != target: continue
		var reference_card = ReferenceCardScript.new()
		reference_card.configure(tag, int(candidate.get("form_id", 0)), target, base_name)
		reference_card.activated.connect(_activate_reference_card.bind(int(candidate.get("form_id", 0))))
		reference_card.context_requested.connect(_context_card)
		grid.add_child(reference_card)
		count += 1
	status.text = "%d references found" % count

func _activate_reference_card(_card, reference_id: int) -> void:
	var reference = server.get_reference("authored:%08X" % reference_id) if server != null else null
	if reference != null: EditorInterface.inspect_object(reference)

func _open_selected_reference_scene() -> void:
	if selected_card == null or server == null or not server.is_ready(): return
	var reference: EsmReference
	if selected_card.has_method("get_reference_id"):
		var reference_id := int(selected_card.get_reference_id())
		reference = server.get_reference("authored:%08X" % reference_id)
	else:
		var base_id := int(selected_card.row.get("form_id", 0))
		reference = server.create_reference_for_base(base_id)
	if reference == null:
		return
	var scene_root := Node3D.new()
	scene_root.name = _preview_scene_name(reference, selected_card.row if selected_card != null else {})
	scene_root.set_script(PreviewScript)
	var physicaliser := PhysicaliserScript.new()
	physicaliser.physicalise(reference, scene_root)
	var packed_scene := PackedScene.new()
	if packed_scene.pack(scene_root) != OK:
		return
	var preview_file_name := scene_root.name.replace("/", "_").replace("\\", "_").replace(":", "_")
	var preview_path := "res://.godot/%s.tscn" % preview_file_name
	if ResourceSaver.save(packed_scene, preview_path) != OK:
		return
	_write_preview_edit_state(preview_path, scene_root)
	EditorInterface.open_scene_from_path(preview_path)
	call_deferred("_finish_open_preview_scene", preview_path)

func _finish_open_preview_scene(preview_path: String) -> void:
	# The scene remains live in the editor after its temporary source file is
	# removed. This makes it a disposable, unsaved inspection scene.
	EditorInterface.mark_scene_as_unsaved()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(preview_path))

func _humanize(value: String) -> String:
	var output := ""
	for i in value.length():
		var c := value[i]
		if i > 0:
			var previous := value[i - 1]
			var next := value[i + 1] if i + 1 < value.length() else ""
			var c_upper := c == c.to_upper() and c != c.to_lower()
			var previous_lower := previous == previous.to_lower() and previous != previous.to_upper()
			var previous_upper := previous == previous.to_upper() and previous != previous.to_lower()
			var c_digit := c >= "0" and c <= "9"
			var previous_digit := previous >= "0" and previous <= "9"
			var next_lower := next != "" and next == next.to_lower() and next != next.to_upper()
			var boundary := (c_upper and previous_lower) \
					or (c_upper and previous_upper and next_lower) \
					or (c_digit and not previous_digit) \
					or (not c_digit and previous_digit and c != "x")
			if boundary and output != "" and not output.ends_with(" "):
				output += " "
		output += c
	return output

func _preview_scene_name(reference: EsmReference, indexed_row: Dictionary = {}) -> String:
	var type_name := String(reference.base.record_type) if reference.base != null else String(indexed_row.get("record_type", "REFR"))
	var label := String(reference.base.full_name).strip_edges() if reference.base != null else ""
	if label.is_empty() and reference.base != null:
		label = String(reference.base.editor_id).strip_edges()
	if label.is_empty():
		label = String(indexed_row.get("full_name", "")).strip_edges()
	if label.is_empty():
		label = String(indexed_row.get("editor_id", "")).strip_edges()
	if label.is_empty() and reference.base != null:
		label = "0x%08X" % reference.base.form_id
	if label.is_empty():
		label = "Unknown"
	return ("%s (%s)" % [type_name, label]).validate_node_name()

func _write_preview_edit_state(scene_path: String, scene_root: Node3D) -> void:
	var bounds := _preview_bounds(scene_root)
	var radius := max(bounds.size.length() * 0.5, 0.5)
	var fov := 70.0
	# Keep the generated framing close to the item for inspection.
	var distance := max(radius / tan(deg_to_rad(fov * 0.5)) * 0.3375, 1.5)
	var state_path := "res://.godot/editor/%s-editstate-%s.cfg" % [scene_path.get_file(), scene_path.md5_text()]
	var file := FileAccess.open(ProjectSettings.globalize_path(state_path), FileAccess.WRITE)
	if file == null:
		push_warning("Could not write preview editor state: %s" % state_path)
		return
	file.store_string("[editor_states]\n")
	file.store_string("3D={\n")
	file.store_string("\"fov\": %s,\n" % fov)
	file.store_string("\"viewport_mode\": 1,\n")
	file.store_string("\"viewports\": [{\n")
	file.store_string("\"auto_orthogonal\": false,\n\"auto_orthogonal_enabled\": true,\n")
	file.store_string("\"distance\": %s,\n" % distance)
	file.store_string("\"position\": Vector3(%s, %s, %s),\n" % [bounds.get_center().x, bounds.get_center().y, bounds.get_center().z])
	file.store_string("\"x_rotation\": 0.35,\n\"y_rotation\": -0.65,\n")
	file.store_string("\"orthogonal\": false,\n\"view_type\": 0\n")
	file.store_string("}]\n}\n")
	file.close()

func _preview_bounds(node: Node3D, parent_transform: Transform3D = Transform3D.IDENTITY) -> AABB:
	var combined := AABB()
	var have_bounds := false
	var local_transform := parent_transform * node.transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		combined = local_transform * (node as MeshInstance3D).get_aabb()
		have_bounds = true
	for child in node.get_children():
		if not child is Node3D:
			continue
		var child_bounds := _preview_bounds(child as Node3D, local_transform)
		if child_bounds.size.length() <= 0.0:
			continue
		combined = child_bounds if not have_bounds else combined.merge(child_bounds)
		have_bounds = true
	return combined if have_bounds else AABB(Vector3.ZERO, Vector3.ONE)

func _subrecord(raw: Dictionary, tag: String) -> PackedByteArray:
	for sub in raw.get("subrecords", []):
		if String(sub.get("type", "")) == tag: return sub.get("data", PackedByteArray())
	return PackedByteArray()

func _u32(data: PackedByteArray) -> int:
	return int(data.decode_u32(0)) if data.size() >= 4 else 0
