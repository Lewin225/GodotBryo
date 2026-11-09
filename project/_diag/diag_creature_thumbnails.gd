extends Node
## Spawn menu creature thumbnails: for every CREA in FalloutNV.esm, whether
## SpawnCatalog finds body parts (own NIFZ, or a CREA template's), how many
## distinct part sets there are, and renders of a few, saved as a sheet to
## $DIAG_OUT/creature_sheet.png to check that skinned parts with no skeleton
## draw in their bind pose. Run windowed:
## Godot --path . _diag/diag_creature_thumbnails.tscn

const SAMPLES := ["gecko", "deathclaw", "radscorpion", "cazador", "bighorner", "nightstalker",
		"mrhandy", "securitron", "giantant", "coyote", "bloatfly", "supermutant"]

func _ready() -> void:
	var esm_server: Node = get_node("/root/EsmServer")
	if not esm_server.is_ready():
		await esm_server.esm_ready
	var catalog := SpawnCatalog.new(esm_server.reader, esm_server.get_record_index(), get_node("/root/ArchiveServer"))
	var rows := catalog.rows_for_type("CREA")
	var with_parts := 0
	var own_model := 0
	var from_template := 0
	var keys := {}
	var none: Array = []
	for row: Dictionary in rows:
		var key := SpawnMenuTab.thumbnail_model(row)
		if key.is_empty():
			none.append("%s %s" % [row["editor_id"], row["model"]])
			continue
		with_parts += 1
		if String(row["model"]).is_empty():
			from_template += 1
		else:
			own_model += 1
		keys[key] = true
	print("CREA rows %d: with parts %d (own MODL %d, from a template %d), none %d; distinct part sets %d"
			% [rows.size(), with_parts, own_model, from_template, none.size(), keys.size()])
	for line in none.slice(0, 12):
		print("  none  ", line)
	# Why: a TPLT, and what it points at; or no MODL and no TPLT.
	var reasons := {}
	var reader: EsmReader = esm_server.reader
	for row: Dictionary in rows:
		if not SpawnMenuTab.thumbnail_model(row).is_empty():
			continue
		var raw: Dictionary = reader.get_record_data(int(row["form_id"]))
		var why := "no TPLT"
		var has_nifz := false
		for sub: Dictionary in raw["subrecords"]:
			if sub["type"] == "NIFZ":
				has_nifz = true
			if sub["type"] == "TPLT" and (sub["data"] as PackedByteArray).size() >= 4:
				var target: Dictionary = reader.get_record_data((sub["data"] as PackedByteArray).decode_u32(0))
				why = "TPLT -> %s" % target.get("record_type", "?")
		why += ", own NIFZ" if has_nifz else ", no NIFZ"
		why += ", MODL" if not String(row["model"]).is_empty() else ", no MODL"
		reasons[why] = int(reasons.get(why, 0)) + 1
	print("no parts, by reason: ", reasons)

	var renderer: Node = ThumbnailServer
	var picked: Array = []
	for word: String in SAMPLES:
		for key: String in keys:
			if key.to_lower().contains(word) and not picked.has(key):
				picked.append(key)
				break
	var size := ThumbnailServer.THUMBNAIL_SIZE
	var sheet := Image.create(size * 6, size * 2, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.16, 0.16, 0.18))
	for i in picked.size():
		var texture: Texture2D = await renderer._render(picked[i])
		var image := texture.get_image() if texture != null else null
		print("  %s  %s" % ["drawn" if image != null else "NONE ", picked[i]])
		if image == null:
			continue
		image.decompress()
		image.clear_mipmaps()
		image.convert(Image.FORMAT_RGBA8)
		sheet.blend_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), Vector2i(i % 6 * size, i / 6 * size))
	sheet.save_png(OS.get_environment("DIAG_OUT") + "/creature_sheet.png")
	get_tree().quit()
