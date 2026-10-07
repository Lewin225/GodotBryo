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
- **Package idle lists**: PACK IDLA names idles the package plays while it runs, with IDLC, IDLF
  and IDLT beside it (`PackageBase.idle_animations`, read; the other three raw, meaning not
  verified: xEdit's `wbIdleAnimation` is in a definitions file not vendored under
  `enginedocs/xEdit/`). Doc's VCG01 Travel packages list `NPCSmokingIdle` (0x071EE3,
  `SmokingStanding.kf`, 4 conditions; census A3). No script calls it.
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
- **Loops**: a looping clip plays between `loop_minimum` and `loop_maximum` times (once when both
  are 0), after a census of the values on the idles played this way.
- **Package idle lists** (`NPCSmokingIdle`) and **ambient idles**: later steps, after a census of
  IDLC / IDLF / IDLT.

## Build order

1. Done (`test_actor_idles`): `special_idle`, `ActorIdles`, `PlayIdle`; Doc plays
   VCG01DocGiveMirror and returns to locomotion. An idle asked for while the actor's animations
   load is kept and played once they have (`EsmActorNode._apply_animation_state`).
2. Done (`test_actor_idles`): package event idles play after the event's script and topic; On
   Change runs when `AddScriptPackage` adds the active package again, and when another package
   replaces it before it is done (inferred).
3. Loops (census first).
4. Package idle lists (IDLA with IDLC / IDLF / IDLT; census first): Doc's NPCSmokingIdle.
5. Ambient idles from the IDLE tree.

## Open

- What Change means beyond re-adding the active package.
- Whether an actor without a node holds the idle's duration (scripts that wait on it).
