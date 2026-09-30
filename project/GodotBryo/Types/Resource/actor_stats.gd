@tool
class_name ActorStats
extends Resource

## The authored stats of an NPC_ or CREA record: ACBS, DATA, DNAM (NPC_) and
## AIDT. ActorValues derives an actor's base values from these.

## ACBS flag: level is a multiple of the player's level.
const FLAG_PC_LEVEL_MULT := 0x80
## ACBS template flags: which parts come from the TPLT record (xEdit
## `wbTemplateFlags`). Traits covers the Female flag and VTCK; Factions SNAM.
const TEMPLATE_USE_TRAITS := 0x01
const TEMPLATE_USE_STATS := 0x02
const TEMPLATE_USE_FACTIONS := 0x04
const TEMPLATE_USE_AI_DATA := 0x10

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var is_creature: bool = false

## The NPC_ or CREA record that supplies `record`'s part named by the template
## flag `flag`: `record` itself, or the template it takes that part from,
## followed while each record takes it from its template. A template that is
## not an NPC_ or CREA (a leveled list) is not followed.
static func template_source(record: EsmBase, flag: int) -> EsmBase:
	var esm_server := EsmReference.get_esm_server()
	for _depth in 8:
		var stats: ActorStats = record.get("actor_stats") if record != null else null
		if stats == null or (stats.template_flags & flag) == 0 or stats.template_form_id == 0 or esm_server == null:
			return record
		var template: EsmBase = esm_server.get_base(stats.template_form_id)
		if template == null or template.get("actor_stats") == null:
			return record
		record = template
	return record
## ACBS flags.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var flags: int = 0
## ACBS level; with FLAG_PC_LEVEL_MULT it is the multiplier x 1000.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var level: int = 1
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var calc_min: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var calc_max: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var fatigue: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var speed_mult: int = 100
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var karma: float = 0.0
## ACBS template flags and the TPLT record they take parts from (0 if none).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var template_flags: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var template_form_id: int = 0
## NPC_ DATA base health or CREA DATA health.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var base_health: int = 0
## Strength, Perception, Endurance, Charisma, Intelligence, Agility, Luck.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var attributes := PackedInt32Array([0, 0, 0, 0, 0, 0, 0])
## NPC_ DNAM skill values, Barter (32) through Unarmed (45); empty for CREA.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skills := PackedInt32Array()
## CREA DATA combat, magic and stealth skills and damage.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var combat_skill: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var magic_skill: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var stealth_skill: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var damage: int = 0
## AIDT: aggression, confidence, energy, responsibility, mood, assistance.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var aggression: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var confidence: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var energy: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var responsibility: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var mood: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var assistance: int = 0

func has_pc_level_mult() -> bool:
	return (flags & FLAG_PC_LEVEL_MULT) != 0
