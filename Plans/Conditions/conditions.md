# Conditions (CTDA)

**Status: stages A and B done; stage C next.**

Parse every CTDA into one shared typed resource on the record that owns it, and evaluate
condition lists at runtime through the same function registry scripts use. First consumers:
quest stage log entries and terminal menu items; dialogue (INFO) builds on this.

## Facts

FalloutNV.esm census (`native/tools/ctda_record_census.cpp`): 68,005 CTDAs on 12 record types.

| Type | Records with CTDA | CTDAs | Decides |
|---|---|---|---|
| INFO | 22,471 of 23,247 | 59,664 | which dialogue response is said |
| PACK | 1,814 of 4,163 | 2,992 | which AI package runs |
| IDLE | 1,098 of 1,597 | 1,798 | which idle animation plays |
| QUST | 172 of 436 | 1,501 | stage log entries, objective targets, quest conditions |
| CPTH | 328 of 418 | 593 | which camera path is used |
| TERM | 75 of 344 | 405 | which terminal menu items show |
| ALCH | 147 of 189 | 341 | per-effect conditions |
| PERK | 103 of 176 | 260 | when perk effects apply |
| MESG | 70 of 1,144 | 259 | which message box buttons show |
| SPEL | 42 of 270 | 84 | per-effect conditions |
| RCPE | 25 of 105 | 26 | recipe availability |
| ENCH | 19 of 145 | 82 | per-effect conditions |

Sizes: 28 bytes x67,880, 20 bytes x123, 24 bytes x2.

Layout (xEdit `wbConditions`, `enginedocs/xEdit/Core/wbDefinitionsFNV.pas`):

| Offset | Field | |
|---|---|---|
| 0 | Type (u8) | comparison operator and flags; see below |
| 1 | unused (3) | |
| 4 | Comparison value | float, or a GLOB FormID when the type's Use Global flag is set |
| 8 | Function (u16) | condition function index (the xEdit `wbConditionFunctions` table) |
| 10 | unused (2) | |
| 12 | Parameter 1 (u32) | int or FormID, by the function's first parameter type |
| 16 | Parameter 2 (u32) | int or FormID, by the function's second parameter type |
| 20 | Run On (u32) | 0 Subject, 1 Target, 2 Reference, 3 Combat Target, 4 Linked Reference; on IDLE records an animation group instead |
| 24 | Reference (FormID) | the reference for Run On = Reference |

Fields from offset 20 are optional (xEdit `SetOptionalFrom(7)`); the 20- and 24-byte forms lack
them.

**Stage A results** (`native/tools/ctda_layout_census.cpp`):

- Type byte: the top three bits are the comparison operator, 0 `==` (57,475), 1 `!=` (3,108),
  2 `>` (841), 3 `>=` (3,365), 4 `<` (2,369), 5 `<=` (847); 6 and 7 never occur. Low bits are
  flags: 0x01 Or (2,898), 0x04 Use Global (59), 0x02 never set, 0x10 once (meaning unknown). The
  operator names are recalled, the ordering matches xEdit's usual `==, !=, >, >=, <, <=`.
- Use Global: all 59 flagged conditions have a GLOB FormID as comparison word; no unflagged
  condition does.
- Run On (28-byte forms): Subject 62,811, Target 2,941, Reference 1,927, Combat Target 66 (all
  INFO), Linked Reference 130 (TERM 115, PACK 15). On IDLE the field holds animation groups
  (1, 7, 20).
- Reference: set on 1,923 of the 1,927 Run On = Reference conditions, and on 179 others, where it
  is ignored. Targets: ACHR 537, ACRE 166, REFR 101, and 0x14 1,298. 0x14 is the player's
  reference, which has no record in the ESM.
- Short forms: 20 bytes x123 (IDLE 98, PACK 24 on function 18, QUST 1 on function 427), 24 bytes
  x2 (IDLE). They have no Run On; they run on the subject.
- Or: 27,582 condition lists (maximal runs of consecutive CTDAs); 1,471 contain an Or flag and
  422 end with one, where no following condition exists to group with.
- Functions: 144 distinct indices, all present in xEdit's table. 27,733 CTDAs (40.8%) use a
  function the registry implements. Most used unimplemented: GetIsVoiceType 16,982,
  GetQuestVariable 9,444, GetInFaction 3,535, GetGlobalValue 2,844, GetReputationThreshold
  1,598, GetScriptVariable 830, GetDead 521, GetIsSex 410, GetDeadCount 391, HasPerk 306.

Existing code: `PackageCondition` (`project/GodotBryo/Types/Resource/package_condition.gd`)
already parses PACK CTDAs with raw fields. `QuestLogEntry` and `QuestObjectiveTarget` keep only
`condition_count`. `TerminalMenuItem` holds its conditions' count, and `TerminalSession` shows
conditioned items as "[conditions not evaluated]". `QuestServer.set_stage()` runs the first log
entry without conditions.

## Design

**Authored: one `Condition` resource.** `PackageCondition` becomes `Condition`, shared by every
record type. Fields: comparison operator, flags (or, use global), comparison value or GLOB
FormID, function index, the two raw parameters, run-on, reference FormID, and whether the
optional fields were present. Every field is described per AGENTS.md "Describing record
fields". One EsmServer parser, `_condition(data)`, builds it; owners hold
`conditions: Array[Condition]` in authored order. `condition_count` fields are replaced by
`conditions.size()`. `PackageCondition` fields are editor-only and never stored, so renaming it
touches no saved data.

**Function table by index.** `ScriptConditionFunctions` gains the xEdit index for each function
and its parameter types, regenerated from `wbConditionFunctions`: index -> (name, parameter
types). The evaluator calls the registry function of that name, so a function implemented for
scripts is implemented for conditions.

**Parameters.** A FormID parameter becomes the resource a script call would pass: a reference
(`EsmServer.get_reference("authored:%08X")`) for reference/actor types, else the base
(`get_base`), e.g. a QuestBase for a quest parameter. Registry argument helpers (`_base_arg`,
`_quest`) accept a resolved resource as well as an editor ID name. Integer parameters pass as
ints.

**Runtime: `ConditionEvaluator`, stateless.** Lives with ScriptServer. It evaluates a
condition list against a context and stores nothing: conditions only read world state.

```gdscript
ConditionEvaluator.evaluate(conditions: Array[Condition], context: ConditionContext) -> bool
```

`ConditionContext` holds `subject` (the speaker, package owner, terminal user), `target` (who
the subject addresses or acts on) and the owning record. Run On picks the reference the
function is called on: Subject, Target, the condition's Reference, Combat Target and Linked
Reference (a condition on a null reference is false). Combat Target is null until combat
exists. Linked Reference is the reference's XLKR, which stage B parses onto EsmReference: 115
TERM conditions depend on it. Of the 16 TERM records with linked-reference conditions, 4 are placed, all with
an XLKR (`native/tools/terminal_link_census.cpp`); the rest are submenus, whose conditions run on
the placed terminal's linked reference. A Reference of 0x14 is the player's reference
(`ScriptServer.player_reference`). Short-form conditions run on the subject. A trailing Or
flag is ignored. The function result is compared with the comparison value, or the GLOB's current value
from `ScriptServer.globals`.

**Combining.** Recalled, to be verified: consecutive conditions flagged Or form a group with the
next unflagged condition; the list passes when every group has at least one true condition,
i.e. `(a OR b) AND c`. Recorded as unverified until checked against real data (stage A:
lists whose Or flags make the grouping observable) or the original.

**Unimplemented functions** evaluate to 0, as they do in scripts, with the existing
once-per-function warning naming the condition's owner. The coverage report (stage F) ranks
them by use.

## Stages

Each stage has a gate; a later stage does not start on an unmet gate.

| Stage | Work | Gate |
|---|---|---|
| A. Census | Every CTDA in FalloutNV.esm: type byte distribution split into operator and flags; Use Global against a GLOB comparison FormID; Run On and Reference use per record type; the 20- and 24-byte cases; function indices used, with counts and whether each has a registry function; Or runs and group shapes. | All 67,985 accounted for; the type byte encoding confirmed or corrected in this plan. |
| B. Resource and parser | `Condition` replaces `PackageCondition`; `_condition()` parser; REFR XLKR (linked reference) onto EsmReference; conditions on PACK, QUST (quest, log entries, objective targets) and TERM items. MESG buttons (each an ITXT followed by its CTDAs, read natively as plain strings today) move to stage E, where they are first used. INFO, IDLE, CPTH, PERK, ALCH, SPEL, ENCH and RCPE get theirs when their records are parsed. | `test_esm_server` asserts the census totals per parsed owner and a sample of fields against xEdit for known records. |
| C. Function table | `ScriptConditionFunctions` indexed by xEdit index with parameter types; FormID parameter resolution; registry helpers accept resources. | Every function index in the census resolves to a name; parameter kinds match xEdit for every used function. |
| D. Evaluator | `ConditionEvaluator` and `ConditionContext`: run-on, comparison, globals, Or grouping. | Unit checks per operator, flag and run-on; real conditions from a known quest stage and terminal evaluate as expected in known game states. |
| E. Consumers | `QuestServer.set_stage()` runs the first log entry whose conditions pass; MESG buttons get their conditions parsed; `TerminalSession` reads its menu from `TerminalBase.menu_items` instead of the native terminal dictionaries and hides items whose conditions fail; MESG buttons likewise. | `test_quest_server` and `test_terminal_session` cover a conditioned stage and a conditioned terminal item in both states. |
| F. Coverage | A report of condition functions by use across all CTDAs, marking unimplemented ones. | Lists the next functions to implement; nothing to pass. |

## Unverified

- The operator names for values 0-5 (the ordering is recalled; the value range is confirmed).
- Flag 0x10 (one condition).
- Or grouping: stage A, then the original.
- Unimplemented function = 0: a condition such as `GetIsID X == 0` on an unimplemented function
  passes. Stage F measures how often that matters.

## Out of scope

- Parsing INFO, IDLE, CPTH, PERK, ALCH, SPEL, ENCH and RCPE records themselves.
- Dialogue topic and response selection, which uses this evaluator.
- Combat targets, which the evaluator reads as null until combat exists.
