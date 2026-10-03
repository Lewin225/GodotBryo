class_name TagSkillsMenu
extends CanvasLayer

## Placeholder tag skills menu (SetTagSkills, menu 1048 CharGen, Skills
## page): the thirteen skills as checkboxes; Done, once exactly the asked-for
## number are chosen, closes it. Sets nothing: tag skills are not stored yet. While open
## the game is in menu mode.

signal closed

const SKILLS := [ActorValue.BARTER, ActorValue.ENERGY_WEAPONS, ActorValue.EXPLOSIVES,
		ActorValue.GUNS, ActorValue.LOCKPICK, ActorValue.MEDICINE, ActorValue.MELEE_WEAPONS,
		ActorValue.REPAIR, ActorValue.SCIENCE, ActorValue.SNEAK, ActorValue.SPEECH,
		ActorValue.SURVIVAL, ActorValue.UNARMED]

@onready var _skills: GridContainer = $Root/Panel/Margin/VBox/Skills
@onready var _remaining: Label = $Root/Panel/Margin/VBox/Remaining
@onready var _done: Button = $Root/Panel/Margin/VBox/Done

var _count := 3
var _boxes: Array[CheckBox] = []

func _ready() -> void:
	visible = false
	_done.pressed.connect(accept)
	for code: int in SKILLS:
		var box := CheckBox.new()
		box.text = ActorValue.NAMES[code]
		box.toggled.connect(func(_on: bool) -> void: _update_remaining())
		_skills.add_child(box)
		_boxes.append(box)

## Shows the menu with params {"count": skills to tag}.
func open(_actor: ActorReference, params: Dictionary = {}) -> void:
	_count = int(params.get("count", 3))
	for box in _boxes:
		box.set_pressed_no_signal(false)
	_update_remaining()
	visible = true
	_done.grab_focus()
	ScriptServer.enter_menu(ScriptServer.MENU_CHARGEN)

## The skills chosen, as actor value codes.
func chosen() -> Array[int]:
	var codes: Array[int] = []
	for i in _boxes.size():
		if _boxes[i].button_pressed:
			codes.append(SKILLS[i])
	return codes

## Closes; nothing while the wrong number is chosen.
func accept() -> void:
	if not visible or chosen().size() != _count:
		return
	visible = false
	ScriptServer.exit_menu(ScriptServer.MENU_CHARGEN)
	closed.emit()

## Ticks skill `index` (into SKILLS), for tests and tools.
func set_chosen(index: int, value: bool) -> void:
	_boxes[index].button_pressed = value

func _update_remaining() -> void:
	var left := _count - chosen().size()
	_remaining.text = "Tag %d more" % left if left >= 0 else "%d too many" % -left
	_done.disabled = left != 0
