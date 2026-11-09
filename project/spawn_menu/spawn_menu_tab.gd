class_name SpawnMenuTab
extends Control

## The Spawn tab of Debug Tools (Plans/SpawnMenu/spawn_menu.md): category tabs
## along the top, a tree of record types and their groups on the left, a grid
## of records filling the rest, a search box above it, and an info bar and
## footer below.
##
## The same in every category: a click selects a record (the info bar names
## it); a double click (or Enter) places it at the crosshair, leveled lists
## resolved first; Shift and click gives it to the player where it can be
## carried (items, and LVLI); right click opens a menu.
## The footer's Count applies to both. Undo (or Ctrl+Z) takes back the newest
## spawn, Clear spawned all of this session's. Spawning goes through `placer`.
##
## Rows come from a SpawnCatalog built the first time the tab is shown; each
## category's types are built on its worker thread, and the tab shows
## "Indexing <type>…" until they arrive.
##
## A record with an ICON shows that inventory icon as it is (the DDS through
## ThumbnailServer, scaled by the grid). A record with no ICON but a model the
## preview can show (_preview_model()) shows a render of that model
## (ThumbnailServer), one per model, so every record sharing a mesh shares
## the same texture. Anything else, and anything still loading, shows a glyph
## coloured by its category. Icons and renders load only for the visible rows
## and one screen ahead, ICON_LOADS_AT_ONCE and RENDERS_AT_ONCE at a time, the
## top of the screen first; scrolling or a new selection drops the ones not
## started yet.
##
## Nodes are authored in spawn_menu_tab.tscn; this script only looks them up.

## Glyph colour of each category, by CATEGORIES index.
const CATEGORY_COLOURS := [Color("#e5c07b"), Color("#d19a66"), Color("#61afef"), Color("#8b929e"), Color("#98c379"), Color("#c678dd")]

## Main-thread time a frame spends adding grid items; a long list fills over
## several frames.
const GRID_FILL_BUDGET_USEC := 4000
## How much larger than the icon the hover preview is.
const PREVIEW_SCALE := 1.2

## Icon loads (ThumbnailServer.request_icon) running at once.
const ICON_LOADS_AT_ONCE := 16
## Thumbnail requests (ThumbnailServer.request_render) running at once. Trees load
## in parallel, but they render one a frame.
const RENDERS_AT_ONCE := 6

## Items removed at a time past the new end of the grid.
const GRID_TRIM_CHUNK := 500

const MENU_PLACE := 0
const MENU_INVENTORY := 1
const MENU_COPY_EDITOR_ID := 2
const MENU_COPY_COMMAND := 3
const MENU_OPEN_IN_CONSOLE := 4
const MENU_EQUIP := 6
const MENU_FAVOURITE := 7

## Where Favourites and Recent are saved (SpawnLists).
@export var lists_path := SpawnLists.DEFAULT_PATH
## Places and adds what the tab spawns: the game's SpawnPlacer.
@export var placer: SpawnPlacer
## Faded out and back in after each spawn, so what was spawned shows behind
## it for a moment: Debug Tools. Null fades the tab's grandparent.
@export var fade_target: CanvasItem
## How far the fade goes (fade_target's alpha), and the seconds to drop to it
## and to ease back to opaque: 0.4 s in all.
@export_range(0.0, 1.0) var fade_alpha := 0.2
@export var fade_out_time := 0.08
@export var fade_in_time := 0.32

@onready var _categories: TabBar = $Margin/VBox/Categories
@onready var _tree: Tree = $Margin/VBox/Split/Tree
@onready var _search: LineEdit = $Margin/VBox/Split/Right/Toolbar/Search
@onready var _size: HSlider = $Margin/VBox/Split/Right/Toolbar/Size
@onready var _spawned: Label = $Margin/VBox/Split/Right/Toolbar/Spawned
@onready var _undo: Button = $Margin/VBox/Split/Right/Toolbar/Undo
@onready var _clear: Button = $Margin/VBox/Split/Right/Toolbar/Clear
@onready var _status: Label = $Margin/VBox/Split/Right/Status
@onready var _grid: ItemList = $Margin/VBox/Split/Right/Grid
@onready var _info: RichTextLabel = $Margin/VBox/Info
@onready var _hint: Label = $Margin/VBox/Footer/Hint
@onready var _count: SpinBox = $Margin/VBox/Footer/Count
@onready var _menu: PopupMenu = $ContextMenu
@onready var _search_delay: Timer = $SearchDelay
@onready var _preview: ModelPreview = $ModelPreview

## The tab's records; null until the tab is first shown with EsmServer ready.
var catalog: SpawnCatalog
var _category := 0
## The tree selection: a type ("" for the whole category) and a group path
## under it ("" for all of the type).
var _selected_type := ""
var _selected_path := ""
## In the Spawnlists category, the list shown (SpawnLists.LISTS).
var _selected_list := StringName()
## Favourites, Common and Recent; made with the catalog.
var lists: SpawnLists
## The rows in the grid, in grid order.
var _shown: Array = []
var _hovered := -1
var _menu_row: Dictionary = {}
var _glyphs: Array[Texture2D] = []
## What the last spawn did, for the status line.
var _last_result := ""
var _fade_tween: Tween
## The row whose icon is blanked under the hover preview, or -1.
var _blanked := -1
var _blank: Texture2D
## Loaded icons by their textures/ path; null for one that did not load.
## Icon paths loading now, and those waiting to (newest last; loaded first).
var _icons_loading := {}
var _icons_waiting := PackedStringArray()
## Models whose thumbnails are being requested now, and those waiting to (as
## _icons_waiting).
var _renders_loading := {}
var _renders_waiting := PackedStringArray()
## The visible range changed; icons are requested at the next frame.
var _icons_dirty := false
var _bold: Font
## Each built type's rows that match the search: {needle, rows}.
var _matches_by_type := {}
var _refresh_pending := false
var _refresh_tree_pending := false
## The tree is out of date with the matches; rebuilt at the next frame.
var _tree_pending := false
## How many of _shown the grid holds so far.
var _grid_cursor := 0

func _ready() -> void:
	_categories.tab_changed.connect(select_category)
	_tree.item_selected.connect(_on_tree_selected)
	_search.text_changed.connect(func(_text: String) -> void: _search_delay.start())
	_search.text_submitted.connect(func(_text: String) -> void: _apply_search_now())
	_search_delay.timeout.connect(_apply_search_now)
	_tree.item_collapsed.connect(_on_tree_item_collapsed)
	_size.value_changed.connect(_on_size_changed)
	_grid.get_v_scroll_bar().value_changed.connect(func(_value: float) -> void:
		_mark_icons_dirty()
		# The hovered item moves under the pointer; the next motion shows it again.
		_hovered = -1
		_hide_preview())
	_grid.resized.connect(_mark_icons_dirty)
	_undo.pressed.connect(_on_undo)
	_clear.pressed.connect(_on_clear)
	_grid.item_clicked.connect(_on_grid_clicked)
	_grid.item_activated.connect(_on_grid_activated)
	_grid.item_selected.connect(func(index: int) -> void: _show_info(index))
	_grid.gui_input.connect(_on_grid_gui_input)
	_grid.mouse_exited.connect(func() -> void:
		_hovered = -1
		_hide_preview()
		_show_info(_selected_index()))
	_menu.id_pressed.connect(_on_menu_id)
	visibility_changed.connect(_on_visibility_changed)
	if placer != null:
		placer.history_changed.connect(_update_spawned)
	_on_size_changed(_size.value)
	_update_spawned()
	set_process(false)
	_on_visibility_changed()

func _process(_delta: float) -> void:
	if catalog != null and catalog.is_building():
		catalog.poll()
	if _refresh_pending:
		_refresh(_refresh_tree_pending)
	elif _tree_pending:
		_build_tree()
	elif is_grid_filling():
		_continue_grid_fill()
	if _icons_dirty:
		_request_visible_icons()
	_start_icon_loads()
	_update_status()
	if (catalog == null or not catalog.is_building()) and not _refresh_pending and not _tree_pending \
			and not is_grid_filling() and not _icons_dirty and _icons_waiting.is_empty() \
			and _renders_waiting.is_empty():
		set_process(false)

## Sets the search text and applies it now, without the typing delay.
func apply_search(text: String) -> void:
	_search.text = text
	_apply_search_now()

func _apply_search_now() -> void:
	_search_delay.stop()
	_refresh(true)

## Ctrl+Z undoes while the tab shows, unless a text field has the key.
func _shortcut_input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_Z and key.is_command_or_control_pressed() and not key.shift_pressed:
		if get_viewport().gui_get_focus_owner() is LineEdit:
			return
		_on_undo()
		get_viewport().set_input_as_handled()

func _on_visibility_changed() -> void:
	if is_visible_in_tree():
		ensure_catalog()

## Builds the catalog the first time it is needed and shows the current
## category. False while EsmServer is not ready.
func ensure_catalog() -> bool:
	if catalog != null:
		return true
	var esm_server := EsmReference.get_esm_server()
	if esm_server == null or not esm_server.is_ready():
		return false
	catalog = SpawnCatalog.new(esm_server.reader, esm_server.get_record_index(), get_node_or_null("/root/ArchiveServer"))
	catalog.type_ready.connect(_on_type_ready)
	lists = SpawnLists.shared(lists_path)
	lists.changed.connect(_on_list_changed)
	select_category(_categories.current_tab)
	return true

# --- Selection ---------------------------------------------------------------

## Shows category `index` (SpawnCatalog.CATEGORIES), its whole content
## selected, and starts building its types.
func select_category(index: int) -> void:
	_category = clampi(index, 0, SpawnCatalog.CATEGORIES.size() - 1)
	if _categories.current_tab != _category:
		_categories.current_tab = _category
	_selected_type = ""
	_selected_path = ""
	_matches_by_type = {}
	_update_hint()
	if catalog == null:
		return
	if is_lists_category():
		# Favourites first; Common while there are none.
		_selected_list = SpawnLists.FAVOURITES if not lists.ids(SpawnLists.FAVOURITES).is_empty() else SpawnLists.COMMON
	for record_type: String in _category_types():
		catalog.request_type(record_type)
	set_process(true)
	_refresh(true)

## Selects the tree node of `record_type` at group `path` ("" for the type's
## own node), as a click on it does. False when the node is not in the tree.
func select_node(record_type: String, path := "") -> bool:
	if _tree_pending:
		_build_tree()
	var item := _find_tree_item(record_type, path)
	if item == null:
		return false
	item.select(0)
	_tree.scroll_to_item(item)
	_on_tree_selected()
	return true

## Shows list `list` (SpawnLists.LISTS) of the Spawnlists category, as a
## click on its tree node does.
func select_list(list: StringName) -> void:
	if not is_lists_category():
		select_category(SpawnCatalog.LISTS_CATEGORY)
	_selected_list = list
	_refresh(true)

## Whether the Spawnlists category is showing.
func is_lists_category() -> bool:
	return _category == SpawnCatalog.LISTS_CATEGORY

## The rows the grid shows, in order.
func shown_rows() -> Array:
	return _shown

func _on_tree_selected() -> void:
	var item := _tree.get_selected()
	var meta: Dictionary = item.get_metadata(0) if item != null else {}
	if meta.get("placeholder", false):
		return
	if meta.has("list"):
		_selected_list = meta["list"]
		_refresh(false)
		return
	_selected_type = String(meta.get("type", ""))
	_selected_path = String(meta.get("path", ""))
	_refresh(false)

## Favourites or Recent changed: the counts in the tree, and the grid when it
## shows that list.
func _on_list_changed(list: StringName) -> void:
	if is_lists_category():
		if list == _selected_list:
			_request_refresh(true)
		else:
			_tree_pending = true
			set_process(true)

## The rows of list `list`: records of any type, in the list's order, those
## the loaded data has.
func list_rows(list: StringName) -> Array:
	var rows := []
	if catalog == null or lists == null:
		return rows
	var form_ids := PackedInt64Array()
	if list == SpawnLists.COMMON:
		if lists.common != null:
			for editor_id in lists.common.editor_ids:
				var form_id := catalog.form_id_for_editor_id(editor_id)
				if form_id != 0:
					form_ids.append(form_id)
	else:
		form_ids = lists.ids(list)
	for form_id in form_ids:
		var row := catalog.row_for(form_id)
		if not row.is_empty():
			rows.append(row)
	return rows

func _on_type_ready(record_type: String) -> void:
	if _category_types().has(record_type):
		_request_refresh(true)

func _category_types() -> Array:
	return SpawnCatalog.CATEGORIES[_category]["types"]

# --- Tree and grid -----------------------------------------------------------

## Asks for a refresh at the next frame: the grid from the current matches,
## and the tree too when `rebuild_tree`. Several requests in one frame (types
## finishing together) make one refresh.
func _request_refresh(rebuild_tree: bool) -> void:
	_refresh_pending = true
	_refresh_tree_pending = _refresh_tree_pending or rebuild_tree
	set_process(true)

## Fills the grid with the selection's rows that match the search. With
## `rebuild_tree` (a new category, search or built type) the tree is rebuilt
## at the next frame, so the two costs fall in different frames.
func _refresh(rebuild_tree: bool) -> void:
	_refresh_pending = false
	_refresh_tree_pending = false
	if catalog == null:
		return
	_update_matches()
	if rebuild_tree:
		_tree_pending = true
		set_process(true)
	_shown = []
	if is_lists_category():
		var needle := _needle()
		for row: Dictionary in list_rows(_selected_list):
			if needle.is_empty() or SpawnCatalog.matches(row, needle):
				_shown.append(row)
		_fill_grid()
		_update_status()
		return
	for record_type: String in _category_types():
		if not _matches_by_type.has(record_type) or (not _selected_type.is_empty() and record_type != _selected_type):
			continue
		var rows: Array = _matches_by_type[record_type]["rows"]
		if _selected_path.is_empty():
			_shown.append_array(rows)
			continue
		for row: Dictionary in rows:
			if SpawnCatalog.in_group(row, _selected_path):
				_shown.append(row)
	_fill_grid()
	_update_status()

## The search box's text as a search: trimmed and lower case.
func _needle() -> String:
	return _search.text.strip_edges().to_lower()

## Brings _matches_by_type up to the search for every built type.
func _update_matches() -> void:
	var needle := _needle()
	for record_type: String in _category_types():
		if not catalog.is_type_ready(record_type):
			continue
		if (_matches_by_type.get(record_type, {}) as Dictionary).get("needle") == needle:
			continue
		_matches_by_type[record_type] = {"needle": needle, "rows": catalog.search(record_type, needle)}

## Rebuilds the tree from the matches: each type's node, and below it only the
## children of expanded nodes. A collapsed node with children holds one
## placeholder child until it is expanded (_on_tree_item_collapsed), so a
## large type costs only its top level. While searching, each type's first
## level shows.
func _build_tree() -> void:
	_tree_pending = false
	var searching := not _needle().is_empty()
	_tree.clear()
	var root := _tree.create_item()
	var selected: TreeItem = null
	if is_lists_category():
		var needle := _needle()
		for list: StringName in SpawnLists.LISTS:
			var rows := list_rows(list)
			var count := rows.size() if needle.is_empty() else rows.filter(func(r: Dictionary) -> bool: return SpawnCatalog.matches(r, needle)).size()
			var list_item := _tree.create_item(root)
			list_item.set_text(0, "%s (%d)" % [SpawnLists.LIST_NAMES[list], count])
			list_item.set_custom_font(0, _bold_font())
			list_item.set_metadata(0, {"list": list})
			if list == _selected_list:
				list_item.select(0)
		return
	for record_type: String in _category_types():
		var type_item := _tree.create_item(root)
		if not _matches_by_type.has(record_type):
			type_item.set_text(0, "%s (indexing…)" % SpawnCatalog.type_label(record_type))
			type_item.set_custom_font(0, _bold_font())
			type_item.set_custom_color(0, Color(0.6, 0.6, 0.6))
			type_item.set_metadata(0, {"type": record_type, "path": "", "node": {}})
			continue
		var node := SpawnCatalog.tree_from_rows(record_type, _matches_by_type[record_type]["rows"]) if searching \
				else catalog.build_tree(record_type)
		type_item.set_text(0, "%s (%d)" % [SpawnCatalog.type_label(record_type), node["count"]])
		type_item.set_custom_font(0, _bold_font())
		type_item.set_metadata(0, {"type": record_type, "path": "", "node": node})
		if searching and int(node["count"]) == 0:
			type_item.visible = false
		_add_placeholder(type_item, node)
		if searching or record_type == _selected_type:
			type_item.collapsed = false
			_expand(type_item)
		if record_type == _selected_type:
			selected = _reveal(type_item, _selected_path)
	if selected != null:
		selected.select(0)
	elif not _selected_type.is_empty():
		_selected_type = ""
		_selected_path = ""

func _add_placeholder(item: TreeItem, node: Dictionary) -> void:
	item.collapsed = true
	if not (node.get("children", []) as Array).is_empty():
		var placeholder := _tree.create_item(item)
		placeholder.set_metadata(0, {"placeholder": true})
		placeholder.set_text(0, "…")
		placeholder.set_selectable(0, false)

## Replaces `item`'s placeholder with its real children (each collapsed, with
## a placeholder of its own).
func _expand(item: TreeItem) -> void:
	var first := item.get_first_child()
	if first == null or not (first.get_metadata(0) as Dictionary).get("placeholder", false):
		return
	item.remove_child(first)
	first.free()
	var meta: Dictionary = item.get_metadata(0)
	for child: Dictionary in meta["node"]["children"]:
		var child_item := _tree.create_item(item)
		child_item.set_text(0, "%s (%d)" % [child["name"], child["count"]])
		child_item.set_metadata(0, {"type": meta["type"], "path": child["path"], "node": child})
		_add_placeholder(child_item, child)

## Expanding a node by its arrow fires this inside the Tree's mouse event,
## when the Tree refuses to create items, so its children are added after the
## event. The tree may be rebuilt meanwhile, freeing `item`.
func _on_tree_item_collapsed(item: TreeItem) -> void:
	if not item.collapsed:
		_expand_later.call_deferred(item)

## Untyped: a tree rebuilt in between frees `item`, and a freed object fails a
## typed parameter before is_instance_valid() can see it.
func _expand_later(item) -> void:
	if is_instance_valid(item) and not (item as TreeItem).collapsed:
		_expand(item)

## Expands the tree from `type_item` down to the node at `path` and returns
## it; null when no node has that path.
func _reveal(type_item: TreeItem, path: String) -> TreeItem:
	var item := type_item
	var walked := ""
	for part in path.split("/", false):
		walked = part if walked.is_empty() else walked + "/" + part
		_expand(item)
		item.collapsed = false
		var next: TreeItem = null
		for child in item.get_children():
			if (child.get_metadata(0) as Dictionary).get("path") == walked:
				next = child
				break
		if next == null:
			return null
		item = next
	return item

func _find_tree_item(record_type: String, path: String) -> TreeItem:
	var root := _tree.get_root()
	if root == null:
		return null
	for type_item in root.get_children():
		if (type_item.get_metadata(0) as Dictionary).get("type") == record_type:
			return _reveal(type_item, path)
	return null

## Starts showing _shown in the grid: as many items as fit in
## GRID_FILL_BUDGET_USEC now, the rest over the next frames (_process).
## Existing items are overwritten in place from the top, and any left over
## past the new end are removed afterwards, also within the budget: clearing
## a full grid at once costs more than a frame (~13 ms for 6785 items).
func _fill_grid() -> void:
	_grid.tooltip_text = ""
	_grid.deselect_all()
	_grid.get_v_scroll_bar().value = 0
	_hovered = -1
	_grid_cursor = 0
	_icons_waiting.clear()
	_renders_waiting.clear()
	# The grid is rewritten, so no icon needs restoring.
	_blanked = -1
	_preview.hide_preview()
	_continue_grid_fill()
	_mark_icons_dirty()
	_show_info(-1)

func _continue_grid_fill() -> void:
	var started := Time.get_ticks_usec()
	var missing_colour := Color("#e5c07b")
	while _grid_cursor < _shown.size():
		var row: Dictionary = _shown[_grid_cursor]
		var icon := _row_icon(row, _row_glyph(row))
		if _grid_cursor < _grid.item_count:
			_grid.set_item_text(_grid_cursor, String(row["display_name"]))
			_grid.set_item_icon(_grid_cursor, icon)
		else:
			_grid.add_item(String(row["display_name"]), icon)
			_grid.set_item_tooltip_enabled(_grid_cursor, false)
		# Color() is ItemList's "no custom colour".
		_grid.set_item_custom_fg_color(_grid_cursor, missing_colour if row["model_missing"] else Color())
		_grid_cursor += 1
		if Time.get_ticks_usec() - started > GRID_FILL_BUDGET_USEC:
			break
	while _grid_cursor >= _shown.size() and _grid.item_count > _shown.size() \
			and Time.get_ticks_usec() - started <= GRID_FILL_BUDGET_USEC:
		_grid.item_count = maxi(_shown.size(), _grid.item_count - GRID_TRIM_CHUNK)
	if is_grid_filling():
		set_process(true)

## The tree selection as a path: `Weapon [WEAP] / weapons / 1handpistol`, or
## `All Items` for the whole category.
func selection_path() -> String:
	if is_lists_category():
		return "%s / %s" % [SpawnCatalog.CATEGORIES[_category]["name"], SpawnLists.LIST_NAMES.get(_selected_list, "")]
	if _selected_type.is_empty():
		return "All %s" % SpawnCatalog.CATEGORIES[_category]["name"]
	var parts := PackedStringArray([SpawnCatalog.type_label(_selected_type)])
	parts.append_array(_selected_path.split("/", false))
	return " / ".join(parts)

# --- Icons -------------------------------------------------------------------

func _mark_icons_dirty() -> void:
	_icons_dirty = true
	set_process(true)

## The grid rows on screen and one screen below, as [first, last] indices
## into _shown; [0, -1] for none.
func visible_range() -> Vector2i:
	if _shown.is_empty() or _grid.item_count == 0:
		return Vector2i(0, -1)
	# Probed inside the panel's margin: a point in the margin answers row 0
	# however far the grid is scrolled.
	var inset := _grid.get_theme_stylebox(&"panel").get_offset() + Vector2(4, 4)
	var first := _grid.get_item_at_position(inset, false)
	var last := _grid.get_item_at_position(_grid.size - inset, false)
	if first < 0 or last < first:
		return Vector2i(0, -1)
	last = mini(last + (last - first + 1), _shown.size() - 1)
	return Vector2i(first, last)

## Shows the loaded icons of the visible range and queues the rest that are
## not loading, in place of whatever was still waiting: the top of the screen
## loads first.
func _request_visible_icons() -> void:
	_icons_dirty = false
	_icons_waiting.clear()
	_renders_waiting.clear()
	var range_ := visible_range()
	for index in range(range_.y, range_.x - 1, -1):
		var row: Dictionary = _shown[index]
		var icon := String(row["shown_icon"])
		if icon.is_empty():
			var model := thumbnail_model(row)
			if model.is_empty() or _renders_loading.has(model) or _renders_waiting.has(model):
				continue
			if ThumbnailServer.has_render(model):
				_apply_icon(index, ThumbnailServer.cached_render(model))
			else:
				_renders_waiting.append(model)
		elif _icons_loading.has(icon) or _icons_waiting.has(icon):
			continue
		elif ThumbnailServer.has_icon(icon):
			_apply_icon(index, ThumbnailServer.cached_icon(icon))
		else:
			_icons_waiting.append(icon)

## The model rendered as row's thumbnail, or "": a record with no ICON whose
## model the preview shows.
static func thumbnail_model(row: Dictionary) -> String:
	return _preview_model(row) if String(row["shown_icon"]).is_empty() else ""

func _apply_icon(index: int, texture: Texture2D) -> void:
	if texture != null and index < _grid_cursor and index != _blanked and _grid.get_item_icon(index) != texture:
		_grid.set_item_icon(index, texture)

func _start_icon_loads() -> void:
	while _icons_loading.size() < ICON_LOADS_AT_ONCE and not _icons_waiting.is_empty():
		var icon := _icons_waiting[_icons_waiting.size() - 1]
		_icons_waiting.remove_at(_icons_waiting.size() - 1)
		_icons_loading[icon] = true
		_load_icon(icon)
	while _renders_loading.size() < RENDERS_AT_ONCE and not _renders_waiting.is_empty():
		var model := _renders_waiting[_renders_waiting.size() - 1]
		_renders_waiting.remove_at(_renders_waiting.size() - 1)
		_renders_loading[model] = true
		_load_render(model)

func _load_render(model: String) -> void:
	var texture := await ThumbnailServer.request_render(model)
	_renders_loading.erase(model)
	if not is_inside_tree():
		return
	if texture != null:
		var range_ := visible_range()
		for index in range(range_.x, range_.y + 1):
			if thumbnail_model(_shown[index]) == model:
				_apply_icon(index, texture)
	set_process(true)

## Whether any icon or thumbnail is waiting or loading.
func is_loading_thumbnails() -> bool:
	return _icons_dirty or not _icons_waiting.is_empty() or not _icons_loading.is_empty() \
			or not _renders_waiting.is_empty() or not _renders_loading.is_empty()

func _load_icon(icon: String) -> void:
	var texture := await ThumbnailServer.request_icon(icon)
	_icons_loading.erase(icon)
	if texture == null or not is_inside_tree():
		return
	var range_ := visible_range()
	for index in range(range_.x, range_.y + 1):
		if _shown[index]["shown_icon"] == icon:
			_apply_icon(index, texture)
	set_process(true)

## The icon shown for grid row `index`: its inventory icon or model render once
## loaded, else the category glyph.
func item_icon(index: int) -> Texture2D:
	return _grid.get_item_icon(index) if index >= 0 and index < _grid.item_count else null

## Whether the grid is still being filled over frames.
func is_grid_filling() -> bool:
	return _grid_cursor < _shown.size() or _grid.item_count > _shown.size()

func _update_status() -> void:
	var parts := PackedStringArray()
	parts.append("%d records in %s" % [_shown.size(), selection_path()])
	if catalog != null and catalog.is_building():
		parts.append("Indexing %s…" % (catalog.building_type() if not catalog.building_type().is_empty() else "…"))
	if not _last_result.is_empty():
		parts.append(_last_result)
	_status.text = "   ·   ".join(parts)

func _on_size_changed(value: float) -> void:
	var icon_size := int(value)
	_grid.fixed_icon_size = Vector2i(icon_size, icon_size)
	_grid.fixed_column_width = icon_size + 40

## A plain square in the category's colour, standing in for a thumbnail.
func _glyph(category: int) -> Texture2D:
	if _glyphs.is_empty():
		for colour: Color in CATEGORY_COLOURS:
			var image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
			image.fill(colour.darkened(0.55))
			image.fill_rect(Rect2i(3, 3, 26, 26), colour.darkened(0.15))
			_glyphs.append(ImageTexture.create_from_image(image))
	return _glyphs[clampi(category, 0, _glyphs.size() - 1)]

# --- Info bar ----------------------------------------------------------------

func _on_grid_gui_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	if motion == null:
		return
	var index := _grid.get_item_at_position(motion.position, true)
	if index != _hovered:
		hover_row(index)
	if _hovered >= 0:
		_preview.set_pointer(pointer_in_cell(_hovered, motion.position))

## Where `grid_position` (in the grid's coordinates) is within row `index`'s
## cell: -1 to 1 on each axis, 0 at the cell's centre, positive right and down.
func pointer_in_cell(index: int, grid_position: Vector2) -> Vector2:
	var cell := _grid.get_item_rect(index)
	# get_item_rect() does not account for scrolling.
	cell.position.y -= _grid.get_v_scroll_bar().value
	var half := (cell.size * 0.5).max(Vector2.ONE)
	return ((grid_position - cell.get_center()) / half).clamp(-Vector2.ONE, Vector2.ONE)

## Shows grid row `index` as hovered: the info bar, the tooltip and, for a
## record with a model, the 3D preview over its icon. -1 for none.
func hover_row(index: int) -> void:
	_hovered = index if index >= 0 and index < _grid_cursor else -1
	_grid.tooltip_text = _row_tooltip(_shown[_hovered]) if _hovered >= 0 else ""
	_show_info(_hovered if _hovered >= 0 else _selected_index())
	var model := _preview_model(_shown[_hovered]) if _hovered >= 0 else ""
	if model.is_empty():
		_hide_preview()
		return
	_restore_blanked()
	_preview.show_model(model, preview_rect(_hovered))
	# The preview's backdrop is see-through, so the icon under it is blanked
	# while it shows; a blank of the same size keeps the cell's layout.
	_grid.set_item_icon(_hovered, _blank_icon())
	_blanked = _hovered

func _hide_preview() -> void:
	_preview.hide_preview()
	_restore_blanked()

## Gives the row whose icon the preview blanked its icon back.
func _restore_blanked() -> void:
	if _blanked >= 0 and _blanked < _grid_cursor and _blanked < _shown.size():
		_grid.set_item_icon(_blanked, _row_icon(_shown[_blanked], _row_glyph(_shown[_blanked])))
	_blanked = -1

## The glyph a row shows without a picture: its own type's category's, so a
## list of mixed types tells them apart.
func _row_glyph(row: Dictionary) -> Texture2D:
	var category := SpawnCatalog.category_index_for_type(String(row["record_type"]))
	return _glyph(category if category >= 0 else _category)

## A row's grid icon: its inventory icon or model render once loaded, else
## `glyph`.
func _row_icon(row: Dictionary, glyph: Texture2D) -> Texture2D:
	var icon: Texture2D
	if not String(row["shown_icon"]).is_empty():
		icon = ThumbnailServer.cached_icon(String(row["shown_icon"]))
	else:
		var model := thumbnail_model(row)
		icon = ThumbnailServer.cached_render(model) if not model.is_empty() else null
	return icon if icon != null else glyph

func _blank_icon() -> Texture2D:
	if _blank == null:
		var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		image.fill(Color(0, 0, 0, 0))
		_blank = ImageTexture.create_from_image(image)
	return _blank

## The model key (ThumbnailServer.request_model()) a row's preview and
## thumbnail show: its `shown_model` (RecordVisuals: the record's own model,
## another of its model subrecords, a creature's body parts, or a leveled
## list's entry's), "" for none.
static func _preview_model(row: Dictionary) -> String:
	return String(row["shown_model"])

## Where the preview of grid row `index` goes, in this tab's coordinates: the
## row's icon, grown by PREVIEW_SCALE about its centre.
func preview_rect(index: int) -> Rect2:
	var item := _grid.get_item_rect(index)
	# get_item_rect() does not account for scrolling.
	item.position.y -= _grid.get_v_scroll_bar().value
	var icon := Vector2(_grid.fixed_icon_size)
	var centre := Vector2(item.get_center().x, item.position.y + icon.y * 0.5)
	var grown := icon * PREVIEW_SCALE
	return Rect2(_grid.global_position - global_position + centre - grown * 0.5, grown)

## The grid's tooltip for a row, set on hover rather than per item.
static func _row_tooltip(row: Dictionary) -> String:
	var tooltip := "%s\n%s %s 0x%08X" % [row["display_name"], row["record_type"], row["editor_id"], row["form_id"]]
	if row["model_missing"]:
		tooltip += "\nModel not in any archive: meshes/%s" % row["model"]
	if row["shown_leveled"]:
		tooltip += "\nLooks vary: %s; shown is its first entry with a picture, lowest level first" \
				% ("its template is a leveled list" if row["record_type"] == "CREA" else "a leveled list")
	elif String(row["icon"]).is_empty() and String(row["shown_icon"]).is_empty() and (row["parts"] as PackedStringArray).is_empty() \
			and not String(row["shown_model"]).is_empty() and row["shown_model"] != "meshes/" + String(row["model"]):
		tooltip += "\nNo world model; shown is %s" % row["shown_model"]
	return tooltip

func _selected_index() -> int:
	var selected := _grid.get_selected_items()
	return selected[0] if not selected.is_empty() else -1

## Shows row `index` of the grid in the info bar; with none, what the tab does.
func _show_info(index: int) -> void:
	if index < 0 or index >= _shown.size():
		_info.text = "[color=#7f848e]Hover a record to see it here.[/color]"
		return
	var row: Dictionary = _shown[index]
	var parts := PackedStringArray([
		"[b]%s[/b]" % _escape(row["display_name"]),
		_escape(row["editor_id"]) if not String(row["editor_id"]).is_empty() else "[color=#7f848e](no EditorID)[/color]",
		"%s 0x%08X" % [row["record_type"], row["form_id"]],
	])
	if not String(row["model"]).is_empty():
		var model := "meshes/" + String(row["model"])
		parts.append("[color=#e5c07b]%s (not in any archive)[/color]" % _escape(model) if row["model_missing"] else _escape(model))
	var base: EsmBase = EsmReference.get_esm_server().get_base(int(row["form_id"])) if row["record_type"] in SpawnCatalog.INVENTORY_TYPES else null
	if base != null and "value" in base and "weight" in base:
		parts.append("value %d, weight %s" % [base.get("value"), str(snappedf(float(base.get("weight")), 0.01))])
	_info.text = "  ·  ".join(parts)

static func _escape(value: Variant) -> String:
	return String(value).replace("[", "[lb]")

func _update_hint() -> void:
	var action := StringName(SpawnCatalog.CATEGORIES[_category]["action"])
	match action:
		SpawnCatalog.ACTION_LISTS:
			_hint.text = "Double click: place at crosshair    Shift+click: give to player (items)    Right click: Add to Favourites and more"
		SpawnCatalog.ACTION_INVENTORY:
			_hint.text = "Double click: place at crosshair    Shift+click: give to player    Right click: more"
		SpawnCatalog.ACTION_RESOLVE:
			_hint.text = "Double click: resolve at the player's level and place    Shift+click: give to player (LVLI)    Right click: more"
		_:
			_hint.text = "Double click: place at crosshair    Right click: more"

# --- Spawning ----------------------------------------------------------------

func _on_grid_clicked(index: int, at_position: Vector2, mouse_button_index: int) -> void:
	# Items past _grid_cursor still show the previous list for a frame or two.
	if index < 0 or index >= _shown.size() or index >= _grid_cursor:
		return
	if mouse_button_index == MOUSE_BUTTON_LEFT:
		if Input.is_key_pressed(KEY_SHIFT):
			give_row(index)
	elif mouse_button_index == MOUSE_BUTTON_RIGHT:
		_open_menu(index, _grid.get_screen_position() + at_position)

## A double click or Enter on a grid item; Shift and a double click is two
## Shift and clicks, which already gave it.
func _on_grid_activated(index: int) -> void:
	if index < 0 or index >= _shown.size() or index >= _grid_cursor or Input.is_key_pressed(KEY_SHIFT):
		return
	place_row(index)

## Places grid row `index` at the crosshair (double click), a leveled list
## resolved first. Returns the placed references, or null.
func place_row(index: int) -> Variant:
	if index < 0 or index >= _shown.size():
		return null
	return _spawn(_shown[index], false)

## Gives grid row `index` to the player (Shift and click): the number of items
## added, or 0 for a record that cannot be carried (null for no row).
func give_row(index: int) -> Variant:
	if index < 0 or index >= _shown.size():
		return null
	var row: Dictionary = _shown[index]
	if not _can_add_to_inventory(row):
		_last_result = "%s can't be carried; double click to place it" % row["display_name"]
		_update_status()
		return 0
	return _spawn(row, true)

## Whether `row` can go in the inventory: Items, and LVLI. Also picks the
## console command (AddItem or PlaceAtMe).
static func _adds_to_inventory(row: Dictionary) -> bool:
	var record_type := String(row["record_type"])
	return SpawnCatalog.INVENTORY_TYPES.has(record_type) or record_type == "LVLI"

static func _can_add_to_inventory(row: Dictionary) -> bool:
	return _adds_to_inventory(row)

func _spawn(row: Dictionary, to_inventory: bool) -> Variant:
	if placer == null:
		_last_result = "No SpawnPlacer"
		_update_status()
		return null
	var count := int(_count.value)
	var form_id := int(row["form_id"])
	var result: Variant
	if to_inventory:
		var player := _player()
		var added := placer.add_to_inventory(form_id, player, count) if player != null else 0
		_last_result = "Added %d × %s" % [added, row["display_name"]] if added > 0 else "Added nothing (%s)" % row["display_name"]
		result = added
	else:
		var placed := placer.place_at_crosshair(form_id, count)
		_last_result = _placed_text(row, placed)
		result = placed
	_update_status()
	if (result is int and result > 0) or (result is Array and not (result as Array).is_empty()):
		flash_spawned()
		if lists != null:
			lists.add_recent(form_id)
	return result

## Drops fade_target quickly to fade_alpha and eases it back to opaque, so
## whatever was just spawned shows through the menu for a moment. A spawn
## during the fade starts it again from where it is.
func flash_spawned() -> void:
	var target := fade_target if fade_target != null else get_parent().get_parent() as CanvasItem
	if target == null:
		return
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
	_fade_tween = create_tween()
	_fade_tween.tween_property(target, "modulate:a", fade_alpha, fade_out_time) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_fade_tween.tween_property(target, "modulate:a", 1.0, fade_in_time) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

## Whether the spawn fade is running.
func is_flashing() -> bool:
	return _fade_tween != null and _fade_tween.is_running()

## The tree's font, emboldened, for the type nodes.
func _bold_font() -> Font:
	if _bold == null:
		var bold := FontVariation.new()
		bold.base_font = _tree.get_theme_font(&"font")
		bold.variation_embolden = 0.8
		_bold = bold
	return _bold

## "Placed 2 × Name", naming what a leveled list resolved to.
static func _placed_text(row: Dictionary, placed: Array[EsmReference]) -> String:
	if placed.is_empty():
		return "Placed nothing (%s)" % row["display_name"]
	if not String(row["record_type"]) in SpawnCatalog.LEVELED_TYPES:
		return "Placed %d × %s" % [placed.size(), row["display_name"]]
	var names := PackedStringArray()
	for reference in placed:
		var base := reference.base
		names.append(SpawnCatalog.display_name(base.full_name, base.editor_id, base.record_type, base.form_id) if base != null else "?")
	return "%s gave %s" % [row["display_name"], ", ".join(names)]

## Gives the player one of `row`'s weapon or armor and equips it
## (SpawnPlacer.equip()). Returns the equipped WeaponReference or worn
## InventoryItem, or null.
func equip_row(row: Dictionary) -> Object:
	if placer == null:
		return null
	var equipped := placer.equip(int(row["form_id"]), _player())
	_last_result = "Equipped %s" % row["display_name"] if equipped != null else "Could not equip %s" % row["display_name"]
	_update_status()
	if equipped != null:
		flash_spawned()
		if lists != null:
			lists.add_recent(int(row["form_id"]))
	return equipped

## Adds `row`'s record to Favourites, or takes it out; true when it is now a
## favourite.
func toggle_favourite(row: Dictionary) -> bool:
	if lists == null:
		return false
	var added := lists.toggle_favourite(int(row["form_id"]))
	_last_result = "%s %s Favourites" % [row["display_name"], "added to" if added else "removed from"]
	_update_status()
	return added

func _player() -> EsmReference:
	var script_server := get_node_or_null("/root/ScriptServer")
	var player: EsmReference = script_server.player_reference if script_server != null else null
	if player == null:
		var esm_server := EsmReference.get_esm_server()
		player = esm_server.get_player_reference() if esm_server != null else null
	return player

func _on_undo() -> void:
	if placer != null and placer.undo():
		_last_result = "Undone"
		_update_status()

func _on_clear() -> void:
	if placer != null:
		var n := placer.clear()
		_last_result = "Cleared %d spawn%s" % [n, "" if n == 1 else "s"]
		_update_status()

func _update_spawned() -> void:
	var n := placer.history_size() if placer != null else 0
	_spawned.text = "%d spawned" % n
	_undo.disabled = n == 0
	_clear.disabled = n == 0

# --- Context menu ------------------------------------------------------------

func _open_menu(index: int, screen_position: Vector2) -> void:
	_menu_row = _shown[index]
	_menu.set_item_disabled(_menu.get_item_index(MENU_INVENTORY), not _can_add_to_inventory(_menu_row))
	_menu.set_item_disabled(_menu.get_item_index(MENU_EQUIP), not _menu_row["record_type"] in ["WEAP", "ARMO"])
	_menu.set_item_disabled(_menu.get_item_index(MENU_COPY_EDITOR_ID), String(_menu_row["editor_id"]).is_empty())
	var favourite := lists != null and lists.is_favourite(int(_menu_row["form_id"]))
	_menu.set_item_text(_menu.get_item_index(MENU_FAVOURITE), "Remove from Favourites" if favourite else "Add to Favourites")
	_menu.position = Vector2i(screen_position)
	_menu.reset_size()
	_menu.popup()

func _on_menu_id(id: int) -> void:
	if _menu_row.is_empty():
		return
	match id:
		MENU_PLACE:
			_spawn(_menu_row, false)
		MENU_INVENTORY:
			_spawn(_menu_row, true)
		MENU_EQUIP:
			equip_row(_menu_row)
		MENU_FAVOURITE:
			toggle_favourite(_menu_row)
		MENU_COPY_EDITOR_ID:
			DisplayServer.clipboard_set(String(_menu_row["editor_id"]))
		MENU_COPY_COMMAND:
			DisplayServer.clipboard_set(console_command(_menu_row, int(_count.value)))
		MENU_OPEN_IN_CONSOLE:
			var console := get_tree().get_first_node_in_group(&"console") as ConsoleOverlay
			if console != null:
				console.open_with_line(console_command(_menu_row, int(_count.value)))

## The console line that spawns `row` as a plain click does: `player.AddItem`
## for what goes into the inventory, else `player.PlaceAtMe`. The record is
## named by EditorID, or by its 8-digit FormID without one.
static func console_command(row: Dictionary, count: int) -> String:
	var record := String(row["editor_id"]) if not String(row["editor_id"]).is_empty() else "%08X" % int(row["form_id"])
	return "player.%s %s %d" % ["AddItem" if _adds_to_inventory(row) else "PlaceAtMe", record, maxi(count, 1)]
