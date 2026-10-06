extends Node

## Every line in SCPT sources, QUST stage result scripts, INFO result scripts
## and PACK event scripts that calls Look or StopLook, with where it is, for
## the editor IDs containing the command-line word (all when none).

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var word := OS.get_cmdline_user_args()[0] if not OS.get_cmdline_user_args().is_empty() else ""
	var pattern := RegEx.create_from_string("(?i)^[^;]*\\b(look|stoplook)\\b")
	for row: Dictionary in EsmServer.get_record_index():
		var type := String(row.get("record_type", ""))
		var editor_id := String(row.get("editor_id", ""))
		var sources := []
		if type == "SCPT":
			sources.append(String(EsmServer.reader.get_script_data(int(row["form_id"])).get("source_text", "")))
		elif type == "PACK":
			var p := EsmServer.get_base(int(row["form_id"])) as PackageBase
			for event in [p.on_begin, p.on_end, p.on_change]:
				if event != null:
					sources.append(event.script_source)
		elif type == "QUST" or type == "INFO":
			var raw: Dictionary = EsmServer.reader.get_record_data(int(row["form_id"]))
			for sub in raw.get("subrecords", []):
				if sub.get("type") == "SCTX":
					sources.append((sub["data"] as PackedByteArray).get_string_from_ascii())
		for source: String in sources:
			for line in source.split("\n"):
				if pattern.search(line) == null:
					continue
				if not word.is_empty() and not editor_id.containsn(word) and not line.containsn(word):
					continue
				print("%s %s %08X: %s" % [type, editor_id, int(row["form_id"]), line.strip_edges()])
	get_tree().quit()
