extends Node

## For IDLE records whose editor ID contains any of the words on the command
## line: MODL, ANAM parent / previous, DATA's section byte, and each CTDA's
## function (by name), parameters, comparison and value, read from the raw
## record (IdleBase does not read these yet).

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var words := OS.get_cmdline_user_args()
	for row: Dictionary in EsmServer.get_record_index():
		_names[int(row["form_id"])] = String(row.get("editor_id", ""))
	for row: Dictionary in EsmServer.get_record_index():
		if String(row.get("record_type", "")) != "IDLE":
			continue
		var editor_id := String(row.get("editor_id", ""))
		var wanted := false
		for word in words:
			if editor_id.to_lower().contains(word.to_lower()):
				wanted = true
		if not wanted:
			continue
		var raw: Dictionary = EsmServer.reader.get_record_data(int(row["form_id"]))
		var line := "%s %08X" % [editor_id, int(row["form_id"])]
		var conditions := ""
		for sub in raw.get("subrecords", []):
			var data: PackedByteArray = sub["data"]
			match String(sub.get("type")):
				"MODL":
					line += "  %s" % data.get_string_from_ascii().get_file()
				"ANAM":
					line += "  parent %s previous %s" % [_name(data.decode_u32(0)), _name(data.decode_u32(4))]
				"DATA":
					line += "  section %02X" % data[0]
				"CTDA":
					var function_index := data.decode_u16(8)
					var entry: Array = ScriptConditionFunctions.BY_INDEX.get(function_index, ["#%d" % function_index, []])
					var function_name: String = entry[0]
					var types: Array = entry[1]
					var comparison: String = ["==", "!=", ">", ">=", "<", "<="][(data[0] >> 5) & 7] if ((data[0] >> 5) & 7) < 6 else "?"
					conditions += "\n    %s(%s, %s) %s %s%s" % [function_name, _param(data.decode_u32(12), types, 0), _param(data.decode_u32(16), types, 1), comparison, data.decode_float(4), " OR" if (data[0] & 1) != 0 else ""]
		print(line + conditions)
	get_tree().quit()

## Editor IDs by FormID, from the record index.
var _names: Dictionary = {}

## A CTDA parameter: named when its type is a form, else the integer.
func _param(value: int, types: Array, index: int) -> String:
	if index >= types.size():
		return "-"
	var type := String(types[index])
	if ScriptConditionFunctions.INTEGER_PARAMETERS.has(type):
		return str(value)
	return _name(value)

func _name(form_id: int) -> String:
	if form_id == 0:
		return "-"
	var name: String = _names.get(form_id, "")
	return name if not name.is_empty() else "%08X" % form_id
