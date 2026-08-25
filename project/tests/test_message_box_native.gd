extends Node

var failures := 0

func check(ok: bool, message: String) -> void:
	print("  OK   " if ok else "  FAIL ", message)
	if not ok:
		failures += 1


func _ready() -> void:
	var esm := EsmReader.new()
	var data_dir := GameDataSettings.get_data_dir()
	check(esm.open(data_dir + "FalloutNV.esm"), "opened FalloutNV.esm")

	# 1. Test GSBrokenSMGMsg (Modal message box with 2 ITXT buttons)
	var smg_msg: Dictionary = esm.get_message_by_editor_id("GSBrokenSMGMsg")
	check(not smg_msg.is_empty(), "found GSBrokenSMGMsg record")
	check(smg_msg.get("editor_id", "") == "GSBrokenSMGMsg", "editor_id matches GSBrokenSMGMsg")
	check(bool(smg_msg.get("is_message_box", false)) == true, "GSBrokenSMGMsg is_message_box is true")
	var smg_buttons: Array = smg_msg.get("buttons", [])
	check(smg_buttons.size() == 2, "GSBrokenSMGMsg has 2 ITXT buttons (got %d)" % smg_buttons.size())
	if smg_buttons.size() >= 2:
		check(String(smg_buttons[0]) != "", "first button text: '%s'" % smg_buttons[0])
		check(String(smg_buttons[1]) != "", "second button text: '%s'" % smg_buttons[1])

	# 2. Test EDERepair04 (Modal message box with 4 ITXT buttons)
	var ede_msg: Dictionary = esm.get_message_by_editor_id("EDERepair04")
	check(not ede_msg.is_empty(), "found EDERepair04 record")
	check(bool(ede_msg.get("is_message_box", false)) == true, "EDERepair04 is_message_box is true")
	var ede_buttons: Array = ede_msg.get("buttons", [])
	check(ede_buttons.size() == 4, "EDERepair04 has 4 ITXT buttons (got %d)" % ede_buttons.size())

	# 3. Test WildWastelandMessage (Toast notification, flags=0, 0 buttons)
	var ww_msg: Dictionary = esm.get_message_by_editor_id("WildWastelandMessage")
	check(not ww_msg.is_empty(), "found WildWastelandMessage record")
	check(bool(ww_msg.get("is_message_box", true)) == false, "WildWastelandMessage is_message_box is false")
	check(ww_msg.get("text", "") == "...", "WildWastelandMessage text is '...'")
	check(float(ww_msg.get("display_time", 0.0)) > 0.0, "WildWastelandMessage has positive display_time")

	# 4. Test lookup by FormID
	var form_id: int = int(smg_msg.get("form_id", 0))
	var smg_by_id: Dictionary = esm.get_message_by_form_id(form_id)
	check(not smg_by_id.is_empty(), "found message by FormID 0x%X" % form_id)
	check(smg_by_id.get("editor_id", "") == "GSBrokenSMGMsg", "form_id lookup resolved same editor_id")

	_finish()


func _finish() -> void:
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
