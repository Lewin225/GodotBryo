@tool
class_name DoorBase
extends EsmBase

## DOOR Model Data model path.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_path: String = ""
## MODS: Alternate Textures for MODL. On 21 of 320 DOOR in FalloutNV.esm.
## Read; not used yet (NifServer would swap the named shapes' texture sets).
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "AlternateTextureCollection", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var alternate_textures: Array[AlternateTextureCollection] = []
## Resolved DOOR SNAM open sound path.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var open_sound_path: String = ""
## Resolved DOOR ANAM close sound path.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var close_sound_path: String = ""
## Resolved DOOR BNAM looping sound path.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var loop_sound_path: String = ""
## DOOR SNAM open sound FormID.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var open_sound_form_id: int = 0
## DOOR ANAM close sound FormID.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var close_sound_form_id: int = 0
## DOOR BNAM looping sound FormID.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var loop_sound_form_id: int = 0
## Raw DOOR FNAM flags.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var flags: int = 0
## DOOR FNAM automatic-door flag.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var is_automatic_door: bool = false
## DOOR FNAM hidden-door flag.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var is_hidden: bool = false
## DOOR FNAM minimal-use flag.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var is_minimal_use: bool = false
## DOOR FNAM sliding-door flag.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var is_sliding_door: bool = false

## A locked door opens for an activator carrying its key, and unlocks. Without
## the key a level-255 lock fails; any other level starts lockpicking, which is
## using the door. An unlocked door with XTEL moves the activator to the
## landing; one without toggles open and closed.
func activate(ref: EsmReference, activator: EsmReference) -> void:
	var door := ref as DoorReference
	if door == null:
		return
	if door.is_locked:
		if door.lock_key != null and carries(activator, door.lock_key.form_id):
			ScriptServer.unlock(door)
		elif door.lock_level >= 255:
			return
		else:
			ScriptServer.begin_use(activator, door)
			return
	if door.has_teleport:
		ScriptServer.move_reference(activator, door.get_teleport_destination_space_form_id(), door.teleport_position, door.teleport_rotation)
	else:
		door.is_open = not door.is_open
