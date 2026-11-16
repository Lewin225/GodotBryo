extends Node3D

## A hit reaches the reference hit: ProjectileServer calls
## EsmReference.receive_hit(), which runs the reference's OnHit and OnHitWith
## blocks and emits its `hit` signal. VCG02's bottles (MISC VCG02Bottle,
## VCG02TargetSCRIPT) count a hit only while the player has a weapon out whose
## GetWeaponAnimType is 4 to 8 (the varmint rifle, Animation Type 5, reads 6);
## three bottles complete objective 10.

const BOTTLE_BASE := 0x0010A1F6
const RIFLE := "WeapNVVarmintRifle"

var failures := 0


func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1


func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var player := EsmServer.get_player_reference() as ActorReference
	ScriptServer.player_reference = player
	var vcg02: QuestBase = EsmServer.find_quest_by_editor_id("VCG02")
	QuestServer.start_quest(vcg02)
	var quest_script := ScriptServer.get_quest_instance(vcg02)
	var rifle := EsmServer.find_base_by_editor_id(RIFLE) as WeaponBase
	var bottles := _bottles()
	check(bottles.size() >= 4, "VCG02BottleMarkerREF's cell and its neighbours hold %d VCG02Bottle references" % bottles.size())
	if bottles.size() < 4:
		_finish()
		return

	ScriptServer.run_result_script("player.AddItem %s 1\nplayer.EquipItem %s" % [RIFLE, RIFLE], player)
	check(int(ScriptServer.run_result_script("player.GetWeaponAnimType", player)) == rifle.animation_type + 1,
			"GetWeaponAnimType is the varmint rifle's Animation Type + 1 (%s, type %d)" % [ScriptServer.run_result_script("player.GetWeaponAnimType", player), rifle.animation_type])
	check(int(ScriptServer.run_result_script("player.IsWeaponOut", player)) == 0, "IsWeaponOut is 0 while the rifle is holstered")

	var signalled: Array[EsmReference] = []
	bottles[0].hit.connect(func(shooter: EsmReference, _weapon: WeaponBase, _report: Dictionary) -> void: signalled.append(shooter))
	bottles[0].receive_hit(player, rifle, {})
	check(int(quest_script.get_local("nTargetCount")) == 0, "a hit with the rifle holstered does not count (nTargetCount %s)" % quest_script.get_local("nTargetCount"))
	check(signalled == [player], "and the bottle's hit signal names the player")

	player.draw_weapon()
	check(int(ScriptServer.run_result_script("player.IsWeaponOut", player)) == 1, "IsWeaponOut is 1 with the rifle drawn")
	bottles[1].receive_hit(player, rifle, {})
	bottles[1].receive_hit(player, rifle, {})
	check(int(quest_script.get_local("nTargetCount")) == 1, "a bottle hit twice with the rifle drawn counts once (nTargetCount %s)" % quest_script.get_local("nTargetCount"))
	bottles[2].receive_hit(player, rifle, {})
	check(not QuestServer.is_objective_completed(vcg02, 10), "two bottles do not complete objective 10")

	# A real shot: ProjectileServer finds the bottle through its node.
	# The bottles follow VCG02BottleMarkerREF, which the bottle line's begin
	# script enables; disabled, their collision is off.
	ScriptServer.run_result_script("VCG02BottleMarkerREF.Enable", player)
	var node := EsmNode.new()
	node.name = "Bottle"
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	body.add_child(shape)
	node.add_child(body)
	node.reference = bottles[3]
	add_child(node)
	node.global_position = Vector3(0, 0, -3)
	await get_tree().physics_frame
	var projectile := rifle.effective_projectile(null)
	ProjectileServer.fire(rifle, player, Transform3D(Basis.IDENTITY, Vector3.ZERO), projectile, null, 1)
	for frame in 4:
		await get_tree().physics_frame
	check(int(quest_script.get_local("nTargetCount")) == 3, "a varmint rifle shot at a third bottle counts it (nTargetCount %s)" % quest_script.get_local("nTargetCount"))
	check(QuestServer.is_objective_completed(vcg02, 10), "and completes objective 10")
	_finish()


## The VCG02Bottle references in VCG02BottleMarkerREF's grid cell and the
## eight around it.
func _bottles() -> Array[EsmReference]:
	var marker: EsmReference = EsmServer.find_reference_by_editor_id("VCG02BottleMarkerREF")
	var centre := EsmServer.exterior_grid_coord(marker.position)
	var result: Array[EsmReference] = []
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for reference in EsmServer.get_references_in_exterior_cell(marker.current_space_form_id, centre + Vector2i(dx, dy)):
				if reference.base_form_id == BOTTLE_BASE:
					result.append(reference)
	return result


func _finish() -> void:
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
