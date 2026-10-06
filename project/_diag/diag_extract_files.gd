extends Node

## Writes each archive path given after `--` (first argument: output
## directory) to that directory, named by its file name, for offline parsing.
func _ready() -> void:
	await get_tree().process_frame
	var args := OS.get_cmdline_user_args()
	var out_dir := args[0]
	for path in args.slice(1):
		var result := ArchiveServer.read(path)
		var data: PackedByteArray = result.get("data", PackedByteArray())
		var name := path.replace("/", "_")
		var file := FileAccess.open(out_dir.path_join(name), FileAccess.WRITE)
		file.store_buffer(data)
		print("%s: %d bytes" % [path, data.size()])
	get_tree().quit()
