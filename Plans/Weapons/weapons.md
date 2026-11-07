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
- No node in `_male\skeleton.nif` is named with `holster`, `back` or `side`. Holstered pistols and
  rifles on the back are seen in play, so the points exist somewhere: possibly nodes on body or
  clothing NIFs (placed per outfit against clipping), or named otherwise. Not checked.
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
  resource, so it survives the node. Stowing hands it to the `InventoryItem`; drawing hands it
  back.
- The node takes inputs (fire, reload, ...) as signals. It works with no actor holding it.
- The weapon spends ammo, plays its sounds, ejects shells (`ShellCasingNode`, on 32 of the 66
  gun NIFs) and drops spent magazines, all internally. It reads ammo from its holder's inventory (`get_item_count(form_id)`, as script
  `GetItemCount`).
- The node fetches the weapon's sounds and creates their sound player nodes. The clip's
  `Sound:` text keys trigger them.
- The actor holds which item is readied and whether it is drawn, nothing of the weapon's own state.

### Equip slots

- An actor has three weapon slots: two short guns on the belt and one long gun on the back. Each
  holds a weapon node, holstered or drawn.
- A slot hangs from the holster point where one exists (skeleton, body or clothing NIF). A slot
  with none (likely the second pistol) is a stub node the actor node adds at an offset from a bone
  when the body is delivered.
  `# ASSUMPTION`
- Classic play draws one at a time; the others stay holstered and visible. (The original hides a
  holstered pistol when a long gun is drawn: it has one active item slot.)
- The procedural path draws any pair of one-handed short guns, one short gun two-handed, or a long
  gun. VR uses the three slots for its interactions.

### Models

- The world model (`MODL`) leads: it always exists, it is what drops in the world, and the
  reference, the state resource and the weapon's script sit on it. It hangs on the holding actor.
- The viewmodel (`WNAM` STAT) is loaded only when the possessor needs it: the player in first
  person, where the first-person rig sits. The node owns it. A missing model falls back to the
  other.
- NPC-only weapons need no viewmodel in v0.
- Hand-to-hand weapons with no `WNAM` equip as cosmetic models.

### Clips

- The weapon is the clock and the only source of clip events (sounds, text keys): the actor, the
  rig and each model following it emit none, so a sound plays once. While the viewmodel is loaded
  the clock plays the first-person version and emits its keys; otherwise the third-person one.
- In first person the possessed actor's third-person animator can be disabled; it is not visible.
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
- Muzzle: the shooter's model's `ProjectileNode`. The server converts its Gamebryo forward to
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
   `_make_node()` dispatches a `WeaponReference` to it (today an `EsmItemNode`); placed from the
   asset browser for editor testing, with no actor. State resource.
2. Holding: find the holster points (body and clothing NIF census); the three equip slots on the
   actor (a bone-offset stub where a point is missing), holstered and drawn; the stow and draw
   hand-off with the `InventoryItem`.
3. WEAP `DNAM` and `CRDT` fields (fire rate, spread, projectiles, ammo use, attack and reload
   speed, flags), census and field docs per AGENTS.md.
4. Viewmodel: resolve `WNAM`, load it for the player in first person, fall back to `MODL`, hang it
   on the rig.
5. Clip names from family and ids; rules for reload ids 17 to 19 (no clip) and the anim types that
   share a family (3/4, 5/7).
6. KfAnimator: sync source per slot, `Node3D` targets. The weapon's animator as clock; weapon
   actions (equip, fire, reload, jam) on actor, rig and models; the clock switching version with
   the viewmodel.
7. Sounds: the node's sound player nodes, triggered by `Sound:` text keys.
8. ProjectileServer: the fire entry point, PROJ records, muzzle and aim points, script
   `FireWeapon`. Ammo spent from the holder's inventory, shells and magazines dropped.
9. Viewmodel motion on the classic path: procedural sway, landing and jump. Not related to the
   procedural weapon path.

## Later

- The procedural weapon path, VR included: a separate rig system for the actor
  ([../WeaponPrefabs/weapon_prefabs.md](../WeaponPrefabs/weapon_prefabs.md)). VR weapons may need
  several clips at once.
- Co-op ([weapons_notes.md](weapons_notes.md)).
- Reporting a kill when the shot resolves, before it shows, for the kill cam (to be decided).
- Damage and hit resolution, VATS, condition and jam chance, NPC combat AI.
- Weapon mods (`WNMn`, `MWDn`): v1.
