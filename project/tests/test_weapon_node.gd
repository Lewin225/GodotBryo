extends Node3D

## EsmWeaponNode on its own: the physicaliser builds one for a WEAP reference;
## its world model loads with the muzzle, shell ejection and sighting nodes
## found (the 10mm pistol has all three, the Minigun's muzzle is nested under
## ##MinigunGun, the Gatling Laser's is named ##ProjectileNode, the cleaver has
## none); its state survives a save round trip.

const PISTOL := "Weap10mmPistol"
const MINIGUN := "WeapMinigun"
const CLEAVER := "WeapNVCleaver"
const GATLING_LASER := "WeapGatlingLaser"

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

	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)


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
