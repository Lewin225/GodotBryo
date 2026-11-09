extends Node3D

## ActorEquipment hangs an unskinned model from the bone its NIF's file root
## names in `Prn`: the player, given the Pip-Boy, commits equipment with the
## Pip-Boy arm on Bip01 L ForeTwist, and a first-person rig following the
## player then wears the body's meshes.

const PIPBOY := "PipBoy"
const FRAMES := 900

var failures := 0


func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1


func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var player := EsmServer.get_player_reference()
	ScriptServer.player_reference = player
	var actor := (load("res://GodotBryo/Types/Node/esm_actor_node.tscn") as PackedScene).instantiate() as EsmActorNode
	add_child(actor)
	var rig := (load("res://GodotBryo/Types/Node/first_person_rig.tscn") as PackedScene).instantiate() as FirstPersonRig
	add_child(rig)
	rig.follow(actor)
	actor.placed_by_parent = true
	actor.configure(player)
	actor.load_actor()
	await _wait_until(func() -> bool: return actor.is_visual_built() and not actor.equipment.is_loading() and rig.skeleton != null)
	ScriptServer.run_debug_line("player.EquipItem %s" % PIPBOY)
	await _wait_until(func() -> bool: return not actor.equipment.is_loading() and _equipment_has_pipboy(actor))
	check(_equipment_has_pipboy(actor), "the player's committed equipment holds the Pip-Boy")
	var arm: BoneAttachment3D = null
	for node: Node in actor.find_children("*", "BoneAttachment3D", true, false):
		for child: Node in node.find_children("*", "Node3D", true, false):
			if String(child.get_meta(NifNames.META_NIF_NAME, "")) == "PipBoyArm":
				arm = node as BoneAttachment3D
	check(arm != null and arm.bone_name == "Bip01 L ForeTwist", "the Pip-Boy arm hangs from its Prn bone, Bip01 L ForeTwist (%s)" % (arm.bone_name if arm != null else "none"))
	await _wait_frames(5)
	check(rig._sources.size() > 0, "the first-person rig wears the body's meshes (%d)" % rig._sources.size())
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _equipment_has_pipboy(actor: EsmActorNode) -> bool:
	for node: Node in actor.find_children("*", "Node3D", true, false):
		if String(node.get_meta(NifNames.META_NIF_NAME, "")) == "PipBoyArm":
			return true
	return false


func _wait_until(condition: Callable) -> void:
	for frame in FRAMES:
		if condition.call():
			return
		await get_tree().process_frame


func _wait_frames(count: int) -> void:
	for frame in count:
		await get_tree().process_frame
