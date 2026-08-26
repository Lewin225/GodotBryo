extends Node

const MESSAGE_BOX_SCENE := preload("res://message_box.tscn")

var failures := 0

func check(ok: bool, message: String) -> void:
	print("  OK   " if ok else "  FAIL ", message)
	if not ok:
		failures += 1


func _ready() -> void:
	var esm := EsmReader.new()
	var data_dir := GameDataSettings.get_data_dir()
	check(esm.open(data_dir + "FalloutNV.esm"), "opened FalloutNV.esm")

	var msg_box := MESSAGE_BOX_SCENE.instantiate() as MessageBox
	add_child(msg_box)

	var script_engine := ScriptEngine.new()
	script_engine.esm = esm
	script_engine.message_box = msg_box
	add_child(script_engine)

	# 1. Initial button pressed state should be -1
	var ctx := ScriptExecutionContext.new(null)
	var initial_btn: Variant = script_engine.function_registry.call_function("GetButtonPressed", [], ctx)
	check(initial_btn == -1, "GetButtonPressed initially returns -1 (got %s)" % str(initial_btn))

	# 2. Call ShowMessage GSBrokenSMGMsg
	var show_res: Variant = script_engine.function_registry.call_function("ShowMessage", ["GSBrokenSMGMsg"], ctx)
	check(show_res == 1, "ShowMessage returned 1 (success)")
	check(msg_box._is_dialog_active == true, "MessageBox dialog is active")
	check(msg_box._button_nodes.size() == 2, "MessageBox instantiated 2 buttons")

	# 3. Check GetButtonPressed while dialog is open -> still -1
	var pending_btn: Variant = script_engine.function_registry.call_function("GetButtonPressed", [], ctx)
	check(pending_btn == -1, "GetButtonPressed returns -1 while dialog is pending")

	# 4. Simulate real mouse click on Button 1 (Repair) via button's pressed signal
	check(msg_box._button_nodes[1] != null, "Button 1 node exists")
	msg_box._button_nodes[1].emit_signal("pressed")
	check(msg_box._is_dialog_active == false, "MessageBox dialog closed after button click")

	# 5. Check GetButtonPressed -> returns 1
	var clicked_btn: Variant = script_engine.function_registry.call_function("GetButtonPressed", [], ctx)
	check(clicked_btn == 1, "GetButtonPressed returns 1 after button 1 was pressed (got %s)" % str(clicked_btn))

	# 6. Check GetButtonPressed again -> returns -1 (consumed)
	var consumed_btn: Variant = script_engine.function_registry.call_function("GetButtonPressed", [], ctx)
	check(consumed_btn == -1, "GetButtonPressed auto-resets to -1 after consumption (got %s)" % str(consumed_btn))

	# 7. Test Toast Notification (WildWastelandMessage)
	var toast_res: Variant = script_engine.function_registry.call_function("ShowMessage", ["WildWastelandMessage"], ctx)
	check(toast_res == 1, "ShowMessage on notification returned 1")
	check(msg_box._is_dialog_active == false, "Modal dialog not opened for corner notification")
	check(msg_box._toast_root.visible == true, "Toast notification root is visible")
	check(msg_box._toast_label.text == "...", "Toast notification label displays message text")

	msg_box.free()
	script_engine.free()
	_finish()


func _finish() -> void:
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
