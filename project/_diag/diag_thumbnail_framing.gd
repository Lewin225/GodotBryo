extends Node
## Spawn menu thumbnails (ThumbnailServer): for every saved render of a
## WEAP/ARMO/STAT/CONT/MISC model, how much of the image the model fills.
## Flags tiny renders (longest side under 40%) and cropped ones (touching an
## edge), then dumps the visual nodes of a few flagged models in pivot space,
## to find what makes ThumbnailServer.frame_model()'s bounds wrong.
## Run windowed: Godot --path . _diag/diag_thumbnail_framing.tscn

const TYPES := ["WEAP", "ARMO", "STAT", "CONT", "MISC"]

func _ready() -> void:
	var esm_server: Node = get_node("/root/EsmServer")
	if not esm_server.is_ready():
		await esm_server.esm_ready
	var catalog := SpawnCatalog.new(esm_server.reader, esm_server.get_record_index(), get_node("/root/ArchiveServer"))
	var renderer: Node = ThumbnailServer
	var seen := {}
	var total := 0
	var tiny: Array = []
	var cropped: Array = []
	for type: String in TYPES:
		for row: Dictionary in catalog.rows_for_type(type):
			var model := SpawnMenuTab.thumbnail_model(row)
			if model.is_empty() or seen.has(model):
				continue
			seen[model] = true
			var file := renderer.cache_path(model)
			if not FileAccess.file_exists(file):
				continue
			var image := Image.load_from_file(file)
			var used := image.get_used_rect()
			total += 1
			var side := maxi(used.size.x, used.size.y)
			if side < image.get_width() * 0.4:
				tiny.append([model, used])
			if used.position.x <= 0 or used.position.y <= 0 or used.end.x >= image.get_width() or used.end.y >= image.get_height():
				cropped.append([model, used])
	print("renders on disk: %d, tiny: %d, cropped: %d" % [total, tiny.size(), cropped.size()])
	for entry in tiny:
		print("  tiny    %s %s" % entry)
	for entry in cropped:
		print("  cropped %s %s" % entry)
	var dumps: Array = tiny.slice(0, 2) + cropped.slice(0, 2)
	for entry: Array in dumps:
		await _dump(renderer, String(entry[0]))
	# Render a few again, one after another and all at once.
	var scratch := OS.get_environment("DIAG_OUT")
	var models := ["meshes/weapons/1handpistol/44magnumrevolverunique.nif", "meshes/clutter/sportsequipment/baseball.nif",
			"meshes/dlc04/weapons/2handmelee/dlc04shovel.nif", "meshes/clutter/crate/cratelarge01.nif"]
	for model: String in models:
		var texture: Texture2D = await renderer._render(model)
		var image := texture.get_image()
		print("serial %s used %s cam %s" % [model, image.get_used_rect(), renderer._camera.position])
		image.save_png("%s/serial_%s.png" % [scratch, model.get_file()])
	get_tree().quit()

func _dump(renderer: Node, model: String) -> void:
	var delivery: Array = [null, false]
	renderer.request_model(model, func(tree: Node3D) -> void:
		delivery[0] = tree
		delivery[1] = true)
	while not delivery[1]:
		await get_tree().process_frame
	var tree: Node3D = delivery[0]
	if tree == null:
		return
	var pivot: Node3D = renderer._pivot
	if tree.get_parent() != null:
		tree.get_parent().remove_child(tree)
	pivot.add_child(tree)
	tree.visible = true
	print("\n%s  bounds %s" % [model, ThumbnailServer.model_bounds(tree, pivot)])
	for node in tree.find_children("*", "Node3D", true, false):
		var n := node as Node3D
		var line := "  %s%s (%s)%s%s" % ["  ".repeat(tree.get_path_to(n).get_name_count() - 1), n.name, n.get_class(),
				"" if n.is_visible_in_tree() else " hidden", " top_level" if n.top_level else ""]
		if n is VisualInstance3D:
			var box := pivot.global_transform.affine_inverse() * n.global_transform * (n as VisualInstance3D).get_aabb()
			line += " aabb %s size %s" % [box.position, box.size]
		if n is MeshInstance3D and (n as MeshInstance3D).skin != null:
			line += " SKINNED"
		print(line)
	tree.queue_free()
