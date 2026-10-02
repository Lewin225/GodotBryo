class_name PlayerController
extends CharacterBody3D

const MotionDataScript := preload("res://gamebryo/motion_data.gd")

# --- Input Action Mappings ---
@export_group("Input Actions")
## Dictionary mapping control actions to InputMap action StringNames.
@export var input_actions: Dictionary = {
	"move_left": &"left",
	"move_right": &"right",
	"move_forward": &"forward",
	"move_backward": &"backward",
	"jump": &"jump",
	"sprint": &"sprint",
	"crouch": &"crouch",
	"zoom": &"zoom",
}

@export_group("Mouse & Look")
@export var mouse_sensitivity: float = 0.003
@export_range(10.0, 89.0) var pitch_limit_degrees: float = 89.0
@export var handle_mouse_capture:bool = false
@export var capture_mouse_on_start: bool = true

# --- Movement Parameters ---
@export_group("Movement")
## Base target walk speed in meters/second.
@export var base_speed: float = 4.0
## Acceleration rate to reach target speed.
@export var acceleration: float = 45.0
## Deceleration rate when stopping.
@export var deceleration: float = 35.0
@export var sprint_multiplier: float = 1.6
@export var crouch_multiplier: float = 0.5
@export var air_control_multiplier: float = 0.2
@export var jump_velocity: float = 5.5
## Whether holding the jump button automatically jumps continuously as soon as grounded.
@export var auto_jump: bool = true
## Grace period (in seconds) after leaving a ledge where jumping is still permitted.
@export var coyote_time: float = 0.15
@export var max_ground_velocity: float = 30.0
@export var ground_snap_velocity: float = -2.0

@export_group("Noclip & Cheats")
@export var noclip: bool = false:
	set(val):
		noclip = val
		if collision_shape:
			collision_shape.disabled = noclip
		if _shape_cast:
			_shape_cast.enabled = !noclip
		if noclip:
			velocity = Vector3.ZERO
			is_grounded = false
@export var noclip_speed: float = 12.0
@export var noclip_sprint_multiplier: float = 2.5

@export_group("Step & Hovering")
## How far above the true ground the capsule bottom floats to step over obstacles.
@export var hover_offset: float = 0.6
## Maximum step up scan range while walking.
@export var step_height: float = 0.7
## Maximum step down scan range while walking before detaching and falling naturally.
@export var step_down_height: float = 0.3
## Maximum slope angle (in degrees) to consider as walkable without sliding.
@export_range(1.0, 89.0) var max_floor_angle: float = 50.0:
	set(val):
		max_floor_angle = val
		floor_max_angle = deg_to_rad(max_floor_angle)
## Visual camera dip depth (in meters) when wedged across a gap/crevice.
@export var bridge_dip_offset: float = 0.15

@export_group("Crouching")
## Height of capsule standing vs crouching.
@export var standing_height: float = 1.7
@export var crouching_height: float = 1.2

@export_group("Camera Base")
## Vertical (Y) camera follow speed — keep high for crisp step/crouch response.
@export var camera_follow_speed: float = 25.0
## Horizontal (X/Z) camera follow speed — lower values smooth out lateral jitter.
@export var camera_xz_follow_speed: float = 14.0
@export var camera_aim_smooth_speed: float = 40.0
@export var camera_eye_height: float = 1.5

@export_group("Camera Procedural Animation")
## Sine wave head-bob frequency multiplier.
@export var bob_frequency: float = 12.0
## Vertical head-bob amplitude in meters.
@export var bob_vertical_amplitude: float = 0.02
## Horizontal head-bob amplitude in meters.
@export var bob_horizontal_amplitude: float = 0.02
## Maximum camera roll angle when strafing (in degrees).
@export_range(0.0, 15.0) var strafe_lean_degrees: float = 1.25
## Maximum camera pitch angle when accelerating/braking (in degrees).
@export_range(0.0, 15.0) var accel_lean_degrees: float = 0.2
## Smoothing speed for camera leaning transitions.
@export var lean_smooth_speed: float = 20.0
## Decay speed for applied camera trauma/shake.
@export var shake_decay_speed: float = 4.0
## Positional displacement multiplier for camera shake.
@export var shake_pos_strength: float = 0.08
## Rotational displacement multiplier for camera shake (in radians).
@export var shake_rot_strength: float = 0.05
@export var debug_click_shake: bool = false

@export_group("Push Physics")
@export var push_force: float = 100.0

@export_group("Required Nodes")
@export var collision_shape: CollisionShape3D
@export var camera: Camera3D
@export var interact_ray: InteractRay
## Player-facing UI. The message box presents ScriptServer's ShowMessage; the
## terminal session opens while the possessed actor uses an unlocked terminal;
## the unlock session while it uses a locked terminal or door.
@export var message_box: MessageBox
@export var terminal_session: TerminalSession
@export var unlock_session: UnlockSession
## HUD label announcing a newly granted quest.
@export var quest_notice: Label
## HUD label showing the response being said (DialogueServer).
@export var subtitle: Label
## Name entry menu (GetPlayerName).
@export var name_menu: NameMenu
## Race menu (ShowRaceMenu).
@export var race_menu: RaceMenu
## Conversation screen (DialogueServer conversations with the player).
@export var dialogue_session: DialogueSession

const LOCK_LEVEL_NAMES := ["Very Easy", "Easy", "Average", "Hard", "Very Hard"]

@export_group("Actor")
## Visual actor owned by this controller. The controller supplies movement
## state; the actor remains responsible for rendering and animation playback.
@export var actor: EsmHumanoidActor
@export var drive_actor_animation: bool = true
@export var motion_data: MotionData = MotionData.new()

## Compatibility alias for code expecting CAMERA in uppercase
var CAMERA: Camera3D:
	get:
		return camera

# --- Internal Procedural ShapeCast & RayCast Objects ---
var _shape_cast: ShapeCast3D
var _ray_query: PhysicsRayQueryParameters3D
var _ceiling_shape_query: PhysicsShapeQueryParameters3D
var _ceiling_cylinder: CylinderShape3D

# --- State Variables ---
var is_grounded: bool = false
var is_bridged: bool = false
var is_on_steep_slope: bool = false
var ground_normal: Vector3 = Vector3.UP
var is_crouching: bool = false
var is_sprinting: bool = false
var is_teleporting: bool = false
var _jump_cooldown_timer: float = 0.0
var _coyote_timer: float = 0.0
var _actor_animation: ActorAnimationComponent = null

var knocked_timer_ms: int = 0
var aim_smooth: Vector3 = Vector3.ZERO
var camera_lerp_position: Vector3 = Vector3.ZERO
var camera_pitch: float = 0.0
var gravity_project: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var gravity_multiplier: float = 1.4:
	set(val):
		gravity_multiplier = val
		gravity = gravity_project * gravity_multiplier
@onready var gravity: float = gravity_project * gravity_multiplier

# --- Camera Animation State Variables ---
var _bob_timer: float = 0.0
var _camera_trauma: float = 0.0
var _current_roll_lean: float = 0.0
var _current_pitch_lean: float = 0.0
var _current_bridge_dip: float = 0.0
var _noise_seed: float = 0.0
@warning_ignore("unused_private_class_variable")
var _click_shake_index: int = 0
const CLICK_SHAKE_PATTERN: Array[float] = [0.5, 1.0, 2.0, 3.0, 4.0]


func toggle_noclip() -> bool:
	noclip = !noclip
	return noclip


## Seconds a "Quest Added" notice stays on screen.
const QUEST_NOTICE_SECONDS := 4.0
var _quest_notice_generation := 0
var _subtitle_line: DialogueLine = null # the line the subtitle shows

func _ready() -> void:
	slide_on_ceiling = false
	var quest_server := get_tree().root.get_node_or_null("QuestServer")
	if quest_server != null and not quest_server.quest_granted.is_connected(_on_quest_granted):
		quest_server.quest_granted.connect(_on_quest_granted)
	if quest_notice != null:
		quest_notice.hide()
	var dialogue := get_tree().root.get_node_or_null("DialogueServer")
	if dialogue != null and not dialogue.response_started.is_connected(_on_response_started):
		dialogue.response_started.connect(_on_response_started)
		dialogue.line_finished.connect(_on_line_finished)
		dialogue.conversation_started.connect(_on_conversation_started)
		dialogue.conversation_ended.connect(_on_conversation_ended)
	if subtitle != null:
		subtitle.hide()
	floor_max_angle = deg_to_rad(max_floor_angle)

	if capture_mouse_on_start and handle_mouse_capture:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	if not collision_shape:
		collision_shape = get_node_or_null("CollisionShape3D")
	if not camera:
		camera = get_node_or_null("Camera3D")
	if actor == null:
		actor = get_node_or_null("EsmHumanoidActor") as EsmHumanoidActor
	if actor != null:
		actor.load_actor()

	if collision_shape and collision_shape.shape is CapsuleShape3D:
		var cap := collision_shape.shape as CapsuleShape3D
		cap.height = standing_height
		collision_shape.position.y = (standing_height * 0.5) + hover_offset

	_shape_cast = ShapeCast3D.new()
	var sweep_cylinder := CylinderShape3D.new()
	sweep_cylinder.radius = 0.32
	sweep_cylinder.height = 0.15
	_shape_cast.shape = sweep_cylinder
	_shape_cast.collision_mask = collision_mask
	_shape_cast.add_exception(self)
	_shape_cast.max_results = 6
	_shape_cast.collide_with_areas = false
	_shape_cast.collide_with_bodies = true
	_shape_cast.position = Vector3(0.0, hover_offset + 0.1, 0.0)
	add_child(_shape_cast)

	_ray_query = PhysicsRayQueryParameters3D.new()
	_ray_query.collision_mask = collision_mask
	_ray_query.exclude = [get_rid()]
	_ray_query.collide_with_bodies = true
	_ray_query.collide_with_areas = false

	_ceiling_cylinder = CylinderShape3D.new()
	_ceiling_shape_query = PhysicsShapeQueryParameters3D.new()
	_ceiling_shape_query.collision_mask = collision_mask
	_ceiling_shape_query.exclude = [get_rid()]
	_ceiling_shape_query.collide_with_bodies = true
	_ceiling_shape_query.collide_with_areas = false
	_ceiling_shape_query.shape = _ceiling_cylinder

	if camera:
		camera_lerp_position = global_position + Vector3(0, camera_eye_height, 0)
		_noise_seed = randf() * 100.0


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"interact"):
		request_activate()
		return
	if debug_click_shake and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		return
		# Incedibly annoying
		#var shake_val := CLICK_SHAKE_PATTERN[_click_shake_index]
		#apply_camera_shake(shake_val)
		#_click_shake_index = (_click_shake_index + 1) % CLICK_SHAKE_PATTERN.size()

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotation.y -= event.relative.x * mouse_sensitivity
		var max_pitch := deg_to_rad(pitch_limit_degrees)
		camera_pitch = clampf(camera_pitch - (event.relative.y * mouse_sensitivity), -max_pitch, max_pitch)


func _process(delta: float) -> void:
	if is_teleporting or not camera:
		return
	_update_camera_transform(delta)


func _physics_process(delta: float) -> void:
	_sync_possessed()
	if is_teleporting:
		is_teleporting = false
		_publish_actor_motion()
		return

	if noclip:
		_handle_noclip_movement(delta)
		_publish_actor_motion()
		return

	if _jump_cooldown_timer > 0.0:
		_jump_cooldown_timer -= delta

	var space_state := get_world_3d().direct_space_state
	_apply_gravity_and_grounding(delta)

	if is_grounded and not is_on_steep_slope:
		_coyote_timer = coyote_time
	else:
		_coyote_timer = maxf(0.0, _coyote_timer - delta)

	_handle_movement(delta)
	_handle_crouching(space_state)

	move_and_slide()
	_apply_push_forces(delta)
	_publish_actor_motion()


func _publish_actor_motion() -> void:
	if not drive_actor_animation or actor == null:
		return
	if motion_data == null:
		motion_data = MotionDataScript.new()
	# MotionData is consumed in actor-local space so forward/strafe clips stay
	# correct while the controller turns. Keep the controller's world velocity
	# available separately if a future consumer needs it.
	var actor_local_velocity := global_transform.basis.inverse() * velocity
	motion_data.update_from_velocity(actor_local_velocity, is_grounded)
	motion_data.crouched = is_crouching
	motion_data.sprinting = is_sprinting
	if _actor_animation == null and is_instance_valid(actor):
		_actor_animation = actor.get_node_or_null("ActorAnimationComponent") as ActorAnimationComponent
	if _actor_animation != null:
		_actor_animation.set_motion(motion_data)


func _handle_noclip_movement(delta: float) -> void:
	var left_action: StringName = input_actions.get("move_left", &"left")
	var right_action: StringName = input_actions.get("move_right", &"right")
	var forward_action: StringName = input_actions.get("move_forward", &"forward")
	var backward_action: StringName = input_actions.get("move_backward", &"backward")
	var jump_action: StringName = input_actions.get("jump", &"jump")
	var crouch_action: StringName = input_actions.get("crouch", &"crouch")
	var sprint_action: StringName = input_actions.get("sprint", &"sprint")

	if not InputMap.has_action(left_action): left_action = &"ui_left"
	if not InputMap.has_action(right_action): right_action = &"ui_right"
	if not InputMap.has_action(forward_action): forward_action = &"ui_up"
	if not InputMap.has_action(backward_action): backward_action = &"ui_down"
	if not InputMap.has_action(jump_action): jump_action = &"ui_accept"
	if not InputMap.has_action(crouch_action): crouch_action = &"ui_cancel"

	var input_vector := Input.get_vector(left_action, right_action, forward_action, backward_action)
	var vertical_input := 0.0
	if Input.is_action_pressed(jump_action):
		vertical_input += 1.0
	if InputMap.has_action(crouch_action) and Input.is_action_pressed(crouch_action):
		vertical_input -= 1.0

	var cam_basis := camera.global_transform.basis if camera else global_transform.basis
	var move_dir := (cam_basis.x * input_vector.x + cam_basis.z * input_vector.y + Vector3.UP * vertical_input)
	if move_dir.length_squared() > 1.0:
		move_dir = move_dir.normalized()

	var is_fast := InputMap.has_action(sprint_action) and Input.is_action_pressed(sprint_action)
	var cur_speed := noclip_speed * (noclip_sprint_multiplier if is_fast else 1.0)

	velocity = move_dir * cur_speed
	global_position += velocity * delta


# --- Movement & Slope Physics ---

func _handle_movement(delta: float) -> void:
	var left_action: StringName = input_actions.get("move_left", &"left")
	var right_action: StringName = input_actions.get("move_right", &"right")
	var forward_action: StringName = input_actions.get("move_forward", &"forward")
	var backward_action: StringName = input_actions.get("move_backward", &"backward")

	# Fallbacks if project only has ui_ actions
	if not InputMap.has_action(left_action): left_action = &"ui_left"
	if not InputMap.has_action(right_action): right_action = &"ui_right"
	if not InputMap.has_action(forward_action): forward_action = &"ui_up"
	if not InputMap.has_action(backward_action): backward_action = &"ui_down"

	var input_vector := Input.get_vector(left_action, right_action, forward_action, backward_action)
	var move_direction := (transform.basis * Vector3(input_vector.x, 0.0, input_vector.y)).normalized()

	var jump_action: StringName = input_actions.get("jump", &"jump")
	if not InputMap.has_action(jump_action): jump_action = &"ui_accept"
	var jump_requested: bool = Input.is_action_pressed(jump_action) if auto_jump else Input.is_action_just_pressed(jump_action)
	var can_jump: bool = (is_grounded or _coyote_timer > 0.0) and not is_on_steep_slope and _jump_cooldown_timer <= 0.0

	if jump_requested and can_jump:
		velocity.y = jump_velocity
		is_grounded = false
		_coyote_timer = 0.0
		_jump_cooldown_timer = 0.15
		apply_camera_shake(0.2)

	var sprint_action: StringName = input_actions.get("sprint", &"sprint")
	is_sprinting = InputMap.has_action(sprint_action) and Input.is_action_pressed(sprint_action) and input_vector.y < 0.0

	var speed_multi := crouch_multiplier if is_crouching else (sprint_multiplier if is_sprinting else 1.0)
	var target_vel := move_direction * (base_speed * speed_multi)

	var has_full_traction := is_grounded and not is_on_steep_slope
	var accel_rate := acceleration if move_direction != Vector3.ZERO else deceleration

	if not has_full_traction:
		accel_rate *= air_control_multiplier

	# Natural Slope Deflection
	if is_grounded and is_on_steep_slope:
		var uphill := Vector3(-ground_normal.x, 0.0, -ground_normal.z).normalized()
		if target_vel.dot(uphill) > 0.0:
			target_vel -= uphill * target_vel.dot(uphill)

	velocity.x = move_toward(velocity.x, target_vel.x, accel_rate * delta)
	velocity.z = move_toward(velocity.z, target_vel.z, accel_rate * delta)


func _apply_gravity_and_grounding(delta: float) -> void:
	var was_grounded := is_grounded
	var hit_info := _query_ground_swept(delta)

	is_grounded = hit_info.is_valid
	is_bridged = hit_info.get("is_bridged", false)
	is_on_steep_slope = hit_info.get("is_steep", false)
	ground_normal = hit_info.get("normal", Vector3.UP)

	if is_grounded:
		if not was_grounded and not is_on_steep_slope:
			_handle_landing()

		if is_on_steep_slope:
			# Downhill acceleration on non-walkable slopes
			var down_slope := (Vector3.DOWN - ground_normal * Vector3.DOWN.dot(ground_normal)).normalized()
			var slope_sine := sqrt(maxf(0.0, 1.0 - (ground_normal.dot(Vector3.UP) * ground_normal.dot(Vector3.UP))))
			var slide_accel := gravity * slope_sine

			velocity += down_slope * slide_accel * delta
		else:
			# Walkable ground handling (both flat and sloped)
			var target_y: float = hit_info.position.y
			var is_sloped := ground_normal.dot(Vector3.UP) < 0.98

			if is_sloped:
				# On angled terrain, match height to ground surface smoothly
				global_position.y = move_toward(global_position.y, target_y, (base_speed * 2.5 + absf(velocity.length())) * delta)
				velocity.y = ground_snap_velocity
			else:
				# On flat steps, snap directly to maintain crisp ledge/stair attachment
				global_position.y = target_y
				velocity.y = ground_snap_velocity
	else:
		var effective_gravity := (gravity * 0.8) if velocity.y >= 0.0 else gravity
		velocity.y -= effective_gravity * delta


func _query_ground_swept(delta: float) -> Dictionary:
	if is_teleporting or velocity.length() > max_ground_velocity:
		return {"is_valid": false}
	if knocked_timer_ms + 300 > Time.get_ticks_msec():
		return {"is_valid": false}

	if _jump_cooldown_timer > 0.0:
		return {"is_valid": false}

	var min_dot := cos(deg_to_rad(max_floor_angle))
	var space_state := get_world_3d().direct_space_state

	var cast_start_y_offset := hover_offset + 0.1
	var ray_start_y := global_position.y + cast_start_y_offset
	var down_reach := step_down_height if is_grounded else maxf(absf(velocity.y) * delta + 0.1, 0.15)
	var ray_target_y := global_position.y - down_reach

	# 1. PRIMARY: Center Raycast
	_ray_query.from = Vector3(global_position.x, ray_start_y, global_position.z)
	_ray_query.to = Vector3(global_position.x, ray_target_y, global_position.z)

	var center_hit := space_state.intersect_ray(_ray_query)
	if not center_hit.is_empty():
		var normal: Vector3 = center_hit.normal
		if normal.dot(Vector3.UP) > 0.05:
			var is_steep := normal.dot(Vector3.UP) < min_dot
			return {
				"is_valid": true,
				"position": center_hit.position,
				"normal": normal,
				"is_steep": is_steep,
				"is_bridged": false
			}

	# 2. SECONDARY: Swept ShapeCast
	_shape_cast.position = Vector3(0.0, cast_start_y_offset, 0.0)
	_shape_cast.target_position = Vector3(0.0, -(cast_start_y_offset + down_reach), 0.0)
	_shape_cast.force_shapecast_update()

	if _shape_cast.is_colliding():
		var count := _shape_cast.get_collision_count()
		var highest_y := -INF
		var best_pos := Vector3.ZERO
		var best_normal := Vector3.UP
		var found_surface := false

		var normal_sum := Vector3.ZERO
		var surface_count := 0

		for i in count:
			var normal := _shape_cast.get_collision_normal(i)
			var point := _shape_cast.get_collision_point(i)
			var up_dot := normal.dot(Vector3.UP)

			if up_dot <= 0.05:
				continue

			normal_sum += normal
			surface_count += 1

			if point.y > highest_y:
				highest_y = point.y
				best_pos = point
				best_normal = normal
				found_surface = true

		if found_surface:
			var is_bridged_hit := (surface_count >= 2 and normal_sum.normalized().dot(Vector3.UP) >= min_dot and best_normal.dot(Vector3.UP) < min_dot)
			var is_steep_hit := best_normal.dot(Vector3.UP) < min_dot and not is_bridged_hit

			return {
				"is_valid": true,
				"position": best_pos,
				"normal": best_normal,
				"is_steep": is_steep_hit,
				"is_bridged": is_bridged_hit
			}

	# 3. TERTIARY: Direct Slide Collisions from move_and_slide()
	if is_grounded:
		for i in get_slide_collision_count():
			var col := get_slide_collision(i)
			var normal := col.get_normal()
			if normal.dot(Vector3.UP) > 0.05:
				return {
					"is_valid": true,
					"position": col.get_position(),
					"normal": normal,
					"is_steep": normal.dot(Vector3.UP) < min_dot,
					"is_bridged": false
				}

	return {"is_valid": false}


func _handle_crouching(space_state: PhysicsDirectSpaceState3D) -> void:
	if not collision_shape or not collision_shape.shape is CapsuleShape3D:
		return

	var crouch_action: StringName = input_actions.get("crouch", &"crouch")
	var duck_requested := InputMap.has_action(crouch_action) and Input.is_action_pressed(crouch_action)

	# Only allow transitions between crouching and standing while grounded
	if is_grounded:
		var ceiling_blocked := false

		if not duck_requested and is_crouching:
			var cap := collision_shape.shape as CapsuleShape3D
			var r: float = cap.radius * 0.75
			# Ray origin starts deep inside the crouching capsule (waist level, ~40% height)
			var crouch_mid_y: float = global_position.y + hover_offset + (crouching_height * 0.4)
			var stand_top_y: float = global_position.y + hover_offset + standing_height + 0.05

			# 1. Multi-ray checks (center + 4 perimeter points) to catch overhangs/beams
			var ray_offsets: Array[Vector3] = [
				Vector3.ZERO,
				Vector3(r, 0.0, 0.0),
				Vector3(-r, 0.0, 0.0),
				Vector3(0.0, 0.0, r),
				Vector3(0.0, 0.0, -r)
			]
			for offset in ray_offsets:
				_ray_query.from = Vector3(global_position.x + offset.x, crouch_mid_y, global_position.z + offset.z)
				_ray_query.to = Vector3(global_position.x + offset.x, stand_top_y, global_position.z + offset.z)
				if not space_state.intersect_ray(_ray_query).is_empty():
					ceiling_blocked = true
					break

			# 2. Volumetric shape test in the expansion headroom
			if not ceiling_blocked:
				var headroom: float = maxf(0.1, standing_height - crouching_height)
				_ceiling_cylinder.radius = maxf(0.1, cap.radius - 0.04)
				_ceiling_cylinder.height = headroom
				var headroom_center_y: float = global_position.y + hover_offset + crouching_height + (headroom * 0.5)
				_ceiling_shape_query.transform = Transform3D(Basis.IDENTITY, Vector3(global_position.x, headroom_center_y, global_position.z))
				var hits := space_state.intersect_shape(_ceiling_shape_query, 1)
				if not hits.is_empty():
					ceiling_blocked = true

		is_crouching = duck_requested or ceiling_blocked

	var shape := collision_shape.shape as CapsuleShape3D
	var target_height := crouching_height if is_crouching else standing_height
	if shape.height != target_height:
		shape.height = target_height
		collision_shape.position.y = (target_height * 0.5) + hover_offset


func _handle_landing() -> void:
	var fall_speed := absf(velocity.y)
	if fall_speed > 3.0:
		var trauma_amount := clampf((fall_speed - 3.0) / 12.0, 0.1, 0.8)
		apply_camera_shake(trauma_amount)


func _apply_push_forces(delta: float) -> void:
	for i in get_slide_collision_count():
		var col := get_slide_collision(i)
		var rigid_body := col.get_collider() as RigidBody3D
		if is_instance_valid(rigid_body):
			var impulse_point := col.get_position() - rigid_body.global_position
			rigid_body.apply_impulse(-col.get_normal() * push_force * delta, impulse_point)


# --- Camera Transform, Smoothing & Procedural Dynamics ---

func _update_camera_transform(delta: float) -> void:
	var zoom_action: StringName = input_actions.get("zoom", &"zoom")
	var zoom_active := InputMap.has_action(zoom_action) and Input.is_action_pressed(zoom_action)
	var target_aim := Vector3(camera_pitch, rotation.y, 0.0)
	aim_smooth = lerp(aim_smooth, target_aim, clampf(delta * camera_aim_smooth_speed, 0.0, 1.0)) if zoom_active else target_aim

	camera.fov = lerpf(camera.fov, (75.0-(float(zoom_active)*50)), delta*5)

	# 1. Base Positional Follow & Smoothing (with dynamic Bridge Dip)
	var current_height := crouching_height if is_crouching else standing_height

	# Use Godot's built-in physics interpolation (requires Physics Interpolation
	# enabled in Project Settings) so the camera target advances sub-frame smoothly
	# rather than stepping at the physics tick rate.
	var interp_transform := get_global_transform_interpolated()
	var interp_pos := interp_transform.origin

	var eye_y: float
	if collision_shape and not noclip:
		var interp_cs := collision_shape.get_global_transform_interpolated()
		eye_y = (interp_cs.origin.y + (current_height * 0.5)) - 0.5
	else:
		eye_y = interp_pos.y + camera_eye_height

	var target_dip := bridge_dip_offset if is_bridged else 0.0
	_current_bridge_dip = lerpf(_current_bridge_dip, target_dip, clampf(delta * 12.0, 0.0, 1.0))
	eye_y -= _current_bridge_dip

	var target_pos := Vector3(interp_pos.x, eye_y, interp_pos.z)

	# Decouple horizontal and vertical smoothing:
	# Y follows quickly so steps and crouching snap cleanly;
	# X/Z follows slowly to dampen residual jitter.
	var xz_t: float = clampf(delta * camera_xz_follow_speed, 0.0, 1.0)
	var y_t: float = clampf(delta * camera_follow_speed, 0.0, 1.0)
	camera_lerp_position.x = lerpf(camera_lerp_position.x, target_pos.x, xz_t)
	camera_lerp_position.z = lerpf(camera_lerp_position.z, target_pos.z, xz_t)
	camera_lerp_position.y = lerpf(camera_lerp_position.y, target_pos.y, y_t)

	# 2. Procedural Sine-Wave Head-Bobbing
	var planar_speed := Vector2(velocity.x, velocity.z).length()
	var bob_offset := Vector3.ZERO

	if is_grounded and not is_on_steep_slope and planar_speed > 0.1:
		var speed_factor := planar_speed / base_speed
		_bob_timer += delta * bob_frequency * speed_factor
		bob_offset.y = sin(_bob_timer) * (bob_vertical_amplitude * speed_factor)
		bob_offset.x = cos(_bob_timer * 0.5) * (bob_horizontal_amplitude * speed_factor)
	else:
		_bob_timer = move_toward(_bob_timer, 0.0, delta * 5.0)

	# 3. Dynamic Rotational Leaning
	var local_vel := transform.basis.inverse() * velocity
	var target_roll := -deg_to_rad(strafe_lean_degrees) * (local_vel.x / base_speed)
	var target_pitch := deg_to_rad(accel_lean_degrees) * (local_vel.z / base_speed)

	_current_roll_lean = lerpf(_current_roll_lean, target_roll, clampf(delta * lean_smooth_speed, 0.0, 1.0))
	_current_pitch_lean = lerpf(_current_pitch_lean, target_pitch, clampf(delta * lean_smooth_speed, 0.0, 1.0))

	# 4. Dynamic Trauma Shake
	var shake_pos := Vector3.ZERO
	var shake_rot := Vector3.ZERO

	if _camera_trauma > 0.0:
		var shake_amount := _camera_trauma * _camera_trauma
		shake_amount = clampf(shake_amount, 0.0, 5.0)
		var time := Time.get_ticks_msec() * 0.02

		shake_pos = Vector3(
			sin(time * 1.1 + _noise_seed) * shake_pos_strength * shake_amount,
			cos(time * 1.3 + _noise_seed) * shake_pos_strength * shake_amount,
			sin(time * 0.9 + _noise_seed) * (shake_pos_strength * 0.5) * shake_amount
		)
		shake_rot = Vector3(
			sin(time * 1.2 + _noise_seed) * shake_rot_strength * shake_amount,
			cos(time * 0.8 + _noise_seed) * shake_rot_strength * shake_amount,
			sin(time * 1.4 + _noise_seed) * shake_rot_strength * shake_amount
		)

		_camera_trauma = maxf(_camera_trauma - (delta * shake_decay_speed), 0.0)

	# 5. Composite Final Camera Transform
	var rotated_bob := bob_offset.rotated(Vector3.UP, rotation.y)
	camera.global_position = camera_lerp_position + rotated_bob + shake_pos
	camera.global_rotation = Vector3(
		aim_smooth.x + _current_pitch_lean + shake_rot.x,
		aim_smooth.y + shake_rot.y,
		_current_roll_lean + shake_rot.z
	)


# --- Public Interface ---

## The actor this controller possesses. Its reference is where the player is:
## the body writes its position and heading to it every physics frame, and a
## teleport of it moves the body (TransitionCoordinator).
var possessed: ActorReference = null
## While frozen the body neither moves nor writes to `possessed`.
var frozen := false
## While a UI has focus the body neither moves nor takes look/interact input.
var _input_suspended := false

## Takes control of `actor`: scripts' `player` becomes its reference, and
## body-level commands act on this body.
func possess(actor_reference: ActorReference) -> void:
	if possessed != null and possessed.using_changed.is_connected(_on_using_changed):
		possessed.using_changed.disconnect(_on_using_changed)
	possessed = actor_reference
	if possessed != null:
		possessed.using_changed.connect(_on_using_changed)
	ScriptServer.player_reference = actor_reference
	ScriptServer.player_node = self
	ScriptServer.message_box = message_box
	ScriptServer.menu_opener = _open_script_menu
	_connect_ui()

## Shows "Quest Added: <name>" for QUEST_NOTICE_SECONDS; a newer notice
## replaces an older one.
func _on_quest_granted(quest: QuestBase) -> void:
	if quest_notice == null:
		return
	quest_notice.text = "Quest Added: %s" % (quest.full_name if not quest.full_name.is_empty() else quest.editor_id)
	quest_notice.show()
	_quest_notice_generation += 1
	var generation := _quest_notice_generation
	await get_tree().create_timer(QUEST_NOTICE_SECONDS).timeout
	if generation == _quest_notice_generation and quest_notice != null:
		quest_notice.hide()

## Shows a response being said as a subtitle, unless the conversation screen
## shows it.
func _on_response_started(line: DialogueLine, text: String) -> void:
	if subtitle == null or (dialogue_session != null and dialogue_session.visible and line.speaker == DialogueServer.get_conversation_speaker()):
		return
	_subtitle_line = line
	subtitle.text = text
	subtitle.visible = not text.is_empty()

## Clears the subtitle when its line finishes and no other line replaced it.
func _on_line_finished(line: DialogueLine) -> void:
	if subtitle != null and line == _subtitle_line:
		subtitle.hide()
		_subtitle_line = null

func _connect_ui() -> void:
	if terminal_session != null and not terminal_session.closed.is_connected(_on_terminal_closed):
		terminal_session.closed.connect(_on_terminal_closed)
		terminal_session.item_chosen.connect(_on_terminal_item_chosen)
	if unlock_session != null and not unlock_session.succeeded.is_connected(_on_unlock_succeeded):
		unlock_session.succeeded.connect(_on_unlock_succeeded)
		unlock_session.cancelled.connect(_on_unlock_cancelled)
	for menu: CanvasLayer in [name_menu, race_menu]:
		if menu != null and not menu.closed.is_connected(_on_script_menu_closed):
			menu.closed.connect(_on_script_menu_closed)

## Opens the menu a script asked for (ScriptServer.menu_opener): the name or
## race menu for the possessed actor. False for a menu with no UI.
func _open_script_menu(menu_id: int) -> bool:
	var menu: CanvasLayer = null
	match menu_id:
		ScriptServer.MENU_TEXT_EDIT: menu = name_menu
		ScriptServer.MENU_RACE: menu = race_menu
	if menu == null or possessed == null:
		return false
	menu.open(possessed)
	_set_input_suspended(true)
	return true

func _on_script_menu_closed() -> void:
	_set_input_suspended(false)

## A conversation with the possessed actor opens the conversation screen.
func _on_conversation_started(speaker: EsmReference, listener: EsmReference) -> void:
	if dialogue_session == null or possessed == null or listener != possessed:
		return
	dialogue_session.open(speaker)
	_set_input_suspended(true)

func _on_conversation_ended(_speaker: EsmReference) -> void:
	if dialogue_session != null and dialogue_session.visible:
		dialogue_session.close()
		_set_input_suspended(false)

## Shows the UI for what the possessed actor started using, and closes it when
## the use ends another way.
func _on_using_changed(_previous: EsmReference, current: EsmReference) -> void:
	if current == null:
		if terminal_session != null and terminal_session.visible:
			terminal_session.close_session()
		if unlock_session != null and unlock_session.visible:
			unlock_session.cancel()
		return
	if current is TerminalReference:
		if current.is_locked:
			_open_unlock("Hack", LOCK_LEVEL_NAMES[clampi(current.lock_level, 0, 4)])
		else:
			_open_terminal(current)
	elif current is DoorReference and current.is_locked:
		_open_unlock("Lockpick", LOCK_LEVEL_NAMES[clampi(current.lock_level / 25, 0, 4)])

func _open_terminal(terminal: TerminalReference) -> void:
	if terminal_session != null and terminal_session.open_session(terminal, EsmServer.reader, possessed):
		_set_input_suspended(true)
	else:
		ScriptServer.end_use(possessed)

func _open_unlock(title: String, detail: String) -> void:
	if unlock_session == null:
		ScriptServer.end_use(possessed)
		return
	unlock_session.open(title, detail)
	_set_input_suspended(true)

## A picked lock unlocks and ends the use; a hacked terminal unlocks and opens.
func _on_unlock_succeeded() -> void:
	var target := possessed.using if possessed != null else null
	if target == null:
		_set_input_suspended(false)
		return
	ScriptServer.unlock(target)
	if target is TerminalReference:
		_open_terminal(target)
	else:
		_set_input_suspended(false)
		ScriptServer.end_use(possessed)

func _on_unlock_cancelled() -> void:
	_set_input_suspended(false)
	if possessed != null and possessed.using != null:
		ScriptServer.end_use(possessed)

## Closing the terminal ends the actor's use of it.
func _on_terminal_closed() -> void:
	_set_input_suspended(false)
	if possessed != null and possessed.using is TerminalReference:
		ScriptServer.end_use(possessed)

## A chosen menu item runs its result script on the terminal, with the
## possessed actor as the activator.
func _on_terminal_item_chosen(item: Dictionary) -> void:
	if possessed != null:
		ScriptServer.run_result_script(String(item.get("script_source", "")), possessed.using, possessed)

## Stops movement and look/interact input while a UI has focus.
func _set_input_suspended(suspended: bool) -> void:
	_input_suspended = suspended
	set_physics_process(not frozen and not _input_suspended)
	set_process_unhandled_input(not suspended)
	velocity = Vector3.ZERO

func set_frozen(value: bool) -> void:
	frozen = value
	set_physics_process(not frozen and not _input_suspended)
	velocity = Vector3.ZERO

## Moves the body to a Godot-space position and yaw, with no leftover motion
## or camera pitch.
func place_body(target_global_position: Vector3, yaw: float) -> void:
	teleport(target_global_position)
	rotation.y = yaw
	camera_pitch = 0.0

## Activates what the interact ray is aimed at, with the possessed actor as the
## activator.
func request_activate() -> void:
	if possessed == null or interact_ray == null:
		return
	var target := interact_ray.current_target as EsmNode
	if target != null and target.reference != null:
		ScriptServer.activate(target.reference, possessed)

func _sync_possessed() -> void:
	if frozen or possessed == null or possessed.current_space_form_id == 0:
		return
	possessed.position = EsmReferencePhysicaliser.authored_position(global_position)
	possessed.rotation = EsmReferencePhysicaliser.authored_heading(rotation.y)

## Adds trauma to the procedural camera shake system.
func apply_camera_shake(trauma_amount: float) -> void:
	_camera_trauma += trauma_amount
	_camera_trauma = clampf(_camera_trauma, 0.0, 6.0)


func teleport(target_global_position: Vector3) -> void:
	is_teleporting = true
	global_position = target_global_position
	velocity = Vector3.ZERO
	_camera_trauma = 0.0
	_coyote_timer = 0.0
	_jump_cooldown_timer = 0.0
	if camera:
		camera_lerp_position = target_global_position + Vector3(0, camera_eye_height, 0)
		camera.global_position = camera_lerp_position


func apply_radial_force(force_strength: float, origin: Vector3, radius: float, shake_trauma: float = 0.0, apply_knockdown: bool = true) -> void:
	var height := crouching_height if is_crouching else standing_height
	var character_center := global_position + Vector3(0.0, (height * 0.5) + hover_offset, 0.0)
	var offset := character_center - origin
	var distance := offset.length()

	if distance >= radius or force_strength <= 0.0:
		return

	var falloff := 1.0 - (distance / radius)
	var final_force := offset.normalized() * force_strength * falloff

	final_force.x -= velocity.x * 0.5
	final_force.z -= velocity.z * 0.5
	final_force.y -= velocity.y
	velocity += final_force

	if shake_trauma > 0.0:
		apply_camera_shake(shake_trauma * falloff)

	if apply_knockdown:
		knocked_timer_ms = Time.get_ticks_msec()
