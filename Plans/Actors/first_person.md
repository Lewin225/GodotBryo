# First person

The first-person view: the skeleton, clips and viewmodel that make the player's hands and held
weapon, and how they stay in step with the third-person body. Session notes, the state of the
branch and the reasoning behind the shape are in [first_person_notes.md](first_person_notes.md).

## Facts

From the archives and FalloutNV.esm (`_diag/diag_kf_camera1st`, `diag_idle_1stp`,
`diag_1stperson_files`, `diag_1stperson_rig`, `diag_kf_bones`, `diag_nif_node_transforms`,
`diag_kf_blocks`, `first_person_test`, `native/tools/kf_first_person_pairs`,
`kf_first_person_keys`, and a Python scan of every WEAP, STAT, ARMO, ARMA and RACE subrecord).

### Skeleton

- `meshes\characters\_1stperson\skeleton.nif` is the only NIF under `_1stperson\`. NifServer
  returns it as plain nodes (no Skeleton3D); built from them (`ActorSkinning.build_skeleton_from_nodes`)
  it has 74 bones.
- Its chain: `Scene Root`, `Bip01`, `Bip01 NonAccum`, `Bip01 Looking`, then `Bip01 Translate`,
  `Bip01 Rotate`, `Bip`, `Bip01 Pelvis` and the biped below; `Camera1st` hangs from
  `Bip01 Looking`. `Bip01 Looking` sits 1.686 m up (local), `Bip01 Translate` 1.686 m down from it:
  the body hangs from the eye. The hands carry `Bip01 L/R Hand01` to `Hand04` and `Weapon` (right).
- Rest poses match the third-person `_male\skeleton.nif` bone for bone in skeleton space below
  the root (pelvis, spine, arms, thighs: same position, 0 degrees apart); only `Bip01` differs (at
  the origin, unrotated, against the third person's 0.968 m and 90 degrees).
- Every bone that Doc Mitchell's 49 skinned meshes (body, skinned head parts, equipment) bind
  exists on it.

### Clips

- 376 KFs directly in `_1stperson\` (plus `locomotion\`); 370 have a same-named KF in `_male\`, none
  byte-identical. The other six: `mtidle`, `mtturnleft`, `mtturnright`, `2hhjama`, `2hhreloada`,
  `pipboychild`.
- Of the 370 pairs, 364 have the same length. Of 14,289 bones both versions animate, 1,587 (11%)
  carry the same local pose within 1 degree and 1 mm at 11 samples across the clip; no pair matches
  on every shared bone, 145 match on none. The spine differs most (147 to 155 degrees on most
  clips), then `Weapon` (138 to 177) and the weapon's parts (`##GFPin` 168). The first-person clips
  are separately posed, on the third-person clips' timing; not slices of them.
- First-person clips key `Bip`, the `Hand01`-`Hand04` bones and the `##` weapon parts
  (`##LighterFlame`, `##batonhandle`, `##PGRing`, ...), which the third-person versions do not; the
  third-person versions key 12 to 34 targets the first-person ones do not.
- The first-person walk and run clips (`_1stperson\locomotion\mt[fast]{forward,backward,left,right}.kf`)
  key only `Bip01`'s translation (`mtforward.kf`: 2 controlled blocks). The standing idle and the
  turns are in `_1stperson\`'s root (`mtidle`, `mtturnleft`, `mtturnright`), not its `locomotion\`.
- Paths: 471 of the 2,256 KFs below `_male\` have a KF at the same relative path below `_1stperson\`;
  30 more share a file name in another folder (the `locomotion\male`, `female` and `child` variants,
  8 each, against `locomotion\`; `mtidle` and the turns, and their `hurt\` variants, against the
  root). 13 `_1stperson\` KFs share neither path nor name with a `_male\` one (BSA listing).
- `_1stperson\mtidle.kf` (`Idle`, 4 s, 68 controlled blocks): the clavicles, upper arms,
  forearms and neck by static pose only (no keys), hands and fingers keyed, `Camera1st`,
  `Bip01 NonAccum`, the spine. It bends the spine back: Spine1 23, Spine2 26 and the head 27
  degrees from rest.
- Priorities: first-person `mtidle` 20 on the upper arm and Spine1; `2haaim` (first person) 45;
  the third-person walk 30.
- `Bip01 Looking` (`native/tools/kf_bip01_looking_census`, all 442 `_1stperson\` KFs in every
  BSA, 0 parse failures): 4 KFs have a controlled block on it (`Camera1st`: 332, `Bip01 NonAccum`:
  422). None has rotation keys. `h2hstomp.kf` has translation keys (B-spline, 132 resampled keys);
  `2hrattack7.kf`, `2hrattack7is.kf` (DeadMoney) and `sneakmtidle.kf` are NiTransformInterpolators
  with no keys whose stored transform is the unset sentinel (rotation -3.4028e38 on all components,
  translation -4.86e36), read from nifly, raw bytes not checked. So no clip turns `Bip01 Looking`.
- In every clip checked, `Camera1st` has a rotation track and no position track, except the
  scripted player clips, which move it:
  - `specialidle_nvcg01playerwakeup.kf`, `...situp`, `...bedsit`, `...standup` key only
    `Camera1st` (position and rotation); the wake-up also holds static poses (no keys) on the neck,
    clavicles, upper arms and forearms (15 controlled blocks; 30 tracks from NifServer). Wake-up holds about 1 m down and to the side of
    the rest pose; stand-up ends at the rest pose (0, -0.053, 0).
  - Others: `cg00playersection00-05`, `cg04playerwaking`, `mq08playercaptured`,
    `specialidle_nvopen_playerknockdown`, `...playerpickedup`, the DLC `*1stperson*` clips.
- VCG01 (the opening): stage 0 runs `player.addscriptpackage VCG01PlayerSection0`, stage 5
  `player.addscriptpackage VCG01PlayerSection1`, stage 7 adds VCG01PlayerSection1 again ("it
  triggers the OnChange animation"), stage 50 (0x32) `player.removescriptpackage` ("turn off the
  animated cam"). The packages (PKDT type 6), their idles and KFs:
  - VCG01PlayerSection0: On Begin LooseVCG01PlayerWakeup; IDLA Wakeup, Situp (IDLC 2, IDLF 1).
  - VCG01PlayerSection1: On Begin LooseVCG01PlayerSitup, On Change LooseVCG01PlayerBedsit; IDLA
    Bedsit.
  - VCG01PlayerSection2 (not added by VCG01's stages): On Begin LooseVCG01PlayerStandup; IDLA Situp.
  - Their MODLs are `Characters\_Male\IdleAnims\SpecialIdle_NVCG01Player*.kf`: the files are
    under `_male\idleanims\` only, none under `_1stperson\`. Their keys are on `Camera1st`, which
    the third-person `_male\skeleton.nif` does not have (nor `Bip01 Looking`); the static neck and
    arm poses bind on it, so the actor plays the wake-up.
  - So the camera clips are addressed to the player's actor, as ordinary third-person idle paths,
    and only the first-person skeleton can play them.
- The IDLE tree picks first-person clips through conditions `GetIsID Player == 1` and
  `IsPC1stPerson == 1`, beside the third-person idle under the same parent
  (`ChairDynamicIdle1stPerson`, `StoolDynamicIdle1stPerson`, `1stPHit*`, `PipboyWaver*`, ...).
  `IsPC1stPerson` (condition function 392) is named in `script_condition_functions.gd` but not
  evaluated.

### Meshes

- Hands: `characters\_male\lefthand1st.nif`, `righthand1st.nif` and female and Pip-Boy-glove
  variants, each matching its third-person file with `NiSkinInstance` in place of
  `BSDismemberSkinInstance`. No record names them except one ARMO `MOD3`. Not used: the rig wears
  the actor's own meshes.
- No first-person upper body or armour files exist.
- WEAP `WNAM` names a STAT on 179 of 261 WEAP; in the samples checked its MODL is the WEAP's own.

## Built (branch `first-person-rig`, uncommitted)

- KfAnimator sync mode (`native/src/animation/kf_animator.{h,cpp}`): `play(..., path,
  source_serial)` returns the start's serial; `announce()`; `clip_started` / `clip_stopped`;
  `get_start()`, `get_started_slots()`; `sync_source`. `KfClipSync`
  (`GodotBryo/Types/Node/kf_clip_sync.gd`): the loading half, `path_remap` (the default sends
  `_male\` to `_1stperson\`, with `mtidle` and the turns to the root). ActorAnimator passes each
  idle's and locomotion clip's path, and announces an idle it cannot play.
  `tests/test_kf_animator_sync.tscn`.
- `FirstPersonRig` (`GodotBryo/Types/Node/first_person_rig.{gd,tscn}`, `@tool`): scene nodes
  `SkeletonModel`, `Meshes`, `KfAnimator`, `KfClipSync`. Builds the first-person skeleton at
  runtime; `follow(actor)` copies the actor's skinned meshes onto it (each copy keeps its source
  mesh's transform relative to the actor's skeleton, follows its source's visibility, casts no
  shadow; no head parts, no mesh bound only to head bones) and follows the actor's KfAnimator once
  the skeleton and the actor's animation are loaded. It no longer chooses clips of its own. Editor
  buttons Preview / Clear Preview (owns the preview skeleton for the Scene dock; clear before saving).
- `FirstPersonViewPitch` (a SkeletonModifier3D on the rig's skeleton) fits the body to the view:
  the clavicles and `Bip01 Neck` take their animated world pose (the clips' framing, spine bend
  included) turned by the view's pitch about `Camera1st`, around the view's right axis (BODY look
  mode only); then the spine (`Bip01 Spine`, `Spine1`, `Spine2`) goes back to rest. The pelvis and
  legs keep their pose and the skin between spine and shoulders stretches. `Bip01 Looking` is not
  turned (the body hangs from it) and is in the rig KfAnimator's `disabled_bones`
  (`FirstPersonRig.held_bones`). Holding the spine in the animator instead left the arms posed for
  a bent spine. Pitch checked headless (`_diag/diag_rig_pitch`): at ±0.5 rad the hand swings about
  the eye, the pelvis stays at 0.968 m, the camera offset stays at identity.
- The camera follows the rig's `Camera1st` as an offset from rest on top of its own transform; the
  rig stays placed at the camera (`top_level`), not parented to the body.
- `PlayerController.first_person_rig` (export, null for none): `possess()` calls `follow()`, and
  `_update_camera_transform()` calls `place_at_camera(camera, _camera_eye_height)` after setting the
  camera. The rig is still `top_level` and placed at the camera (the body-parented shape is not
  built yet).

## Shape (agreed)

- **Input goes into the actor.** A controller (NpcController's AI, or the player) gives its actor an
  input packet: movement, look, actions (equip, fire, reload, ...), and for a VR client hand poses.
  The player's packet is what is networked.
- **The actor animates itself.** ActorAnimator turns the input into clips on the third-person body:
  locomotion, weapon actions in their slots. NPCs hold and fire weapons through the same code.
- **The third-person body is the shadow and the body others see,** in every mode. The first-person
  rig never casts a shadow (it is posed for the eye).
- **The actor reports what it is asked to play.** KfAnimator signals `clip_started(slot, path,
  animation, serial, fade, keep_root, speed)` and `clip_stopped(slot, fade)`. `path` is the clip's canonical KF
  path; `serial` names the start. A clip the actor cannot play (the KF is missing, or keys none of its
  bones, as a `_1stperson\` clip on the third-person skeleton) is still announced, with nothing
  playing in the slot.
- **Viewmodels mirror it.** A swappable viewmodel component on the player:
  - *Classic*: FirstPersonRig, a KfAnimator in sync mode on the first-person skeleton. No IK: the
    first-person clips pose the whole arm.
  - *Procedural / VR*: the input's hand poses drive IK modifiers on the third-person body's arms; the
    first-person rig is not used.
- **Sync mode (clip and time).** A follower KfAnimator has a `sync_source` (another KfAnimator) and a
  path remap (directory pairs, `characters/_male/` to `characters/_1stperson/`):
  - *Clip*, by `KfClipSync.mode`: *Same clip* plays the start's own Animation; *Remapped* loads the
    remapped path (a path no pair matches as it is) and, when that KF is missing, plays the start's
    own Animation if it keys a bone the follower has and the source lacks (`filter_fallback`; off,
    always). To be revisited for weapon idles. Same slot, fade and speed; on `clip_stopped` it stops it. A
    start with nothing to play leaves the slot empty.
  - *Time*: a follower clip whose source start is still the current clip of the source slot takes
    the source clip's time each frame (no drift; loops, seeks and speed follow). A start the source
    only announced runs on the follower's own clock.
  - *Events*: a follower clip that takes its time from the source emits no `clip_finished` or
    `text_key` (the source's are the ones game logic hears); one on its own clock emits both.
  - The follower keeps its own root settings (the rig drops Bip01 and NonAccum).
  - So the bed wake-up works with no player-only call: the actor plays its `_male\` KF (the static
    arm poses; the shadow body is all that shows them), and the rig, with no `_1stperson\` file for
    it and keying `Camera1st`, plays the same clip.
  - A new game runs its startup script once the player's actor is built and animated
    (`game.gd`): VCG00 stage 100 sets VCG01 stage 0, whose package plays the wake-up at once, and an
    idle given to an actor node with no animator is dropped.
  - Stage 3's `DocMitchellREF.SayTo player` gave the player a listen gesture (Idle Manager pick,
    section 7) that replaced the looping wake-up. ASSUMPTION (`ActorIdles._play_dialogue_idle`,
    no data behind it): dialogue gestures do not replace an idle a script (PlayIdle) or package
    event asked for; they replace ambient picks, collections and earlier gestures.
  - `KfAnimator.disabled_bones`: bones never written, whatever keys them (to keep a follower's
    clips off bones it should not move).
- **The camera follows `Camera1st`.** The rig is placed at the camera each frame (lockstep), and the
  camera takes `Camera1st`'s change from rest on top of its own transform (vertical lerp, bob, lean,
  shake), so clips that move the bone move the view. Physics interpolation keeps the body smooth at
  144 fps (an even per-frame step at 144 frames to 60 ticks); the camera's horizontal catch-up lerp
  is removed.
- **Scripted camera sequences** (VCG01 bed wake-up and the other `*player*` clips, which key only
  `Camera1st`): the first-person skeleton plays the clip and the camera locks to `Camera1st`.

## Next

1. Weapon actions on ActorAnimator: the clip for the equipped weapon's type and state (aim, fire,
   reload, equip) in the weapon slots, which the rig follows through the sync. Needs weapons.
2. Input packets from the controllers to the actor (movement, look, actions; the player's is the
   networked one).
3. NifServer: issue #91, keyless interpolators holding the unset sentinel.

## Open

- Look mode: HEAD (mouse look turns the camera about its own position, the body keeps its heading)
  while the possessed actor plays a scripted idle (`ActorIdles.is_playing_scripted`), else BODY.
  Combat knockdowns, when built, come from the knocked state rather than an IDLE and need their own
  HEAD trigger. Keying HEAD on `Camera1st` leaving rest alone is not enough (weapon firing may move
  it). The HEAD camera may need a lerp to hide the switch.

- A follower's clip is requested from NifServer when the source starts, so it fades in a frame or
  more late; time follow puts it at the source's time once loaded.
- Whether a clip only the follower plays (the wake-up) should report its end to the actor, for
  scripts that wait on the idle.
- Whether PackageRunner runs the player's script package in game is not checked
  (`test_actor_idles` adds VCG01PlayerSection1 to Doc).
- Where the rig is placed while seated, lying or in dialogue (the head-follow camera mode does not
  call `place_at_camera`).
- Whether the classic mode shows the third-person legs below the rig (the torsos will not line up:
  the first-person spine is posed back).
- The rig's `place_at_camera` uses the camera's eye height above the body each frame; crouch and
  steps follow the camera's own lerp.
