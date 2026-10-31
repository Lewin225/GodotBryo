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
- 60 facemods named `m<race>_<npc>_0.dds` / `f<race>_<npc>_0.dds` ship (FalloutNV.exe's
  `M%08X_%08X_%i` / `F%08X_%08X_%i` patterns): an NPC's face on another race, for 18 NPCs,
  mostly NCR Rangers templated on `vForlornHopeNCRRanger*TEMPLATE` / `vHDRangerKimballGuardTEMPLATE`
  (one per human race), and five NPCs that take traits from a leveled list (one AfricanAmerican
  file each). FaceGenServer only looks for `<npc>_0.dds` (`Completed Plans/Actors/faces.md`).

## Shape

- `LeveledActorBase` (`LeveledNpcBase`, `LeveledCreatureBase`) holds LVLD, LVLF and LVLO
  (`LeveledActorEntryCollection`).
- `LeveledActorResolver.resolve(list, level, rng)` takes the entries at or below the level, only
  those at the highest such level unless LVLF 0x01, and picks one at random, following nested
  lists. A list with nothing at or below the level takes its lowest-level entries.
- `ActorReference.get_leveled_template()` chooses once, at the player's level, seeded from
  `instance_id`, into `leveled_template`.
- `ActorBase.template_source(record, flag, leveled_choice)` continues into the choice at a
  leveled list; `ActorReference.template_source(flag)` passes it. Stats, inventory, packages,
  idles, voice type, script functions and the actor node go through it.
- `ActorReference.model_source()`: the Model/Animation source, or the leveled choice's when that
  is the `marker_creature.nif` placeholder (the 44 above; inferred).

## Build

Done on branch `leveled-npc-templates`. `tests/test_actor_node`: all 1,852 get a choice, the same
one when chosen again, and a skeleton other than the placeholder; the first one
(VHDCLLegionary1a) builds.

## Open

- The level used, and whether the encounter zone (XEZN on 5 ACHR, or the cell's zone) and XLCM
  (178 ACHR) change it. Encounter zones are not resolved per cell yet.
- What LVLF's flags do.
- Choosing again on cell reset, once cell reset exists.
- Lists with nothing at or below the level: taking the lowest entries is our choice.
- The 44 placeholder actors' skeletons.
- Facemods for a leveled choice (`m<race>_<npc>_0.dds`): FaceGenServer looks up the chosen NPC's
  own.
