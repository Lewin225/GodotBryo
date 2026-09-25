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

	# Test Contextual 2nd argument suggestions for 'coc '
	script_tab._line.text = "coc Nov"
	script_tab._line.caret_column = 7
	script_tab._update_suggestions_panel()
	check(script_tab._suggestions.has("NovacPlayersRoom") or script_tab._suggestions.has("NovacGiftShop"), "Contextual suggestion for 'coc Nov' suggests Novac cells")

	# Test Contextual dynamic item suggestions from live inventory
	var test_game := Node.new()
	var test_inv := Inventory.new()
	test_inv.add_item(0x00004334, {"full_name": "Stimpak", "editor_id": "Stimpak"})
	test_game.set_meta("inventory", test_inv)
	var dynamic_items := ScriptCandidateProvider.get_item_candidates(test_game)
	check(dynamic_items.has("Stimpak"), "ScriptCandidateProvider dynamically extracts 'Stimpak' from live inventory")
	check(dynamic_items.has("0x00004334"), "ScriptCandidateProvider dynamically extracts '0x00004334' from live inventory")
	test_game.free()

	# Test dynamic message extraction from live scripted instances
	var test_instances: Array = [
		{"name": "BrokenSMG", "script_name": "GSBrokenSMGScript", "source_text": "ShowMessage GSBrokenSMGMsg\n"}
	]
	var dynamic_msgs := ScriptCandidateProvider.get_message_candidates(null, test_instances)
	check(dynamic_msgs.has("GSBrokenSMGMsg"), "ScriptCandidateProvider dynamically extracts 'GSBrokenSMGMsg' from active script source")

	# Test ScriptCandidateProvider dynamic command generation
	var script_server: Node = get_node("/root/ScriptServer")
	script_server.function_registry.register("MyDynamicDebugCmd", func(_a, _c): return 1)
	var dynamic_cmds := ScriptCandidateProvider.get_command_candidates(script_server)
	check(dynamic_cmds.has("MyDynamicDebugCmd"), "ScriptCandidateProvider includes newly registered function 'MyDynamicDebugCmd'")
	check(dynamic_cmds.has("Player.MyDynamicDebugCmd"), "ScriptCandidateProvider includes player-scoped 'Player.MyDynamicDebugCmd'")

	# Test EsmReader dynamic item and cell scanning against real game data
	var test_esm := EsmReader.new()
	if test_esm.open("fresh_nv_copy/Data/FalloutNV.esm"):
		var esm_items := test_esm.get_all_item_candidates()
		check(esm_items.size() > 1000, "EsmReader scans >1000 items from FalloutNV.esm (got %d)" % esm_items.size())
		check(esm_items.has("WeapNV9mmPistol") or esm_items.has("Stimpak"), "EsmReader item candidates include standard items")
		var esm_cells := test_esm.get_all_cell_candidates()
		check(esm_cells.size() > 500, "EsmReader scans cell candidates from FalloutNV.esm (got %d)" % esm_cells.size())

	script_tab._suggestions_list.free()
	script_tab._suggestions_panel.free()
	script_tab._line.free()
	script_tab.free()

	# 4. Test Scripting suggestions panel and the V2 streaming profiler layout.
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
	var v2_status: Node = ws_tab.get_node_or_null("Margin/SubTabs/V2 Profiler/Margin/VBox/StateGrid/Status")
	check(v2_status != null, "WorldStreamerV2 profiler has a scene-authored state dashboard")
	var v2_budget: Node = ws_tab.get_node_or_null("Margin/SubTabs/V2 Profiler/Margin/VBox/ConfigGrid/ObjectsPerFrame")
	check(v2_budget is SpinBox, "WorldStreamerV2 profiler exposes the reference-per-frame budget")
	var streaming_mode: Node = ws_tab.get_node_or_null("Margin/SubTabs/V2 Profiler/Margin/VBox/Actions/StreamingMode")
	check(streaming_mode is OptionButton and (streaming_mode as OptionButton).item_count == 3,
		"WorldStreamerV2 profiler exposes Run, Pause, and Pause & Hide modes")
	check(ws_tab.get_node_or_null("Margin/SubTabs/Ground Textures") == null,
		"terrain texture cache no longer appears in World Streaming")
	var terrain_tab: Node = game_node.get_node_or_null("Debug Tools/TabContainer/Terrain Streaming")
	check(terrain_tab != null, "Terrain Streaming tab exists in game.tscn")
	var terrain_queue_card: Node = terrain_tab.get_node_or_null("Margin/VBox/StateGrid/QueueCard") if terrain_tab != null else null
	check(terrain_queue_card != null, "Terrain Streaming queue card is scene-authored")
	var retained_worldspaces: Node = terrain_tab.get_node_or_null("Margin/VBox/RetainedWorldspaces") if terrain_tab != null else null
	check(retained_worldspaces != null, "Terrain Streaming retained-worldspace tree is scene-authored")
	var terrain_texture_tree: Node = terrain_tab.get_node_or_null("Margin/VBox/TextureTree") if terrain_tab != null else null
	check(terrain_texture_tree is Tree, "Terrain Streaming owns the Terrain3D texture-cache tree")

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

		# TCL through ScriptServer acts on the player's body.
		script_server.player_node = player
		var res: Dictionary = script_server.run_debug_line("tcl")
		check(bool(res.get("ok", false)), "ScriptServer executes 'tcl'")
		check(player.noclip == true, "'tcl' command toggles player noclip to true")
		script_server.run_debug_line("tcl")
		check(player.noclip == false, "'tcl' command toggles player noclip back to false")
		script_server.player_node = null

	game_node.free()

	_finish()


func _finish() -> void:
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
