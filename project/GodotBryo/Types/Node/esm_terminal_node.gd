@tool
@icon("res://GodotBryo/Types/Node/terminal.svg")
class_name EsmTerminalNode
extends EsmNode

## The menu is immutable Base data. TerminalSession remains the owner of UI
## and navigation state when the runtime interaction path is used.
var menu_items: Array[TerminalMenuItem] = []

func _on_reference_ready() -> void:
	var terminal_ref := reference as TerminalReference
	if terminal_ref == null or not terminal_ref.base is TerminalBase:
		return
	var base := terminal_ref.base as TerminalBase
	menu_items = base.menu_items.duplicate(true)
