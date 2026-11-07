# Animation blending

How Fallout: New Vegas combines several KF sequences on one actor, and what the runtime needs to
reproduce it. Actors currently play one clip at a time (`ActorAnimator`): a hand gesture replaces
the walk cycle, and a seated idle replaces every gesture.

## Facts

From `native/tools/kf_priority_census` over every KF under `meshes\characters\_male\` (2,109
files, 2,149 `NiControllerSequence` blocks), `Plans/Completed Plans/Actors/census.md` A5 and
`enginedocs/Animation Census.txt`.

### Per-bone priority

- Each controlled block (`ControllerLink`, one per animated bone or other target) carries a
  priority byte. NifSource does not read it.
- Values run from 0 to 100. The most common: 55 (22,199 blocks), 65 (13,151), 30 (12,739), 50
  (11,781), 13 (11,066), 0 (3,599), 27 (3,568), 56 (3,530).
- Clips in the folder root (the shared and weapon clips) split the body by priority:
  - legs, feet, pelvis and `Bip01 NonAccum`: about 25 to 30 (`Bip01 L Thigh = 27` on 355
    sequences, `= 30` on 290);
  - spine, arms, hands, fingers, pauldrons and `Weapon`: 55;
  - head: 65 or 95.

  Priority sets per sequence: {25, 55} on 90, {27, 65} on 64, {26, 55} on 64, {0, 27, 65} on 58,
  {27, 55} on 53.
- Special idles give every bone one priority, and the value differs between clips:

  | KF | Sequence | Priority | Length |
  |---|---|---|---|
  | `idleanims\congratgesture.kf` | SpecialIdle_CongratGesture | 13, every bone | 1.67 s |
  | `idleanims\dialogarmscrossedtalka.kf` | SpecialIdle_DialogArmsCrossedTalkA | 13, every bone | 3.37 s |
  | `idleanims\chairfemalesittinga.kf` | SpecialIdle_ChairFemaleSittingA | 50, every bone | 13.40 s |

  In `idleanims`: {13} on 126 sequences, {50} on 58, {55} on 37, {50, 55} on 36, {30, 85, 94,
  95} on 34. `dialogarmscrossedtalka.kf` also has controlled blocks with no node name, at
  priorities 6 to 90; what they target is not checked.
- `locomotion\hurt`, `locomotion`, `locomotion\female` and `locomotion\child` sequences use 30 on
  every bone, or {0, 30, 36}.

### Sequence fields

- Weight: 1.00 on all 2,149 sequences.
- Cycle type: 2 on 1,771, 0 on 378.
- Accum root: `Bip01` on the clips checked.

### Text keys

Kinds across all sequences (the part before a colon):

| Key | Count |
|---|---|
| `end` | 2,187 |
| `start` | 2,186 |
| `sound:` | 1,704 |
| `blend:` | 1,241 |
| `enum:` | 1,011 |
| `hit` | 433 |
| `blendin:` | 370 |
| `a:` | 358 |
| `endloop` | 342 |
| `startloop` | 334 |
| `m:` | 190 |
| `prn:` | 100 |
| `decal:` | 91 |
| `blendout:` | 41 |

Examples: `chairfemalesittinga.kf` has `start` 0.00, `Startloop` 0.03, `Blend:10` 3.30,
`Endloop` 13.37, `end` 13.40; `congratgesture.kf` has `Blend: 20` at 0.80;
`dialogarmscrossedtalka.kf` has `Startloop` 0.83, `Blend:30` 2.63, `Endloop` 3.33.

### Animation group sections

IDLE DATA byte 0, low six bits (census A5): 0 Idle, 1 Movement, 2 Left Arm, 3 Left Hand,
4 Weapon, 5 Weapon Up, 6 Weapon Down, 7 Special Idle, 20 Whole Body, 21 Upper Body. Counts: 7 on
748 IDLEs, 0x47 on 346, 20 on 151, 0x87 on 72, 1 on 123, 4 on 55, 0 on 37. Read into
`IdleBase.animation_group_section`; only the loose flag (0x40) is used, by IdleTree.

### Bones keyed per section

From `native/tools/idle_section_census` over every IDLE in `FalloutNV.esm`: the section (DATA
byte 0, low six bits), the IDLE's MODL KF, and the bones its controlled blocks name, grouped
into regions: lower (Bip01, NonAccum, pelvis, legs), spine, head (neck, head), left arm, right
arm (clavicle to fingers), weapon, other.

| Section | IDLEs | KFs read | KFs keying every body region |
|---|---|---|---|
| 0 Idle | 45 | 39 | 25 |
| 1 Movement | 125 | 112 | 100 |
| 4 Weapon | 68 | 31 | 30 |
| 7 Special Idle | 1,170 | 856 | 723 |
| 20 Whole Body | 168 | 145 | 130 |
| 21 Upper Body | 21 | 20 | 8 (the other 12: 9 Securitron KFs, 3 keying all but other) |

- No IDLE uses sections 2, 3, 5 or 6. The IDLEs without a KF are grouping nodes with no MODL,
  or name a KF not in the BSAs.
- A KF's section does not limit the bones it keys. The 20 Upper Body KFs read all key the lower
  body.
- Within one KF, the bones outside the section are often at a lower priority than the bones in it:

  | KF (section 21) | Legs | Spine | Arms | Head |
  |---|---|---|---|---|
  | `2hrLoiter.kf`, `2hrShiftWeight.kf`, `2haAlertScan.kf` | 13 | 30 | 33 | 33 (93 on some head blocks) |
  | `HeadUpGreet.kf` (and Left, Right) | 9, 11 | 11 | 11 | 13, 93 |
  | `2HATalkAngry.kf` | 13 | 13 | 13 | 13 |

## OpenMW

From `enginedocs/OpenMW (Morrowwind Engine Replacement) source/openmw-master`. OpenMW does not
play NV KFs, so it shows one engine's design, not what Gamebryo does.

- `components/nif/controller.cpp` reads `NiControllerSequence` and the ControllerLink priority
  byte (`mPriority`, Bethesda versions only). Nothing in `components/nifosg` or `apps/` uses
  either. Animation runs from Morrowwind-style `NiKeyframeController` tracks and text keys
  (`group: start`, `group: loop start`, ...). `ESM4NpcAnimation` assembles body parts and plays
  nothing.
- The skeleton splits into four fixed bone groups (`bonegroup.hpp`, `blendmask.hpp`): lower body,
  torso, left arm, right arm. A track's group is its first ancestor named `Bip01 Spine1`,
  `Bip01 L Clavicle` or `Bip01 R Clavicle`; anything else is lower body
  (`Animation::detectBlendMask`).
- `play()` takes a group name, an `AnimPriority` (one int per bone group) and a mask of the bone
  groups it plays on. Priorities come from game logic (`mwmechanics/character.hpp`
  `Priority_*`: Default, WeaponLowerBody, SneakIdleLowerBody, SwimIdle, Jump, Movement, Hit,
  Weapon, Block, Knockdown, Torch, Storm, Death, Scripted), not from the file.
- Playing a group ends every other state with an identical `AnimPriority`.
- `resetActiveGroups()`: per bone group, the playing state whose mask covers the group and whose
  priority there is highest drives every bone in it. No weights; one state per group.
- Transitions cross-fade per bone (`animblendcontroller.cpp`: slerp rotation, lerp translation,
  scale not blended) over a duration from optional YAML blend rules (from group/key to
  group/key, duration, easing); with no rule the duration is 0.

## Inferred, not confirmed

- Gamebryo blends per bone by priority: the tracks at the highest priority take their weight,
  and weight left below 1 passes to the next priority down. With every weight at 1, the highest
  priority track on a bone decides it. Not checked against the game or Gamebryo's code.
- `Blend:N` is a blend time in frames; `startloop` / `endloop` bound the looping part of a clip
  with an intro and an outro. Read from the key names and positions only.
- The animation group section is the slot an IDLE plays in, one sequence per section, as the
  sections name body parts and weapon states.
- Under the priority rule alone, a talk gesture at 13 would lose every bone to a walk's 27 to 55,
  and a seated idle at 50 would keep the walk's head at 65. Either the section, not the KF
  priority, decides a bone, or the engine changes priorities per section. The files do not say
  which.
- The section census rules out the section as a bone mask: Upper Body KFs key the legs. A KF's
  priorities instead look like its own mask, high on the bones it means to move (the head at 93
  in `HeadUpGreet.kf`) and low on the rest, so another sequence at a higher priority can take
  them. The absolute values still lose to a walk's 27 to 55 under the cascade alone. Either the
  engine raises an IDLE's priorities, or a walk is not playing while an IDLE does.

## Design

### Why not AnimationPlayer or AnimationTree

`AnimationMixer` (the base of both) blends every track by weight. An `AnimationTree` blend node
has a fixed per-track filter, on or off. Neither picks per bone and per frame the track with the
highest priority among the playing clips. `ActorAnimator` drives one `AnimationPlayer` and plays
one clip at a time.

### KfAnimator

Our own animator, in C++ (GDExtension, `native/src/`): a node that writes the skeleton's bone
poses, in the place `AnimationMixer` holds, not a `SkeletonModifier3D`. GDScript only picks clips
per slot and reacts to text keys. Per frame the work is bones × slots × actors (about 60 to 80
bones on a humanoid); `Plans/Actors/actor_performance.md` has animation among the largest
per-actor costs with 190 and 1,342 NPCs.

**Modifiers run on top of it.** `Skeleton3D` (Godot 4.7.2, `scene/3d/skeleton_3d.cpp`) saves
every bone pose before running its `SkeletonModifier3D` children in order, and restores the
saved poses after the frame is drawn. A modifier's result lasts one frame; the pose it starts
from is whatever was written with `set_bone_pose_*` beforehand. So:

- `KfAnimator` writes with `set_bone_pose_*` before the skeleton updates. On frames its update
  interval skips, the last written pose stays, as it would not if it were a modifier.
- IK modifiers (weapon holding, first-person hands) and `LookAtModifier3D` (head) are children
  of the `Skeleton3D` and run after it, each from the pose before it in child order.
  `LookAtModifier3D` at influence 1 replaces the head's rotation; below 1 it blends with the
  animated pose.
- A bone a modifier sets is not something `KfAnimator` resolves differently; priority applies
  only between KF slots.

- **Slots.** One per animation group section: Idle, Movement, Weapon, Special Idle, Whole Body,
  Upper Body. A slot plays at most one KF with its own time, speed and loop state.
- **Tracks.** A clip holds, per bone, a transform track and that controlled block's priority
  byte. Bones a clip does not key are absent, not held.
- **Per-bone resolve.** For each bone channel, the playing tracks that key it take the weight
  highest priority first: a priority's tracks share the weight still unclaimed (their fade
  weights), and the rest passes to the next priority down. Weight no priority claims is shared
  among the tracks in proportion, so a clip fading out alone holds its pose. Equal priorities
  blend by weight, or the newest clip takes them (`tie_mode`). A bone no clip keys is not
  written.
- **Cross-fade.** Changing a slot's clip fades the old clip out and the new clip in over the
  blend time (`Blend:N`, `BlendIn:N`, `BlendOut:N`; a default when the clip has none). While
  fading, both are candidates at their own priorities, weighted by the fade.
- **Loops.** `startloop` / `endloop` bound a loop section with an intro and an outro;
  `cycle type` decides whether a clip without them loops.
- **Text keys.** Fired as signals (`sound:`, `hit`, `a:`, `m:`, ...) for the actor to act on.
- **Root motion.** Bip01 and Bip01 NonAccum are reported to the actor and not applied, as in
  locomotion now; idles that carry the body (furniture) apply them as `ActorAnimator` does.
- **Face.** Face morph tracks stay as `ActorAnimator.face_weights()`.
- **Update interval.** Each animator has an adjustable update interval: it writes poses every
  Nth frame with the accumulated delta, or not at all while paused (time still advances, so a
  clip is in the right place when it resumes). Text keys fire from the clip clock, not the pose
  update, so sounds and hits keep their timing at any interval. Choosing the interval from
  distance or visibility is a later caller of this setting.
- **Clip data.** A clip is decoded once into flat per-bone key arrays, shared by every actor
  with the same skeleton; an animator holds only times, weights and the bone map.

### Test scene

`project/_diag/kf_animator_test.tscn`: one actor (a humanoid NPC_ by EditorID) on a floor with a
camera, built without a cell or streaming so it starts and stops in seconds. It carries a
`LookAtModifier3D` and an IK modifier on the skeleton, toggled, to check they apply over the
animated pose at every update interval. Debug controls pick a
KF per slot, scrub or pause, and set the update interval. Used for visual checks (a gesture over
a walk, a seated idle, cross-fades) and for timing one animator.

### NifServer

NifSource reads the controlled block priority byte and returns it per track with the KF.
This is a NifServer contract change: its own change, with a census and a test in
`tests/servers/`.

## Root bones

From `native/tools/kf_root_census` over the 770 readable KFs that an IDLE under
`characters\_male\` names, or that sit in `locomotion\`: Bip01 and Bip01 NonAccum at each
clip's start and end (keys, or the interpolator's static pose), yaw about the parent's Z.

- Bip01 never rotates: on all 349 clips that key it, its yaw is 0 at start and end. It carries
  translation only: walks and runs move it 1.1 to 4.0 m over the clip, section 20 enters and
  exits 0.4 to 1.3 m, turns and gestures 0.
- Bip01 NonAccum is keyed on every clip. Its standing stance is yaw 90 at about 0.95 m (342 of
  the Special Idles end there). The turn clips (`mtturnleft.kf`, `mtturnright.kf`) end at the
  yaw they start.
- 79 clips change NonAccum's yaw by more than 10 degrees, 34 of them section 20 and 37
  section 7: the furniture and bed enters and exits.
- A chair enter, seated loop and exit:

  | KF | NonAccum start | NonAccum end | Bip01 start | Bip01 end |
  |---|---|---|---|---|
  | `chair_forwardenter.kf` (20) | yaw 85, 0.96 m | yaw -90, 0.53 m, tilted 50 | 0, -0.02 m | 0, 0.78 m |
  | `dynamicidle_chairsit.kf` (0) | yaw 90, 0.53 m, tilted 50 | same | not keyed | not keyed |
  | `chair_forwardexit.kf` (20) | yaw -90, 0.53 m, tilted 50 | yaw -95, 0.96 m | 0, 0.78 m | 0, -0.02 m |

  The exit starts exactly where the enter ends. The seated loop starts at the stance yaw (90),
  180 degrees from both, with Bip01 at the clip origin. `chairchild_` and `chairskirt_` pairs
  match.
- skeleton.nif rests Bip01 at 0.968 m and 90 degrees with NonAccum at identity; the KFs put
  Bip01 at the origin, unrotated, with the stance on NonAccum.

### Tried in the test scene

`_diag/kf_animator_test.tscn`, "Sit, card point, stand" (`Chair_ForwardEnter.kf`, the seated loop
`DynamicIdle_ChairSit.kf`, `SpecialIdle_CardPoint01.kf` over it, `Chair_ForwardExit.kf`), under
KfAnimator's root motion modes, each clip measured from its own start:

| Mode | Enter | Seated loop | Exit |
|---|---|---|---|
| None | sits correctly | turned 180 degrees | correct; snaps 180 degrees when it ends and locomotion returns |
| Bip01 translation | as None | as None, and jumps 0.78 m back | as None, and jumps |
| Bip01 + NonAccum yaw | correct, the actor turning and moving | correct | faces the chair |
| Root transform | correct | correct | correct; ends at the start, facing away from the chair |

Root transform takes the root as one transform, Bip01's translation then NonAccum's facing (its
X axis against Bip01's +Y, the stance yaw 90); each clip moves the actor by that transform's change
since the clip started, composed as a transform, and is drawn with all of it taken out (Bip01 at
the origin, NonAccum turned to the stance). In the test scene it plays the whole sequence
correctly with no furniture handling; the actor ends 0.00 m from its start, turned 180 degrees.
The other modes fail because they take translation and yaw apart: the exit's Bip01 runs from
0.78 m to -0.02 m along the enter's facing, not the seated actor's.

No per-clip reading of the root bones plays all three. The enter and the exit are authored in
one frame (the exit starts where the enter ends); the seated loop, and what plays over it, in the
frame of an actor on the seat facing out.

### Tested guesses, in the game

Both are implemented and played correctly in `_diag/kf_animator_test.tscn`; neither is checked
against the original game, and the code says so where it acts on them.

- **Root motion (Root transform).** The root is one transform, Bip01's translation then
  NonAccum's facing against the stance yaw 90 (read from the census, not engine data); each clip
  moves the actor by its change since the clip started and is drawn with all of it taken out.
  `ActorAnimator` runs its KfAnimator in this mode for every clip, locomotion included, and
  reports an idle's step each frame as `root_moved` (not locomotion's, the controller moving the
  actor while it walks, and not a clip started from its end, the actor being past it).
  `NpcController` and `PlayerController` move themselves by it and write the reference;
  FurnitureSeating no longer turns the actor on standing up.
- **Whole Body ends other idles.** An idle of section 20, once it plays, ends the idles in every
  other slot: the chair exit ends the seated loop, which at priority 35 otherwise outranks
  standing (`mtidle`, 10) when the exit ends. Read from the section's name.

## Next

1. Measure in a crowd: only one actor's pose write is timed (7.9 to 20.3 us headless, 1 to 3
   clips, before root motion); compare against `tools/Tracy-Profiles/190 NPC's.tracy` and the
   `DebugActorCost` numbers.
2. Connect the update interval: `KfAnimator.update_interval` is set by nothing in the game;
   ActorAnimator exposes no rate and nothing chooses one from distance or visibility, so every
   actor writes its pose every frame.
3. Looping clips with root motion: the motion is measured from the clip's start, so each wrap
   steps back by a whole cycle.
4. Idle fades: fixed 0.2 s or the KFs' blend keys (`fade_from_text_keys`, off), not settled.
5. Check in play: whether a seated NPC's talk gesture moves only the arms, and whether a walking
   NPC's gesture keeps the legs walking.
