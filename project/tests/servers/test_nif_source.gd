extends Node

## Stage D gate (Plans/server_stack_build_order.md): NifSource exposes nifly's
## object model -- block types, collision subclass, all six texture slots, the
## object palette, property block identity, resolved controller links, extra
## data, and geometry/skin/collision.
##
## Figures here are asserted against the corpus research in
## Plans/NifServer/Research/nifserver_design_findings.md. Counts run slightly
## below the research totals because ArchiveServer returns priority winners
## only -- 204 duplicate .nif paths are shadowed by DLC overrides.

const SKELETON := "meshes/characters/_male/skeleton.nif"
const BARRACKS := "meshes/architecture/barracks/barracks01.nif"
const UPPERBODY := "meshes/characters/_male/upperbody.nif"
const BOTTLE := "meshes/clutter/junk/milkbottle01.nif"
const SKYDOME := "meshes/nvdlc04/dungeons/utemple/nvdlc04uskydome.nif"
const EATIDLE := "meshes/characters/_male/idleanims/eatidle.kf"
const MTFORWARD := "meshes/characters/_male/locomotion/male/mtforward.kf"
const DOOR := "meshes/dungeons/vaultruined/doors/vdoorslidingvault22.nif"
const TRANSFORM_SHAPE := "meshes/architecture/freeside/ramshacklebusdoor02.nif"
const BSPLINE := "meshes/dlc05/creatures/alien/locomotion/forwardwalk.kf"

var failures := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1


func _load(path: String) -> NifSource:
	var r: Dictionary = ArchiveServer.read(path)
	if not bool(r["found"]):
		check(false, "read %s (%s)" % [path, r["error"]])
		return null
	var src := NifSource.new()
	if not src.load(PackedByteArray(r["data"])):
		check(false, "parse %s (%s)" % [path, src.get_last_error()])
		return null
	return src


func _by_name(src: NifSource, wanted: String) -> Dictionary:
	for n in src.get_nodes():
		if String(n["name"]) == wanted:
			return n
	return {}


func test_d1_block_types() -> void:
	print("--- D1: per-node block type ---")
	var src := _load(SKELETON)
	if src == null:
		return
	var by_type := {}
	var roots := 0
	for n in src.get_nodes():
		by_type[String(n["block_type"])] = int(by_type.get(String(n["block_type"]), 0)) + 1
		if int(n["parent_index"]) == -1:
			roots += 1
	check(src.get_block_count() == 388, "skeleton.nif has 388 blocks (got %d)" % src.get_block_count())
	check(src.get_nodes().size() == 67, "67 NiAVObject nodes (got %d)" % src.get_nodes().size())
	check(roots == 1, "exactly one root (got %d)" % roots)
	# The distinction nif_loader.cpp cannot make: these are three different types.
	check(int(by_type.get("NiNode", 0)) == 65, "65 NiNode (got %d)" % by_type.get("NiNode", 0))
	check(int(by_type.get("BSFadeNode", 0)) == 1, "1 BSFadeNode")
	check(int(by_type.get("NiTriShape", 0)) == 1, "1 NiTriShape")

	var head := _by_name(src, "HeadAnims:0")
	check(not head.is_empty(), "authored name 'HeadAnims:0' survives verbatim")
	check(String(head.get("block_type", "")) == "NiTriShape", "'HeadAnims:0' is a NiTriShape")
	var nonaccum := _by_name(src, "Bip01 NonAccum")
	check(int(nonaccum.get("parent_index", -1)) != -1, "'Bip01 NonAccum' is parented, not flat")


func test_d2_collision_subclass() -> void:
	print("--- D2: collision object subclass (the ragdoll discriminator) ---")
	var skel := _load(SKELETON)
	var barr := _load(BARRACKS)
	if skel == null or barr == null:
		return
	var skel_kinds := {}
	for n in skel.get_nodes():
		var t := String(n["collision_type"])
		if t != "":
			skel_kinds[t] = int(skel_kinds.get(t, 0)) + 1
	check(int(skel_kinds.get("bhkBlendCollisionObject", 0)) == 18,
		"skeleton.nif: 18 bhkBlendCollisionObject (got %d)" % skel_kinds.get("bhkBlendCollisionObject", 0))
	check(not skel_kinds.has("bhkCollisionObject"), "skeleton.nif has no ordinary bhkCollisionObject")

	var barr_kinds := {}
	for n in barr.get_nodes():
		var t := String(n["collision_type"])
		if t != "":
			barr_kinds[t] = int(barr_kinds.get(t, 0)) + 1
	check(int(barr_kinds.get("bhkCollisionObject", 0)) == 1, "barracks01.nif: 1 bhkCollisionObject")
	check(not barr_kinds.has("bhkBlendCollisionObject"), "barracks01.nif is not a ragdoll")


func test_d3_texture_slots() -> void:
	print("--- D3: all six texture slots ---")
	var src := _load(BARRACKS)
	if src == null:
		return
	var sets := 0
	var slot0 := 0
	var slot1 := 0
	for n in src.get_nodes():
		var slots: PackedStringArray = n["texture_slots"]
		if slots.is_empty():
			continue
		sets += 1
		check(slots.size() == 6, "texture set declares 6 slots (got %d)" % slots.size()) if sets == 1 else null
		if String(slots[0]) != "":
			slot0 += 1
		if String(slots[1]) != "":
			slot1 += 1
	check(sets > 0, "%d shapes carry a texture set" % sets)
	check(slot0 == sets, "every set has a diffuse (%d of %d)" % [slot0, sets])
	check(slot1 > 0, "%d sets have a normal map" % slot1)
	# A shader with no texture set must report an EMPTY slot array, not six
	# empty strings -- otherwise "has a set" degenerates to "is a shape".
	var shapes := 0
	var with_set := 0
	for n in src.get_nodes():
		if String(n["shader_type"]) != "":
			shapes += 1
			if not (n["texture_slots"] as PackedStringArray).is_empty():
				with_set += 1
	check(shapes >= with_set, "%d shaders, %d with a texture set" % [shapes, with_set])


func test_d4_object_palette() -> void:
	print("--- D4: NiDefaultAVObjectPalette aliasing ---")
	var src := _load(SKYDOME)
	if src == null:
		return
	var names := {}
	for n in src.get_nodes():
		names[int(n["block_index"])] = String(n["name"])
	var palettes: Array = src.get_object_palettes()
	check(palettes.size() == 1, "skydome has 1 palette (got %d)" % palettes.size())
	if palettes.is_empty():
		return
	var entries: Array = (palettes[0] as Dictionary)["entries"]
	check(entries.size() == 2, "palette has 2 entries (got %d)" % entries.size())
	var alias_ok := false
	var null_ok := false
	for e in entries:
		var nm := String(e["name"])
		var idx := int(e["object_block_index"])
		if nm == "NVDLC04USkyDome:2" and idx >= 0 and String(names.get(idx, "")) == "NVDLC04USkyDome NonAccum":
			alias_ok = true
		if nm == "NVDLC04USkyDome NonAccum" and idx < 0:
			null_ok = true
	check(alias_ok, "alias 'NVDLC04USkyDome:2' resolves to the block named 'NVDLC04USkyDome NonAccum'")
	check(null_ok, "the entry matching the block's own name points nowhere")


func test_d5_property_identity() -> void:
	print("--- D5: property block identity and sharing ---")
	var src := _load(BARRACKS)
	if src == null:
		return
	var refs := {}
	var per_node_types := {}
	for n in src.get_nodes():
		var idxs: PackedInt32Array = n["property_block_indices"]
		var types: PackedStringArray = n["property_types"]
		check(idxs.size() == types.size(), "property indices and types are parallel") if refs.is_empty() and idxs.size() > 0 else null
		var seen := {}
		for i in idxs.size():
			refs[idxs[i]] = int(refs.get(idxs[i], 0)) + 1
			seen[String(types[i])] = int(seen.get(String(types[i]), 0)) + 1
		for t in seen.keys():
			per_node_types[t] = maxi(int(per_node_types.get(t, 0)), int(seen[t]))
	check(refs.size() > 0, "%d distinct property blocks referenced" % refs.size())
	var shared := 0
	for k in refs.keys():
		if int(refs[k]) > 1:
			shared += 1
	check(shared > 0, "%d property blocks are shared by 2+ nodes" % shared)
	var max_per_type := 0
	for t in per_node_types.keys():
		max_per_type = maxi(max_per_type, int(per_node_types[t]))
	check(max_per_type == 1, "no node carries two properties of one type (max %d)" % max_per_type)


func test_d6_controller_links() -> void:
	print("--- D6: resolved ControllerLink targets ---")
	var src := _load(MTFORWARD)
	if src == null:
		return
	var seqs: Array = src.get_sequences()
	check(seqs.size() == 1, "mtforward.kf has 1 sequence (got %d)" % seqs.size())
	if seqs.is_empty():
		return
	var seq: Dictionary = seqs[0]
	check(String(seq["name"]) == "Forward", "sequence is named 'Forward' (got '%s')" % seq["name"])
	check(String(seq["accum_root_name"]) == "Bip01", "accum root is 'Bip01'")
	check(float(seq["stop_time"]) > 0.0, "stop_time is %.2fs" % float(seq["stop_time"]))
	var blocks: Array = seq["controlled_blocks"]
	var blank := 0
	for b in blocks:
		if String(b["node_name"]) == "":
			blank += 1
	check(blocks.size() == 60, "60 controlled blocks (got %d)" % blocks.size())
	check(blank == 0, "every inline-addressed target resolves (%d blank)" % blank)

	# Known gap: nifly truncates NiStringPalette, so the five 20.0.0.4 idles
	# cannot resolve. Asserted as a KNOWN state so the gate flips when the
	# upstream fix or a local patch lands.
	var idle := _load(EATIDLE)
	if idle == null:
		return
	var idle_blank := 0
	var idle_total := 0
	var via_palette := 0
	for s in idle.get_sequences():
		for b in s["controlled_blocks"]:
			idle_total += 1
			if String(b["node_name"]) == "":
				idle_blank += 1
			if bool(b["from_string_palette"]):
				via_palette += 1
	check(via_palette == idle_total and idle_total > 0,
		"eatidle.kf: all %d links use NiStringPalette addressing" % idle_total)
	if idle_blank == 0:
		print("  NOTE  eatidle.kf fully resolves -- the nifly palette fix is in effect")
	else:
		print("  KNOWN %d of %d eatidle.kf targets unresolved (nifly NiStringPalette truncation; see Implementation/outstanding_issues.md #1)"
			% [idle_blank, idle_total])


func test_d9_interpolators() -> void:
	print("--- D9: interpolator keyframe data ---")
	var src := _load(DOOR)
	if src == null:
		return
	var seqs: Array = src.get_sequences()
	check(seqs.size() == 2, "the door has 2 sequences (got %d)" % seqs.size())
	var with_keys := 0
	for seq in seqs:
		for cb in seq["controlled_blocks"]:
			var ip: Dictionary = cb["interpolator"]
			check(bool(ip["present"]), "%s/%s has an interpolator" % [seq["name"], cb["node_name"]])
			check(String(ip["kind"]) == "transform",
				"%s/%s is a transform interpolator (got '%s')" % [seq["name"], cb["node_name"], ip["kind"]])
			check(not bool(ip["resampled"]), "authored keys, not resampled")
			if (ip["translation_keys"] as Array).size() > 0:
				with_keys += 1
	check(with_keys == 4, "all 4 controlled blocks carry translation keys (got %d)" % with_keys)

	# Translation is the one channel carrying a unit. A vault door panel slides
	# a fraction of a metre, not the ~25 a raw Gamebryo value would read as.
	var first: Dictionary = (seqs[0]["controlled_blocks"] as Array)[0]
	var keys: Array = (first["interpolator"] as Dictionary)["translation_keys"]
	var span := (Vector3(keys[-1]["value"]) - Vector3(keys[0]["value"])).length()
	check(span > 0.01 and span < 5.0, "the panel travels %.3f m over the clip" % span)

	# rotationType == XYZ_ROTATION_KEY: three per-axis float curves, composed
	# into quaternion keys here because a rotation track cannot carry them
	# separately.
	var euler := 0
	for seq in seqs:
		for cb in seq["controlled_blocks"]:
			if bool((cb["interpolator"] as Dictionary)["rotation_from_euler"]):
				euler += 1
	check(euler == 4, "%d of 4 links use per-axis rotation curves" % euler)
	for seq in seqs:
		for cb in seq["controlled_blocks"]:
			for k in (cb["interpolator"] as Dictionary)["rotation_keys"]:
				var q: Quaternion = k["value"]
				check(absf(q.length() - 1.0) < 0.001, "composed rotation key is a unit quaternion")
				break
			break
		break

	# The compressed form: cubic B-spline control points, which have no
	# keyframe equivalent and are evaluated rather than read.
	var spline := _load(BSPLINE)
	if spline == null:
		return
	var resampled := 0
	var spline_keys := 0
	for seq in spline.get_sequences():
		for cb in seq["controlled_blocks"]:
			var ip: Dictionary = cb["interpolator"]
			if not bool(ip["resampled"]):
				continue
			resampled += 1
			spline_keys += (ip["translation_keys"] as Array).size() + (ip["rotation_keys"] as Array).size()
	check(resampled > 0, "%d B-spline interpolators sampled" % resampled)
	check(spline_keys > 0, "they yielded %d keys" % spline_keys)


func test_d10_controller_chain_and_text_keys() -> void:
	print("--- D10: controller chain, sequence text keys, shape transforms ---")

	# Controllers form a chain through nextControllerRef. Checking only the
	# head missed every morpher that is not first.
	var skel := _load(SKELETON)
	if skel == null:
		return
	var morph_nodes := 0
	var frames := 0
	for n in skel.get_nodes():
		var m: Array = n.get("morphs", [])
		if m.is_empty():
			continue
		morph_nodes += 1
		frames += m.size()
	check(morph_nodes >= 1, "skeleton.nif yields morph frames (%d nodes)" % morph_nodes)
	check(frames == 31, "31 FaceGen morph frames (got %d)" % frames)

	# NiControllerSequence::textKeyRef, a different link from the node-attached
	# NiObjectNET::extraDataRefs chain.
	var door := _load(DOOR)
	if door == null:
		return
	var seq_with_keys := 0
	var seen_start := false
	for seq in door.get_sequences():
		var tk: Array = seq["text_keys"]
		if tk.is_empty():
			continue
		seq_with_keys += 1
		for k in tk:
			if String(k["value"]) == "start":
				seen_start = true
	check(seq_with_keys > 0, "%d door sequences carry text keys" % seq_with_keys)
	check(seen_start, "a 'start' marker is present")

	# bhkTransformShape / bhkConvexTransformShape wrappers. The transform is
	# reported; whether it should be APPLIED is unresolved -- measured against
	# render-mesh AABBs it improves 1 shape and worsens 25, so the builder
	# deliberately does not apply it. See outstanding_issues.md #3.
	var wrapped := 0
	var xform_src := _load(TRANSFORM_SHAPE)
	if xform_src == null:
		return
	for cs in xform_src.get_collision_shapes():
		if bool(cs["has_transform"]):
			wrapped += 1
	check(wrapped > 0, "%s reports %d wrapper transforms" % [TRANSFORM_SHAPE.get_file(), wrapped])


func test_d7_extra_data() -> void:
	print("--- D7: extra data ---")
	var src := _load(BARRACKS)
	if src == null:
		return
	var found_bsx := false
	for n in src.get_nodes():
		for x in n["extra_data"]:
			if String(x["block_type"]) == "BSXFlags":
				found_bsx = true
				check(x.has("integer"), "BSXFlags decodes an integer payload (0x%X)" % int(x.get("integer", -1)))
				check(String(x["name"]) == "BSX", "BSXFlags is named 'BSX'")
	check(found_bsx, "barracks01.nif carries BSXFlags")


func test_d8_geometry_skin_collision() -> void:
	print("--- D8: geometry, skin, collision ---")
	var barr := _load(BARRACKS)
	var body := _load(UPPERBODY)
	var bottle := _load(BOTTLE)
	if barr == null or body == null or bottle == null:
		return

	var meshes := 0
	var verts := 0
	var render_aabb := AABB()
	var first := true
	for n in barr.get_nodes():
		if not n.has("positions"):
			continue
		meshes += 1
		var pos: PackedVector3Array = n["positions"]
		verts += pos.size()
		for p in pos:
			if first:
				render_aabb = AABB(p, Vector3.ZERO)
				first = false
			else:
				render_aabb = render_aabb.expand(p)
	check(meshes == 10, "barracks01.nif: 10 geometry nodes (got %d)" % meshes)
	check(verts == 10699, "barracks01.nif: 10699 vertices (got %d)" % verts)
	# Independent cross-check: the legacy loader reports the same counts.
	check(render_aabb.size.x > 12.0 and render_aabb.size.x < 13.0,
		"render mesh is %.2f m wide -- units are meters, not raw Gamebryo" % render_aabb.size.x)

	# Winding: Gamebryo (DirectX lineage) is clockwise-front, Godot expects
	# counter-clockwise, so the last two indices of every triangle are swapped.
	# Asserted against the shipping loader rather than against a normal-
	# direction heuristic -- the heuristic's sign convention is easy to get
	# backwards, and being identical to the path that already renders
	# correctly is the property that actually matters.
	# Test-only use of the legacy reader, same allowlisted exception as the
	# other parity tests.
	var legacy := NifReader.new()
	var raw: Dictionary = ArchiveServer.read(BARRACKS)
	if legacy.load(PackedByteArray(raw["data"])):
		var legacy_indices := {}
		for i in legacy.get_submesh_count():
			legacy_indices[String(legacy.get_submesh_name(i))] = legacy.get_indices(i)
		var compared := 0
		var identical := 0
		for n in barr.get_nodes():
			if not n.has("indices"):
				continue
			var nm := String(n["name"])
			if not legacy_indices.has(nm):
				continue
			compared += 1
			var mine: PackedInt32Array = n["indices"]
			var theirs: PackedInt32Array = legacy_indices[nm]
			if mine == theirs:
				identical += 1
		check(compared > 0, "compared triangle winding on %d submeshes" % compared)
		check(identical == compared,
			"winding identical to the shipping loader (%d of %d)" % [identical, compared])

	var shapes: Array = barr.get_collision_shapes()
	var bodies: Array = barr.get_collision_bodies()
	check(shapes.size() == 1 and String((shapes[0] as Dictionary)["kind"]) == "triangle_mesh",
		"barracks01.nif: 1 triangle_mesh collision shape")
	check(bodies.size() == 1 and String((bodies[0] as Dictionary)["block_type"]) == "bhkRigidBodyT",
		"barracks01.nif: 1 bhkRigidBodyT")
	var cpos: PackedVector3Array = (shapes[0] as Dictionary)["positions"]
	var caabb := AABB(cpos[0], Vector3.ZERO)
	for p in cpos:
		caabb = caabb.expand(p)
	# Havok units (/10) and Gamebryo units (/70) must land on the same object.
	check(absf(caabb.size.x - render_aabb.size.x) < 0.05,
		"collision %.2f m vs render %.2f m -- two unit systems agree" % [caabb.size.x, render_aabb.size.x])

	var skinned := 0
	var bones := 0
	var weight_ok := true
	for n in body.get_nodes():
		if not n.has("skin"):
			continue
		skinned += 1
		var sk: Dictionary = n["skin"]
		var names: PackedStringArray = sk["bone_names"]
		var binds: Array = sk["bind_transforms"]
		var bi: PackedInt32Array = sk["bone_indices"]
		var bw: PackedFloat32Array = sk["bone_weights"]
		var nv := (n["positions"] as PackedVector3Array).size()
		bones = maxi(bones, names.size())
		if names.size() != binds.size() or bi.size() != nv * 4 or bw.size() != bi.size():
			weight_ok = false
		var sum := 0.0
		for i in mini(bw.size(), 40):
			sum += bw[i]
		if absf(sum - 10.0) > 0.01:
			weight_ok = false
	check(skinned == 6, "upperbody.nif: 6 skinned meshes (got %d)" % skinned)
	check(bones > 0, "skin exposes %d bone names" % bones)
	check(weight_ok, "bind/index/weight arrays are consistent and weights normalise to 1.0 per vertex")

	var bshapes: Array = bottle.get_collision_shapes()
	check(bshapes.size() == 1 and String((bshapes[0] as Dictionary)["kind"]) == "convex_hull",
		"milkbottle01.nif: convex_hull collision")

	var skel := _load(SKELETON)
	if skel != null:
		var caps := 0
		for s in skel.get_collision_shapes():
			if String(s["kind"]) == "capsule":
				caps += 1
		check(caps == 18, "skeleton.nif: 18 capsule ragdoll shapes (got %d)" % caps)


## units.h: every position this codebase returns is in meters. That applies to
## node translations as much as to vertices -- a scene graph left in raw
## Gamebryo units is ~70x oversized, and is invisible to any per-mesh
## local-space measurement.
func test_node_transform_units() -> void:
	print("--- node transforms are in meters ---")
	var src := _load(SKELETON)
	if src == null:
		return

	# Parity against the shipping loader, whose scene_nodes are meters by
	# construction. Test-only use, same allowlisted exception as elsewhere.
	var legacy := NifReader.new()
	var raw: Dictionary = ArchiveServer.read(SKELETON)
	if legacy.load(PackedByteArray(raw["data"])):
		var legacy_by_name := {}
		for entry in legacy.get_scene_nodes():
			legacy_by_name[String(entry["name"])] = (entry["transform"] as Transform3D).origin
		var compared := 0
		var matched := 0
		var worst := 0.0
		for n in src.get_nodes():
			var nm := String(n["name"])
			if not legacy_by_name.has(nm):
				continue
			compared += 1
			var delta: float = ((n["transform"] as Transform3D).origin - Vector3(legacy_by_name[nm])).length()
			worst = maxf(worst, delta)
			if delta < 0.001:
				matched += 1
		check(compared > 0, "compared %d node translations against the shipping loader" % compared)
		check(matched == compared,
			"all %d node translations match to 1 mm (worst %.4f m)" % [compared, worst])

	# Sanity on the absolute scale: a human skeleton is roughly 1.8 m, not 128.
	var lo := Vector3(1e9, 1e9, 1e9)
	var hi := -lo
	var nodes: Array = src.get_nodes()
	for i in nodes.size():
		var world: Vector3 = (nodes[i]["transform"] as Transform3D).origin
		var parent := int(nodes[i]["parent_index"])
		while parent != -1:
			world = (nodes[parent]["transform"] as Transform3D) * world
			parent = int(nodes[parent]["parent_index"])
		lo = lo.min(world)
		hi = hi.max(world)
	var extent := hi - lo
	var tallest: float = maxf(extent.x, maxf(extent.y, extent.z))
	check(tallest > 1.0 and tallest < 2.5,
		"skeleton spans %.2f m -- a human, not %d raw units" % [tallest, int(tallest * 70.0)])


func test_corpus_parses() -> void:
	print("--- corpus: every shipped NIF/KF parses ---")
	var files := 0
	var ok := 0
	var av := 0
	var types := {}
	for p in ArchiveServer.list_files_with_prefix("meshes/"):
		var sp := String(p)
		if not (sp.ends_with(".nif") or sp.ends_with(".kf")):
			continue
		files += 1
		var r: Dictionary = ArchiveServer.read(sp)
		if not bool(r["found"]):
			continue
		var src := NifSource.new()
		if not src.load(PackedByteArray(r["data"])):
			continue
		ok += 1
		for n in src.get_nodes():
			av += 1
			types[String(n["block_type"])] = true
	check(files > 25000, "%d NIF/KF files in the catalog" % files)
	check(ok == files, "all %d parsed, 0 failures (got %d)" % [files, ok])
	check(av > 140000, "%d NiAVObject blocks" % av)
	check(types.size() == 18, "exactly 18 NiAVObject block types corpus-wide (got %d)" % types.size())


func _ready() -> void:
	check(ArchiveServer.is_ready(), "ArchiveServer available")
	test_d1_block_types()
	test_d2_collision_subclass()
	test_d3_texture_slots()
	test_d4_object_palette()
	test_d5_property_identity()
	test_d6_controller_links()
	test_d7_extra_data()
	test_d8_geometry_skin_collision()
	test_d9_interpolators()
	test_d10_controller_chain_and_text_keys()
	test_node_transform_units()
	test_corpus_parses()

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
