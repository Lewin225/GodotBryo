class_name ModelPreview
extends Control

## A live 3D view of a record's model, for any UI: the spawn menu shows one
## over its hovered icon (SpawnMenuTab). A SubViewport with its own World3D,
## so nothing in it touches the game world, its physics or its lights.
##
## show_record() (a record) or show_model() (a model key) places it and, after
## `load_delay` seconds on the same model (so sweeping the mouse across a grid
## does not load every cell), asks ThumbnailServer.request_model() for the
## tree, prepared and turned as a thumbnail is. A model asked for and then
## left is dropped when it arrives. It is framed as its thumbnail is
## (ThumbnailServer.frame_model()).
##
## Its viewport renders at full scale with bilinear scaling, not the
## project's upscaler (rendering/scaling_3d: FSR, MetalFX on macOS), which
## SubViewports inherit: an upscaled image has no alpha, so the preview would
## draw an opaque black square over its backdrop (a radial gradient, black at
## the centre and clear at the edge, so the labels under it stay readable).
##
## The model spins slowly (turn_speed). While Shift is held the pointer turns
## it instead (set_pointer()): across the hovered cell is orbit_degrees of
## yaw each way, up and down the same of pitch, so the model turns to face the
## pointer, easing toward it the short way round from wherever the spin left
## it. Let go and the spin carries on from there while the pitch eases level.
##
## It ignores the mouse, so the grid under it keeps the hover.
##
## Without Shift it appears in its thumbnail's pose
## (ThumbnailServer.start_pose()), so a rendered icon under it carries on into
## the spin.
##
## Nodes are authored in model_preview.tscn; the camera, pivot, lights and
## world are ThumbnailServer's stage.tscn, the stage its renders are drawn on.
## This script only looks them up.

## Seconds the pointer must stay on one model before it loads.
@export var load_delay := 0.08
## Radians a second the model spins while Shift is not held.
@export var turn_speed := 0.6
## How far the pointer turns the model each way with Shift held, in degrees,
## on yaw and pitch.
@export var orbit_degrees := 45.0
## How quickly the model eases toward the pointer's orientation, and back
## level after; higher is snappier.
@export var orbit_sharpness := 12.0
## Test hook: steer with the pointer as if Shift were held.
var force_orbit := false

## Emitted when a requested model is framed and showing.
signal model_shown(model_path: String)

@onready var _viewport: SubViewport = $ViewportContainer/Viewport
@onready var _camera: Camera3D = $ViewportContainer/Viewport/Camera3D
@onready var _pivot: Node3D = $ViewportContainer/Viewport/Pivot
@onready var _status: Label = $Status

## The model asked for, the one showing, and the tree of the one showing.
var _wanted := ""
var _showing := ""
var _model: Node3D
var _wait := 0.0
var _requested := {}
## The pointer within the cell, -1 to 1 each way (set_pointer()); the yaw and
## pitch it asks for, and those the model has eased to, in radians.
var _pointer := Vector2.ZERO
var _yaw := 0.0
var _pitch := 0.0

func _ready() -> void:
	visible = false
	set_process(false)

func _process(delta: float) -> void:
	if _wanted != _showing and not _requested.has(_wanted):
		_wait -= delta
		if _wait <= 0.0:
			_requested[_wanted] = true
			ThumbnailServer.request_model(_wanted, _on_delivered.bind(_wanted))
	if _model != null:
		var weight := 1.0 - exp(-orbit_sharpness * delta)
		if is_orbiting():
			var target := _orbit_target()
			_yaw += angle_difference(_yaw, target.x) * weight
			_pitch = lerpf(_pitch, target.y, weight)
		else:
			_yaw = wrapf(_yaw + turn_speed * delta, -PI, PI)
			_pitch = lerpf(_pitch, 0.0, weight)
		_apply_orbit()

## The pointer within the hovered cell, -1 to 1 on each axis (right, down);
## the model turns to face it.
func set_pointer(normalized: Vector2) -> void:
	_pointer = normalized.clamp(-Vector2.ONE, Vector2.ONE)

## Whether the pointer steers the model: Shift is held.
func is_orbiting() -> bool:
	return force_orbit or Input.is_key_pressed(KEY_SHIFT)

## The [yaw, pitch] the pointer asks for, in radians: about the thumbnail's
## pose.
func _orbit_target() -> Vector2:
	var reach := deg_to_rad(orbit_degrees)
	return ThumbnailServer.start_pose() + Vector2(_pointer.x * reach, _pointer.y * reach)

## The model's current [yaw, pitch], in radians.
func orbit() -> Vector2:
	return Vector2(_yaw, _pitch)

## Yaw about the pivot's up, then pitch about the camera's right: positive
## yaw turns the model's front to the right, positive pitch tips it down.
func _apply_orbit() -> void:
	_pivot.basis = Basis(Vector3.RIGHT, _pitch) * Basis(Vector3.UP, _yaw)

## Shows the preview over `rect` (in the parent's coordinates) for record
## `form_id`'s model (ThumbnailServer.record_visual()); false, and hidden,
## when it has none.
func show_record(form_id: int, rect: Rect2) -> bool:
	var model := String(ThumbnailServer.record_visual(form_id).get("model", ""))
	if model.is_empty():
		hide_preview()
		return false
	show_model(model, rect)
	return true

## Shows the preview over `rect` (in the parent's coordinates) for
## `model_path` (a model key, ThumbnailServer.request_model()), loading it
## after load_delay unless it is the model already showing.
func show_model(model_path: String, rect: Rect2) -> void:
	position = rect.position
	size = rect.size
	visible = true
	set_process(true)
	if model_path == _wanted:
		return
	_wanted = model_path
	_wait = load_delay
	if model_path != _showing:
		_clear_model()
		_status.text = "…"
		_status.visible = true

## Hides the preview and drops its model; a model still loading is dropped
## when it arrives.
func hide_preview() -> void:
	visible = false
	set_process(false)
	_wanted = ""
	_clear_model()

## The model showing, or "".
func showing() -> String:
	return _showing

## The model tree showing, or null.
func model_root() -> Node3D:
	return _model

func _clear_model() -> void:
	_showing = ""
	if _model != null:
		_model.queue_free()
		_model = null

func _on_delivered(tree: Node3D, model_path: String) -> void:
	_requested.erase(model_path)
	if model_path != _wanted or not visible:
		if tree != null:
			tree.queue_free()
		return
	_clear_model()
	if tree == null:
		_status.text = "No model"
		_status.visible = true
		return
	# Unsteered, it starts in the pose of its thumbnail, so the icon it covers
	# turns into it without a jump.
	var target := _orbit_target() if is_orbiting() else ThumbnailServer.start_pose()
	_yaw = target.x
	_pitch = target.y
	_apply_orbit()
	_pivot.add_child(tree)
	_model = tree
	_showing = model_path
	ThumbnailServer.frame_model(tree, _pivot, _camera)
	_status.visible = false
	model_shown.emit(model_path)
