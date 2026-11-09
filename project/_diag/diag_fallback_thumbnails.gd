extends Node
## Spawn menu: renders the ARMO and WEAP rows that show a fallback model (no
## world model or icon of their own, SpawnCatalog.shown_assets()) to
## $DIAG_OUT/fallback_sheet.png, to look at them. Run windowed:
## Godot --path . _diag/diag_fallback_thumbnails.tscn

func _ready() -> void:
	var esm_server: Node = get_node("/root/EsmServer")
	if not esm_server.is_ready():
		await esm_server.esm_ready
	var catalog := SpawnCatalog.new(esm_server.reader, esm_server.get_record_index(), get_node("/root/ArchiveServer"))
	var renderer: Node = ThumbnailServer
	var keys: Array = []
	for type: String in ["ARMO", "WEAP"]:
		for row: Dictionary in catalog.rows_for_type(type):
			if String(row["model"]).is_empty() and String(row["icon"]).is_empty() and not String(row["shown_model"]).is_empty():
				var key := SpawnMenuTab.thumbnail_model(row)
				print("%s %s -> %s" % [type, row["editor_id"], key])
				if not keys.has(key):
					keys.append(key)
	var size := ThumbnailServer.THUMBNAIL_SIZE
	var sheet := Image.create(size * 7, size * 2, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.16, 0.16, 0.18))
	for i in mini(keys.size(), 14):
		var texture: Texture2D = await renderer._render(keys[i])
		if texture == null:
			print("  NONE ", keys[i])
			continue
		var image := texture.get_image()
		image.decompress()
		image.clear_mipmaps()
		image.convert(Image.FORMAT_RGBA8)
		sheet.blend_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), Vector2i(i % 7 * size, i / 7 * size))
	sheet.save_png(OS.get_environment("DIAG_OUT") + "/fallback_sheet.png")
	get_tree().quit()
