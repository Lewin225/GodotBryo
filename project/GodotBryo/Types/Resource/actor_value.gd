@tool
class_name ActorValue
extends RefCounted

## Actor value codes (the GECK's Actor Value Codes, 0-76), their script names,
## and how each one's base value derives from an actor's ActorStats.

enum {
	AGGRESSION, CONFIDENCE, ENERGY, RESPONSIBILITY, MOOD,
	STRENGTH, PERCEPTION, ENDURANCE, CHARISMA, INTELLIGENCE, AGILITY, LUCK,
	ACTION_POINTS, CARRY_WEIGHT, CRIT_CHANCE, HEAL_RATE, HEALTH, MELEE_DAMAGE,
	DAMAGE_RESIST, POISON_RESIST, RAD_RESIST, SPEED_MULT, FATIGUE, KARMA, XP,
	PERCEPTION_CONDITION, ENDURANCE_CONDITION, LEFT_ATTACK_CONDITION,
	RIGHT_ATTACK_CONDITION, LEFT_MOBILITY_CONDITION, RIGHT_MOBILITY_CONDITION,
	BRAIN_CONDITION,
	BARTER, BIG_GUNS, ENERGY_WEAPONS, EXPLOSIVES, LOCKPICK, MEDICINE,
	MELEE_WEAPONS, REPAIR, SCIENCE, GUNS, SNEAK, SPEECH, SURVIVAL, UNARMED,
	INVENTORY_WEIGHT, PARALYSIS, INVISIBILITY, CHAMELEON, NIGHT_EYE, TURBO,
	FIRE_RESIST, WATER_BREATHING, RADIATION_RADS, BLOODY_MESS, UNARMED_DAMAGE,
	ASSISTANCE, ELECTRIC_RESIST, FROST_RESIST, ENERGY_RESIST, EMP_RESIST,
	VARIABLE01, VARIABLE02, VARIABLE03, VARIABLE04, VARIABLE05, VARIABLE06,
	VARIABLE07, VARIABLE08, VARIABLE09, VARIABLE10,
	IGNORE_CRIPPLED_LIMBS, DEHYDRATION, HUNGER, SLEEP_DEPRIVATION,
	DAMAGE_THRESHOLD,
	COUNT,
}

## Script names by code, as the GECK spells them.
const NAMES := [
	"Aggression", "Confidence", "Energy", "Responsibility", "Mood",
	"Strength", "Perception", "Endurance", "Charisma", "Intelligence", "Agility", "Luck",
	"ActionPoints", "CarryWeight", "CritChance", "HealRate", "Health", "MeleeDamage",
	"DamageResist", "PoisonResist", "RadResist", "SpeedMult", "Fatigue", "Karma", "XP",
	"PerceptionCondition", "EnduranceCondition", "LeftAttackCondition",
	"RightAttackCondition", "LeftMobilityCondition", "RightMobilityCondition",
	"BrainCondition",
	"Barter", "BigGuns", "EnergyWeapons", "Explosives", "Lockpick", "Medicine",
	"MeleeWeapons", "Repair", "Science", "Guns", "Sneak", "Speech", "Survival", "Unarmed",
	"InventoryWeight", "Paralysis", "Invisibility", "Chameleon", "NightEye", "Turbo",
	"FireResist", "WaterBreathing", "RadiationRads", "BloodyMess", "UnarmedDamage",
	"Assistance", "ElectricResist", "FrostResist", "EnergyResist", "EmpResist",
	"Variable01", "Variable02", "Variable03", "Variable04", "Variable05", "Variable06",
	"Variable07", "Variable08", "Variable09", "Variable10",
	"IgnoreCrippledLimbs", "Dehydration", "Hunger", "SleepDeprevation",
	"DamageThreshold",
]

## Other names scripts may use for a code.
const ALIASES := {"smallguns": GUNS, "sleepdeprivation": SLEEP_DEPRIVATION}

## Engine defaults of the derivation game settings (GECK's list of game
## settings). FalloutNV.esm's GMST records override these where present.
const DEFAULT_SETTINGS := {
	"fAVDActionPointsBase": 65.0, "fAVDActionPointsMult": 3.0,
	"fAVDCarryWeightsBase": 150.0, "fAVDCarryWeightMult": 10.0,
	"fAVDCritLuckBase": 0.0, "fAVDCritLuckMult": 1.0,
	"fAVDDefaultBodyPartCondition": 100.0,
	"fAVDHealRateEndurance6Bonus": 5.0, "fAVDHealRateEndurance7Bonus": 5.0,
	"fAVDHealRateEndurance8Bonus": 5.0, "fAVDHealRateEndurance9Bonus": 10.0,
	"fAVDHealRateEndurance10Bonus": 10.0,
	"fAVDHealthEnduranceMult": 20.0, "fAVDHealthEnduranceOffset": 0.0, "fAVDHealthLevelMult": 5.0,
	"fAVDNPCHealthEnduranceMult": 5.0, "fAVDNPCHealthEnduranceOffset": -1.0, "fAVDNPCHealthLevelMult": 5.0,
	"fAVDMeleeDamageStrengthMult": 0.5, "fAVDMeleeDamageStrengthOffset": 0.0,
	"fAVDPoisonResistEnduranceMult": 5.0, "fAVDPoisonResistEnduranceOffset": -1.0,
	"fAVDRadResistEnduranceMult": 2.0, "fAVDRadResistEnduranceOffset": -1.0,
	"fAVDUnarmedDamageBase": 0.5, "fAVDUnarmedDamageMult": 0.05,
}

static var _by_name: Dictionary = {}

## The code for a script name (case-insensitive), or -1.
static func from_name(name: String) -> int:
	if _by_name.is_empty():
		for i in NAMES.size():
			_by_name[String(NAMES[i]).to_lower()] = i
		_by_name.merge(ALIASES)
	return int(_by_name.get(name.to_lower(), -1))

## A derivation game setting: FalloutNV.esm's GMST value, else the engine
## default.
static func setting(name: String) -> float:
	var esm_server := EsmReference.get_esm_server()
	if esm_server != null and esm_server.is_ready():
		var value: Variant = esm_server.get_game_setting(name)
		if value is float or value is int:
			return float(value)
	return float(DEFAULT_SETTINGS.get(name, 0.0))

## An actor's base value of `code`, derived from its stats and level.
## `is_player` selects the player's Health formula over the NPC one.
static func derive_base(code: int, stats: ActorStats, level: int, is_player: bool) -> float:
	if stats == null:
		return 0.0
	match code:
		AGGRESSION: return stats.aggression
		CONFIDENCE: return stats.confidence
		ENERGY: return stats.energy
		RESPONSIBILITY: return stats.responsibility
		MOOD: return stats.mood
		ASSISTANCE: return stats.assistance
		STRENGTH, PERCEPTION, ENDURANCE, CHARISMA, INTELLIGENCE, AGILITY, LUCK:
			return stats.attributes[code - STRENGTH]
		ACTION_POINTS:
			return setting("fAVDActionPointsBase") + _attribute(stats, AGILITY) * setting("fAVDActionPointsMult")
		CARRY_WEIGHT:
			return setting("fAVDCarryWeightsBase") + _attribute(stats, STRENGTH) * setting("fAVDCarryWeightMult")
		CRIT_CHANCE:
			return setting("fAVDCritLuckBase") + _attribute(stats, LUCK) * setting("fAVDCritLuckMult")
		HEAL_RATE:
			var endurance := clampi(_attribute(stats, ENDURANCE), 0, 10)
			return setting("fAVDHealRateEndurance%dBonus" % endurance) if endurance >= 6 else 0.0
		HEALTH:
			return _health(stats, level, is_player)
		MELEE_DAMAGE:
			return (_attribute(stats, STRENGTH) + setting("fAVDMeleeDamageStrengthOffset")) * setting("fAVDMeleeDamageStrengthMult")
		POISON_RESIST:
			return (_attribute(stats, ENDURANCE) + setting("fAVDPoisonResistEnduranceOffset")) * setting("fAVDPoisonResistEnduranceMult")
		RAD_RESIST:
			return (_attribute(stats, ENDURANCE) + setting("fAVDRadResistEnduranceOffset")) * setting("fAVDRadResistEnduranceMult")
		SPEED_MULT: return stats.speed_mult
		FATIGUE: return stats.fatigue
		KARMA: return stats.karma
		PERCEPTION_CONDITION, ENDURANCE_CONDITION, LEFT_ATTACK_CONDITION, RIGHT_ATTACK_CONDITION, \
				LEFT_MOBILITY_CONDITION, RIGHT_MOBILITY_CONDITION, BRAIN_CONDITION:
			return setting("fAVDDefaultBodyPartCondition")
		UNARMED_DAMAGE:
			return setting("fAVDUnarmedDamageBase") + derive_base(UNARMED, stats, level, is_player) * setting("fAVDUnarmedDamageMult")
	if code >= BARTER and code <= UNARMED and code - BARTER < stats.skills.size():
		return stats.skills[code - BARTER]
	return 0.0

## Health: the authored base health plus Endurance and level terms. The
## player uses fAVDHealth*, other NPCs fAVDNPCHealth*; creatures use their
## DATA health alone.
static func _health(stats: ActorStats, level: int, is_player: bool) -> float:
	if stats.is_creature:
		return stats.base_health
	var prefix := "fAVDHealth" if is_player else "fAVDNPCHealth"
	var endurance := _attribute(stats, ENDURANCE)
	return stats.base_health \
			+ (endurance + setting(prefix + "EnduranceOffset")) * setting(prefix + "EnduranceMult") \
			+ maxi(level - 1, 0) * setting(prefix + "LevelMult")

static func _attribute(stats: ActorStats, code: int) -> int:
	return stats.attributes[code - STRENGTH]
