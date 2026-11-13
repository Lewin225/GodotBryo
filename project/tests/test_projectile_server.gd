extends Node3D

## ProjectileServer's hitscan path with a weapon node and no holder. The 10mm
## pistol's muzzle forward points out of the barrel; a shot fires along it and
## hits a wall in its range, not the shooter's own collision; the shotgun's 7
## pellets fan inside Min Spread and the same seed draws the same pellets; a
## target whose Health the shot's damage covers gets a lethal hit; past the
## PROJ's Range a ray misses.

const PISTOL := "Weap10mmPistol"
const SHOTGUN := "WeapNVHuntingShotgun"
const TARGET_NPC := "GSSunnySmiles"
const FRAMES := 900

var failures := 0


func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1


func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	await _check_muzzle_and_wall()
	_check_spread()
	await _check_lethal_and_range()
	await _check_throw_release("WeapGrenadeFrag")
	await _check_throw_release("WeapMineFrag")
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _check_muzzle_and_wall() -> void:
	var pistol := await _place(PISTOL)
	check(pistol.muzzle != null, "the pistol's model has its ProjectileNode muzzle")
	var model_centre := _model_centre(pistol)
	var forward := pistol.muzzle_forward()
	var offset := pistol.muzzle.global_position - model_centre
	check(offset.normalized().dot(forward) > 0.7,
			"the muzzle's +Y points out of the barrel (muzzle %.3f m from the model's centre, along forward %.2f)" % [offset.length(), offset.normalized().dot(forward)])
	var from := pistol.shot_transform(RandomNumberGenerator.new())
	var wall := _wall(from.origin - from.basis.z * 5.0, from.basis)
	var shooter_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = SphereShape3D.new()
	(shape.shape as SphereShape3D).radius = 1.0
	shooter_body.add_child(shape)
	pistol.add_child(shooter_body)
	shooter_body.global_position = from.origin
	await _physics()
	var hits: Array[Dictionary] = []
	var on_hit := func(_id: int, report: Dictionary) -> void: hits.append(report)
	ProjectileServer.hit.connect(on_hit)
	var created: Array[Dictionary] = []
	var on_created := func(shot: Dictionary) -> void: created.append(shot)
	ProjectileServer.shot_created.connect(on_created)
	var reference := pistol.get_weapon_reference()
	reference.loaded_ammo_count = 5
	check(pistol.fire(), "the pistol fires")
	var flash := pistol.shot_muzzle().get_node_or_null("MuzzleFlash") as ProjectileEffect
	check(flash != null and flash.global_basis.z.dot(-pistol.muzzle_forward()) > 0.99,
			"its muzzle flash hangs under its muzzle, facing along the muzzle's forward")
	await _physics()
	await _physics()
	ProjectileServer.hit.disconnect(on_hit)
	ProjectileServer.shot_created.disconnect(on_created)
	var shot: Dictionary = created[0] if not created.is_empty() else {}
	check(not shot.is_empty() and (shot["projectile"] as ProjectileBase).editor_id == "10mmBulletProjectile" and (shot["directions"] as PackedVector3Array).size() == 1,
			"shot_created carries the request: 10mmBulletProjectile, one direction")
	check(hits.size() == 1 and hits[0]["collider"] == wall, "its one ray hits the wall, not the shooter's own collision around the muzzle")
	if hits.size() == 1:
		var distance: float = (hits[0]["position"] as Vector3).distance_to(from.origin)
		check(absf(distance - 5.0) < 0.3, "at the wall's distance (%.2f m)" % distance)
		check(is_equal_approx(float(hits[0]["damage"]), float(pistol.get_weapon_base().base_damage)), "for the WEAP's Base Damage %d (Ammo10mm has no Damage Mod)" % pistol.get_weapon_base().base_damage)
	wall.queue_free()
	pistol.queue_free()


func _check_spread() -> void:
	var shotgun := EsmServer.find_base_by_editor_id(SHOTGUN) as WeaponBase
	var from := Transform3D(Basis.IDENTITY, Vector3.ZERO)
	var directions := ProjectileServer.projectile_directions(shotgun, null, from, 1234)
	var again := ProjectileServer.projectile_directions(shotgun, null, from, 1234)
	var other := ProjectileServer.projectile_directions(shotgun, null, from, 99)
	var widest := 0.0
	for direction in directions:
		widest = maxf(widest, rad_to_deg(direction.angle_to(Vector3.FORWARD)))
	check(directions.size() == 7, "the shotgun's shot fans into 7 pellets")
	check(widest <= shotgun.min_spread + 0.001 and widest > 0.0, "inside its Min Spread of %.2f degrees (widest %.2f)" % [shotgun.min_spread, widest])
	check(directions == again and directions != other, "the same seed draws the same pellets, another seed others")


func _check_lethal_and_range() -> void:
	var weapon := EsmServer.find_base_by_editor_id(PISTOL) as WeaponBase
	var projectile := weapon.effective_projectile(null)
	var npc := EsmServer.find_base_by_editor_id(TARGET_NPC)
	var target := EsmServer.create_reference_for_base(npc.form_id)
	var values := target.get_actor_values()
	check(values != null and values.get_current(ActorValue.HEALTH) > 0.0, "%s has Health %.0f" % [TARGET_NPC, values.get_current(ActorValue.HEALTH) if values != null else 0.0])
	var target_node := EsmNode.new()
	target_node.name = "Target"
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	body.add_child(shape)
	target_node.add_child(body)
	target_node.reference = target
	add_child(target_node)
	target_node.global_position = Vector3(0, 0, -3)
	await _physics()
	values.force(ActorValue.HEALTH, ProjectileServer.projectile_damage(weapon, null))
	var lethal: Array[EsmReference] = []
	var on_lethal := func(_id: int, who: EsmReference) -> void: lethal.append(who)
	ProjectileServer.lethal_hit.connect(on_lethal)
	var hits: Array[Dictionary] = []
	var on_hit := func(_id: int, report: Dictionary) -> void: hits.append(report)
	ProjectileServer.hit.connect(on_hit)
	ProjectileServer.fire(weapon, null, Transform3D(Basis.IDENTITY, Vector3.ZERO), projectile, null, 1)
	await _physics()
	await _physics()
	check(hits.size() == 1 and hits[0]["target"] == target, "a shot hitting the target's collision reports its reference")
	check(lethal == [target], "Health at the shot's damage: a lethal hit")
	values.force(ActorValue.HEALTH, 1000.0)
	lethal.clear()
	ProjectileServer.fire(weapon, null, Transform3D(Basis.IDENTITY, Vector3.ZERO), projectile, null, 1)
	await _physics()
	await _physics()
	check(lethal.is_empty(), "Health above it: no lethal hit")
	target_node.global_position = Vector3(0, 0, -(projectile.projectile_range / ProjectileServer.UNITS_PER_METRE) - 2.0)
	await _physics()
	hits.clear()
	var ends: Array[PackedVector3Array] = []
	var on_resolved := func(_id: int, points: PackedVector3Array) -> void: ends.append(points)
	ProjectileServer.shot_resolved.connect(on_resolved)
	ProjectileServer.fire(weapon, null, Transform3D(Basis.IDENTITY, Vector3.ZERO), projectile, null, 1)
	await _physics()
	await _physics()
	check(hits.is_empty(), "past the PROJ's Range of %.0f units the ray misses" % projectile.projectile_range)
	check(ends.size() == 1 and absf(ends[0][0].length() - projectile.projectile_range / ProjectileServer.UNITS_PER_METRE) < 0.01, "and ends at the range")
	ProjectileServer.lethal_hit.disconnect(on_lethal)
	ProjectileServer.hit.disconnect(on_hit)
	ProjectileServer.shot_resolved.disconnect(on_resolved)


func _check_throw_release(editor_id: String) -> void:
	var grenade := await _place(editor_id)
	var base := grenade.get_weapon_base()
	var path := base.attack_clip_path()
	NifServer.request_kf(path, grenade, grenade._on_clip_delivered.bind(-1, path))
	for frame in FRAMES:
		if grenade._clips.has(path):
			break
		await get_tree().process_frame
	var shots: Array[int] = []
	var on_fired := func(shot_id: int) -> void: shots.append(shot_id)
	grenade.fired.connect(on_fired)
	var started := Time.get_ticks_msec()
	check(grenade.throws_at_release() and grenade.fire(), "%s starts its throw" % editor_id)
	await _physics()
	check(shots.is_empty(), "no shot before its attack clip's Release key")
	for frame in FRAMES:
		if not shots.is_empty():
			break
		await get_tree().process_frame
	var seconds := (Time.get_ticks_msec() - started) / 1000.0
	check(shots.size() == 1 and shots[0] != 0 and seconds > 0.6, "the shot goes at Release (%.2f s into %s)" % [seconds, path.get_file()])
	grenade.fired.disconnect(on_fired)
	grenade.queue_free()


func _wall(centre: Vector3, facing: Basis) -> StaticBody3D:
	var wall := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	(shape.shape as BoxShape3D).size = Vector3(4, 4, 0.2)
	wall.add_child(shape)
	add_child(wall)
	wall.global_transform = Transform3D(facing, centre)
	return wall


func _model_centre(node: Node3D) -> Vector3:
	var box := AABB()
	var first := true
	for mesh: MeshInstance3D in node.find_children("*", "MeshInstance3D", true, false):
		var world := mesh.global_transform * mesh.get_aabb()
		box = world if first else box.merge(world)
		first = false
	return box.get_center()


func _place(editor_id: String) -> EsmWeaponNode:
	var base := EsmServer.find_base_by_editor_id(editor_id) as WeaponBase
	var reference := EsmServer.create_runtime_reference(base.form_id) as WeaponReference
	var node := EsmReferencePhysicaliser.new().physicalise(reference, self) as EsmWeaponNode
	for frame in FRAMES:
		if node.muzzle != null:
			break
		await get_tree().process_frame
	return node


func _physics() -> void:
	await get_tree().physics_frame
