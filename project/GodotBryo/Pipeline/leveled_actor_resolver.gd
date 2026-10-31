@tool
class_name LeveledActorResolver
extends RefCounted

## Chooses the NPC_ or CREA a leveled list (LVLN, LVLC) gives at a level,
## following lists inside lists. ActorReference.leveled_template keeps the
## choice.
##
## Eligible entries are those at or below the level. Without LVLF 0x01 only
## the eligible entries at the highest of their levels remain. One of them is
## chosen at random. A list with no entry at or below the level (64 LVLN in
## FalloutNV.esm have none at level 1) takes its lowest-level entries instead,
## so the actor still has a template.

const MAX_DEPTH := 8


## The actor `list` gives at `level`, choosing with `rng`; null when the list
## gives none (Chance None, no entries, or lists nested past MAX_DEPTH).
static func resolve(list: LeveledActorBase, level: int, rng: RandomNumberGenerator) -> ActorBase:
	var current: EsmBase = list
	for _depth in MAX_DEPTH:
		if current is ActorBase:
			return current as ActorBase
		var leveled := current as LeveledActorBase
		if leveled == null:
			return null
		if leveled.chance_none > 0 and rng.randi_range(0, 99) < leveled.chance_none:
			return null
		var candidates := _candidates(leveled, level)
		if candidates.is_empty():
			return null
		current = candidates[rng.randi_range(0, candidates.size() - 1)].actor
	return current as ActorBase


static func _candidates(list: LeveledActorBase, level: int) -> Array[LeveledActorEntryCollection]:
	var eligible: Array[LeveledActorEntryCollection] = []
	for entry in list.entries:
		if entry.actor != null and entry.level <= level:
			eligible.append(entry)
	if eligible.is_empty():
		return _at_level(list.entries, _lowest_level(list.entries))
	if list.calculate_from_all_levels():
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
