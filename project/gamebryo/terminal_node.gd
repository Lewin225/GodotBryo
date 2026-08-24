class_name TerminalNode
extends GamebryoVisual

## TERM. This node owns immutable, base-record menu data only.  A terminal
## browsing session belongs to Game (the player/UI owner), never a placed
## reference, so two copies of the same TERM cannot accidentally carry two
## independent menus or input states.

var terminal_data: Dictionary = {}

func configure_terminal(data: Dictionary) -> void:
	terminal_data = data.duplicate(true)
