@tool
class_name PackageEventCollection
extends Resource

## One of PACK's POBA (On Begin), POEA (On End) or POCA (On Change) event
## blocks: an idle, a topic and a result script. PackageRunner runs the script,
## then says the topic, then plays the idle, the order the GECK gives
## ("Category Packages", Begin/End/Change Tab).

## INAM: the IDLE played when the event fires. Read; resolved into `idle`.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var idle_form_id: int = 0
## INAM, resolved. Used by PackageRunner, which has ScriptServer's ActorIdles
## play it on the actor.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "IdleBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var idle: IdleBase
## TNAM: the topic said when the event fires. Read; resolved into `topic`.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var topic_form_id: int = 0
## TNAM, resolved. Used by PackageRunner: the actor says it (DialogueServer.say).
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "DialogueTopicBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var topic: DialogueTopicBase
## SCHR, raw. Read; not used (its fields are below).
var script_header: PackedByteArray = PackedByteArray()
## SCHR offset 4: the number of SCRO/SCRV references. Read; not used.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var script_reference_count: int = 0
## SCHR offset 8: the size of the compiled script (SCDA). Read; not used.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var compiled_script_size: int = 0
## SCHR offset 12: the number of local variables. Read; not used.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var script_variable_count: int = 0
## SCHR offset 16: the script type. Read; not used.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var script_type: int = 0
## SCHR offset 18: the script flags. Read; not used.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var script_flags: int = 0
## SCDA: the compiled script. Read; not used (ScriptServer runs the source).
var compiled_script: PackedByteArray = PackedByteArray()
## SCTX: the script's source. Read; used by PackageRunner, which runs it with
## the actor as subject (ScriptServer.run_result_script).
@export_multiline var script_source: String = ""
## SLSD, raw, one per local variable. Read; not used (see `local_variables`).
var local_variable_data: Array[PackedByteArray] = []
## SCVR, one per local variable. Read; not used (see `local_variables`).
var local_variable_names: PackedStringArray = []
## SLSD with its SCVR name, one per local variable. Read; not used: the
## interpreter declares locals from the source.
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "ScriptLocalCollection", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var local_variables: Array[ScriptLocalCollection] = []
## SCRO: the FormIDs the compiled script references. Read; not used: the
## interpreter resolves editor IDs in the source.
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "int", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var script_references: Array[int] = []
## SCRV: the local variables the compiled script references by index. Read;
## not used.
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "int", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var script_local_reference_indices: Array[int] = []
