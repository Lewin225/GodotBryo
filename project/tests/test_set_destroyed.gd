extends Node3D

## SetDestroyed. VCG01's stage 0 runs `GSDocMitchellHouseIntDoorREF.setDestroyed
## 1` ("Set door to Doc's house to not work initially"), and Doc's farewell
## INFO (001057E7) runs `SetDestroyed 0` "so player can leave". A destroyed
## reference is one the player's InteractRay cannot target, so the door cannot
## be activated until Doc lets the player go. VCG02's bottles destroy
## themselves OnLoad, so they cannot be picked up. The flag is saved.

const DOOR_ID := "GSDocMitchellHouseIntDoorREF"
const FAREWELL_INFO := 0x001057E7

var failures := 0


func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1


func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	ScriptServer.player_reference = EsmServer.get_player_reference()
	var door: EsmReference = EsmServer.find_reference_by_editor_id(DOOR_ID)
	var node := EsmReferencePhysicaliser.new().physicalise(door, self)
	for frame in 600:
		await get_tree().process_frame
		if not node.find_children("*", "CollisionShape3D", true, false).is_empty():
			break
	for frame in 4:
		await get_tree().physics_frame
	var ray := _aim_ray_at(node)
	check(ray != null, "a ray from 1.2 m finds %s's node" % DOOR_ID)
	if ray == null:
		_finish()
		return
	check(_targets(ray) == node, "before VCG01 starts, the player can target the door")

	var vcg01: QuestBase = EsmServer.find_quest_by_editor_id("VCG01")
	QuestServer.start_quest(vcg01)
	QuestServer.set_stage(vcg01, 0)
	check(door.destroyed, "VCG01 stage 0 destroys the door")
	check(int(ScriptServer.run_result_script("%s.GetDestroyed" % DOOR_ID, null)) == 1, "GetDestroyed reads 1")
	check(_targets(ray) == null, "the player cannot target the destroyed door")
	check(bool(SaveFields.write(door).get("destroyed", false)), "the destroyed flag is saved")

	var farewell := EsmServer.get_base(FAREWELL_INFO) as DialogueInfoBase
	ScriptServer.run_result_script(farewell.begin_script_source, EsmServer.find_reference_by_editor_id("DocMitchellREF"), ScriptServer.player_reference)
	check(not door.destroyed, "Doc's farewell INFO restores the door")
	check(_targets(ray) == node, "and the player can target it again")

	var bottle := _a_bottle()
	check(bottle != null, "a VCG02Bottle reference exists")
	if bottle != null:
		ScriptServer.dispatch_event(bottle, "OnLoad")
		check(bottle.destroyed, "a VCG02 bottle destroys itself OnLoad")
	_finish()


func _finish() -> void:
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)


## An InteractRay 1.2 m from the centre of `node`'s mesh, aimed through it
## along the horizontal axis on which it hits the node; null when neither does.
func _aim_ray_at(node: Node3D) -> InteractRay:
	var mesh_box := AABB()
	var first := true
	for mesh: MeshInstance3D in node.find_children("*", "MeshInstance3D", true, false):
		var box := mesh.global_transform * mesh.get_aabb()
		mesh_box = box if first else mesh_box.merge(box)
		first = false
	var centre := mesh_box.get_center()
	var ray := InteractRay.new()
	add_child(ray)
	for offset: Vector3 in [Vector3(1.2, 0, 0), Vector3(-1.2, 0, 0), Vector3(0, 0, 1.2), Vector3(0, 0, -1.2)]:
		ray.global_position = centre + offset
		ray.look_at(centre, Vector3.UP if absf(offset.y) < 1.0 else Vector3.RIGHT)
		ray.force_raycast_update()
		if ray.is_colliding() and InteractRay.semantic_target(ray.get_collider()) == node:
			return ray
	return null


func _targets(ray: InteractRay) -> Object:
	ray.force_raycast_update()
	ray._update_target()
	return ray.current_target


func _a_bottle() -> EsmReference:
	var marker: EsmReference = EsmServer.find_reference_by_editor_id("VCG02BottleMarkerREF")
	for reference in EsmServer.get_references_in_cell(marker.current_cell_form_id):
		if reference.base_form_id == 0x0010A1F6:
			return reference
	return null
