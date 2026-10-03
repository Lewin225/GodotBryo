class_name SpecialMenu
extends CanvasLayer

## Placeholder vigor tester menu (ShowLoveTesterMenuParams, menu 1074): seven
## 1-10 values, starting at the actor's SPECIAL, and a points budget; Done,
## once every point is spent, sets each as the actor's base value (as SetAV
## does). While open the game is in menu mode. That the original requires
## every point spent before Done is not verified.

signal closed

const ATTRIBUTES := ["Strength", "Perception", "Endurance", "Charisma", "Intelligence", "Agility", "Luck"]

@onready var _rows: GridContainer = $Root/Panel/Margin/VBox/Rows
@onready var _remaining: Label = $Root/Panel/Margin/VBox/Remaining
@onready var _done: Button = $Root/Panel/Margin/VBox/Done

var _actor: ActorReference = null
var _points := 0
var _spins: Array[SpinBox] = []

func _ready() -> void:
	visible = false
	_done.pressed.connect(accept)
	for i in ATTRIBUTES.size():
		var label := Label.new()
		label.text = ATTRIBUTES[i]
		_rows.add_child(label)
		var spin := SpinBox.new()
		spin.min_value = 1
		spin.max_value = 10
		spin.value_changed.connect(func(_value: float) -> void: _update_remaining())
		_rows.add_child(spin)
		_spins.append(spin)

## Shows the menu for `actor` with params {"points": total to distribute}.
func open(actor: ActorReference, params: Dictionary = {}) -> void:
	_actor = actor
	_points = int(params.get("points", 40))
	var values := actor.get_actor_values() if actor != null else null
	for i in _spins.size():
		_spins[i].set_value_no_signal(values.get_base(ActorValue.STRENGTH + i) if values != null else 5.0)
	_update_remaining()
	visible = true
	_done.grab_focus()
	ScriptServer.enter_menu(ScriptServer.MENU_LOVE_TESTER)

## The points not yet spent.
func remaining() -> int:
	var spent := 0
	for spin in _spins:
		spent += int(spin.value)
	return _points - spent

## Sets the actor's SPECIAL and closes; nothing while points remain.
func accept() -> void:
	if not visible or remaining() != 0:
		return
	var values := _actor.get_actor_values() if _actor != null else null
	if values != null:
		for i in _spins.size():
			values.set_base(ActorValue.STRENGTH + i, _spins[i].value)
	visible = false
	ScriptServer.exit_menu(ScriptServer.MENU_LOVE_TESTER)
	closed.emit()

## Sets attribute `index` (0 Strength .. 6 Luck), for tests and tools.
func set_attribute(index: int, value: int) -> void:
	_spins[index].value = value

func _update_remaining() -> void:
	var left := remaining()
	_remaining.text = "Points left: %d" % left
	_done.disabled = left != 0
