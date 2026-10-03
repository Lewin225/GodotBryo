class_name RaceMenu
extends CanvasLayer

## Placeholder race menu (ShowRaceMenu, menu 1036): a FaceGen editor goes
## here; for now only the sex is chosen. Done or Escape closes it. While open
## the game is in menu mode, so MenuMode 1036 blocks run. The sex is set on the
## ACBS Female flag of the actor's NPC_, which is marked dirty.

signal closed

@onready var _male: Button = $Root/Panel/Margin/VBox/Sex/Male
@onready var _female: Button = $Root/Panel/Margin/VBox/Sex/Female
@onready var _done: Button = $Root/Panel/Margin/VBox/Done

var _actor: ActorReference = null

func _ready() -> void:
	visible = false
	_done.pressed.connect(accept)

## Shows the menu for `actor`, its current sex selected.
func open(actor: ActorReference) -> void:
	_actor = actor
	var female := actor != null and actor.base is NpcBase and (actor.base as NpcBase).is_female()
	_female.button_pressed = female
	_male.button_pressed = not female
	visible = true
	_done.grab_focus()
	ScriptServer.enter_menu(ScriptServer.MENU_RACE)

## Sets the chosen sex and closes.
func accept() -> void:
	if not visible:
		return
	if _actor != null and _actor.base is NpcBase:
		(_actor.base as NpcBase).set_female(_female.button_pressed)
	visible = false
	ScriptServer.exit_menu(ScriptServer.MENU_RACE)
	closed.emit()

func _unhandled_key_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		accept()
		get_viewport().set_input_as_handled()
