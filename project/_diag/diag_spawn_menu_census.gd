extends SceneTree
## Census for the spawn menu plan (Plans/SpawnMenu/spawn_menu.md): per
## placeable base type in FalloutNV.esm, how many records have FULL, a world
## model (MODL; ARMO's MOD2), an ICON and whether that icon is in an archive,
## a non-zero OBND, and the top-level meshes/ folders of their models.
const TYPES := ["ACTI","ALCH","AMMO","ARMO","BOOK","CCRD","CMNY","CONT","CREA","DOOR","FURN","IDLM","KEYM","LIGH","LVLC","LVLI","LVLN","MISC","MSTT","NOTE","NPC_","SCOL","STAT","TACT","TERM","TREE","WEAP","FLST","IMOD","CHIP","GRAS"]
func _str(data: PackedByteArray) -> String:
	return data.get_string_from_ascii().replace("\\", "/").to_lower()
func _init() -> void:
	var data_dir: String = GameDataConfig.resolve()["data_dir"]
	var esm := EsmReader.new()
	esm.open(data_dir + "FalloutNV.esm")
	var catalog := ArchiveCatalog.new()
	catalog.open_data_dir(data_dir)
	var stats := {}
	for row in esm.get_record_index():
		var t := String(row["record_type"])
		if t not in TYPES:
			continue
		if not stats.has(t):
			stats[t] = {"n": 0, "name": 0, "model": 0, "model_found": 0, "icon": 0, "icon_found": 0, "obnd": 0, "dirs": {}}
		var s: Dictionary = stats[t]
		s.n += 1
		var model := ""
		var icon := ""
		var has_name := false
		var obnd := false
		for sub in esm.get_record_data(int(row["form_id"]))["subrecords"]:
			var tag := String(sub["type"])
			var d: PackedByteArray = sub["data"]
			if tag == "FULL" and d.size() > 1: has_name = true
			elif tag == "OBND":
				for b in d: if b != 0: obnd = true
			elif model == "" and (tag == "MODL" if t != "ARMO" else tag == "MOD2"): model = _str(d)
			elif icon == "" and tag == "ICON": icon = _str(d)
		if has_name: s.name += 1
		if obnd: s.obnd += 1
		if model != "":
			s.model += 1
			if catalog.contains("meshes/" + model): s.model_found += 1
			var parts := model.split("/")
			var dir := parts[0] if parts.size() > 1 else "(root)"
			s.dirs[dir] = int(s.dirs.get(dir, 0)) + 1
		if icon != "":
			s.icon += 1
			if catalog.contains("textures/" + icon): s.icon_found += 1
	for t in TYPES:
		if not stats.has(t): continue
		var s: Dictionary = stats[t]
		var dirs: Array = s.dirs.keys()
		dirs.sort_custom(func(a, b): return s.dirs[a] > s.dirs[b])
		var top := []
		for d in dirs.slice(0, 6): top.append("%s:%d" % [d, s.dirs[d]])
		print("%s n=%d full=%d model=%d (in bsa %d) icon=%d (in bsa %d) obnd=%d dirs=%d top=%s" % [t, s.n, s.name, s.model, s.model_found, s.icon, s.icon_found, s.obnd, dirs.size(), top])
	quit()
