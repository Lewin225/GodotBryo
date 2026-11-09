extends Node

## Fires shots: the one entry point that creates projectiles and casts hits.
## A weapon node, script `FireWeapon` and NPC combat call fire(); nothing else
## creates projectiles. Runs on the physics tick in the loaded space. Contract
## and rules: README.md. Plan: Plans/Weapons/projectiles.md.

## A shot was fired: its id and request, for a client's ProjectileServer to
## replay with the same seed (no hits).
signal shot_created(shot: Dictionary)
## A shot's projectile hit something. `hit`: shot_id, position, normal (Godot
## world), collider, target (the EsmReference hit, or null), damage.
signal hit(shot_id: int, hit: Dictionary)
## The damage `shot_id` deals `target` would kill it: emitted once per target
## per shot, before anything shows. The kill cam listens.
signal lethal_hit(shot_id: int, target: EsmReference)
## A moving projectile was launched (fired, or spawned by a placed charge).
signal projectile_launched(projectile: ProjectileReference)
## A projectile's explosion went off at `position` (Godot world).
signal exploded(shot_id: int, explosion: ExplosionBase, position: Vector3)
## A moving projectile ended and was released: "exploded", "range",
## "space_unloaded", "hit", "picked_up" or "removed".
signal projectile_ended(projectile: ProjectileReference, reason: String)
## A hitscan shot resolved: every projectile's ray cast. `ends`: each ray's end
## point (its hit, or its full range), Godot world.
signal shot_resolved(shot_id: int, ends: PackedVector3Array)

## Game units per metre (native/src/common/units.h).
const UNITS_PER_METRE := 70.0
## A muzzle flash model's turn inside its effect: the flash is authored along
## the ProjectileNode's +X, so its +X goes to the effect's -Z (the shot's
## direction). The weapon models cannot change, so the turn is made here.
const MUZZLE_FLASH_TURN := Basis(Vector3.UP, PI / 2.0)
## A muzzle flash light's radius and energy against its LIGH's, also used by
## the copy a projectile carries in flight: set by eye.
const FLASH_LIGHT_RADIUS_SCALE := 2.0
const FLASH_LIGHT_ENERGY_SCALE := 1.5
## The physics layer of a projectile's shootable area (EsmProjectileNode):
## layer 20. Hitscan rays look for it in a second cast that sees only areas.
const PROJECTILE_LAYER := 1 << 19
## Seconds a projectile does not hit its shooter, so it clears the shooter's
## own body. `# ASSUMPTION`
const SHOOTER_GRACE_SECONDS := 0.5
## Below this speed (metres per second) a bounce comes to rest.
const REST_SPEED := 1.0
## A bounce keeps this share of its speed into the surface, times the PROJ's
## Bouncy Mult (1 on the frag grenade, which would otherwise never settle),
## and this share along it. `# ASSUMPTION` both.
const BOUNCE_RESTITUTION := 0.4
const BOUNCE_FRICTION := 0.6
## Seconds an explosion's model shows. `# ASSUMPTION`: EXPL has no duration.
const EXPLOSION_SECONDS := 2.0
## The physics layers a shot's ray hits: all of them.
const HIT_MASK := 0xFFFFFFFF

## How many damage log lines are kept.
const DAMAGE_LOG_SIZE := 100
## How many resolved hitscan shots are kept for spawn_shot_projectile().
const RESOLVED_SHOTS_KEPT := 32
## Seconds a debug shot line shows.
const DEBUG_LINE_SECONDS := 3.0

## The id the next shot gets.
var next_shot_id := 1
## The latest hits, oldest first: "<shooter> hit <target> with <weapon> for
## <damage>". The damage system (later) applies the damage; this records it.
var damage_log: PackedStringArray = PackedStringArray()
## Whether shots show their effects (muzzle flash, tracers, impacts). Tests
## and a client that replays shots itself turn it off.
var show_effects := true
## Whether each resolved shot draws its rays as debug lines (green to a hit,
## red to a miss at its range) for DEBUG_LINE_SECONDS. On in debug builds.
var debug_shot_lines := OS.is_debug_build()
## Resolved hitscan shots by id (from, projectile, ends), the latest
## RESOLVED_SHOTS_KEPT, for spawn_shot_projectile().
var _resolved := {}
## Shots fired since the last physics tick, resolved in it.
var _pending: Array[Dictionary] = []
## The projectiles stepped each tick: every ProjectileReference the server
## launched, flying or at rest, until it ends.
var _projectiles: Array[ProjectileReference] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	var saves := get_node_or_null("/root/SaveServer")
	if saves != null:
		saves.extra_sections["projectile_server"] = self


## Fires one shot of `weapon` with `projectile` (resolved by the caller: the
## ammo's DAT2 Projectile, else the WEAP's) and `ammo` (null when none). `from`
## is the shot's origin and direction (-Z), Godot world, after the caller's
## accuracy cone. `seed` draws the post-shot spread. `shooter` is any
## reference, or null; its collision is excluded from the shot. Returns the
## shot's id, or 0 when nothing fires.
func fire(weapon: WeaponBase, shooter: EsmReference, from: Transform3D, projectile: ProjectileBase,
		ammo: AmmoBase = null, seed: int = 0) -> int:
	if weapon == null or projectile == null:
		return 0
	var shot := {
		"id": next_shot_id,
		"weapon": weapon,
		"shooter": shooter,
		"from": from,
		"projectile": projectile,
		"ammo": ammo,
		"seed": seed,
	}
	next_shot_id += 1
	shot["directions"] = projectile_directions(weapon, ammo, from, seed)
	_pending.append(shot)
	shot_created.emit(shot)
	return int(shot["id"])


## The direction of each of a shot's projectiles, Godot world: the shot's
## count (the ammo's Proj. per Shot, else the WEAP's Projectile Count, at
## least 1) fanned around `from`'s -Z inside the post-shot spread, drawn from
## `seed` so the same request gives the same directions.
static func projectile_directions(weapon: WeaponBase, ammo: AmmoBase, from: Transform3D, seed: int) -> PackedVector3Array:
	var random := RandomNumberGenerator.new()
	random.seed = seed
	var count := maxi(weapon.effective_projectile_count(ammo), 1)
	var cone := deg_to_rad(post_shot_spread(weapon, ammo))
	var result := PackedVector3Array()
	for index in count:
		result.append(cone_direction(from.basis, cone, random))
	return result


## The post-shot spread, degrees: the WEAP's Min Spread with the ammo's
## Spread Mod effects. `# ASSUMPTION` Min Spread is the post-shot spread
## (WeaponBase.min_spread).
static func post_shot_spread(weapon: WeaponBase, ammo: AmmoBase) -> float:
	var spread := weapon.min_spread
	if ammo != null:
		for effect in ammo.effects:
			if effect.effect_type == AmmoEffectBase.TYPE_SPREAD:
				spread = effect.apply(spread)
	return maxf(spread, 0.0)


## A direction within `half_angle` radians of `basis`'s -Z, uniform over the
## cone's solid angle.
static func cone_direction(basis: Basis, half_angle: float, random: RandomNumberGenerator) -> Vector3:
	var forward := -basis.z.normalized()
	if half_angle <= 0.0:
		return forward
	var cos_angle := lerpf(1.0, cos(half_angle), random.randf())
	var sin_angle := sqrt(maxf(1.0 - cos_angle * cos_angle, 0.0))
	var turn := random.randf() * TAU
	var side := basis.x.normalized()
	var up := basis.y.normalized()
	return (forward * cos_angle + (side * cos(turn) + up * sin(turn)) * sin_angle).normalized()


## A shot's damage per projectile: the WEAP's Base Damage with the ammo's
## Damage Mod effects. Resistances, criticals and limbs are not applied here.
static func projectile_damage(weapon: WeaponBase, ammo: AmmoBase) -> float:
	var damage := float(weapon.base_damage)
	if ammo != null:
		for effect in ammo.effects:
			if effect.effect_type == AmmoEffectBase.TYPE_DAMAGE:
				damage = effect.apply(damage)
	return maxf(damage, 0.0)


func _physics_process(_delta: float) -> void:
	var shots := _pending
	_pending = []
	for shot in shots:
		var projectile: ProjectileBase = shot["projectile"]
		if resolves_as_ray(projectile):
			_resolve_hitscan(shot)
		else:
			_launch(shot)
	_step_projectiles(_delta)


## Whether a shot of `projectile` resolves as rays in the tick it is fired:
## the hitscan PROJ, and the Beam PROJ (every laser) until beams have their own
## path. `# ASSUMPTION` beams as rays: no Beam PROJ is hitscan.
static func resolves_as_ray(projectile: ProjectileBase) -> bool:
	return projectile.is_hitscan() or projectile.projectile_type == ProjectileBase.TYPE_BEAM


## Casts one ray per projectile to the PROJ's Range and reports each hit, then
## a lethal hit for each target the shot's total damage would kill.
func _resolve_hitscan(shot: Dictionary) -> void:
	var space := get_viewport().world_3d.direct_space_state if get_viewport() != null else null
	if space == null:
		return
	var projectile: ProjectileBase = shot["projectile"]
	var from: Transform3D = shot["from"]
	var length := projectile.projectile_range / UNITS_PER_METRE
	var damage := projectile_damage(shot["weapon"], shot["ammo"])
	var exclude := shooter_collision(shot["shooter"])
	var totals := {}
	var ends := PackedVector3Array()
	var hit_flags: Array[bool] = []
	var tracer_random := RandomNumberGenerator.new()
	tracer_random.seed = int(shot["seed"]) + 1
	for direction: Vector3 in shot["directions"]:
		var query := PhysicsRayQueryParameters3D.create(from.origin, from.origin + direction * length, HIT_MASK, exclude)
		var result := space.intersect_ray(query)
		var end: Vector3 = from.origin + direction * length if result.is_empty() else result["position"]
		var struck := _shot_projectile(space, from.origin, end)
		if struck != null:
			ends.append(struck.position)
			hit_flags.append(true)
			detonate(struck)
			continue
		ends.append(end)
		hit_flags.append(not result.is_empty())
		var is_beam := projectile.projectile_type == ProjectileBase.TYPE_BEAM
		if show_effects and (is_beam or tracer_random.randf() < projectile.tracer_chance):
			_show_tracer(projectile, from.origin, end)
		if result.is_empty():
			continue
		var target := reference_of(result["collider"])
		if show_effects:
			_show_impact(shot["weapon"], target, result["position"], result["normal"], direction)
		_log_hit(shot, target, damage)
		var report := {
			"shot_id": shot["id"],
			"position": result["position"],
			"normal": result["normal"],
			"collider": result["collider"],
			"target": target,
			"damage": damage,
		}
		hit.emit(int(shot["id"]), report)
		if target != null:
			totals[target] = float(totals.get(target, 0.0)) + damage
	_keep_resolved(shot, ends)
	if debug_shot_lines:
		_draw_debug_lines(from.origin, ends, hit_flags)
	shot_resolved.emit(int(shot["id"]), ends)
	for target: EsmReference in totals:
		if would_kill(target, totals[target]):
			lethal_hit.emit(int(shot["id"]), target)


## Whether `damage` would kill `target`: an actor whose current Health is
## above 0 and at most `damage`. `# ASSUMPTION` the damage formula (DT, DR,
## criticals, limbs) is not applied.
static func would_kill(target: EsmReference, damage: float) -> bool:
	var values := target.get_actor_values() if target != null else null
	if values == null:
		return false
	var health := values.get_current(ActorValue.HEALTH)
	return health > 0.0 and damage >= health


## The EsmReference a collider belongs to: its nearest EsmNode ancestor's; null
## for world geometry with none.
static func reference_of(collider: Object) -> EsmReference:
	var node := collider as Node
	while node != null:
		if node is EsmNode:
			return (node as EsmNode).reference
		node = node.get_parent()
	return null


## The collision RIDs a shot from `shooter` must not hit: every collision
## object of its node, and the body its node is part of (the player's
## CharacterBody3D above its actor node).
static func shooter_collision(shooter: EsmReference) -> Array[RID]:
	var result: Array[RID] = []
	var node: Node = EsmNode.node_for(shooter) if shooter != null else null
	if node == null:
		return result
	for body: Node in node.find_children("*", "CollisionObject3D", true, false):
		result.append((body as CollisionObject3D).get_rid())
	var ancestor := node.get_parent()
	while ancestor != null:
		if ancestor is CollisionObject3D:
			result.append((ancestor as CollisionObject3D).get_rid())
			break
		ancestor = ancestor.get_parent()
	return result


## The kill-cam projectile of a resolved hitscan shot: its PROJ's model flying
## from the shot's origin to its first projectile's end at the PROJ's Speed.
## Null when the shot is no longer kept. The kill cam follows it.
func spawn_shot_projectile(shot_id: int) -> ProjectileEffect:
	var shot: Dictionary = _resolved.get(shot_id, {})
	if shot.is_empty():
		return null
	var projectile: ProjectileBase = shot["projectile"]
	var from: Transform3D = shot["from"]
	var ends: PackedVector3Array = shot["ends"]
	if ends.is_empty():
		return null
	var effect := _make_effect("ShotProjectile")
	effect.show_model(projectile.model_path)
	effect.fly(from.origin, ends[0], projectile.speed / UNITS_PER_METRE)
	effect.play_sound(projectile.sound)
	return effect


func _keep_resolved(shot: Dictionary, ends: PackedVector3Array) -> void:
	_resolved[int(shot["id"])] = {"from": shot["from"], "projectile": shot["projectile"], "ends": ends}
	while _resolved.size() > RESOLVED_SHOTS_KEPT:
		_resolved.erase(_resolved.keys()[0])


## Shows `projectile`'s muzzle flash: NAM1 at `from` (facing its -Z) for
## Muzzle Flash Duration, with its Muzzle Flash Light, when the Muzzle Flash
## flag is set. Cosmetic, so fire() does not show it: a weapon node shows its
## own under its muzzle (`parent`), so it moves with the gun; a caller with no
## gun (script FireWeapon) passes no parent and it stays where it is shown.
## The flash, or null when it has none.
func show_muzzle_flash(projectile: ProjectileBase, from: Transform3D, parent: Node = null) -> ProjectileEffect:
	if not show_effects or projectile == null:
		return null
	if projectile.flags & ProjectileBase.FLAG_MUZZLE_FLASH == 0 or projectile.muzzle_flash_model_path.is_empty():
		return null
	var effect := _make_effect("MuzzleFlash")
	if parent != null:
		effect.reparent(parent, false)
	effect.global_transform = from
	effect.lifetime = maxf(projectile.muzzle_flash_duration, 0.02)
	effect.show_model(projectile.muzzle_flash_model_path, MUZZLE_FLASH_TURN)
	if projectile.muzzle_flash_light_form_id != 0:
		effect.add_light(EsmServer.get_base(projectile.muzzle_flash_light_form_id) as LightBase)
	return effect


## A tracer: the PROJ's model flying from the muzzle to the ray's end at its
## Speed.
func _show_tracer(projectile: ProjectileBase, from: Vector3, to: Vector3) -> void:
	var effect := _make_effect("Tracer")
	effect.show_model(projectile.model_path)
	effect.fly(from, to, projectile.speed / UNITS_PER_METRE)


## The weapon's impact (INAM IPDS) for the hit surface: its IPCT's model for
## its duration, turned by its orientation, and its sound. The surface's
## material is Organic on an actor, Stone elsewhere: collision does not keep
## its havok material yet. `# ASSUMPTION`
func _show_impact(weapon: WeaponBase, target: EsmReference, position: Vector3, normal: Vector3, direction: Vector3) -> void:
	if weapon.impact_dataset_form_id == 0:
		return
	var dataset := EsmServer.get_base(weapon.impact_dataset_form_id) as ImpactDatasetBase
	if dataset == null:
		return
	var material := ImpactDatasetBase.MATERIAL_ORGANIC if target is ActorReference else ImpactDatasetBase.MATERIAL_STONE
	var impact := dataset.impact_for(material)
	if impact == null:
		return
	var effect := _make_effect("Impact")
	effect.global_position = position
	var facing := normal
	if impact.orientation == ImpactBase.ORIENTATION_PROJECTILE_VECTOR:
		facing = direction
	elif impact.orientation == ImpactBase.ORIENTATION_PROJECTILE_REFLECTION:
		facing = direction.bounce(normal)
	effect.face(facing)
	effect.lifetime = maxf(impact.duration, 0.05)
	effect.show_model(impact.model_path)
	effect.play_sound(impact.sound)


func _make_effect(effect_name: String) -> ProjectileEffect:
	var effect := ProjectileEffect.new()
	effect.name = effect_name
	add_child(effect, true)
	return effect


## Adds a damage log line for one projectile's hit.
func _log_hit(shot: Dictionary, target: EsmReference, damage: float) -> void:
	var line := "%s hit %s with %s for %.0f" % [display_name(shot["shooter"]), display_name(target), display_name(shot["weapon"]), damage]
	damage_log.append(line)
	if damage_log.size() > DAMAGE_LOG_SIZE:
		damage_log.remove_at(0)


## A reference's or record's name for the damage log: its base's FULL, else
## its EditorID, else its id; "nothing" for null.
static func display_name(thing: Object) -> String:
	if thing == null:
		return "nothing"
	var record: EsmBase = thing.base if thing is EsmReference else thing as EsmBase
	if record != null and not record.full_name.is_empty():
		return record.full_name
	if record != null and not record.editor_id.is_empty():
		return record.editor_id
	if thing is EsmReference:
		return String((thing as EsmReference).instance_id)
	return str(thing)


## Draws each ray of a shot from `origin` to its end, green where it hit and
## red where it missed, on top of everything, for DEBUG_LINE_SECONDS.
func _draw_debug_lines(origin: Vector3, ends: PackedVector3Array, hit_flags: Array[bool]) -> void:
	var lines := ImmediateMesh.new()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.no_depth_test = true
	lines.surface_begin(Mesh.PRIMITIVE_LINES, material)
	for index in ends.size():
		lines.surface_set_color(Color.GREEN if hit_flags[index] else Color.RED)
		lines.surface_add_vertex(origin)
		lines.surface_add_vertex(ends[index])
	lines.surface_end()
	var drawn := MeshInstance3D.new()
	drawn.name = "DebugShotLines"
	drawn.mesh = lines
	drawn.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var effect := _make_effect("DebugShot")
	effect.lifetime = DEBUG_LINE_SECONDS
	effect.add_child(drawn)


## The projectiles the server is stepping, flying or at rest.
func get_projectiles() -> Array[ProjectileReference]:
	return _projectiles.duplicate()


## Starts one ProjectileReference per direction of a moving shot: at the
## shot's origin, at the PROJ's Speed, in the shooter's space (the player's
## when it has none). A grenade's fuse starts now; a mine's when it lands.
func _launch(shot: Dictionary) -> void:
	var projectile: ProjectileBase = shot["projectile"]
	var from: Transform3D = shot["from"]
	var shooter: EsmReference = shot["shooter"]
	var space_form_id := _space_of(shooter)
	for direction: Vector3 in shot["directions"]:
		var reference := EsmServer.create_runtime_reference(projectile.form_id) as ProjectileReference
		if reference == null:
			continue
		reference.shot_id = int(shot["id"])
		reference.shooter = shooter
		reference.weapon = shot["weapon"]
		reference.ammo = shot["ammo"]
		reference.segment_origin = from.origin
		reference.segment_velocity = direction * projectile.speed / UNITS_PER_METRE
		reference.segment_time = 0.0
		if projectile.alt_trigger_timer > 0.0 and projectile.alt_trigger_proximity <= 0.0:
			reference.fuse_left = projectile.alt_trigger_timer
		_place(reference, space_form_id, from.origin, direction)
		_projectiles.append(reference)
		projectile_launched.emit(reference)


## Gravity on `projectile`, metres per second squared: its Gravity times the
## world's, and no less than the world's for a Lobber. 3 of the 23 Lobber PROJ
## have Gravity 0 (the bottlecap, plasma and pulse mines; the other 20 have
## 1), and with none a dropped mine flies straight to its Range.
## `# ASSUMPTION` the PROJ's Gravity multiplies the world's, and a Lobber
## always falls.
static func gravity_of(projectile: ProjectileBase) -> Vector3:
	var world := float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	var scale := projectile.gravity
	if projectile.projectile_type == ProjectileBase.TYPE_LOBBER:
		scale = maxf(scale, 1.0)
	return Vector3.DOWN * world * scale


## The point of `reference`'s segment `seconds` into it, Godot world: closed
## form, so the same launch gives the same arc at any tick rate.
static func segment_point(reference: ProjectileReference, seconds: float) -> Vector3:
	var gravity := gravity_of(reference.get_projectile_base())
	return reference.segment_origin + reference.segment_velocity * seconds + gravity * (0.5 * seconds * seconds)


## The velocity of `reference`'s segment `seconds` into it.
static func segment_velocity_at(reference: ProjectileReference, seconds: float) -> Vector3:
	return reference.segment_velocity + gravity_of(reference.get_projectile_base()) * seconds


## The facing of a projectile moving along `direction` at `age` seconds: its
## -Z along the direction, then spun by the PROJ's Rotation (degrees per
## second about each axis) when its Rotation flag is set. `# ASSUMPTION` the
## Rotation's unit.
static func facing(projectile: ProjectileBase, direction: Vector3, age: float) -> Basis:
	var basis := Basis.IDENTITY
	if direction.length() > 0.0001:
		var forward := direction.normalized()
		var up := Vector3.UP if absf(forward.dot(Vector3.UP)) < 0.99 else Vector3.BACK
		basis = Basis.looking_at(forward, up)
	if projectile != null and projectile.flags & ProjectileBase.FLAG_ROTATION != 0:
		var spin := projectile.rotation * age
		basis = basis * Basis.from_euler(Vector3(deg_to_rad(spin.x), deg_to_rad(spin.y), deg_to_rad(spin.z)))
	return basis


## Writes a projectile's place to its reference (authored metres and
## rotation), so the streamers file it in the cell under it and its node
## follows.
static func _place(reference: ProjectileReference, space_form_id: int, point: Vector3, direction: Vector3) -> void:
	var placement := EsmReferencePhysicaliser.authored_placement(Transform3D(facing(reference.get_projectile_base(), direction, reference.age), point))
	reference.set_location(space_form_id, placement["position"])
	reference.rotation = placement["rotation"]


## The space a shot from `shooter` flies in: its space, else the player's.
func _space_of(shooter: EsmReference) -> int:
	if shooter != null and shooter.current_space_form_id != 0:
		return shooter.current_space_form_id
	var player: EsmReference = ScriptServer.player_reference
	return player.current_space_form_id if player != null else 0


## The space loaded: the player's; 0 when there is no player (tests), when
## no projectile is removed for its space.
func _loaded_space() -> int:
	var player: EsmReference = ScriptServer.player_reference
	return player.current_space_form_id if player != null else 0


func _step_projectiles(delta: float) -> void:
	if _projectiles.is_empty():
		return
	var space := get_viewport().world_3d.direct_space_state if get_viewport() != null else null
	var loaded := _loaded_space()
	for reference in _projectiles.duplicate():
		if not _projectiles.has(reference):
			continue
		if loaded != 0 and reference.current_space_form_id != loaded:
			end_projectile(reference, "space_unloaded")
			continue
		reference.age += delta
		if _step_fuse(reference, delta, space):
			continue
		if not reference.at_rest and space != null:
			_fly(reference, delta, space)


## Runs `reference`'s fuse and proximity trigger. True when it went off.
func _step_fuse(reference: ProjectileReference, delta: float, space: PhysicsDirectSpaceState3D) -> bool:
	if reference.disarmed:
		return false
	var projectile: ProjectileBase = reference.get_projectile_base()
	if reference.fuse_left >= 0.0:
		reference.fuse_left -= delta
		if reference.fuse_left < 0.0:
			if projectile.alt_trigger_proximity > 0.0:
				reference.armed = true
			else:
				detonate(reference)
				return true
	if reference.armed and space != null and _someone_near(reference, space):
		detonate(reference)
		return true
	return false


## Whether an actor other than the shooter is within the PROJ's Alt. Trigger
## Proximity of an armed projectile.
func _someone_near(reference: ProjectileReference, space: PhysicsDirectSpaceState3D) -> bool:
	var radius := reference.get_projectile_base().alt_trigger_proximity / UNITS_PER_METRE
	for found in _actors_within(space, segment_point(reference, reference.segment_time), radius):
		if found != reference.shooter:
			return true
	return false


## The actor references whose collision is within `radius` of `point`.
func _actors_within(space: PhysicsDirectSpaceState3D, point: Vector3, radius: float) -> Array[EsmReference]:
	var sphere := SphereShape3D.new()
	sphere.radius = maxf(radius, 0.01)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.transform = Transform3D(Basis.IDENTITY, point)
	query.collision_mask = HIT_MASK
	var result: Array[EsmReference] = []
	for found in space.intersect_shape(query, 64):
		var target := reference_of(found["collider"])
		if target is ActorReference and not result.has(target):
			result.append(target)
	return result


## Moves a flying projectile one tick along its segment, casting along the
## step for what it strikes.
func _fly(reference: ProjectileReference, delta: float, space: PhysicsDirectSpaceState3D) -> void:
	var projectile: ProjectileBase = reference.get_projectile_base()
	var start := segment_point(reference, reference.segment_time)
	var next_time := reference.segment_time + delta
	var finish := segment_point(reference, next_time)
	var exclude: Array[RID] = []
	if reference.age < SHOOTER_GRACE_SECONDS:
		exclude = shooter_collision(reference.shooter)
	var query := PhysicsRayQueryParameters3D.create(start, finish, HIT_MASK, exclude)
	var result := space.intersect_ray(query)
	if not result.is_empty():
		_strike(reference, result, segment_velocity_at(reference, next_time))
		return
	reference.segment_time = next_time
	reference.travelled += start.distance_to(finish)
	_place(reference, reference.current_space_form_id, finish, segment_velocity_at(reference, next_time))
	if reference.travelled >= projectile.projectile_range / UNITS_PER_METRE:
		end_projectile(reference, "range")


## What a projectile does where it strikes: an explosive Missile explodes; a
## Lobber with a proximity trigger or Detonates sticks and waits; another
## Lobber bounces (bounce_velocity()) and comes to rest; any other Missile hits
## for its weapon's damage, then lies there when it Can Be Picked Up (the
## throwing knife, hatchet and spear) or ends. `# ASSUMPTION` these rules.
func _strike(reference: ProjectileReference, result: Dictionary, velocity: Vector3) -> void:
	var projectile: ProjectileBase = reference.get_projectile_base()
	var point: Vector3 = result["position"]
	var normal: Vector3 = result["normal"]
	var target := reference_of(result["collider"])
	var waits := projectile.alt_trigger_proximity > 0.0 or projectile.flags & ProjectileBase.FLAG_DETONATES != 0
	if projectile.projectile_type == ProjectileBase.TYPE_LOBBER:
		if waits:
			_come_to_rest(reference, point, velocity)
			if projectile.alt_trigger_proximity > 0.0 and reference.fuse_left < 0.0:
				reference.fuse_left = projectile.alt_trigger_timer
			return
		var bounced := bounce_velocity(velocity, normal, projectile.bouncy_mult)
		if bounced.length() < REST_SPEED:
			_come_to_rest(reference, point + normal * 0.02, velocity)
			return
		_start_segment(reference, point + normal * 0.02, bounced)
		return
	_report_hit(reference, target, point, normal, velocity)
	if projectile.explodes():
		reference.segment_origin = point
		reference.segment_velocity = Vector3.ZERO
		reference.segment_time = 0.0
		detonate(reference)
		return
	if projectile.flags & ProjectileBase.FLAG_CAN_BE_PICKED_UP != 0:
		_come_to_rest(reference, point, velocity)
		return
	end_projectile(reference, "hit")


## The velocity after a bounce off a surface with `normal`: the part into the
## surface reflected and scaled by Bouncy Mult (clamped to 0..1) and
## BOUNCE_RESTITUTION, the part along it scaled by BOUNCE_FRICTION.
static func bounce_velocity(velocity: Vector3, normal: Vector3, bouncy_mult: float) -> Vector3:
	var into := normal * velocity.dot(normal)
	var along := velocity - into
	return -into * clampf(bouncy_mult, 0.0, 1.0) * BOUNCE_RESTITUTION + along * BOUNCE_FRICTION


## Starts a new segment from `point` with `velocity` (a bounce).
func _start_segment(reference: ProjectileReference, point: Vector3, velocity: Vector3) -> void:
	reference.travelled += segment_point(reference, reference.segment_time).distance_to(point)
	reference.segment_origin = point
	reference.segment_velocity = velocity
	reference.segment_time = 0.0
	_place(reference, reference.current_space_form_id, point, velocity)


## Stops a projectile at `point`, facing along the way it came.
func _come_to_rest(reference: ProjectileReference, point: Vector3, velocity: Vector3) -> void:
	reference.segment_origin = point
	reference.segment_velocity = Vector3.ZERO
	reference.segment_time = 0.0
	reference.at_rest = true
	_place(reference, reference.current_space_form_id, point, velocity)


## Reports a moving projectile's direct hit: the weapon's damage per
## projectile, the impact, the damage log and a lethal hit.
func _report_hit(reference: ProjectileReference, target: EsmReference, point: Vector3, normal: Vector3, velocity: Vector3) -> void:
	var damage := projectile_damage(reference.weapon, reference.ammo) if reference.weapon != null else 0.0
	var shot := {"id": reference.shot_id, "shooter": reference.shooter, "weapon": reference.weapon}
	if show_effects and reference.weapon != null:
		_show_impact(reference.weapon, target, point, normal, velocity.normalized())
	_log_hit(shot, target, damage)
	hit.emit(reference.shot_id, {
		"shot_id": reference.shot_id,
		"position": point,
		"normal": normal,
		"collider": null,
		"target": target,
		"damage": damage,
		"projectile": reference,
	})
	if target != null and would_kill(target, damage):
		lethal_hit.emit(reference.shot_id, target)


## Sets `reference` off now: its explosion where it is, when the PROJ explodes
## (by its Explosion flag), then ends it. A disarmed projectile does nothing.
func detonate(reference: ProjectileReference) -> void:
	if reference == null or reference.disarmed or not _projectiles.has(reference):
		return
	var projectile: ProjectileBase = reference.get_projectile_base()
	var point := segment_point(reference, reference.segment_time)
	if projectile.explodes():
		explode(projectile.explosion, point, reference.shot_id, reference.shooter, reference.weapon)
	end_projectile(reference, "exploded")


## Sets off every charge `shooter` placed that waits to be detonated (the PROJ's
## Detonates flag: C4), for a detonator: a weapon with Projectile Count 0 and
## no PROJ. `# ASSUMPTION` the detonator's link. How many it set off.
func detonate_placed(shooter: EsmReference) -> int:
	var count := 0
	for reference in _projectiles.duplicate():
		var projectile: ProjectileBase = reference.get_projectile_base()
		if reference.shooter == shooter and reference.at_rest and projectile.flags & ProjectileBase.FLAG_DETONATES != 0:
			detonate(reference)
			count += 1
	return count


## An explosion at `point`: its damage to every actor within its Radius,
## falling off linearly to 0 at the edge and blocked by world geometry unless
## it Ignores LOS; its Force pushing rigid bodies the same way; its model and
## sound. `# ASSUMPTION` the falloff and the force's unit.
func explode(explosion: ExplosionBase, point: Vector3, shot_id: int = 0, shooter: EsmReference = null, weapon: WeaponBase = null) -> void:
	if explosion == null:
		return
	var space := get_viewport().world_3d.direct_space_state if get_viewport() != null else null
	var radius := explosion.radius / UNITS_PER_METRE
	if show_effects:
		var effect := _make_effect("Explosion")
		effect.global_position = point
		effect.lifetime = EXPLOSION_SECONDS
		effect.show_model(explosion.model_path)
		effect.play_sound(explosion.sound)
	if space != null and radius > 0.0:
		var shot := {"id": shot_id, "shooter": shooter, "weapon": weapon}
		for target in _actors_within(space, point, radius):
			var node := EsmNode.node_for(target)
			var at: Vector3 = node.global_position if node != null else point
			if explosion.flags & ExplosionBase.FLAG_IGNORE_LOS_CHECK == 0 and _blocked(space, point, at, target):
				continue
			var falloff := clampf(1.0 - point.distance_to(at) / radius, 0.0, 1.0)
			var damage := explosion.damage * falloff
			_log_hit(shot, target, damage)
			hit.emit(shot_id, {"shot_id": shot_id, "position": at, "normal": Vector3.ZERO, "collider": null, "target": target, "damage": damage, "explosion": explosion})
			if would_kill(target, damage):
				lethal_hit.emit(shot_id, target)
		_push_bodies(space, explosion, point, radius)
	exploded.emit(shot_id, explosion, point)


## Whether world geometry stands between `from` and `to`, not counting
## `target`'s own collision.
func _blocked(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3, target: EsmReference) -> bool:
	var query := PhysicsRayQueryParameters3D.create(from, to, HIT_MASK)
	var result := space.intersect_ray(query)
	return not result.is_empty() and reference_of(result["collider"]) != target


func _push_bodies(space: PhysicsDirectSpaceState3D, explosion: ExplosionBase, point: Vector3, radius: float) -> void:
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.transform = Transform3D(Basis.IDENTITY, point)
	for found in space.intersect_shape(query, 64):
		var body := found["collider"] as RigidBody3D
		if body == null or body.freeze:
			continue
		var away := body.global_position - point
		var falloff := clampf(1.0 - away.length() / radius, 0.0, 1.0)
		body.apply_central_impulse(away.normalized() * explosion.force / UNITS_PER_METRE * falloff)


## The projectile a hitscan ray from `from` to `to` strikes first, when one is
## shootable: a non-hitscan PROJ with the Explosion flag that is not
## disarmed. Its EsmProjectileNode's area is on PROJECTILE_LAYER.
func _shot_projectile(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> ProjectileReference:
	var query := PhysicsRayQueryParameters3D.create(from, to, PROJECTILE_LAYER)
	query.collide_with_areas = true
	query.collide_with_bodies = false
	var result := space.intersect_ray(query)
	if result.is_empty():
		return null
	var struck := reference_of(result["collider"]) as ProjectileReference
	if struck == null or struck.disarmed or not struck.get_projectile_base().explodes():
		return null
	return struck


## Disarms a projectile (the PROJ's Can Be Disabled): it no longer explodes and
## lies until picked up; its node plays the Sound - Disable. False when it
## cannot be disarmed.
func disarm(reference: ProjectileReference) -> bool:
	var projectile: ProjectileBase = reference.get_projectile_base() if reference != null else null
	if projectile == null or projectile.flags & ProjectileBase.FLAG_CAN_BE_DISABLED == 0 or reference.disarmed:
		return false
	reference.disarmed = true
	reference.armed = false
	reference.fuse_left = -1.0
	var node := EsmNode.node_for(reference) as EsmProjectileNode
	if node != null:
		node.play_disarm_sound()
	return true


## Picks up a projectile lying at rest (the PROJ's Can Be Picked Up, or
## disarmed): one of the weapon it was fired from goes into `actor`'s
## inventory, and the projectile ends. False when it cannot be picked up.
func pick_up(reference: ProjectileReference, actor: EsmReference) -> bool:
	var projectile: ProjectileBase = reference.get_projectile_base() if reference != null else null
	if projectile == null or not reference.at_rest:
		return false
	if projectile.flags & ProjectileBase.FLAG_CAN_BE_PICKED_UP == 0 and not reference.disarmed:
		return false
	var inventory := actor.get("contents") as Inventory if actor != null else null
	if inventory != null and reference.weapon != null:
		inventory.add_item(reference.weapon.form_id)
	end_projectile(reference, "picked_up")
	return true


## Ends a projectile: stops stepping it, frees its node, unplaces it and
## releases its runtime reference, so a save leaves it out.
func end_projectile(reference: ProjectileReference, reason: String) -> void:
	_projectiles.erase(reference)
	var node := EsmNode.node_for(reference)
	if node != null:
		node.queue_free()
	# Unplaced first, so no cell still files it for a streamer to rebuild.
	reference.set_location(0, Vector3.ZERO)
	EsmServer.release_runtime_reference(reference)
	projectile_ended.emit(reference, reason)


## SaveServer section: the shot id counter. The projectiles themselves save as
## EsmServer's runtime references.
func save_state() -> Dictionary:
	return {"next_shot_id": next_shot_id}


## Restores the shot id counter and steps every ProjectileReference the load
## rebuilt, from where it was saved.
func load_state(state: Dictionary, _report: Array = []) -> void:
	next_shot_id = int(state.get("next_shot_id", 1))
	_pending.clear()
	_projectiles.clear()
	for reference in EsmServer.get_runtime_references():
		if reference is ProjectileReference:
			_projectiles.append(reference)
