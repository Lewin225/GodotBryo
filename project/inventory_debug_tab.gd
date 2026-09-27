extends Control

@onready var _filter_edit: LineEdit = $Margin/VBox/FilterEdit
@onready var _tree: Tree = $Margin/VBox/ItemTree
@onready var _status: RichTextLabel = $Margin/VBox/Status
@onready var _inc: Button = $Margin/VBox/Buttons/Increment
@onready var _delete: Button = $Margin/VBox/Buttons/Delete
@onready var _drop: Button = $Margin/VBox/Buttons/Drop

var _game: Node3D


func _ready() -> void:
	_game = get_tree().root.get_node_or_null("Game")
	_setup_tree()
	_filter_edit.text_changed.connect(func(_t: String) -> void: _refresh())
	_inc.pressed.connect(_increment)
	_delete.pressed.connect(_delete_selected)
	_drop.pressed.connect(_drop_selected)
	_refresh()


func _setup_tree() -> void:
	_tree.columns = 6
	_tree.column_titles_visible = true
	_tree.hide_root = true
	_tree.select_mode = Tree.SELECT_ROW

	_tree.set_column_title(0, "Qty")
	_tree.set_column_expand(0, false)
	_tree.set_column_custom_minimum_width(0, 50)

	_tree.set_column_title(1, "Item Name")
	_tree.set_column_expand(1, true)

	_tree.set_column_title(2, "FormID")
	_tree.set_column_expand(2, false)
	_tree.set_column_custom_minimum_width(2, 100)

	_tree.set_column_title(3, "Weight")
	_tree.set_column_expand(3, false)
	_tree.set_column_custom_minimum_width(3, 75)

	_tree.set_column_title(4, "Value")
	_tree.set_column_expand(4, false)
	_tree.set_column_custom_minimum_width(4, 65)

	_tree.set_column_title(5, "Total Wt")
	_tree.set_column_expand(5, false)
	_tree.set_column_custom_minimum_width(5, 80)


func _process(_delta: float) -> void:
	if is_visible_in_tree():
		_refresh()


func _resolve_item_name(entry: Dictionary) -> String:
	var full: String = String(entry.get("full_name", "")).strip_edges()
	if not full.is_empty():
		return full
	var edid: String = String(entry.get("editor_id", "")).strip_edges()
	if not edid.is_empty():
		return edid
	return "Item 0x%X" % int(entry.get("base_form_id", 0))


func _refresh() -> void:
	if _game == null or _game.inventory == null:
		_status.text = "Game / Inventory not found"
		return

	var prev_selected_id := _selected_id()
	_tree.clear()
	var root := _tree.create_item()

	var filter_text := _filter_edit.text.to_lower().strip_edges()
	var entries: Array = _game.inventory.get_entries()

	var distinct_types := 0
	var total_count := 0
	var total_weight := 0.0
	var total_value := 0
	var selected_item_found: TreeItem = null

	for entry in entries:
		var base_id := int(entry.get("base_form_id", 0))
		var count := int(entry.get("count", 1))
		var unit_wt := float(entry.get("weight", 0.0))
		var unit_val := int(entry.get("value", 0))
		var item_name := _resolve_item_name(entry)
		var hex_id := "0x%08X" % base_id

		total_count += count
		total_weight += unit_wt * count
		total_value += unit_val * count
		distinct_types += 1

		# Filter search
		if not filter_text.is_empty():
			if item_name.to_lower().find(filter_text) == -1 and hex_id.to_lower().find(filter_text) == -1:
				continue

		var item := _tree.create_item(root)
		item.set_metadata(0, base_id)
		item.set_text(0, str(count))
		item.set_text_alignment(0, HORIZONTAL_ALIGNMENT_CENTER)

		item.set_text(1, item_name)
		item.set_custom_color(1, Color("#e5c07b"))

		item.set_text(2, hex_id)
		item.set_text_alignment(2, HORIZONTAL_ALIGNMENT_CENTER)
		item.set_custom_color(2, Color("#61afef"))

		item.set_text(3, "%.2f" % unit_wt)
		item.set_text_alignment(3, HORIZONTAL_ALIGNMENT_RIGHT)
		item.set_custom_color(3, Color("#abb2bf"))

		item.set_text(4, "%d" % unit_val)
		item.set_text_alignment(4, HORIZONTAL_ALIGNMENT_RIGHT)
		item.set_custom_color(4, Color("#98c379"))

		item.set_text(5, "%.2f" % (unit_wt * count))
		item.set_text_alignment(5, HORIZONTAL_ALIGNMENT_RIGHT)
		item.set_custom_color(5, Color("#d19a66"))

		if base_id == prev_selected_id:
			selected_item_found = item

	if selected_item_found != null:
		selected_item_found.select(0)

	_status.text = "[b]%d[/b] distinct item(s)   •   [b]%d[/b] total items   •   Total Weight: [color=#e5c07b][b]%.2f[/b] lbs[/color]   •   Total Value: [color=#98c379][b]%d[/b] caps[/color]" % [
		distinct_types, total_count, total_weight, total_value
	]


func _selected_id() -> int:
	var selected := _tree.get_selected()
	if selected == null:
		return 0
	return int(selected.get_metadata(0))


func _increment() -> void:
	var id := _selected_id()
	if id != 0 and _game != null and _game.has_method("debug_add_inventory_item"):
		_game.debug_add_inventory_item(id)


func _delete_selected() -> void:
	var id := _selected_id()
	if id != 0 and _game != null and _game.inventory != null:
		_game.inventory.remove_item(id)


func _drop_selected() -> void:
	var id := _selected_id()
	if id != 0 and _game != null and _game.has_method("debug_drop_inventory_item"):
		_game.debug_drop_inventory_item(id)
