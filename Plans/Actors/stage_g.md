# Stage G: Furniture

Any actor (NPC, creature, the player) sits in, lies on or leans against furniture, chosen and
animated from the game's own data: the furniture NIF's markers and the IDLE tree. Gate: Doc sits in
his chair and stands from it in play, and the player sits on the couch, completing VCG01
objective 40.

## Facts

From `Plans/Actors/census.md` A4 and A5, `_diag/diag_furniture_anims`,
`_diag/diag_idle_conditions`, the GECK's "Idle Animations" page and the code.

- **Markers.** A furniture NIF's `BSFurnitureMarker` holds positions: offset (NIF units), heading
  (thousandths of a radian) and posRef. FURN MNAM bits 0-5 enable markers
  (`FurnitureBase.get_active_markers()`). Doc's chair and the couch seat VCG01 enables are both
  posRef 14, in front.
- **posRef is the furniture marker ID.** The IDLE tree tests `GetFurnitureMarkerID` against posRef
  values: ChairSitting 11-14; ChairLeftSit 11, ChairRightSit 12, ChairFrontSit 14; BedLeftGetUp 1.
- **Picking** (GECK "Idle Animations"): from the top item for the actor's skeleton, take the
  first child whose conditions hold, then its first qualifying child, until none qualifies; play
  that idle's KF. An idle without a KF is skipped when it has Must Return File, else nothing plays.
- **The chair tree** (male adult; female, skirt and child siblings exist):

  | Item | Conditions | Front seat (14) |
  |---|---|---|
  | ChairSitting | GetFurnitureMarkerID 11-14 | |
  | SitDown | GetSitting == 2 | ChairFrontSit: `Chair_ForwardEnter.kf` |
  | DefaultSitIdle | GetSitting == 1 | ChairDynamicIdle: `DynamicIdle_ChairSit.kf` (player in first person: `1stP_ChairDynamicIdle.kf`) |
  | SittingChairIdles | GetSitting == 3 | relax and talk idles |
  | StandUp | (not read) | ChairFrontStand: `Chair_ForwardExit.kf`; NVchairStandDoc (VCG01 stages 10-50): `SpecialIdle_NVDocChairFrontExit.kf` |
  | ChairExitFast | GetIsAlerted == 1 or ... | ChairForwardExitFast: `Chair_ForwardExitFast.kf` |

- **GetSitting values** are not in the local GECK. Inferred from the tree's order and the
  Oblivion-era documentation, not verified: 0 not sitting, 1 wants to sit, 2 sitting down,
  3 sitting, 4 wants to stand, 5 standing up.
- **Today.** `IdleBase` reads only EDID. `ScriptServer.begin_use` / `end_use` set
  `ActorReference.using` and `using_marker` (the MNAM marker index). `IsCurrentFurnitureRef` /
  `IsCurrentFurnitureObj` exist; `GetSitting` and `GetFurnitureMarkerID` are names in the
  condition table only. The native NIF reader reports a `BSFurnitureMarker` block's type and name
  but not its positions. `ActorAnimator` plays locomotion clips only. PackageRunner seats an
  actor at a radius-0 Travel furniture destination.

## Proposed shape (needs agreeing before building)

- **`IdleBase` reads** MODL (`model_path`), CTDA (`conditions`), ANAM (`parent`, `previous`:
  IDLE links) and DATA (`animation_group_section`, `loop_minimum`, `loop_maximum`,
  `replay_delay`, `flags` with named constants), with the field-doc rule's descriptions.
- **`IdleTree`** (a RefCounted owned by ScriptServer, built once from every IDLE): children in
  sibling order from ANAM; `pick(actor, start: IdleBase = null) -> IdleBase` as the GECK
  describes, conditions through `ScriptServer.evaluate_conditions` with the actor as subject.
  Which top-level item matches the actor's skeleton is to be read from the data in step 1.
- **Sit state on `ActorReference`**: `sit_state: int`, runtime, saved; the GetSitting value.
  `begin_use` on furniture sets 1, `end_use` sets 4; the actor node advances 1 to 2 to 3 and 4 to
  5 to 0 as each picked idle finishes. An actor with no node (off screen) goes straight to 3 or 0.
- **Conditions**: `GetSitting` reads `sit_state`; `GetFurnitureMarkerID` the posRef of the marker
  the actor uses.
- **Markers from the NIF**: NifServer's honest tree for a furniture model holds a `Marker3D` per
  `BSFurnitureMarker` position (metres, like every position; orientation and posRef raw in
  metadata). ScriptServer's `FurnitureSeating` requests the model's tree with the ordinary
  `request()`, reads the markers once per model and frees the tree, so an off-screen actor can
  be placed too. No furniture-specific NifServer entry point (no per-caller modes).
- **Placement**: sitting puts the actor at the used marker's position and heading; standing
  leaves it where the exit idle ends.
- **`ActorAnimator.play_idle(idle, loop)`**: plays an IDLE's KF over locomotion, once and held
  (the KFs' cycle type) or looping, and signals its end; the same entry serves `PlayIdle` and
  package idles in stage F.
- **The player** sits the same way through `PlayerController`: held in the seat, the camera at the
  seat's eye height, and leaves on the activate or a movement key. Held means its movement and
  collision queries are suspended while seated: it is a `CharacterBody3D` on layer 1, so its next
  move would otherwise push it out of the furniture's collision. An NPC is not pushed: its capsule
  is an `AnimatableBody3D` on layer 2 with no mask, moved only by its controller, which stays
  idle while seated (not yet checked with the furniture's collision loaded).

## Build order

1. **IdleBase and IdleTree**, `GetSitting`, `GetFurnitureMarkerID`. Done
   (`test_furniture_seating`): Doc in his chair picks ChairFrontSit at sit state 2,
   ChairDynamicIdle at 1, ChairFrontStand at 4, and NVchairStandDoc at 4 during VCG01 stages
   10-50. The tree's top-level items: FurnitureIdles for furniture, GeneralIdles for package and
   general idles; matching a creature's skeleton to its items is not done.
2. **Markers.** Done as its own NifServer change: `Marker3D`s in the tree, kept through
   flattening (`test_nif_furniture_markers`): 516 markers over 233 FURN records, matching census
   A4. Replaces a first version, `NifServer.request_furniture_markers`, removed for breaking the
   honest-return rule (a per-caller entry point returning raw NIF data).
3. **Sit state and placement**, on screen and off. Done (`test_furniture_seating`):
   `ScriptServer.begin_use` on furniture seats the actor through `FurnitureSeating` (sit state
   3 at the marker, placed by the furniture's transform); `end_use` stands it (0, left at the
   marker). At VCG01 stage 80 Doc's Travel package ends with him seated off screen; physicalised,
   his controller moves to the seat and stays. The animated states (1, 2, 4, 5) wait for step 4.
4. **Animation.** Built (`test_furniture_seating`): `ActorAnimator.play_idle` / `stop_idle`
   play an IDLE's KF in place of locomotion with its root tracks kept, holding the root bones
   for a clip without them (the seated loop); `FurnitureSeating` runs the sequence for an actor
   with a built visual: enter at sit state 2, the seated loop (the item picked at 1) at 3, the
   exit picked at 4 and played at 5, then 0 and locomotion. `NpcController` holds at the marker
   while the sit state is not 0. Physicalised Doc: ChairFrontSit, ChairDynamicIdle with his hips
   at 0.53 m (0.97 standing) carried into the seat, ChairFrontStand, then locomotion; his
   controller stays on the marker. Gate in play: Doc sits and stands, facing the right way.
5. **The player** on the couch. Gate in play: objective 40.

## Open

- GetSitting's values (inferred above) and StandUp's own conditions.
- Settled by the KFs (`_diag/diag_kf_root_motion`): an actor stands at the marker before the
  enter idle. `Chair_ForwardEnter.kf` carries Bip01 0.78 m along its +Y (forward) from the start
  and lowers Bip01 NonAccum from 0.96 to 0.53 m while turning it about 170 degrees;
  `Chair_ForwardExit.kf` reverses both; `DynamicIdle_ChairSit.kf` has no root position tracks.
  The front marker sits about 0.9 m in front of the chair's origin, so 0.78 m forward from it,
  facing the chair (orientation pi), ends at the seat.
- Settled (`_diag/diag_idle_facing`): the furniture KFs are authored with Bip01, the accumulation
  root, unrotated at the actor's origin. Held at its skeleton.nif rest (90 degrees about Z), the
  chair enter's first frame faces 87 degrees off the standing pose; held at identity it matches
  within 3 degrees, and seated the torso faces 180 degrees from standing at the marker (away from
  the chair's back). The exit leaves the body facing away from the chair, so standing up turns
  the actor's heading with it (`ActorAnimator.stop_idle` reports the turn).
- MNAM bits 30 and 31 (meaning unknown).
- The default look target is behind a seated actor. `EsmActorNode`'s LookAtModifier3D aims at a
  point fixed in the skeleton's space, ahead of where a standing actor faces; seated, the body faces
  180 degrees from the controller (which stays facing the furniture at the marker), so the point
  is behind the head and only the 110-degree limit stops the head turning round. Options: aim the
  default target from the torso's facing rather than the skeleton frame; or turn the controller
  to the seated facing while seated, counter-rotating the idle's root. Stage F's `Look` /
  `StopLook` set real targets and may decide it.
- Layered sequences. `DynamicIdle_ChairSit.kf` drives the thighs and feet but no calves, pelvis or
  root: it is authored to play over the pose `Chair_ForwardEnter.kf` ends in (knees bent about
  90 degrees). Gamebryo layers KF sequences by per-bone priority, so a lower sequence keeps the
  bones a higher one does not drive; `ActorAnimator` plays one clip at a time and approximates
  this by holding every bone an idle has no track for at its current pose
  (`_hold_missing_tracks`). That covers a static base pose; several sequences active at once
  (a talking idle on a seated pose, upper-body idles while walking) need a real layer model
  with the KFs' priorities, not designed yet.
