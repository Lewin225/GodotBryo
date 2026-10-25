extends Node

var ESM_PATH: String = GameDataConfig.resolve()["data_dir"] + GameDataConfig.ESM_FILE
var failures := 0

func check(condition: bool, message: String) -> void:
	if condition:
		print("  OK   ", message)
	else:
		print("  FAIL ", message)
		failures += 1

func _ready() -> void:
	var esm := EsmReader.new()
	check(esm.open(ESM_PATH), "opened FalloutNV.esm")
	if esm.get_last_error() != "":
		_finish()
		return

	print("--- placed Note-browsing fixture ---")
	var stealth: Dictionary = esm.get_terminal_data(0x166B56) # VHDStealthSuitTerminal
	check(String(stealth.get("editor_id", "")) == "VHDStealthSuitTerminal", "fixture EditorID resolves (got %s)" % String(stealth.get("editor_id", "")))
	var stealth_items: Array = stealth.get("items", [])
	check(stealth_items.size() == 3, "fixture has three authored choices")
	if stealth_items.size() == 3:
		check(String(stealth_items[0]["text"]) == "Initial Inventory Report", "first item text matches")
		check(String(stealth_items[0]["result_text"]) == "Loading...", "first item result text matches")
		check(int(stealth_items[0]["note_form_id"]) == 0x166B67, "first item INAM Note FormID matches")
		check(int(stealth_items[0]["submenu_form_id"]) == 0, "first item has no submenu")
		var note: Dictionary = esm.get_note_data(int(stealth_items[0]["note_form_id"]))
		check(String(note.get("editor_id", "")) == "VHDInventoryNote01", "linked NOTE EditorID resolves by INAM FormID")
		check(String(note.get("text", "")).begins_with("We've begun to take stock"), "linked NOTE body resolves from TNAM")

	print("--- placed submenu fixture ---")
	var root: Dictionary = esm.get_terminal_data(0x17B7A0) # P04CompanionFireTerminal
	check(String(root.get("welcome_text", "")) == "Welcome, Courier.", "root welcome text matches DESC")
	var root_items: Array = root.get("items", [])
	check(root_items.size() == 1, "root has one authored choice")
	if root_items.size() == 1:
		check(int(root_items[0]["submenu_form_id"]) == 0x17B79F, "root TNAM points to submenu TERM")
		check(String(root_items[0]["result_text"]) == "Accessing confirmation menu...", "root result text matches")

	var submenu: Dictionary = esm.get_terminal_data(0x17B79F)
	var submenu_items: Array = submenu.get("items", [])
	check(submenu_items.size() == 2, "submenu has two authored choices")
	if submenu_items.size() == 2:
		check(String(submenu_items[0]["text"]) == "No.", "empty-result item label matches")
		check(String(submenu_items[0]["result_text"]) == "", "4-byte zero RNAM becomes empty result text")
		check(String(submenu_items[1]["text"]) == "Yes.", "second submenu label matches")
		check(String(submenu_items[1]["result_text"]) == "Notification sent...", "second submenu result text matches")
		check(String(submenu_items[1]["script_source"]).find("P04") != -1, "menu item SCTX is retained for future script dispatch")

	_finish()

func _finish() -> void:
	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
