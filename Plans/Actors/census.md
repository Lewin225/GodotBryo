# Actors census

Stage A of `actors.md`. Counts are over every record of the type in FalloutNV.esm unless a section
names a narrower population. Labels and layouts are xEdit's (`enginedocs/xEdit/Core/
wbDefinitionsFNV.pas`).

## A1. Shared record fields

Counts from `native/tools/actor_record_census` (records carrying the subrecord, of the type's
total). "Present on none" means xEdit defines it and FalloutNV.esm never uses it.

### Placed actors: ACHR (3,386) and ACRE (2,999)

xEdit defines ACHR and ACRE with the same subrecords, except Ownership (XOWN, XRNK), which only
ACRE has.

| Subrecord | xEdit label | ACHR | ACRE | On EsmReference today |
|---|---|---:|---:|---|
| EDID | Editor ID | 1,503 | 702 | via the record index |
| NAME | Base (NPC_ / CREA) | 3,386 | 2,999 | `base_form_id`, `base` |
| DATA | Position / Rotation | 3,386 | 2,999 | `position`, `rotation` |
| XSCL | Scale | 10 | 56 | `scale` |
| XLKR | Linked Reference | 1,164 | 242 | `linked_reference_form_id` |
| XESP | Enable Parent | 647 | 184 | `enable_parent_form_id`, `enable_parent_flags` |
| XRGD | Ragdoll Data | 278 | 109 | no |
| XRGB | Ragdoll Biped Data | 277 | 14 | no |
| XLCM | Level Modifier (s32) | 178 | 119 | no |
| XMRC | Merchant Container (REFR) | 76 | 1 | `merchant_container_form_id`, not read |
| XEZN | Encounter Zone (ECZN) | 5 | 11 | no |
| XAPD | Parent Activate Only | 3 | 1 | no |
| XATO | Activation Prompt | 3 | 1 | no |
| XIBS | Ignored By Sandbox | 6 | 0 | no |
| XOWN | Owner (ACRE only) | — | 10 | `CreatureReference.owner_form_id`, not read |

Present on none, on either: XPRD, XPPA, INAM, TNAM (Patrol Data), XCNT, XRDS, XHLP, XDCR, XCLP,
XAPR, XEMI, XMBR, XRNK. Today's `health`, `count`, `radius`, `idle_time`, `idle_form_id`,
`topic_form_id` (both reference types) and `faction_rank` (CreatureReference) are these.

**Result.** Every reference field is shared except ownership, which only ACRE carries (10
records). The reference-side data fits the abstract `ActorReference` whole.

### Bases: NPC_ (3,816) and CREA (1,578)

**Same signature, same meaning** (shared):

| Subrecord | xEdit label | Resolves to | NPC_ | CREA |
|---|---|---|---:|---:|
| EDID | Editor ID | | 3,816 | 1,578 |
| OBND | Object Bounds | | 3,816 | 1,578 |
| FULL | Name | | 3,399 | 1,159 |
| MODL | Model (the skeleton) | | 3,808 | 1,093 |
| ACBS | Configuration: flags, fatigue, barter gold, level, calc min/max, speed mult, karma, disposition, template flags | | 3,816 | 1,578 |
| SNAM | Factions (faction, rank) | FACT | 3,138 | 1,165 |
| INAM | Death Item | LVLI | 658 | 977 |
| VTCK | Voice | VTYP | 3,816 | 1,045 |
| TPLT | Template | NPC_/LVLN on NPC_; CREA/LVLC on CREA | 2,573 | 1,150 |
| SCRI | Script | SCPT | 1,046 | 260 |
| CNTO (+COED) | Items (+ extra data) | ARMO, AMMO, MISC, WEAP, BOOK, LVLI, KEYM, ALCH, NOTE, IMOD, CMNY, CCRD, LIGH, CHIP | 3,141 | 484 |
| AIDT | AI Data: aggression, confidence, energy, responsibility, mood, services, teaches, max training, assistance, aggro radius | | 3,816 | 1,578 |
| PKID | Packages, in order | PACK | 3,073 | 1,306 |
| SPLO | Actor Effects | SPEL | 191 | 647 |
| EITM | Unarmed Attack Effect | ENCH/SPEL | 0 | 217 |
| EAMT | Unarmed Attack Animation | | 3,816 | 1,578 |
| ZNAM | Combat Style | CSTY | 1,485 | 1,520 |
| NAM4 | Impact Material Type | | 3,816 | 1,578 |
| KFFZ | Animations | | 0 | 99 |
| DEST, DSTD, DSTF | Destructible | | 7 | 55 |

**Same signature, different meaning:**

| Subrecord | NPC_ | CREA |
|---|---|---|
| DATA | base health (s32), 7 attributes; 11 bytes | type, combat/magic/stealth skill, health (s16), damage, 7 attributes; 17 bytes |
| RNAM | Race (RACE) | Attack Reach (u8) |
| PNAM | Head Parts (HDPT, repeated) | Body Part Data (BPTD) |
| CNAM | Class (CLAS) | Impact Dataset (IPDS) |
| NAM5 | Unknown (u16) | Sound Level (u32) |
| LNAM | Hair Length (float) | Melee Weapon List (FLST) |

The ACBS flags share their layout but not their names (wbDefinitionsFNV's NPC_ and CREA flag
lists differ).

**NPC_ only:** DNAM (skill values and offsets), HNAM (Hair, HAIR), ENAM (Eyes, EYES), HCLR (hair
colour), FGGS / FGGA / FGTS (FaceGen), NAM6 (Height), NAM7 (Weight).

**CREA only:** NIFZ (Model List) and NIFT (its textures), TNAM (Turning Speed), BNAM (Base
Scale), WNAM (Foot Weight), CSCR (Inherits Sounds From, CREA), CSDT / CSDI / CSDC (sound types).

**Result.** 20 subrecords are shared with the same meaning, including everything the generic
actor runs on: factions, voice, template, script, inventory, AI data, packages, actor effects,
combat style. Today `NpcBase` and `CreatureBase` each carry their own `voice_type_form_id`,
`factions` and `actor_stats`, and `NpcBase` alone carries `packages`. Six subrecords share a
signature with different meanings, so a shared parent holds only the shared table above, and
each type reads its own DATA, RNAM, PNAM, CNAM, NAM5 and LNAM.

### Today's fields that do not hold

- `ActorStats` bundles ACBS (shared), AIDT (shared), TPLT (shared), DATA (different per type)
  and DNAM (NPC_ only), with `is_creature` choosing which DATA layout it holds.
- `CreatureBase.pnam_values` is CREA PNAM, a single BPTD FormID per xEdit, not a list of values.
- `CreatureBase` already holds NIFZ (`model_list_filenames`, `model_list_paths`) and KFFZ
  (`animation_filenames`, `animation_paths`); none of its fields carries a description.
- The earlier note that CREA RNAM is an impact data set is wrong: CREA RNAM is Attack Reach; the
  impact data set is CREA CNAM.

## A2. Code callers

Every use of `ActorReference` and `CreatureReference` in `project/` outside `old/` and
`addons/` (107 lines, 29 files), plus the base-type checks that stand for "an actor". After stage
B, `ActorReference` is the abstract actor; today's `ActorReference` is the NPC.

**Any actor: stays `ActorReference`.** A pair `is ActorReference or is CreatureReference`
becomes one `is ActorReference`.

| Where | Use |
|---|---|
| `script_server.gd:264` | disabled actors' scripts do not run (pair) |
| `script_server.gd:331, 357` | `begin_use` / `end_use` cast the user to `ActorReference`; a creature user fails the cast today |
| `esm_server.gd:623-626` | `spawn_cell_form_id`, `simulation_mode` set on placement |
| `esm_server.gd:682, 717` | actor values and inventory created (pairs) |
| `esm_primitive_volume.gd:78` | trigger occupants are actors (pair) |
| `esm_reference.gd:124` (`used_by`), `furniture_reference.gd:11` (`occupants`) | who uses a reference |
| `world_streamer_v2.gd:541-542` | actors are excluded from a tile's static set (pair) |
| `player_controller.gd:739, 747` | the possessed actor |
| `special_menu.gd`, `tag_skills_menu.gd`, `trait_menu.gd` | actor values; nothing NPC-specific |
| `nav_npc_simulation_server.gd` (24 lines), `nav_simulation_viewer.gd` (5) | index, ground, route, check-out and check-in |
| `esm_server.gd:440-452, 499-504` | `get_all_placed_actor_references()` and its batch feed the simulation server, but from `get_all_placed_npc_actors()` (ACHR only); widening it to ACRE is what makes the server generic |

**NPC only: becomes `NpcReference`.**

| Where | Use |
|---|---|
| `esm_server.gd:28` | `TYPE_TO_REFERENCE["NPC_"]` |
| `esm_server.gd:67, 312-316` | the player's reference (base 0x7, an NPC_) |
| `esm_server.gd:752` | `equip_default_armor()` on the new inventory: worn equipment is humanoid |
| `name_menu.gd`, `race_menu.gd` | write the NPC_'s FULL and Female flag |
| `esm_humanoid_actor.gd:913, 1288, 1296` | the humanoid node's reference; becomes the humanoid layer in stage C |
| `esm_reference_physicaliser.gd:71` | NPCs to the humanoid node; actors to the actor node after stage C |

**Both kept apart.** `cell_streamer_v2.gd:241-243` and `world_streamer_v2.gd:523-525` choose by
the `SPAWN_ACHR` / `SPAWN_CREA` flags: `NpcReference` and `CreatureReference`.

**Bases.** Five places reach the stats by `record.get("actor_stats")` duck typing because no
shared base type exists: `actor_stats.gd:26, 30`, `actor_values.gd:94`,
`script_function_registry.gd:668`, `dialogue_server.gd:375`. With `ActorBase` they type it.
`SexChange`, `GetIsSex` and `race_menu.gd` use `NpcBase` and stay NPC only.

**Tests.** 11 test files name `ActorReference`; each follows its subject's class above (the
player and Doc become `NpcReference`, `test_actor_values.gd`'s creature Rex stays
`CreatureReference`, `ActorReference.new()` in tests becomes the concrete type).

**Result.** Of the non-test uses, most mean any actor; the NPC-only ones are the NPC_ mapping,
the player, worn equipment, the name and race menus and the humanoid node. Two places silently
exclude creatures today: `begin_use` / `end_use`, and the simulation server's seed list.
