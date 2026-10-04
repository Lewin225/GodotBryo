# Actor field lists (stage B draft)

For agreement before any code. Sources are census A1 and A2 (`census.md`) and xEdit. Every
FormID field keeps its id and resolves to a resource beside it, named in "Resolves to". A type
with no typed resource yet resolves to a plain `EsmBase` (editor ID and name, nothing decoded);
those are marked *EsmBase*. "Today" says where the value lives now.

Groups are `@export_group`s on the resource. Sub-resources only where another record type uses
the same structure.

## ActorReference (abstract; extends EsmReference)

EsmReference already holds NAME (`base`), DATA, XSCL, XLKR, XESP and the enable state.

| Group | Field | Source | Resolves to | Today |
|---|---|---|---|---|
| Placement | `level_modifier` | XLCM (s32): 178 ACHR, 119 ACRE | | not read |
| Placement | `encounter_zone_form_id`, `encounter_zone` | XEZN: 5 ACHR, 11 ACRE | *EsmBase* (ECZN) | not read |
| Placement | `merchant_container_form_id`, `merchant_container` | XMRC: 76 ACHR, 1 ACRE | EsmReference (a placed CONT) | both reference types, not read |
| Placement | `ragdoll_data` | XRGD (raw bytes; 278 ACHR, 109 ACRE) | | not read |
| Placement | `ragdoll_biped_data` | XRGB (raw bytes; 277 ACHR, 14 ACRE) | | not read |
| Activation | `activation_prompt` | XATO: 3 ACHR, 1 ACRE | | not read |
| Activation | `parent_activate_only` | XAPD: 3 ACHR, 1 ACRE | | not read |
| Activation | `ignored_by_sandbox` | XIBS: 6 ACHR, 0 ACRE | | not read |
| Unused in FalloutNV.esm | `health`, `count`, `radius`, `idle_time`, `idle_form_id`, `topic_form_id` | XHLP, XCNT, XRDS, XPRD, INAM, TNAM: on no ACHR or ACRE | (idle: *EsmBase* IDLE; topic: DialogueTopicBase) | both reference types, documented as unused |
| State | `contents` | runtime, seeded from the base's CNTO | Inventory | both |
| State | `actor_values` | runtime | ActorValues | both |
| State | `alive` | runtime | | both, unused |
| State | `using`, `using_marker` | runtime (begin_use) | EsmReference | NPC only; a creature user fails today |
| State | `active_package` | runtime | PackageBase | NPC only |
| State | `simulation_mode` | runtime (NpcSimulationServer) | | NPC only |
| State | `spawn_cell_form_id` | runtime (the filing CELL) | | NPC only |

`using_changed` and `get_actor_values()` move here too.

XATO, XAPD, XIBS, XEMI and XMBR are not actor-specific (REFR has them); they would sit better on
EsmReference. Listed here only because this refactor touches them; moving them is a separate
choice.

## NpcReference (ACHR; extends ActorReference)

No fields of its own. `base` is an NpcBase.

## CreatureReference (ACRE; extends ActorReference)

| Group | Field | Source | Resolves to | Today |
|---|---|---|---|---|
| Ownership | `owner_form_id`, `owner` | XOWN: 10 ACRE | NpcBase or *EsmBase* (FACT) | CreatureReference, not read |
| Ownership | `owner_faction_rank` | XRNK: on no ACRE | | `faction_rank`, documented as unused |

## ActorBase (abstract; extends EsmBase)

EsmBase already holds EDID, FULL and SCRI (`script_form_id`).

| Group | Field | Source | Resolves to | Today |
|---|---|---|---|---|
| Model | `model_path` | MODL (the skeleton) | | NpcBase, CreatureBase |
| Model | `bounds` | OBND | | not read |
| Model | `animations` | KFFZ (0 NPC_, 99 CREA) | | CreatureBase `animation_filenames` / `animation_paths` |
| Configuration | `fatigue`, `barter_gold`, `level`, `calc_min`, `calc_max`, `speed_multiplier`, `karma`, `disposition_base` | ACBS 4-21 | | ActorStats (no barter gold, disposition) |
| Configuration | `template_flags` | ACBS 22 (`@export_flags`: Traits, Stats, Factions, Actor Effect List, AI Data, AI Packages, Model/Animation, Base Data, Inventory, Script) | | ActorStats and NpcBase `acbs_template_flags` |
| Configuration | `template_form_id`, `template` | TPLT | NpcBase / CreatureBase, or *EsmBase* (LVLN / LVLC) | ActorStats |
| Factions | `factions` | SNAM | Array[ActorFaction] (FACT as *EsmBase*) | NpcBase, CreatureBase |
| Traits | `death_item_form_id`, `death_item` | INAM | LeveledItemBase | not read |
| Traits | `voice_type_form_id`, `voice_type` | VTCK | *EsmBase* (VTYP) | NpcBase, CreatureBase (id only) |
| Traits | `combat_style_form_id`, `combat_style` | ZNAM | *EsmBase* (CSTY) | not read |
| Traits | `impact_material_type` | NAM4 (enum) | | not read |
| Actor effects | `actor_effects` | SPLO | Array of *EsmBase* (SPEL) | not read |
| Actor effects | `unarmed_attack_effect_form_id`, `unarmed_attack_effect` | EITM (0 NPC_, 217 CREA) | *EsmBase* (ENCH / SPEL) | not read |
| Actor effects | `unarmed_attack_animation` | EAMT (enum) | | not read |
| AI Data | `aggression`, `confidence`, `energy`, `responsibility`, `mood`, `services` (flags), `teaches`, `maximum_training_level`, `assistance`, `aggro_radius_behavior`, `aggro_radius` | AIDT | | ActorStats (five of them) |
| AI | `packages` | PKID, in order | Array[PackageBase] | NpcBase only |

Methods: `template_source(flag)` (from ActorStats), and a typed accessor ActorValues uses in place
of `get("actor_stats")`.

Not read, no field: CNTO (the reference's `contents` is seeded from it, as today), DEST
(destructible: 7 NPC_, 55 CREA).

## NpcBase (NPC_; extends ActorBase)

| Group | Field | Source | Resolves to | Today |
|---|---|---|---|---|
| Configuration | `acbs_flags` | ACBS 0 (`@export_flags`, NPC_ names) | | NpcBase |
| Stats | `base_health`, `attributes` | DATA | | ActorStats |
| Stats | `skill_values`, `skill_offsets` | DNAM | | ActorStats `skills` (values only) |
| Appearance | `race_form_id`, `race` | RNAM | RaceBase | NpcBase |
| Appearance | `class_form_id`, `actor_class` | CNAM | ClassBase | NpcBase |
| Appearance | `head_parts` | PNAM, repeated | Array of *EsmBase* (HDPT) | not read |
| Appearance | `hair_form_id`, `hair` | HNAM | HairBase | NpcBase |
| Appearance | `hair_length` | LNAM | | not read |
| Appearance | `hair_color` | HCLR | | not read |
| Appearance | `eyes_form_id`, `eyes` | ENAM | EyesBase | NpcBase |
| Appearance | `face_gen` | FGGS, FGGA, FGTS | (existing face_gen resource) | NpcBase |
| Appearance | `height`, `weight` | NAM6, NAM7 | | not read |
| Other | `unknown_nam5` | NAM5 (u16; xEdit "Unknown") | | not read |
| Not ESM | `body_part_data`, `is_child` | (unchanged) | | NpcBase |

`is_female()` / `set_female()` stay.

## CreatureBase (CREA; extends ActorBase)

| Group | Field | Source | Resolves to | Today |
|---|---|---|---|---|
| Configuration | `acbs_flags` | ACBS 0 (`@export_flags`, CREA names) | | ActorStats `flags` |
| Stats | `creature_type`, `combat_skill`, `magic_skill`, `stealth_skill`, `health`, `damage`, `attributes` | DATA | | ActorStats (no type) |
| Combat | `attack_reach` | RNAM | | not read |
| Combat | `melee_weapon_list_form_id`, `melee_weapon_list` | LNAM | BipedModelListBase (EsmServer maps every FLST to it today, though FLST is a general form list) | not read |
| Body | `model_list` | NIFZ | | `model_list_filenames` / `model_list_paths` |
| Body | `model_list_textures` | NIFT (raw) | | not read |
| Body | `body_part_data_form_id`, `body_part_data` | PNAM | BodyPartDataBase | `pnam_values` (Array[int]) |
| Body | `turning_speed`, `base_scale`, `foot_weight` | TNAM, BNAM, WNAM | | not read |
| Sound | `sound_level` | NAM5 (enum) | | not read |
| Sound | `impact_dataset_form_id`, `impact_dataset` | CNAM | *EsmBase* (IPDS) | not read |
| Sound | `inherits_sounds_from_form_id`, `inherits_sounds_from` | CSCR | CreatureBase | not read |
| Sound | `sounds` | CSDT / CSDI / CSDC | | not read |

## Removed

`ActorStats` (its fields move to ActorBase, NpcBase and CreatureBase as above); NpcBase
`acbs_template_flags` (becomes ActorBase `template_flags`); CreatureBase `pnam_values`,
`model_list_filenames` / `paths`, `animation_filenames` / `paths` (renamed).

## Questions

1. The six reference fields on no ACHR or ACRE (XHLP, XCNT, XRDS, Patrol Data): keep them, as
   today, or drop them?
2. XATO, XAPD, XIBS: on ActorReference now, or leave them for a later move onto EsmReference?
3. Types with no resource (ECZN, VTYP, CSTY, SPEL, ENCH, HDPT, IPDS, LVLN, LVLC, FACT):
   resolve to a plain EsmBase now, or add typed resources for some (VTYP and FACT are read by
   conditions today)?
4. CNTO on the base: keep reading it raw to seed the reference's `contents` (today's behaviour),
   or add a base field (CONT has CNTO too, so it would be a shared sub-resource)?
5. CSDT sounds, NIFT and DEST: fields now (CSDT would be a small sub-resource list), or "not read"
   until a consumer needs them?
