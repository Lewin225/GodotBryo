extends Node

## FaceGenServer: an NPC's head-part meshes come back with the race's plus the
## NPC's FGGS / FGGA applied through each shape's EGM, by callback, once per
## request. The census morphs every shape of every HAIR, HDPT and RACE head-part
## NIF in FalloutNV.esm and reports which have no EGM that fits.

const DOC_MITCHELL := 0x00104C0C
const CAUCASIAN_OLD := 0x000042C3
const HEAD := "Characters\\Head\\HeadHuman.NIF"

signal tree_delivered
signal mesh_delivered

var failures := 0
var _tree: Node3D = null
var _mesh: ArrayMesh = null
var _callback_count := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1


func _ready() -> void:
	var esm = get_node("/root/EsmServer")
	if not esm.is_ready():
		await esm.esm_ready
	var server = get_node("/root/FaceGenServer")

	check(server.egm_path_for("Characters\\Hair\\HairBun.NIF", "NoHat") == "meshes/characters/hair/hairbunnohat.egm",
			"a NoHat shape picks <stem>nohat.egm")
	check(server.egm_path_for("Characters\\Hair\\HairBun.NIF", "Hat") == "meshes/characters/hair/hairbunhat.egm",
			"a Hat shape picks <stem>hat.egm")
	check(server.egm_path_for(HEAD, "HeadMale") == "meshes/characters/head/headhuman.egm",
			"any other shape picks <stem>.egm")

	var doc := esm.get_base(DOC_MITCHELL) as NpcBase
	check(doc != null and doc.race != null and doc.race.form_id == CAUCASIAN_OLD, "Doc Mitchell is CaucasianOld")
	if doc == null:
		_finish()
		return
	var coordinates: Array = server.geometry_coordinates(doc)
	var own := doc.face_gen.fggs.to_float32_array()
	var race := doc.race.facegen_geometry_symmetric(false)
	check((coordinates[0] as PackedFloat32Array).size() == 50, "FGGS has 50 coefficients")
	check(is_equal_approx(coordinates[0][0], own[0] + race[0]) and is_equal_approx(coordinates[0][49], own[49] + race[49]),
			"FGGS is the race's plus the NPC's")
	check((coordinates[1] as PackedFloat32Array).size() == 30, "FGGA has 30 coefficients")

	await _check_head(server, doc)
	await _census(esm, server, doc)
	_finish()


func _check_head(server: Node, doc: NpcBase) -> void:
	var tree := await _request_tree(HEAD)
	check(tree != null, "the head NIF is delivered")
	if tree == null:
		return
	var source := _first_mesh_instance(tree)
	var mesh := source.mesh as ArrayMesh
	var shape := _shape_name(source)
	var morphed := await _request_morph(server, mesh, HEAD, shape, doc)
	check(morphed != null, "the head shape is morphed")
	check(morphed != mesh, "the morph is a copy, not the shared mesh")
	if morphed == null:
		tree.free()
		return
	var before: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var after: PackedVector3Array = morphed.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	check(before.size() == 1211 and after.size() == before.size(), "the head keeps its 1,211 vertices")
	var largest := 0.0
	for i in before.size():
		largest = maxf(largest, before[i].distance_to(after[i]))
	print("       largest head vertex offset %.4f m" % largest)
	check(largest > 0.001 and largest < 0.05, "Doc's face moves vertices by more than a millimetre and less than 5 cm")
	check(morphed.surface_get_material(0) == mesh.surface_get_material(0), "the copy keeps the shared material")

	var again := await _request_morph(server, mesh, HEAD, shape, doc)
	check(again == morphed, "the same mesh and face come back as the same copy")

	_callback_count = 0
	server.request_morph(mesh, HEAD, shape, doc, self, _on_mesh)
	check(_callback_count == 0, "a cached result is not delivered from inside request_morph")
	await mesh_delivered
	check(_callback_count == 1, "it is delivered once, later")

	var refused := Node.new()
	add_child(refused)
	server.request_morph(mesh, HEAD, shape, doc, refused, _on_mesh)
	await get_tree().process_frame
	await get_tree().process_frame
	check(_callback_count == 1, "a callback that is not the owner's method is refused")
	refused.free()

	var gone_before: int = server.get_stats()["owner_gone_count"]
	var receiver := Node.new()
	receiver.set_script(load("res://tests/servers/test_face_gen_server_receiver.gd"))
	add_child(receiver)
	server.request_morph(mesh, HEAD, shape, doc, receiver, Callable(receiver, "receive"))
	receiver.free()
	await get_tree().process_frame
	await get_tree().process_frame
	check(server.get_stats()["owner_gone_count"] == gone_before + 1, "a freed owner receives nothing")
	tree.free()


## Every shape of every HAIR, HDPT and RACE head-part NIF.
func _census(esm: Node, server: Node, doc: NpcBase) -> void:
	var paths := {}
	for row in esm.get_record_index():
		var record_type := String(row.get("record_type", ""))
		if record_type != "HAIR" and record_type != "HDPT" and record_type != "RACE":
			continue
		var base = esm.get_base(int(row.get("form_id", 0)))
		if base is RaceBase:
			for female in [false, true]:
				for part in (base as RaceBase).head_parts(female):
					_add_path(paths, part.model_path)
		elif base is HairBase or base is HeadPartBase:
			_add_path(paths, String(base.model_path))
	var morphed_shapes := 0
	var unmorphed := {}
	var names := paths.keys()
	names.sort()
	for path in names:
		var tree := await _request_tree(path)
		if tree == null:
			unmorphed[path] = "NIF not delivered"
			continue
		var shapes := {}
		for child in tree.find_children("*", "MeshInstance3D", true, false):
			var mesh_instance := child as MeshInstance3D
			var shape := _shape_name(mesh_instance)
			if shapes.has(shape) or not (mesh_instance.mesh is ArrayMesh):
				continue
			shapes[shape] = true
			var morphed := await _request_morph(server, mesh_instance.mesh, path, shape, doc)
			if morphed == null:
				unmorphed["%s [%s]" % [path, shape]] = server.egm_path_for(path, shape)
			else:
				morphed_shapes += 1
		tree.free()
	print("       %d NIFs, %d shapes morphed, %d not" % [names.size(), morphed_shapes, unmorphed.size()])
	for key in unmorphed:
		print("       not morphed: %s -> %s" % [key, unmorphed[key]])
	check(morphed_shapes == 171 and unmorphed.is_empty(), "all 171 shapes of the 110 NIFs have an EGM that fits (got %d)" % morphed_shapes)


func _add_path(paths: Dictionary, path: String) -> void:
	if not path.strip_edges().is_empty():
		paths[path.strip_edges()] = true


func _shape_name(mesh_instance: MeshInstance3D) -> String:
	if mesh_instance.has_meta("nif_dismember_source_shape"):
		return String(mesh_instance.get_meta("nif_dismember_source_shape"))
	return String(mesh_instance.get_meta("nif_name", mesh_instance.name))


func _first_mesh_instance(root: Node) -> MeshInstance3D:
	for child in root.find_children("*", "MeshInstance3D", true, false):
		if (child as MeshInstance3D).mesh is ArrayMesh:
			return child
	return null


func _request_tree(path: String) -> Node3D:
	_tree = null
	get_node("/root/NifServer").request(path, self, _on_tree)
	await tree_delivered
	return _tree


## Adopted at once: NifServer frees a delivered tree left unparented.
func _on_tree(tree: Node3D) -> void:
	_tree = tree
	if tree != null:
		add_child(tree)
	tree_delivered.emit()


func _request_morph(server: Node, mesh: ArrayMesh, path: String, shape: String, npc: NpcBase) -> ArrayMesh:
	_mesh = null
	server.request_morph(mesh, path, shape, npc, self, _on_mesh)
	await mesh_delivered
	return _mesh


func _on_mesh(mesh: ArrayMesh) -> void:
	_callback_count += 1
	_mesh = mesh
	mesh_delivered.emit()


func _finish() -> void:
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: %d" % failures)
	get_tree().quit(1 if failures > 0 else 0)
