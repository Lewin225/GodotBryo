extends Node

## Runs the result script of VCG01's farewell INFO (0x1057E7) that hands VCG01
## to VGenericTimer (nEvent 3), then reports VGenericTimer's state and VCG01's
## stage and completion over a few seconds.
func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	QuestServer.begin_game()
	var vcg01 := EsmServer.find_quest_by_editor_id("VCG01")
	var timer := EsmServer.find_quest_by_editor_id("VGenericTimer")
	QuestServer.set_stage(vcg01, 115)
	var source := "VCG01CasualHardcoreMessageREF.Activate player 1;\nEnablePlayerControls 1 1 0 1 1 1 0\nset VGenericTimer.fTimer to 0.1;\nset VGenericTimer.nEvent to 3;\nStartQuest VGenericTimer;\n"
	var doc := EsmServer.find_reference_by_editor_id("DocMitchellREF")
	print("result script -> ", ScriptServer.run_result_script(source, doc))
	var message_ref := EsmServer.find_reference_by_editor_id("VCG01CasualHardcoreMessageREF")
	print("VCG01CasualHardcoreMessageREF: ", message_ref, " base ", message_ref.base.editor_id if message_ref != null and message_ref.base != null else "none", " space %08X" % (message_ref.current_space_form_id if message_ref != null else 0))
	_report(vcg01, timer)
	for second in 8:
		var until := Time.get_ticks_msec() + 1000
		while Time.get_ticks_msec() < until:
			await get_tree().process_frame
		_report(vcg01, timer)
	get_tree().quit()

func _report(vcg01: EsmBase, timer: EsmBase) -> void:
	var state := QuestServer.get_quest_state(timer)
	var instance: Variant = state.script_instance if state != null else null
	var locals := "no script instance"
	if instance != null:
		locals = "nEvent %s fTimer %s" % [instance.get_local("nEvent"), instance.get_local("fTimer")]
	print("VGenericTimer running %s delay %.2f %s | VCG01 stage %d completed %s running %s | VCG02 stage %d" % [QuestServer.is_running(timer), QuestServer.get_script_delay(timer), locals, QuestServer.get_stage(vcg01), QuestServer.is_completed(vcg01), QuestServer.is_running(vcg01), QuestServer.get_stage(EsmServer.find_quest_by_editor_id("VCG02"))])
