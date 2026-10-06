# First person

The first-person rig: the skeleton, meshes and clips that make the player's view, hands and
held weapon. Built with weapons and viewmodels, not before. Until then the seated and dialogue
camera follows the third-person body's head (`PlayerController._update_head_camera`).

## Facts

From the archives and FalloutNV.esm (`_diag/diag_kf_camera1st`, `diag_idle_1stp`,
`diag_1stperson_files`, `diag_1stperson_rig`, `diag_kf_bones`, `diag_nif_node_transforms`, and a
Python scan of every WEAP, STAT, ARMO, ARMA and RACE subrecord).

### Skeleton

- `meshes\characters\_1stperson\skeleton.nif` is the only NIF under `_1stperson\`.
- It is a full biped plus `Camera1st`, `Bip01 Translate`, `Bip01 Rotate` and `Bip01 Looking`.
- `Camera1st` sits at the origin, local (0, -0.053, 0). `Bip01 Translate` sits 1.686 m below it.
  The skeleton hangs from the eye: the camera is at the root and the body is offset down.
- The third-person `_male\skeleton.nif` has no `Camera1st`; it has `Camera3rd`, local origin
  (0, -0.053, 1.691).
- About 50 bone names are shared between the two skeletons. This count comes from a string scan of
  the files, not a parse; the exact set is unverified.

### Clips

- 4,765 KFs under `meshes\`; 370 name `Camera1st`, all in `characters\_1stperson\` (and its
  `locomotion\` folders) or player clips in `characters\_male\idleanims\`.
- `_1stperson\` holds 376 KFs (plus 66 in `locomotion\`). For each weapon type there are aim,
  attack, equip, unequip, holster, reload, jam and hand-grip clips; there are also locomotion, sneak,
  swim and Pip-Boy clips (`1hp*` one-hand pistol, `2hr*` rifle, `2ha*` automatic, `2hh*` heavy,
  `2hl*` launcher, `1hm*` / `2hm*` melee, `h2h*` unarmed, `1gt*` thrown, `1lm*` / `1md*` mines,
  `mt*` no weapon, `pipboy*`).
- `1hpaim.kf` (2.47 s, looping, 88 tracks): both clavicles, upper arms, forearms, hands and every
  finger, the neck, spine, pelvis and `Bip01 NonAccum`, `Camera1st` rotation, and about 35
  `##`-prefixed nodes (`##357Hammer`, `##cmClip`, `##ThatTrigger`, `##LaserSightBeam`, ...). The
  `##` nodes are moving parts inside weapon NIFs: one clip animates arms, weapon and camera sway.
- `mtidle.kf` (4 s, looping, 84 tracks): the same arm set and `Camera1st` rotation.
- In every clip checked, `Camera1st` has a rotation track and no position track, except the
  scripted player clips, which move it:
  - `specialidle_nvcg01playerwakeup.kf`, `...situp`, `...bedsit`, `...standup` have only two
    tracks, `Camera1st` position and rotation. Wake-up holds about 1 m down and to the side of
    the rest pose; stand-up ends at the rest pose (0, -0.053, 0).
  - Others: `cg00playersection00-05`, `cg04playerwaking`, `mq08playercaptured`,
    `specialidle_nvopen_playerknockdown`, `...playerpickedup`, the DLC `*1stperson*` clips.
- The IDLE tree picks first-person clips through conditions `GetIsID Player == 1` and
  `IsPC1stPerson == 1`, beside the third-person idle under the same parent:
  - `ChairDynamicIdle1stPerson` (`1stP_ChairDynamicIdle.kf`) under `DefaultSitIdle`;
  - `StoolDynamicIdle1stPerson`, `NVStoolDynamicIdleNoLean1stPerson`, `PodSitIdle1stPerson`;
  - `1stPHit*` under `1stPersonHitReactions`, `1stPersonActWater`, the `PipboyWaver*` idles.
- `1stP_ChairDynamicIdle.kf` (4 s, looping): `Camera1st`, `Bip01 Translate` and `Bip01 Rotate`
  rotation only. It does not say where the seated eye is.
- `IsPC1stPerson` (condition function 392) is named in `script_condition_functions.gd` but not
  evaluated, so the player gets the third-person sit idles today.

### Meshes

- Hands: `characters\_male\lefthand1st.nif`, `righthand1st.nif`, `femalelefthand1st.nif`,
  `femalerighthand1st.nif`, `lefthandpipboyglove1st.nif`, `femalelefthandpipboyglove1st.nif`.
  Each matches its third-person file (same shape name, same texture) with `NiSkinInstance` in place
  of `BSDismemberSkinInstance`.
- No FalloutNV.esm record names a `*1st.nif` hand except one ARMO `MOD3`
  (`FemaleLeftHandPipBoyGlove1st.NIF`, form 0x025B83). RACE body parts name the third-person hands.
- No first-person upper body or arms file exists; `upperbody.nif` and armour have no `1st` variant.
- WEAP `WNAM` (first-person model) names a STAT on 179 of 261 WEAP. In the samples checked the STAT's
  MODL is the same NIF as the WEAP's own MODL. 12 NIFs under `weapons\` and DLC weapon folders are
  named `1stperson*.nif`; one WEAP MODL names one (`1stpersonCleaverU.NIF`).

## Inferred, not confirmed

- The `*1st.nif` hands are found by appending `1st` to the race's hand paths (no record names
  them).
- Upper body and armour meshes are skinned onto the first-person skeleton by bone name.
- The first-person rig is placed relative to the player's body; how it lowers when seated, lying
  or in dialogue is not in any data found.

## Shape (proposed, to agree when weapons start)

- First person is a second body for the possessed actor: the first-person skeleton with hands, arms,
  armour and the held weapon skinned to it, and the camera on `Camera1st`. The third-person body
  stays for shadows, mirrors and what other actors look at.
- `ActorAnimator` (or a first-person sibling) plays `_1stperson\` clips on that skeleton; a track
  naming a node in the weapon NIF (`##...`) drives it there.
- `IsPC1stPerson` evaluated, so the IDLE tree picks the first-person siblings.
- Scripted player clips (VCG01 wake-up and the rest) play on the same rig; they move `Camera1st`.

## Depends on this

- VCG01's opening on the bed: VCG01 stages 0, 5 and 7 add `VCG01PlayerSection0/1` (Travel,
  editor location, radius 0) whose On Begin and On Change idles are the wake-up clips above; stage
  7 re-adds Section1 to fire its On Change (the script's own comment). Those clips move only
  `Camera1st`, so the opening needs this rig.
- The seated and dialogue camera, replacing the head-follow stopgap.

## Open

- Where the engine places the first-person rig while seated, lying or in dialogue.
- How the `1st` hand meshes are found.
- The exact shared bone set between the two skeletons (parse, not string scan).
- Whether the first-person camera turns to the conversation partner.
