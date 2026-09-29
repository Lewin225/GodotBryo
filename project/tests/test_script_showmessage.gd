extends Node

const MESSAGE_BOX_SCENE := preload("res://message_box.tscn")

var failures := 0

func check(ok: bool, message: String) -> void:
	print("  OK   " if ok else "  FAIL ", message)
	if not ok:
		failures += 1


func _ready() -> void:
	var esm_server = get_node("/root/EsmServer")
	if not esm_server.is_ready():
		await esm_server.esm_ready
	var player: ActorReference = esm_server.get_player_reference()
	var esm := EsmReader.new()
	var data_dir := GameDataSettings.get_data_dir()
	check(esm.open(data_dir + "FalloutNV.esm"), "opened FalloutNV.esm")

	var msg_box := MESSAGE_BOX_SCENE.instantiate() as MessageBox
	add_child(msg_box)

	var script_engine: Node = get_node("/root/ScriptServer")
	script_engine.function_registry.esm = esm
	script_engine.message_box = msg_box

	# GSBrokenSMGMsg's second button needs the player's Repair >= 25.
	var ctx := ScriptExecutionContext.new(null)
	script_engine.function_registry.call_function("SetActorValue", ["Repair", 50], ScriptExecutionContext.new(player))

	# 1. Initial button pressed state should be -1
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

	# Buttons whose conditions fail are hidden; the rest report their authored
	# index. NellisSolarArrayRepairMsg: button 1 needs Repair >= 40, button 2
	# an item (0015ECD6) the player carries.
	script_engine.function_registry.call_function("SetActorValue", ["Repair", 10], ScriptExecutionContext.new(player))
	script_engine.function_registry.call_function("ShowMessage", ["NellisSolarArrayRepairMsg"], ctx)
	check(msg_box._button_nodes.size() == 1, "with Repair 10 and no item only the first button shows (%d)" % msg_box._button_nodes.size())
	msg_box._button_nodes[0].emit_signal("pressed")
	script_engine.function_registry.call_function("GetButtonPressed", [], ctx)
	esm_server.add_inventory_items(player, esm_server.get_base(0x0015ECD6), 1)
	script_engine.function_registry.call_function("ShowMessage", ["NellisSolarArrayRepairMsg"], ctx)
	check(msg_box._button_nodes.size() == 2, "carrying the item shows its button too (%d)" % msg_box._button_nodes.size())
	msg_box._button_nodes[1].emit_signal("pressed")
	var hidden_btn: Variant = script_engine.function_registry.call_function("GetButtonPressed", [], ctx)
	check(hidden_btn == 2, "which reports its authored index 2 past the hidden one (got %s)" % str(hidden_btn))
	script_engine.function_registry.call_function("SetActorValue", ["Repair", 50], ScriptExecutionContext.new(player))
	script_engine.function_registry.call_function("ShowMessage", ["NellisSolarArrayRepairMsg"], ctx)
	check(msg_box._button_nodes.size() == 3, "Repair 50 shows all three")
	msg_box._button_nodes[0].emit_signal("pressed")
	script_engine.function_registry.call_function("GetButtonPressed", [], ctx)

	# 7. Test Toast Notification (WildWastelandMessage)
	var toast_res: Variant = script_engine.function_registry.call_function("ShowMessage", ["WildWastelandMessage"], ctx)
	check(toast_res == 1, "ShowMessage on notification returned 1")
	check(msg_box._is_dialog_active == false, "Modal dialog not opened for corner notification")
	check(msg_box._toast_root.visible == true, "Toast notification root is visible")
	check(msg_box._toast_label.text == "...", "Toast notification label displays message text")

	# Notifications queue: a second one waits for the first to fade.
	msg_box.display_message({"text": "second", "is_message_box": false, "display_time": 1.0})
	check(msg_box._toast_label.text == "..." and msg_box._toast_queue.size() == 1, "a second notification waits behind the first")
	msg_box._toast_tween.custom_step(60.0)
	check(msg_box._toast_label.text == "second" and msg_box._toast_queue.is_empty(), "and shows once the first has faded")

	msg_box.free()
	script_engine.message_box = null
	_finish()


func _finish() -> void:
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
