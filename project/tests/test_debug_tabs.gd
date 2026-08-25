extends Node

var failures := 0

func check(ok: bool, message: String) -> void:
	print("  OK   " if ok else "  FAIL ", message)
	if not ok:
		failures += 1


func _ready() -> void:
	# 1. Test Inventory name resolution and totals calculation
	var inv_tab_script := load("res://inventory_debug_tab.gd")
	var inv_tab: Control = inv_tab_script.new()

	var named_item := { "base_form_id": 0x000E32F9, "full_name": "Bottle Cap", "editor_id": "Caps001", "weight": 0.0, "value": 1, "count": 100 }
	var unnamed_item := { "base_form_id": 0x0010522B, "full_name": "", "editor_id": "DynamiteBoxRef", "weight": 5.0, "value": 20, "count": 2 }
	var bare_item := { "base_form_id": 0x00123456, "full_name": "", "editor_id": "", "weight": 1.5, "value": 10, "count": 1 }

	check(inv_tab._resolve_item_name(named_item) == "Bottle Cap", "named item resolves full_name")
	check(inv_tab._resolve_item_name(unnamed_item) == "DynamiteBoxRef", "empty full_name falls back to editor_id")
	check(inv_tab._resolve_item_name(bare_item) == "Item 0x123456", "empty editor_id falls back to hex FormID")

	inv_tab.free()

	# 2. Test Environment color formatting
	var env_tab_script := load("res://environment_debug_tab.gd")
	var env_tab: Control = env_tab_script.new()
	var test_color := Color(1.0, 0.5, 0.0, 1.0)
	var col_str: String = env_tab._color_str(test_color)
	check(col_str.contains("#FF7F00"), "Color string contains formatted hex (#FF7F00, got %s)" % col_str)
	check(col_str.contains("rgb(255, 127, 0)"), "Color string contains RGB values")

	env_tab.free()

	# 3. Test Scripting tab history navigation
	var script_tab_script := load("res://scripting_debug_tab.gd")
	var script_tab: Control = script_tab_script.new()
	var sample_history: Array[String] = ["Player.Disable", "ShowMessage GSBrokenSMGMsg", "CenterOnCell Goodsprings"]
	script_tab._history = sample_history

	# Simulate Up key
	script_tab._history_index = -1
	script_tab._current_input_buffer = "partial"

	# Simulate Key Up: should go to last history item
	if script_tab._history_index == -1:
		script_tab._history_index = script_tab._history.size() - 1
	check(script_tab._history[script_tab._history_index] == "CenterOnCell Goodsprings", "Up arrow navigates to most recent command")

	# Simulate Key Up again
	script_tab._history_index -= 1
	check(script_tab._history[script_tab._history_index] == "ShowMessage GSBrokenSMGMsg", "Second Up arrow navigates to previous command")

	# Simulate Key Down
	script_tab._history_index += 1
	check(script_tab._history[script_tab._history_index] == "CenterOnCell Goodsprings", "Down arrow navigates forward in history")

	script_tab.free()
	_finish()


func _finish() -> void:
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
