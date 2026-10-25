# Templated and leveled NPCs

Placed actors whose NPC_ takes its traits from a template (ACBS Traits flag + TPLT) render with
the template's race, sex, hair, eyes and head parts, including templates that are leveled lists
(LVLN). Follow-on to [`Completed Plans/Actors/stage_d.md`](../Completed%20Plans/Actors/stage_d.md).

## Facts

- 1,582 of the 3,386 placed actors (all NPC_ bases) take their traits from a template: 149 from
  another NPC_, 1,433 from a leveled list (LVLN). All render invisible
  (`_diag/diag_actor_templates`).
- `EsmActorNode` asks the reference's own base for its parts (`NpcBase.get_model_parts`), which
  uses the record's own `race`; a templated NPC_ has none, so the node builds nothing.
- `ActorBase.template_source(record, flag)` follows TPLT through NPC_ templates while the flag is
  set, up to 8 deep; it stops at a leveled list. Callers: packages (`PackageRunner`), idles,
  inventory, stats, voice type, FaceGen coordinates (`FaceGenServer`), script functions.
- `LeveledNpcBase` does not read LVLD (Chance None), LVLF (Flags) or LVLO (entries).
- Four Goodsprings powder gangers take their packages from a leveled list, which
  `template_source` does not follow.

## Shape (proposed, not agreed)

- `LeveledNpcBase` reads LVLD, LVLF and LVLO, mirroring `LeveledItemBase` /
  `LeveledItemResolver`.
- Each placed actor chooses once from a leveled template into a saved runtime field on
  `ActorReference` (e.g. `leveled_template`), at the player's level per LVLF (inferred from the
  flag name, not verified).
- `template_source` continues into that choice; the actor node takes its parts from
  `template_source(base, Traits)`.
- Stats, inventory and packages follow the same template flags through `template_source`.

## Open

- What LVLF's flags do in the game (calculate from all levels, for each item in count, use all).
- Whether the leveled choice is made once per reference and saved, or again on respawn or cell
  reset.
