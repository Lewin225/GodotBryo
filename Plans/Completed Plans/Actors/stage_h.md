# Stage H: Packages

Package selection and the package types VCG01 needs, for every placed actor, on screen and off.
Gate (the actors plan's done-condition, with stages F and G): a new game plays VCG01 from stage 80
to stage 200 with no console.

## Facts

From `Plans/Actors/census.md` A3 and A4, the GECK pages in `enginedocs/Geck/Packages/` and the code.

- **Sources.** `ActorBase.packages` (PKID, authored order); from the template when ACBS template
  flag 0x20 (Use AI Packages) is set (`ActorBase.template_source`). Scripts add one with
  `AddScriptPackage` (1,141 calls in FalloutNV.esm) and remove it with `RemoveScriptPackage`.
  Four Goodsprings powder gangers take theirs from a leveled list, which `template_source` does
  not follow (`Plans/Actors/templated_npcs.md`).
- **Selection** (GECK "How Are Packages Evaluated"): the list is searched top to bottom and the
  first package whose schedule and conditions hold is chosen. Re-evaluated about every 10 s, on
  `EvaluatePackage` (`evp`), and when a package completes.
- **Removing a script package** (GECK `RemoveScriptPackage`): "the actor will automatically choose
  a new package".
- **Schedule.** PSDT on every PACK: month, day of week, date, hour (-1 is any) and duration
  (`PackageBase.schedule_*`). Every package in the Goodsprings census has one; the VCG01 ones
  have no hour. The game hour is `game_time_manager.game_hour` (`GetCurrentTime`).
- **Conditions.** `PackageBase.conditions` (CTDA). VCG01's use GetStage; the Goodsprings
  population also uses GetStageDone, GetQuestCompleted, GetQuestVariable, GetObjectiveDisplayed
  and GetObjectiveCompleted, all implemented.
- **Doc's PKID** (census A3), top to bottom: GoodspringsMilitiaTravelPackage (VMS16b),
  VCG01DocMitchellSandbox (VCG01 completed), FarewellDialogueStart 00105BD2 (Dialogue,
  stage >= 115), TravelToExit 00105BD1 (stage >= 110), TravelToExamSpot (stage >= 80,
  DocMitchellChairREF), TravelToSkullTestSpot (>= 76; On End `DocMitchellREF.Look player`),
  TravelToPlayerAtTester (>= 55), BedsideStandingPackage (>= 40), FirstPosition (always). The
  Travel ones carry the idle NPCSmokingIdle.
- **Travel** (GECK): the actor paths to the destination and stops at the edge of its radius.
  A Travel package to a furniture reference with radius 0 makes the actor use it: 110 of the 111
  Travel packages whose Location 1 is near a placed FURN have radius 0 (census A3; the rule was
  given by the user, not found in the GECK).
- **Dialogue** (GECK): the actor goes to its Start/Wait location, then to the target, and starts
  the conversation within Activate Distance; with the player as target and Conversation type it
  force-greets. 00105BD2: near VCG01DocMitchellExitMarkerREF, target the player, distance 420
  units (6 m), no topic (GREETING).
- **Events.** On Begin, On End, On Change (`PackageBase.on_begin` / `on_end` / `on_change`,
  PackageEventCollection: idle, embedded script, topic), on 11 of the census's 68 packages.
- **Today.** `PackageRunner` runs `ActorReference.active_package`, set only by
  `set_package()` (AddScriptPackage); FOLLOW only. `ScriptServer.begin_use` / `end_use` set
  `ActorReference.using` and `using_marker` and claim a free furniture marker, for any actor.
  `ScriptServer.run_result_script` runs a script fragment on a subject.

Not verified: when a Travel package counts as complete (inferred: on arrival, since
TravelToSkullTestSpot's On End `Look player` only makes sense there); what Must Complete and
Must Reach Location change for Travel; whether a second `AddScriptPackage` replaces the first;
00105BD2's flags.

## Proposed shape (needs agreeing before building)

**State on `ActorReference`** (runtime, saved with the reference):

- `active_package: PackageBase` — exists today, written by `set_package()` (AddScriptPackage)
  and run by `PackageRunner`. Changes meaning: the package selection chose (the script package,
  else the first of the base's packages whose schedule and conditions hold), written only by
  `PackageRunner`.
- `script_package: PackageBase` — new: the package `AddScriptPackage` gave, which selection puts
  first until it completes or `RemoveScriptPackage` clears it, after which the actor chooses from
  its own list again. A separate field so that clearing it leaves the base's list to choose from,
  and selection can tell an added package from one it chose.
- `package_completed: bool` — new (step 2): the active package has done its job (Travel arrived,
  Dialogue spoken). Name and need to be confirmed against what completion does in the game.

**`PackageRunner`** grows from FOLLOW-only:

- **Evaluation** per actor every 10 s (on its sweep turn, both sweeps), on `evp`, and when the
  active package completes; also when an actor is first seeded. A change of package runs the old
  one's On End (if it had begun and not ended) and the new one's On Begin.
- **Generic over actors**: the same code for leased and unleased actors; only movement differs
  (NpcController or LowLevelTravel, through `move_target`, as FOLLOW does now).
- **Travel**: resolves Location 1 (Near reference, In cell, Near current location; others left
  unresolved and logged once) to a point; sets `move_target`; arrival is within the radius
  (radius 0: `move_target_reached`). On arrival at a furniture reference with radius 0 it calls
  `ScriptServer.begin_use(actor, furniture)`; otherwise the actor stands. Arrival completes the
  package and runs On End. A target in another space goes through the door sequence FOLLOW uses.
- **Dialogue**: goes to the Start/Wait location; when the target is within Activate Distance,
  starts the conversation through `DialogueServer` (GREETING when no topic; force-greet when the
  target is the player) and completes.
- **Events**: On Begin / End / Change scripts through `ScriptServer.run_result_script` with the
  actor as subject; topics through `DialogueServer.say`; idles handed to the actor (stage F plays
  them; until then recorded and ignored).
- **Package idles** (IDLA, e.g. NPCSmokingIdle) while a Travel package waits at its destination:
  stage F.

**Seating is the actor's state, not the controller's** (stage G). Any actor, NPC or creature,
sits by `begin_use`; the controller and LowLevelTravel only stop moving while `using` is set, and
the actor node plays the furniture animations from `using` / `using_marker`. An off-screen actor
sits the same way, so a physicalised actor appears already seated.

**Script functions**: `EvaluatePackage` / `evp`; `AddScriptPackage` / `RemoveScriptPackage` move
to `script_package`. `GetIsCurrentPackage`, `GetCurrentAIPackage` and `GetCurrentAIProcedure` when
a script needs them.

## Build order

1. **Selection.** Done (`test_package_selection`): `PackageRunner` tracks every actor
   NpcSimulationServer indexes and chooses by schedule and conditions, script package first;
   `evp`. `active_package_changed` replaces `move_running`.
2. **Travel.** Done off screen (`test_package_travel`): Near reference, Near linked reference,
   Near editor location (`EsmServer.get_authored_placement`) and Near current location (1,249
   of the 1,260 Travel packages; In cell's 11 are logged and left); arrival at the radius or,
   for radius 0, at the point; completion (`package_completed`), On End, and choosing again;
   On Begin; a radius-0 furniture destination is used (`begin_use`) and left when another
   package replaces it. Doc walks to each VCG01 marker in turn and ends in his chair at stage
   80. Still to check: the same on screen (NpcController), and his chair trigger setting
   `bDocInChair`.
3. **Dialogue.** Done off screen (`test_package_dialogue`): Location 1 is the wait location,
   Location 2 the trigger location, Target 1's Count / Distance the activate distance; within it
   a Conversation package starts the conversation (the force-greet with the player), a Say To
   package says its topic, GREETING when PKDD names none; that completes it. Doc force-greets at
   the exit at stage 115; Sunny waits until the player is inside SunnySmilesTrigger, then
   greets. `IsCurrentFurnitureRef` / `IsCurrentFurnitureObj` added for the chair trigger, which
   then sets `bDocInChair` in play.
4. **Gate**, with stages F (PlayIdle, Look, sitting animations) and G (the player sitting on the
   couch): `test_vcg01_exam` drives VCG01 from 80 to 200, then the same in play.

Not in this stage: Sandbox, Sleep, Eat, Guard, Patrol and the rest; hour schedules beyond the
check above; the player's packages (VCG00/VCG01 wake-up sections, before stage 80).

## Open

- The four unverified points under Facts, checked against the game or real data before the step
  that relies on each.
- On End runs only when a package completes; whether it also runs when a package is
  interrupted, and when On Change runs, are not verified, so On Change is not run.
- Day of week in schedules (53 packages) is not checked.
- Sunny Smiles does not greet the player entering the saloon in play, although
  `test_package_dialogue` passes off screen with the player placed inside SunnySmilesTrigger.
  Not investigated (parked to focus on VCG01).
- Inferred, not verified: a Dialogue trigger location of radius 0 on a reference with an XPRM
  primitive means the target inside that volume (`PackageRunner.is_inside_primitive`); a
  Dialogue package that finds nothing to say still completes, so the actor does not retry.
- Leveled-list package sources (`Plans/Actors/templated_npcs.md`).
