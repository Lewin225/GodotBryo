@tool
class_name ActorValues
extends Resource

## One actor's actor values. Base values derive from its base record (an
## ActorBase, following templates that supply stats) through ActorValue; this
## stores what scripts and gameplay change on top of them, per code:
##   current = base + permanent + damage
## SetAV replaces the base, ModAV and ForceAV change the permanent modifier,
## DamageAV and RestoreAV the damage modifier, which is never above 0.

## Base values set by SetAV, by code. They replace the derived base.
@export var base_overrides: Dictionary = {}
## Permanent modifiers (ModAV, ForceAV), by code.
@export var permanent: Dictionary = {}
## Damage modifiers (DamageAV, RestoreAV), by code; always <= 0.
@export var damage: Dictionary = {}

## Every actor value's current value by script name, for inspection. Not
## saved.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var current_values: Dictionary:
	get:
		var values := {}
		for code in ActorValue.COUNT:
			values[ActorValue.NAMES[code]] = get_current(code)
		return values

## The actor these values belong to. Runtime only; held weakly, since the
## actor holds these values.
var owner: EsmReference:
	get:
		return _owner.get_ref() if _owner != null else null
	set(value):
		_owner = weakref(value) if value != null else null
var _owner: WeakRef = null

func get_base(code: int) -> float:
	if base_overrides.has(code):
		return float(base_overrides[code])
	return ActorValue.derive_base(code, get_stats(), get_level(), _is_player())

## Base plus permanent modifiers (GetPermanentActorValue).
func get_permanent(code: int) -> float:
	return get_base(code) + float(permanent.get(code, 0.0))

## The current value (GetActorValue).
func get_current(code: int) -> float:
	return get_permanent(code) + float(damage.get(code, 0.0))

func set_base(code: int, value: float) -> void:
	base_overrides[code] = value

func modify(code: int, amount: float) -> void:
	permanent[code] = float(permanent.get(code, 0.0)) + amount

## Changes the permanent modifier so the current value becomes `value`.
func force(code: int, value: float) -> void:
	modify(code, value - get_current(code))

func damage_value(code: int, amount: float) -> void:
	damage[code] = float(damage.get(code, 0.0)) - amount

func restore_value(code: int, amount: float) -> void:
	damage[code] = minf(float(damage.get(code, 0.0)) + amount, 0.0)

## Current Health over base Health; 1.0 when base Health is 0.
func health_percentage() -> float:
	var base_health := get_base(ActorValue.HEALTH)
	return get_current(ActorValue.HEALTH) / base_health if base_health != 0.0 else 1.0

## The actor's level: its ACBS level, or the player's level times its level
## multiplier, clamped to its calc min and max (a max of 0 is no max).
func get_level() -> int:
	var stats := get_stats()
	if stats == null:
		return 1
	if not stats.has_pc_level_mult():
		return maxi(stats.level, 1)
	var player_level := 1
	var esm_server := EsmReference.get_esm_server()
	var player: EsmReference = esm_server.get_player_reference() if esm_server != null and esm_server.is_ready() else null
	if player != null and player != owner and player.get_actor_values() != null:
		player_level = player.get_actor_values().get_level()
	var level := maxi(roundi(player_level * stats.level / 1000.0), 1)
	level = maxi(level, stats.calc_min)
	if stats.calc_max > 0:
		level = mini(level, stats.calc_max)
	return level

## The record the base values derive from: the base record, or its template
## chain's while each record takes its stats from its template.
func get_stats() -> ActorBase:
	return ActorBase.template_source(owner.base if owner != null else null, ActorBase.TEMPLATE_USE_STATS)

func _is_player() -> bool:
	var esm_server := EsmReference.get_esm_server()
	return owner != null and esm_server != null and owner.instance_id == esm_server.PLAYER_INSTANCE_ID
