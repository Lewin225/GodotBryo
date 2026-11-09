extends Node

## PROJ, AMMO, AMEF and EXPL as EsmServer reads them, and the projectile a
## weapon fires: the WEAP's DNAM Projectile and Projectile Count, each
## overridden by the loaded ammo's DAT2 when it names one.

var failures := 0


func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1


func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	_check_bullet()
	_check_ammo_overrides()
	_check_explosive()
	_check_ammo_effects()
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _base(editor_id: String) -> EsmBase:
	return EsmServer.find_base_by_editor_id(editor_id)


func _check_bullet() -> void:
	var pistol := _base("Weap10mmPistol") as WeaponBase
	var ammo := pistol.default_ammo()
	var projectile := pistol.effective_projectile(ammo)
	check(ammo != null and ammo.editor_id == "Ammo10mm", "the 10mm pistol's default ammo is Ammo10mm (%s)" % (ammo.editor_id if ammo != null else "none"))
	check(projectile != null and projectile.editor_id == "10mmBulletProjectile", "it fires 10mmBulletProjectile")
	check(projectile.is_hitscan() and projectile.projectile_type == ProjectileBase.TYPE_MISSILE, "a hitscan Missile")
	check(is_equal_approx(projectile.speed, 27520.0) and is_equal_approx(projectile.projectile_range, 10000.0), "speed 27520, range 10000")
	check(projectile.muzzle_flash_model_path.to_lower().ends_with("handgunmuzzleflash01.nif"), "muzzle flash %s" % projectile.muzzle_flash_model_path)
	check(pistol.effective_projectile_count(ammo) == 1, "one projectile per shot")
	check(pistol.impact_dataset_form_id != 0, "the weapon names an impact dataset (INAM)")


func _check_ammo_overrides() -> void:
	var shotgun := _base("WeapNVHuntingShotgunUnique") as WeaponBase
	check(shotgun.effective_projectile(null).editor_id == "BuckshotProjectile" and shotgun.effective_projectile_count(null) == 7,
			"with no ammo override the shotgun fires 7 BuckshotProjectile")
	var slug := _base("Ammo12GaSlug") as AmmoBase
	check(shotgun.effective_projectile(slug).editor_id == "12GaSlugProjectile" and shotgun.effective_projectile_count(slug) == 1,
			"slugs override both: one 12GaSlugProjectile")
	var coin := _base("Ammo12GaCoinShot") as AmmoBase
	check(shotgun.effective_projectile_count(coin) == 8, "coin shot fires 8 (Proj. per Shot)")
	check(shotgun.min_spread > 0.0 and is_zero_approx(shotgun.spread), "a shotgun's spread is Min Spread %.2f, Spread 0" % shotgun.min_spread)


func _check_explosive() -> void:
	var launcher := _base("WeapMissileLauncher") as WeaponBase
	var missile := launcher.effective_projectile(launcher.default_ammo())
	check(missile != null and not missile.is_hitscan() and missile.explodes(), "the missile is not hitscan and explodes")
	var explosion := missile.explosion
	check(explosion != null and explosion.editor_id == "MissileExplosion" and is_equal_approx(explosion.damage, 200.0) and is_equal_approx(explosion.radius, 1000.0),
			"MissileExplosion: damage 200, radius 1000")
	var hatchet := _base("WeapNVThrowingHatchet") as WeaponBase
	var thrown := hatchet.effective_projectile(null)
	check(hatchet.default_ammo() == null and thrown.explosion != null and not thrown.explodes(),
			"the hatchet has no ammo; its PROJ names an explosion but the Explosion flag is clear")
	var grenade := (_base("WeapGrenadeFrag") as WeaponBase).effective_projectile(null)
	check(grenade.projectile_type == ProjectileBase.TYPE_LOBBER and is_equal_approx(grenade.alt_trigger_timer, 2.5) and is_equal_approx(grenade.gravity, 1.0),
			"the frag grenade is a Lobber with a 2.5 s fuse and gravity 1")
	var short := _base("BBProjectile") as ProjectileBase
	check(short != null and short.rotation == Vector3.ZERO and is_zero_approx(short.bouncy_mult), "a 68-byte DATA leaves Rotation and Bouncy Mult at 0")


func _check_ammo_effects() -> void:
	var found := false
	for editor_id in ["Ammo10mmJHP", "Ammo308JSP", "Ammo556mmHollowPoint"]:
		var ammo := _base(editor_id) as AmmoBase
		if ammo == null or ammo.effects.is_empty():
			continue
		found = true
		var names: Array[String] = []
		for effect in ammo.effects:
			names.append("%s %d/%d %.2f" % [effect.editor_id, effect.effect_type, effect.operation, effect.value])
		check(true, "%s carries %s" % [editor_id, ", ".join(names)])
	check(found, "a hollow-point ammo carries ammo effects (RCIL)")
	var multiply := AmmoEffectBase.new()
	multiply.operation = AmmoEffectBase.OPERATION_MULTIPLY
	multiply.value = 1.5
	check(is_equal_approx(multiply.apply(10.0), 15.0), "a Multiply effect of 1.5 makes 10 damage 15")
