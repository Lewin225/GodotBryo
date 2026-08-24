extends Node

const DATA_DIR := "/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/"
const SESSION_SCENE := preload("res://terminal_session.tscn")

var failures := 0

func check(ok: bool, message: String) -> void:
	print("  OK   " if ok else "  FAIL ", message)
	if not ok:
		failures += 1

func _ready() -> void:
	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened FalloutNV.esm")
	var player := Node.new()
	add_child(player)
	var session := SESSION_SCENE.instantiate() as TerminalSession
	add_child(session)
	await get_tree().process_frame

	var note_terminal := TerminalNode.new()
	note_terminal.configure_terminal(esm.get_terminal_data(0x166B56)) # VHDStealthSuitTerminal
	session.open_session(note_terminal, esm, player)
	check(session.visible, "opening a terminal shows the session overlay")
	check(not player.is_physics_processing(), "opening a terminal suspends player physics input")
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
	check(player.is_physics_processing(), "exiting restores player physics input")

	var submenu_terminal := TerminalNode.new()
	submenu_terminal.configure_terminal(esm.get_terminal_data(0x17B7A0)) # P04CompanionFireTerminal
	session.open_session(submenu_terminal, esm, player)
	check(session._view == TerminalSession.View.WELCOME, "non-empty DESC opens a welcome page first")
	session._select_current()
	session._select_current()
	check(session._view == TerminalSession.View.RESULT, "submenu fixture choice shows its result page")
	session._select_current()
	check(session._view == TerminalSession.View.WELCOME and session._terminal_stack.size() == 2, "TNAM opens the authored submenu by FormID")
	session.close_session()

	session.queue_free()
	player.queue_free()
	_finish()

func _finish() -> void:
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
