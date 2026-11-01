# Creatures

Placed creatures (ACRE, CREA) render, animate and run their packages through the same actor
node, controllers and servers as NPCs. Follow-on to
[`Completed Plans/Actors/actors.md`](../Completed%20Plans/Actors/actors.md) (its stage J), held
back until the actor refactor.

## Facts

- CREA `NIFZ` (xEdit "Model List"): 1,059 of 1,578 CREA in FalloutNV.esm; 468 of the rest are
  templated; about 51 are audio templates or spawn markers. The parts are relative to `MODL`'s
  folder, through `TPLT` when templated.
- `CreatureBase` reads NIFZ into `model_list` and `model_list_paths` (MODL's folder joined);
  not used yet. KFFZ (99 CREA, 0 NPC_) is read into `ActorBase.animations`; not used yet.
- NIFZ parts against their skeleton, every CREA through its Model/Animation template
  (`_diag/diag_creature_parts`): 1,059 creatures, 276 distinct skeleton and part pairs.
  - 138 skinned, every bind a bone of the skeleton's Skeleton3D.
  - 57 unskinned, a `Prn` NiStringExtraData on the part naming a skeleton bone (Rex's eyes).
  - 4 unskinned, `Prn` naming a node of the skeleton NIF that is not in its Skeleton3D
    (`Bip01 L Finger1` on the sentry bot, `DomeRoot` on the robobrain).
  - 6 skinned with binds the skeleton lacks, every one a node in the part itself: the
    brahmin lamp's pole, the Cazador's wings, the sentry bot's `Bip01 R Finger2`.
  - 53 on a skeleton NIF that NifServer returns without a Skeleton3D (Mister Gutsy and Handy,
    eyebots, the penthouse computer): 21 unskinned with a `Prn` naming a node of it, 32
    skinned.
  - 18 name a file no archive ships (`DLC03*`, `BrahminWater.nif`, `MMM_ghoulvariant_v1.nif`).
  - Every unskinned part carries a `Prn`.
- 2,999 placed ACRE in FalloutNV.esm, every one naming a CREA; 512 Initially Disabled; 1,887
  reach a leveled list (LVLC) through TPLT (`acre_census.py` scan).
- `EsmServer.get_all_placed_actor_references()`, NpcSimulationServer's seed list, comes from
  `EsmReader.get_all_placed_npc_actors()`: ACHR only.
- Both streamers have a CREA spawn flag; `game.tscn` sets theirs to REFR and ACHR only.
- `CreatureBase` names no animation folders (`animation_search_paths()` is ActorBase's empty
  one), so a creature loads no clips.
- Leveled templates and encounter zones work on `ActorReference`: a creature whose TPLT chain
  reaches an LVLC takes its choice through `ActorReference.template_source()` and
  `model_source()` (see [`templated_npcs.md`](../Completed%20Plans/Actors/templated_npcs.md)).
  The streamers skip disabled actors, creatures included.
- Package processing, furniture (`ScriptServer.begin_use`), dialogue and look work on
  `ActorReference` and do not branch on NPC versus creature.
- `IdleTree` picks general idles by the actor's skeleton; matching a creature's skeleton to its
  furniture idles is not done (`Completed Plans/Actors/stage_g.md`).

## Build order

1. **Parts.** `CreatureBase` lists its NIFZ parts (through the template when templated), all
   optional; the actor node skins skinned parts to the skeleton and hangs unskinned ones from
   their `Prn` bone. Gate: Rex renders. Done: his body, skull cap and eyes build, and one CREA
   for each of the 169 distinct skeleton and parts combinations builds
   (`_diag/diag_creature_builds`). The actor node composes what the files declare only
   together (`ActorSkinning`): a skeleton NIF with no declared bones becomes a Skeleton3D of
   its nodes, a part's own bones join the skeleton under their parent, and a `Prn` naming a
   non-bone skeleton node makes it a bone. The only parts left without a mesh are the files
   no archive ships and parts with no mesh at all (laser emitters, the securitron smoke trail).
2. **Animation.** The creature's KFs (its skeleton folder and KFFZ) through `ActorAnimator`.
   Gate: Rex idles and walks.
3. **Seeding.** The seed list widened from ACHR to ACRE, and the streamers' CREA flag turned
   on in `game.tscn`; creatures virtual and local as NPCs are. Gate: a Goodsprings creature
   leaving the loaded area continues virtually and returns where the server put it, and
   Vault 3's leveled creatures get a choice.
4. **Packages and furniture.** A Goodsprings creature runs its packages; creature furniture
   idles chosen by skeleton.

## Unverified

- That creatures cannot wear clothing.
