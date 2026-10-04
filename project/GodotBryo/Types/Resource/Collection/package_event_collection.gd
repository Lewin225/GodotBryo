@tool
class_name PackageEventCollection
extends Resource

## One of PACK's POBA/POEA/POCA event blocks. The embedded script subrecords
## are kept verbatim here; script decoding/execution belongs to ScriptServer.
## INAM: the idle played when the event fires. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var idle_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "IdleBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var idle: IdleBase
## TNAM: the topic said when the event fires. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var topic_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "DialogueTopicBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var topic: DialogueTopicBase
var script_header: PackedByteArray = PackedByteArray()
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var script_reference_count: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var compiled_script_size: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var script_variable_count: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var script_type: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var script_flags: int = 0
var compiled_script: PackedByteArray = PackedByteArray()
@export_multiline var script_source: String = ""
var local_variable_data: Array[PackedByteArray] = []
var local_variable_names: PackedStringArray = []
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "ScriptLocalCollection", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var local_variables: Array[ScriptLocalCollection] = []
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "int", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var script_references: Array[int] = []
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "int", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var script_local_reference_indices: Array[int] = []
