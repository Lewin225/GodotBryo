extends Node

var failures := 0

const FIXTURE_HASHES := {
	# Negative/sparse edge, missing VCLR, missing BTXT, and max-overlay fixtures.
	Vector2i(-9, 0): ["db43aec27f96cd374146500fb8059b414b691f2d1f6c058aeeb72331e528deee", "8c4045fe3994fef04a1027f14fbe51103c1191ebb523d23d908ee25ed416b1c0", "acef6470b724278f129b60e1e494b0a4daa7a594f769ac4dd18cc9a2d3fbb9f7", "8a39d2abd3999ab73c34db2476849cddf303ce389b35826850f9a700589b4a90", "8a39d2abd3999ab73c34db2476849cddf303ce389b35826850f9a700589b4a90", "8a39d2abd3999ab73c34db2476849cddf303ce389b35826850f9a700589b4a90", "8a39d2abd3999ab73c34db2476849cddf303ce389b35826850f9a700589b4a90", "62628d533484b08d3a5b5486febc58a2b9021630c3c981ee438f9352ecd1703a"],
	Vector2i(-8, 7): ["5cb48bf81ceae9855d738ec7dd7b59af67d12ff44b091fba38d074febb00aecc", "8c4045fe3994fef04a1027f14fbe51103c1191ebb523d23d908ee25ed416b1c0", "0135dad7fe006b0047c0052c64f5158f1db926d42a2817b0a5320ad4b3709c2b", "8a39d2abd3999ab73c34db2476849cddf303ce389b35826850f9a700589b4a90", "8a39d2abd3999ab73c34db2476849cddf303ce389b35826850f9a700589b4a90", "8a39d2abd3999ab73c34db2476849cddf303ce389b35826850f9a700589b4a90", "8a39d2abd3999ab73c34db2476849cddf303ce389b35826850f9a700589b4a90", "4bea866f2df0a2be705fcac73de1fea023cbb3e5e4c6685bd7c2a3252c2f14be"],
	Vector2i(-5, -3): ["9d43f22c19cb61c8c9b45126e2ee52b91c4463d64226d79a8092126049c66450", "8c4045fe3994fef04a1027f14fbe51103c1191ebb523d23d908ee25ed416b1c0", "4e272bdde3632c9c8bcbf0291ad4db13dcc251a96cd0be21152285e6e704975b", "529294c0f72f358d888e804999e267a93c64499b8b900a87b2b135039f5deaf9", "8a39d2abd3999ab73c34db2476849cddf303ce389b35826850f9a700589b4a90", "8a39d2abd3999ab73c34db2476849cddf303ce389b35826850f9a700589b4a90", "8a39d2abd3999ab73c34db2476849cddf303ce389b35826850f9a700589b4a90", "f94c5af1e22cef33af659bc5636c338347dfabc122874c981f6a3fc796db9b76"],
	Vector2i(-4, -3): ["564378b2646573f4ef60cc09860b93ef301d89e200e9b48abae6a72131404bb6", "8c4045fe3994fef04a1027f14fbe51103c1191ebb523d23d908ee25ed416b1c0", "24ac7a9e21aa87d15850139e5a041ca3cbdd29e93da7e57b2b4a4951d08c59fe", "569340d4b31fac5bddf925af9da24e43f26ee0b957276b216adc5744abf6e990", "0f422898d6e8aa602d30627c302ca00e51768939a1d4bc76bdc8a85381b03aeb", "d1c8af684c43a30ea1811772d1253bf211aec3c488d4d3d42ef24b41621bf448", "66da3e978d1162e034f5c399f31d9ee26e039b1565fe67af14bec7da8b6d0962", "49b1a0610b9bc285a5a5cd55bce90f4fc051b05bc8252c0d760cc5b6ed38e37d"],
}

func check(condition: bool, message: String) -> void:
	if condition:
		print("  OK   ", message)
	else:
		print("  FAIL ", message)
		failures += 1

func _ready() -> void:
	var config := GameDataConfig.resolve()
	check(String(config.error).is_empty(), "game data is available")
	if not String(config.error).is_empty():
		finish()
		return
	var esm := EsmReader.new()
	check(esm.open(String(config.data_dir) + GameDataConfig.ESM_FILE), "reference ESM opens")
	var world: Dictionary = esm.find_worldspace_by_editor_id("WastelandNV")
	check(not world.is_empty(), "WastelandNV resolves")
	var stager := TerrainRegionStager.new()
	check(stager.open_esm(String(config.data_dir) + GameDataConfig.ESM_FILE), "native worker reader opens")
	var started := Time.get_ticks_usec()
	var catalogue: Dictionary = stager.index_worldspace(int(world.form_id))
	print("  INFO catalogue_ms=%.3f" % (float(Time.get_ticks_usec() - started) / 1000.0))
	check(String(catalogue.get("error", "")).is_empty(), "native catalogue builds")
	check(Array(catalogue.get("usable_cells", [])).size() == 16388, "catalogue has 16,388 usable first-LAND cells")
	check(Array(catalogue.get("regions", [])).size() == 292, "catalogue has 292 touched regions")
	check(Vector2i(Dictionary(catalogue.get("region_bounds", {})).get("size", Vector2i.ZERO)) == Vector2i(18, 18), "fixed domain is 18x18")
	var ltex_ids: PackedInt64Array = catalogue.get("ltex_form_ids", PackedInt64Array())
	check(ltex_ids.size() == 80, "catalogue has the expected 80-LTEX logical domain")
	var sorted_ids := Array(ltex_ids)
	sorted_ids.sort()
	check(Array(ltex_ids) == sorted_ids, "LTEX identities are unsigned-ascending and deterministic")
	var slots := {}
	for i in range(ltex_ids.size()):
		slots[int(ltex_ids[i])] = i + 1
	var location := Vector2i(-3, -1) # contains Goodsprings (-17, 0)
	check(not String(stager.compose_region(int(world.form_id), location, {}).get("error", "")).is_empty(),
			"composition rejects an incomplete logical-slot table")
	var noncanonical_slots := slots.duplicate()
	noncanonical_slots[int(ltex_ids[0])] = 2
	check(not String(stager.compose_region(int(world.form_id), location, noncanonical_slots).get("error", "")).is_empty(),
			"composition rejects a noncanonical logical-slot assignment")
	started = Time.get_ticks_usec()
	var payload: Dictionary = stager.compose_region(int(world.form_id), location, slots)
	print("  INFO compose_ms=%.3f contributors=%d" % [float(Time.get_ticks_usec() - started) / 1000.0, Array(payload.get("contributing_cells", [])).size()])
	check(String(payload.get("error", "")).is_empty(), "native region composition succeeds")
	var maps: Array = payload.get("maps", [])
	check(maps.size() == 8, "composition returns all eight maps")
	for i in range(maps.size()):
		var image: Image = maps[i]
		check(image != null and image.get_size() == Vector2i(256, 256), "map %d is detached 256x256 data" % i)
		check(image.get_format() == (Image.FORMAT_RF if i <= 1 else Image.FORMAT_RGBA8), "map %d has the required format" % i)
	var first_order := FIXTURE_HASHES.keys()
	first_order.shuffle()
	var first_results := _compose_hashes(stager, int(world.form_id), slots, first_order)
	var second_order := first_order.duplicate()
	second_order.reverse()
	var second_results := _compose_hashes(stager, int(world.form_id), slots, second_order)
	for fixture: Vector2i in FIXTURE_HASHES:
		check(first_results[fixture] == PackedStringArray(FIXTURE_HASHES[fixture]), "fixture %s matches all eight oracle hashes" % fixture)
		check(second_results[fixture] == first_results[fixture], "fixture %s is completion-order independent" % fixture)
	var native_source := FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://../native/terrain_streamer/src/terrain_region_stager.cpp"))
	check(native_source.find("RenderingServer") == -1 and native_source.find("PhysicsServer") == -1
			and native_source.find("Terrain3DData") == -1 and native_source.find("Node3D") == -1,
			"worker implementation has no rendering, physics, Terrain3D, or scene-object access")
	var synthetic_heights := PackedFloat32Array()
	synthetic_heights.resize(33 * 33)
	for row in range(33):
		for col in range(33):
			synthetic_heights[row * 33 + col] = float(col) * 0.25 + float(row) * 0.5
	var native_fallback: PackedByteArray = stager.compose_computed_normal_fixture(synthetic_heights)
	var expected_fallback := PackedByteArray()
	expected_fallback.resize(33 * 33 * 4)
	for row in range(33):
		for col in range(33):
			var h_l := synthetic_heights[row * 33 + maxi(col - 1, 0)]
			var h_r := synthetic_heights[row * 33 + mini(col + 1, 32)]
			var h_d := synthetic_heights[maxi(row - 1, 0) * 33 + col]
			var h_u := synthetic_heights[mini(row + 1, 32) * 33 + col]
			var dx := Vector3(2.0 * Terrain3DBridge.VERTEX_SPACING, h_r - h_l, 0.0)
			var dz := Vector3(0.0, h_u - h_d, -2.0 * Terrain3DBridge.VERTEX_SPACING)
			var normal := dx.cross(dz).normalized()
			var offset := (row * 33 + col) * 4
			expected_fallback[offset] = int(clampf((normal.x * 0.5 + 0.5) * 255.0, 0.0, 255.0))
			expected_fallback[offset + 1] = int(clampf((normal.y * 0.5 + 0.5) * 255.0, 0.0, 255.0))
			expected_fallback[offset + 2] = int(clampf((normal.z * 0.5 + 0.5) * 255.0, 0.0, 255.0))
			expected_fallback[offset + 3] = 255
	check(native_fallback == expected_fallback, "missing-VNML computed-normal fallback is byte-identical to the bridge formula")
	finish()

func _compose_hashes(stager: TerrainRegionStager, world_id: int, slots: Dictionary, locations: Array) -> Dictionary:
	var output := {}
	for location: Vector2i in locations:
		var payload: Dictionary = stager.compose_region(world_id, location, slots)
		var hashes := PackedStringArray()
		for image: Image in payload.maps:
			var context := HashingContext.new()
			context.start(HashingContext.HASH_SHA256)
			context.update(image.get_data())
			hashes.append(context.finish().hex_encode())
		output[location] = hashes
	return output

func finish() -> void:
	print("=======================")
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(1 if failures else 0)
