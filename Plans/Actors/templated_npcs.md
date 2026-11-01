# Templated and leveled NPCs

Placed actors whose NPC_ takes its traits from a template (ACBS Traits flag + TPLT) render with
the template's race, sex, hair, eyes and head parts, including templates that are leveled lists
(LVLN). Follow-on to [`Completed Plans/Actors/stage_d.md`](../Completed%20Plans/Actors/stage_d.md).

## Facts

- 1,582 of the 3,386 placed actors (all NPC_ bases) take their traits from a template. By the
  first link: 149 from another NPC_, 1,433 from a leveled list (LVLN)
  (`_diag/diag_actor_templates`). Followed to the end of the chain: 79 end at an NPC_, 1,503 at
  a leveled list.
- Every templated NPC_ carries an RNAM of its own. The 79 whose chain ends at an NPC_ always
  built, from their own copies of the traits, which are stale on some: hair on 6, HCLR on 7,
  FGTS on 16, race on 1. `EsmActorNode` now builds from `template_source(base, Use Traits)` and
  takes its skeleton and animations from `template_source(base, Use Model/Animation)`
  (`tests/test_actor_node`: VMcCarranNCRTrooperMonorail1 wears NCRTrooperCF's hair and HCLR).
- Leveled-template actors are invisible because their skeleton never loads: 638 NPC_ have MODL
  `marker_creature.nif` (no Skeleton3D) and take their model from a leveled list
  (`_diag/diag_leveled_actor_build`: VHDLegionPowerPlant01Legionary). 3,170 NPC_ name
  `characters\_male\skeleton.nif`, 8 none.
- LVLN (365) and LVLC (343) in FalloutNV.esm (`lvl_census.py` scan): LVLD 0 on all; every LVLO
  12 bytes with count 1, no COED; LVLF 0 / 1 / 2 / 3 on 139 / 28 / 132 / 66 LVLN and 0 / 1 on
  270 / 73 LVLC. LVLN entries: 1,891 NPC_, 186 LVLN; LVLC: 1,056 CREA, 279 LVLC. No entry NPC_ or
  CREA templates on a leveled list. 64 LVLN have no entry at level 1 or below; one LVLN and one
  LVLC have no entries.
- XLCM on ACHR: 0 on 41, 1 on 76, 2 on 59, 3 on 2.
- 1,852 placed actors reach a leveled list in their TPLT chain. 44 of them do not take
  Model/Animation from it and keep `marker_creature.nif` (40 take Traits from it, 4 take neither:
  `BoomerMessAAF` ×2, `BoomerMessCM`, `vGOMReceptionist`).
- 60 facemods named `m<race>_<npc>_0.dds` / `f<race>_<npc>_0.dds` ship in Fallout - Textures.bsa
  (FalloutNV.exe's `M%08X_%08X_%i` / `F%08X_%08X_%i` patterns), for 17 NPC_. The NPC is the
  placed actor's own NPC_, the race one its traits can give it: one AfricanAmerican file each for
  four that take traits from a template or leveled list (`PrimmNCRPatrolMcGee`,
  `PrimmNCRPatrol`, `PrimmNCRDeputyRanger`, `vGOMReceptionist`), and one per human race for
  `vMORangerGhost` and NCR Rangers and their templates (`vForlornHopeNCRRanger*`,
  `vHDRangerKimballGuardTEMPLATE`, `VHDRangerOliverGuard`, `CharlieInteriorRanger`,
  `vMORangerJackson`), whose races are their own.
- ECZN: 17 records. DATA Minimum Level 0 to 22; Never Resets on 11. XEZN on 5 ACHR and 11 ACRE,
  and on CELLs. Of the 3,739 placed ACHR and ACRE whose chain reaches a leveled list, 16 name a
  zone themselves, 899 are in a cell that does (625 in `HooverDamZone`), 2,824 have none. 275 of
  them carry XLCM (0 / 1 / 2 / 3 on 75 / 121 / 76 / 3); 22 actors that reach no list carry it too.

## Shape

- `LeveledActorBase` (`LeveledNpcBase`, `LeveledCreatureBase`) holds LVLD, LVLF and LVLO
  (`LeveledActorEntryCollection`).
- `LeveledActorResolver.resolve(list, level, rng)` takes the entries at or below the level, only
  those at the highest such level unless LVLF 0x01, and picks one at random, following nested
  lists. A list with nothing at or below the level takes its lowest-level entries.
- `ActorReference.get_leveled_template()` chooses once into `leveled_template`, on first use, at
  the space's level: the actor's XEZN zone, else its cell's (`EsmServer.encounter_zone_for_cell`),
  whose level `EncounterZoneBase.resolve_level` fixes on first use (the player's, raised to the
  minimum unless Match PC Below Minimum Level); the player's level without a zone. Without XLCM
  the list's LVLF rules apply, seeded from `instance_id`. With XLCM (0-3 read as Easy, Medium,
  Hard, Boss) the level is scaled (0.5, 0.75, 1.25, 2.0); Easy takes any entry at or below it,
  the others only the closest, and the choice is seeded from space, modifier and list, so those
  actors in one space are the same.
- `ActorBase.template_source(record, flag, leveled_choice)` continues into the choice at a
  leveled list; `ActorReference.template_source(flag)` passes it. Stats, inventory, packages,
  idles, voice type, script functions and the actor node go through it.
- `ActorReference.model_source()`: the Model/Animation source, or the leveled choice's when that
  is the `marker_creature.nif` placeholder (the 44 above; inferred).
- `FaceGenServer.request_skin(npc, ..., placed_npc)`: the face map is `placed_npc`'s facemod on
  the race of `npc` (the trait source) when that file ships, before `npc`'s own.

## Build

Done on branch `leveled-npc-templates`. `tests/test_actor_node`: all 1,852 get a choice, the same
one when chosen again, and a skeleton other than the placeholder; the first one
(VHDCLLegionary1a) builds.

## Open

- XLCM's value-to-modifier mapping and scales are inferred, not confirmed in game.
- Zone level rules (minimum, Match PC Below Minimum Level) are inferred, not confirmed in game.
- Choices are made on first use, which is when EsmServer creates the reference (its inventory
  comes from the Inventory template), so zones resolve at the player's level then. Choosing again on cell reset, and zone resets (Never
  Resets), wait for cell reset.
- Lists with nothing at or below the level: taking the lowest entries is our choice.
- The 44 placeholder actors' skeletons.
