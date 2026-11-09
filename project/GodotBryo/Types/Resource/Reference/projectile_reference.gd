@tool
class_name ProjectileReference
extends EsmReference

## A reference to a PROJ: a moving projectile the ProjectileServer spawned (a
## missile, grenade, plasma bolt, thrown weapon), or one placed from the
## GodotBryo browser to inspect it. A runtime reference
## (EsmServer.create_runtime_reference()), so it saves with the game and a
## load resumes it. Its flight is a segment computed in closed form: its point
## at `segment_time` is segment_origin + segment_velocity × t + ½ gravity × t²
## (ProjectileServer.segment_point()). A bounce or a stop starts a new
## segment. Plan: Plans/Weapons/projectiles.md, Shape and Saving.
##
## Every field below is runtime state with no ESM source, set by
## ProjectileServer, saved, and used by ProjectileServer and
## EsmProjectileNode. `position` and `rotation` (EsmReference) follow the
## flight each tick, so the streamers file it in the cell it is over.

## The shot it belongs to (ProjectileServer's shot ids).
@export var shot_id: int = 0:
	set(value):
		shot_id = value
		mark_dirty()
## Who fired it: named in the damage log, excluded from its first metres, the
## owner of a placed charge. Saved as its instance_id.
@export var shooter: EsmReference = null:
	set(value):
		shooter = value
		mark_dirty()
## The WEAP it was fired from: its Base Damage on a hit.
@export var weapon: WeaponBase = null:
	set(value):
		weapon = value
		mark_dirty()
## The ammo it was fired with, null when none: its damage effects.
@export var ammo: AmmoBase = null:
	set(value):
		ammo = value
		mark_dirty()
## The segment's start, Godot world, metres.
@export var segment_origin: Vector3 = Vector3.ZERO:
	set(value):
		segment_origin = value
		mark_dirty()
## The segment's start velocity, Godot world, metres per second.
@export var segment_velocity: Vector3 = Vector3.ZERO:
	set(value):
		segment_velocity = value
		mark_dirty()
## Seconds into the segment.
@export var segment_time: float = 0.0:
	set(value):
		segment_time = value
		mark_dirty()
## Seconds since it was fired: its spin, and when it may hit its shooter.
@export var age: float = 0.0:
	set(value):
		age = value
		mark_dirty()
## Metres flown in all its segments, against the PROJ's Range.
@export var travelled: float = 0.0:
	set(value):
		travelled = value
		mark_dirty()
## Whether it has stopped: lying where it landed, stuck where it hit, or
## placed. A stopped projectile is not flown; its segment velocity is zero.
@export var at_rest: bool = false:
	set(value):
		at_rest = value
		mark_dirty()
## Seconds left on its fuse (the PROJ's Alt. Trigger Timer): the explosion of a
## grenade, the arming of a mine. Below 0 when no fuse runs.
@export var fuse_left: float = -1.0:
	set(value):
		fuse_left = value
		mark_dirty()
## Whether its proximity trigger is armed (a landed mine whose arming fuse ran
## out).
@export var armed: bool = false:
	set(value):
		armed = value
		mark_dirty()
## Whether it was disarmed: it no longer explodes, and lies until picked up.
@export var disarmed: bool = false:
	set(value):
		disarmed = value
		mark_dirty()


## The PROJ; null before the base resolves.
func get_projectile_base() -> ProjectileBase:
	return base as ProjectileBase


## Activated (ScriptServer.activate()): an armed or counting-down projectile
## that Can Be Disabled is disarmed; one lying at rest is picked up into the
## activator's inventory (ProjectileServer.disarm(), pick_up()).
func default_activate(activator: EsmReference) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var server: Node = tree.root.get_node_or_null("ProjectileServer") if tree != null else null
	if server == null:
		return
	var live := (armed or fuse_left >= 0.0) and not disarmed
	if live and server.disarm(self):
		return
	server.pick_up(self, activator)
