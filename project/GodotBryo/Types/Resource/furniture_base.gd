@tool
class_name FurnitureBase
extends EsmBase
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_path: String = ""
## Placeholder SCPT FormID; resolve and attach through the script engine.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var script_form_id: int = 0
## FURN MNAM marker flags; individual marker meanings remain engine data.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var marker_flags: PackedByteArray = PackedByteArray()

## Indices of the markers this furniture enables: set bits 0-23 of FURN MNAM.
## Bits 24-31 are flags, not markers.
func get_active_markers() -> PackedInt32Array:
	var result := PackedInt32Array()
	if marker_flags.size() < 4:
		return result
	var bits := marker_flags.decode_u32(0) & 0x00FFFFFF
	for index in 24:
		if bits & (1 << index):
			result.append(index)
	return result

## Using furniture occupies one of its free active markers.
func activate(ref: EsmReference, activator: EsmReference) -> void:
	ScriptServer.begin_use(activator, ref)
