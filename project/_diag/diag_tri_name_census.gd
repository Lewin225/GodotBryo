extends SceneTree
## Census: the difference and statistical morph names of every TRI, against
## the channels skeleton.nif's HeadAnims morpher declares.
func _init() -> void:
	var bsa := BsaReader.new()
	bsa.open(GameDataConfig.resolve()["data_dir"] + "Fallout - Meshes.bsa")
	var skeleton := NifReader.new()
	skeleton.load(bsa.extract("meshes/characters/_male/skeleton.nif"))
	var channels := {}
	for t in skeleton.get_morph_data()[0]["targets"]:
		channels[t["name"]] = true
	var name_files := {}
	for path in bsa.list_entries():
		if not path.ends_with(".tri"):
			continue
		var tri := TriReader.new()
		if not tri.load(bsa.extract(path), path):
			print("FAILED ", path, " ", tri.get_last_error())
			continue
		var diff := []
		for i in tri.get_delta_morph_count():
			diff.append(tri.get_delta_morph_name(i))
		var stat := []
		for i in tri.get_statistical_morph_count():
			stat.append(tri.get_statistical_morph_name(i))
		print("%s V=%d K=%d diff=%s stat=%s" % [path.get_file(), tri.get_vertex_count(), tri.get_statistical_vertex_count(), diff, stat])
		for n in diff + stat:
			if not name_files.has(n):
				name_files[n] = 0
			name_files[n] += 1
	var missing := []
	for n in name_files:
		if not channels.has(n):
			missing.append(n)
	var unused := []
	for n in channels:
		if not name_files.has(n):
			unused.append(n)
	print("TRI names not a skeleton channel: ", missing)
	print("skeleton channels in no TRI: ", unused)
	quit()
