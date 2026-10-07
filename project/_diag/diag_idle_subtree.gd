extends Node

## Prints the idle tree below the named top-level item, indented, each item
## with its KF (or "group") and its conditions.
func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var root := ScriptServer.idle_tree.get_root(OS.get_cmdline_user_args()[0])
	_print(root, 0)
	get_tree().quit()

func _print(item: IdleBase, depth: int) -> void:
	var parts := PackedStringArray()
	for condition in item.conditions:
		var named := EsmServer.get_base(condition.parameter_1)
		parts.append("%s%s %s %s" % [ScriptConditionFunctions.name_for_index(condition.function_index), "(%s)" % named.editor_id if named != null else "", ["==", "!=", ">", ">=", "<", "<="][condition.comparison], condition.comparison_value])
	print("%s%s [%s] %s" % ["  ".repeat(depth), item.editor_id, item.model_path.get_file() if item.has_kf() else "group", "; ".join(parts)])
	for child: IdleBase in ScriptServer.idle_tree.get_children(item):
		_print(child, depth + 1)
