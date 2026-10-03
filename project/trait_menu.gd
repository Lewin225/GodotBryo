class_name TraitMenu
extends CanvasLayer

## Placeholder trait menu (ShowTraitMenu, menu 1084 Character Creation
## Traits): a note in place of the traits, with how many may be chosen (the
## game setting iTraitMenuMaxNumTraits, per the GECK wiki), and Done, which
## closes it. Sets
## nothing: traits are PERK records, not read yet. While open the game is in
## menu mode.

signal closed

@onready var _done: Button = $Root/Panel/Margin/VBox/Done
@onready var _note: Label = $Root/Panel/Margin/VBox/Note

func _ready() -> void:
	visible = false
	_done.pressed.connect(accept)

func open(_actor: ActorReference, _params: Dictionary = {}) -> void:
	_note.text = "<trait selection to go here: up to %d>" % max_traits()
	visible = true
	_done.grab_focus()
	ScriptServer.enter_menu(ScriptServer.MENU_TRAITS)

## iTraitMenuMaxNumTraits.
func max_traits() -> int:
	return int(EsmServer.get_game_setting("iTraitMenuMaxNumTraits"))

func accept() -> void:
	if not visible:
		return
	visible = false
	ScriptServer.exit_menu(ScriptServer.MENU_TRAITS)
	closed.emit()
