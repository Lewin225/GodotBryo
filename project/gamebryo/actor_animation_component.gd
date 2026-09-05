@tool
class_name ActorAnimationComponent
extends Node

const MotionDataScript := preload("res://gamebryo/motion_data.gd")

enum ActorAction { EQUIP, UNEQUIP, IDLE, BLOCK, HOLSTER, ATTACK, RELOAD, GRIP }

@export var movement_enabled := true
@export var action_blend_time := 0.0

var equipped_weapon: WeaponRecord = null
var _locomotion_player: AnimationPlayer = null
var _animation_tree: AnimationTree = null
var _facial_player: AnimationPlayer = null
var _weapon_players: Array[AnimationPlayer] = []
var _action_active := false
var _active_action := -1

func _ready() -> void:
	_refresh_layers()

func _refresh_layers() -> void:
	_locomotion_player = null
	_animation_tree = null
	_facial_player = null
	_weapon_players.clear()
	var root := get_parent()
	if root == null:
		return
	for candidate in root.find_children("*", "AnimationPlayer", true, false):
		var player := candidate as AnimationPlayer
		match String(player.name):
			"LocomotionAnimationPlayer": _locomotion_player = player
			"FacialAnimationPlayer": _facial_player = player
			"WeaponAnimationPlayer", "DirectControllerAnimationPlayer": _weapon_players.append(player)
	_animation_tree = root.get_node_or_null(^"AnimationTree") as AnimationTree
	if _animation_tree != null and _locomotion_player != null:
		# The player is generated under Body after this hand-authored component
		# exists. Bind the persistent tree to that actor-local player now.
		_animation_tree.anim_player = _animation_tree.get_path_to(_locomotion_player)
		_animation_tree.active = true
	if _locomotion_player != null and not _locomotion_player.animation_finished.is_connected(_on_locomotion_animation_finished):
		_locomotion_player.animation_finished.connect(_on_locomotion_animation_finished)

func set_equipped_weapon(weapon: WeaponRecord) -> void:
	equipped_weapon = weapon
	_refresh_layers()

func play_default_idle() -> void:
	if _locomotion_player == null:
		return
	if _animation_tree != null:
		_set_blend_position(Vector2.ZERO)
		return
	var clip := _find_clip("mtidle.kf")
	if equipped_weapon != null:
		var weapon_idle := equipped_weapon.action_clip_name("idle")
		if _has_clip(_locomotion_player, weapon_idle):
			clip = weapon_idle
	if not clip.is_empty():
		_locomotion_player.play(clip, action_blend_time)

func set_motion(motion: Resource) -> void:
	if motion == null or not movement_enabled or _locomotion_player == null:
		return
	if _animation_tree != null and _animation_tree.active:
		var planar: Vector3 = motion.get("planar_velocity")
		var direction := Vector2(planar.x, -planar.z)
		if direction.length_squared() < 0.0001:
			direction = Vector2.ZERO
		elif direction.length() > 1.0:
			direction = direction.normalized()
		_set_blend_position(direction)
		return
	var clip := _movement_clip(motion)
	if clip.is_empty():
		_locomotion_player.stop()
		push_warning("ActorAnimationComponent: no authored locomotion clip for motion state")
		return
	if _action_active:
		return
	if _locomotion_player.current_animation != clip:
		_locomotion_player.play(clip, action_blend_time)

func request_action(action: ActorAction) -> bool:
	if _action_active:
		return false
	if equipped_weapon == null or _locomotion_player == null:
		return false
	var action_name := _action_name(action)
	var clip := equipped_weapon.action_clip_name(action_name)
	if clip.is_empty() or not _has_clip(_locomotion_player, clip):
		return false
	_action_active = true
	_active_action = action
	_locomotion_player.play(clip, action_blend_time)
	for player in _weapon_players:
		if is_instance_valid(player) and player.has_animation(clip):
			player.play(clip, action_blend_time)
	return true

func stop_action() -> void:
	if _locomotion_player != null:
		_locomotion_player.stop()
	for player in _weapon_players:
		if is_instance_valid(player):
			player.stop()
	_action_active = false
	_active_action = -1

func is_action_busy() -> bool:
	return _action_active

func _movement_clip(motion: Resource) -> String:
	var planar: Vector3 = motion.get("planar_velocity")
	if planar.length_squared() < 0.0001:
		return _find_clip("locomotion_idle")
	var local := Vector2(planar.x, planar.z)
	var prefix := "locomotion_fast_" if bool(motion.get("sprinting")) else "locomotion_walk_"
	var direction: String
	if absf(local.x) > absf(local.y):
		direction = "right" if local.x > 0.0 else "left"
	else:
		direction = "forward" if local.y < 0.0 else "backward"
	var selected := _find_clip(prefix + direction)
	if selected.is_empty() and prefix != "locomotion_walk_":
		selected = _find_clip("locomotion_walk_" + direction)
	return selected

func _set_blend_position(position: Vector2) -> void:
	if _animation_tree == null:
		return
	_animation_tree.set("parameters/LowerLegLocomotionSpace/blend_position", position)
	_animation_tree.set("parameters/UpperLocomotionSpace/blend_position", position)

func _find_clip(base_name: String) -> String:
	if _locomotion_player == null:
		return ""
	if _locomotion_player.has_animation(base_name):
		return base_name
	for candidate in _locomotion_player.get_animation_list():
		if String(candidate).ends_with("__" + base_name):
			return String(candidate)
	return ""

func _has_clip(player: AnimationPlayer, clip: String) -> bool:
	return player.has_animation(clip)

func _action_name(action: ActorAction) -> String:
	match action:
		ActorAction.EQUIP: return "equip"
		ActorAction.UNEQUIP: return "unequip"
		ActorAction.IDLE: return "idle"
		ActorAction.BLOCK: return "block"
		ActorAction.HOLSTER: return "holster"
		ActorAction.ATTACK: return "attack"
		ActorAction.RELOAD: return "reload"
		ActorAction.GRIP: return "grip"
	return ""

func _on_locomotion_animation_finished(_name: StringName) -> void:
	_action_active = false
	_active_action = -1
