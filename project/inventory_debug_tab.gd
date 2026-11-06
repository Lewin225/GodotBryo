extends Control

## The possessed actor's inventory (ActorReference.contents): one row per
## entry, a stack or one held item reference, with its count, name, base
## FormID, the reference's instance_id when it is one, and weight and value
## from the base. Increment adds one to a stack; Delete removes one from the
## entry; Drop places the whole entry in front of the actor
## (ActorReference.drop_entry()): a held reference as itself, a stack as one new
## runtime reference per unit.

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
	_tree.columns = 7
	_tree.column_titles_visible = true
	_tree.hide_root = true
	_tree.select_mode = Tree.SELECT_ROW
	_add_column(0, "Qty", 50)
	_add_column(1, "Item Name", 0)
	_add_column(2, "FormID", 100)
	_add_column(3, "Reference", 190)
	_add_column(4, "Weight", 75)
	_add_column(5, "Value", 65)
	_add_column(6, "Total Wt", 80)


## A column; 0 width expands to fill.
func _add_column(column: int, title: String, width: int) -> void:
	_tree.set_column_title(column, title)
	_tree.set_column_expand(column, width == 0)
	if width > 0:
		_tree.set_column_custom_minimum_width(column, width)


func _process(_delta: float) -> void:
	if is_visible_in_tree():
		_refresh()


## The possessed actor, or null.
func _actor() -> ActorReference:
	if _game == null or _game.player == null:
		return null
	return _game.player.possessed


func _refresh() -> void:
	var actor := _actor()
	if actor == null or actor.contents == null:
		_status.text = "No possessed actor with an inventory"
		return
	var selected := _selected_entry()
	_tree.clear()
	var root := _tree.create_item()
	var filter_text := _filter_edit.text.to_lower().strip_edges()
	var total_count := 0
	var total_weight := 0.0
	var total_value := 0
	var entries := actor.contents.get_items()
	for entry in entries:
		var weight := _base_number(entry.base, "weight")
		var value := int(_base_number(entry.base, "value"))
		total_count += entry.count
		total_weight += weight * entry.count
		total_value += value * entry.count
		if not _matches(entry, filter_text):
			continue
		var row := _add_row(root, entry, weight, value)
		if entry == selected:
			row.select(0)
	_status.text = "[b]%d[/b] entries   •   [b]%d[/b] total items   •   Total Weight: [color=#e5c07b][b]%.2f[/b] lbs[/color]   •   Total Value: [color=#98c379][b]%d[/b] caps[/color]" % [
		entries.size(), total_count, total_weight, total_value
	]


func _add_row(root: TreeItem, entry: InventoryItem, weight: float, value: int) -> TreeItem:
	var row := _tree.create_item(root)
	row.set_metadata(0, entry)
	row.set_text(0, str(entry.count))
	row.set_text_alignment(0, HORIZONTAL_ALIGNMENT_CENTER)
	row.set_text(1, _item_name(entry))
	row.set_custom_color(1, Color("#e5c07b"))
	row.set_text(2, "0x%08X" % entry.base_form_id)
	row.set_text_alignment(2, HORIZONTAL_ALIGNMENT_CENTER)
	row.set_custom_color(2, Color("#61afef"))
	var reference_text := String(entry.item_reference.instance_id) if entry.item_reference != null else "stack"
	row.set_text(3, reference_text)
	row.set_custom_color(3, Color("#c678dd") if entry.item_reference != null else Color("#5c6370"))
	row.set_text(4, "%.2f" % weight)
	row.set_text_alignment(4, HORIZONTAL_ALIGNMENT_RIGHT)
	row.set_text(5, "%d" % value)
	row.set_text_alignment(5, HORIZONTAL_ALIGNMENT_RIGHT)
	row.set_custom_color(5, Color("#98c379"))
	row.set_text(6, "%.2f" % (weight * entry.count))
	row.set_text_alignment(6, HORIZONTAL_ALIGNMENT_RIGHT)
	row.set_custom_color(6, Color("#d19a66"))
	return row


## Whether the entry's name, FormID or reference contains `filter_text`.
func _matches(entry: InventoryItem, filter_text: String) -> bool:
	if filter_text.is_empty():
		return true
	var reference_text := String(entry.item_reference.instance_id) if entry.item_reference != null else ""
	var haystack := "%s 0x%08x %s" % [_item_name(entry), entry.base_form_id, reference_text]
	return haystack.to_lower().contains(filter_text)


## The base's name, else its editor ID, else its FormID.
func _item_name(entry: InventoryItem) -> String:
	if entry.base == null:
		return "Item 0x%X" % entry.base_form_id
	var full := String(entry.base.full_name).strip_edges()
	if not full.is_empty():
		return full
	return String(entry.base.editor_id)


## A numeric field of the base (weight, value), or 0 when it has none.
func _base_number(base: EsmBase, field: String) -> float:
	if base == null or not field in base:
		return 0.0
	return float(base.get(field))


func _selected_entry() -> InventoryItem:
	var row := _tree.get_selected()
	if row == null:
		return null
	return row.get_metadata(0) as InventoryItem


## Adds one to the selected stack.
func _increment() -> void:
	var entry := _selected_entry()
	if entry == null or entry.item_reference != null:
		return
	entry.count += 1
	_actor().contents.inventory_changed.emit()


## Removes one from the selected entry; a held reference stays held by nothing
## and in no space.
func _delete_selected() -> void:
	var entry := _selected_entry()
	var actor := _actor()
	if entry == null or actor == null:
		return
	if entry.item_reference != null:
		entry.item_reference.holder_instance_id = &""
	actor.contents.remove_inventory_item(entry)


## Drops the whole selected entry in front of the actor.
func _drop_selected() -> void:
	var entry := _selected_entry()
	var actor := _actor()
	if entry == null or actor == null:
		return
	actor.drop_entry(entry)
