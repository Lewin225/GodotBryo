@tool
class_name LeveledItemResolver
extends RefCounted

## Resolves authored LVLI data into concrete InventoryItems. The caller passes
## one actor level; player level is not a separate concept.

## TODO - This is probbaly inaccurate to what a real LVLI would return, but it can be improved as we go

const MAX_DEPTH := 32

var server

func _init(esm_server = null) -> void:
	server = esm_server

func resolve(list: LeveledItemBase, level: int, context: Dictionary = {}) -> Array[InventoryItem]:
	var result: Array[InventoryItem] = []
	if list == null:
		return result
	var stack: Array[int] = []
	_resolve_list(list, level, context, result, stack, 0, 1)
	return result

func _resolve_list(list: LeveledItemBase, level: int, context: Dictionary, output: Array[InventoryItem], stack: Array[int], depth: int, multiplier: int) -> void:
	if depth > MAX_DEPTH or list.form_id in stack:
		list.diagnostics.append("LVLI recursion stopped at 0x%08X" % list.form_id)
		return
	stack.append(list.form_id)
	var rng: RandomNumberGenerator = context.get("rng")
	if rng == null:
		rng = RandomNumberGenerator.new()
		rng.seed = int(context.get("seed", list.form_id)) + depth
	var chance := _chance_none(list, context)
	if chance > 0 and rng.randi_range(0, 99) < chance:
		stack.pop_back()
		return
	var eligible: Array[LeveledItemEntryCollection] = []
	for entry in list.entries:
		if entry == null or entry.item_form_id == 0:
			continue
		if list.use_all() or entry.level <= level:
			eligible.append(entry)
	if not list.use_all() and not list.calculate_from_all_levels():
		eligible = _nearest_level_entries(eligible, level)
	elif not list.use_all() and int(context.get("level_difference_max", 0)) > 0:
		eligible = _within_level_difference(eligible, level, int(context.get("level_difference_max", 0)))
	if eligible.is_empty():
		stack.pop_back()
		return
	if list.use_all():
		for entry in eligible:
			_emit_entry(entry, level, context, output, stack, depth, multiplier * maxi(1, abs(entry.count)))
	else:
		var chosen := eligible[rng.randi_range(0, eligible.size() - 1)]
		var count := maxi(1, abs(chosen.count))
		if list.calculate_for_each_item_in_count():
			for _i in count:
				_emit_entry(chosen, level, context, output, stack, depth, multiplier)
		else:
			_emit_entry(chosen, level, context, output, stack, depth, multiplier * count)
	stack.pop_back()

func _emit_entry(entry: LeveledItemEntryCollection, level: int, context: Dictionary, output: Array[InventoryItem], stack: Array[int], depth: int, multiplier: int) -> void:
	var base := entry.item_base
	if base == null and server != null and server.has_method("get_base"):
		base = server.get_base(entry.item_form_id)
	if base == null:
		return
	if base is LeveledItemBase:
		_resolve_list(base, level, context, output, stack, depth + 1, multiplier)
		return
	if server == null or not server.has_method("create_inventory_item_reference"):
		return
	var item_ref: EsmReference = server.create_inventory_item_reference(base.form_id, "")
	if item_ref == null:
		return
	var item := InventoryItem.new()
	item.item_reference = item_ref
	item.count = maxi(1, multiplier)
	item.instance_id = "leveled:%08X:%d" % [base.form_id, output.size()]
	item.owner_form_id = entry.owner_form_id
	item.health_percent = entry.health_percent
	if item_ref is WeaponReference and entry.health_percent >= 0.0:
		(item_ref as WeaponReference).condition = entry.health_percent
	elif item_ref is ArmorReference and entry.health_percent >= 0.0:
		(item_ref as ArmorReference).condition = entry.health_percent
	item.compatibility_data["owner_form_id"] = entry.owner_form_id
	item.compatibility_data["health_percent"] = entry.health_percent
	output.append(item)

func _nearest_level_entries(entries: Array[LeveledItemEntryCollection], level: int) -> Array[LeveledItemEntryCollection]:
	if entries.is_empty():
		return entries
	var highest := -2147483648
	for entry in entries:
		highest = maxi(highest, entry.level)
	var result: Array[LeveledItemEntryCollection] = []
	for entry in entries:
		if entry.level == highest:
			result.append(entry)
	return result

func _within_level_difference(entries: Array[LeveledItemEntryCollection], level: int, limit: int) -> Array[LeveledItemEntryCollection]:
	if entries.is_empty():
		return entries
	var highest := -2147483648
	for entry in entries:
		highest = maxi(highest, entry.level)
	var result: Array[LeveledItemEntryCollection] = []
	for entry in entries:
		if highest - entry.level <= limit:
			result.append(entry)
	return result

func _chance_none(list: LeveledItemBase, context: Dictionary) -> int:
	var provider = context.get("global_value_provider")
	if list.global_form_id != 0 and provider is Callable and provider.is_valid():
		return clampi(int(provider.call(list.global_form_id)), 0, 100)
	if list.global_form_id != 0 and context.has("global_value"):
		return clampi(int(context.get("global_value")), 0, 100)
	return clampi(list.chance_none, 0, 100)
