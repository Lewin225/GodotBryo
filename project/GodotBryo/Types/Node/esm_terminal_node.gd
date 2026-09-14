@tool
@icon("res://GodotBryo/Types/Node/terminal.svg")
class_name EsmTerminalNode
extends EsmNode

@export_tool_button("Activate") var activate_button: Callable = activate

## The menu is immutable Base data. TerminalSession remains the owner of UI
## and navigation state when the runtime interaction path is used.
var menu_items: Array[TerminalMenuItem] = []

func _on_reference_ready() -> void:
	var terminal_ref := reference as TerminalReference
	if terminal_ref == null or not terminal_ref.base is TerminalBase:
		return
	var base := terminal_ref.base as TerminalBase
	menu_items = base.menu_items.duplicate(true)

## UI/session opening remains owned by Game. This hook provides the same
## activation contract as DoorNode while that session is being routed.
func activate(_actor: Node = null) -> Dictionary:
	return {"terminal": self, "menu_items": menu_items}
