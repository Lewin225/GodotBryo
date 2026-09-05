class_name EsmRecordResource
extends Resource

## ESM identity and raw source data shared by every typed record resource.
## Unknown bytes stay available while individual subrecord meanings are
## verified against the shipped corpus.
@export var form_id: int = 0
@export var editor_id: String = ""
@export var record_type: String = ""
@export var source_uri: String = ""
var raw_subrecords: Array[Dictionary] = []
var diagnostics: PackedStringArray = []

func subrecord_data(tag: String) -> PackedByteArray:
	for subrecord in raw_subrecords:
		if String(subrecord.get("type", "")) == tag:
			return subrecord.get("data", PackedByteArray())
	return PackedByteArray()

func all_subrecord_data(tag: String) -> Array[PackedByteArray]:
	var result: Array[PackedByteArray] = []
	for subrecord in raw_subrecords:
		if String(subrecord.get("type", "")) == tag:
			result.append(subrecord.get("data", PackedByteArray()))
	return result
