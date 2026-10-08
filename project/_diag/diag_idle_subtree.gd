extends Node

## Prints the idle tree below the named top-level item, indented, each item
## with its KF (or "group") and its conditions (parameter, OR flag), to the
## depth given as the second argument (all when absent).
func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var root := ScriptServer.idle_tree.get_root(OS.get_cmdline_user_args()[0])
	var args := OS.get_cmdline_user_args()
	_max_depth = int(args[1]) if args.size() > 1 else 99
	_print(root, 0)
	get_tree().quit()

var _max_depth := 99

func _print(item: IdleBase, depth: int) -> void:
	if depth > _max_depth:
		return
	var parts := PackedStringArray()
	for condition in item.conditions:
		var named := EsmServer.get_base(condition.parameter_1)
		var parameter := "(%s)" % named.editor_id if named != null else ("(%d)" % condition.parameter_1 if condition.parameter_1 != 0 else "")
		var joiner := " OR" if (condition.flags & 1) != 0 else ""
		parts.append("%s%s %s %s%s" % [ScriptConditionFunctions.name_for_index(condition.function_index), parameter, ["==", "!=", ">", ">=", "<", "<="][condition.comparison], condition.comparison_value, joiner])
	print("%s%s [%s] %s" % ["  ".repeat(depth), item.editor_id, item.model_path.get_file() if item.has_kf() else "group", "; ".join(parts)])
	for child: IdleBase in ScriptServer.idle_tree.get_children(item):
		_print(child, depth + 1)
