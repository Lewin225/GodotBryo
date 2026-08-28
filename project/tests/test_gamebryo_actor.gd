extends Node

# Issue #52 chunk 3: scaffolding-only test for GamebryoActor. No real ESM/
# NIF data yet (that's chunk 4) -- just proves the composed CharacterBody3D
# child builds correctly, mirrors GamebryoVisual's StaticBody3D composition
# trick (see gamebryo_actor.gd / enginedocs/nv_class_hierarchy.md), and that
# GamebryoActor inherits the same identity fields as every other
# GamebryoObject.

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

	check(actor.get_character_body() == null, "no CharacterBody until populate_character_body() is called")

	var body := actor.populate_character_body()
	check(body != null, "populate_character_body() returns a real body")
	check(body is CharacterBody3D, "composed body is a CharacterBody3D (not Static/RigidBody3D -- actors move under AI)")
	check(body.owner_ref == actor, "composed body's owner_ref resolves back to the actor, same convention as GamebryoCollisionBody/GamebryoRigidBody")
	check(actor.get_node_or_null(^"CharacterBody") == body, "body is a real child node named \"CharacterBody\"")
	check(actor.get_character_body() == body, "get_character_body() finds the same node")

	var col := body.get_node_or_null(^"CollisionShape3D") as CollisionShape3D
	check(col != null, "CharacterBody has a CollisionShape3D child")
	if col != null:
		check(col.shape is CapsuleShape3D, "collision shape is a capsule (human-scale placeholder)")
		var cap := col.shape as CapsuleShape3D
		check(cap.radius > 0.0 and cap.height > 0.0, "capsule has real non-zero dimensions (radius=%.2f height=%.2f)" % [cap.radius, cap.height])

	var second_call := actor.populate_character_body()
	check(second_call == body, "populate_character_body() is idempotent -- calling twice doesn't stack a second CharacterBody")
	check(actor.get_children().filter(func(c): return c is CharacterBody3D).size() == 1, "exactly one CharacterBody3D child after two calls")

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
