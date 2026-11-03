extends Node

## SaveFields: an NPC, a container, a door, a runtime weapon and a quest's
## state, each changed in play, written to plain values, sent through JSON text
## and read into a fresh instance of the same class, then written again; the
## two writes match, the output holds no Object, and the links resolve to the
## same objects.

const KEY_FIELDS := ["instance_id", "base_form_id"]

var failures := 0

func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var stimpak := EsmServer.find_base_by_editor_id("Stimpak")

	var doc := EsmServer.find_reference_by_editor_id("DocMitchellREF") as ActorReference
	var player := EsmServer.get_player_reference()
	doc.position += Vector3(1.25, -0.5, 0.0)
	doc.look_target = player
	doc.package_completed = true
	doc.get_actor_values().damage_value(ActorValue.HEALTH, 12.0)
	doc.contents.add_item(stimpak.form_id, null, 3)
	doc.script_instance = ScriptInstance.new()
	doc.script_instance.set_local("talked", 2)
	doc.script_instance.set_local("helper", player)
	var doc_copy := _round_trip(doc, "Doc Mitchell") as ActorReference
	check(doc_copy.look_target == player, "Doc's look target reads back as the player's reference")
	check(doc_copy.position.is_equal_approx(doc.position), "Doc's position reads back as a Vector3")
	check(is_equal_approx(doc_copy.get_actor_values().damage.get(ActorValue.HEALTH, 0.0), -12.0), "Doc's Health damage reads back by its code")
	check(doc_copy.contents.get_item_count(stimpak.form_id) == doc.contents.get_item_count(stimpak.form_id), "Doc's stimpaks read back as a stack of the same base")
	check(doc_copy.script_instance.get_local("helper") == player, "a ref local reads back as the same reference")
	var doc_data := SaveFields.write(doc, KEY_FIELDS)
	check((doc_data["actor_values"]["damage"] as Dictionary).has("Health"), "actor values are keyed by name")
	check(not doc_data.has("is_moving") and not doc_data.has("simulation_mode") and not doc_data.has("current_cell_form_id") and not doc_data.has("level_modifier"),
			"per-frame, derived and ESM-read fields are not saved")

	var container := _first_reference_of(ContainerReference) as ContainerReference
	container.is_open = true
	container.contents.add_item(stimpak.form_id, null, 2)
	var container_copy := _round_trip(container, "a container") as ContainerReference
	check(container_copy.is_open and container_copy.contents.get_item_count(stimpak.form_id) == container.contents.get_item_count(stimpak.form_id), "the container's open state and contents read back")

	var door := EsmServer.get_reference_by_form_id(0x0010901D) as DoorReference
	door.is_open = not door.is_open
	door.is_locked = true
	door.lock_level = 3
	var door_copy := _round_trip(door, "a door") as DoorReference
	check(door_copy.is_open == door.is_open and door_copy.is_locked and door_copy.lock_level == 3, "the door's open and lock state read back")

	var ammo := EsmServer.find_base_by_editor_id("Ammo9mm")
	var weapon := EsmServer.create_runtime_reference(0x000E3778) as WeaponReference
	weapon.condition = 0.42
	weapon.loaded_ammo_form_id = ammo.form_id
	weapon.loaded_ammo_count = 7
	var weapon_copy := _round_trip(weapon, "a runtime weapon") as WeaponReference
	check(is_equal_approx(weapon_copy.condition, 0.42) and weapon_copy.loaded_ammo_form_id == ammo.form_id and weapon_copy.loaded_ammo_count == 7,
			"the weapon's condition and loaded ammo read back, the ammo by its record")
	check(SaveFields.write(weapon)["loaded_ammo_form_id"] == String(EsmServer.instance_id_for_form_id(ammo.form_id)), "a *_form_id field is written as <file>:<local id>")
	EsmServer.release_runtime_reference(weapon)

	var vcg01 := EsmServer.find_quest_by_editor_id("VCG01")
	var state := QuestState.new()
	state.quest_form_id = vcg01.form_id
	state.stage = 10
	state.stages_done = {0: true, 10: true}
	state.running = true
	state.objectives_displayed = {10: true}
	var state_copy := _round_trip(state, "VCG01's quest state") as QuestState
	check(state_copy.quest_form_id == vcg01.form_id and state_copy.stage == 10 and state_copy.stages_done.has(10) and state_copy.objectives_displayed.get(10, false),
			"the quest state's record, stage, done stages and objectives read back with int keys")

	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

## Writes `resource`, sends it through JSON text, reads it into a fresh
## instance of its class, writes that, and checks the two writes match.
func _round_trip(resource: Resource, label: String) -> Resource:
	var skipped: Array = KEY_FIELDS if resource is EsmReference else []
	var data := SaveFields.write(resource, skipped)
	check(not SaveFields.holds_object(data), "%s's saved fields hold no Object" % label)
	var text := JSON.stringify(data, "\t", true)
	var copy: Resource = resource.get_script().new()
	if resource is EsmReference:
		copy.instance_id = resource.instance_id
		copy.base_form_id = resource.base_form_id
		copy.base = resource.base
	SaveFields.read(copy, JSON.parse_string(text), skipped)
	var again := JSON.stringify(SaveFields.write(copy, skipped), "\t", true)
	check(again == text, "%s writes the same after a read through JSON" % label)
	if again != text:
		print(text, "\n---\n", again)
	return copy

func _first_reference_of(type: Script) -> EsmReference:
	for row: Dictionary in EsmServer.get_record_index():
		if String(row.get("record_type", "")) != "REFR":
			continue
		var reference := EsmServer.get_reference_by_form_id(int(row.get("form_id", 0)))
		if is_instance_of(reference, type):
			return reference
	return null
