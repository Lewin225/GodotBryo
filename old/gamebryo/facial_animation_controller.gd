@tool
class_name FacialAnimationController
extends Node

## Runtime driver for the named TRI blend shapes on an NPC head. This is a
## separate layer from locomotion/skeleton animation: facial controls mutate
## only MeshInstance3D blend-shape weights and never bone poses.
##
## Authored facial actions are exposed only when the loaded TRI actually
## contains the named target. No visual blink fallback is synthesized when it
## does not.

var _head_meshes: Array[MeshInstance3D] = []
var _morph_names: PackedStringArray = []
var _animation_player: AnimationPlayer = null
var _blink_targets: PackedStringArray = []
var _blink_countdown := 0.0
var _blink_active := false
var _preview_applied_name := ""

@export var automatic_blinking := true
@export var blink_min_interval := 3.0
@export var blink_max_interval := 8.0
@export var blink_duration := 0.12
## Editor-facing diagnostic controls. Select a discovered TRI channel and set
## its weight while inspecting an NPCActor in the editor.
@export var preview_morph_name := "":
	set(value):
		preview_morph_name = value
		_apply_preview_morph()
@export_range(0.0, 1.0, 0.01) var preview_morph_weight := 0.0:
	set(value):
		preview_morph_weight = clampf(value, 0.0, 1.0)
		_apply_preview_morph()
@export var discovered_morph_names: PackedStringArray = []
@export_tool_button("Clear Preview Morph") var clear_preview_button: Callable = clear_preview_morph

func configure(head_meshes: Array) -> void:
	_head_meshes.clear()
	_morph_names = PackedStringArray()
	_blink_targets = PackedStringArray()
	for candidate in head_meshes:
		if not candidate is MeshInstance3D or not candidate.mesh is ArrayMesh:
			continue
		var mesh := candidate.mesh as ArrayMesh
		_head_meshes.append(candidate)
		for i in mesh.get_blend_shape_count():
			var name := mesh.get_blend_shape_name(i)
			if not _morph_names.has(name):
				_morph_names.append(name)
	discovered_morph_names = _morph_names.duplicate()
	for candidate in ["Blink", "BlinkLeft", "BlinkRight", "EyeClose"]:
		if has_morph(candidate):
			_blink_targets.append(candidate)
	if not _head_meshes.is_empty():
		_animation_player = AnimationPlayer.new()
		_animation_player.name = "FacialAnimationPlayer"
		get_parent().add_child(_animation_player)
		_animation_player.root_node = NodePath("..")
	set_process(supports_blink() and automatic_blinking)
	_schedule_next_blink()
	_apply_preview_morph()

func _apply_preview_morph() -> void:
	if not is_inside_tree() or _morph_names.is_empty():
		return
	if not _preview_applied_name.is_empty() and _preview_applied_name != preview_morph_name:
		set_morph_weight(_preview_applied_name, 0.0)
	_preview_applied_name = preview_morph_name
	if not preview_morph_name.is_empty():
		set_morph_weight(preview_morph_name, preview_morph_weight)

func clear_preview_morph() -> void:
	if not _preview_applied_name.is_empty():
		set_morph_weight(_preview_applied_name, 0.0)
	_preview_applied_name = ""
	preview_morph_name = ""
	preview_morph_weight = 0.0

func _process(delta: float) -> void:
	if not supports_blink() or not automatic_blinking or _blink_active:
		return
	_blink_countdown -= delta
	if _blink_countdown <= 0.0:
		blink()

func _schedule_next_blink() -> void:
	if not supports_blink():
		_blink_countdown = 0.0
		return
	_blink_countdown = randf_range(minf(blink_min_interval, blink_max_interval), maxf(blink_min_interval, blink_max_interval))

func get_animation_player() -> AnimationPlayer:
	return _animation_player

func get_morph_names() -> PackedStringArray:
	return _morph_names

func has_morph(name: String) -> bool:
	return _morph_names.has(name)

func set_morph_weight(name: String, weight: float) -> bool:
	var applied := false
	for head in _head_meshes:
		var mesh := head.mesh as ArrayMesh
		var index := -1
		for candidate_index in mesh.get_blend_shape_count():
			if mesh.get_blend_shape_name(candidate_index) == name:
				index = candidate_index
				break
		if index == -1:
			continue
		head.set_blend_shape_value(index, clampf(weight, 0.0, 1.0))
		applied = true
	return applied

func set_phoneme(name: String, weight: float = 1.0) -> bool:
	return set_morph_weight(name, weight)

func set_expression(name: String, weight: float = 1.0) -> bool:
	return set_morph_weight(name, weight)

func animate_morph(name: String, peak_weight: float = 1.0, duration: float = 0.25) -> bool:
	## Diagnostic/runtime primitive for a verified TRI target. Authored KF
	## facial files currently contain bone tracks only, so higher-level
	## phoneme/expression scheduling supplies timing and calls this method.
	## Godot's blend-shape property is not a stable AnimationMixer target in
	## this runtime build, so the controller owns this tiny linear tween while
	## FacialAnimationPlayer remains the reserved layer for future verified
	## authored tracks.
	if not has_morph(name):
		return false
	var tween := create_tween()
	tween.tween_method(func(value: float): set_morph_weight(name, value), 0.0, clampf(peak_weight, 0.0, 1.0), maxf(duration * 0.5, 0.01))
	tween.tween_method(func(value: float): set_morph_weight(name, value), clampf(peak_weight, 0.0, 1.0), 0.0, maxf(duration * 0.5, 0.01))
	return true

func blink() -> bool:
	if _blink_targets.is_empty() or _blink_active:
		return false
	_blink_active = true
	var peak := func(value: float) -> void:
		for target in _blink_targets:
			set_morph_weight(target, value)
	var tween := create_tween()
	tween.tween_method(peak, 0.0, 1.0, maxf(blink_duration * 0.5, 0.01))
	tween.tween_method(peak, 1.0, 0.0, maxf(blink_duration * 0.5, 0.01))
	tween.finished.connect(func():
		_blink_active = false
		_schedule_next_blink()
	)
	return true

func clear_weights() -> void:
	for name in _morph_names:
		set_morph_weight(name, 0.0)

func supports_blink() -> bool:
	return not _blink_targets.is_empty()
