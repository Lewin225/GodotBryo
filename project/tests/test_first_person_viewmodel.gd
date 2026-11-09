extends Node3D

## FirstPersonViewmodel: a first-person rig following an actor copies the
## actor's drawn weapon onto the rig skeleton's Weapon bone, as the weapon's
## viewmodel (WNAM's STAT model, else MODL), with no physics; holstering clears
## it. The straight razor's viewmodel is its separate first-person NIF. In
## PlayerController.possess()'s order (the rig follows the actor node before
## the node is given the player's reference) the player's drawn weapon is
## copied too.

const PISTOL := "Weap10mmPistol"
const RAZOR := "WeapNVStraightRazor"
const MINIGUN := "WeapMinigun"
const FRAMES := 900

var failures := 0


func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1


func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var razor := EsmServer.find_base_by_editor_id(RAZOR) as WeaponBase
	check(FirstPersonViewmodel.viewmodel_path(razor).to_lower().ends_with("1stpersonstraightrazor.nif"),
			"the straight razor's viewmodel is its WNAM model (%s)" % FirstPersonViewmodel.viewmodel_path(razor))
	var pistol_base := EsmServer.find_base_by_editor_id(PISTOL) as WeaponBase
	check(FirstPersonViewmodel.viewmodel_path(pistol_base).to_lower() == pistol_base.model_path.to_lower(),
			"the 10mm pistol's WNAM model is its world model (%s)" % FirstPersonViewmodel.viewmodel_path(pistol_base))

	var doc := EsmServer.find_reference_by_editor_id("DocMitchellREF") as ActorReference
	var controller := EsmReferencePhysicaliser.new().physicalise(doc, self) as NpcController
	var rig := (load("res://GodotBryo/Types/Node/first_person_rig.tscn") as PackedScene).instantiate() as FirstPersonRig
	add_child(rig)
	await _wait_until(func() -> bool: return controller.actor != null and controller.actor.find_child("Skeleton3D", true, false) != null and rig.skeleton != null)
	rig.follow(controller.actor)
	var viewmodel := rig.get_node("Viewmodel") as FirstPersonViewmodel

	ScriptServer.run_debug_line("DocMitchellREF.EquipItem %s" % PISTOL)
	await _wait_frames(5)
	check(viewmodel.model == null, "a holstered weapon has no viewmodel")
	doc.draw_weapon(ActorReference.WeaponSlot.RIGHT_HIP)
	await _wait_until(func() -> bool: return viewmodel.model != null)
	check(viewmodel.model != null and viewmodel.weapon == doc.weapon_right_hip, "drawing the 10mm builds its viewmodel")
	var attachment := viewmodel.model.get_parent() as BoneAttachment3D if viewmodel.model != null else null
	check(attachment != null and attachment.bone_name == "Weapon" and attachment.get_parent() == rig.skeleton,
			"on the rig skeleton's Weapon bone")
	check(viewmodel.model != null and viewmodel.model.find_children("*", "CollisionObject3D", true, false).is_empty(),
			"with no rigid bodies or collision")
	doc.holster_weapon()
	await _wait_frames(2)
	check(viewmodel.model == null, "holstering clears it")

	ScriptServer.run_debug_line("DocMitchellREF.EquipItem %s" % MINIGUN)
	doc.draw_weapon(ActorReference.WeaponSlot.BACK)
	await _wait_until(func() -> bool: return viewmodel.model != null)
	var backpack: Node3D = null
	for node: Node in rig.skeleton.find_children("*", "Node3D", true, false):
		if String(node.get_meta(NifNames.META_NIF_NAME, "")) == "Backpack":
			backpack = node
	check(backpack != null and (backpack.get_parent() as BoneAttachment3D).bone_name == "Bip01 Spine2", "the minigun's viewmodel Backpack hangs from the rig's Bip01 Spine2")
	for slot in [ActorReference.WeaponSlot.RIGHT_HIP, ActorReference.WeaponSlot.BACK]:
		doc.unequip_weapon(slot)
	await _wait_frames(2)
	check(viewmodel.model == null, "unequipping clears it")
	await _check_possess_order()
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _check_possess_order() -> void:
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
	await _wait_until(func() -> bool: return actor.find_child("Skeleton3D", true, false) != null and rig.skeleton != null)
	ScriptServer.run_debug_line("player.EquipItem %s" % PISTOL)
	player.draw_weapon(ActorReference.WeaponSlot.RIGHT_HIP)
	var viewmodel := rig.get_node("Viewmodel") as FirstPersonViewmodel
	await _wait_until(func() -> bool: return viewmodel.model != null)
	check(viewmodel.model != null and viewmodel.weapon == player.weapon_right_hip,
			"a rig following the actor node before it has the player's reference copies the player's drawn 10mm")
	player.unequip_weapon(ActorReference.WeaponSlot.RIGHT_HIP)


func _wait_until(condition: Callable) -> void:
	for frame in FRAMES:
		if condition.call():
			return
		await get_tree().process_frame


func _wait_frames(count: int) -> void:
	for frame in count:
		await get_tree().process_frame
