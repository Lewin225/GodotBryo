extends Node

## Prints the source of the SCPT records named on the command line (FormID hex
## or editor ID).

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	for name in OS.get_cmdline_user_args():
		var form_id := name.hex_to_int() if name.is_valid_hex_number() else EsmServer.find_form_id_by_editor_id(name)
		var data: Dictionary = EsmServer.reader.get_script_data(form_id)
		if data.is_empty():
			print("%s: not a SCPT" % name)
			continue
		print("===== %s %08X\n%s" % [name, form_id, String(data["source_text"])])
	get_tree().quit()
