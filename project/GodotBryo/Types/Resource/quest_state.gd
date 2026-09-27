@tool
class_name QuestState
extends Resource

## The runtime state of one quest: what an EsmReference is to a placed base,
## this is to a QUST record, which has no placements. One canonical instance
## per quest, from QuestServer.get_quest_state().

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
## Whether the quest is running: its script's GameMode block runs every
## script_delay seconds.
@export var running: bool = false
## Seconds between runs of the quest script; negative uses the QUST record's
## delay (or the engine default when that is 0). Set by SetQuestDelay.
@export var script_delay: float = -1.0
## Set when a stage whose log entry completes or fails the quest is reached.
@export var completed: bool = false
@export var failed: bool = false
## Objectives shown in the Pip-Boy, as {QOBJ index: true}. Only indexes the
## QUST defines; set and cleared by QuestServer (SetObjectiveDisplayed).
@export var objectives_displayed: Dictionary[int, bool] = {}
## Objectives completed, as {QOBJ index: true}. Only indexes the QUST defines;
## set and cleared by QuestServer (SetObjectiveCompleted). Independent of
## objectives_displayed.
@export var objectives_completed: Dictionary[int, bool] = {}
