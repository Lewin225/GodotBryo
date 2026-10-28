extends SceneTree
## Census: which character NIFs carry their own morph data (NiMorphData), and
## whether the NIFs paired with a TRI do.
func _init() -> void:
	var data_dir: String = GameDataConfig.resolve()["data_dir"]
	var bsa := BsaReader.new()
	bsa.open(data_dir + "Fallout - Meshes.bsa")
	var entries: PackedStringArray = bsa.list_entries()
	var tri_stems := {}
	for path in entries:
		if path.to_lower().ends_with(".tri"):
			tri_stems[path.to_lower().get_basename()] = path
	var with_morph := 0
	var character_nifs := 0
	var tri_nifs := 0
	var tri_nifs_with_morph := 0
	for path in entries:
		var lower := path.to_lower()
		if not lower.ends_with(".nif") or not lower.begins_with("meshes/characters"):
			continue
		character_nifs += 1
		var nif := NifReader.new()
		if not nif.load(bsa.extract(path)):
			continue
		var morphs: Array = nif.get_morph_data()
		var paired := tri_stems.has(lower.get_basename())
		if paired:
			tri_nifs += 1
		if morphs.is_empty():
			continue
		with_morph += 1
		if paired:
			tri_nifs_with_morph += 1
		var names := []
		for m in morphs:
			for t in m.get("targets", []):
				names.append(t.get("name", ""))
		print("MORPH ", path, " tri=", paired, " ", names.slice(0, 12))
	print("character NIFs %d, with morph data %d; TRI-paired NIFs %d, with morph data %d" % [character_nifs, with_morph, tri_nifs, tri_nifs_with_morph])
	quit()
