@tool
class_name TerminalMenuItem
extends Resource

## GodotBryo convenience resource for one embedded TERM menu-item group.
## This is not an ESM record type and has no FormID of its own. The item's
## position in TerminalBase.menu_items preserves its authored order.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var text: String = ""
## TERM menu-item RNAM result text.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var result_text: String = ""
## TERM menu-item ANAM flags.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var item_flags: int = 0
## TERM menu-item INAM Display Note FormID.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var display_note_form_id: int = 0
## TERM menu-item TNAM Sub Menu TERM FormID.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var submenu_terminal_form_id: int = 0
## CTDA conditions of this menu item (after its ITXT, in authored order).
## Read; TERM holds 405 in FalloutNV.esm. Used by TerminalSession, which hides
## an item whose conditions fail.
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "Condition", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var conditions: Array[Condition] = []
## Placeholder embedded menu-item script source; execution belongs to the script engine.
@export_multiline var script_source: String = ""
