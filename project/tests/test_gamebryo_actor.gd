extends Node

# Issue #52 chunk 3: scaffolding-only test for GamebryoActor. No real ESM/
# NIF data yet (that's chunk 4) -- just proves GamebryoActor carries the
# same identity fields as every other GamebryoObject, and deliberately has
# NO composed CharacterBody3D/collider (physical movement is real future
# work -- see gamebryo_actor.gd's own doc comment for why, including the
# plan for an actor node to eventually live inside the player's own
# controller rather than each actor owning an independent physics body).

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func _ready() -> void:
	var actor := GamebryoActor.new()
	actor.form_id = 0x00104C0F
	actor.base_form_id = 0x00104C0C
	actor.editor_id = "DocMitchell"
	actor.record_type = "NPC_"
	add_child(actor)

	check(actor is GamebryoObject, "GamebryoActor is a GamebryoObject")
	check(actor.form_id == 0x00104C0F, "identity fields (form_id) inherited from GamebryoReference")
	check(actor.editor_id == "DocMitchell", "identity fields (editor_id) inherited from GamebryoObject")
	check(actor.record_type == "NPC_", "identity fields (record_type) inherited from GamebryoObject")

	check(actor.get_children().is_empty(), "no composed physics body -- GamebryoActor stays identity-only for now (movement deferred)")

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
