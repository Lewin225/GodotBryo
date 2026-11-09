extends Node

## The console (ConsoleSession, ConsoleCompleter, ConsoleOverlay) against
## FalloutNV.esm: completion narrowed by argument type, EditorID resolution
## and its warnings, FormID arguments, console commands, and the overlay's
## menu mode, completion and history.

var failures := 0
var _output: Array = []

func check(ok: bool, message: String) -> void:
	print("  OK   " if ok else "  FAIL ", message)
	if not ok:
		failures += 1

func _ready() -> void:
	var esm_server: Node = get_node("/root/EsmServer")
	if not esm_server.is_ready():
		await esm_server.esm_ready
	var script_server: Node = get_node("/root/ScriptServer")
	var previous_player: EsmReference = script_server.player_reference
	script_server.player_reference = esm_server.get_player_reference()

	_check_signatures(script_server)
	var session := ConsoleSession.new(script_server)
	session.output.connect(func(entry: Dictionary) -> void: _output.append(entry))
	_check_completion(session)
	_check_session(session, script_server)
	_check_status(session, script_server)
	_check_buttons(session, script_server)
	await _check_menu_reopen(script_server)
	await _check_hold_to_run(script_server)
	await _check_overlay(script_server)

	script_server.player_reference = previous_player
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)

## Every SIGNATURES name is a registered function, so the table cannot drift
## to names the registry no longer has.
func _check_signatures(script_server: Node) -> void:
	var registry: ScriptFunctionRegistry = script_server.function_registry
	var unknown := PackedStringArray()
	for names: String in ConsoleCompleter.SIGNATURES:
		for name in names.split("|"):
			if not registry.is_registered(name):
				unknown.append(name)
	check(unknown.is_empty(), "every ConsoleCompleter.SIGNATURES name is a registered function (not: %s)" % ", ".join(unknown))
	var missing := PackedStringArray()
	var completer := ConsoleCompleter.new(registry)
	for name in registry.get_registered_function_names():
		if completer.signature(name) == null:
			missing.append(name)
	print("  info  registered functions without a recorded signature: %s" % (", ".join(missing) if not missing.is_empty() else "none"))
	for name in ConsoleCompleter.meta_command_names():
		check(not registry.is_registered(name), "console command '%s' does not hide a script function" % name)

func _check_completion(session: ConsoleSession) -> void:
	var completer := session.completer
	var started := Time.get_ticks_msec()
	check(completer.ensure_index() and completer.index_size() > 50000,
			"the EditorID index covers FalloutNV.esm (%d EditorIDs, %d ms)" % [completer.index_size(), Time.get_ticks_msec() - started])
	var stimpak := completer.resolve("stimpak")
	check(stimpak.get("record_type") == "ALCH" and stimpak.get("editor_id") == "Stimpak", "Stimpak resolves, case-insensitively, to an ALCH (%s)" % stimpak)
	check(completer.record_for_form_id(int(stimpak["form_id"])).get("editor_id") == "Stimpak", "and back from its FormID")

	var ctx := {"target": null, "script_server": session.script_server}
	var heads := _texts(completer.complete("Center", 6, ctx))
	check(heads.has("CenterOnCell"), "Center completes to CenterOnCell: %s" % heads)
	heads = _texts(completer.complete("he", 2, ctx))
	check(heads.has("help"), "he completes to the help command: %s" % heads)
	var prefixed := _texts(completer.complete("player.AddI", 11, ctx))
	check(prefixed.has("player.AddItem"), "player.AddI completes to player.AddItem: %s" % prefixed)

	var items := completer.complete("player.additem Stimp", 20, ctx)
	check(_texts(items).has("Stimpak") and _all_types(items, ConsoleCompleter.KIND_RECORD_TYPES["item"]),
			"AddItem's first argument completes items only: %s" % _texts(items))
	check(String(items["signature"]).contains("[u][color=#e5c07b]Item"), "with Item underlined in the signature")
	var count_arg := completer.complete("player.additem Stimpak ", 23, ctx)
	check((count_arg["items"] as Array).is_empty() and String(count_arg["signature"]).contains("[u][color=#e5c07b]Count"),
			"the Count argument suggests nothing and underlines Count")
	var trailing := String(completer.complete("GetItemCount Stimpak ", 21, ctx)["signature"])
	var extra := String(completer.complete("GetItemCount Stimpak 5", 22, ctx)["signature"])
	check(not trailing.contains("too many") and extra.contains("too many"),
			"a space after the last argument is not too many arguments; a word there is")
	var by_id := completer.complete("player.additem 0x0001516", 24, ctx)
	check(_texts(by_id).has("Stimpak") and _all_types(by_id, ConsoleCompleter.KIND_RECORD_TYPES["item"]),
			"0x0001516 completes items by FormID, inserting EditorIDs: %s" % _texts(by_id))
	var mid := completer.complete("player.additem 0x00015169", 21, ctx)
	check(_texts(mid) == PackedStringArray(["Stimpak"]) and mid["start"] == 15 and mid["end"] == 25,
			"with the caret inside 0x00015169 the whole word is matched and replaced: %s" % _texts(mid))
	var before_word := completer.complete("player.additem Stimpak", 15, ctx)
	check(_texts(before_word).has("Stimpak") and before_word["end"] == 22, "a caret at the start of a word matches that word")
	var ordered := true
	var last := -1
	for item: Dictionary in completer.complete("player.additem 0x0001", 21, ctx, 200)["items"]:
		var id := ("0x" + String(item["detail"]).get_slice(" ", 1)).hex_to_int()
		ordered = ordered and id >= last
		last = id
	check(ordered and last > 0, "FormID matches come in FormID order")
	check(not (completer.complete("player.additem 0x", 17, ctx)["items"] as Array).is_empty()
			and (completer.complete("player.additem 0xZZ", 19, ctx)["items"] as Array).is_empty(),
			"a bare 0x lists items; non-hex digits match nothing")
	var doc_cells := completer.complete("coc 0x", 6, ctx)
	check(not (doc_cells["items"] as Array).is_empty() and _all_types(doc_cells, ["CELL"]), "coc 0x lists only CELLs")
	var cells := completer.complete("coc GSDoc", 9, ctx)
	check(_texts(cells).has("GSDocMitchellHouse") and _all_types(cells, ["CELL"]), "coc GSDoc completes the interior CELL GSDocMitchellHouse: %s" % _texts(cells))
	var exterior := _first_exterior_cell()
	if not exterior.is_empty():
		check(not _texts(completer.complete("coc " + exterior, 4 + exterior.length(), ctx)).has(exterior),
				"coc leaves out the exterior CELL %s, which CenterOnCell rejects" % exterior)
	var quests := completer.complete("SetStage VMQ0", 13, ctx)
	check(_texts(quests).has("VMQ01") and _all_types(quests, ["QUST"]), "SetStage completes quests: %s" % _texts(quests))
	check(_texts(completer.complete("GetAV Heal", 10, ctx)).has("Health"), "GetAV completes actor values")
	check(_texts(completer.complete("SexChange F", 11, ctx)).has("Female"), "SexChange completes Male/Female")
	var refs := completer.complete("prid Doc", 8, ctx)
	check(not (refs["items"] as Array).is_empty() and _all_types(refs, ["REFR", "ACHR", "ACRE"]), "prid completes placed references: %s" % _texts(refs))
	var second := completer.complete("help | player.additem Stimp", 27, ctx)
	check(_texts(second).has("Stimpak"), "completion follows the statement after |")
	check((completer.complete("ShowMessage \"Stim", 17, ctx)["items"] as Array).is_empty(), "nothing completes inside quotes")
	var variables := completer.complete("set VMQ01.", 10, ctx)
	check(not (variables["items"] as Array).is_empty() and String(variables["items"][0]["text"]).begins_with("VMQ01."),
			"set Quest. completes the quest's script variables: %s" % _texts(variables))

	started = Time.get_ticks_usec()
	completer.complete("info zzq", 8, ctx)
	check(true, "a substring search over every EditorID takes %d ms" % ((Time.get_ticks_usec() - started) / 1000))

func _check_status(session: ConsoleSession, script_server: Node) -> void:
	_run(session, "status")
	var text := "\n".join(_output.map(func(entry: Dictionary) -> String: return entry["text"]))
	check(text.contains("Plugins: FalloutNV.esm") and text.contains("NPC_ ") and text.contains("script functions registered, all complete their arguments")
			and text.contains("Space: "), "the status lists plugins, record counts, functions and the space:\n%s" % text)
	var player: EsmReference = script_server.player_reference
	var old_space := player.current_space_form_id
	var old_position := player.position
	check(session.describe_space().contains("not placed"), "an unplaced player has no space")
	player.current_space_form_id = int(session.completer.resolve("GSDocMitchellHouse")["form_id"])
	check(session.describe_space() == "GSDocMitchellHouse (interior)", "an interior shows its CELL: %s" % session.describe_space())
	player.current_space_form_id = int(session.completer.resolve("WastelandNV")["form_id"])
	player.position = Vector3(EsmServer.EXTERIOR_CELL_SIZE_METERS * 2.5, -EsmServer.EXTERIOR_CELL_SIZE_METERS * 0.5, 0)
	check(session.describe_space() == "WastelandNV, grid (2, -1)", "a worldspace shows its grid coordinate: %s" % session.describe_space())
	player.position = old_position
	player.current_space_form_id = old_space

func _check_session(session: ConsoleSession, script_server: Node) -> void:
	_run(session, "help AddItem")
	check(_has("info", "AddItem Item Count [HideMessage]"), "help AddItem shows its arguments")
	_run(session, "find Stimpak ALCH")
	check(_has("info", "Stimpak") and _has("info", "ALCH"), "find Stimpak ALCH lists the ALCH")
	_run(session, "Foo 1")
	check(_has("error", "'Foo' is not a script function"), "an unknown function is an error, not a silent 0")
	_run(session, "GetItemCount Stimpk")
	check(_has("warning", "did you mean Stimpak"), "a misspelt item argument warns with the closest EditorID")
	_run(session, "GetItemCount GSDocMitchellHouse")
	check(_has("warning", "is a CELL"), "an argument naming the wrong record type warns")
	var form_id := int(session.completer.resolve("Stimpak")["form_id"])
	_run(session, "GetItemCount 0x%08X" % form_id)
	check(_has("info", "= Stimpak") and _has("result", "GetItemCount >> "), "a 0x FormID argument becomes its EditorID")

	var bare := "%08X" % form_id
	_run(session, "GetItemCount " + bare)
	check(_has("info", "%s = Stimpak" % bare) and not _has("warning", ""), "a bare 8-digit FormID argument (%s) becomes its EditorID" % bare)
	_run(session, "AddItem %s 1" % bare)
	check(_has("result", "AddItem >> ") and not _has("error", ""), "player.additem-style: AddItem %s 1 keeps the count" % bare)
	_run(session, "GetSecondsPassed 00000001")
	check(_count("warning") == 0, "short numbers are not FormIDs")
	check(ConsoleCompleter.parse_form_id("00004322") == 0x4322 and ConsoleCompleter.parse_form_id("0x4322") == 0x4322
			and ConsoleCompleter.parse_form_id("4322") == -1 and ConsoleCompleter.parse_form_id("-0000001") == -1 and ConsoleCompleter.parse_form_id("Stimpak") == -1,
			"parse_form_id takes 0x… or 8 digits, not shorter numbers or names")
	var doc := String(session.completer.resolve("DocMitchellREF").get("editor_id", ""))
	if doc != "":
		var doc_id := int(session.completer.resolve(doc)["form_id"])
		_run(session, "prid %08X" % doc_id)
		check(session.target != null and session.target == session.find_reference(doc), "prid takes a bare FormID")
		session.set_target(null)
	_run(session, "prid player")
	check(session.target == script_server.player_reference and script_server.player_reference != null, "prid player targets the player")
	var before := (session.target as ActorReference).get_actor_values().get_current(ActorValue.from_name("Health")) if session.target is ActorReference else -1.0
	_run(session, "GetAV Health")
	check(_has("result", "GetActorValue >> ") or _has("result", "GetAV >> "), "an unprefixed statement runs on the target (Health %s)" % before)
	_run(session, "info")
	check(_has("info", "[player]") or _has("info", "player"), "info with no name describes the target")
	_run(session, "prid none")
	check(session.target == null, "prid none clears the target")
	_run(session, "info GSDocMitchellHouse")
	check(_has("info", "CELL"), "info describes a record by EditorID")

	_run(session, "GetSecondsPassed | GetRandomPercent")
	check(_count("result") == 2, "| runs two statements")
	var history_size := session.history.size()
	_run(session, "history 3")
	check(_count("info") == 3 and session.history.size() == history_size + 1, "history lists recent commands")

	var batch := "user://console_test_batch.txt"
	var file := FileAccess.open(batch, FileAccess.WRITE)
	file.store_string("; a comment\nGetRandomPercent\nbat console_test_batch\n")
	file.close()
	_run(session, "bat console_test_batch")
	check(_count("result") == ConsoleSession.MAX_BATCH_DEPTH and _has("error", "nested"), "bat runs a file's lines and stops a file that runs itself")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(batch))

func _check_buttons(session: ConsoleSession, script_server: Node) -> void:
	var registry: ScriptFunctionRegistry = script_server.function_registry
	for spec: Dictionary in ConsoleSession.BUTTONS:
		var commands: Array = spec["command"] if spec["command"] is Array else [spec["command"]]
		for command: String in commands:
			var name := command.get_slice(" ", 0)
			check(registry.is_registered(name.substr(name.rfind(".") + 1)), "button command '%s' is a registered function" % command)
	var player: EsmReference = script_server.player_reference
	# TGM / TDM flip their flags; Kill / Resurrect change Health.
	var god: bool = script_server.god_mode
	var demigod: bool = script_server.demigod_mode
	_run(session, "TDM")
	check(script_server.demigod_mode == not demigod, "TDM toggles demigod mode")
	_run(session, "TDM")
	_run(session, "TGM")
	check(script_server.god_mode == not god, "TGM toggles god mode")
	_run(session, "TGM")
	check(script_server.god_mode == god, "and back")
	var health := ActorValue.from_name("Health")
	var values := player.get_actor_values()
	var full := values.get_current(health)
	session.set_target(player)
	_run(session, "Kill")
	check(values.get_current(health) == 0.0 and full > 0.0, "Kill takes the target's Health to 0 (was %s)" % full)
	_run(session, "Resurrect")
	check(values.get_current(health) == full, "Resurrect restores it")
	session.set_target(null)
	_run(session, "Kill")
	check(_has("result", "Kill >> 0"), "Kill with no target does nothing")

	script_server.disable_player_controls(ScriptServer.CONTROL_MOVEMENT | ScriptServer.CONTROL_LOOKING)
	session.submit("EnablePlayerControls", false)
	check(script_server.disabled_player_controls == 0, "EnablePlayerControls with no arguments enables every control")

	var toggle: Dictionary = ConsoleSession.BUTTONS[0]
	check(not session.button_status(toggle)["enabled"], "the Enable/Disable button needs a target")
	var door := EsmServer.find_reference_by_editor_id("DocMitchellREF")
	session.set_target(door)
	check(session.button_status(toggle)["enabled"] and session.button_label(toggle) == "Disable" and session.button_command(toggle) == "Disable",
			"with a target it offers Disable")
	session.submit(session.button_command(toggle))
	check(door.is_disabled() and session.button_label(toggle) == "Enable" and session.button_command(toggle) == "Enable", "which flips to Enable once disabled")
	session.submit(session.button_command(toggle))
	check(not door.is_disabled(), "and back")
	_run(session, "GetSelf")
	check(_has("result", "DocMitchell"), "a command runs on the target by default")
	_output.clear()
	session.submit("GetSelf", false)
	check(_has("result", "(nothing)"), "and ignoring the target runs it as the player (no calling reference)")
	session.set_target(null)

## Opening a script menu while it is showing must not enter menu mode twice:
## closing leaves it once, which kept the game in menu mode.
func _check_menu_reopen(script_server: Node) -> void:
	var player: PlayerController = load("res://player/player.tscn").instantiate()
	add_child(player)
	await get_tree().process_frame
	var previous_opener: Callable = script_server.menu_opener
	player.possess(script_server.player_reference as ActorReference)
	var was_menu: bool = script_server.is_menu_mode()
	for i in 3:
		script_server.open_menu(ScriptServer.MENU_RACE)
	check(player.race_menu.visible and script_server.is_menu_open(ScriptServer.MENU_RACE), "the race menu opens")
	player.race_menu.accept()
	check(not script_server.is_menu_open(ScriptServer.MENU_RACE) and script_server.is_menu_mode() == was_menu,
			"opening it three times then closing once leaves menu mode")
	script_server.menu_opener = previous_opener
	player.queue_free()
	await get_tree().process_frame

static func _key(pressed: bool, echo := false) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = KEY_QUOTELEFT
	event.keycode = KEY_QUOTELEFT
	event.pressed = pressed
	event.echo = echo
	return event

## Hold ` , type, let go: it runs and closes. A tap just opens. A command
## that prints an error or warning leaves the console open.
func _check_hold_to_run(script_server: Node) -> void:
	var overlay: ConsoleOverlay = load("res://console/console_overlay.tscn").instantiate()
	add_child(overlay)
	await get_tree().process_frame
	overlay._input(_key(true))
	check(overlay.is_open() and overlay._key_held_open, "pressing ` opens the console")
	overlay._line.text = "GetRandomPercent"
	overlay._input(_key(true, true))
	overlay._input(_key(false))
	check(not overlay.is_open() and overlay.session.history.back() == "GetRandomPercent" and not script_server.is_menu_mode(),
			"letting go of ` with a command typed runs it and closes the console")
	overlay._input(_key(true))
	overlay._input(_key(false))
	check(overlay.is_open() and not overlay._key_held_open, "a tap of ` just opens it")
	overlay._input(_key(true))
	check(not overlay.is_open(), "and the next press closes it")
	overlay._input(_key(true))
	overlay._line.text = "NoSuchFunction 1"
	overlay._input(_key(false))
	check(overlay.is_open() and overlay._output.get_parsed_text().contains("not a script function"),
			"a command that fails leaves the console open to read the error")
	overlay.set_open(false)
	overlay._line.text = "GetRandomPercent"
	overlay.set_open(true)
	overlay._input(_key(false))
	check(overlay.is_open(), "letting go of ` does nothing when it did not open the console")
	overlay.set_open(false)
	overlay.queue_free()

func _check_overlay(script_server: Node) -> void:
	var overlay: ConsoleOverlay = load("res://console/console_overlay.tscn").instantiate()
	add_child(overlay)
	await get_tree().process_frame
	var was_menu: bool = script_server.is_menu_mode()
	overlay.set_open(true)
	check(script_server.is_menu_mode() and overlay._panel.visible, "opening the console enters menu mode")
	var target_row := overlay.get_node("Panel/Margin/VBox/TargetRow")
	check(target_row.get_index() == overlay.get_node("Panel/Margin/VBox/InputRow").get_index() - 1, "the target row sits just above the input")
	check(not overlay._clear_target.visible, "Clear is hidden with no target")
	overlay.session.set_target(script_server.player_reference)
	check(overlay._clear_target.visible and overlay._target_label.get_parsed_text().contains("player"), "a target shows above the input, with Clear")
	overlay._clear_target.pressed.emit()
	check(overlay.session.target == null and not overlay._clear_target.visible and overlay._line.has_focus(),
			"Clear clears the target and keeps the input focused")
	await _check_target_box(overlay, script_server)
	var line: LineEdit = overlay._line
	line.text = "player.additem Stimp"
	line.caret_column = line.text.length()
	overlay._refresh_completion(false)
	check(overlay._suggestions.visible and overlay._signature.visible, "typing shows suggestions and the signature")
	for pressed in [true, false]:
		var tab := InputEventKey.new()
		tab.keycode = KEY_TAB
		tab.pressed = pressed
		get_viewport().push_input(tab)
	check(not line.get_menu().visible, "Tab (ui_menu) does not open the input's context menu on release")
	overlay._tab_complete()
	check(line.text.begins_with("player.additem Stimpak") or line.text.begins_with("player.additem Stimp"),
			"Tab applies the first suggestion: %s" % line.text)
	line.text = "player.additem Stimp"
	line.caret_column = line.text.length()
	overlay._refresh_completion(false)
	await get_tree().process_frame
	var list: RichTextLabel = overlay._suggestion_list
	var second := String(overlay._completion["items"][1]["text"])
	var motion := InputEventMouseMotion.new()
	motion.position = Vector2(4, list.get_line_offset(1) + list.get_line_height(1) * 0.5)
	overlay._on_suggestion_gui_input(motion)
	check(overlay._selected == 1, "hovering a suggestion highlights it")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = motion.position
	overlay._on_suggestion_gui_input(click)
	check(line.text == "player.additem %s " % second and line.has_focus(), "clicking a suggestion applies it and keeps the input focused: %s" % line.text)

	line.text = "player.additem Ammo"
	line.caret_column = line.text.length()
	overlay._refresh_completion(false)
	await get_tree().process_frame
	var all_items: Array = overlay._completion["items"]
	check(all_items.size() > ConsoleOverlay.VISIBLE_SUGGESTIONS and list.get_line_count() == ConsoleOverlay.VISIBLE_SUGGESTIONS + 1,
			"%d suggestions match, %d show at a time" % [all_items.size(), ConsoleOverlay.VISIBLE_SUGGESTIONS])
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel.pressed = true
	for i in ConsoleOverlay.VISIBLE_SUGGESTIONS + 1:
		overlay._on_suggestion_gui_input(wheel)
	check(overlay._selected == ConsoleOverlay.VISIBLE_SUGGESTIONS and overlay._scroll == 1,
			"the wheel moves the highlight down as Down does, scrolling past the bottom (%d, %d)" % [overlay._selected, overlay._scroll])
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	overlay._on_suggestion_gui_input(wheel)
	overlay._on_suggestion_gui_input(wheel)
	check(overlay._selected == ConsoleOverlay.VISIBLE_SUGGESTIONS - 2 and overlay._scroll == 1,
			"and up as Up does, the list staying put while the highlight is in view")
	for i in ConsoleOverlay.VISIBLE_SUGGESTIONS - 1:
		overlay._move_selection(-1)
	check(overlay._selected == all_items.size() - 1 and overlay._scroll == all_items.size() - ConsoleOverlay.VISIBLE_SUGGESTIONS,
			"Up past the first suggestion wraps to the last, scrolling to the end")
	for i in 2:
		overlay._move_selection(1)
	check(overlay._selected == 1 and overlay._scroll == 0, "and Down past the last wraps to the first")
	overlay._move_selection(1)
	for i in ConsoleOverlay.VISIBLE_SUGGESTIONS:
		overlay._on_suggestion_gui_input(_wheel(MOUSE_BUTTON_WHEEL_DOWN))
	check(overlay._scroll == 3, "so the list scrolls (%d)" % overlay._scroll)
	var selected_before: int = overlay._selected
	var pan := InputEventPanGesture.new()
	pan.delta = Vector2(0, ConsoleOverlay.PAN_PER_ROW * 0.5)
	overlay._on_suggestion_gui_input(pan)
	check(overlay._selected == selected_before, "half a row of trackpad scroll does not move the highlight yet")
	overlay._on_suggestion_gui_input(pan)
	pan.delta = Vector2(0, ConsoleOverlay.PAN_PER_ROW * 2.0)
	overlay._on_suggestion_gui_input(pan)
	check(overlay._selected == selected_before + 3, "a trackpad scroll down moves the highlight a row per PAN_PER_ROW")
	pan.delta = Vector2(0, -ConsoleOverlay.PAN_PER_ROW * 3.0)
	overlay._on_suggestion_gui_input(pan)
	check(overlay._selected == selected_before, "and up moves it back")
	var scrolled_to: int = overlay._scroll
	click.position = Vector2(4, list.get_line_offset(0) + list.get_line_height(0) * 0.5)
	overlay._on_suggestion_gui_input(click)
	check(line.text == "player.additem %s " % String(all_items[scrolled_to]["text"]), "a click on a scrolled list applies the suggestion shown there: %s" % line.text)

	var saved_zoom := overlay.get_zoom()
	var base_size: int = overlay._font_sizes.filter(func(e: Array) -> bool: return e[0] == overlay._output and e[1] == &"normal_font_size")[0][2]
	overlay._set_zoom(1.0)
	var plus := InputEventKey.new()
	plus.keycode = KEY_EQUAL
	plus.ctrl_pressed = true
	plus.pressed = true
	overlay._zoom_input(plus)
	overlay._zoom_input(plus)
	check(is_equal_approx(overlay.get_zoom(), 1.2) and overlay._output.get_theme_font_size(&"normal_font_size") == roundi(base_size * 1.2),
			"Ctrl+= zooms the text (%.1f, %d px)" % [overlay.get_zoom(), overlay._output.get_theme_font_size(&"normal_font_size")])
	check(is_equal_approx(overlay._load_zoom(), 1.2), "and the zoom is saved")
	var minus := plus.duplicate() as InputEventKey
	minus.keycode = KEY_MINUS
	overlay._zoom_input(minus)
	check(is_equal_approx(overlay.get_zoom(), 1.1), "Ctrl+- zooms out")
	var reset := plus.duplicate() as InputEventKey
	reset.keycode = KEY_0
	overlay._zoom_input(reset)
	check(is_equal_approx(overlay.get_zoom(), 1.0) and overlay._line.get_theme_font_size(&"font_size") == 15, "Ctrl+0 resets it")
	overlay._set_zoom(saved_zoom)

	line.text = "GetRandomPercent"
	overlay._on_submitted(line.text)
	check(line.text.is_empty() and overlay.session.history.back() == "GetRandomPercent", "Enter runs the line and records it")
	overlay._browse_history(-1)
	check(line.text == "GetRandomPercent", "Up recalls it")
	overlay._browse_history(1)
	check(line.text.is_empty(), "Down returns to the draft")
	check(overlay._output.get_parsed_text().contains("GetRandomPercent >> "), "the result shows in the output")
	overlay._process(0.0)
	check(overlay._button_nodes.size() == ConsoleSession.BUTTONS.size() and overlay._button_nodes[0].disabled, "the overlay has a button per entry, the target ones disabled")
	var caps_index := ConsoleSession.BUTTONS.find_custom(func(b: Dictionary) -> bool: return b.get("type_only", false))
	overlay._on_button_pressed(caps_index)
	check(line.text == "player.AddItem Caps001 1000" and line.get_selected_text() == "1000" and line.has_focus(),
			"+ Caps types the command with the amount selected, without running it: '%s' / '%s'" % [line.text, line.get_selected_text()])
	line.clear()
	overlay.set_open(false)
	check(script_server.is_menu_mode() == was_menu, "closing the console leaves menu mode")
	overlay.queue_free()

func _run(session: ConsoleSession, line: String) -> void:
	_output.clear()
	session.submit(line)

func _has(kind: String, text: String) -> bool:
	for entry: Dictionary in _output:
		if entry["kind"] == kind and String(entry["text"]).contains(text):
			return true
	return false

func _count(kind: String) -> int:
	return _output.filter(func(entry: Dictionary) -> bool: return entry["kind"] == kind).size()

static func _texts(completion: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for item: Dictionary in completion.get("items", []):
		out.append(String(item["text"]))
	return out

## Whether every suggestion is a record of one of `types`.
static func _all_types(completion: Dictionary, types: Array) -> bool:
	for item: Dictionary in completion.get("items", []):
		if not types.has(String(item["detail"]).get_slice(" ", 0)):
			return false
	return true

## An exterior CELL with an EditorID, or "".
func _first_exterior_cell() -> String:
	var esm_server: Node = get_node("/root/EsmServer")
	for row: Dictionary in esm_server.get_record_index():
		if row["record_type"] == "CELL" and String(row["editor_id"]) != "" \
				and esm_server.get_space_form_id_for_cell(int(row["form_id"])) != int(row["form_id"]):
			return String(row["editor_id"])
	return ""

static func _wheel(button_index: MouseButton) -> InputEventMouseButton:
	var wheel := InputEventMouseButton.new()
	wheel.button_index = button_index
	wheel.pressed = true
	return wheel

## The target box outlines the target's meshes in its node's space, follows
## the node, and shows only while the console is open and the target has a
## node.
func _check_target_box(overlay: ConsoleOverlay, script_server: Node) -> void:
	var reference: EsmReference = script_server.player_reference
	var node := EsmNode.new()
	add_child(node)
	node.position = Vector3(10, 0, 0)
	node.rotation = Vector3(0, PI / 2, 0)
	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(2, 4, 6)
	mesh_instance.mesh = box
	mesh_instance.position = Vector3(0, 2, 0)
	node.add_child(mesh_instance)
	var aabb := ConsoleOverlay.local_mesh_aabb(node)
	check(aabb.position.is_equal_approx(Vector3(-1, 0, -3)) and aabb.size.is_equal_approx(Vector3(2, 4, 6)),
			"the target box bounds the meshes in the node's own space (%s)" % aabb)
	overlay.session.set_target(reference)
	EsmNode._nodes_by_reference[reference] = node
	overlay._process(0.0)
	var box_mesh := overlay._target_box.mesh as ImmediateMesh
	var lines: int = (box_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() if box_mesh.get_surface_count() > 0 else 0
	check(overlay._target_box.visible and lines == 24 and overlay._target_box.global_transform.is_equal_approx(node.global_transform),
			"and draws its 12 edges at the node (%d vertices)" % lines)
	node.position = Vector3(0, 5, 0)
	overlay._process(0.0)
	check(overlay._target_box.global_position.is_equal_approx(Vector3(0, 5, 0)), "following it when it moves")
	overlay.set_open(false)
	overlay._process(0.0)
	check(not overlay._target_box.visible, "and hides while the console is closed")
	overlay.set_open(true)
	EsmNode._nodes_by_reference.erase(reference)
	overlay._process(0.0)
	check(not overlay._target_box.visible, "or when the target has no node")
	overlay.session.set_target(null)
	node.queue_free()
