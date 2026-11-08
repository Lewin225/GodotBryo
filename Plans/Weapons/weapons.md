# Weapons

Weapons as objects: the weapon node and its state, its world model and viewmodel, how its clips
drive the actor and the first-person rig, and the single entry point that fires projectiles. NIF
part rigs and the VR path are in [../WeaponPrefabs/weapon_prefabs.md](../WeaponPrefabs/weapon_prefabs.md);
the first-person rig and clip sync are in [../Actors/first_person.md](../Actors/first_person.md);
co-op notes in [weapons_notes.md](weapons_notes.md).

## Facts

From the archives and FalloutNV.esm plus the five DLC ESMs. One-off census tools (not committed):
`kf_part_tracks`, `kf_len_keys`, `weap_models`, `fireweapon`, `scri_users`, `nif_nodes`.

### Reload and jam clips

- `characters\_1stperson\` holds 120 reload and jam KFs. 118 have a `characters\_male\` KF of the
  same name; `2hhjama.kf` and `2hhreloada.kf` have none.
- `_male\` also has a `sneak` version of 61 of them, which `_1stperson\` does not. `_male\` has two
  with no first-person file: `2hrreloadn.kf`, `pa2hareloade.kf`.
- Every one of the 120 keys the `Weapon` node and `##` weapon parts in both versions. The
  first-person version also keys `Bip` and `Camera1st`.
- The `##` part sets are equal in 66 pairs; the first-person set is smaller in 14, the third-person
  set smaller in 33, and each keys parts the other lacks in 7. Example, `1hpreloada`: first person
  `##Clip ##Hammer ##Slide`, third person `##Clip ##Slide`.
- Of the 118 pairs, 115 are the same length (within 0.02 s) and 32 have identical text keys.
  `1hpreloada`: `Sound: WPNPistol10mmReloadOut` at 0.20 s first person, 0.07 s third person;
  `Blend:3` against `Blend:2`.

### Clip names

- DNAM Attack Animation (offset 41; xEdit's enum: 26 AttackLeft, 32 AttackRight, 38 Attack3 ...
  162 AttackThrow8, 255 DEFAULT) names the attack clip after the family: `1hp` + 32 is
  `1hpattackright.kf` (the 10mm pistol). DEFAULT is on 4 guns; which clip it stands for is not in
  the data.
- Every WEAP in the six ESMs, against `characters\_male\`: every `<family>aim.kf` exists; the gun
  families' reload and jam clips exist (1hp 108 of 108 reloads, 106 of 108 jams; 2ha and 2hr all),
  as do nearly all gun attacks. Melee, thrown and creature weapons have no reload or jam clips
  (`h2h`, `1hm`, `2hm`, `1gt`, `1lm`, `1md`) and most of their attack names (`1hmattackleft`,
  `2hmattackleft`, `h2hattack5`) have no file: those families name attacks otherwise. 2hr misses
  17 attacks (turrets, `2hrattackloop`); 2hh misses 6 reloads (Securitron and creature weapons).
- A clip keys only some weapons' parts: `1hpaim` keys the .357 revolver's and That Gun's parts,
  none of the 10mm pistol's.

### WEAP data

- Every WEAP in the six ESMs (502) has a DNAM of at least 136 bytes (136 to 204; xEdit marks
  offset 36 on optional) and a 16-byte CRDT. 288 have NAM0: 143 an AMMO, 145 a FLST of AMMO.
- `WeaponBase` reads DNAM (Animation Multiplier, Reach, Flags 1, Ammo Use, spreads, Sight FOV,
  Projectile, Projectile Count, ranges, Flags 2, Animation Attack Multiplier, Fire Rate, Attack
  Shots/Sec, Reload Time, Jam Time, Aim Arc, semi-automatic delays), CRDT and NAM0. Rumble, VATS
  and mod fields are not read.

### Weapon actions

- xEdit's Animation Type names: 3 Pistol - Ballistic, 4 Pistol - Energy, 5 Rifle - Ballistic, 7
  Rifle - Energy; each pair shares a clip family (1hp, 2hr).
- Reload Animation is xEdit's ReloadA to ReloadZ: 17 to 19 are R, S, W. Across the six ESMs' 502
  WEAP: 0 on 266, 1 to 16 on 223, 20 to 22 on 13; none uses 17 to 19.
- Priorities (pistol): `mtidle` 10 everywhere; `mtforward` and `1hpforward` legs 30, `1hpforward`
  spine 31 and right arm 35; `1hpaim` legs 25, spine and left arm 30, right arm 35; `1hpequip`,
  `1hpattackright` and `1hpreloada` legs 26 to 27 (under locomotion's 30) and upper body 55 to
  65.
- Equip and unequip clips key `prn:` where the weapon changes bone: `1hpequip` `prn: Bip01 R
  Hand` at 0.13 s of 0.37, `1hpunequip` `prn: Bip01 Pelvis` at 0.20 of 0.47, `2hrunequip`
  `prn: Bip01 Spine2` at 0.80 of 0.83, `2hhequip` and `2hhunequip` `prn: Bip01 R Hand` at 0.97 of
  1.00. They also key `Attach` / `Detach` and `Enum: Equip` / `Enum: Unequip`.

### World model and viewmodel

WEAP `MODL` (world model) against the STAT that `WNAM` names (first-person model), over the 378
WEAP records with a `MODL` (DLC `WNAM`s resolve to FalloutNV.esm STATs). Records with no `MODL`
are creature attacks; their model is part of the creature.

| | Count |
|---|---|
| `WNAM` STAT uses the same NIF as `MODL` | 313 |
| Different NIF | 17 |
| No `WNAM` | 48 |

- Different NIF:
  - a separate first-person mesh, mostly melee (12): straight razor and unique, cleaver (and the
    Honest Hearts NPC poison cleaver), fire axe and unique (and the NPC poison fire axe), machete
    gladius, lead pipe unique, gauss rifle unique, throwing hatchet (FalloutNV.esm and the Old
    World Blues override);
  - a unique world mesh with the base weapon's viewmodel (4): holy frag grenade, Lily's carbine,
    ghost gas bomb, Hunting Revolver custom;
  - `TrapBaseball`: a baseball in the world, the frag grenade in first person.
- No `WNAM`: hand-to-hand (power fists and variants, boxing gloves and tape, Ballistic Fist,
  Saturnite Fists, Industrial Hand), NPC-only weapons (Vertibird gun, Behemoth's fire hydrant,
  Lily's sword and gauntlet, Legate's swords, slave backpack, `NVCamera`, `NVRorschach01`), and
  player weapons including Mysterious Stranger's and Miss Fortune's .44, the alien pistol and
  rifle, the shock baton, throwing knife, cattle prod, flare gun, arc welder and several DLC
  uniques.

### Weapon bone

- `_male\skeleton.nif` has one `Weapon` node, under `Bip01 R Hand`, and no holster nodes.
- `1hpequip`, `1hpunequip` and `2haequip` key `Weapon` (27, 30, 79 rotation keys).
- No holster node exists: the third-person skeleton's non-bone nodes are `Weapon`, `Camera3rd`,
  `HeadAnims`; no node on the 849 NIFs under `characters\` and `armor\` is one.
- Holstering is a text key: `prn: <bone>` parents the `Weapon` node to that bone. Each
  `<family>holster.kf` is 0.10 to 0.17 s and holds `Weapon` static at the holster offset, in that
  bone's space (`1hpholster` (0.0, 0.0, -0.2), `2hrholster` (0.3, -0.1, -0.1)), and keys `##`
  parts (hiding a laser sight beam, for one).

  | `prn:` target | `_male\` holster clips |
  |---|---|
  | `Bip01 Pelvis` | 1gt, 1hm, 1hp, 1lm, 1md |
  | `Bip01 Spine2` | 2ha, 2hl, 2hm, 2hr, pa2ha, pa2hm, pa2hr, pasneak2ha, pasneak2hr |
  | `Bip01 R ForeTwist` | h2h |
  | `Bip01 R Hand` | 2hh |

  `1mdholster` first keys `prn: Bip01 R Hand  -at none`, then `prn: Bip01 Pelvis`. The
  `_1stperson\` holster clips key `Prn: Bip01 Translate`. Meaning of `-at none`: not known.
- Equip and unequip clips move `Weapon` only 0.1 to 0.3 units in its parent's space: the hand
  carries the weapon to the holster.
- Not checked: the `prn:` keys in equip clips (the reparent back to the hand).
- `2hhholster` keeps `Weapon` on `Bip01 R Hand` and keys bool (visibility) tracks on
  `##FlamerGun`, `##GatlingLaserGun`, `##MinigunGun`, `##RIL`: the held part is hidden, not
  moved. Bool values not read.

### Heavy weapons and backpacks

- `minigun.nif`, `flamer.nif`, `lasergatling.nif`: the root carries NiStringExtraData `Prn` =
  `Weapon` (the bone the model hangs from); a rigid `Backpack` node, sibling of the gun part,
  carries NiStringExtraData `UPB` = `Bip01 Spine2`. Meaning inferred: the backpack hangs from
  `Bip01 Spine2`, the rest from `Weapon`. Not checked on other NIFs.
- Across the 362 NIFs under `meshes\weapons\`: 1,606 `UPB` strings, 17 of them a bone name of
  `_male\skeleton.nif`, every one `Bip01 Spine2` on a node named `Backpack` (the heavy weapons and
  the Shishkebab). Every one of the 180 `Prn` strings is `Weapon`. NifServer keeps them as
  `nif_string_extra_data` on the node.
- `Backpack` nodes sit at the weapon root's origin (minigun, flamer, Shishkebab); their shapes
  carry the offset.
- `lasergatling.nif`'s muzzle is `##ProjectileNode`, not `ProjectileNode`.
- WEAP DNAM Flags 1 bit 0x10 (xEdit: "Hide Backpack") is set on the 7 heavy weapons of animation
  type 8 (Minigun and unique, Gatling Laser, Flamer, Grenade Machinegun and unique,
  `HVBrokenWeapMinigun`) and on the Shishkebab; on no other WEAP. What it hides: not known (the
  heavy weapons' backpacks are drawn).
- No heavy weapon has a BIPL: the backpack is part of the weapon NIF.
- `EsmReferencePhysicaliser._make_node()` builds an `EsmItemNode` for a `WeaponReference`.

### FireWeapon

`FireWeapon` in script source (SCPT, INFO, QUST, PACK, TERM, PERK SCTX; FalloutNV.esm only) takes
a WEAP base and fires it from the calling reference. No weapon reference is involved.

| Script | Calling reference | WEAP |
|---|---|---|
| `TrapShotgunSCRIPT` | the trap (ACTI `trapShotgun`) | `WeapNVSingleShotgun` |
| `TRAPPitchingMachineScript` | the machine (ACTI `TrapPitchingMachine01`) | `TrapBaseball` |
| `RavenRockTrapLaserTripwireSCRIPT` | `flameEmitter` | `weapFlamer` |
| `VFSSilverRushWarehouseGasThrowScript` | `VFSGasFireMarker` | `WeapGrenadeGas` |
| `WeapPewPewScript` | `Owner` | `WeapNVLaserPistolUnique` |
| `DLC03TeslaChainEffectScript` | itself | commented out |
| `VCG00` | `BennyREF` | commented out (twice) |

- `traps\shotguntrap.nif` has `ProjectileNode` and the parts `##Trigger`, `##SSHammer`,
  `##sosgStock`, `##Shells`. `traps\pitchingmachine01.nif` has `ProjectileNode`.
- Every pistol, automatic and rifle NIF has `ProjectileNode` ([weapon_prefabs.md](../WeaponPrefabs/weapon_prefabs.md)),
  rotated to Gamebryo forward.
- Not checked: the calling bases of the flame emitter and gas marker.

## Shape

### Paths

- Two paths animate a weapon: classic (the holder's KF clips drive the parts) and procedural
  (a WeaponPrefab's own logic drives them; VR is one user). This plan is the classic path;
  [weapon_prefabs.md](../WeaponPrefabs/weapon_prefabs.md) is the procedural one.
- The path is a client setting, respected per possessor: each client's possessed actor uses its
  own setting; every other holder uses classic.
- Both paths share `EsmWeaponNode` and its state resource (ammo, jam, cycle) and fire through
  the same ProjectileServer request. Only what moves the parts, trigger and muzzle differs.
- WeaponPrefabs are procedural only: on the classic path a weapon always builds from its NIF.
- The procedural path needs at least IK hands on its holder, and is designed to tie into a
  procedurally animated skeleton. Design projects (not code to port): `/home/lewin/godot-npc-anim/`,
  `/home/lewin/godot-desktop-and-vr-interactions/`.

### Weapon node and state

- A weapon in the world is a reference and an EsmNode, whether held, on the back or dropped.
  Returning it to an inventory, or leaving it dropped until its cell unloads, frees the node.
- The node runs the weapon: loaded ammo, jammed, cycle state. The state is held on the weapon's
  `WeaponReference`, so it survives the node.
- An equipped weapon leaves the inventory: it is a world reference held in an equip slot, so a VR
  player can throw it and an NPC can drop it when shot. Unequipping frees the node and puts the
  reference back in the inventory (`InventoryItem.item_reference`).
- Scripts that count or check a held weapon (`GetItemCount`, `GetEquipped` and the like) must
  still see it: they read the inventory and the equip slots. Not checked: how many scripts do.
- The node takes inputs (fire, reload, ...) as signals. It works with no actor holding it.
- The weapon spends ammo, plays its sounds, ejects shells (`ShellCasingNode`, on 32 of the 66
  gun NIFs) and drops spent magazines, all internally. It reads ammo from its holder's inventory (`get_item_count(form_id)`, as script
  `GetItemCount`).
- The node fetches the weapon's sounds and creates their sound player nodes. The clip's
  `Sound:` text keys trigger them.
- The actor holds which item is readied and whether it is drawn, nothing of the weapon's own state.

### Equip slots

- An actor has three weapon slots: from the data, a right-hip short gun and a back long gun; ours,
  a left-hip short gun. Each holds a weapon node, holstered or drawn.
- The right-hip slot and the back slot are the holster clips' `prn:` bone and `Weapon` pose:
  `Bip01 Pelvis` for short guns, `Bip01 Spine2` for long guns, read from the weapon family's
  holster clip.
- A heavy weapon's `Backpack` hangs from `Bip01 Spine2` (`UPB`) and takes the back slot; its gun
  stays on the hand, hidden while holstered.
- Holstering plays the family's holster clip on the actor and the weapon. Its `prn:` target picks
  the slot (`Bip01 Pelvis` a hip slot, `Bip01 Spine2` the back slot, `Bip01 R Hand` stays in the
  hand), its `Weapon` pose is the slot offset, and its visibility tracks hide parts. No table per
  family.
- The left-hip slot is ours, not vanilla: the right-hip slot's bone and pose mirrored, made when
  the body is delivered. `# ASSUMPTION`. A holster goes to its clip's slot, else (a short gun) the
  left hip, else the inventory. The vanilla clips reach only the right hip and back: a weapon snaps to
  the left hip at the holster clip's `prn:` key, and from it at the equip clip's.
- With a heavy weapon's backpack on the back slot, a long gun goes to the inventory. A second back
  slot is possible later, not planned.
- An equip request is `InventoryItem.is_equipped` set on a weapon (EquipItem, the player's UI): the
  weapon then leaves the inventory for its slot (a stack entry first splits one runtime reference
  off).
- Drawing: a draw or fire input with nothing drawn draws the last drawn weapon; a slot's hotkey
  draws that slot's weapon (holstering the drawn one).
- Controllers drive the actor through control inputs on `EsmActorNode`: `equip_slot(index)`,
  `draw()`, `holster()`, `fire()`, `reload()`; PlayerController now, NpcController later. They will
  become one input packet type. The player's map: `fire` (left mouse), `reload` (R; held 0.5 s
  holsters), `hotkey_1` to `hotkey_9` and `hotkey_0`.
- In classic mode the slots bind to hotkeys 1 to 3; the slots can be disabled (one weapon, as
  vanilla). The slots are actor state on the `ActorReference`, saved whatever the mode, since the
  mode can change at any point. Each slot field holds its `WeaponReference`, saved as the
  instance_id; the reference itself is saved with EsmServer's runtime (or changed placed)
  references, so no inventory round-trip is needed.
- An actor without a body (low-detail simulation) keeps its slots as instance_ids only and builds
  no weapon nodes: it cannot fight.
- Classic play draws one at a time; the others stay holstered and visible. (The original hides a
  holstered pistol when a long gun is drawn: it has one active item slot.)
- The procedural path draws any pair of one-handed short guns, one short gun two-handed, or a long
  gun. VR uses the three slots for its interactions.

### Models

- The world model (`MODL`) leads: it always exists, it is what drops in the world, and the
  reference, the state resource and the weapon's script sit on it. It hangs on the holding actor.
- The viewmodel (`WNAM` STAT's model, else `MODL`) sits on the possessor: the first-person rig's
  `FirstPersonViewmodel` watches the followed actor's drawn weapon and copies it onto the rig's
  `Weapon` bone, its physics removed and its `Backpack` on the rig's `Bip01 Spine2`. Only the
  player's rig builds one. The possessed actor's own world-model weapon shows only its shadow in
  first person, as its body does.
- NPC-only weapons need no viewmodel in v0.
- Hand-to-hand weapons with no `WNAM` equip as cosmetic models.

### Clips

- The weapon is the clock and the only source of clip events (sounds, text keys): the actor, the
  rig and each model following it emit none, so a sound plays once. The clock plays the
  third-person (`_male`) version. First-person timing is left for later: if the view's sounds are
  too far off, the possessed actor's third-person animator can be disabled in first person.
- The weapon names the clip (family plus attack, reload or jam id). Each follower resolves it in
  its own library: the actor in `_male\` (or its `sneak` or `pa` version), the rig in
  `_1stperson\`.
- The actor and the rig follow the weapon's clock in the weapon's slot only and keep their own
  clock in the others. KfAnimator's `sync_source` covers the whole animator: it needs a source per
  slot.
- Clips that drive the body (heavy melee) do so through the actor's priority blend.
- Each model has its own animator, which plays its holder's clip on its own `##` parts and
  `Weapon` node (the world model the `_male` version, the viewmodel the `_1stperson` one; the two
  key different parts). The magazine follows the hand through sync alone. KfAnimator writes only
  Skeleton3D bones; the parts are `Node3D`s, so it needs `Node3D` targets.

### Firing

- One entry point creates projectiles and casts hits: a ProjectileServer, outside ScriptServer.
  The weapon node (after its ammo, jam and cycle checks), script `FireWeapon`, and NPC combat all
  call it; nothing else creates projectiles.
- A request: `fire(weapon base, shooter, muzzle transform, aim point, seed)`. It carries everything
  the server needs and nothing it must ask back for. The seed draws spread and projectile count.
- Muzzle: the shooter's model's `ProjectileNode` (`##ProjectileNode` on the Gatling Laser). The server converts its Gamebryo forward to
  Godot once. With no `ProjectileNode`, the calling reference's transform. `# ASSUMPTION`
- Direction: muzzle to aim point. With no aim point, the muzzle's forward (the reference's -Z in
  the fallback).
- Aim point, from the actor's head tracking:
  - player: a ray from the look node (the controller's camera) along its forward; where it hits,
    or a point at a fixed far distance if it hits nothing within it. Physics is not queried at long
    range;
  - NPC: the head-tracking target, with the target bone and inaccuracy applied (target
    correction). Combat owns the head-tracking target while it is active, so the NPC looks where
    it shoots;
  - no head tracking (traps, markers): none.
- The aim point is taken by the caller and sent in the request.

## Order

1. `EsmWeaponNode` on its own (`esm_weapon_node.gd`, extends `EsmItemNode`): the physicaliser's
   `_make_node()` dispatches a `WeaponReference` to it; placed from the asset browser for editor
   testing, with no actor. State on `WeaponReference`. Inputs fire, reload, aim (inspector
   buttons); a jam clears itself through the jam clip; reload with no holder fills to the clip
   size. Its own KfAnimator plays the `_male` clips on its parts: KfAnimator node targets, and
   NifServer visibility tracks (`NiVisController` bool blocks). Float and point3 tracks: #93.
2. Holding, in order:
   a. Slots: slot fields on `ActorReference` (instance_ids, the drawn and last drawn slot); an
      `ActorWeaponSlots` node in `esm_actor_node.tscn` building a BoneAttachment3D per slot
      (holster clip bone and `Weapon` pose; the mirrored left hip) and one on `Weapon` for the
      drawn weapon; each slot's `EsmWeaponNode` from the physicaliser. `ActorEquipment` stops
      building weapons.
   b. Equip and unequip: `is_equipped` on a weapon moves it from the inventory into its slot;
      unequipping puts it back.
   c. Holster and draw (snapped; motion in step 6): the holster clip's visibility tracks, the
      heavy weapons' `Backpack` on its `UPB` bone; draw and fire inputs, hotkeys 1 to 3.
   d. Script item queries (GetItemCount, GetEquipped, UnequipItem) see the slots.
3. WEAP `DNAM` and `CRDT` fields (fire rate, spread, projectiles, ammo use, attack and reload
   speed, flags), census and field docs per AGENTS.md.
4. Viewmodel: resolve `WNAM`, load it for the player in first person, fall back to `MODL`, hang it
   on the rig.
5. KfAnimator: sync source per slot (`Node3D` targets came with step 1). The weapon's animator as
   clock; weapon actions (equip, fire, reload, jam) on actor, rig and models.
   Built: `slot_sync_sources`; WEAPON_STANCE_SLOT 64 and WEAPON_ACTION_SLOT 65 (`# ASSUMPTION`);
   the actor follows the weapon's action slot and plays `<family>aim` and the family's locomotion
   while drawn; equip and unequip move the weapon at their `prn:` keys; a node-target clip keying
   no node plays as a clock.
6. Sounds: the node's sound player nodes, triggered by `Sound:` text keys.
7. ProjectileServer: the fire entry point, PROJ records, muzzle and aim points, script
   `FireWeapon`. Ammo spent from the holder's inventory, shells and magazines dropped.
8. Viewmodel motion on the classic path: procedural sway, landing and jump. Not related to the
   procedural weapon path.

## Later

- After weapons: the player's actor node stops being authored in `player.tscn` and is built for
  the possessed reference, as an NPC's is; then the actor node needs one path for its reference
  (today one set after `_ready()` skips the watches there and in the rehydrate path, covered in
  `_start_visual_load()`).
- The procedural weapon path, VR included: a separate rig system for the actor
  ([../WeaponPrefabs/weapon_prefabs.md](../WeaponPrefabs/weapon_prefabs.md)). VR weapons may need
  several clips at once.
- Co-op ([weapons_notes.md](weapons_notes.md)).
- Reporting a kill when the shot resolves, before it shows, for the kill cam (to be decided).
- Damage and hit resolution, VATS, condition and jam chance, NPC combat AI.
- Weapon mods (`WNMn`, `MWDn`): v1.
