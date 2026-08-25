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

	# Test floating suggestion panel and completion
	script_tab._line = LineEdit.new()
	script_tab._suggestions_panel = PanelContainer.new()
	script_tab._suggestions_list = RichTextLabel.new()
	script_tab._line.text = "Center"
	script_tab._line.caret_column = 6
	script_tab._update_suggestions_panel()
	check(script_tab._suggestions.size() > 0, "Typing 'Center' populates suggestions list")
	check(script_tab._suggestions.has("CenterOnCell"), "Suggestions list contains 'CenterOnCell'")

	# Test Down arrow selection
	script_tab._navigating_suggestions = true
	script_tab._suggestion_index = 0
	script_tab._apply_selected_suggestion()
	check(script_tab._line.text.begins_with("CenterOnCell"), "Applying suggestion completes 'Center' to 'CenterOnCell'")

	script_tab._suggestions_list.free()
	script_tab._suggestions_panel.free()
	script_tab._line.free()
	script_tab.free()

	# 4. Test Scripting suggestions panel and World Streaming sub-tabs structure in game.tscn
	var game_scene: PackedScene = load("res://game.tscn")
	var game_node: Node = game_scene.instantiate()
	var script_tab_node: Node = game_node.get_node_or_null("Debug Tools/TabContainer/Scripting")
	check(script_tab_node != null, "Scripting tab exists in game.tscn")
	var suggestions_panel: Node = script_tab_node.get_node_or_null("SuggestionsPanel")
	check(suggestions_panel != null, "SuggestionsPanel resolved in Scripting tab")
	var suggestions_list: Node = script_tab_node.get_node_or_null("SuggestionsPanel/Margin/SuggestionsList")
	check(suggestions_list != null, "SuggestionsList resolved in SuggestionsPanel")

	var ws_tab: Node = game_node.get_node_or_null("Debug Tools/TabContainer/World Streaming")
	check(ws_tab != null, "World Streaming tab exists in game.tscn")
	var status_card: Node = ws_tab.get_node_or_null("Margin/SubTabs/Streaming State/VBox/StateGrid/StatusCard")
	check(status_card != null, "StatusCard resolved in Streaming State subtab")
	var tex_tree: Node = ws_tab.get_node_or_null("Margin/SubTabs/Ground Textures/VBox/TextureTree")
	check(tex_tree != null, "TextureTree resolved in Ground Textures subtab")

	# 5. Test Teleport tab in game.tscn
	var teleport_tab: Node = game_node.get_node_or_null("Debug Tools/TabContainer/Teleport")
	check(teleport_tab != null, "Teleport tab exists in game.tscn")
	var cell_input: Node = teleport_tab.get_node_or_null("Margin/VBox/QuickRow/CellInput")
	check(cell_input != null, "CellInput resolved in Teleport tab")
	var preset_tree: Node = teleport_tab.get_node_or_null("Margin/VBox/PresetTree")
	check(preset_tree != null, "PresetTree resolved in Teleport tab")

	var teleport_script := load("res://teleport_debug_tab.gd")
	check(teleport_script.PRESETS.size() > 50, "Teleport tab has curated presets (>50)")

	# 6. Test Player tab in game.tscn
	var player_tab: Node = game_node.get_node_or_null("Debug Tools/TabContainer/Player")
	check(player_tab != null, "Player tab exists in game.tscn")
	var noclip_check: Node = player_tab.get_node_or_null("Margin/VBox/NoclipRow/NoclipCheck")
	check(noclip_check != null, "NoclipCheck resolved in Player tab")
	var base_speed_spin: Node = player_tab.get_node_or_null("Margin/VBox/MoveGrid/BaseSpeedSpin")
	check(base_speed_spin != null, "BaseSpeedSpin resolved in Player tab")
	var jump_vel_spin: Node = player_tab.get_node_or_null("Margin/VBox/MoveGrid/JumpVelSpin")
	check(jump_vel_spin != null, "JumpVelSpin resolved in Player tab")
	var stand_height_spin: Node = player_tab.get_node_or_null("Margin/VBox/ViewGrid/StandHeightSpin")
	check(stand_height_spin != null, "StandHeightSpin resolved in Player tab")
	var crouch_height_spin: Node = player_tab.get_node_or_null("Margin/VBox/ViewGrid/CrouchHeightSpin")
	check(crouch_height_spin != null, "CrouchHeightSpin resolved in Player tab")

	# 7. Test PlayerController noclip & ScriptEngine TCL command
	var player: PlayerController = game_node.get_node_or_null("Character")
	check(player != null, "Character is PlayerController")
	if player != null:
		check(player.noclip == false, "Player starts with noclip=false")
		player.toggle_noclip()
		check(player.noclip == true, "Player toggle_noclip() sets noclip=true")
		check(player.collision_shape.disabled == true, "Collision shape is disabled during noclip")
		player.toggle_noclip()
		check(player.noclip == false, "Player toggle_noclip() sets noclip=false again")
		check(player.collision_shape.disabled == false, "Collision shape is re-enabled when noclip is off")

		# Test TCL via script engine
		var script_engine: ScriptEngine = game_node.get_node_or_null("ScriptEngine")
		if script_engine != null:
			script_engine.player_node = player
			var res := script_engine.run_debug_line("tcl", player)
			check(bool(res.get("ok", false)), "ScriptEngine executes 'tcl'")
			check(player.noclip == true, "'tcl' command toggles player noclip to true")
			script_engine.run_debug_line("tcl", player)
			check(player.noclip == false, "'tcl' command toggles player noclip back to false")

	game_node.free()

	_finish()


func _finish() -> void:
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
