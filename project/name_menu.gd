class_name NameMenu
extends CanvasLayer

## Placeholder name entry menu (GetPlayerName, menu 1051): type a name, OK or
## Enter to accept. While open the game is in menu mode. The name is the FULL
## of the actor's base record, which is marked dirty; an empty name changes
## nothing.

signal closed

@onready var _name: LineEdit = $Root/Panel/Margin/VBox/Name
@onready var _ok: Button = $Root/Panel/Margin/VBox/OK

var _actor: ActorReference = null

func _ready() -> void:
	visible = false
	_ok.pressed.connect(accept)
	_name.text_submitted.connect(func(_text: String) -> void: accept())

## Shows the menu for `actor`, its current name filled in.
func open(actor: ActorReference) -> void:
	_actor = actor
	_name.text = actor.base.full_name if actor != null and actor.base != null else ""
	visible = true
	_name.grab_focus()
	_name.select_all()
	ScriptServer.enter_menu(ScriptServer.MENU_TEXT_EDIT)

## Sets the typed name and closes.
func accept() -> void:
	if not visible:
		return
	var typed := _name.text.strip_edges()
	if _actor != null and _actor.base != null and not typed.is_empty():
		_actor.base.full_name = typed
		_actor.base.mark_dirty()
	visible = false
	ScriptServer.exit_menu(ScriptServer.MENU_TEXT_EDIT)
	closed.emit()
