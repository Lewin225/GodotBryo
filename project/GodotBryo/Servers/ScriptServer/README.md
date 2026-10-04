# ScriptServer

Runs GECK object scripts for references. Autoloaded singleton `ScriptServer`.

A reference's script is its base record's `SCRI` (`<type>_base.script_form_id`).
Its persistent state is the reference's `ScriptInstance` (`EsmReference.script_instance`):
the SCPT FormID and the locals, saved with the reference. Nothing per-reference is
kept in this server except which references are loaded.

---

## Contract

```gdscript
ScriptServer.activate(target, activator)                 # OnActivate block, or built-in
ScriptServer.default_activate(target, activator)         # built-in only, then node presents
ScriptServer.move_reference(reference, space_form_id, position, rotation)   # queued
ScriptServer.get_pending_move(reference) -> Dictionary
ScriptServer.apply_pending_moves()                       # also run every frame
ScriptServer.begin_use(actor, target, marker := -1) -> bool
ScriptServer.end_use(actor)
ScriptServer.lock(reference, level := -1)             # doors and terminals
ScriptServer.unlock(reference)
ScriptServer.run_result_script(source, subject, action_ref := null) -> Variant
ScriptServer.get_quest_instance(quest: EsmBase) -> ScriptInstance
ScriptServer.run_quest_block(quest: EsmBase, block_type) -> Variant
ScriptServer.dispatch_event(reference, block_type, action_ref := null) -> Variant
ScriptServer.has_block_for(reference, block_type, action_ref := null) -> bool
ScriptServer.get_script_instance(reference) -> ScriptInstance   # created on first use
ScriptServer.set_reference_loaded(reference, loaded: bool)
ScriptServer.is_reference_loaded(reference) -> bool
ScriptServer.run_debug_line(line, target: EsmReference = null) -> Dictionary
ScriptServer.get_debug_instances() -> Array
ScriptServer.get_debug_usage() -> Dictionary

ScriptServer.player_reference: EsmReference   # what `player` resolves to
ScriptServer.player_node: Node                # the player's body, for ToggleCollision
ScriptServer.message_box: MessageBox          # ShowMessage / GetButtonPressed
ScriptServer.function_registry: ScriptFunctionRegistry
```

**Moves.** `move_reference()` queues; a later move of the same reference replaces the
queued one. Each frame `_process()` runs loaded references' `GameMode` blocks, then
applies the queue: space, position and rotation are set together (one cell refresh) and
the reference's `teleported(old_space, new_space)` and
`reference_teleported(reference, old_space, new_space)` are emitted. `process_priority`
is 100, so this runs after default-priority `_process()`; physics bodies sync their
references in `_physics_process()`, earlier in the frame. Script `MoveTo Target [x y z]`
(offset in Gamebryo units, Target's rotation), `PositionCell x y z zRot CellID` and
`PositionWorld x y z zRot WorldspaceID` (Gamebryo units, degrees) all queue through
`move_reference()`.

**Blocks.** Event blocks (`OnActivate`, `OnTriggerEnter`, ...) run whenever
`dispatch_event()` is called, whether or not the reference is loaded. `GameMode` and
`MenuMode` run every frame only for references marked loaded with
`set_reference_loaded()`, which also runs `OnLoad` (once per load).
`dispatch_event_for(reference, block_type, subject)` runs blocks for a non-reference
subject: a menu ID, or a topic for `SayToDone <topic>`, matched by editor ID. `SayTo` and
`Say` speak through `DialogueServer.say()`; `StartConversation Player [Topic]` starts a
conversation (`DialogueServer.start_conversation`), and `AddTopic` adds a topic to the
player's list.

**Menu mode.** A menu opening calls `enter_menu(menu_id)` and closing calls
`exit_menu(menu_id)`; the game is in menu mode while any is open (the GECK's Begin page:
GameMode runs "while the game is in non-menu mode", MenuMode "while the game is in menu
mode"). Then loaded references run `MenuMode` blocks accepting the most recently opened
menu each frame instead of `GameMode`, quest scripts run `MenuMode` instead of `GameMode`,
and `DialogueServer` lines and voices pause. Menu IDs are the GECK's (`MenuMode
(Function)` in `enginedocs/Geck`): `MessageBox` modal dialogs are 1001, conversations 1009
(Dialog), `UnlockSession` 1014 (LockPick) or 1055 (Hacking), the race menu 1036, the name
menu 1051 (TextEdit), `TerminalSession` 1057 (Computers), and the Debug Tools panel 3 (the
console). The player's controller frees the mouse in menu mode and captures it otherwise;
no screen sets the mouse mode itself.
`open_menu(menu_id)` is how a script opens one (`GetPlayerName`/`ShowNameMenu` 1051,
`ShowRaceMenu` 1036, `ShowLoveTesterMenuParams` 1074 with its points): the player's
controller (`menu_opener`) shows `NameMenu`, `RaceMenu`, `SpecialMenu` (the vigor
tester, which sets the SPECIAL as base actor values once every point is spent),
`TagSkillsMenu` (`SetTagSkills total`, CharGen 1048) or `TraitMenu` (`ShowTraitMenu`,
1084, up to `iTraitMenuMaxNumTraits`); the last two are placeholders that set nothing, as
tag skills and traits are not stored yet; with no UI (headless) the menu opens and closes at once, running the
`MenuMode` blocks that accept it once. The `MenuMode [type]` function is 1 for any open
menu, a specific open menu, or group 2 (any menu but the "main four", none of which exist
yet); group 1 is always 0. `SexChange` sets the ACBS Female flag of the actor's NPC_.

**Player controls.** `DisablePlayerControls` / `EnablePlayerControls [Movement Pipboy
Fighting POV Looking RolloverText Sneaking]` (each 0/1; Disable with none is `1 1 1 1 0 0 0`
per the GECK wiki, Enable with none enables all, not verified) set
`disabled_player_controls`, the player's (not any actor's) disabled controls, and emit
`player_controls_changed`. The player's controller ignores movement input and activation
while Movement is disabled and mouse look while Looking is; the crosshair drops its prompt
while Rollover Text is. Pip-Boy, Fighting, POV and Sneaking are recorded with no system
reading them yet.
`CellStreamerV2` marks its current CELL's references loaded; `WorldStreamerV2`
marks those of resident tiles at full detail, and unloads them when a tile drops to
LOD, is removed, or is paused for an interior visit. References moving between
CELLs are unloaded by the streamer they left and loaded (deferred to the end of the
frame) by the one they entered. A block with a parameter
(`Begin OnActivate Player`) runs only when the parameter names the dispatch's action
reference; a block without one always runs.

**Activation.** `activate()` runs the target's `OnActivate` block that accepts the
activator; with none, it performs the built-in activation, as if the block were
`Begin OnActivate / Activate / End`. The built-in activation is
`EsmReference.default_activate()`, which calls the base type's `activate(ref,
activator)`: doors unlock with their key, start lockpicking, move the activator
through XTEL or toggle open; terminals, containers and furniture start being used.
The target's loaded node then plays it (`EsmNode.on_activated()`). Script `Activate`
performs the built-in activation, or runs `OnActivate` when its second argument is 1;
its activator is the first argument, or the dispatch's action reference.

**Inventory, identity, location.** `GetItemCount`, `AddItem`, `RemoveItem`, `RemoveAllItems`,
`EquipItem`, `UnequipItem` and `GetEquipped` act on the calling reference's `contents`
(actors, creatures, containers), naming items by base editor ID; `AddItem` goes through
`EsmServer.add_inventory_items()`, which builds typed item references and resolves leveled
lists. `GetIsID`, `GetIsReference`, `GetInCell`, `GetInWorldspace`, `GetInSameCell` and
`GetDistance` (Gamebryo units) read the reference's base, cell, space and position.
`GetLocked`, `GetOpenState` and `SetOpenState` read and set `is_locked` / `is_open`;
`SetOpenState` lets a loaded door play the change. `MarkForDelete` sets
`EsmReference.marked_for_delete`, which the streamers do not spawn again.

**Conditions.** `evaluate_conditions(conditions, context)` evaluates a list of CTDA
`ConditionSubrecord`s through `ConditionEvaluator`, stateless. Each condition calls its function (by
CTDA index, `ScriptConditionFunctions`) on the reference its Run On names from the
`ConditionContext` (subject, target, the linked reference of `linked_from`, or a named
reference, 0x14 being the player), with its parameters resolved, and compares the result with
its value or its GLOB's current value. Or'd conditions group with the next; every group must
pass. A missing Reference, Linked Reference or Combat Target makes a condition false; a missing
subject or target runs the function with no calling reference. Unimplemented functions read 0,
warned once per function per owner. `GetQuestVariable` and `GetScriptVariable` take a variable
as an SLSD index (`script_variable_name()`), as conditions store it, or by name.

**Triggers.** A placed reference with an XPRM primitive gets an `EsmPrimitiveVolume`
(Area3D) when loaded, whatever its base or script. When its base has a script, the volume
dispatches `OnTriggerEnter` and `OnTriggerLeave` once per actor and `OnTrigger` every
physics frame an actor is inside, with that actor's reference as the action ref (so
`Begin OnTriggerEnter Player` and `IsActionRef player` work). The player's body stands for
the possessed reference; other bodies for their EsmNode's actor reference. Bodies that are
not actors are ignored.

**Result scripts.** `run_result_script()` runs a bare statement list with no
Begin/End (terminal menu items; later dialogue and packages). `subject` is the implicit
reference of its calls, `action_ref` the activator. It has its own locals, declared in
its source and fresh on every run.

**Locks.** A door with XLOC, or a terminal whose base is not flagged unlocked, starts
locked. Activating one with its key (door) or password note (terminal) unlocks it;
level 255 (door) or 5 (terminal) without it does nothing; otherwise the activator starts
using it — lockpicking or hacking.

**Use.** `begin_use()` / `end_use()` set `ActorReference.using` / `using_marker` and
the target's side together: `used_by` for single-user references, one
`FurnitureReference.occupants` slot per active MNAM marker for furniture.
`ActorReference.using_changed` reports both. Use state is runtime only.

**Contexts.** `ScriptExecutionContext` is built per dispatch: calling reference, action
reference, the player's reference, and the calling reference's `ScriptInstance`. Script
values are int, float or `EsmReference`; a `ref` local is stored in the instance as
`{"ref": instance_id}` and read back as the reference.

**Names.** `player` resolves to `player_reference`; any other name that is a placed
reference's editor ID resolves to that reference (`EsmServer.find_reference_by_editor_id`),
loaded or not. Other names stay as text for functions that take editor IDs of other record
types (ShowMessage's MESG). `SomeREF.var` reads and writes a variable of that reference's
own `ScriptInstance`.

**Quests.** Quest state and stages belong to `QuestServer`. Here: `QuestEditorID.var`
reads and writes the quest script's variables (its `QuestState.script_instance`, created
on first use by `get_quest_instance()`), and `run_quest_block()` runs a quest script's
block with those variables and no calling reference. A name prefix resolves as a
reference first, then as a quest. `SetObjectiveDisplayed Quest Index Flag` and
`SetObjectiveCompleted Quest Index Flag` set the objective's state when Flag is nonzero and
clear it when 0; without Flag they change nothing and warn. `GetObjectiveDisplayed Quest
Index` and `GetObjectiveCompleted Quest Index` return 1 or 0. Both go through
`QuestServer`, which refuses an index the quest does not define.

**Message boxes.** `ShowMessage` records the calling reference; `GetButtonPressed`
returns the clicked button to that reference only, once, and -1 to every other
reference. Many loaded scripts poll `GetButtonPressed` every frame.

**Return.** `Return` ends the run: no later statement of the block, and no later block of
the same type, runs.

**Elapsed time.** `GetSecondsPassed` returns the seconds of `ScriptServer.clock` since
the calling script last ran (0 on its first run), tracked per `ScriptInstance` in the
runtime-only `last_run_time`. `clock` is frame time (not timescaled game time), advanced
by `_process(delta)`, so a test can step it. Every run through `dispatch_event` or
`run_quest_block` restarts that script's clock; result scripts and console lines get 0 and
restart nothing.

**Actor values.** `GetActorValue`/`GetAV`, `GetBaseActorValue`/`GetBaseAV`,
`GetPermanentActorValue`/`GetPermAV`, `SetActorValue`/`SetAV`, `ModActorValue`/`ModAV`,
`ForceActorValue`/`ForceAV`, `DamageActorValue`/`DamageAV`, `RestoreActorValue`/`RestoreAV`,
`GetHealthPercentage` and `GetLevel` act on the calling reference's `ActorValues`
(`EsmReference.get_actor_values()`, null for non-actors, which read 0). The actor value is
named by its script name, case-insensitive (`ActorValue.from_name`). Current = base +
permanent + damage: SetAV replaces the base, ModAV adds to the permanent modifier, ForceAV
is ModAV by (value − current), DamageAV and RestoreAV move the damage modifier, which stays
≤ 0. `GetHealthPercentage` is current Health / base Health, 1.0 when base Health is 0.
Base values derive from the base record's `ActorStats`, following NPC_/CREA templates
that supply stats.

**Enable state.** `Enable` / `Disable` set the reference's state
(`EsmReference.set_disabled`), loaded or not, and mark it dirty; `GetDisabled` reads
`is_disabled()`. A placement starts as its header flag 0x800 (Initially Disabled) says. A
reference with an XESP enable parent always has its parent's state (inverted with
Opposite of Parent), and `Enable` / `Disable` on it do nothing, per the GECK. A disabled
NPC's or creature's script does not run (`dispatch_event` / `has_block_for` skip it);
other disabled references' scripts do. `EsmNode` hides a disabled reference and turns its
collision off, following `enable_state_changed` on the reference and its enable parents
while it is in the tree. The fade argument (`Enable 1`) is ignored.

**Texture swaps.** `SwapTexture Ref "Block" "path"` (always this form in FalloutNV.esm:
242 calls, the Rorschach card, the ending slides and Euclid's C-Finder screen) records
`Block -> path` on the reference (`EsmReference.swap_texture`, `texture_swaps`), loaded
or not. `EsmNode` gives the meshes of the NIF block with that authored name
(case-insensitive) `textures\<path>.dds` as their albedo, through a per-node copy of each
material, when its visual loads and on each later swap. Swaps are not saved: per the GECK
wiki, loading a save reverts them.

**Handlers.** World-facing commands delegate to callables on `function_registry` set by
the scene that owns the loaders: `place_at_me_handler(args, calling_reference)`,
`center_on_cell_handler(args)`, plus `game_time_manager` for time functions.

---

## Known gaps

- **A call inside an expression takes its argument count from a table.** Every FNV condition
  function is covered (`ScriptConditionFunctions.ARITIES`, 338 entries from xEdit), plus
  `ScriptParser.KNOWN_ARITIES` for non-condition functions and aliases. A function in
  neither table consumes no arguments inside an expression, and its arguments are parsed as
  whatever follows. Trailing arguments may be omitted (`HasPerk` with one argument, the
  optional three of `PlaceAtMe`), so argument collection also stops at an operator.
- **Mismatched `if` structure is resolved by guesswork.** About 40 shipped scripts have a
  stray `endif`, `elseif` or `else` (79 in all), e.g. VCassTimerRegionBarkScript's inner
  `If … Else` is never closed before the outer `ElseIf`. The parser skips each stray
  keyword with a warning naming the script and line. What the original compiler did with
  them is only recorded in the compiled SCDA, which is not decoded.

## Unverified behaviour

What the code assumes where the original game's behaviour has not been checked in play.
Each is a reason to test before building on it.

| Assumption | Code | Source | How to check |
|---|---|---|---|
| `Activate`'s `RunOnActivateBlockFlag` defaults to 0 = built-in activation; 1 runs the target's `OnActivate` | registry `Activate` | GECK wiki, recalled | scripted door + console `SomeDoorREF.Activate player` with and without `1` |
| Code after `player.MoveTo` to another CELL still runs that frame | `move_reference` never interrupts the caller | GECK wiki recalls the rest of the script stops | a script that sets a variable after `player.MoveTo` |
| `GetPos` right after `MoveTo` in the same script returns the old position | moves are queued and applied after `GameMode` | follows from deferred moves | `GetPos` is not implemented yet |
| `GetSecondsPassed` counts frame time, not game time (timescale), per calling script | `ScriptServer._start_run` (`clock`) | GECK wiki, recalled | a quest script counting down 10 s with `GetSecondsPassed` at timescale 30 |
| Derived base values other than human Health: creature Health (DATA health alone), action points, carry weight, crit chance, heal rate, melee/unarmed damage, poison/rad resist | `ActorValue.derive_base` | GMST names and GECK defaults; the way they combine is inferred | console `GetBaseAV` for each on Doc Mitchell and Rex |
| Human Health = base health + EnduranceMult × (Endurance + EnduranceOffset) + LevelMult × (level − 1), with `fAVDHealth*` for the player and `fAVDNPCHealth*` for NPCs | `ActorValue._health` | Nexus Mods forum, "Equal base health for all humans" (forums.nexusmods.com/topic/7329951); Fallout wiki for the player; the level-1 player's 200 at Endurance 5 confirmed in the original | console `GetBaseAV Health` on Doc Mitchell (expects 65) |
| Creature skill actor values (Barter–Unarmed) are 0; CREA DATA's combat/magic/stealth skills are not mapped onto them | `ActorValue.derive_base` | no source | console `GetAV Guns` on a creature |
| Templates from a leveled list (LVLN/LVLC: 587 NPC_, 429 CREA with Use Stats) fall back to the record's own stats | `ActorValues.get_stats` | leveled template resolution not implemented | an NPC_ templated from an LVLN, e.g. a generic Powder Ganger |
| `CompleteQuest` and `FailQuest` do not stop the quest or its script | `QuestServer.complete_quest` / `fail_quest` | conservative default; no source | a running quest's script counter after console `CompleteQuest` |
| `ResetQuest` clears stage, stages done, objectives, completion and script variables, and leaves the quest running | `QuestServer.reset_quest` | inferred from the name; no source | console `ResetQuest` on a quest with a set stage and a script variable, then `GetStage` and `ShowQuestVars` |
| `CompleteAllObjectives` completes only; it does not display objectives | `QuestServer.complete_all_objectives` | conservative default, like `SetObjectiveCompleted` | Pip-Boy after console `CompleteAllObjectives` on a quest with hidden objectives |
| Record header flag 0x400 on item records is the Quest Item flag | `EsmBase.RECORD_FLAG_QUEST_ITEM` | xEdit; the three Van Graff items scripts clear with `SetQuestObject ... 0` all carry it | whether a flagged item can be dropped in the original |
| XPRM bounds are half-extents (a sphere's radius in X) | `EsmPrimitiveVolume.configure` | xEdit displays them doubled | the vigor tester trigger (REFR 00104C16, 3.1 x 1.3 x 1.4 m half-extents) against where stage 60 fires in the original |
| Only actors fire triggers, not items or other physics objects | `EsmPrimitiveVolume.actor_reference_for` | no source | a trigger script with an OnTriggerEnter block and a dropped item |
| `OnTrigger` runs every physics frame while an actor is inside | `EsmPrimitiveVolume._physics_process` | GECK wiki, recalled | a trigger script counting OnTrigger runs |
| `EquipItem` adds the item when the actor has none | registry `EquipItem` | GECK wiki, recalled | console `EquipItem` of an item an NPC does not carry |
| `RemoveAllItems` removes (or moves) every item, quest items and equipped items included | registry `RemoveAllItems` | no source | an NPC with a quest item after `RemoveAllItems` |
| `AddItem` of a leveled list resolves it once per count, at the owner's level | `EsmServer.add_inventory_items` | no source | console `AddItem` of a leveled list with count 5 |
| `GetOpenState` is 1 open, 2 opening, 3 closed, 4 closing; opening and closing are never reported | registry `GetOpenState` | GECK wiki, recalled; shipped scripts test `== 1 \|\| == 2` | `GetOpenState` while a door animates |
| `GetDistance` across spaces returns a very large number (1e10 here) | registry `DISTANCE_OTHER_SPACE` | no source | console `GetDistance` to a reference in another cell |
| `MarkForDelete` removes the reference only once its CELL unloads | `EsmReference.marked_for_delete`, streamer `_should_spawn` | GECK wiki, recalled | a `MarkForDelete` script on a placed reference, then leave and return |
| Or'd conditions group with the next unflagged one, `(a OR b) AND c` | `ConditionEvaluator.evaluate` | recalled; the data cannot show it | a dialogue line whose conditions mix Or and And, in the original |
| Activators have an open state (`GetOpenState`/`SetOpenState`), like doors and containers | `ActivatorReference.is_open` | shipped data: V19OverseerWallTerminal's items test `GetOpenState` on a linked ACTI; GECK, recalled | `GetOpenState` on an animated activator after opening it |
| Completing an objective does not display it, and hiding one does not uncomplete it; the two flags are independent | `QuestServer.set_objective_completed` / `set_objective_displayed` | conservative default; no source | console `SetObjectiveCompleted VMQ01 10 1` on a new game, then check the Pip-Boy and `GetObjectiveDisplayed VMQ01 10` |
| `SetObjective*` without a flag changes nothing | registry `_change_objective` | conservative default; every one of 4785 shipped calls passes a flag | console `SetObjectiveDisplayed VMQ01 10` on a new game |
| A flag other than 0 or 1 sets (one shipped call: `SetObjectiveDisplayed VMQHouse4 50 2`) | registry `_change_objective` | treated as nonzero = set; no source | console `SetObjectiveDisplayed VMQ01 10 2`, then `GetObjectiveDisplayed VMQ01 10` |
| An objective index the QUST does not define reads 0 and cannot be set (62 shipped calls name one) | `QuestServer._objective_state` | conservative default; the original may keep state for any index | console `SetObjectiveCompleted VMQ01 15 1`, then `GetObjectiveCompleted VMQ01 15` |
| Setting or completing an objective does not depend on the quest running or its stage | `QuestServer.set_objective_*` | no check in scripts suggests otherwise; not verified | console `SetObjectiveDisplayed` on a quest that is not running, then the Pip-Boy |
| Owners (NPC or faction) do not pass their own locked doors without the key | `DoorBase.activate` | conservative default; `Lock`'s `AsOwner` parameter (GECK wiki) may decide it | an owner NPC following through a door locked with `lock 50 0` and `lock 50 1` |

## Files

| File | Role |
|---|---|
| `script_server.gd` | the autoload |
| `script_lexer.gd`, `script_parser.gd` | SCTX source → AST |
| `script_interpreter.gd` | tree-walking interpreter, one per parsed SCPT, cached |
| `script_function_registry.gd` | script function table |
| `script_execution_context.gd` | per-dispatch state |

## Tests

`tests/test_script_lexer`, `test_script_parser`, `test_script_interpreter`,
`test_script_showmessage`, `test_script_esm`, `test_debug_tabs`, run against the shipped
ESM:

```
cd project
../tools/Godot_v4.7.1-stable_linux.x86_64 --headless --path . tests/test_script_interpreter.tscn
```
