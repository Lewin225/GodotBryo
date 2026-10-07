extends Node

## For the humanoid idle tree (top-level IDLEs whose MODL is a folder or KF
## under Characters\_Male\, and everything below them): each condition
## function the items use, how many items use it, and whether ScriptServer
## implements it (unimplemented functions read 0), and each root's own
## conditions. Arguments after `--` limit it to those roots.
## DATA's animation group section, low six bits (xEdit wbIdleAnam).
const SECTION_NAMES := {0: "Idle", 1: "Movement", 2: "Left Arm", 3: "Left Hand", 4: "Weapon", 5: "Weapon Up", 6: "Weapon Down", 7: "Special Idle", 20: "Whole Body", 21: "Upper Body"}

## "<section> under <root>" -> editor IDs, for the Movement and Weapon items.
var _examples := {}

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var tree := ScriptServer.idle_tree
	var roots: Array[IdleBase] = []
	for row: Dictionary in EsmServer.get_record_index():
		if String(row.get("record_type", "")) != "IDLE":
			continue
		var idle := EsmServer.get_base(int(row["form_id"])) as IdleBase
		if idle != null and idle.parent == null and not tree.get_children(idle).is_empty() and idle.model_path.to_lower().begins_with("characters\\_male\\"):
			var only: PackedStringArray = OS.get_cmdline_user_args()
			if only.is_empty() or only.has(idle.editor_id):
				roots.append(idle)
	var names := PackedStringArray()
	for root in roots:
		names.append(root.editor_id)
	print("humanoid roots with children: %s" % ", ".join(names))
	for root in roots:
		var root_conditions := PackedStringArray()
		for condition in root.conditions:
			var function_name := ScriptConditionFunctions.name_for_index(condition.function_index)
			var missing := "" if ScriptServer.function_registry.is_registered(function_name) else " (NOT IMPLEMENTED)"
			root_conditions.append("%s %s %s%s" % [function_name, ["==", "!=", ">", ">=", "<", "<="][condition.comparison], condition.comparison_value, missing])
		print("  %s's own conditions: %s" % [root.editor_id, "; ".join(root_conditions)])
	var uses := {}
	var sections := {}
	var per_root := {}
	for root in roots:
		var below: Array = [root]
		var kf_count := 0
		var group_count := 0
		while not below.is_empty():
			var node: IdleBase = below.pop_back()
			if node.has_kf():
				kf_count += 1
			else:
				group_count += 1
			below.append_array(tree.get_children(node))
		per_root[root.editor_id] = "%d with a KF, %d grouping" % [kf_count, group_count]
	print("per root: %s" % per_root)
	var stack: Array = roots.duplicate()
	var items := 0
	while not stack.is_empty():
		var item: IdleBase = stack.pop_back()
		items += 1
		var section_name: String = SECTION_NAMES.get(item.animation_group_section & 0x3F, "#%d" % (item.animation_group_section & 0x3F))
		sections[section_name] = int(sections.get(section_name, 0)) + 1
		if section_name == "Movement" or section_name == "Weapon":
			var top := item
			while top.parent != null:
				top = top.parent
			var key := "%s under %s" % [section_name, top.editor_id]
			if not _examples.has(key):
				_examples[key] = PackedStringArray()
			_examples[key].append(item.editor_id)
		for condition in item.conditions:
			var name := ScriptConditionFunctions.name_for_index(condition.function_index)
			uses[name] = int(uses.get(name, 0)) + 1
		stack.append_array(tree.get_children(item))
	print("items %d; by animation group section: %s" % [items, sections])
	for key: String in _examples:
		var names_in: PackedStringArray = _examples[key]
		print("  %s (%d): %s" % [key, names_in.size(), ", ".join(names_in.slice(0, 8))])
	var registry: ScriptFunctionRegistry = ScriptServer.function_registry
	var keys := uses.keys()
	keys.sort_custom(func(a: String, b: String) -> bool: return uses[a] > uses[b])
	for name: String in keys:
		print("  %4d %s %s" % [uses[name], name, "" if registry.is_registered(name) else "NOT IMPLEMENTED"])
	get_tree().quit()
