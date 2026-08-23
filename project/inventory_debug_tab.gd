extends Control

@onready var _list: ItemList = $Margin/VBox/ItemList
@onready var _status: Label = $Margin/VBox/Status
@onready var _inc: Button = $Margin/VBox/Buttons/Increment
@onready var _delete: Button = $Margin/VBox/Buttons/Delete
@onready var _drop: Button = $Margin/VBox/Buttons/Drop
var _game: Node3D
var _ids := PackedInt64Array()

func _ready() -> void:
	_game = get_tree().root.get_node_or_null("Game")
	_inc.pressed.connect(_increment)
	_delete.pressed.connect(_delete_selected)
	_drop.pressed.connect(_drop_selected)
	_refresh()

func _process(_delta: float) -> void:
	if is_visible_in_tree(): _refresh()

func _refresh() -> void:
	var selected := _list.get_selected_items()
	var selected_id := _ids[selected[0]] if not selected.is_empty() and selected[0] < _ids.size() else 0
	_list.clear(); _ids.clear()
	if _game == null: _status.text = "Game not found"; return
	for entry in _game.inventory.get_entries():
		var id := int(entry["base_form_id"])
		_ids.append(id)
		_list.add_item("%3d  %-36s  wt %5.2f  value %4d" % [entry["count"], entry.get("full_name", "(unnamed)"), entry.get("weight", 0.0), entry.get("value", 0)])
		if id == selected_id: _list.select(_ids.size() - 1)
	_status.text = "%d distinct item type(s)" % _ids.size()

func _selected_id() -> int:
	var selected := _list.get_selected_items()
	return int(_ids[selected[0]]) if not selected.is_empty() else 0
func _increment() -> void: _game.debug_add_inventory_item(_selected_id())
func _delete_selected() -> void: _game.inventory.remove_item(_selected_id())
func _drop_selected() -> void: _game.debug_drop_inventory_item(_selected_id())
