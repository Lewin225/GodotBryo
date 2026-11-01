@tool
class_name LeveledActorResolver
extends RefCounted

## Chooses the NPC_ or CREA a leveled list (LVLN, LVLC) gives at a level,
## following lists inside lists. ActorReference.leveled_template keeps the
## choice.
##
## Eligible entries are those at or below the level. In Mode.LIST, without
## LVLF 0x01 only the eligible entries at the highest of their levels remain;
## Mode.ALL_AT_OR_BELOW keeps them all and Mode.CLOSEST keeps only the highest,
## whatever LVLF says (a reference's XLCM). One of them is chosen at random. A list with no entry at or below the level (64 LVLN in
## FalloutNV.esm have none at level 1) takes its lowest-level entries instead,
## so the actor still has a template.

const MAX_DEPTH := 8

## Which eligible entries remain: by the list's LVLF 0x01, all of them, or
## those at the highest level.
enum Mode { LIST, ALL_AT_OR_BELOW, CLOSEST }


## The actor `list` gives at `level`, choosing with `rng`; null when the list
## gives none (Chance None, no entries, or lists nested past MAX_DEPTH).
static func resolve(list: LeveledActorBase, level: int, rng: RandomNumberGenerator, mode := Mode.LIST) -> ActorBase:
	var current: EsmBase = list
	for _depth in MAX_DEPTH:
		if current is ActorBase:
			return current as ActorBase
		var leveled := current as LeveledActorBase
		if leveled == null:
			return null
		if leveled.chance_none > 0 and rng.randi_range(0, 99) < leveled.chance_none:
			return null
		var candidates := _candidates(leveled, level, mode)
		if candidates.is_empty():
			return null
		current = candidates[rng.randi_range(0, candidates.size() - 1)].actor
	return current as ActorBase


static func _candidates(list: LeveledActorBase, level: int, mode: Mode) -> Array[LeveledActorEntryCollection]:
	var eligible: Array[LeveledActorEntryCollection] = []
	for entry in list.entries:
		if entry.actor != null and entry.level <= level:
			eligible.append(entry)
	if eligible.is_empty():
		return _at_level(list.entries, _lowest_level(list.entries))
	if mode == Mode.ALL_AT_OR_BELOW:
		return eligible
	if mode == Mode.LIST and list.calculate_from_all_levels():
		return eligible
	return _at_level(eligible, _highest_level(eligible))


static func _at_level(entries: Array[LeveledActorEntryCollection], level: int) -> Array[LeveledActorEntryCollection]:
	var result: Array[LeveledActorEntryCollection] = []
	for entry in entries:
		if entry.actor != null and entry.level == level:
			result.append(entry)
	return result


static func _highest_level(entries: Array[LeveledActorEntryCollection]) -> int:
	var highest := -32768
	for entry in entries:
		highest = maxi(highest, entry.level)
	return highest


static func _lowest_level(entries: Array[LeveledActorEntryCollection]) -> int:
	var lowest := 32767
	for entry in entries:
		if entry.actor != null:
			lowest = mini(lowest, entry.level)
	return lowest
