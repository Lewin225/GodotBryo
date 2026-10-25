extends Node

var DATA_DIR: String = GameDataConfig.resolve()["data_dir"] ## the launcher's data folder, or GODOTBRYO_DATA_DIR
const SESSION_SCENE := preload("res://terminal_session.tscn")

var failures := 0

func check(ok: bool, message: String) -> void:
	print("  OK   " if ok else "  FAIL ", message)
	if not ok:
		failures += 1

func _ready() -> void:
	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened FalloutNV.esm")
	var session := SESSION_SCENE.instantiate() as TerminalSession
	add_child(session)
	await get_tree().process_frame
	var closed_count := [0]
	session.closed.connect(func() -> void: closed_count[0] += 1)

	var note_terminal := _typed_terminal(0x166B56) # VHDStealthSuitTerminal
	check(session.open_session(note_terminal, esm), "a terminal reference opens a session")
	check(ScriptServer.get_menu() == ScriptServer.MENU_COMPUTERS, "an open session is menu 1057 (Computers)")
	check(session.visible, "opening a terminal shows the session overlay")
	check(session._choices.item_count == 3, "empty welcome text opens the real menu directly")
	session._select_current()
	check(session._view == TerminalSession.View.RESULT, "selecting an item shows its real result page")
	check(session._body.text == "Loading...", "result page retains authored RNAM text")
	session._select_current()
	check(session._view == TerminalSession.View.NOTE, "result continuation opens linked NOTE")
	check(session._body.text.begins_with("We've begun to take stock"), "NOTE page retains TNAM body text")
	session._go_back()
	check(session._view == TerminalSession.View.MENU, "Back from NOTE restores its terminal menu")
	session.close_session()
	check(not session.visible and closed_count[0] == 1, "closing hides the session and emits closed once")
	check(not ScriptServer.is_menu_mode(), "and leaves menu mode")
	session.close_session()
	check(closed_count[0] == 1, "closing an already-closed session emits nothing")

	var submenu_terminal := _typed_terminal(0x17B7A0) # P04CompanionFireTerminal
	session.open_session(submenu_terminal, esm)
	check(session._view == TerminalSession.View.WELCOME, "non-empty DESC opens a welcome page first")
	session._select_current()
	session._select_current()
	check(session._view == TerminalSession.View.RESULT, "submenu fixture choice shows its result page")
	session._select_current()
	check(session._view == TerminalSession.View.WELCOME and session._terminal_stack.size() == 2, "TNAM opens the authored submenu by FormID")
	session.close_session()

	check(not session.open_session(TerminalReference.new(), esm) and not session.visible, "a terminal with no base opens nothing")

	# V19OverseerWallTerminal (REFR 00143990): its items test the open state of
	# the reference it links to; the failing one is hidden.
	var esm_server = get_node("/root/EsmServer")
	if not esm_server.is_ready():
		await esm_server.esm_ready
	var wall: TerminalReference = esm_server.get_reference("authored:00143990")
	var linked: ActivatorReference = esm_server.get_reference("authored:%08X" % wall.linked_reference_form_id)
	var menu_texts := func() -> Array[String]:
		var texts: Array[String] = []
		for i in session._choices.item_count:
			texts.append(session._choices.get_item_text(i).strip_edges())
		return texts
	var disengage: String = wall.base.menu_items[0].text.strip_edges()
	var engage: String = wall.base.menu_items[1].text.strip_edges()
	linked.is_open = false
	session.open_session(wall, esm, esm_server.get_player_reference())
	if session._view == TerminalSession.View.WELCOME:
		session._select_current()
	var closed_menu: Array[String] = menu_texts.call()
	check(closed_menu.has(disengage) and not closed_menu.has(engage), "linked reference closed: '%s' shows, '%s' is hidden (%s)" % [disengage, engage, closed_menu])
	session.close_session()
	linked.is_open = true
	session.open_session(wall, esm, esm_server.get_player_reference())
	if session._view == TerminalSession.View.WELCOME:
		session._select_current()
	var open_menu: Array[String] = menu_texts.call()
	check(open_menu.has(engage) and not open_menu.has(disengage), "linked reference open: the reverse (%s)" % [open_menu])
	session.close_session()
	linked.is_open = false

	session.queue_free()
	_finish()

## A TerminalReference on a TERM base, with no node: the session reads the
## menu from the reference's base.
func _typed_terminal(base_form_id: int) -> TerminalReference:
	var base := TerminalBase.new()
	base.form_id = base_form_id
	var reference := TerminalReference.new()
	reference.base = base
	reference.base_form_id = base_form_id
	return reference

func _finish() -> void:
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
