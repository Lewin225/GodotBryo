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

## A3. Packages

From `project/_diag/diag_package_census.tscn`. Population: the 21 ACHR filed in an interior CELL
whose editor ID starts with "GS" (GSDocMitchellHouse, GSGasStation, GSGeneralStore,
GSProspectorSaloonInterior), or placed in WastelandNV at grid x -19..-15, y -2..1 (the exterior
cells holding the NPCs named for Goodsprings, padded by one). ACRE (creatures) are not in it.

**Package sources.** PKID on the NPC_, or on its template when ACBS template flag 0x20 (Use AI
Packages; xEdit `wbActorTemplateUseAIPackages`) is set: the six powder gangers GSPG02-06 take
GSPGAAM's. Four saloon powder gangers (0015F316-0015F319) take theirs from LVLN
VarGoodspringsPowderGanger, a leveled list, which `ActorStats.template_source` does not follow.
Scripts add more with `AddScriptPackage` (1,141 calls in FalloutNV.esm; 12 distinct packages for
this population and the player), and `RemoveScriptPackage` removes one (GSJoeCobbLeavePackage's
On End).

**Packages used: 56** on the population's NPC_ records, plus 12 script-added. By type, the 68:

| Type | Packages |
|---|---:|
| Travel | 30 |
| Sandbox | 10 |
| Sleep | 10 |
| Dialogue | 9 |
| Guard | 4 |
| Eat | 2 |
| Flee Not Combat | 2 |
| Ambush | 1 |

Guard, Flee Not Combat and Ambush belong to VMS16's gunfight (conditions on VMS16 / VMS16b
variables), as do the Travel packages GoodspringsMilitiaTravelPackage and GSPGTravelPackage and
the script-added RingoTravelPackage and SunnyTravelPackage.

**Selection.** Every package here has a schedule; those without an hour (-1) run at any time.
Conditions use GetStage, GetStageDone, GetQuestCompleted, GetQuestVariable,
GetObjectiveDisplayed and GetObjectiveCompleted, all implemented. Per the GECK's "How Are Packages
Evaluated": the list is searched top to bottom and the first package whose schedule and
conditions hold is selected; packages are re-evaluated about every 10 seconds, on
`EvaluatePackage`, and when a package completes.

**Doc Mitchell.** PKID, in order, with the condition that selects each:

| Package | Type | Selected when | Location / target |
|---|---|---|---|
| GoodspringsMilitiaTravelPackage | Travel | VMS16b variable 1 == 1 | near 0015ED61 |
| VCG01DocMitchellSandbox | Sandbox | VCG01 completed | near current location, radius 1024 |
| VCG01DocMitchellFarewellDialogueStart (00105BD2) | Dialogue | VCG01 stage >= 115 | near VCG01DocMitchellExitMarkerREF; target the player, distance 420; no topic (GREETING) |
| VCG01DocMitchellTravelToExit (00105BD1) | Travel | stage >= 110 | VCG01DocMitchellExitMarkerREF |
| VCG01DocMitchellTravelToExamSpot | Travel | stage >= 80 | DocMitchellChairREF (FURN) |
| VCG01DocMitchellTravelToSkullTestSpot | Travel | stage >= 76 | VCG01DocSkullTestMarkerREF; On End `DocMitchellREF.Look player` |
| VCG01DocMitchellTravelToPlayerAtTester | Travel | stage >= 55 | VCG01DocMarkerFaceTesterREF |
| VCG01DocMitchellBedsideStandingPackage | Travel | stage >= 40 | GSDocMitchellBesideMarker |
| VCG01DocMitchellFirstPosition | Travel | always | 001059B0 |

The VCG01 Travel packages carry the idle NPCSmokingIdle. Top-to-bottom selection makes the
highest stage reached win. The force-greet at the door is 00105BD2 (a Dialogue package whose
target is the player); 00105BD1 is the walk to the exit (its On End is commented out).

**Furniture use.** Travel and Use Item At packages both make an actor use furniture; a Travel
package does so when its destination is a furniture reference with radius 0 (rule given by the
user; not in the GECK's Travel Package page). Doc reaches his chair this way: his Travel package
targets DocMitchellChairREF with radius 0, nothing activates the chair, and
VCG01DocMitchellChairTriggerSCRIPT (SCPT 00105BCB) then expects
`DocMitchellREF.IsCurrentFurnitureRef DocMitchellChairREF`.

The data fits the rule: of the 111 Travel packages in FalloutNV.esm whose Location 1 is near a
placed FURN, 110 have radius 0; the other, NVCCSleepSeverus (bedroll, radius 1024), would stop
near the bedroll without using it. Use Item At: 17 to a placed FURN, 15 with radius 0. Other
types with a FURN destination: Sleep 67, Eat 20, Dialogue 7, Sandbox 6, Patrol 4.

**The player runs packages.** VCG00 and VCG01 add Travel packages to the player whose On Begin
and On Change play the opening's idles: VCG00PlayerSection0-2 (NVOpenPlayerKnockedDown,
nvopenplayercamidle, NVopenPlayerPickedUp) and VCG01PlayerSection0-2
(LooseVCG01PlayerWakeup, Situp, Bedsit, Standup).

**Result.** For the done-condition: Travel (using the furniture at a radius-0 furniture destination) and
Dialogue (force-greet with GREETING), selected top to bottom by condition, re-evaluated by
`evp`. For Goodsprings generally: add Sandbox, Sleep and hour schedules. Guard, Flee Not Combat
and Ambush only serve VMS16's gunfight. Package events (On Begin / End / Change: idle, topic,
script) appear on 11 of the 68.

## A4. Furniture

From `native/tools/furniture_census` over every FURN in FalloutNV.esm and its NIF in the BSAs.

**FURN records: 234** in FalloutNV.esm (recounted from the FURN group's record headers and
from the record index; Dead Money adds 15, Honest Hearts 7, the other masters none). They are base
records: 7,054 placed REFRs use 206 of them. xEdit gives FURN EDID, OBND, FULL, MODL, SCRI, DEST and MNAM ("Marker
Flags", a byte array, on all 234, always 4 bytes). One FURN's NIF is missing from the BSAs.

**NIF markers.** The NIF's `BSFurnitureMarker` extra data holds a list of positions (nifly's
`FurniturePosition`; FNV's NIFs use the User Version <= 11 form): an offset (Vector3, NIF units),
an orientation (u16) and two bytes, posRef1 and posRef2. 516 markers over 233 NIFs; markers per
NIF: 0 (7), 1 (62), 2 (72), 3 (73), 4 (12), 5 (5), 6 (3). No `BSFurnitureMarkerNode` occurs.

- Orientation is in thousandths of a radian: the common values are 1570, 3141 and 4712 (pi/2, pi,
  3pi/2), and none exceeds 6283.
- posRef1 equals posRef2 on all 516 markers. Its value sorts by furniture kind (names of the
  FURN using it):

  | posRef | Furniture | Usual orientation |
  |---|---|---|
  | 1-4 | beds, mattresses, bedrolls | pi/2, 3pi/2 |
  | 5, 6 | super mutant beds, floor sleeping, dying soldier | |
  | 10 | NVCrucifixFurniture | |
  | 11 | chairs, from the left | pi/2 (88 of 93) |
  | 12 | chairs, from the right | 3pi/2 (88 of 93) |
  | 14 | chairs, couches, benches, from the front | pi (123 of 153) |
  | 15 | stools, gambling stools | |
  | 16 | Lucky38TLPodchair | |
  | 17 | floor sit, dance markers | pi |
  | 18 | FFCaptiveMarker | |
  | 19 | wall markers, welding | |
  | 20 | couches (SubCouchDirty01F, VMS21NeroCouch, VCG01DocMitchellCouch), DanceMarker03 | |
  | 22 | lean, blackboard, cook stove, push-ups | |

  What a posRef value selects (animation, entry side) is inferred from these names, not
  documented.

**MNAM.** Bits set, by FURN count: 0 (163), 1 (95), 2 (40), 3 (14), 4 (10), 5 (6), 30 (144),
31 (59); no others. Bit i of bits 0-5 enables NIF marker i: on 212 of the 233 FURN with a NIF,
every set low bit indexes an existing marker. Chair variants named L, R and F (Chair01L,
Chair01R, Chair01F) set bits 0, 1 and 2; in SubChairDirty01.NIF, markers 0, 1 and 2 are posRef 11
(left), 12 (right) and 14 (front). Chair01's own NIF marker order was not checked. On the other 21, bits
are set beyond the NIF's markers (the benches' 0x1F over 3 markers; consoles and intercoms with
bit 0 and no markers). Bits 30 and 31 are not markers; their meaning is unknown.
`FurnitureBase.get_active_markers()` takes bits 0-23 as markers, which fits.

**The couch and Doc's chair.**

| Reference | FURN | NIF | MNAM | Enabled marker |
|---|---|---|---|---|
| DocMitchellCouchREF | VCG01DocMitchellCouch (0012429A) | Furniture\Suburban\SubCouchDirty01.NIF | 0x40000004 | 2: offset (-47.6, 71.9, -33.7), orientation pi, posRef 14 |
| DocMitchellChairREF | SubChairDirtyF (0006B55D) | Furniture\Suburban\SubChairDirty01.NIF | 0x40000004 | 2: offset (-2.0, 62.8, -37.2), orientation pi, posRef 14 |

The couch NIF has four markers: three front seats (posRef 14) and one posRef 20 at (-0.9, 194.7,
0.0). VCG01DocMitchellCouch is a VCG01-specific FURN enabling only one seat. The chair NIF's
markers are left (posRef 11), right (12) and front (14); SubChairDirtyF enables the front. Neither
FURN has a script.

**Result.** Using furniture means: pick a free enabled marker (an MNAM bit with a NIF marker
behind it), take the marker's offset and orientation in the furniture's space, and play the
animation its posRef names. The marker offsets lie beside or in front of the seat, about 35 units
below the NIF origin; whether the actor stands there before the enter animation or ends there is
not established, and is for stage F's animations to settle.

## A5. Idles

From `native/tools/idle_census` over every IDLE in FalloutNV.esm.

**IDLE records: 1,597**, each with MODL, CTDA conditions (1,098 have some), ANAM (Parent and
Previous IDLE: a tree with siblings in order; 512 have no parent) and DATA (animation group
section, loop min/max, replay delay, flags). 1,203 MODLs name a KF found in the BSAs; the other
394 name only a folder (`Characters\_Male\IdleAnims`) and are grouping nodes of the tree (340 of
them have children).

DATA's first byte is the animation group section (xEdit `wbIdleAnam`): the low six bits name the
section (0 Idle, 1 Movement, 2 Left Arm, 3 Left Hand, 4 Weapon, 5 Weapon Up, 6 Weapon Down,
7 Special Idle, 20 Whole Body, 21 Upper Body), 0x40 marks a loose idle and 0x80 clear means "must
return a file". Counts: 7 (748), 0x47 (346), 20 (151), 0x87 (72), 1 (123), 4 (55), 0 (37), others
under 20 each.

**What VCG00 and VCG01 play.** The Rorschach test's `PlayIdle VCG01DocRorschachTest1-3` lines are
commented out in their INFOs. Live:

| IDLE | Played by | KF | Length | Bones driven |
|---|---|---|---|---|
| VCG01DocGiveMirror | VCG01 stage script, `DocMitchellREF.PlayIdle` | SpecialIdle_NVCG01DocGiveMirror.kf | 3.00 s | 61 |
| NPCSmokingIdle | VCG01 Doc Travel packages' idle list | SmokingStanding.kf | 8.37 s | 52 |
| NVOpenPlayerKnockedDown | VCG00PlayerSection0 On Begin | SpecialIdle_NVopen_PlayerKnockDown.kf | 28.93 s | 19 |
| nvopenplayercamidle | VCG00PlayerSection1 On Begin | SpecialIdle_NVopen_PlayerCamIdle.kf | 3.33 s, loops | 75 |
| NVopenPlayerPickedUp | VCG00PlayerSection2 On Begin | SpecialIdle_NVopen_PlayerPickedUp.kf | 12.33 s | 19 |
| LooseVCG01PlayerWakeup | VCG01PlayerSection0 On Begin | SpecialIdle_NVCG01PlayerWakeup.kf | 6.00 s | 15 |
| LooseVCG01PlayerSitup | VCG01PlayerSection1 On Begin | SpecialIdle_NVCG01PlayerSitUp.kf | 5.40 s | 15 |
| LooseVCG01PlayerBedsit | VCG01PlayerSection1 On Change | SpecialIdle_NVCG01PlayerBedsit.kf | 8.17 s | 15 |
| LooseVCG01PlayerStandup | VCG01PlayerSection2 On Begin | SpecialIdle_NVCG01PlayerStandup.kf | 11.13 s | 15 |
| CowerIdles | GoodspringsFleePackage's idle list | 3rdP_Cowering.kf | 12.13 s | 60 |

All KFs are under `Characters\_Male\IdleAnims\`, in the BSAs, with one NiControllerSequence whose
accum root is Bip01. All but nvopenplayercamidle (cycle 0, loop) are cycle type 2 (clamp: play
once and hold).

Every VCG idle above is section 0x47 (Special Idle, loose) with no parent and no conditions: played
by name, outside the idle tree. NPCSmokingIdle and CowerIdles are section 7 (Special Idle, not
loose) with four conditions each; NPCSmokingIdle sits in the tree at GeneralIdles > NPCOnlyIdles >
NPCNonWeaponIdles.

**Result.** VCG01 needs direct playback of a named IDLE's KF on the actor's skeleton (PlayIdle,
and package On Begin / On Change idles), and a package's idle list. The idle tree (parent,
sibling order, conditions; 1,098 IDLEs with conditions) is for the general idles actors play while
idling, which VCG01 does not depend on. The player's idles drive 15-19 bones: the opening plays
them on the player's body, likely the camera and head; what they move is for stage F.
