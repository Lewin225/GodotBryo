extends Control

## Debug Tools window (game.tscn) -> TabContainer -> "Player" tab.
## Streamlined inspection and tuning of PlayerController properties:
## Noclip (TCL), speeds, jump height, standing/crouch height, mouse sens, and FOV.

const REFRESH_INTERVAL_SEC := 0.1

const DEFAULTS := {
	"base_speed": 4.0,
	"sprint_multiplier": 1.6,
	"crouch_multiplier": 0.5,
	"jump_velocity": 5.5,
	"standing_height": 1.7,
	"crouching_height": 1.2,
	"mouse_sensitivity": 0.003,
	"noclip_speed": 12.0,
	"noclip_sprint_multiplier": 2.5,
	"fov": 75.0,
}

@onready var _status_card: RichTextLabel = $Margin/VBox/StatusCard

# Noclip controls
@onready var _noclip_check: CheckBox = $Margin/VBox/NoclipRow/NoclipCheck
@onready var _noclip_speed_spin: SpinBox = $Margin/VBox/NoclipRow/NoclipSpeedSpin
@onready var _noclip_sprint_spin: SpinBox = $Margin/VBox/NoclipRow/NoclipSprintSpin

# Movement & Jump
@onready var _base_speed_spin: SpinBox = $Margin/VBox/MoveGrid/BaseSpeedSpin
@onready var _sprint_multi_spin: SpinBox = $Margin/VBox/MoveGrid/SprintMultiSpin
@onready var _crouch_multi_spin: SpinBox = $Margin/VBox/MoveGrid/CrouchMultiSpin
@onready var _jump_vel_spin: SpinBox = $Margin/VBox/MoveGrid/JumpVelSpin

# Height & View
@onready var _stand_height_spin: SpinBox = $Margin/VBox/ViewGrid/StandHeightSpin
@onready var _crouch_height_spin: SpinBox = $Margin/VBox/ViewGrid/CrouchHeightSpin
@onready var _mouse_sens_spin: SpinBox = $Margin/VBox/ViewGrid/MouseSensSpin
@onready var _fov_spin: SpinBox = $Margin/VBox/ViewGrid/FovSpin

# Action Buttons
@onready var _reset_defaults_btn: Button = $Margin/VBox/ActionsRow/ResetDefaultsBtn
@onready var _ground_snap_btn: Button = $Margin/VBox/ActionsRow/GroundSnapBtn

var _player: PlayerController
var _refresh_timer := 0.0
var _suppress_signals := false


func _ready() -> void:
	_player = get_tree().root.get_node_or_null("Game/Character") as PlayerController

	_connect_signals()
	_sync_from_player()
	_refresh_status_card()


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return

	_refresh_timer -= delta
	if _refresh_timer <= 0.0:
		_refresh_timer = REFRESH_INTERVAL_SEC
		_refresh_status_card()
		# Keep noclip checkbox synced in case it was toggled via console 'tcl'
		if _player != null and _noclip_check.button_pressed != _player.noclip:
			_suppress_signals = true
			_noclip_check.button_pressed = _player.noclip
			_suppress_signals = false


func _connect_signals() -> void:
	# Noclip
	_noclip_check.toggled.connect(func(enabled: bool) -> void:
		if _suppress_signals or _player == null: return
		_player.noclip = enabled
		_refresh_status_card()
	)
	_noclip_speed_spin.value_changed.connect(func(val: float) -> void:
		if _suppress_signals or _player == null: return
		_player.noclip_speed = val
	)
	_noclip_sprint_spin.value_changed.connect(func(val: float) -> void:
		if _suppress_signals or _player == null: return
		_player.noclip_sprint_multiplier = val
	)

	# Movement & Jump
	_base_speed_spin.value_changed.connect(func(val: float) -> void:
		if _suppress_signals or _player == null: return
		_player.base_speed = val
	)
	_sprint_multi_spin.value_changed.connect(func(val: float) -> void:
		if _suppress_signals or _player == null: return
		_player.sprint_multiplier = val
	)
	_crouch_multi_spin.value_changed.connect(func(val: float) -> void:
		if _suppress_signals or _player == null: return
		_player.crouch_multiplier = val
	)
	_jump_vel_spin.value_changed.connect(func(val: float) -> void:
		if _suppress_signals or _player == null: return
		_player.jump_velocity = val
	)

	# Height & View
	_stand_height_spin.value_changed.connect(func(val: float) -> void:
		if _suppress_signals or _player == null: return
		_player.standing_height = val
	)
	_crouch_height_spin.value_changed.connect(func(val: float) -> void:
		if _suppress_signals or _player == null: return
		_player.crouching_height = val
	)
	_mouse_sens_spin.value_changed.connect(func(val: float) -> void:
		if _suppress_signals or _player == null: return
		_player.mouse_sensitivity = val
	)
	_fov_spin.value_changed.connect(func(val: float) -> void:
		if _suppress_signals or _player == null or _player.camera == null: return
		_player.camera.fov = val
	)

	# Actions
	_reset_defaults_btn.pressed.connect(_reset_to_defaults)
	_ground_snap_btn.pressed.connect(_snap_to_ground)


func _sync_from_player() -> void:
	if _player == null:
		return
	_suppress_signals = true

	_noclip_check.button_pressed = _player.noclip
	_noclip_speed_spin.value = _player.noclip_speed
	_noclip_sprint_spin.value = _player.noclip_sprint_multiplier

	_base_speed_spin.value = _player.base_speed
	_sprint_multi_spin.value = _player.sprint_multiplier
	_crouch_multi_spin.value = _player.crouch_multiplier
	_jump_vel_spin.value = _player.jump_velocity

	_stand_height_spin.value = _player.standing_height
	_crouch_height_spin.value = _player.crouching_height
	_mouse_sens_spin.value = _player.mouse_sensitivity
	if _player.camera != null:
		_fov_spin.value = _player.camera.fov

	_suppress_signals = false


func _reset_to_defaults() -> void:
	if _player == null:
		return
	_player.noclip = false
	_player.noclip_speed = DEFAULTS["noclip_speed"]
	_player.noclip_sprint_multiplier = DEFAULTS["noclip_sprint_multiplier"]
	_player.base_speed = DEFAULTS["base_speed"]
	_player.sprint_multiplier = DEFAULTS["sprint_multiplier"]
	_player.crouch_multiplier = DEFAULTS["crouch_multiplier"]
	_player.jump_velocity = DEFAULTS["jump_velocity"]
	_player.standing_height = DEFAULTS["standing_height"]
	_player.crouching_height = DEFAULTS["crouching_height"]
	_player.mouse_sensitivity = DEFAULTS["mouse_sensitivity"]
	if _player.camera != null:
		_player.camera.fov = DEFAULTS["fov"]
	_sync_from_player()


func _snap_to_ground() -> void:
	if _player == null:
		return
	var space_state := _player.get_world_3d().direct_space_state
	var ray := PhysicsRayQueryParameters3D.create(
		_player.global_position + Vector3(0, 1.0, 0),
		_player.global_position + Vector3(0, -100.0, 0),
		_player.collision_mask
	)
	ray.exclude = [_player.get_rid()]
	var hit := space_state.intersect_ray(ray)
	if not hit.is_empty():
		_player.global_position = hit.position
		_player.velocity = Vector3.ZERO


func _refresh_status_card() -> void:
	if _player == null:
		_status_card.text = "[color=#e06c75]PlayerController node not found in scene tree[/color]"
		return

	var pos := _player.global_position
	var vel := _player.velocity.length()
	var state_str := ""

	if _player.noclip:
		state_str = "[color=#c678dd][b]👻 NOCLIP (FLY)[/b][/color]"
	elif _player.is_grounded:
		state_str = "[color=#98c379][b]🟢 GROUNDED[/b][/color]"
	else:
		state_str = "[color=#e5c07b][b]🟡 AIRBORNE[/b][/color]"

	_status_card.text = "[b]Pos:[/b] [color=#61afef](%.2f, %.2f, %.2f)[/color]   •   [b]Speed:[/b] [color=#e5c07b]%.1f m/s[/color]   •   [b]State:[/b] %s" % [
		pos.x, pos.y, pos.z, vel, state_str
	]
