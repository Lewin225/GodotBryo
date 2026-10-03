class_name Crosshair
extends CenterContainer

@export var interact_ray: InteractRay
@export var action_label: Label

@export_group("Dot Settings")
@export var dot_radius: float = 2.5
@export var dot_color: Color = Color(1.0, 1.0, 1.0, 0.9)
@export var outline_color: Color = Color(0.0, 0.0, 0.0, 0.7)
@export var outline_width: float = 1.0

@export_group("Interact Circle Settings")
@export var interact_circle_radius: float = 12.0
@export var interact_circle_width: float = 2.0
@export var interact_circle_color: Color = Color(1.0, 1.0, 1.0, 0.95)
@export var show_dot_inside_circle: bool = true

var current_action: String = ""
var _anim_t: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	if not action_label:
		action_label = get_node_or_null("VBoxContainer/ActionLabel") as Label
		if not action_label:
			action_label = get_node_or_null("ActionLabel") as Label
	if not interact_ray:
		var player := get_parent().get_parent()
		if player:
			interact_ray = player.get_node_or_null("Camera3D/InteractRay") as InteractRay
	if interact_ray:
		interact_ray.target_changed.connect(_on_target_changed)

	if action_label:
		action_label.text = ""


func _process(delta: float) -> void:
	var has_target := (current_action != "")
	var target_anim := 1.0 if has_target else 0.0
	_anim_t = lerpf(_anim_t, target_anim, clampf(delta * 16.0, 0.0, 1.0))

	if action_label:
		if has_target:
			action_label.text = current_action
		action_label.modulate.a = _anim_t
		action_label.visible = (_anim_t > 0.01)

	queue_redraw()


## The prompt for what the crosshair is on; none while scripts disable rollover
## text (DisablePlayerControls).
func _on_target_changed(_target: Object, _collider: Object, _type: StringName, action_text: String) -> void:
	current_action = action_text if ScriptServer.is_player_control_enabled(ScriptServer.CONTROL_ROLLOVER_TEXT) else ""


func _draw() -> void:
	var center := size * 0.5

	# 1. Base Center Dot
	if show_dot_inside_circle or _anim_t < 0.99:
		var dot_alpha: float = (1.0 - _anim_t) if not show_dot_inside_circle else 1.0
		var cur_dot_col := Color(dot_color.r, dot_color.g, dot_color.b, dot_color.a * dot_alpha)
		var cur_out_col := Color(outline_color.r, outline_color.g, outline_color.b, outline_color.a * dot_alpha)
		if outline_width > 0.0:
			draw_circle(center, dot_radius + outline_width, cur_out_col)
		draw_circle(center, dot_radius, cur_dot_col)

	# 2. Large Interactive Ring/Circle on Hover
	if _anim_t > 0.01:
		var cur_radius: float = lerpf(dot_radius, interact_circle_radius, _anim_t)
		var circle_col := Color(interact_circle_color.r, interact_circle_color.g, interact_circle_color.b, interact_circle_color.a * _anim_t)
		var circle_out := Color(outline_color.r, outline_color.g, outline_color.b, outline_color.a * _anim_t)

		if outline_width > 0.0:
			draw_arc(center, cur_radius, 0.0, TAU, 48, circle_out, interact_circle_width + outline_width * 2.0, true)
		draw_arc(center, cur_radius, 0.0, TAU, 48, circle_col, interact_circle_width, true)
