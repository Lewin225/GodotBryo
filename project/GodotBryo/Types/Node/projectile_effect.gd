class_name ProjectileEffect
extends Node3D

## One visual a shot leaves: a muzzle flash, a tracer, an impact or the
## kill-cam projectile. Built by ProjectileServer under itself: a NIF model
## (physics stripped, no shadow), an optional light and sound, and either a
## lifetime or a flight from one point to another, after which it frees
## itself.

const ProjectileServerScript := preload("res://GodotBryo/Servers/ProjectileServer/projectile_server.gd")
## Game units per metre (native/src/common/units.h).
const UNITS_PER_METRE := 70.0

## Seconds left before it frees itself; below 0 while it flies instead.
var lifetime := -1.0
## The flight: where it starts and ends (Godot world) and its speed, metres
## per second. Emits arrived at the end.
var flight_from := Vector3.ZERO
var flight_to := Vector3.ZERO
var flight_speed := 0.0
var _flight_time := 0.0
## The model path requested; a delivery for another path is dropped.
var _model_path := ""
## Seconds spent waiting for the requested model: a lifetime starts when it
## is shown, so a first impact or flash is not over before its model loads,
## and waits no more than MODEL_WAIT_SECONDS.
var _model_wait := -1.0
## The model's turn inside the effect (show_model()).
var _model_turn := Basis.IDENTITY

## The longest a lifetime waits for its model.
const MODEL_WAIT_SECONDS := 2.0

## A flight reached its end.
signal arrived


## Requests `path` from NifServer and shows it as this effect's child,
## turned by `turn` inside the effect (identity: the NIF's +Y along -Z).
func show_model(path: String, turn := Basis.IDENTITY) -> void:
	if path.is_empty():
		return
	_model_path = path
	_model_turn = turn
	_model_wait = 0.0
	NifServer.request(path, self, _on_model_delivered.bind(path))


## Adds a light from a LIGH: its colour, and its radius (metres) and energy
## scaled by ProjectileServer's FLASH_LIGHT_* constants, casting
## shadows, so where it shines from shows in the game.
func add_light(light_base: LightBase) -> void:
	if light_base == null:
		return
	var light := OmniLight3D.new()
	light.name = "Light"
	light.light_color = light_base.color
	light.omni_range = maxf(light_base.radius, 0.1) * ProjectileServerScript.FLASH_LIGHT_RADIUS_SCALE
	light.light_energy = ProjectileServerScript.FLASH_LIGHT_ENERGY_SCALE
	light.shadow_enabled = true
	add_child(light)


## Plays `sound` here once: its files through SoundServer, several in an
## AudioStreamRandomizer, with its attenuation distances.
func play_sound(sound: SoundBase) -> void:
	if sound == null:
		return
	var streams := SoundServer.get_streams(sound)
	if streams.is_empty():
		return
	var player := AudioStreamPlayer3D.new()
	player.name = "Sound"
	if streams.size() == 1:
		player.stream = streams[0]
	else:
		var random := AudioStreamRandomizer.new()
		for stream in streams:
			random.add_stream(-1, stream)
		player.stream = random
	player.unit_size = maxf(sound.minimum_attenuation_distance / UNITS_PER_METRE, 1.0)
	if sound.maximum_attenuation_distance > 0.0:
		player.max_distance = sound.maximum_attenuation_distance / UNITS_PER_METRE
	add_child(player)
	player.play()


## Flies from `from` to `to` at `speed` metres per second, facing along the
## way (its -Z, the model's NIF +Y), then emits arrived and frees itself.
func fly(from: Vector3, to: Vector3, speed: float) -> void:
	flight_from = from
	flight_to = to
	flight_speed = maxf(speed, 0.01)
	_flight_time = 0.0
	lifetime = -1.0
	global_position = from
	face(to - from)


func _process(delta: float) -> void:
	if _model_wait >= 0.0 and _model_wait < MODEL_WAIT_SECONDS:
		_model_wait += delta
		if lifetime >= 0.0:
			return
	if lifetime >= 0.0:
		lifetime -= delta
		if lifetime < 0.0:
			queue_free()
		return
	if flight_speed <= 0.0:
		return
	_flight_time += delta
	var length := flight_from.distance_to(flight_to)
	var travelled := minf(_flight_time * flight_speed, length)
	global_position = flight_from.lerp(flight_to, travelled / length if length > 0.0 else 1.0)
	if travelled >= length:
		flight_speed = 0.0
		arrived.emit()
		queue_free()


## Turns the effect so its -Z faces `direction`.
func face(direction: Vector3) -> void:
	if direction.length() < 0.0001:
		return
	var up := Vector3.UP if absf(direction.normalized().dot(Vector3.UP)) < 0.99 else Vector3.BACK
	global_basis = Basis.looking_at(direction.normalized(), up)


func _on_model_delivered(tree: Node3D, path: String) -> void:
	if tree == null:
		return
	if path != _model_path or not is_inside_tree():
		tree.queue_free()
		return
	FirstPersonViewmodel._strip_physics(tree)
	for mesh: MeshInstance3D in tree.find_children("*", "MeshInstance3D", true, false):
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(tree)
	_model_wait = -1.0
	# NifServer's root is already Y-up: the NIF's +Y (the projectile's
	# forward) is the tree's -Z; `_model_turn` turns a model authored along
	# another axis.
	tree.transform = Transform3D(_model_turn, Vector3.ZERO)
	_play_sequence(tree)


## Plays the model's sequence from its start when it has exactly one: 212 of
## the 263 NIFs under effects folders carry one (Idle, SpecialIdle_AreaEffect,
## Forward); 50 carry several (Forward, Backward, Left, Right), which are
## left still. Only the tracks NifServer builds play (transforms and
## NiVisController visibility); its alpha, colour and texture controllers
## are not built. # ASSUMPTION: an effect plays its only sequence once shown,
## as Gamebryo plays a NIF's sequence by default.
func _play_sequence(tree: Node3D) -> void:
	var player := tree.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if player == null:
		return
	var clips := player.get_animation_list()
	if clips.size() != 1:
		return
	player.play(clips[0])
