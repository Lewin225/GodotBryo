extends Node3D

## EsmWeaponNode on its own: the physicaliser builds one for a WEAP reference;
## its world model loads with the muzzle, shell ejection and sighting nodes
## found (the 10mm pistol has all three, the Minigun's muzzle is nested under
## ##MinigunGun, the Gatling Laser's is named ##ProjectileNode, the cleaver has
## none); its state survives a save round trip. With no holder, the 10mm pistol
## fires (spending a round and playing 1hpattackright on its parts), reloads
## to its clip size, clears a jam by itself and aims; 1hpaim keys none of its
## parts but does key the .357 revolver's, which plays it. WeaponBase reads
## DNAM, CRDT and NAM0: the 10mm pistol's and minigun's values as the raw
## bytes give them.

const PISTOL := "Weap10mmPistol"
const MINIGUN := "WeapMinigun"
const CLEAVER := "WeapNVCleaver"
const GATLING_LASER := "WeapGatlingLaser"
const REVOLVER := "WeapNV357Revolver"

var failures := 0


func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1


func _ready() -> void:
	var esm_server = get_node("/root/EsmServer")
	if not esm_server.is_ready():
		await esm_server.esm_ready

	var pistol := await _place(esm_server, PISTOL)
	check(pistol is EsmWeaponNode, "a WEAP reference physicalises as an EsmWeaponNode")
	if pistol is EsmWeaponNode:
		check(pistol.get_weapon_base() != null and pistol.get_weapon_base().editor_id == PISTOL, "the node's base is the %s WEAP" % PISTOL)
		check(pistol.muzzle != null, "the 10mm pistol's muzzle node is found")
		check(pistol.shell_ejection != null, "the 10mm pistol's shell ejection node is found")
		check(pistol.sighting != null, "the 10mm pistol's sighting node is found")

	var minigun := await _place(esm_server, MINIGUN)
	if minigun is EsmWeaponNode:
		var parent_name := ""
		if minigun.muzzle != null:
			parent_name = String(minigun.muzzle.get_parent().get_meta(NifNames.META_NIF_NAME, ""))
		check(parent_name == "##MinigunGun", "the Minigun's muzzle is found under ##MinigunGun (got '%s')" % parent_name)
	else:
		check(false, "the Minigun physicalises as an EsmWeaponNode")

	var gatling := await _place(esm_server, GATLING_LASER)
	check(gatling is EsmWeaponNode and gatling.muzzle != null, "the Gatling Laser's ##ProjectileNode is its muzzle")

	var cleaver := await _place(esm_server, CLEAVER)
	if cleaver is EsmWeaponNode:
		check(cleaver.muzzle == null and cleaver.shell_ejection == null and cleaver.sighting == null, "the cleaver has no muzzle, shell ejection or sighting node")
	else:
		check(false, "the cleaver physicalises as an EsmWeaponNode")

	if pistol is EsmWeaponNode:
		var weapon: WeaponReference = pistol.get_weapon_reference()
		weapon.loaded_ammo_count = 9
		weapon.is_jammed = true
		var data := SaveFields.write(weapon)
		check(int(data.get("loaded_ammo_count", -1)) == 9 and bool(data.get("is_jammed", false)), "loaded ammo and jammed are saved fields")

	_check_base_fields(esm_server)
	if pistol is EsmWeaponNode:
		await _check_inputs(pistol)

	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)


## Expected values read from FalloutNV.esm's raw DNAM, CRDT and NAM0 bytes.
func _check_base_fields(esm_server: Node) -> void:
	var pistol := esm_server.find_base_by_editor_id(PISTOL) as WeaponBase
	check(is_equal_approx(pistol.min_spread, 0.8) and is_equal_approx(pistol.spread, 0.5) and pistol.projectile_count == 1,
			"10mm spread 0.8 / 0.5, one projectile")
	check(is_equal_approx(pistol.attack_shots_per_second, 2.75) and is_equal_approx(pistol.reload_time, 1.3) and is_equal_approx(pistol.max_range, 768.0),
			"10mm 2.75 shots/s, reload 1.3 s, max range 768")
	check(pistol.projectile_form_id == 0x0002CD5F and pistol.ammo_form_id == 0x001537E6 and pistol.ammo != null,
			"10mm projectile 0002CD5F, ammo 001537E6 resolved (%s)" % (pistol.ammo.get_class() if pistol.ammo != null else "none"))
	check(pistol.critical_damage == 22 and (pistol.flags1 & WeaponBase.FLAG1_IS_AUTOMATIC) == 0, "10mm critical damage 22, not automatic")
	var minigun := esm_server.find_base_by_editor_id(MINIGUN) as WeaponBase
	check(minigun.flags1 == 0x52 and (minigun.flags1 & WeaponBase.FLAG1_IS_AUTOMATIC) != 0 and (minigun.flags1 & WeaponBase.FLAG1_HIDE_BACKPACK) != 0,
			"minigun Flags 1 0x52: automatic, Hide Backpack")
	check(minigun.flags2 == 0x908 and is_equal_approx(minigun.fire_rate, 20.0) and is_equal_approx(minigun.critical_chance_multiplier, 0.5),
			"minigun Flags 2 0x908, fire rate 20, crit % mult 0.5")


func _check_inputs(pistol: EsmWeaponNode) -> void:
	var weapon: WeaponReference = pistol.get_weapon_reference()
	var base: WeaponBase = pistol.get_weapon_base()
	check(base.attack_clip_path().ends_with("1hpattackright.kf") and base.reload_clip_path().ends_with("1hpreloada.kf"),
			"the 10mm pistol's clips are 1hpattackright and 1hpreloada (%s, %s)" % [base.attack_clip_path(), base.reload_clip_path()])
	weapon.is_jammed = false
	weapon.loaded_ammo_count = 0
	check(not pistol.fire(), "an empty weapon does not fire")

	check(pistol.reload(), "reload starts")
	check(await _wait_for(pistol.reloaded), "the reload ends")
	check(weapon.loaded_ammo_count == base.clip_size, "the reload fills the clip (%d of %d)" % [weapon.loaded_ammo_count, base.clip_size])

	check(pistol.fire(), "a loaded weapon fires")
	check(weapon.loaded_ammo_count == base.clip_size - 1, "firing spends one round")
	await _wait_frames(30)
	var attack: Dictionary = pistol._animator.get_start(EsmWeaponNode.SLOT_ACTION)
	check(bool(attack.get("played", false)) and String(attack.get("path", "")) == base.attack_clip_path(),
			"the attack clip plays on the weapon's parts")

	pistol.jam()
	check(weapon.is_jammed and not pistol.fire(), "a jammed weapon does not fire")
	check(await _wait_for(pistol.jam_cleared), "the jam clip ends")
	check(not weapon.is_jammed, "the jam clears with no input")

	pistol.aim(true)
	await _wait_frames(30)
	check(pistol.is_aiming and pistol._animator.get_start(EsmWeaponNode.SLOT_AIM).is_empty(),
			"the 10mm aims; 1hpaim keys none of its parts, so nothing plays")
	pistol.aim(false)
	check(not pistol.is_aiming, "aim(false) lowers the weapon")

	var revolver := await _place(EsmServer, REVOLVER)
	if revolver is EsmWeaponNode:
		revolver.aim(true)
		await _wait_frames(30)
		var aim: Dictionary = revolver._animator.get_start(EsmWeaponNode.SLOT_AIM)
		check(bool(aim.get("played", false)), "the .357 revolver's aim plays 1hpaim on its parts")
	else:
		check(false, "the .357 revolver physicalises as an EsmWeaponNode")


## Whether `event` fires within 10 seconds.
func _wait_for(event: Signal) -> bool:
	var state := {"fired": false}
	var on_event := func(_a = null, _b = null) -> void: state["fired"] = true
	event.connect(on_event, CONNECT_ONE_SHOT)
	for i in 600:
		if state["fired"]:
			return true
		await get_tree().process_frame
	return state["fired"]


func _wait_frames(count: int) -> void:
	for i in count:
		await get_tree().process_frame


## A runtime reference of the WEAP `editor_id`, physicalised under this node,
## once its model has loaded (or after 600 frames).
func _place(esm_server: Node, editor_id: String) -> EsmNode:
	var base: EsmBase = esm_server.find_base_by_editor_id(editor_id)
	check(base is WeaponBase, "%s is a WEAP" % editor_id)
	if base == null:
		return null
	var reference: EsmReference = esm_server.create_runtime_reference(base.form_id)
	var node: EsmNode = EsmReferencePhysicaliser.new().physicalise(reference, self)
	for i in 600:
		if node == null or node._visual_node(node.visual_detail) != null:
			break
		await get_tree().process_frame
	check(node != null and node._visual_node(node.visual_detail) != null, "%s's world model loads" % editor_id)
	return node
