extends Node3D

## Weapon slots on Doc Mitchell: EquipItem takes a weapon out of his inventory
## into a slot; the 10mm pistol hangs at the right hip (1hpholster's prn:
## Bip01 Pelvis), a second pistol at the left hip (the right hip mirrored), the
## hunting rifle on the back (2hrholster's prn: Bip01 Spine2); a drawn weapon
## hangs from the Weapon bone; unequipping puts it back; the slots save as
## instance_ids. Scripts see slotted weapons: GetItemCount counts them,
## GetEquipped reports them, UnequipItem returns one to the inventory and
## RemoveItem takes one away. The minigun takes the back slot: its Backpack
## hangs from Bip01 Spine2, its holstered gun stays on the right hand hidden
## (2hhholster), and shows when drawn. The actor node's control inputs:
## equip_slot() draws a slot, fire() with nothing drawn draws the last drawn
## and with a weapon drawn fires it, holster() holsters. An actor node given
## its reference after it is ready (PlayerController.possess(): configure()
## then load_actor()) hangs that reference's weapons.

const PISTOL := "Weap10mmPistol"
const SECOND_PISTOL := "WeapNV9mmPistol"
const RIFLE := "WeapHuntingRifle"
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
	var doc := EsmServer.find_reference_by_editor_id("DocMitchellREF") as ActorReference
	var controller := EsmReferencePhysicaliser.new().physicalise(doc, self) as NpcController
	await _wait_until(func() -> bool: return controller.actor != null and controller.actor.find_child("Skeleton3D", true, false) != null)
	var node := controller.actor
	var skeleton := node.find_child("Skeleton3D", true, false) as Skeleton3D
	check(skeleton != null, "Doc's body is built")
	if skeleton == null:
		_finish()
		return
	var slots := node.weapon_slots
	var pistol_base := EsmServer.find_base_by_editor_id(PISTOL) as WeaponBase

	ScriptServer.run_debug_line("DocMitchellREF.EquipItem %s" % PISTOL)
	var pistol := doc.weapon_right_hip
	check(pistol != null and pistol.base == pistol_base, "EquipItem puts the 10mm pistol in the right hip slot")
	check(doc.contents.get_item_count(pistol_base.form_id) == 0, "and takes it out of his inventory")
	check(pistol != null and pistol.get_holder() == doc, "the weapon reference's holder is Doc")
	var pistol_node := await _node_of(slots, pistol)
	check(_bone_of(pistol_node) == "Bip01 Pelvis", "the holstered 10mm hangs from Bip01 Pelvis (%s)" % _bone_of(pistol_node))
	check(pistol_node != null and pistol_node.is_held, "its node is held")
	await _check_meshes_follow(pistol_node)

	ScriptServer.run_debug_line("DocMitchellREF.EquipItem %s" % SECOND_PISTOL)
	var second := doc.weapon_left_hip
	check(second != null and doc.weapon_right_hip == pistol, "a second pistol goes to the left hip")
	var second_node := await _node_of(slots, second)
	check(_bone_of(second_node) == "Bip01 Pelvis", "the left hip hangs from Bip01 Pelvis too")
	if pistol_node != null and second_node != null:
		var right_offset := _across(skeleton, pistol_node.position, pistol_node)
		var left_offset := _across(skeleton, second_node.position, second_node)
		check(absf(right_offset + left_offset) < 0.01 and absf(right_offset) > 0.01,
				"the left hip mirrors the right across the body (%.3f, %.3f m)" % [right_offset, left_offset])

	ScriptServer.run_debug_line("DocMitchellREF.EquipItem %s" % RIFLE)
	var rifle := doc.weapon_back
	var rifle_node := await _node_of(slots, rifle)
	check(rifle != null and _bone_of(rifle_node) == "Bip01 Spine2", "the hunting rifle hangs on the back, from Bip01 Spine2 (%s)" % _bone_of(rifle_node))

	check(doc.draw_weapon(ActorReference.WeaponSlot.RIGHT_HIP), "drawing the right hip")
	pistol_node = await _node_of(slots, pistol)
	await _wait_until(func() -> bool: return _bone_of(pistol_node) == "Weapon")
	check(_bone_of(pistol_node) == "Weapon" and pistol_node.transform.is_equal_approx(Transform3D.IDENTITY), "puts the 10mm on the Weapon bone, at its equip clip's prn: key")
	doc.holster_weapon()
	check(doc.draw_weapon(), "drawing with no slot draws the last drawn")
	check(doc.drawn_weapon_slot == ActorReference.WeaponSlot.RIGHT_HIP, "the last drawn is the right hip, drawn above")

	var saved := SaveFields.write(doc)
	check(rifle != null and str(saved.get("weapon_right_hip", "")) == str(pistol.instance_id) and str(saved.get("weapon_back", "")) == str(rifle.instance_id),
			"the slots save as their weapons' instance_ids")

	check(doc.unequip_weapon(ActorReference.WeaponSlot.RIGHT_HIP), "unequipping the right hip")
	check(doc.weapon_right_hip == null and doc.contents.get_item_count(pistol_base.form_id) == 1, "puts the 10mm back in his inventory")
	await get_tree().process_frame
	check(slots.get_weapon_node(pistol) == null, "and frees its node")
	await _check_control_inputs(doc, node, slots)
	_check_script_queries(doc, pistol_base)
	await _check_heavy(doc, slots)
	await _check_late_reference()
	for slot in [ActorReference.WeaponSlot.LEFT_HIP, ActorReference.WeaponSlot.BACK]:
		doc.unequip_weapon(slot)
	_finish()


## Moves the holder and checks the held weapon's meshes move with it: its
## rigid body must not pin them where it was built.
func _check_meshes_follow(weapon: EsmWeaponNode) -> void:
	var mesh: MeshInstance3D = null
	for frame in FRAMES:
		var found := weapon.find_children("*", "MeshInstance3D", true, false) if weapon != null else []
		if not found.is_empty() and weapon.body != null:
			mesh = found[0]
			break
		await get_tree().process_frame
	check(mesh != null, "the held 10mm has meshes and a rigid body")
	if mesh == null:
		return
	var holder := weapon.get_parent().get_parent().get_parent() as Node3D
	while holder != null and not holder is EsmActorNode:
		holder = holder.get_parent() as Node3D
	var mesh_before := mesh.global_position
	var weapon_before := weapon.global_position
	holder.global_position += Vector3(3.0, 0.0, 0.0)
	for frame in 5:
		await get_tree().process_frame
	var weapon_moved := weapon.global_position - weapon_before
	var mesh_moved := mesh.global_position - mesh_before
	check(weapon_moved.length() > 2.9 and mesh_moved.is_equal_approx(weapon_moved),
			"moving the holder 3 m moves the weapon's meshes with it (%s, weapon %s)" % [mesh_moved, weapon_moved])
	holder.global_position -= Vector3(3.0, 0.0, 0.0)


func _check_late_reference() -> void:
	var player := EsmServer.get_player_reference()
	ScriptServer.player_reference = player
	var actor := (load("res://GodotBryo/Types/Node/esm_actor_node.tscn") as PackedScene).instantiate() as EsmActorNode
	add_child(actor)
	actor.placed_by_parent = true
	actor.configure(player)
	actor.load_actor()
	await _wait_until(func() -> bool: return actor.find_child("Skeleton3D", true, false) != null)
	ScriptServer.run_debug_line("player.EquipItem %s" % PISTOL)
	check(player.weapon_right_hip != null, "the player's reference holds the 10mm")
	var node := await _node_of(actor.weapon_slots, player.weapon_right_hip)
	check(node != null, "an actor node given its reference late hangs the player's 10mm")
	actor.possessed_first_person = true
	actor.refresh_first_person_render_mode()
	player.draw_weapon(ActorReference.WeaponSlot.RIGHT_HIP)
	for frame in 30:
		await get_tree().process_frame
	var meshes := node.find_children("*", "MeshInstance3D", true, false) if node != null else []
	check(not meshes.is_empty() and meshes.all(func(mesh: MeshInstance3D) -> bool: return mesh.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY),
			"in first person the possessed actor's drawn weapon shows only its shadow")
	player.unequip_weapon(ActorReference.WeaponSlot.RIGHT_HIP)
	actor.queue_free()


func _check_control_inputs(doc: ActorReference, actor: EsmActorNode, slots: ActorWeaponSlots) -> void:
	ScriptServer.run_debug_line("DocMitchellREF.EquipItem %s" % PISTOL)
	doc.holster_weapon()
	check(actor.equip_slot(0) and doc.drawn_weapon_slot == ActorReference.WeaponSlot.RIGHT_HIP, "equip_slot(0) draws the right hip")
	check(actor.holster() and doc.drawn_weapon_slot == ActorReference.WeaponSlot.NONE, "holster() holsters it")
	check(not actor.equip_slot(7), "equip_slot() of a slot that does not exist does nothing")
	check(actor.fire() and doc.drawn_weapon_slot == ActorReference.WeaponSlot.RIGHT_HIP, "fire() with nothing drawn draws the last drawn")
	var pistol := doc.weapon_right_hip
	var node := await _node_of(slots, pistol)
	for frame in FRAMES:
		if node.muzzle != null:
			break
		await get_tree().process_frame
	await _wait_until(func() -> bool: return node.get_action() == EsmWeaponNode.Action.NONE)
	pistol.loaded_ammo_count = 3
	check(actor.fire() and pistol.loaded_ammo_count == 2, "fire() with the pistol drawn, once its equip clip ends, fires it")
	actor.holster()
	doc.unequip_weapon(ActorReference.WeaponSlot.RIGHT_HIP)


func _check_heavy(doc: ActorReference, slots: ActorWeaponSlots) -> void:
	ScriptServer.run_debug_line("DocMitchellREF.EquipItem %s" % MINIGUN)
	var minigun := doc.weapon_back
	check(minigun != null and minigun.base.editor_id == MINIGUN, "the minigun takes the back slot")
	var node := await _node_of(slots, minigun)
	check(_bone_of(node) == "Bip01 R Hand", "holstered, it stays on Bip01 R Hand (%s)" % _bone_of(node))
	var gun: Node3D = null
	var backpack: Node3D = null
	for frame in FRAMES:
		gun = node.get_part("##MinigunGun") if node != null else null
		backpack = _find_backpack(node)
		if gun != null and backpack != null:
			break
		await get_tree().process_frame
	check(backpack != null and backpack.get_parent() is BoneAttachment3D and (backpack.get_parent() as BoneAttachment3D).bone_name == "Bip01 Spine2",
			"its Backpack hangs from Bip01 Spine2")
	for frame in 10:
		await get_tree().process_frame
	check(backpack != null and backpack.transform.is_equal_approx(Transform3D.IDENTITY),
			"the Backpack keeps its authored transform under the spine; its own rigid body does not move it (%s)" % (backpack.transform if backpack != null else "none"))
	check(gun != null and not gun.visible, "its gun is hidden while holstered")
	doc.draw_weapon(ActorReference.WeaponSlot.BACK)
	await _wait_until(func() -> bool: return node.get_action() == EsmWeaponNode.Action.NONE and _bone_of(node) == "Weapon")
	check(_bone_of(node) == "Weapon" and gun != null and gun.visible, "drawn, it is on the Weapon bone with its gun shown")
	check(backpack != null and is_instance_valid(backpack) and (backpack.get_parent() as BoneAttachment3D).bone_name == "Bip01 Spine2", "and its Backpack stays on the spine")
	doc.unequip_weapon(ActorReference.WeaponSlot.BACK)
	await get_tree().process_frame
	check(not is_instance_valid(backpack) or backpack.is_queued_for_deletion(), "unequipping frees the Backpack with the weapon")


## The minigun's Backpack, moved to a bone attachment under the skeleton.
func _find_backpack(node: EsmWeaponNode) -> Node3D:
	if node == null:
		return null
	var skeleton := node.get_parent().get_parent() as Skeleton3D if node.get_parent() != null else null
	if skeleton == null:
		return null
	for part: Node in skeleton.find_children("*", "Node3D", true, false):
		if String(part.get_meta(NifNames.META_NIF_NAME, "")) == "Backpack":
			return part as Node3D
	return null


func _check_script_queries(doc: ActorReference, pistol_base: WeaponBase) -> void:
	var registry: ScriptFunctionRegistry = ScriptServer.function_registry
	var ctx := ScriptExecutionContext.new(doc)
	var held := doc.contents.get_item_count(pistol_base.form_id)
	ScriptServer.run_debug_line("DocMitchellREF.EquipItem %s" % PISTOL)
	check(doc.get_weapon_slots_of(pistol_base.form_id).size() == 1, "the 10mm is equipped again")
	check(registry.call_function("GetItemCount", [pistol_base], ctx) == held,
			"GetItemCount counts the equipped 10mm (%s of %d)" % [registry.call_function("GetItemCount", [pistol_base], ctx), held])
	check(registry.call_function("GetEquipped", [pistol_base], ctx) == 1, "GetEquipped reports it")
	registry.call_function("UnequipItem", [pistol_base], ctx)
	check(doc.get_weapon_slots_of(pistol_base.form_id).is_empty() and doc.contents.get_item_count(pistol_base.form_id) == held,
			"UnequipItem returns it to the inventory")
	check(registry.call_function("GetEquipped", [pistol_base], ctx) == 0, "GetEquipped then reports nothing")
	ScriptServer.run_debug_line("DocMitchellREF.EquipItem %s" % PISTOL)
	registry.call_function("RemoveItem", [pistol_base, held], ctx)
	check(registry.call_function("GetItemCount", [pistol_base], ctx) == 0 and doc.get_weapon_slots_of(pistol_base.form_id).is_empty(),
			"RemoveItem of all he has takes the equipped one too")


## `weapon`'s node once it hangs (its holster clip loads first).
func _node_of(slots: ActorWeaponSlots, weapon: WeaponReference) -> EsmWeaponNode:
	for frame in FRAMES:
		var node := slots.get_weapon_node(weapon)
		if node != null and node.get_parent() != null:
			return node
		await get_tree().process_frame
	return null


func _bone_of(node: Node) -> String:
	if node == null or not node.get_parent() is BoneAttachment3D:
		return ""
	return (node.get_parent() as BoneAttachment3D).bone_name


## How far across the body (along the thighs' left-right axis, from their
## centre, at rest) the node's position lies.
func _across(skeleton: Skeleton3D, _local: Vector3, node: Node3D) -> float:
	var attachment := node.get_parent() as BoneAttachment3D
	var bone_rest := skeleton.get_bone_global_rest(skeleton.find_bone(attachment.bone_name))
	var global := bone_rest * node.position
	var left := skeleton.get_bone_global_rest(skeleton.find_bone("Bip01 L Thigh")).origin
	var right := skeleton.get_bone_global_rest(skeleton.find_bone("Bip01 R Thigh")).origin
	return (global - (left + right) * 0.5).dot((left - right).normalized())


func _wait_until(condition: Callable) -> void:
	for frame in FRAMES:
		if condition.call():
			return
		await get_tree().process_frame


func _finish() -> void:
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
