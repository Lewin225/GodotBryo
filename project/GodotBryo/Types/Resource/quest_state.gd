@tool
class_name QuestState
extends Resource

## The runtime state of one quest: what an EsmReference is to a placed base,
## this is to a QUST record, which has no placements. One canonical instance
## per quest, from EsmServer.get_quest_state().

## QUST FormID; persisted identity.
@export var quest_form_id: int = 0
## The QUST record. Resolved at runtime, not saved.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EsmBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var quest: EsmBase
## The quest script's variables (`QuestEditorID.var`), created by ScriptServer
## on first use. Null when the quest has no script or it has not been used.
@export var script_instance: ScriptInstance
## Current stage; 0 before any SetStage.
@export var stage: int = 0
## Stages set so far, as {stage: true}.
@export var stages_done: Dictionary = {}
