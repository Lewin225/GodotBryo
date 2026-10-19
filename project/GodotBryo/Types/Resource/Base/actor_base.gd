@tool
class_name ActorBase
extends EsmBase

## The fields NPC_ and CREA share with the same meaning (Plans/Completed Plans/Actors/census.md
## A1). Abstract: every actor record is an NpcBase or a CreatureBase, which add
## their own DATA, RNAM, PNAM, CNAM, NAM5, LNAM and ACBS flag names. EsmBase
## holds EDID, FULL and SCRI.

## ACBS flag 0x80 (xEdit: PC Level Mult, on NPC_ and CREA alike): `level` is
## the multiple of the player's level, x 1000.
const FLAG_PC_LEVEL_MULT := 0x80
## ACBS template flags (xEdit `wbTemplateFlags`): which parts come from TPLT.
const TEMPLATE_USE_TRAITS := 0x01
const TEMPLATE_USE_STATS := 0x02
const TEMPLATE_USE_FACTIONS := 0x04
const TEMPLATE_USE_ACTOR_EFFECT_LIST := 0x08
const TEMPLATE_USE_AI_DATA := 0x10
const TEMPLATE_USE_AI_PACKAGES := 0x20
const TEMPLATE_USE_MODEL_ANIMATION := 0x40
const TEMPLATE_USE_BASE_DATA := 0x80
const TEMPLATE_USE_INVENTORY := 0x100
const TEMPLATE_USE_SCRIPT := 0x200

@export_group("Model")
## MODL: the skeleton NIF. Read; EsmActorNode builds the skeleton from it.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_path: String = ""
## OBND: the object bounds' two corners (s16 x, y, z each). Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var bounds_min: Vector3i = Vector3i.ZERO
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var bounds_max: Vector3i = Vector3i.ZERO
## KFFZ: the record's own animation KFs, file names relative to MODL's folder
## (on 99 CREA, no NPC_ in FalloutNV.esm). Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var animations: PackedStringArray = PackedStringArray()
## Not an ESM field: `animations` joined to MODL's folder. Set; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var animation_paths: PackedStringArray = PackedStringArray()

@export_group("Configuration")
## ACBS offset 0: the flags. NpcBase and CreatureBase name them (their xEdit
## flag lists differ). Read; Female (NpcBase) and PC Level Mult are used.
@export_custom(PROPERTY_HINT_FLAGS, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var acbs_flags: int = 0
## ACBS offset 4: Fatigue. Read; used by ActorValues (Fatigue).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var fatigue: int = 0
## ACBS offset 6: Barter Gold. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var barter_gold: int = 0
## ACBS offset 8: Level, or with PC Level Mult the multiplier x 1000. Read;
## used by ActorValues.get_level().
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var level: int = 1
## ACBS offsets 10, 12: Calc min / max, the level bounds with PC Level Mult.
## Read; used by ActorValues.get_level().
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var calc_min: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var calc_max: int = 0
## ACBS offset 14: Speed Multiplier. Read; used by ActorValues (SpeedMult).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var speed_multiplier: int = 100
## ACBS offset 16: Karma (Alignment). Read; used by ActorValues (Karma).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var karma: float = 0.0
## ACBS offset 20: Disposition Base. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var disposition_base: int = 0
## ACBS offset 22: Template Flags. Read; used by template_source().
@export_custom(PROPERTY_HINT_FLAGS, "Traits:1,Stats:2,Factions:4,Actor Effect List:8,AI Data:16,AI Packages:32,Model/Animation:64,Base Data:128,Inventory:256,Script:512", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var template_flags: int = 0
## TPLT: the record parts come from: an NpcBase or LeveledNpcBase on an NPC_,
## a CreatureBase or LeveledCreatureBase on a CREA. Read; used by
## template_source() (leveled lists are not followed).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var template_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EsmBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var template: EsmBase

@export_group("SPECIAL")
## DATA's attributes (NPC_ offsets 4-10, CREA offsets 10-16; NpcBase and
## CreatureBase read their own). Read; used by ActorValues.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var strength: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var perception: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var endurance: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var charisma: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var intelligence: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var agility: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var luck: int = 0

@export_group("Factions")
## SNAM: the factions and the actor's rank in each, in authored order. Read;
## with the Factions template flag the template's are used. Used by
## GetInFaction and GetFactionRank.
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "FactionSubrecord", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var factions: Array[FactionSubrecord] = []

@export_group("Traits")
## INAM: the death item. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var death_item_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "LeveledItemBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var death_item: LeveledItemBase
## VTCK: the voice type. Read; with the Traits template flag the template's is
## used. Used by GetIsVoiceType and the voice-file path.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var voice_type_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "VoiceTypeBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var voice_type: VoiceTypeBase
## ZNAM: the combat style. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var combat_style_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "CombatStyleBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var combat_style: CombatStyleBase
## NAM4: Impact Material Type (u32; xEdit `wbActorImpactMaterialEnum`, whose
## names are not in the vendored xEdit copy). Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var impact_material_type: int = 0

@export_group("Actor effects")
## SPLO: the actor effects. Read; not used yet.
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "SpellBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var actor_effects: Array[SpellBase] = []
## EITM: the unarmed attack effect, an EnchantmentBase or SpellBase (on 217
## CREA, no NPC_ in FalloutNV.esm). Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var unarmed_attack_effect_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EsmBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var unarmed_attack_effect: EsmBase
## EAMT: Unarmed Attack Animation (u16; xEdit `wbAttackAnimationEnum`). Read;
## not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var unarmed_attack_animation: int = 0

@export_group("AI Data")
## AIDT offsets 0-4: Aggression, Confidence, Energy Level, Responsibility,
## Mood. Read; used by ActorValues.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var aggression: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var confidence: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var energy: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var responsibility: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var mood: int = 0
## AIDT offset 8: Buys/Sells and Services (u32 flags; xEdit `wbServiceFlags`).
## Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var services: int = 0
## AIDT offset 12: Teaches (a skill, s8). Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var teaches: int = -1
## AIDT offset 13: Maximum training level. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var maximum_training_level: int = 0
## AIDT offset 14: Assistance (s8). Read; used by ActorValues.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var assistance: int = 0
## AIDT offset 15: Aggro Radius Behavior. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var aggro_radius_behavior: bool = false
## AIDT offset 16: Aggro Radius (s32). Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var aggro_radius: int = 0

@export_group("AI")
## PKID: the AI packages, in authored order. Read; not used yet (package
## selection is the actors plan's stage H).
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "PackageBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var packages: Array[PackageBase] = []

@export_group("Items")
## xEdit "Items": CNTO and the COED after each, in order. Immutable: read only
## to build a reference's runtime inventory (EsmServer, on creating the
## reference); with the Inventory template flag the template's are used.
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "InitialItemCollection", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var items: Array[InitialItemCollection] = []

@export_group("Destructible")
## DEST, DSTD, DMDL, DMDT, DSTF (7 NPC_, 55 CREA); null when absent. Read; not
## used yet.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "DestructionCollection", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var destructible: DestructionCollection
@export_group("")

## The actor record that supplies `record`'s part named by the template flag
## `flag`: `record` itself, or the template it takes that part from, followed
## while each takes it from its template. A leveled-list template is not
## followed.
static func template_source(record: EsmBase, flag: int) -> ActorBase:
	var actor := record as ActorBase
	for _depth in 8:
		if actor == null or (actor.template_flags & flag) == 0 or not actor.template is ActorBase:
			return actor
		actor = actor.template as ActorBase
	return actor

## SPECIAL attribute `index`: 0 Strength through 6 Luck.
func get_attribute(index: int) -> int:
	match index:
		0: return strength
		1: return perception
		2: return endurance
		3: return charisma
		4: return intelligence
		5: return agility
		6: return luck
	return 0

## The model parts an actor is assembled from besides its MODL skeleton, for
## the actor node: each {"key", "path", "required", "kind"} plus any extra
## keys the kind uses. NpcBase and CreatureBase supply theirs; an ActorBase has
## none.
func get_model_parts(_female: bool) -> Array[Dictionary]:
	return []

## Whether the actor uses its female models; an ActorBase is not female.
func is_female() -> bool:
	return false

## Where the actor's animation KFs are found, for the actor node; none here.
func animation_search_paths() -> PackedStringArray:
	return PackedStringArray()

func has_pc_level_mult() -> bool:
	return (acbs_flags & FLAG_PC_LEVEL_MULT) != 0
