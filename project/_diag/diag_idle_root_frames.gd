extends Node

## Census of the root bones in every IDLE's KF under Characters\_Male\: which
## of Bip01 and Bip01 NonAccum each keys (position, rotation), and their first
## key (NonAccum height rounded to 0.1 m, rotation as Euler degrees rounded to
## 10), grouped and counted, with examples.

var _pending := 0
var _groups := {}

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var paths := {}
	for row: Dictionary in EsmServer.get_record_index():
		if String(row.get("record_type", "")) != "IDLE":
			continue
		var idle := EsmServer.get_base(int(row["form_id"])) as IdleBase
		if idle == null or not idle.has_kf() or not idle.model_path.to_lower().begins_with("characters\\_male\\"):
			continue
		paths[idle.model_path.replace("\\", "/").to_lower()] = idle.editor_id
	for path: String in paths:
		_pending += 1
		NifServer.request_kf(path, self, _on_kf.bind(path, paths[path]))
	var deadline := Time.get_ticks_msec() + 400000
	var next_report := Time.get_ticks_msec() + 10000
	while _pending > 0 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		if Time.get_ticks_msec() >= next_report:
			next_report += 10000
			print("pending %d of %d" % [_pending, paths.size()])
	print("KFs: %d, unanswered %d" % [paths.size(), _pending])
	var keys := _groups.keys()
	keys.sort_custom(func(a: String, b: String) -> bool: return _groups[a].size() > _groups[b].size())
	for key: String in keys:
		var names: Array = _groups[key]
		print("%5d  %s  e.g. %s" % [names.size(), key, ", ".join(names.slice(0, 4))])
	get_tree().quit()

func _on_kf(library: AnimationLibrary, path: String, editor_id: String) -> void:
	_pending -= 1
	if library == null or library.get_animation_list().is_empty():
		_add("missing", editor_id)
		return
	var animation := library.get_animation(library.get_animation_list()[0])
	var parts := PackedStringArray()
	for bone: String in ["Bip01", "Bip01 NonAccum"]:
		var position := animation.find_track(NodePath(bone), Animation.TYPE_POSITION_3D)
		var rotation := animation.find_track(NodePath(bone), Animation.TYPE_ROTATION_3D)
		var text := bone + ":"
		if position != -1:
			var value: Vector3 = animation.track_get_key_value(position, 0)
			text += " pos z %.1f" % snappedf(value.z, 0.1) if bone != "Bip01" else " pos %s" % (value.snapped(Vector3.ONE * 0.1))
		if rotation != -1:
			var quat: Quaternion = animation.track_get_key_value(rotation, 0)
			text += " rot %s" % (quat.get_euler() * 180.0 / PI).snapped(Vector3.ONE * 10.0)
		if position == -1 and rotation == -1:
			text += " none"
		parts.append(text)
	_add("; ".join(parts), editor_id)

func _add(key: String, editor_id: String) -> void:
	if not _groups.has(key):
		_groups[key] = []
	_groups[key].append(editor_id)
