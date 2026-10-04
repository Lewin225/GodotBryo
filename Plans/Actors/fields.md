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
| Unused in FalloutNV.esm | `health`, `count`, `radius`, `idle_time`, `idle_form_id`, `topic_form_id` | XHLP, XCNT, XRDS, XPRD, INAM, TNAM | (idle: IdleBase; topic: DialogueTopicBase) | both reference types; kept, each described "Present on no ACHR or ACRE in FalloutNV.esm; not read." |
| State | `contents` | runtime, seeded from the base's CNTO | Inventory | both |
| State | `actor_values` | runtime | ActorValues | both |
| State | `alive` | runtime | | both, unused |
| State | `using`, `using_marker` | runtime (begin_use) | EsmReference | NPC only; a creature user fails today |
| State | `active_package` | runtime | PackageBase | NPC only |
| State | `simulation_mode` | runtime (NpcSimulationServer) | | NPC only |
| State | `spawn_cell_form_id` | runtime (the filing CELL) | | NPC only |

`using_changed` and `get_actor_values()` move here too.

A subrecord's field sits on the reference types that carry it in the data. XATO, XAPD and XIBS
are on ACHR and ACRE, so they are ActorReference fields; REFR-based types that carry them get
their own field when needed, by census.

## NpcReference (ACHR; extends ActorReference)

No fields of its own. `base` is an NpcBase.

## CreatureReference (ACRE; extends ActorReference)

| Group | Field | Source | Resolves to | Today |
|---|---|---|---|---|
| Ownership | `owner_form_id`, `owner` | XOWN: 10 ACRE | NpcBase or *EsmBase* (FACT) | CreatureReference, not read |
| Ownership | `owner_faction_rank` | XRNK | | `faction_rank`; kept, "Present on no ACRE in FalloutNV.esm; not read." |

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

## Resources for referenced types

Record types the fields above point at that have no typed resource. Each would be an EsmBase
subclass with the fields below (xEdit layouts). Until one exists, `EsmServer.get_base` gives a
plain EsmBase for it.

| Record | Resource | Fields | Referenced by | Consumer today or in this plan |
|---|---|---|---|---|
| VTYP | VoiceTypeBase | DNAM flags (Allow Default Dialog, Female) | ActorBase `voice_type` | GetIsVoiceType; the voice file path (DialogueServer) |
| FACT | FactionBase | FULL; DATA flags 1 (Hidden from PC, Evil, Special Combat) and 2 (Track Crime, Allow Sell); relations (XNAM: faction, modifier, group combat reaction; layout from fopdoc, its xEdit definition is not in the vendored copy); ranks (RNAM number, MNAM male title, FNAM female title, INAM insignia); WMI1 reputation (REPU) | ActorFaction `faction`, CreatureReference `owner`, ECZN owner | GetInFaction, GetFactionRank |
| LVLN | LeveledNpcBase | OBND; LVLD chance none; LVLF flags; entries (LVLO: level, NPC_ / LVLN, count; COED) | ActorBase `template` (NPC_) | the four saloon powder gangers' packages (census A3) |
| LVLC | LeveledCreatureBase | as LVLN, entries CREA / LVLC | ActorBase `template` (CREA) | creatures, stage J |
| IDLE | IdleBase | MODL (KF); conditions; ANAM parent, previous; DATA section, loop min/max, replay delay, flags | PACK idle lists and events, `PlayIdle`, ActorReference `idle` | stage F |
| HDPT | HeadPartBase | FULL; MODL; DATA playable; HNAM extra parts (HDPT) | NpcBase `head_parts` | the humanoid head (stage C) |
| SPEL | SpellBase | FULL; SPIT type (Actor Effect, Disease, Power, Lesser Power, Ability, Poison, Addiction), flags; effects (EFID, EFIT, conditions) | ActorBase `actor_effects` | none yet (abilities would change actor values) |
| ENCH | EnchantmentBase | FULL; ENIT type (Weapon, Apparel), flags; effects | ActorBase `unarmed_attack_effect` | none yet |
| CSTY | CombatStyleBase | CSTD (standard), CSAD (advanced), CSSD (simple): dozens of combat tuning values | ActorBase `combat_style` | none (combat is out of scope) |
| ECZN | EncounterZoneBase | DATA: owner (NPC_ / FACT), rank, minimum level, flags (Never Resets, Match PC Below Minimum Level) | ActorReference `encounter_zone` | none yet |
| IPDS | ImpactDatasetBase | DATA: an IPCT per material (stone, dirt, grass, glass, metal, wood, organic, cloth, water, hollow metal, organic bug, organic glow) | CreatureBase `impact_dataset` | none (combat) |

LVLN and LVLC entries have the same layout as LVLI's, which `LeveledItemEntry` holds today; one
shared entry resource would serve all three.

## Questions

1. Which of the resources above to add in stage B: those with a consumer in this plan (VTYP, FACT,
   LVLN, IDLE, HDPT; LVLC with creatures), or all of them?
2. CNTO on the base: keep reading it raw when a reference is created, or add a base field (CONT
   has CNTO too, so it would be a shared sub-resource)?
3. CSDT, NIFT and DEST: fields now, or "not read" until a consumer needs them?
