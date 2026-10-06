# Head tracking

Which way an actor's head turns, and at what: for every actor, not only in dialogue. A component of
the actor node, `ActorHeadTracking`, beside `ActorAnimator` and `ActorEquipment`.

## Facts

From the local GECK (`enginedocs/Geck/`), FalloutNV.esm (`_diag/diag_head_tracking_census`,
`native/tools/gmst_dump`) and OpenMW's source (`enginedocs/OpenMW ... source/`), which is
Morrowind's engine, not FNV's.

- **PKDT General Flags, HeadTracking Off** (0x100000; GECK "Category Packages"): "Actor's head is
  locked looking straight ahead." On 114 of 4,163 PACK: Travel 61, Patrol 23, Follow 12, Guard 4,
  Wander 3, Sandbox 3, Find 2, Sleep 2, and one each of Accompany, Use Weapon, Dialogue, Use Item At.
- **PKDD Flags, No Headtracking** (0x1; GECK "Dialogue Package"): "Speaker and target will not be
  forced to look at each other by the package but will use normal headtracking behavior." So by
  default a Dialogue package's speaker and target face each other. On 2 PACK.
- **`Look <ref>` / `StopLook`**: in the GECK's function list (no local page). 8 SCPT call each, plus
  package event scripts (VCG01's TravelToSkullTestSpot On End `DocMitchellREF.Look player`).
  Neither is implemented in ScriptFunctionRegistry yet.
- **Game settings** (GECK "Complete List of GameSettings"; none of them in FalloutNV.esm, so these
  are the executable's defaults): fAIMaxHeadTrackDistance 400 (5.7 m), fAIBestHeadTrackDistance
  500, fAIInteriorHeadTrackMult 0.5, fAIMaxHeadTrackDistanceFromPC 2000 (28.6 m),
  fAIHoldDefaultHeadTrackTimer 10. Their meaning is inferred from the names only.
- **OpenMW** (`apps/openmw/mwmechanics/actors.cpp`, `updateHeadTracking`): every 0.3 s; none while
  knocked down, nor for the player in first person; in combat or pursuit, the active package's
  target at any distance and angle; otherwise the nearest other actor within
  fMaxHeadTrackDistance (times fInteriorHeadTrackMult indoors), in front (positive dot product
  with the facing), not dead or magically hidden, with line of sight and an awareness check.
- **Today**: `EsmActorNode._ensure_humanoid_look_target` adds a LookAtModifier3D on `Bip01 Head`
  aiming at a point fixed in the skeleton's space (ahead of a standing actor; behind a seated
  one, stage G Open).

## Rules (agreed)

In order; the first that applies wins. Sources in brackets; the rest is design.

1. **Off** when the active package has HeadTracking Off, or the actor is dead or knocked down
   (GECK; OpenMW). The head returns to straight ahead.
2. **`Look <ref>`** until `StopLook` (GECK).
3. **In conversation**: the speaker and the listener look at each other, unless the conversation
   comes from a Dialogue package with No Headtracking (GECK); likewise while a single line is said
   (DialogueServer `response_started` to `line_finished`), speaker and listener. This includes the player, so the
   seated / dialogue camera (`camera_mount` on the head) faces the partner.
4. **In combat**: the combat target, at any distance (OpenMW). When combat exists.
5. **Default**: the nearest actor within fAIMaxHeadTrackDistance (times fAIInteriorHeadTrackMult
   indoors), in front, with line of sight; held for fAIHoldDefaultHeadTrackTimer before choosing
   again (OpenMW, with FNV's settings; the hold inferred from its name). Only for actors within
   fAIMaxHeadTrackDistanceFromPC of the player (inferred from its name).
The player's body is an actor like any other: it chooses by the same rules, and others aim at its
head bone (no player-specific handling; OpenMW turns head tracking off for the player in first
person, which is not followed here: the first-person camera only follows the head while seated or
in dialogue, where looking at the partner is wanted).

Not now: looking at the package's target part of the time, and other randomness in the choice
(later; no source for either).

## Shape (agreed)

- **`ActorHeadTracking`** (a Node in `esm_actor_node.tscn`, beside ActorAnimator and
  ActorEquipment): owns the LookAtModifier3D (moved out of `EsmActorNode`), chooses the target by
  the rules every `evaluation_seconds` (0.3), and aims the modifier at the target's head bone when
  that actor has a node, else its position plus an eye height. Tunables as exports defaulting to
  the settings above. The actor node hands it the skeleton when the visual is built, as it hands
  the animator the body.
- **State it reads, kept outside it**: `ActorReference.look_target` (new, runtime, saved; set by
  `Look`, cleared by `StopLook`), the conversation partner from DialogueServer, and the active
  package's flags and target.
- **Script functions**: `Look`, `StopLook`.

## Build order

1. Done: `ActorHeadTracking` owns the look-at modifier, moved out of `EsmActorNode`
   (`test_actor_node`).
2. Done (`test_head_tracking`): rules 1, 2, 3 and 5; `ActorReference.look_target`; `Look` /
   `StopLook`; `DialogueServer.get_conversation_listener`. The modifier aims at a "Look Point"
   node on the skeleton, moved to the target's head bone (or position plus eye height). The
   default rule's candidates are the other actors with an `ActorHeadTracking` (rendered actors,
   the player's body included), not every simulated actor. Line of sight is a ray on physics
   layer 1 (the world); there is no awareness check.
3. Rule 4 when combat exists.

## Open

- What fAIBestHeadTrackDistance distinguishes from fAIMaxHeadTrackDistance.
- Whether FNV checks line of sight and awareness as OpenMW does.
