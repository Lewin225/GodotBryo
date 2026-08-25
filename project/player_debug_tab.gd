extends Control

## Debug Tools window (game.tscn) -> TabContainer -> "Player" tab.
## Real-time inspection and live tuning of PlayerController movement,
## jump physics, noclip mode, step hovering, gravity, and camera properties.

const REFRESH_INTERVAL_SEC := 0.1

const DEFAULTS := {
	"base_speed": 4.0,
	"sprint_multiplier": 1.6,
	"crouch_multiplier": 0.5,
	"acceleration": 45.0,
	"deceleration": 35.0,
	"jump_velocity": 5.5,
	"gravity_multiplier": 1.4,
	"auto_jump": true,
	"coyote_time": 0.15,
	"step_height": 0.7,
	"max_floor_angle": 50.0,
	"hover_offset": 0.6,
	"mouse_sensitivity": 0.003,
	"camera_eye_height": 1.5,
	"noclip_speed": 12.0,
	"noclip_sprint_multiplier": 2.5,
	"fov": 75.0,
}

@onready var _status_card: RichTextLabel = $Margin/VBox/StatusCard

# Noclip controls
@onready var _noclip_check: CheckBox = $Margin/VBox/NoclipRow/NoclipCheck
@onready var _noclip_speed_spin: SpinBox = $Margin/VBox/NoclipRow/NoclipSpeedSpin
@onready var _noclip_sprint_spin: SpinBox = $Margin/VBox/NoclipRow/NoclipSprintSpin

# Movement parameters
@onready var _base_speed_spin: SpinBox = $Margin/VBox/MoveGrid/BaseSpeedSpin
@onready var _sprint_multi_spin: SpinBox = $Margin/VBox/MoveGrid/SprintMultiSpin
@onready var _crouch_multi_spin: SpinBox = $Margin/VBox/MoveGrid/CrouchMultiSpin
@onready var _accel_spin: SpinBox = $Margin/VBox/MoveGrid/AccelSpin
@onready var _decel_spin: SpinBox = $Margin/VBox/MoveGrid/DecelSpin

# Jump & Gravity
@onready var _jump_vel_spin: SpinBox = $Margin/VBox/JumpGrid/JumpVelSpin
@onready var _gravity_multi_spin: SpinBox = $Margin/VBox/JumpGrid/GravityMultiSpin
@onready var _coyote_spin: SpinBox = $Margin/VBox/JumpGrid/CoyoteSpin
@onready var _auto_jump_check: CheckBox = $Margin/VBox/JumpGrid/AutoJumpCheck

# Step & Slope
@onready var _step_height_spin: SpinBox = $Margin/VBox/StepGrid/StepHeightSpin
@onready var _max_angle_spin: SpinBox = $Margin/VBox/StepGrid/MaxAngleSpin
@onready var _hover_offset_spin: SpinBox = $Margin/VBox/StepGrid/HoverOffsetSpin

# Look & Camera
@onready var _mouse_sens_spin: SpinBox = $Margin/VBox/CameraGrid/MouseSensSpin
@onready var _eye_height_spin: SpinBox = $Margin/VBox/CameraGrid/EyeHeightSpin
@onready var _fov_spin: SpinBox = $Margin/VBox/CameraGrid/FovSpin

# Buttons
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
	_accel_spin.value_changed.connect(func(val: float) -> void:
		if _suppress_signals or _player == null: return
		_player.acceleration = val
	)
	_decel_spin.value_changed.connect(func(val: float) -> void:
		if _suppress_signals or _player == null: return
		_player.deceleration = val
	)

	_jump_vel_spin.value_changed.connect(func(val: float) -> void:
		if _suppress_signals or _player == null: return
		_player.jump_velocity = val
	)
	_gravity_multi_spin.value_changed.connect(func(val: float) -> void:
		if _suppress_signals or _player == null: return
		_player.gravity_multiplier = val
	)
	_coyote_spin.value_changed.connect(func(val: float) -> void:
		if _suppress_signals or _player == null: return
		_player.coyote_time = val
	)
	_auto_jump_check.toggled.connect(func(enabled: bool) -> void:
		if _suppress_signals or _player == null: return
		_player.auto_jump = enabled
	)

	_step_height_spin.value_changed.connect(func(val: float) -> void:
		if _suppress_signals or _player == null: return
		_player.step_height = val
	)
	_max_angle_spin.value_changed.connect(func(val: float) -> void:
		if _suppress_signals or _player == null: return
		_player.max_floor_angle = val
	)
	_hover_offset_spin.value_changed.connect(func(val: float) -> void:
		if _suppress_signals or _player == null: return
		_player.hover_offset = val
	)

	_mouse_sens_spin.value_changed.connect(func(val: float) -> void:
		if _suppress_signals or _player == null: return
		_player.mouse_sensitivity = val
	)
	_eye_height_spin.value_changed.connect(func(val: float) -> void:
		if _suppress_signals or _player == null: return
		_player.camera_eye_height = val
	)
	_fov_spin.value_changed.connect(func(val: float) -> void:
		if _suppress_signals or _player == null or _player.camera == null: return
		_player.camera.fov = val
	)

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
	_accel_spin.value = _player.acceleration
	_decel_spin.value = _player.deceleration

	_jump_vel_spin.value = _player.jump_velocity
	_gravity_multi_spin.value = _player.gravity_multiplier
	_coyote_spin.value = _player.coyote_time
	_auto_jump_check.button_pressed = _player.auto_jump

	_step_height_spin.value = _player.step_height
	_max_angle_spin.value = _player.max_floor_angle
	_hover_offset_spin.value = _player.hover_offset

	_mouse_sens_spin.value = _player.mouse_sensitivity
	_eye_height_spin.value = _player.camera_eye_height
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
	_player.acceleration = DEFAULTS["acceleration"]
	_player.deceleration = DEFAULTS["deceleration"]
	_player.jump_velocity = DEFAULTS["jump_velocity"]
	_player.gravity_multiplier = DEFAULTS["gravity_multiplier"]
	_player.auto_jump = DEFAULTS["auto_jump"]
	_player.coyote_time = DEFAULTS["coyote_time"]
	_player.step_height = DEFAULTS["step_height"]
	_player.max_floor_angle = DEFAULTS["max_floor_angle"]
	_player.hover_offset = DEFAULTS["hover_offset"]
	_player.mouse_sensitivity = DEFAULTS["mouse_sensitivity"]
	_player.camera_eye_height = DEFAULTS["camera_eye_height"]
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
