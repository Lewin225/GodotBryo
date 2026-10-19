extends Node

## Census for looping idles (Plans/Completed Plans/Actors/stage_f.md step 3): the DATA loop
## min / max and replay delay over every IDLE; and, for the idles PlayIdle and
## package events play (the editor IDs or hex FormIDs in the file named on the
## command line, or "all-looping" for every IDLE with a loop maximum above 0),
## those fields with the KF's own loop mode, length and StartLoop / EndLoop
## text keys.

var _pending := 0
var _rows: Array[String] = []

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var pairs := {}
	var delays := {}
	var total := 0
	for row: Dictionary in EsmServer.get_record_index():
		if String(row.get("record_type", "")) != "IDLE":
			continue
		var idle := EsmServer.get_base(int(row["form_id"])) as IdleBase
		if idle == null:
			continue
		total += 1
		var key := "%d-%d" % [idle.loop_minimum, idle.loop_maximum]
		pairs[key] = int(pairs.get(key, 0)) + 1
		delays[idle.replay_delay] = int(delays.get(idle.replay_delay, 0)) + 1
	print("IDLE %d; loop min-max: %s" % [total, pairs])
	print("replay delay: %s" % delays)

	var listed := PackedStringArray()
	if OS.get_cmdline_user_args()[0] == "all-looping":
		for row: Dictionary in EsmServer.get_record_index():
			if String(row.get("record_type", "")) != "IDLE":
				continue
			var looping := EsmServer.get_base(int(row["form_id"])) as IdleBase
			if looping != null and looping.loop_maximum > 0:
				listed.append("%08X" % looping.form_id)
	else:
		listed = FileAccess.get_file_as_string(OS.get_cmdline_user_args()[0]).split("\n", false)
	for entry in listed:
		var idle: IdleBase = null
		if entry.length() == 8 and entry.is_valid_hex_number():
			idle = EsmServer.get_base(entry.hex_to_int()) as IdleBase
		else:
			idle = EsmServer.find_base_by_editor_id(entry) as IdleBase
		if idle == null:
			_rows.append("%s: not an IDLE" % entry)
			continue
		if not idle.has_kf():
			_rows.append("%s: loop %d-%d delay %d, no KF" % [idle.editor_id, idle.loop_minimum, idle.loop_maximum, idle.replay_delay])
			continue
		_pending += 1
		NifServer.request_kf(idle.model_path.replace("\\", "/").to_lower(), self, _on_kf.bind(idle))
	while _pending > 0:
		await get_tree().process_frame
	_rows.sort()
	for row in _rows:
		print(row)
	get_tree().quit()

func _on_kf(library: AnimationLibrary, idle: IdleBase) -> void:
	_pending -= 1
	var mode := "missing"
	var length := 0.0
	var section := "no loop keys"
	if library != null and not library.get_animation_list().is_empty():
		var animation := library.get_animation(library.get_animation_list()[0])
		mode = ["once", "loop", "pingpong"][animation.loop_mode]
		length = animation.length
		var start := -1.0
		var end := -1.0
		for key: Dictionary in animation.get_meta("nif_text_keys", []):
			var value := String(key.get("value", "")).strip_edges().to_lower()
			if value == "startloop":
				start = float(key["time"])
			elif value == "endloop":
				end = float(key["time"])
		if start >= 0.0 or end >= 0.0:
			section = "loop keys %.2f-%.2f" % [start, end]
	_rows.append("%s: loop %d-%d delay %d, KF %s %.2f s, %s" % [idle.editor_id, idle.loop_minimum, idle.loop_maximum, idle.replay_delay, mode, length, section])
