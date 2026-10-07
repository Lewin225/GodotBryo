# Stage F: idles

`PlayIdle`, package event idles, package idle lists and ambient idles. Locomotion, the
furniture idles and `Look` / `StopLook` are done (stage D, `stage_g.md`, `head_tracking.md`).
The player's VCG01 wake-up idles move only `Camera1st` and wait for the first-person rig
(`first_person.md`).

## Facts

From FalloutNV.esm (Python scans of every SCPT, INFO, QUST, PACK and IDLE) and the local GECK
(`Category_Packages`, `Idle Animations`).

- **`PlayIdle <IDLE>`**: 116 calls (SCPT 90, INFO 11, QUST 7, PACK 8) naming 44 IDLEs, mostly
  `Loose*` and `SpecialIdle*`. VCG01's stage script calls `DocMitchellREF.PlayIdle
  VCG01DocGiveMirror` (IDLE 0x10658C, `SpecialIdle_NVCG01DocGiveMirror.kf`, no conditions).
- **Package events**: PKDT's Begin, End and Change each carry an idle, a topic and a result
  script (`PackageEventCollection`: `idle`, `topic`, `script_source`). Idles on 60 of 4,163 PACK:
  On Begin 47, On End 17, On Change 23. GECK: "The script is run first, so if you set a quest
  stage or variable in the results script, the topic and idle will react to it"; "On End idle
  only works for packages which have a 'done' state"; "If a package is marked Must Complete, On
  End idle will finish playing before starting the next package."
- **On Change**: VCG01 stage 7 re-adds the package already running, with the comment "this is
  the second time we call this - it triggers the OnChange animation". The GECK names Change as a
  state change of the package but does not define it further.
- **IDLE loops** (GECK): Loop Forever, Min and Max times ("only available for animations that can
  loop"), Replay Delay. `IdleBase.loop_minimum` / `loop_maximum` / `replay_delay` are read, not
  used.
- **No ESM field holds an actor's current idle.** The only idle on an actor reference is ACHR /
  ACRE patrol data (XPRD idle time, INAM idle, TNAM topic), present on none in FalloutNV.esm
  (census A1; `ActorReference.idle_time` / `idle_form_id` / `idle`, not read).
- **Package idle lists** (census over all 4,163 PACK): 242 carry an idle collection, always in
  the order IDLF, IDLC, IDLT, IDLA. The GECK says only that it lets "the idles used by an actor
  running the package" skip the idle manager. xEdit's `wbIdleAnimation` is in a definitions file
  not vendored under `enginedocs/xEdit/`.
  - IDLA: the IDLE FormIDs (1 to 36).
  - IDLC: their count, equal to IDLA's on all 242 (1 byte; a u32 on 2).
  - IDLF: one byte, 0 on 212, 0x01 on 16 (the VCG00/VCG01/CG00/CG04 player and cutscene
    sections, Dogmeat waiting, DoctorHoldPosition), 0x04 on 14 (the Tops dealers' smoke breaks
    and deals, the protectrons turning on, Strip dialogue packs). Their meaning is not verified;
    FO3's GECK is recalled to have "Run in Sequence" and "Do Once" on this tab.
  - IDLT: a float, 0 on 138, else 0.2 to 30 (2.0 on 27, 1.0 on 15, 5.0 on 13); seconds between
    idles, inferred.
  - Doc's VCG01 Travel packages (TravelToSkullTestSpot, BedsideStanding, ...): IDLF 0, IDLT 0,
    one idle, `NPCSmokingIdle` (0x071EE3, `SmokingStanding.kf`, loop 2-6, replay delay 120;
    conditions IsRunning == 0, GetInFaction 000711A4, GetEquipped 000CC824 != 1,
    GetRandomPercent < 30). No script calls it.
- **Idle timing settings** (GECK's GameSettings list; none in FalloutNV.esm, so the
  executable's defaults): fAIIdleWaitTime 1.0, fAIIdleAnimationDistance 2000, fAIEnergyLevelBase
  0. Their meaning is inferred from the names only.
- **Ambient idles** (GECK): actors pick from the IDLE tree when "their energy level timer has run
  down" while the lower body idles; speaker and listener pick one "each time a new conversation
  item is spoken".
- **Today**: `PackageRunner._run_event` runs the event's script and says its topic; the idle is
  not played and On Change never runs. `ActorAnimator.play_idle` / `stop_idle` play one idle in
  place of locomotion (used by `FurnitureSeating`).

## Proposed shape (needs agreeing before building)

- **`ActorReference.special_idle: IdleBase`** (new, runtime, no ESM source; see Facts): the
  idle a script or package event asked the actor to play; cleared when it ends. Actor state on
  the resource, as `sit_state`. Not the patrol `idle` (INAM).
- **`ActorIdles`** (a child of ScriptServer, beside `FurnitureSeating`): `play(actor, idle)` sets
  `special_idle`; the actor node plays it through `ActorAnimator.play_idle` and on
  `idle_finished` calls `finish(actor)`, which clears it and returns to locomotion (turning the
  actor by `stop_idle`'s yaw, as standing up does). An actor without a node ends the idle at
  once (nothing sees it). While seated, `play` does nothing (the furniture idles own the body).
- **`PlayIdle`**: the script function, on the subject, calls `ActorIdles.play`.
- **Package events**: `_run_event` plays the event's idle after its script and topic. On Change
  runs when `AddScriptPackage` adds the package already active, and when another package
  replaces the active one before it is done (inferred from the name). Must Complete's wait for
  the On End idle is not built.
- **Loops**: the KF's `StartLoop` - `EndLoop` section plays between `loop_minimum` and
  `loop_maximum` times, forever for 255 (step 3).
- **Package idle lists** (step 4; needs agreeing): while an actor with a 3D node idles (not
  moving, not seated, no idle playing) under a package with an idle collection, every IDLT
  seconds (fAIIdleWaitTime when 0) ScriptServer's ActorIdles picks one of IDLA's idles whose
  conditions pass (actor as subject) and plays it as `special_idle`. An idle is not picked again
  within its Replay Delay of last playing (GECK: "The time between animation replays"). IDLF
  0x01 picks in order rather than at random, and 0x04 stops after one pass through the list
  (both inferred from FO3's GECK, recalled). Only within fAIIdleAnimationDistance (2000 units)
  of the player (inferred from the name, as head tracking's fAIMaxHeadTrackDistanceFromPC).
- **Ambient idles**: a later step.

## Build order

1. Done (`test_actor_idles`): `special_idle`, `ActorIdles`, `PlayIdle`; Doc plays
   VCG01DocGiveMirror and returns to locomotion. An idle asked for while the actor's animations
   load is kept and played once they have (`EsmActorNode._apply_animation_state`).
2. Done (`test_actor_idles`): package event idles play after the event's script and topic; On
   Change runs when `AddScriptPackage` adds the active package again, and when another package
   replaces it before it is done (inferred).
3. Done (`test_actor_idles`, census `_diag/diag_idle_loops`): an IDLE's Looping min / max
   count passes of its KF's `StartLoop` - `EndLoop` text-key section (256 of the 258 looping
   IDLEs' KFs have both keys; the other 2 are KFs authored to cycle); 255 loops forever (85
   IDLEs, among them the chained cutscene sections and the VCG01 wake-up idles). The section
   plays a random count between min and max, at least once (inferred: whether N counts passes
   or repeats after the first is not established).
4. Done (`test_actor_idles`): package idle collections, as proposed (IDLF / IDLC / IDLT read as
   typed fields by EsmServer, `39ac6e5a`). IDLT counts from when the last idle ended. Doc never
   plays NPCSmokingIdle: its conditions need SmokerFaction (000711A4), which DocMitchell
   (NPC_ 00104C0C; factions 0015EC58, 00104C6E, 000251D8) is not in; 411 NPC_ are.
5. Ambient idles from the IDLE tree.

## Open

- What Change means beyond re-adding the active package.
- Whether an actor without a node holds the idle's duration (scripts that wait on it).
- What ends a forever idle besides another idle or the package's next event idle: an actor
  given a move target while one plays slides in its pose; a package's collection waits behind
  it.
- `IsRunning` is not implemented (reads 0); idle conditions use it.
