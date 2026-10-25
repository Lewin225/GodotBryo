# Stage F: idles

`PlayIdle`, package event idles, package idle lists and ambient idles. Locomotion, the
furniture idles and `Look` / `StopLook` are done (stage D, `stage_g.md`, `Plans/Completed Plans/Actors/head_tracking.md`).
The player's VCG01 wake-up idles move only `Camera1st` and wait for the first-person rig
(`Plans/Actors/first_person.md`).

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
- **The Idle Manager** (GECK "Idle Animations", The Idle Manager In Game): the tree's top-level
  items are skeletons; a pick starts at the actor's skeleton, takes the first top-level IDLE
  whose conditions it meets, then that item's first qualifying child, until none qualifies.
  Picks happen on `PickIdle`; on knock-downs, getting up and yielding; constantly while sleeping
  or eating; "during dialogue ... by both the speaker and the listener each time a new
  conversation item is spoken"; and "at random times based on the actors energy level. Actors
  with low energy settings will idle more often", when the lower body idles.
- **The humanoid tree** (`_diag/diag_idle_tree_functions`): 11 top-level IDLEs with children
  under `Characters\_Male\`, 721 items: FurnitureIdles 394, DialogueIdles 160, HitReactionIdles
  60, VATSMeleeAttacks 44, GeneralIdles 31, the rest 32. No locomotion: walking, running and
  turning are the skeleton's locomotion KFs. By animation group section: Special Idle 466,
  Whole Body 102, Weapon 61 (44 the VATS melee attacks), Movement 59 (54 leg hit reactions,
  the 2 get-ups, a drunk walk, 2 Pip-Boy idles: the lower body, not walking), Idle 25, Upper
  Body 8. Their own conditions (unimplemented functions read 0):
  PanicExplosivePlanted GetPlantedExplosive == 1*; GeneralIdles GetEquipped != 1, IsInCombat
  != 1*, IsSneaking == 0*; VATSMeleeAttacks GetVATSValue*, GetIsID, GetVATSMode*;
  ActivateIdles GetUsedItemActivate == 1*; KnockedDownIdles GetHitLocation == -1*,
  GetKnockedState != 0*; FurnitureIdles GetSitting > 0, GetSleeping > 0*; HitReactionIdles
  GetSitting == 0, GetSleeping == 0*, GetHitLocation != -1*; DialogueIdles two GetActorValue
  > 0, GetCurrentAIProcedure == 4*, MenuMode == 1; GreetIdles IsGreetingPlayer == 1*; EatIdles
  IsWeaponOut != 1*, GetEquipped != 1, GetCurrentAIProcedure == 10*; MenuModeIdles MenuMode != 0
  (* not implemented). Read as 0, GetHitLocation != -1 passes, so every standing actor would
  qualify for HitReactionIdles. 40 of the 51 functions the tree uses are not implemented;
  under GeneralIdles (31 items) the missing ones are IsMoving and IsWeaponOut (4 each),
  GetCurrentAIPackage, GetCurrentAIProcedure, GetWeaponAnimType (2), and 5 used once; under
  DialogueIdles (160) IsLastIdlePlayed (28), GetDialogueEmotion (20), IsTalking (9), GetIsClass
  (7), GetIsRace (4) and others.
- **Energy level** (NPC_ AIDT offset 2, xEdit): 50 on 2,146 NPC_, 100 on 1,459, 20 on 94, 10
  on 68 (Doc Mitchell 10). No source gives the timer's formula.
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
- **Ambient idles** (step 5; needs agreeing), in three parts:
  - **5a. Honest root conditions.** Register the functions the humanoid roots' own conditions
    use, each returning the state as this engine has it: GetHitLocation -1 and GetKnockedState
    0 (no hits or knock-downs yet), GetPlantedExplosive, GetVATSValue / GetVATSMode,
    GetUsedItemActivate, IsGreetingPlayer 0, IsInCombat 0, IsWeaponOut 0, GetSleeping 0 (no
    sleep yet), GetCurrentAIProcedure (the active package's procedure; its numbering needs a
    source before 4 and 10 mean anything). Each documented as current state, not the original's
    full behaviour.
  - **Movement state on the actor.** IsMoving, IsRunning and IsSneaking read runtime state on
    `ActorReference` (actor behaviour, any actor), set by whichever controller drives it: the
    player's from `PlayerController` (the crouch is sneaking), an NPC's from `NpcController`
    (its package's Always Run and Always Sneak flags until combat and AI set them).
  - **5b. PickIdle and ambient picks.** `IdleTree.pick_for(actor)`: the top-level IDLEs of the
    actor's skeleton (MODL under its skeleton folder; humanoids only at first) in sibling order.
    `PickIdle` plays the pick. An actor standing idle with a 3D node and no package idle
    collection picks every N seconds, N lower for lower energy (formula not sourced: an export,
    say 20 s at energy 50, scaled by energy / 50, at least fAIIdleWaitTime).
  - **5c. Dialogue idles**: speaker and listener pick on each response (DialogueServer
    `response_started`). Needs GetCurrentAIProcedure == 4, IsLastIdlePlayed, GetDialogueEmotion
    and IsTalking; its own step after 5b.

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
5. Ambient idles from the IDLE tree:
   - 5a done: `ActorReference.is_moving` / `is_running` / `is_sneaking`, set by PlayerController
     (the crouch is sneaking) and NpcController (package Always Run / Always Sneak); IsMoving,
     IsRunning, IsSneaking read them. GetHitLocation -1, GetKnockedState, IsInCombat,
     IsWeaponOut, GetSleeping, IsGreetingPlayer, GetPlantedExplosive, GetUsedItemActivate,
     GetVATSMode, GetVATSValue 0, GetCurrentAIProcedure -1: the current state of systems not
     built yet (shipped conditions compare IsMoving / IsRunning / IsSneaking / IsWeaponOut /
     IsInCombat only with 0 and 1; GetHitLocation's -1 is "none", 0-12 body parts).
   - 5b done (`test_actor_idles`): `IdleTree.pick_for` picks from the actor's skeleton's
     top-level items (parentless, not loose, MODL under its skeleton folder), in sibling order;
     `PickIdle`; ambient picks every `ambient_idle_seconds` (20) x energy / 50, at least 1 s, for
     an actor standing idle with no package idle collection. Doc's pick is the GeneralIdles
     group, which plays nothing: every item a standing NPC without a weapon reaches needs
     SmokerFaction or GeneralIdleFaction, and he is in neither. Johnson Nash (a smoker) picks
     NPCSmokingIdle at its 30%.
   - 5c done (`test_actor_idles`): dialogue idles. Saying his farewell, Doc plays
     ttnpcNTRLHandsDownTalkC, B and F for its three neutral responses and
     ttnpcHappyArmsLooseTalkA for the fourth (emotion 5, Happy), all from DialogueIdles. On each response (DialogueServer `response_started`; a
     "conversation item" read as a response: SNAM and TRDT emotion are per response), the
     speaker and the listener each play the response's SNAM / LNAM idle when it names one
     (SNAM on 320 INFOs, LNAM on 1), else their tree pick; the player's body too (actor logic,
     no player exception). A dialogue idle still playing when the line ends is ended. New
     condition functions: IsTalking (saying a line now), GetDialogueEmotion (the response said
     or heard; xEdit TRDT: 0 Neutral, 1 Anger, 2 Disgust, 3 Fear, 4 Sad, 5 Happy, 6 Surprise,
     7 Pained), IsLastIdlePlayed (`ActorReference.last_idle`), GetIsRace, GetIsClass, IsChild
     (RACE DATA flag 0x04), GetCurrentAIPackage (the active package's type mapped by name onto
     the GECK's codes: 0 EXPLORE, 1 FOLLOW, 3 EAT, 4 SLEEP, 5 COMBAT, 6 DIALOGUE, 13 WANDER,
     14 TRAVEL, 15 ACCOMPANY, 16 USEITEMAT, 36 SANDBOX, 37 PATROL ...), and
     GetCurrentAIProcedure from what the actor does (the GECK page saved under
     `enginedocs/Geck/`, written for Fallout 3: 0 TRAVEL, 3 WAIT, 4 DIALOGUE, 5 GREET, 10 EAT,
     11 FOLLOW, 13 COMBAT, 16 FLEE, 24 DO_NOTHING, 48 SITTING ...; "the procedure is not the same
     as the current package": a Travel package travels, then waits). The idle data agrees:
     DialogueIdles tests 4, EatIdles 10, NPCOnlyIdles excludes 4 and 10, LooseSmokingStanding
     excludes 13 and 16.

## Root bones in idle KFs

Census over all 649 IDLE KFs under `Characters\_Male\` (`_diag/diag_idle_root_frames`): no KF
keys Bip01's rotation; where Bip01's position is keyed (91) it is at the origin, or near it plus
the root motion of furniture enters / exits and hit staggers; Bip01 NonAccum carries the stance,
about 0.9 m up and a quarter turn about the up axis (80-110 degrees with authored leans: 116 with
Bip01 unkeyed, 43 with it keyed). 127 key NonAccum's height but not its rotation (many talk and
listen gestures, LooseSmokingStanding); 107 key neither (first-person and player camera clips).
skeleton.nif instead rests Bip01 at 0.968 m and 90 degrees, NonAccum at identity. So an idle
taking over from locomotion holds Bip01 at identity at the origin and, where the clip does not
drive it, NonAccum at the transform locomotion's Bip01 and NonAccum gave it together
(`ActorAnimator._hold_missing_tracks`): held at rest, keyed heights counted twice (Doc floated
0.95 m) and unkeyed rotations lost the quarter turn (bodies turned 90 to 180 degrees).

## Open

- What Change means beyond re-adding the active package.
- Whether an actor without a node holds the idle's duration (scripts that wait on it).
- What ends a forever idle besides another idle or the package's next event idle: an actor
  given a move target while one plays slides in its pose; a package's collection waits behind
  it.
- NPCUnconscious tests GetUnconscious (== 1), unimplemented: reading 0 gives the right answer
  for a conscious NPC, by chance. BartenderDialogue tests GetHeadingAngle, unimplemented.
- Whether FNV's procedure codes are Fallout 3's (the saved GECK page is FO3's); the idle data's
  own uses (4, 10, 13, 16) agree.
