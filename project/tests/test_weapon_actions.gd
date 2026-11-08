extends Node3D

## Weapon actions on Doc Mitchell with the 10mm pistol. Drawing plays 1hpequip
## on the weapon (the clock); the actor's weapon action slot follows it, and the
## weapon stays on the pelvis until the clip's prn: key, then hangs from the
## Weapon bone. Drawn, the actor's stance slot plays 1hpaim. Firing plays
## 1hpattackright on the weapon; the actor follows it on the weapon's clock, and
## a first-person rig following the actor plays _1stperson/1hpattackright.
## Holstering plays 1hpunequip, returns the weapon to the pelvis and ends the
## stance.

const PISTOL := "Weap10mmPistol"
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
	var rig := (load("res://GodotBryo/Types/Node/first_person_rig.tscn") as PackedScene).instantiate() as FirstPersonRig
	add_child(rig)
	await _wait_until(func() -> bool: return controller.actor != null and controller.actor.animator.is_loaded() and rig.skeleton != null)
	var actor := controller.actor
	rig.follow(actor)
	var body_animator := actor.animator.get_kf_animator()
	var rig_animator := rig.get_node("KfAnimator") as KfAnimator

	ScriptServer.run_debug_line("DocMitchellREF.EquipItem %s" % PISTOL)
	var pistol := doc.weapon_right_hip
	await _wait_until(func() -> bool:
		var built := actor.weapon_slots.get_weapon_node(pistol)
		return built != null and built.get_parent() != null and built.muzzle != null)
	var node := actor.weapon_slots.get_weapon_node(pistol)
	check(_bone_of(node) == "Bip01 Pelvis", "the holstered 10mm is on the pelvis")

	doc.draw_weapon(ActorReference.WeaponSlot.RIGHT_HIP)
	var weapon_animator := node.get_animator()
	check(node.get_action() == EsmWeaponNode.Action.EQUIP, "drawing plays the equip clip on the weapon")
	await _wait_until(func() -> bool: return bool(body_animator.get_start(ActorAnimator.WEAPON_ACTION_SLOT).get("played", false)))
	var body_start := body_animator.get_start(ActorAnimator.WEAPON_ACTION_SLOT)
	check(String(body_start.get("path", "")).ends_with("1hpequip.kf"), "the actor's action slot follows it with 1hpequip (%s)" % body_start.get("path", ""))
	if weapon_animator.get_time(ActorAnimator.WEAPON_ACTION_SLOT) < 0.12:
		check(_bone_of(node) == "Bip01 Pelvis", "before the prn: key (0.13 s) the weapon is still on the pelvis")
	await _wait_until(func() -> bool: return _bone_of(node) == "Weapon")
	check(_bone_of(node) == "Weapon", "after it, the weapon hangs from the Weapon bone")
	await _wait_until(func() -> bool: return node.get_action() == EsmWeaponNode.Action.NONE)
	var stance := body_animator.get_start(ActorAnimator.WEAPON_STANCE_SLOT)
	check(String(stance.get("path", "")).ends_with("1hpaim.kf") and bool(stance.get("played", false)), "drawn, the actor's stance slot plays 1hpaim (%s)" % stance.get("path", ""))

	var walking := ActorMotion.new()
	walking.velocity = Vector3(0.0, 0.0, -1.5)
	var family_clip := ActorAnimator.family_locomotion_clip(walking, "1hp")
	check(family_clip == "locomotion/1hpforward.kf" and actor.animator._clips.has(actor.animator._clip_name(actor.animator._root_path + family_clip, 0)),
			"walking with the 10mm drawn picks the loaded locomotion/1hpforward.kf (%s)" % family_clip)
	pistol.loaded_ammo_count = 5
	check(actor.fire(), "the actor fires")
	await _wait_until(func() -> bool: return String(body_animator.get_start(ActorAnimator.WEAPON_ACTION_SLOT).get("path", "")).ends_with("1hpattackright.kf"))
	await _wait_frames(5)
	check(String(body_animator.get_start(ActorAnimator.WEAPON_ACTION_SLOT).get("path", "")).ends_with("1hpattackright.kf"), "the actor follows the attack clip")
	var weapon_time := weapon_animator.get_time(ActorAnimator.WEAPON_ACTION_SLOT)
	var body_time := body_animator.get_time(ActorAnimator.WEAPON_ACTION_SLOT)
	check(weapon_time > 0.0 and is_equal_approx(weapon_time, body_time), "on the weapon's clock (%.3f, %.3f)" % [weapon_time, body_time])
	var rig_start := rig_animator.get_start(ActorAnimator.WEAPON_ACTION_SLOT)
	check(String(rig_start.get("path", "")).contains("_1stperson") and String(rig_start.get("path", "")).ends_with("1hpattackright.kf"),
			"the first-person rig follows with _1stperson/1hpattackright (%s)" % rig_start.get("path", ""))

	doc.holster_weapon()
	await _wait_until(func() -> bool: return node.get_action() == EsmWeaponNode.Action.NONE and _bone_of(node) == "Bip01 Pelvis")
	check(_bone_of(node) == "Bip01 Pelvis", "holstering returns the weapon to the pelvis")
	await _wait_frames(30)
	check(body_animator.get_start(ActorAnimator.WEAPON_STANCE_SLOT).is_empty(), "and ends the stance")
	doc.unequip_weapon(ActorReference.WeaponSlot.RIGHT_HIP)
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _bone_of(node: Node) -> String:
	if node == null or not node.get_parent() is BoneAttachment3D:
		return ""
	return (node.get_parent() as BoneAttachment3D).bone_name


func _wait_until(condition: Callable) -> void:
	for frame in FRAMES:
		if condition.call():
			return
		await get_tree().process_frame


func _wait_frames(count: int) -> void:
	for frame in count:
		await get_tree().process_frame
