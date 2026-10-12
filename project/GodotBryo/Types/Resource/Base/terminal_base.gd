@tool
class_name TerminalBase
extends EsmBase

## TERM Model Data model path.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_path: String = ""
## MODS: Alternate Textures for MODL. On 14 of 344 TERM in FalloutNV.esm.
## Read; not used yet (NifServer would swap the named shapes' texture sets).
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "AlternateTextureCollection", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var alternate_textures: Array[AlternateTextureCollection] = []
## TERM DESC welcome text.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var welcome_text: String = ""
## TERM SNAM looping sound FormID.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var looping_sound_form_id: int = 0
## Resolved TERM SNAM looping sound path.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var looping_sound_path: String = ""
## TERM PNAM password Note FormID. Password/hacking behavior is not yet wired.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var password_note_form_id: int = 0
## TERM DNAM raw flags.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var flags: int = 0
## TERM DNAM base hacking difficulty enum.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var hacking_difficulty: int = 0
## TERM DNAM server type enum.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var server_type: int = 0
## TERM DNAM leveled flag.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var is_leveled: bool = false
## TERM DNAM unlocked flag.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var is_unlocked: bool = false
## TERM DNAM alternate-colors flag.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var uses_alternate_colors: bool = false
## TERM DNAM hide-welcome-text flag.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var hides_welcome_text: bool = false
## Ordered embedded TERM menu items. TerminalMenuItemCollection is a GodotBryo
## convenience resource, not an ESM record type; linked Note/submenu FormIDs
## remain explicit fields on each item.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var menu_items: Array[TerminalMenuItemCollection] = []

## A locked terminal unlocks for an activator carrying its password note.
## Without it, a level-5 terminal does nothing; any other locked terminal is
## used for hacking. Otherwise the actor becomes the terminal's single user.
func activate(ref: EsmReference, activator: EsmReference) -> void:
	var terminal := ref as TerminalReference
	if terminal == null:
		return
	if terminal.is_locked:
		if carries(activator, password_note_form_id):
			ScriptServer.unlock(terminal)
		elif terminal.lock_level >= 5:
			return
	ScriptServer.begin_use(activator, terminal)
