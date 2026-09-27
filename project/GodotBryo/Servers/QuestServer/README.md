# QuestServer

Owns quests. Autoloaded singleton `QuestServer`.

Quests are world state, shared by every actor and every player: many are global variable
containers that object and NPC scripts read and write (`VNPCFollowers.bBooneHired`,
`VMQHouse1.bOnLoungeFloor`). Their runtime state therefore lives here, one `QuestState` per
QUST, not on any actor.

---

## Contract

```gdscript
QuestServer.begin_game()                            # start the start-enabled quests
QuestServer.get_quest_state(quest) -> QuestState     # one per QUST, created on first use
QuestServer.start_quest(quest) / stop_quest(quest) / is_running(quest) -> bool
QuestServer.is_completed(quest) -> bool
QuestServer.complete_quest(quest) / fail_quest(quest)            # running is unchanged
QuestServer.reset_quest(quest)                                    # clears stages, objectives, completion, variables
QuestServer.complete_all_objectives(quest)
QuestServer.active_quest: QuestBase                               # the player's selected quest; active_quest_changed
QuestServer.is_quest_object(item) -> bool / set_quest_object(item, is_quest_item)
QuestServer.get_script_delay(quest) -> float
QuestServer.set_script_delay(quest, seconds)
QuestServer.get_stage(quest) -> int
QuestServer.set_stage(quest, stage)
QuestServer.is_stage_done(quest, stage) -> bool
QuestServer.is_objective_displayed(quest, index) -> bool
QuestServer.is_objective_completed(quest, index) -> bool
QuestServer.set_objective_displayed(quest, index, displayed) -> bool   # false: undefined index
QuestServer.set_objective_completed(quest, index, completed) -> bool   # false: undefined index
```

`quest` is the QUST record, `QuestBase` (`EsmServer.find_quest_by_editor_id`).

**Active quest.** `active_quest` is the quest the player has selected, as the Pip-Boy's
active quest; no shipped script sets it. Assigning it emits `active_quest_changed`.

**Quest items.** `is_quest_object()` reports an item base's quest-item state: what
`SetQuestObject` last set, else its record header flag 0x400 (`EsmBase.RECORD_FLAG_QUEST_ITEM`,
on 252 item bases in FalloutNV.esm). Neither this nor `active_quest` is saved yet.

**State.** `QuestState` holds the quest's script variables (`script_instance`, created by
`ScriptServer` on first use), `stage`, `stages_done`, `running`, a `script_delay`
override, `completed` / `failed`, and `objectives_displayed` / `objectives_completed`
(`{QOBJ index: true}`). It is the quest's equivalent of an `EsmReference`
and is what a save stores for quests.

**Running quests.** `begin_game()` starts every quest whose DATA flags mark it start
game enabled (281 in FalloutNV.esm); `game.gd` calls it at startup. Each running quest's
script `GameMode` block runs every `get_script_delay()` seconds: the `SetQuestDelay`
override, else the QUST DATA delay, else `DEFAULT_SCRIPT_DELAY` (5 s) when that is 0.

**Stages.** `set_stage()` records the stage, marks it done and runs the result script of
the stage's first log entry without conditions. Conditions are not evaluated (20 of 969
log entries have them), so a stage whose entries all have conditions runs none. A log
entry flagged complete or fail marks the quest so.

**Objectives.** The authored objectives are `QuestBase.objectives` (`QuestObjective`: QOBJ
index, NNAM text, QSTA targets). An objective's state is two independent flags on the
`QuestState`, displayed and completed, set and cleared only through the methods above:
completing does not display, and hiding does not uncomplete. An index the QUST does not
define is refused: the getters return false, the setters return false and record nothing,
and the first call per quest and index warns. 62 calls in shipped scripts name such an
index (e.g. `SetObjectiveCompleted VMQ01 15` in an INFO). Targets and their conditions
are parsed but not used.

**Scripts** reach this through `GetStage`, `GetStageDone`, `SetStage`, `StartQuest`,
`StopQuest`, `GetQuestRunning`, `GetQuestCompleted`, `SetQuestDelay`, `SetObjectiveDisplayed`,
`SetObjectiveCompleted`, `GetObjectiveDisplayed` and `GetObjectiveCompleted`, and `QuestEditorID.var` for variables.

## Not yet

- The journal / Pip-Boy view; objective targets as compass and map markers; target
  conditions (CTDA on QSTA) are counted, not evaluated.
- Quest log entry conditions; quest-level conditions.
- The 5 s default delay is the engine's recalled default, not verified in play.
- Saving and loading quest state.

## Tests

`tests/test_quest_server.tscn`.
