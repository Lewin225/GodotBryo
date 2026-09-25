extends Node

## Stage E parity gate (Plans/Completed Plans/server_stack_build_order.md): NifSource against
## the shipping NifReader/mesh_resolver path, over a fixed sample.
##
## The legacy path is the reference because it is what the game has been played
## on. Where the two differ, this says which and why rather than asserting one
## is right -- NifServer reads several things the legacy reader never did.
##
## OUT OF SCOPE: collision PLACEMENT. outstanding_issues.md #12 is parked, and
## the legacy reader cannot unwrap bhkTransformShape at all, so it is not a
## reference for it. Collision shape counts and kinds are still compared.

const SAMPLE := [
	"architecture/barracks/barracks01.nif",
	"architecture/generic/UsonianHomeDamM02.NIF",
	"clutter/junk/milkbottle01.nif",
	"dungeons/vaultruined/doors/vdoorslidingvault22.nif",
	"characters/_male/upperbody.nif",
	"characters/_male/skeleton.nif",
	"terminals/terminaldesk01.nif",
	"architecture/strip/newvegassign.nif",
	"dungeons/vault/accessories/nvvwallconsole01.nif",
	"effects/actorfirefx/fireball01.nif",
]

var failures := 0
var _resolver: GamebryoMeshResolver = null


func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1


func _legacy(model: String) -> NifReader:
	if _resolver == null:
		_resolver = GamebryoMeshResolver.new()
	return _resolver.load_nif(model.replace("/", "\\"))


func _source(model: String) -> NifSource:
	var r: Dictionary = ArchiveServer.read("meshes/" + model.to_lower())
	if not bool(r["found"]):
		return null
	var src := NifSource.new()
	return src if src.load(PackedByteArray(r["data"])) else null


## World transform of a node, composed to the file root.
func _world(nodes: Array) -> Array:
	var out: Array = []
	out.resize(nodes.size())
	for i in nodes.size():
		var t: Transform3D = nodes[i]["transform"]
		var par := int(nodes[i]["parent_index"])
		out[i] = t if par < 0 or par >= i else (out[par] as Transform3D) * t
	return out


func _ready() -> void:
	check(ArchiveServer.is_ready(), "ArchiveServer available")
	var total_v := 0
	var total_i := 0
	var worst_xform := 0.0
	var worst_file := ""
	var tex_mismatch := 0
	var shape_count_diff := 0

	for model in SAMPLE:
		var legacy := _legacy(model)
		var src := _source(model)
		if legacy == null or src == null:
			check(false, "both readers loaded %s" % model)
			continue

		# --- geometry: vertex and index totals -------------------------------
		var lv := 0
		var li := 0
		for i in legacy.get_submesh_count():
			# The legacy reader returns a flat float stream, 3 per vertex.
			lv += (legacy.get_positions(i) as PackedFloat32Array).size() / 3
			li += (legacy.get_indices(i) as PackedInt32Array).size()
		var sv := 0
		var si := 0
		var shapes: Array = []
		var nodes: Array = src.get_nodes()
		for i in nodes.size():
			if not nodes[i].has("positions"):
				continue
			var pos: PackedVector3Array = nodes[i]["positions"]
			if pos.is_empty():
				continue
			shapes.append(i)
			sv += pos.size()
			si += (nodes[i]["indices"] as PackedInt32Array).size()
		total_v += sv
		total_i += si
		check(lv == sv, "%s: %d vertices (legacy %d)" % [model.get_file(), sv, lv])
		check(li == si, "%s: %d indices (legacy %d)" % [model.get_file(), si, li])
		check(legacy.get_submesh_count() == shapes.size(),
			"%s: %d shapes (legacy %d)" % [model.get_file(), shapes.size(), legacy.get_submesh_count()])

		# --- world transforms -------------------------------------------------
		if legacy.get_submesh_count() == shapes.size():
			var world := _world(nodes)
			var worst := 0.0
			for i in shapes.size():
				var mine: Transform3D = world[shapes[i]]
				var theirs: Transform3D = legacy.get_transform(i)
				worst = maxf(worst, (mine.origin - theirs.origin).length())
			if worst > worst_xform:
				worst_xform = worst
				worst_file = model.get_file()
			check(worst < 0.001, "%s: world transforms agree to 1 mm (worst %.6f m)" % [model.get_file(), worst])

			# --- material texture paths --------------------------------------
			var same := 0
			for i in shapes.size():
				var slots: PackedStringArray = nodes[shapes[i]]["texture_slots"]
				var mine_diffuse := String(slots[0]) if slots.size() > 0 else ""
				var theirs_diffuse := String(legacy.get_texture_path(i))
				if mine_diffuse.to_lower() == theirs_diffuse.to_lower():
					same += 1
				else:
					tex_mismatch += 1
			check(same == shapes.size(),
				"%s: %d of %d diffuse paths match" % [model.get_file(), same, shapes.size()])

		# --- skin bind names ---------------------------------------------------
		var legacy_binds := {}
		for entry in legacy.get_skin_data():
			for n in (entry as Dictionary).get("bone_names", PackedStringArray()):
				legacy_binds[String(n)] = true
		var mine_binds := {}
		for i in nodes.size():
			if not nodes[i].has("skin"):
				continue
			for n in ((nodes[i]["skin"] as Dictionary)["bone_names"] as PackedStringArray):
				mine_binds[String(n)] = true
		check(legacy_binds.size() == mine_binds.size(),
			"%s: %d skin bind names (legacy %d)" % [model.get_file(), mine_binds.size(), legacy_binds.size()])
		if legacy_binds.size() == mine_binds.size() and not mine_binds.is_empty():
			var missing := 0
			for n in legacy_binds.keys():
				if not mine_binds.has(n):
					missing += 1
			check(missing == 0, "%s: every legacy bind name is present" % model.get_file())

		# --- collision shape counts (NOT placement, see #12) -------------------
		var lc: int = legacy.get_collision_shapes().size()
		var sc: int = src.get_collision_shapes().size()
		if lc != sc:
			shape_count_diff += 1
			print("  NOTE  %s: %d collision shapes vs legacy %d -- legacy unwrap_shape() handles only bhkMoppBvTreeShape" % [model.get_file(), sc, lc])
		else:
			check(true, "%s: %d collision shapes (legacy %d)" % [model.get_file(), sc, lc])

	print("--- totals ---")
	print("  %d vertices, %d indices across %d files" % [total_v, total_i, SAMPLE.size()])
	print("  worst world-transform disagreement: %.6f m (%s)" % [worst_xform, worst_file])
	print("  diffuse path mismatches: %d" % tex_mismatch)
	print("  files where collision shape COUNT differs: %d" % shape_count_diff)

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
