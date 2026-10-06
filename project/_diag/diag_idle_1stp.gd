extends Node

## Every IDLE whose MODL path is a first-person clip (1stp / 1stperson /
## player camera clips), with its parent chain, and every IDLE naming the
## same file as a third-person counterpart.
func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var idles: Array[IdleBase] = []
	for entry in EsmServer.get_record_index():
		if String(entry.get("record_type", "")) != "IDLE":
			continue
		var idle := EsmServer.get_base(int(entry["form_id"])) as IdleBase
		if idle != null:
			idles.append(idle)
	print("IDLE total ", idles.size())
	for idle in idles:
		var path := idle.model_path.to_lower()
		if path.contains("1stp") or path.contains("1stperson"):
			var chain := []
			var node := idle.parent
			while node != null:
				chain.append(node.editor_id)
				node = node.parent
			print("%s  %s  parents %s  conditions %d" % [idle.editor_id, idle.model_path, " < ".join(chain), idle.conditions.size()])
			if idle.editor_id.contains("Dynamic") or idle.editor_id.contains("Pod"):
				_print_tree_conditions(idle)
	get_tree().quit()

## The idle's conditions, and each sibling under its parent with theirs.
func _print_tree_conditions(idle: IdleBase) -> void:
	for condition in idle.conditions:
		print("      %s fn %d %s %s p1 %08X run_on %d flags %d" % [idle.editor_id, condition.function_index, ["==", "!=", ">", ">=", "<", "<="][condition.comparison], condition.comparison_value, condition.parameter_1, condition.run_on, condition.flags])
