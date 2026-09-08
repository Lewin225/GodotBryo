@tool
extends VBoxContainer

const BASE_TYPES := ["NPC_", "RACE", "HAIR", "EYES", "CLAS", "PACK", "ARMO", "ARMA", "FLST", "WEAP", "ALCH", "LVLI", "AMMO", "BOOK", "CCRD", "CMNY", "KEYM", "MISC", "DOOR", "SCOL", "LIGH", "CONT", "ACTI", "FURN", "TACT", "MSTT", "TERM", "STAT", "CREA"]
const CardScript := preload("res://addons/godotbryo_browser/base_card.gd")
const ReferenceCardScript := preload("res://addons/godotbryo_browser/reference_card.gd")
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
	context_menu = PopupMenu.new(); context_menu.add_item("Find References", 1); context_menu.id_pressed.connect(func(id: int) -> void: if id == 1: _find_selected()); add_child(context_menu)
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
		row["display_name"] = full_name if not full_name.is_empty() else (_humanize(editor_id) if not editor_id.is_empty() else "0x%08X" % int(row.get("form_id", 0)))

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

func _activate_card(card) -> void:
	selected_card = card; find_button.disabled = false
	var resource: EsmBase = server.get_base(int(card.row.get("form_id", 0))) if server != null else null
	card.set_resource(resource)
	if resource != null: EditorInterface.inspect_object(resource)

func _context_card(card, screen_position: Vector2i) -> void:
	selected_card = card; find_button.disabled = false; context_menu.position = screen_position; context_menu.popup()

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
		grid.add_child(reference_card)
		count += 1
	status.text = "%d references found" % count

func _activate_reference_card(_card, reference_id: int) -> void:
	var reference = server.get_reference("authored:%08X" % reference_id) if server != null else null
	if reference != null: EditorInterface.inspect_object(reference)

func _humanize(value: String) -> String:
	var output := ""
	for i in value.length():
		var c := value[i]
		if i > 0 and c == c.to_upper() and c != c.to_lower() and value[i - 1] != " ": output += " "
		output += c
	return output

func _subrecord(raw: Dictionary, tag: String) -> PackedByteArray:
	for sub in raw.get("subrecords", []):
		if String(sub.get("type", "")) == tag: return sub.get("data", PackedByteArray())
	return PackedByteArray()

func _u32(data: PackedByteArray) -> int:
	return int(data.decode_u32(0)) if data.size() >= 4 else 0
