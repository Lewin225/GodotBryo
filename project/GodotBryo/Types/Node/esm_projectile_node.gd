@tool
class_name EsmProjectileNode
extends EsmNode

## A ProjectileReference's model: the PROJ's MODL where its reference is,
## facing along its -Z (the NIF's +Y: the missiles and the Fat Man point that
## way).
## ProjectileServer moves the reference; this node follows it every frame.
## The streamers build and free it like any reference's node. Its rigid
## bodies are held, so a model with one (the grenades, the 40mm round)
## neither falls nor collides. A shootable projectile (a non-hitscan PROJ with
## the Explosion flag) carries an area on ProjectileServer.PROJECTILE_LAYER
## for hitscan rays. Plays the PROJ's Sound while flying, its Sound -
## Countdown while its fuse runs. Placed from the GodotBryo browser it shows a
## projectile's fields (ProjectileBase in the inspector) and its look.

const ProjectileServerScript := preload("res://GodotBryo/Servers/ProjectileServer/projectile_server.gd")
## The shootable area's radius, metres. `# ASSUMPTION`
const SHOOTABLE_RADIUS := 0.15

var _flight_player: AudioStreamPlayer3D = null
var _countdown_player: AudioStreamPlayer3D = null
var _area: Area3D = null
## A copy of the PROJ's Muzzle Flash Light, lit while it flies; null when the
## PROJ has none.
var _light: OmniLight3D = null


## The reference's PROJ; null before it resolves.
func get_projectile_base() -> ProjectileBase:
	return reference.base as ProjectileBase if reference != null else null


## Plays the PROJ's Sound - Disable once.
func play_disarm_sound() -> void:
	var projectile := get_projectile_base()
	if projectile != null and projectile.disable_sound != null:
		_play_once(projectile.disable_sound)


func _ready() -> void:
	super._ready()
	_add_shootable_area()
	_add_light()


func _process(_delta: float) -> void:
	var projectile := reference as ProjectileReference
	if projectile == null or Engine.is_editor_hint():
		return
	global_transform = EsmReferencePhysicaliser.placement_transform(projectile.position, projectile.rotation)
	_set_looping(projectile.get_projectile_base().sound if not projectile.at_rest else null, true)
	if _light != null:
		_light.visible = not projectile.at_rest
	var counting := projectile.fuse_left >= 0.0 and not projectile.disarmed
	_set_looping(projectile.get_projectile_base().countdown_sound if counting else null, false)


func _on_nif_visual_ready(tree: Node3D) -> void:
	super._on_nif_visual_ready(tree)
	EsmWeaponNode.hold_bodies(tree, true)


## A copy of the PROJ's Muzzle Flash Light (LIGH colour, radius and energy
## scaled as the flash's, casting shadows): the PROJ's own Light is NULL on
## all 95. Lit while it flies.
func _add_light() -> void:
	var projectile := get_projectile_base()
	if _light != null or projectile == null or projectile.muzzle_flash_light_form_id == 0:
		return
	var light_base := EsmServer.get_base(projectile.muzzle_flash_light_form_id) as LightBase if not Engine.is_editor_hint() else null
	if light_base == null:
		return
	_light = OmniLight3D.new()
	_light.name = "Light"
	_light.light_color = light_base.color
	_light.omni_range = maxf(light_base.radius, 0.1) * ProjectileServerScript.FLASH_LIGHT_RADIUS_SCALE
	_light.light_energy = ProjectileServerScript.FLASH_LIGHT_ENERGY_SCALE
	_light.shadow_enabled = true
	add_child(_light)


func _add_shootable_area() -> void:
	var projectile := get_projectile_base()
	if _area != null or projectile == null or projectile.is_hitscan() or not projectile.explodes():
		return
	_area = Area3D.new()
	_area.name = "Shootable"
	_area.collision_layer = ProjectileServerScript.PROJECTILE_LAYER
	_area.collision_mask = 0
	_area.monitoring = false
	var shape := CollisionShape3D.new()
	shape.shape = SphereShape3D.new()
	(shape.shape as SphereShape3D).radius = SHOOTABLE_RADIUS
	_area.add_child(shape)
	add_child(_area)


## Starts or stops the flight (`flight` true) or countdown loop: `sound`
## playing, or none when null.
func _set_looping(sound: SoundBase, flight: bool) -> void:
	var player := _flight_player if flight else _countdown_player
	if sound == null:
		if player != null and player.playing:
			player.stop()
		return
	if player == null:
		player = _sound_player(sound)
		if flight:
			_flight_player = player
		else:
			_countdown_player = player
	if player.stream != null and not player.playing:
		player.play()


func _play_once(sound: SoundBase) -> void:
	var player := _sound_player(sound)
	if player.stream != null:
		player.finished.connect(player.queue_free)
		player.play()


func _sound_player(sound: SoundBase) -> AudioStreamPlayer3D:
	var player := AudioStreamPlayer3D.new()
	var streams := SoundServer.get_streams(sound)
	if not streams.is_empty():
		player.stream = streams[0]
	player.unit_size = maxf(sound.minimum_attenuation_distance / ProjectileServerScript.UNITS_PER_METRE, 1.0)
	add_child(player)
	return player
