extends Node3D

## What a hitscan shot leaves, and its other callers. A 10mm pistol shot into
## a wall logs its hit by the shooter's and weapon's names and shows the
## weapon's Stone impact (INAM) where it hits; its muzzle flash (NAM1, with its
## light) is shown by the caller, under the parent it gives; a laser (Beam, not hitscan) resolves as a ray with its beam shown;
## script FireWeapon fires from the calling reference's node; the kill-cam
## projectile flies the PROJ's model from the muzzle to the hit; and a PROJ
## placed from a base is a ProjectileReference shown by an EsmProjectileNode.

const FRAMES := 900

var failures := 0


func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1


func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	_wall(Vector3(0, 0, -6))
	await _physics()
	await _check_hit_effects()
	await _check_laser()
	await _check_fire_weapon()
	await _check_kill_cam_projectile()
	await _check_placed_projectile()
	await _check_effect_sequence()
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _check_hit_effects() -> void:
	var weapon := _weapon("Weap10mmPistol")
	var projectile := weapon.effective_projectile(null)
	var log_before := ProjectileServer.damage_log.size()
	var shooter := EsmServer.create_reference_for_base(EsmServer.find_base_by_editor_id("GSSunnySmiles").form_id)
	ProjectileServer.fire(weapon, shooter, Transform3D.IDENTITY, projectile, weapon.default_ammo(), 3)
	check(ProjectileServer.get_node_or_null("MuzzleFlash") == null, "fire() shows no muzzle flash: it is the caller's")
	var holder := Node3D.new()
	add_child(holder)
	var flash := ProjectileServer.show_muzzle_flash(projectile, Transform3D.IDENTITY, holder)
	check(flash != null and flash.get_parent() == holder and flash.get_node_or_null("Light") != null,
			"show_muzzle_flash() shows it under the given parent with its Muzzle Flash Light")
	await _physics()
	await _physics()
	var line := ProjectileServer.damage_log[-1] if ProjectileServer.damage_log.size() > log_before else ""
	check(line.begins_with(ProjectileServer.display_name(shooter) + " hit") and line.contains(ProjectileServer.display_name(weapon)) and line.contains("for %d" % weapon.base_damage),
			"the damage log has the hit: \"%s\"" % line)
	var impact := ProjectileServer.get_node_or_null("Impact") as ProjectileEffect
	var dataset := EsmServer.get_base(weapon.impact_dataset_form_id) as ImpactDatasetBase
	var stone := dataset.impact_for(ImpactDatasetBase.MATERIAL_STONE)
	check(impact != null and absf(impact.global_position.z + 5.9) < 0.2, "an impact where it hit the wall (%s)" % (str(impact.global_position) if impact != null else "none"))
	await _until(func() -> bool: return impact == null or not is_instance_valid(impact) or _has_mesh(impact))
	check(impact != null and is_instance_valid(impact) and _has_mesh(impact), "showing %s's model %s" % [stone.editor_id, stone.model_path])
	await _until(func() -> bool: return flash == null or not is_instance_valid(flash))
	check(flash == null or not is_instance_valid(flash), "the muzzle flash is gone after its %.2f s" % projectile.muzzle_flash_duration)


func _check_laser() -> void:
	var weapon := _weapon("WeapLaserPistol")
	var projectile := weapon.effective_projectile(weapon.default_ammo())
	check(projectile.projectile_type == ProjectileBase.TYPE_BEAM and not projectile.is_hitscan() and ProjectileServer.resolves_as_ray(projectile),
			"the laser's %s is a Beam, not hitscan, resolved as a ray" % projectile.editor_id)
	var hits: Array[Dictionary] = []
	var on_hit := func(_id: int, report: Dictionary) -> void: hits.append(report)
	ProjectileServer.hit.connect(on_hit)
	ProjectileServer.fire(weapon, null, Transform3D.IDENTITY, projectile, null, 1)
	await _physics()
	await _physics()
	ProjectileServer.hit.disconnect(on_hit)
	check(hits.size() == 1, "it hits the wall in its tick")
	check(ProjectileServer.get_node_or_null("Tracer") != null, "its beam is shown")


func _check_fire_weapon() -> void:
	var marker_base := EsmServer.find_base_by_editor_id("XMarkerHeading")
	var marker := EsmServer.create_runtime_reference(marker_base.form_id)
	var node := EsmNode.new()
	node.reference = marker
	add_child(node)
	var hits: Array[Dictionary] = []
	var on_hit := func(_id: int, report: Dictionary) -> void: hits.append(report)
	ProjectileServer.hit.connect(on_hit)
	var shot_id: Variant = ScriptServer.run_debug_line("FireWeapon Weap10mmPistol", marker)
	await _physics()
	await _physics()
	ProjectileServer.hit.disconnect(on_hit)
	check(hits.size() == 1 and absf((hits[0]["position"] as Vector3).z + 5.9) < 0.2,
			"`FireWeapon Weap10mmPistol` on a marker fires along its -Z into the wall (%s)" % str(shot_id))
	node.queue_free()


func _check_kill_cam_projectile() -> void:
	var weapon := _weapon("WeapHuntingRifle")
	var projectile := weapon.effective_projectile(weapon.default_ammo())
	var shot_id := ProjectileServer.fire(weapon, null, Transform3D.IDENTITY, projectile, null, 2)
	await _physics()
	await _physics()
	var flying := ProjectileServer.spawn_shot_projectile(shot_id)
	check(flying != null, "the resolved shot spawns its kill-cam projectile")
	if flying == null:
		return
	var arrived := {"done": false}
	flying.arrived.connect(func() -> void: arrived["done"] = true)
	var started := Time.get_ticks_msec()
	await _until(func() -> bool: return arrived["done"])
	var seconds := (Time.get_ticks_msec() - started) / 1000.0
	var expected := 5.9 / (projectile.speed / ProjectileServer.UNITS_PER_METRE)
	check(arrived["done"], "it flies %s's model to the hit and arrives (%.3f s; %.3f s at %.0f units/s)" % [projectile.editor_id, seconds, expected, projectile.speed])


func _check_placed_projectile() -> void:
	var base := EsmServer.find_base_by_editor_id("MissileProjectile") as ProjectileBase
	var reference := EsmServer.create_reference_for_base(base.form_id)
	check(reference is ProjectileReference, "a reference to a PROJ is a ProjectileReference")
	var node := EsmReferencePhysicaliser.new().physicalise(reference, self) as EsmProjectileNode
	check(node != null and node.get_projectile_base() == base, "the physicaliser builds an EsmProjectileNode for it")
	await _until(func() -> bool: return node != null and _has_mesh(node))
	check(node != null and _has_mesh(node), "showing its model %s" % base.model_path)


func _weapon(editor_id: String) -> WeaponBase:
	return EsmServer.find_base_by_editor_id(editor_id) as WeaponBase


func _wall(centre: Vector3) -> void:
	var wall := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	(shape.shape as BoxShape3D).size = Vector3(6, 6, 0.2)
	wall.add_child(shape)
	add_child(wall)
	wall.global_position = centre


## The Fat Man explosion's model (ExplosionLarge01) has one sequence,
## SpecialIdle_AreaEffect, and plays it once shown.
func _check_effect_sequence() -> void:
	var effect := ProjectileEffect.new()
	effect.lifetime = 5.0
	add_child(effect)
	effect.show_model("Effects\\ExplosionLarge01.NIF")
	await _until(func() -> bool: return _has_mesh(effect))
	var player := effect.find_child("AnimationPlayer", true, false) as AnimationPlayer
	check(player != null and player.is_playing() and String(player.current_animation) == NifNames.escape("SpecialIdle_AreaEffect"),
			"an effect plays its model's only sequence (%s)" % (String(player.current_animation) if player != null else "no player"))
	effect.queue_free()


func _has_mesh(node: Node) -> bool:
	return not node.find_children("*", "MeshInstance3D", true, false).is_empty()


func _until(condition: Callable) -> void:
	for frame in FRAMES:
		if condition.call():
			return
		await get_tree().process_frame


func _physics() -> void:
	await get_tree().physics_frame
