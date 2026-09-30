@tool
class_name CreatureBase
extends EsmBase
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_path: String = ""
@export var model_list_filenames: Array[String] = []
@export var model_list_paths: Array[String] = []
@export var animation_filenames: Array[String] = []
@export var animation_paths: Array[String] = []
@export var pnam_values: Array[int] = []
## ACBS, DATA and AIDT stats.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "ActorStats", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var actor_stats: ActorStats
## VTCK: the VTYP voice type FormID, on 1,045 of 1,578 CREA records in FalloutNV.esm;
## 0 when absent. Read, from this record; with the Traits template flag the
## template's is used (ActorStats.template_source). Used by GetIsVoiceType.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var voice_type_form_id: int = 0
## SNAM: the factions and the actor's rank in each, in authored order (14,625
## SNAM on NPC_ and CREA in FalloutNV.esm). Read, from this record; with the
## Factions template flag the template's are used. Used by GetInFaction and
## GetFactionRank; runtime changes (SetFactionRank, AddToFaction) are not
## implemented.
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "ActorFaction", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var factions: Array[ActorFaction] = []
