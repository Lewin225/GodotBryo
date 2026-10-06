extends Node

## Prints the authored transform (as NifSource.get_nodes() reports it) of each
## node named after the NIF path on the command line, e.g.
## `-- characters/_male/skeleton.nif "Bip01" "Bip01 NonAccum"`.

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var result: Dictionary = ArchiveServer.read("meshes/" + args[0])
	var source := NifSource.new()
	if not result["found"] or not source.load(PackedByteArray(result["data"])):
		print("could not load %s" % args[0])
		get_tree().quit()
		return
	var wanted := args.slice(1)
	for node: Dictionary in source.get_nodes():
		var name := String(node.get("name", ""))
		if not wanted.has(name):
			continue
		var xform: Transform3D = node.get("transform", Transform3D.IDENTITY)
		print("%s: parent %s, euler degrees %s, origin %s" % [name, node.get("parent", -1), (xform.basis.get_euler() * 180.0 / PI).round(), xform.origin])
	get_tree().quit()
