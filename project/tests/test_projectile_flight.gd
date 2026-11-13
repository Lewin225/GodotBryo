extends Node3D

## ProjectileServer's moving projectiles, with no streamers: a missile flies
## its closed-form segment and explodes on the wall it strikes, damaging an
## actor in its radius; a frag grenade bounces, comes to rest and goes off when
## its 2.5 s fuse runs out; a frag mine lands, arms when its fuse runs out and
## goes off when an actor comes within its proximity; a plasma bolt hits for
## its weapon's damage and ends; a throwing knife lies where it hit and is
## picked up; C4 waits for its detonator; a hitscan shot sets off a grenade;
## a projectile in a space that is not loaded is removed; and a projectile in
## flight survives EsmServer's save and load from where it was.

const FRAMES := 1200

var failures := 0
var _actor: EsmReference
var _actor_node: EsmNode


func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1


func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	ProjectileServer.show_effects = false
	ProjectileServer.debug_shot_lines = false
	_box(Vector3(0, -0.5, 0), Vector3(200, 1, 200))
	_box(Vector3(0, 2, -12), Vector3(20, 6, 0.4))
	_actor = EsmServer.create_reference_for_base(EsmServer.find_base_by_editor_id("GSSunnySmiles").form_id)
	_actor_node = _actor_body(_actor, Vector3(3, 1, -10))
	await _physics()
	await _check_missile()
	await _check_grenade()
	await _check_mine()
	await _check_plasma()
	await _check_knife()
	await _check_c4()
	await _check_disarm()
	await _check_gravityless_mine()
	await _check_shooting()
	await _check_space()
	await _check_save()
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _check_missile() -> void:
	var weapon := _weapon("WeapMissileLauncher")
	var projectile := weapon.effective_projectile(weapon.default_ammo())
	var exploded: Array = []
	var on_exploded := func(_id: int, explosion: ExplosionBase, point: Vector3) -> void: exploded.append([explosion, point])
	ProjectileServer.exploded.connect(on_exploded)
	var hits: Array[Dictionary] = []
	var on_hit := func(_id: int, report: Dictionary) -> void: hits.append(report)
	ProjectileServer.hit.connect(on_hit)
	ProjectileServer.fire(weapon, null, Transform3D(Basis.IDENTITY, Vector3(0, 1, 0)), projectile, null, 1)
	await _physics()
	var flying := _latest()
	check(flying != null and flying.get_projectile_base() == projectile and not flying.at_rest, "the missile launches as a ProjectileReference")
	await _physics()
	await _physics()
	if flying != null:
		var expected := flying.segment_origin + flying.segment_velocity * flying.segment_time
		check(ProjectileServer.segment_point(flying, flying.segment_time).distance_to(expected) < 0.001,
				"its point is origin + velocity × t (Gravity %.1f)" % projectile.gravity)
		var authored := EsmReferencePhysicaliser.authored_position(ProjectileServer.segment_point(flying, flying.segment_time))
		check(flying.position.distance_to(authored) < 0.01, "its reference's position follows its flight")
	await _until(func() -> bool: return not exploded.is_empty())
	ProjectileServer.exploded.disconnect(on_exploded)
	ProjectileServer.hit.disconnect(on_hit)
	check(not exploded.is_empty() and exploded[0][0] == projectile.explosion and absf((exploded[0][1] as Vector3).z + 11.8) < 0.3,
			"it explodes (%s) on the wall it strikes" % projectile.explosion.editor_id)
	var damaged := hits.filter(func(report: Dictionary) -> bool: return report["target"] == _actor and report.has("explosion"))
	check(damaged.size() == 1 and float(damaged[0]["damage"]) > 0.0 and float(damaged[0]["damage"]) < projectile.explosion.damage,
			"an actor 3 m off takes part of its %.0f damage (%.1f)" % [projectile.explosion.damage, float(damaged[0]["damage"]) if not damaged.is_empty() else 0.0])
	check(flying != null and not ProjectileServer.get_projectiles().has(flying) and EsmServer.get_reference(flying.instance_id) == null,
			"and it ends: released from EsmServer's runtime table")


func _check_grenade() -> void:
	var weapon := _weapon("WeapGrenadeFrag")
	var projectile := weapon.effective_projectile(null)
	var throw := Transform3D(Basis(Vector3.RIGHT, -0.4), Vector3(-5, 1.5, 0))
	var started := Time.get_ticks_msec()
	ProjectileServer.fire(weapon, null, throw, projectile, null, 1)
	await _physics()
	var grenade := _latest()
	var exploded := {"at": 0}
	var on_exploded := func(_id: int, _explosion: ExplosionBase, _point: Vector3) -> void: exploded["at"] = Time.get_ticks_msec()
	ProjectileServer.exploded.connect(on_exploded)
	var bounced := {"done": false}
	await _until(func() -> bool:
		if grenade.segment_origin.y < 0.2 and grenade.segment_time < 0.05 and not grenade.at_rest:
			bounced["done"] = true
		return grenade.at_rest or exploded["at"] != 0)
	check(bounced["done"], "the grenade (a Lobber, Bouncy Mult %.2f) bounces off the floor" % projectile.bouncy_mult)
	check(grenade.at_rest and exploded["at"] == 0, "and comes to rest before its fuse runs out")
	await _until(func() -> bool: return exploded["at"] != 0)
	ProjectileServer.exploded.disconnect(on_exploded)
	var seconds := (int(exploded["at"]) - started) / 1000.0
	check(exploded["at"] != 0 and absf(seconds - projectile.alt_trigger_timer) < 0.3,
			"it goes off %.2f s after the throw (Alt. Trigger Timer %.1f s)" % [seconds, projectile.alt_trigger_timer])


func _check_mine() -> void:
	var weapon := _weapon("WeapMineFrag")
	var projectile := weapon.effective_projectile(null)
	_actor_node.global_position = Vector3(30, 1, 30)
	await _physics()
	ProjectileServer.fire(weapon, null, Transform3D(Basis(Vector3.RIGHT, -PI / 2.0), Vector3(10, 0.5, 0)), projectile, null, 1)
	await _physics()
	var mine := _latest()
	await _until(func() -> bool: return mine.at_rest)
	check(mine.at_rest and not mine.armed and mine.fuse_left > 0.0, "the frag mine lands and starts its %.1f s arming fuse" % projectile.alt_trigger_timer)
	await _until(func() -> bool: return mine.armed)
	check(mine.armed and ProjectileServer.get_projectiles().has(mine), "it arms and waits")
	var exploded := {"done": false}
	var on_exploded := func(_id: int, _explosion: ExplosionBase, _point: Vector3) -> void: exploded["done"] = true
	ProjectileServer.exploded.connect(on_exploded)
	_actor_node.global_position = Vector3(10, 1, 0.5)
	await _until(func() -> bool: return exploded["done"])
	ProjectileServer.exploded.disconnect(on_exploded)
	check(exploded["done"], "an actor within its %.0f units sets it off" % projectile.alt_trigger_proximity)
	_actor_node.global_position = Vector3(3, 1, -10)
	await _physics()


func _check_plasma() -> void:
	var weapon := _weapon("WeapPlasmaRifle")
	var projectile := weapon.effective_projectile(weapon.default_ammo())
	var hits: Array[Dictionary] = []
	var on_hit := func(_id: int, report: Dictionary) -> void: hits.append(report)
	ProjectileServer.hit.connect(on_hit)
	var ended: Array = []
	var on_ended := func(reference: ProjectileReference, reason: String) -> void: ended.append([reference, reason])
	ProjectileServer.projectile_ended.connect(on_ended)
	var aim := Transform3D(Basis.looking_at(Vector3(3, 1, -10) - Vector3(0, 1, 0)), Vector3(0, 1, 0))
	ProjectileServer.fire(weapon, null, aim, projectile, null, 1)
	await _until(func() -> bool: return not ended.is_empty())
	ProjectileServer.hit.disconnect(on_hit)
	ProjectileServer.projectile_ended.disconnect(on_ended)
	check(not projectile.is_hitscan() and not projectile.explodes(), "%s is a moving Missile with no explosion" % projectile.editor_id)
	check(hits.size() == 1 and hits[0]["target"] == _actor and is_equal_approx(float(hits[0]["damage"]), float(weapon.base_damage)),
			"it hits the actor for the weapon's Base Damage %d" % weapon.base_damage)
	check(not ended.is_empty() and ended[0][1] == "hit", "and ends there")


func _check_knife() -> void:
	var weapon := _weapon("WeapNVThrowingKnife")
	var projectile := weapon.effective_projectile(null)
	ProjectileServer.fire(weapon, null, Transform3D(Basis.IDENTITY, Vector3(-3, 1, 0)), projectile, null, 1)
	await _physics()
	var knife := _latest()
	await _until(func() -> bool: return knife.at_rest or not ProjectileServer.get_projectiles().has(knife))
	check(knife.at_rest and ProjectileServer.get_projectiles().has(knife), "the throwing knife (Can Be Picked Up) lies where it struck the wall")
	var inventory := _actor.get("contents") as Inventory
	var before := inventory.get_item_count(weapon.form_id) if inventory != null else -1
	check(ProjectileServer.pick_up(knife, _actor), "it can be picked up")
	check(inventory != null and inventory.get_item_count(weapon.form_id) == before + 1, "into the actor's inventory as one %s" % weapon.editor_id)


func _check_c4() -> void:
	var weapon := _weapon("WeapNVC4PlasticExplosive")
	var projectile := weapon.effective_projectile(null)
	ProjectileServer.fire(weapon, _actor, Transform3D(Basis(Vector3.RIGHT, -PI / 2.0), Vector3(-10, 0.5, 5)), projectile, null, 1)
	await _physics()
	var charge := _latest()
	await _until(func() -> bool: return charge.at_rest)
	await _frames(30)
	check(charge.at_rest and ProjectileServer.get_projectiles().has(charge), "C4 (Detonates) lands and waits")
	check(ProjectileServer.detonate_placed(_actor) == 1 and not ProjectileServer.get_projectiles().has(charge), "its shooter's detonator sets it off")
	var detonator := _weapon("WeapNVDetonator")
	check(detonator != null and detonator.projectile_count == 0 and detonator.effective_projectile(null) == null, "the detonator has Projectile Count 0 and no PROJ")


func _check_disarm() -> void:
	var weapon := _weapon("WeapMineFrag")
	var projectile := weapon.effective_projectile(null)
	_actor_node.global_position = Vector3(30, 1, 30)
	await _physics()
	ProjectileServer.fire(weapon, null, Transform3D(Basis(Vector3.RIGHT, -PI / 2.0), Vector3(12, 0.5, 8)), projectile, null, 1)
	await _physics()
	var mine := _latest()
	await _until(func() -> bool: return mine.armed)
	var inventory := _actor.get("contents") as Inventory
	var before := inventory.get_item_count(weapon.form_id)
	ScriptServer.activate(mine, _actor)
	check(mine.disarmed and not mine.armed and ProjectileServer.get_projectiles().has(mine), "activating an armed mine (Can Be Disabled) disarms it")
	ScriptServer.activate(mine, _actor)
	check(not ProjectileServer.get_projectiles().has(mine) and inventory.get_item_count(weapon.form_id) == before + 1, "activating it again picks it up")
	_actor_node.global_position = Vector3(3, 1, -10)
	await _physics()


func _check_gravityless_mine() -> void:
	var weapon := _weapon("WeapMinePlasma")
	var projectile := weapon.effective_projectile(null)
	ProjectileServer.fire(weapon, null, Transform3D(Basis.IDENTITY, Vector3(15, 1, 10)), projectile, null, 1)
	await _physics()
	var mine := _latest()
	await _until(func() -> bool: return mine.at_rest or not ProjectileServer.get_projectiles().has(mine))
	check(is_zero_approx(projectile.gravity) and mine.at_rest, "a plasma mine (Gravity 0) dropped level still falls and lands")
	ProjectileServer.end_projectile(mine, "removed")


func _check_shooting() -> void:
	var weapon := _weapon("WeapGrenadeFrag")
	var projectile := weapon.effective_projectile(null)
	ProjectileServer.fire(weapon, null, Transform3D(Basis(Vector3.RIGHT, -PI / 2.0), Vector3(-8, 0.4, -5)), projectile, null, 1)
	await _physics()
	var grenade := _latest()
	await _until(func() -> bool: return grenade.at_rest)
	var node := EsmReferencePhysicaliser.new().physicalise(grenade, self) as EsmProjectileNode
	await _frames(3)
	check(node != null and node.get_node_or_null("Shootable") != null, "a resting grenade's node carries its shootable area")
	var exploded := {"done": false}
	var on_exploded := func(_id: int, _explosion: ExplosionBase, _point: Vector3) -> void: exploded["done"] = true
	ProjectileServer.exploded.connect(on_exploded)
	var at := ProjectileServer.segment_point(grenade, grenade.segment_time)
	var pistol := _weapon("Weap10mmPistol")
	var aim := Transform3D(Basis.looking_at(at - Vector3(-8, 1.5, -1)), Vector3(-8, 1.5, -1))
	ProjectileServer.fire(pistol, null, aim, pistol.effective_projectile(null), null, 1)
	await _physics()
	await _physics()
	ProjectileServer.exploded.disconnect(on_exploded)
	check(exploded["done"] and not ProjectileServer.get_projectiles().has(grenade), "a pistol shot sets it off at once")


func _check_space() -> void:
	var weapon := _weapon("WeapMissileLauncher")
	var player := EsmServer.create_reference_for_base(EsmServer.find_base_by_editor_id("GSSunnySmiles").form_id)
	var saved_player: EsmReference = ScriptServer.player_reference
	ScriptServer.player_reference = player
	player.current_space_form_id = 1
	var shooter := EsmServer.create_reference_for_base(EsmServer.find_base_by_editor_id("GSSunnySmiles").form_id)
	shooter.current_space_form_id = 1
	ProjectileServer.fire(weapon, shooter, Transform3D(Basis(Vector3.RIGHT, PI / 2.0), Vector3(0, 1, 0)), weapon.effective_projectile(null), null, 1)
	await _physics()
	var missile := _latest()
	var ended: Array = []
	var on_ended := func(reference: ProjectileReference, reason: String) -> void: ended.append([reference, reason])
	ProjectileServer.projectile_ended.connect(on_ended)
	await _physics()
	check(ProjectileServer.get_projectiles().has(missile), "a missile in the loaded space flies")
	player.current_space_form_id = 2
	await _physics()
	await _physics()
	ProjectileServer.projectile_ended.disconnect(on_ended)
	check(not ended.is_empty() and ended[0][1] == "space_unloaded", "when the player's space changes it is removed")
	ScriptServer.player_reference = saved_player


func _check_save() -> void:
	var weapon := _weapon("WeapMissileLauncher")
	ProjectileServer.fire(weapon, _actor, Transform3D(Basis(Vector3.RIGHT, PI / 2.0), Vector3(0, 1, 0)), weapon.effective_projectile(null), null, 1)
	await _physics()
	await _physics()
	var missile := _latest()
	var state := EsmServer.save_state()
	var projectile_state := ProjectileServer.save_state()
	var id := missile.instance_id
	var origin := missile.segment_origin
	var velocity := missile.segment_velocity
	var time := missile.segment_time
	EsmServer.clear_game_state()
	EsmServer.load_state(state)
	ProjectileServer.load_state(projectile_state)
	var loaded := EsmServer.get_reference(id) as ProjectileReference
	check(loaded != null and loaded != missile, "the missile in flight is rebuilt from the save as %s" % id)
	check(loaded != null and loaded.segment_origin.is_equal_approx(origin) and loaded.segment_velocity.is_equal_approx(velocity) and absf(loaded.segment_time - time) < 0.001,
			"with its segment: origin, velocity and time into it")
	check(loaded != null and loaded.weapon == weapon and ProjectileServer.get_projectiles().has(loaded), "its weapon, and ProjectileServer steps it again")
	if loaded != null:
		await _physics()
		await _physics()
		check(loaded.segment_time > time, "it flies on from where it was saved")
		ProjectileServer.end_projectile(loaded, "removed")


func _latest() -> ProjectileReference:
	var all := ProjectileServer.get_projectiles()
	return all[-1] if not all.is_empty() else null


func _weapon(editor_id: String) -> WeaponBase:
	return EsmServer.find_base_by_editor_id(editor_id) as WeaponBase


func _box(centre: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	(shape.shape as BoxShape3D).size = size
	body.add_child(shape)
	add_child(body)
	body.global_position = centre


func _actor_body(reference: EsmReference, at: Vector3) -> EsmNode:
	var node := EsmNode.new()
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = CapsuleShape3D.new()
	body.add_child(shape)
	node.add_child(body)
	node.reference = reference
	add_child(node)
	node.global_position = at
	return node


func _until(condition: Callable) -> void:
	for frame in FRAMES:
		if condition.call():
			return
		await get_tree().physics_frame


func _frames(count: int) -> void:
	for frame in count:
		await get_tree().physics_frame


func _physics() -> void:
	await get_tree().physics_frame
