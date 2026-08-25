extends Node

const GameDataConfigScript := preload("res://game_data_config.gd")

var failures := 0


func check(condition: bool, message: String) -> void:
	if condition:
		print("  OK   ", message)
	else:
		print("  FAIL ", message)
		failures += 1


func _ready() -> void:
	var invalid_existing_dir := ProjectSettings.globalize_path("res://tests/")
	var valid_data_dir := ProjectSettings.globalize_path("res://../fresh_nv_copy/Data/")
	var config = GameDataConfigScript.resolve_from_candidates("", [invalid_existing_dir, valid_data_dir])
	check(String(config.get("error", "")) == "", "candidate discovery finds the installed data directory")
	check(String(config.get("data_dir", "")) == GameDataConfigScript.normalise_data_dir(valid_data_dir), "existing directory without FalloutNV.esm does not mask a later valid candidate")

	var invalid_override = GameDataConfigScript.resolve_from_candidates(invalid_existing_dir, [valid_data_dir])
	check(not String(invalid_override.get("error", "")).is_empty(), "invalid environment override reports a clear error")
	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
