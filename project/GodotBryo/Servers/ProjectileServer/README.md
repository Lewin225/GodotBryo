# ProjectileServer

Fires shots: the one entry point that creates projectiles and casts hits. The weapon node
(EsmWeaponNode, after its ammo, jam and cycle checks), script `FireWeapon` and NPC combat call
`fire()`; nothing else creates projectiles. Plan: `Plans/Weapons/projectiles.md`.

## Contract

```gdscript
ProjectileServer.fire(weapon: WeaponBase, shooter: EsmReference, from: Transform3D,
		projectile: ProjectileBase, ammo: AmmoBase = null, seed: int = 0) -> int   # shot id, 0 when nothing fires
ProjectileServer.projectile_directions(weapon, ammo, from, seed) -> PackedVector3Array  # static
ProjectileServer.projectile_damage(weapon, ammo) -> float                               # static
ProjectileServer.resolves_as_ray(projectile) -> bool                                    # static
ProjectileServer.spawn_shot_projectile(shot_id) -> ProjectileEffect   # the kill-cam projectile
ProjectileServer.show_muzzle_flash(projectile, from, parent = null) -> ProjectileEffect
ProjectileServer.get_projectiles() -> Array[ProjectileReference]      # moving and resting
ProjectileServer.detonate(projectile)                                 # sets it off now
ProjectileServer.detonate_placed(shooter) -> int                      # a detonator: shooter's C4
ProjectileServer.explode(explosion, point, shot_id, shooter, weapon)
ProjectileServer.disarm(projectile) -> bool
ProjectileServer.pick_up(projectile, actor) -> bool
ProjectileServer.end_projectile(projectile, reason)
ProjectileServer.segment_point(projectile, seconds) -> Vector3        # static, closed form
ProjectileServer.damage_log: PackedStringArray                        # latest hits, oldest first
ProjectileServer.show_effects: bool                                   # muzzle flash, tracers, impacts
signal shot_created(shot: Dictionary)          # id, weapon, shooter, from, projectile, ammo, seed, directions
signal hit(shot_id: int, hit: Dictionary)      # shot_id, position, normal, collider, target, damage
signal lethal_hit(shot_id: int, target: EsmReference)
signal shot_resolved(shot_id: int, ends: PackedVector3Array)
signal projectile_launched(projectile: ProjectileReference)
signal exploded(shot_id: int, explosion: ExplosionBase, position: Vector3)
signal projectile_ended(projectile: ProjectileReference, reason: String)
```

## Rules

- **The caller resolves** the projectile (the ammo's DAT2 Projectile, else the WEAP's DNAM
  Projectile) and the shot's direction inside the accuracy cone (the WEAP's Spread). The server
  uses `projectile` as given and never reads the ammo's PROJ.
- **The server fans** the shot into its projectiles: the ammo's Proj. per Shot, else the WEAP's
  Projectile Count, inside the post-shot spread (the WEAP's Min Spread, with the ammo's Spread
  Mod effects), drawn from `seed`. The same request draws the same directions.
- **Physics tick.** `fire()` queues the shot; the next `_physics_process` resolves it. A hitscan
  PROJ, and for now a Beam PROJ (no Beam PROJ is hitscan), casts one ray per projectile to the
  PROJ's Range. The shooter's node's collision, and the body its node sits in, are excluded.
  Pauses with the game (`PROCESS_MODE_PAUSABLE`).
- **Damage** per projectile is the WEAP's Base Damage with the ammo's Damage Mod effects. The
  server reports it (`hit`, `damage_log`) and does not apply it: resistances, criticals, limbs
  and Health belong to the damage system. `lethal_hit` fires once per target per shot when the
  shot's total damage to that target reaches its current Health.
- **Effects**, under the server as `ProjectileEffect` nodes: a tracer (the PROJ's model flying to the ray's end) by
  Tracer Chance, always for a beam; the weapon's INAM impact where a ray hits (Organic on an
  actor, Stone elsewhere, until collision keeps its havok material). An effect's lifetime starts
  when its model arrives.
- **The muzzle flash is the caller's.** It is cosmetic, so `fire()` does not show it.
  `show_muzzle_flash()` shows NAM1 with its Muzzle Flash Light for its duration: EsmWeaponNode
  passes its muzzle as the parent, so the flash moves with the gun (the viewmodel's in first
  person); script `FireWeapon` passes none and it stays in the world.
- **Units.** PROJ Speed and Range are game units; the server divides by 70 for metres.
- **Moving projectiles** (every non-hitscan, non-Beam PROJ) are `ProjectileReference`s, runtime
  references in EsmServer. Each flies a segment in closed form (`segment_point()`: origin +
  velocity × t + ½ gravity × t², gravity the PROJ's Gravity × the world's); each tick casts along
  that tick's stretch. A bounce or a stop starts a new segment. The server writes the
  reference's position and rotation each tick; the streamers build and free its
  `EsmProjectileNode` like any reference's, and the node follows the reference.
- **What a strike does:** an explosive Missile explodes; a Lobber with a proximity trigger or
  Detonates (mines, C4) sticks and waits; another Lobber bounces (`bounce_velocity()`) and comes
  to rest; any other Missile hits for its weapon's damage, then lies there when it Can Be Picked
  Up (knife, hatchet, spear) or ends. A grenade's fuse runs from launch; a mine's arms it after
  it lands, then an actor within its proximity sets it off.
- **Explosions:** damage within Radius falling off linearly, blocked by world geometry unless
  the EXPL Ignores LOS; Force pushes rigid bodies.
- **Shooting projectiles:** a non-hitscan PROJ with the Explosion flag carries an area on
  `PROJECTILE_LAYER`; a hitscan ray that reaches it sets it off.
- **Space:** a projectile flies in its space; when the loaded space (the player's) is another, it
  is removed with no hit.
- **Saving:** projectiles save as EsmServer runtime references (segment, fuse, armed); the server's
  `projectile_server` section holds the shot counter, and its `load_state()` steps every
  rebuilt `ProjectileReference` again.
- Activating a projectile (`ProjectileReference.default_activate()`) disarms it when armed, else
  picks it up.
