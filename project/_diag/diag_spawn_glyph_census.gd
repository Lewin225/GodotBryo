extends Node
## Spawn menu: per type, the rows that still show the category glyph (no ICON
## and no model to preview, SpawnMenuTab.thumbnail_model()), and which
## subrecords those rows do carry, to find other models or icons to use.
## Also, for LVLI, what its lowest-level entry is.
## Godot --headless --path . _diag/diag_spawn_glyph_census.tscn

func _ready() -> void:
	var esm_server: Node = get_node("/root/EsmServer")
	if not esm_server.is_ready():
		await esm_server.esm_ready
	var reader: EsmReader = esm_server.reader
	var catalog := SpawnCatalog.new(reader, esm_server.get_record_index(), get_node("/root/ArchiveServer"))
	var archives = get_node("/root/ArchiveServer")
	for type: String in SpawnCatalog.all_types():
		var rows := catalog.rows_for_type(type)
		var glyph: Array = rows.filter(func(r: Dictionary) -> bool:
			return String(r["icon"]).is_empty() and SpawnMenuTab.thumbnail_model(r).is_empty())
		if glyph.is_empty():
			continue
		var tags := {}
		var examples: Array = []
		for row: Dictionary in glyph:
			var seen := {}
			for sub: Dictionary in reader.get_record_data(int(row["form_id"]))["subrecords"]:
				seen[String(sub["type"])] = true
			for tag in seen:
				tags[tag] = int(tags.get(tag, 0)) + 1
			if examples.size() < 4:
				examples.append(row["editor_id"])
		var listed := []
		for tag in tags:
			listed.append([tags[tag], tag])
		listed.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
		print("%s: %d of %d show the glyph; e.g. %s" % [type, glyph.size(), rows.size(), examples])
		print("    subrecords: %s" % ", ".join(listed.slice(0, 22).map(func(e: Array) -> String: return "%s %d" % [e[1], e[0]])))

	# Model and icon alternatives, and whether an archive has them.
	for spec: Array in [["ARMO", ["MODL", "MOD2", "MOD3", "MOD4", "ICON", "ICO2"]], ["NOTE", ["MODL", "ICON", "DATA"]],
			["WEAP", ["MODL", "ICON", "MOD2", "MOD3", "MOD4"]], ["LIGH", ["MODL", "ICON"]], ["ACTI", ["MODL"]]]:
		var type: String = spec[0]
		var counts := {}
		for row: Dictionary in catalog.rows_for_type(type):
			if not (String(row["icon"]).is_empty() and SpawnMenuTab.thumbnail_model(row).is_empty()):
				continue
			for sub: Dictionary in reader.get_record_data(int(row["form_id"]))["subrecords"]:
				var tag := String(sub["type"])
				if tag in spec[1]:
					var data: PackedByteArray = sub["data"]
					var value := data.get_string_from_ascii().replace("\\", "/").to_lower() if tag != "DATA" else str(data[0] if data.size() > 0 else -1)
					var found := ""
					if tag.begins_with("MOD"):
						found = " in BSA" if archives.contains("meshes/" + value) else " MISSING"
					elif tag.begins_with("ICO"):
						found = " in BSA" if archives.contains("textures/" + value) else " MISSING"
					var key := tag + found
					counts[key] = int(counts.get(key, 0)) + 1
		print("%s glyph rows' alternatives: %s" % [type, counts])

	# LVLI: the lowest-level entry's type, and whether it has an icon or model.
	var kinds := {}
	for row: Dictionary in catalog.rows_for_type("LVLI"):
		var raw: Dictionary = reader.get_record_data(int(row["form_id"]))
		var entry := 0
		for _hop in 8:
			var lowest := 0x10000
			entry = 0
			for sub: Dictionary in raw["subrecords"]:
				var data: PackedByteArray = sub["data"]
				if sub["type"] == "LVLO" and data.size() >= 8 and data.decode_u16(0) < lowest:
					lowest = data.decode_u16(0)
					entry = data.decode_u32(4)
			if entry == 0:
				break
			raw = reader.get_record_data(entry)
			if String(raw.get("record_type", "")) != "LVLI":
				break
		var kind := String(raw.get("record_type", "none")) if entry != 0 else "no entries"
		var has_icon := false
		var has_model := false
		for sub: Dictionary in raw.get("subrecords", []):
			if sub["type"] == "ICON": has_icon = true
			if sub["type"] in ["MODL", "MOD2"]: has_model = true
		kind += " icon" if has_icon else (" model" if has_model else " neither")
		kinds[kind] = int(kinds.get(kind, 0)) + 1
	print("LVLI lowest-level entries: ", kinds)
	get_tree().quit()
