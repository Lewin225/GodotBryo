# First person: session notes

Companion to [first_person.md](first_person.md) and [animation_blending.md](animation_blending.md):
the state of the work, the decisions with their reasons, what was tried and dropped, and the
traps hit. For picking the work up without the session that produced it.

## State

- Branch `first-person-rig`, based on `kf-track-priority` (not `master`: `master` lacks the
  static-pose fix and the new ActorAnimator, and a rig on it gets clips with no arm tracks).
- `kf-track-priority` commits, not pushed, not merged:
  - `a39c1dd` NifServer returns each KF track's controlled block priority (`nif_track_priorities`,
    `nif_face_track_priorities`).
  - `4dc8216` NifServer holds a link's static pose on channels without keys (53,157 links in 4,256
    KFs were dropped before; `kf_static_pose_census`).
  - `887d835` KfAnimator (`native/src/animation/kf_animator.{h,cpp}`).
  - `3c0cc4d` ActorAnimator through KfAnimator; idles per slot; root motion moves the actor.
  - `3b5080e` `animation_blending.md` and census tools.
- Uncommitted on `first-person-rig`:
  - new: `GodotBryo/Types/Node/first_person_rig.{gd,tscn}`; `_diag/first_person_test`,
    `_diag/diag_kf_blocks`, `_diag/diag_doc_idles`,
    `_diag/diag_kf_static_tracks`; `native/tools/kf_first_person_pairs.cpp`,
    `kf_first_person_keys.cpp` (the first-person / third-person clip comparisons).
  - modified: `player/player_controller.gd` (rig `follow()` in `possess()`, `_camera_eye_height`,
    `place_at_camera` after the camera is set), `player/player.tscn` (one `FirstPersonRig` instance,
    three lines; the user's file, the user commits it).
- `_diag` scenes and one-off tools are not committed (project convention).

## KfAnimator in brief

C++ node writing bone poses with `set_bone_pose_*` (not a SkeletonModifier3D: Skeleton3D restores
poses after its modifiers each frame, so IK and LookAtModifier3D run on top of what it writes).
Slots keyed by animation group section; `play(slot, animation, fade, keep_root, speed)`; per bone
channel the highest priority takes the weight, the rest passes down, unclaimed weight is shared
among the clips keying the bone (a lone fading clip holds its pose). Every clip fades in, empty slot
or not. Loop sections with counts; `clip_finished` and `text_key` emitted after the slots advance.
`update_interval`, `paused`, `tie_mode` (Blend / Newest). Root motion modes; ActorAnimator uses
`ROOT_TRANSFORM` with `root_motion_excluded_slot = 1` and `consume_root_motion()`.

## Decisions and why

- **Root motion = Root transform** (tested guess): the root is Bip01's translation then NonAccum's
  facing against the stance yaw 90; each clip moves the actor by its change since the clip started;
  drawn with the whole root taken out. The only reading that plays Doc's chair enter, seated loop and
  exit correctly; the per-channel readings fail on the exit. Seated, the reference stays at the
  furniture marker; the controller moves.
- **Whole Body (section 20) ends the other idles once it plays** (tested guess): the chair exit ends
  the seated loop, which otherwise outranks standing when the exit ends.
- **No special cases** in the animation system: the user rejected a caller flag (`ends_others`) and
  furniture-specific turns; rules must hold for every clip.
- **The rig wears the actor's meshes** (fetched from the possessed actor), not the `*1st.nif` hands.
- **The rig is a scene with real nodes**, not a script building everything, so it can be inspected;
  `@tool` with a Preview.
- **No third-person walks on the rig**: they took the arms (priority 30 against the idle's 20) and
  their static spine poses broke the upper body; a walking body is the third-person model's to show.
- **Lockstep with the camera**: PlayerController places the rig straight after the camera; the rig
  is `top_level` (as a plain child, mouse-look turning the body after placement swung it off the
  camera). Physics interpolation is irrelevant (only the CharacterBody3D is physical; the camera is
  a top-level child lerping behind it).
- **Two modes, actor authoritative** (see the Shape in first_person.md). Considered and dropped:
  - IK on the third-person body following the first-person rig's hands in classic mode: the user
    judged IK would not follow an animation well, and the classic clips pose the whole arm.
  - Third-person weapon clips for the viewmodel: the first-person clips are a separate pose (see the
    census), framed for the eye.
  - A shadow from the rig: it is deformed for the view; the third-person body casts the shadow.
  - Warping the actor body for desktop: its shadow would show it.
- The user has a procedural hand and weapon system from another project (desktop and VR); classic
  animations stay for players and modders who want them (the originals are widely thought poor).

## Traps hit

- Skinned vertices in Godot are placed by the MeshInstance3D's own global transform times the
  bones in skeleton space (`skeleton_3d.cpp`: `global_pose * bind`). The actor's part roots
  (`NudeBody`, `Equipment`) carry NifServer's Z-up conversion, so copies must keep their source
  mesh's transform relative to the actor's skeleton; using the Body frame laid the rig flat
  (the user's "x -90" workaround).
- Runtime-added nodes have no owner in the editor, so they are not in the Scene dock and a
  Skeleton3D shows no bone gizmo.
- `TwoBoneIK3D` skips a setting without a pole node.
- A bone pose read after the frame is the restored one; read modifier results on `skeleton_updated`.
- `EsmActorNode` starts watching equipment in `_ready`: set its reference before adding it; a
  preview reference made from a base has no inventory, so use the placed reference
  (`DocMitchellREF`).
- New `class_name` scripts need `--headless --editor --quit` before a headless run finds them.
- Test runs: watch the log and act on the result line (`Monitor`, or an until-loop), kill Godot
  after; several tests hang on quit. `test_player_seating` (and `test_head_tracking` on the old
  animator) carry known camera failures noted in animation_blending.md.

## Probes

- `_diag/first_person_test.tscn` with `FP_TEST_PROBE=1`: the rig on Doc, what it wears, bone
  positions and rests, clip tracks against skeleton bones, priorities per slot, the motion-to-clip
  choice.
- `_diag/diag_kf_blocks.tscn` with `KF_BLOCKS_PATH=<kf>` (and `KF_BLOCKS_MOVING=1`): a KF's
  controlled blocks as NifSource reads them.
- `animation_viewer.tscn` (launcher: Animation viewer): an NPC picked by EditorID on a floor with every slot, root motion modes, the sit and
  seated-idles sequence.

## Gaps carried from the animation work

- No crowd performance measurement (one actor: about 8 to 20 us a pose write headless).
- `KfAnimator.update_interval` is set by nothing in the game.
- Looping clips with root motion step back a cycle at each wrap.
- Idle fades: fixed 0.2 s or the blend text keys (`fade_from_text_keys`, off); unsettled.
- Three committed diags still look for the removed `LocomotionAnimationPlayer`
  (`diag_idle_facing`, `diag_creature_builds`, `diag_skeleton_bones`).
