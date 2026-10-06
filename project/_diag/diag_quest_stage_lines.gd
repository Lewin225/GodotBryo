extends Node

## For the QUST named on the command line: each stage (INDX) whose result
## script contains the second argument, with the matching lines.

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var args := OS.get_cmdline_user_args()
	var form_id := EsmServer.find_form_id_by_editor_id(args[0])
	var raw: Dictionary = EsmServer.reader.get_record_data(form_id)
	var stage := -1
	for sub in raw.get("subrecords", []):
		var data: PackedByteArray = sub["data"]
		if sub.get("type") == "INDX":
			stage = data.decode_s16(0)
		elif sub.get("type") == "SCTX":
			for line in data.get_string_from_ascii().split("\n"):
				if line.containsn(args[1]):
					print("stage %d: %s" % [stage, line.strip_edges()])
	get_tree().quit()
