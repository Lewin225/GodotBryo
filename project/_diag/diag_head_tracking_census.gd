extends Node

## Census for head tracking: PACK General Flags Head Tracking Off (0x100000)
## and PKDD No Headtracking (0x1) by package type, and SCPT sources (plus PACK
## event scripts) calling Look or StopLook, with examples.

const HEAD_TRACKING_OFF := 0x100000
const DIALOGUE_NO_HEADTRACKING := 0x1

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var off_by_type := {}
	var no_dialogue := 0
	var packages := 0
	var look_scripts := []
	var stoplook_scripts := 0
	var look_regex := RegEx.create_from_string("(?im)^[^;]*\\b(\\w+\\.)?look\\s+\\w+")
	var stop_regex := RegEx.create_from_string("(?im)^[^;]*\\bstoplook\\b")
	for row: Dictionary in EsmServer.get_record_index():
		var type := String(row.get("record_type", ""))
		if type == "PACK":
			var p := EsmServer.get_base(int(row["form_id"])) as PackageBase
			if p == null:
				continue
			packages += 1
			if (p.general_flags & HEAD_TRACKING_OFF) != 0:
				var name: String = PackageBase.PackageType.keys()[p.package_type]
				off_by_type[name] = int(off_by_type.get(name, 0)) + 1
			if p.has_dialogue_data and (p.dialogue_flags & DIALOGUE_NO_HEADTRACKING) != 0:
				no_dialogue += 1
		elif type == "SCPT":
			var data: Dictionary = EsmServer.reader.get_script_data(int(row["form_id"]))
			var source := String(data.get("source_text", ""))
			if look_regex.search(source) != null:
				look_scripts.append(String(row.get("editor_id", "")))
			if stop_regex.search(source) != null:
				stoplook_scripts += 1
	print("PACK: %d; Head Tracking Off by type: %s; PKDD No Headtracking: %d" % [packages, off_by_type, no_dialogue])
	print("SCPT calling Look: %d (StopLook: %d); e.g. %s" % [look_scripts.size(), stoplook_scripts, look_scripts.slice(0, 12)])
	get_tree().quit()
