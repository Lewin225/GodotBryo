@tool
extends Node

## FaceGenServer: shapes a delivered head-part mesh to one NPC's face.
## `request_morph()` reads the mesh's EGM, adds the NPC's FaceGen offsets to its
## vertices on a worker, and calls back on the main thread with that NPC's own
## copy of the mesh. See README.md.

## Coefficient digits in a result key.
const SCALE_KEY_DIGITS := 6
## Metadata on every delivered mesh: the EGM path it was morphed with.
const META_EGM_PATH := "face_gen_egm_path"
## A shipped facemod: `<plugin>\<file-local form id>_0.dds` under this folder.
const FACEMOD_FOLDER := "textures\\characters\\facemods\\"
## RACE head part INDX 0, Head.
const HEAD_PART_INDEX := 0

const GameDataConfigScript := preload("res://game_data_config.gd")


## A worker task's result, emitted on the main thread for a coroutine to await.
class WorkerResult extends RefCounted:
	signal finished(value)

	var done := false
	var value = null

	func finish(result) -> void:
		done = true
		value = result
		finished.emit(result)

## Every result is delivered from `_process`, never from inside
## `request_morph()`, so a callback always fires after the request returns.
@export var deliveries_per_frame: int = 64

var _archive_server: Node = null
var _texture_server: Node = null
var _shutting_down := false

## EGM path -> {"egm": EgmReader, "tri": TriReader or null, "tri_vertex_count": int,
## "tri_extra_vertex_count": int}, or null when the EGM is missing or does not load.
var _bases := {}
## EGM path -> jobs waiting for the basis to load.
var _base_waiters := {}
## Result key -> WeakRef to a morphed ArrayMesh. The actors holding the mesh
## keep it alive; a key whose mesh has gone is morphed again.
var _morphed := {}
## Result key -> jobs waiting for one morph in flight.
var _morph_waiters := {}
## EGT path -> EgtReader, or null when the EGT is missing or does not load.
var _egts := {}
## EGT path -> WorkerResult of its load in flight.
var _egt_loads := {}
## Face map key -> WeakRef to a generated face map ImageTexture.
var _face_maps := {}
## Face map key -> WorkerResult of its generation in flight.
var _face_map_builds := {}
## Jobs ready to call back: [{job, result}], a mesh or a skin Dictionary.
var _deliveries := []
var _warned := {}

var _stats := {
	"request_count": 0,
	"cache_hits": 0,
	"no_egm_count": 0,
	"vertex_mismatch_count": 0,
	"morph_count": 0,
	"base_load_count": 0,
	"owner_gone_count": 0,
	"skin_request_count": 0,
	"facemod_count": 0,
	"face_map_build_count": 0,
}


func _ready() -> void:
	_archive_server = get_tree().root.get_node_or_null("ArchiveServer")
	if _archive_server == null:
		push_error("FaceGenServer: ArchiveServer autoload not found; every request will deliver null")
	_texture_server = get_tree().root.get_node_or_null("TextureServer")


func _exit_tree() -> void:
	_shutting_down = true


## Calls `on_complete(mesh: ArrayMesh)` once, on the main thread: `mesh` with
## `npc`'s FaceGen applied, or null when the shape has no EGM to apply (none
## exists, or its vertex count does not fit the mesh). `on_complete` must be a
## method on `requesting_node`; nothing is delivered once that node is freed.
##
## `model_path` is the NIF's MODL-style path and `shape_name` the shape's
## authored name (`nif_name`), which picks a hair NIF's Hat or NoHat EGM.
## The delivered mesh is shared by every request with the same mesh, EGM and
## FaceGen values, so callers must not modify it.
func request_morph(mesh: ArrayMesh, model_path: String, shape_name: String, npc: NpcBase,
		requesting_node: Node, on_complete: Callable) -> void:
	_stats["request_count"] += 1
	if not _valid_callback(requesting_node, on_complete):
		push_error("FaceGenServer: on_complete must be a method on `requesting_node`; request for '%s' refused" % model_path)
		return
	var job := {"owner": requesting_node, "cb": on_complete}
	if _shutting_down or _archive_server == null or mesh == null or npc == null:
		_queue_delivery(job, null)
		return
	var egm_path := egm_path_for(model_path, shape_name)
	var coordinates := geometry_coordinates(npc)
	job["mesh"] = mesh
	job["egm_path"] = egm_path
	job["symmetric"] = coordinates[0]
	job["asymmetric"] = coordinates[1]
	job["key"] = _result_key(mesh, egm_path, coordinates[0], coordinates[1])

	var cached := _cached_mesh(String(job["key"]))
	if cached != null:
		_stats["cache_hits"] += 1
		_queue_delivery(job, cached)
		return
	if _morph_waiters.has(job["key"]):
		(_morph_waiters[job["key"]] as Array).append(job)
		return
	if _bases.has(egm_path):
		_start_morph(job)
		return
	if _base_waiters.has(egm_path):
		(_base_waiters[egm_path] as Array).append(job)
		return
	_base_waiters[egm_path] = [job]
	WorkerThreadPool.add_task(_load_base_task.bind(egm_path))


## The EGM for one shape of `model_path`: `<stem>.egm`, or for a shape named
## Hat or NoHat (hair NIFs), `<stem>hat.egm` / `<stem>nohat.egm`. Lowercase,
## with `/` separators and the `meshes/` prefix.
static func egm_path_for(model_path: String, shape_name: String) -> String:
	var stem := model_path.replace("\\", "/").strip_edges().to_lower()
	while stem.begins_with("/"):
		stem = stem.substr(1)
	if not stem.begins_with("meshes/"):
		stem = "meshes/" + stem
	stem = stem.get_basename()
	var variant := shape_name.strip_edges().to_lower()
	if variant == "hat" or variant == "nohat":
		return stem + variant + ".egm"
	return stem + ".egm"


## `npc`'s FaceGen geometry coefficients: [FGGS, FGGA], each its race's (for
## its gender) plus its own. Both come from the template when the NPC takes its
## traits from one.
static func geometry_coordinates(npc: NpcBase) -> Array[PackedFloat32Array]:
	var source := ActorBase.template_source(npc, ActorBase.TEMPLATE_USE_TRAITS) as NpcBase
	if source == null:
		source = npc
	var symmetric := PackedFloat32Array()
	var asymmetric := PackedFloat32Array()
	if source.face_gen != null:
		symmetric = source.face_gen.fggs.to_float32_array()
		asymmetric = source.face_gen.fgga.to_float32_array()
	if source.race != null:
		var female := source.is_female()
		symmetric = _sum(symmetric, source.race.facegen_geometry_symmetric(female))
		asymmetric = _sum(asymmetric, source.race.facegen_geometry_asymmetric(female))
	return [symmetric, asymmetric]


## Calls `on_complete(skin: Dictionary)` once, on the main thread, with
## `npc`'s FaceGen skin:
## - "face_map": the head's offset map (Texture2D), or null. The NPC's shipped
##   facemod where one exists, else one built from the race head's EGT and the
##   NPC's FGTS, in the facemod's encoding (128 + offset / 2).
## - "body_offset": the upper-body offset as a Color, in 8-bit levels / 255
##   (signed): the race's upper-body EGT at the NPC's FGTS. Every shipped
##   upper-body EGT is one value over all its texels, so one colour holds it.
##   Black when the race names no body EGT.
## The callback rule is request_morph's.
func request_skin(npc: NpcBase, requesting_node: Node, on_complete: Callable) -> void:
	_stats["skin_request_count"] += 1
	if not _valid_callback(requesting_node, on_complete):
		push_error("FaceGenServer: on_complete must be a method on `requesting_node`; skin request refused")
		return
	var job := {"owner": requesting_node, "cb": on_complete}
	if _shutting_down or _archive_server == null or npc == null:
		_queue_delivery(job, {"face_map": null, "body_offset": Color(0, 0, 0)})
		return
	_resolve_skin(job, npc)


## `npc`'s FGTS: its race's for its gender plus its own, from the template when
## the NPC takes its traits from one.
static func texture_coordinates(npc: NpcBase) -> PackedFloat32Array:
	var source := _trait_source(npc)
	var symmetric := PackedFloat32Array()
	if source.face_gen != null:
		symmetric = source.face_gen.fgts.to_float32_array()
	if source.race != null:
		symmetric = _sum(symmetric, source.race.facegen_texture_symmetric(source.is_female()))
	return symmetric


## The shipped facemod path for `npc` (the NPC whose traits it takes), whether
## or not the file exists.
static func facemod_path_for(npc: NpcBase) -> String:
	var source := _trait_source(npc)
	return "%s%s\\%08X_0.dds" % [FACEMOD_FOLDER, GameDataConfigScript.ESM_FILE.to_lower(), source.form_id & 0xFFFFFF]


## The head's EGT: the race head NIF's stem with `.egt`. Empty without a race
## head part.
static func head_egt_path_for(npc: NpcBase) -> String:
	var source := _trait_source(npc)
	if source.race == null:
		return ""
	for part in source.race.head_parts(source.is_female()):
		if part.index == HEAD_PART_INDEX and not part.model_path.is_empty():
			return egm_path_for(part.model_path, "").get_basename() + ".egt"
	return ""


## The race's upper-body EGT, under `meshes/`. Empty when the race names none.
static func body_egt_path_for(npc: NpcBase) -> String:
	var source := _trait_source(npc)
	if source.race == null:
		return ""
	var path := source.race.body_egt_path(source.is_female())
	if path.is_empty():
		return ""
	return egm_path_for(path, "").get_basename() + ".egt"


static func _trait_source(npc: NpcBase) -> NpcBase:
	var source := ActorBase.template_source(npc, ActorBase.TEMPLATE_USE_TRAITS) as NpcBase
	if source == null:
		return npc
	return source


func get_stats() -> Dictionary:
	var stats := _stats.duplicate()
	stats["bases_resident"] = _bases.size()
	stats["morphed_entries"] = _morphed.size()
	stats["egts_resident"] = _egts.size()
	return stats


func reset_stats() -> void:
	for key in _stats:
		_stats[key] = 0


## Drops the loaded EGMs and the morphed-mesh index. Meshes already delivered
## stay with their holders.
func purge_all() -> void:
	_bases.clear()
	_morphed.clear()
	_egts.clear()
	_face_maps.clear()


func _process(_delta: float) -> void:
	var delivered := 0
	while not _deliveries.is_empty() and delivered < deliveries_per_frame:
		var delivery: Dictionary = _deliveries.pop_front()
		_deliver(delivery["job"], delivery["result"])
		delivered += 1


static func _valid_callback(owner_node: Node, on_complete: Callable) -> bool:
	return owner_node != null and on_complete.is_valid() and on_complete.get_object() == owner_node


static func _sum(a: PackedFloat32Array, b: PackedFloat32Array) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(maxi(a.size(), b.size()))
	for i in result.size():
		var value := 0.0
		if i < a.size():
			value += a[i]
		if i < b.size():
			value += b[i]
		result[i] = value
	return result


static func _result_key(mesh: ArrayMesh, egm_path: String, symmetric: PackedFloat32Array,
		asymmetric: PackedFloat32Array) -> String:
	var parts := PackedStringArray([egm_path, str(mesh.get_instance_id())])
	for value in symmetric:
		parts.append(String.num(value, SCALE_KEY_DIGITS))
	parts.append("|")
	for value in asymmetric:
		parts.append(String.num(value, SCALE_KEY_DIGITS))
	return ",".join(parts)


func _cached_mesh(key: String) -> ArrayMesh:
	if not _morphed.has(key):
		return null
	var mesh := (_morphed[key] as WeakRef).get_ref() as ArrayMesh
	if mesh == null:
		_morphed.erase(key)
	return mesh


## Worker: reads and parses the EGM and, when it exists, the TRI of the same
## stem, whose vertex counts say how many EGM vertices belong to the NIF shape.
func _load_base_task(egm_path: String) -> void:
	var base = null
	var error := ""
	var result: Dictionary = _archive_server.read(egm_path)
	if not bool(result["found"]):
		error = "not found"
	else:
		var egm := EgmReader.new()
		if egm.load(PackedByteArray(result["data"]), egm_path):
			base = {"egm": egm, "tri": null, "tri_vertex_count": 0, "tri_extra_vertex_count": 0}
			_read_tri(egm_path, base)
		else:
			error = egm.get_last_error()
	_on_base_loaded.bind(egm_path, base, error).call_deferred()


## Reads the TRI of the EGM's stem, for its vertex counts and expression
## morphs. A hair EGM has no TRI of its own (`<stem>hat.tri` does not exist),
## and needs none: its vertex count is the shape's.
func _read_tri(egm_path: String, base: Dictionary) -> void:
	var tri_path := egm_path.get_basename() + ".tri"
	var result: Dictionary = _archive_server.read(tri_path)
	if not bool(result["found"]):
		return
	var tri := TriReader.new()
	if not tri.load(PackedByteArray(result["data"]), tri_path):
		return
	base["tri"] = tri
	base["tri_vertex_count"] = tri.get_vertex_count()
	base["tri_extra_vertex_count"] = tri.get_statistical_vertex_count()


func _on_base_loaded(egm_path: String, base, error: String) -> void:
	_bases[egm_path] = base
	if base == null:
		_stats["no_egm_count"] += 1
		if error != "not found":
			_warn_once(egm_path, "FaceGenServer: %s failed to load (%s)" % [egm_path, error])
	else:
		_stats["base_load_count"] += 1
	var waiters: Array = _base_waiters.get(egm_path, [])
	_base_waiters.erase(egm_path)
	for job in waiters:
		var cached := _cached_mesh(String(job["key"]))
		if cached != null:
			_queue_delivery(job, cached)
		elif _morph_waiters.has(job["key"]):
			(_morph_waiters[job["key"]] as Array).append(job)
		else:
			_start_morph(job)


func _start_morph(job: Dictionary) -> void:
	var base = _bases.get(job["egm_path"])
	if base == null:
		_queue_delivery(job, null)
		return
	var mesh := job["mesh"] as ArrayMesh
	var surfaces: Array = []
	for surface in mesh.get_surface_count():
		surfaces.append(mesh.surface_get_arrays(surface))
	_morph_waiters[job["key"]] = [job]
	WorkerThreadPool.add_task(_morph_task.bind(job, base, surfaces))


## Worker: the morphed vertex array of every surface, or an empty array when a
## surface's vertex count does not fit the EGM; and the TRI's expression
## morphs as offsets for those vertices.
func _morph_task(job: Dictionary, base: Dictionary, surfaces: Array) -> void:
	var egm := base["egm"] as EgmReader
	var morphed: Array[PackedVector3Array] = []
	var vertex_count := -1
	for arrays in surfaces:
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if not _fits(positions.size(), base) or (vertex_count != -1 and positions.size() != vertex_count):
			morphed.clear()
			break
		vertex_count = positions.size()
		morphed.append(egm.morph(positions, job["symmetric"], job["asymmetric"]))
	var expressions: Array = []
	if not morphed.is_empty():
		expressions = _expression_offsets(base, vertex_count, job["symmetric"], job["asymmetric"])
	_on_morphed.bind(job, surfaces, morphed, expressions).call_deferred()


## The TRI's expression morphs for a shape of `vertex_count` vertices, as
## [{"name": String, "offsets": PackedVector3Array}], one offset per vertex;
## empty without a TRI or when the shape is not the TRI's. A difference morph's
## offsets are its deltas. A statistical morph moves each listed vertex to the
## next of the TRI's extra vertices, both with the NPC's FaceGen applied, so
## blinks and eye looks follow this face. A name met twice keeps its first.
static func _expression_offsets(base: Dictionary, vertex_count: int, symmetric: PackedFloat32Array,
		asymmetric: PackedFloat32Array) -> Array:
	var tri := base["tri"] as TriReader
	if tri == null or vertex_count != tri.get_vertex_count():
		return []
	var expressions: Array = []
	var seen := {}
	for i in tri.get_delta_morph_count():
		var name := tri.get_delta_morph_name(i)
		var deltas := tri.get_delta_morph_deltas(i)
		if name.is_empty() or seen.has(name) or deltas.size() != vertex_count * 3:
			continue
		seen[name] = true
		var offsets := PackedVector3Array()
		offsets.resize(vertex_count)
		for v in vertex_count:
			offsets[v] = Vector3(deltas[v * 3], deltas[v * 3 + 1], deltas[v * 3 + 2])
		expressions.append({"name": name, "offsets": offsets})
	if tri.get_statistical_morph_count() == 0:
		return expressions
	var face := _tri_face_positions(tri, base["egm"] as EgmReader, symmetric, asymmetric)
	if face.is_empty():
		return expressions
	var extra := vertex_count
	for i in tri.get_statistical_morph_count():
		var name := tri.get_statistical_morph_name(i)
		var indices := tri.get_statistical_morph_vertex_indices(i)
		var offsets := PackedVector3Array()
		offsets.resize(vertex_count)
		for index in indices:
			if index >= 0 and index < vertex_count and extra < face.size():
				offsets[index] = face[extra] - face[index]
			extra += 1
		if name.is_empty() or seen.has(name):
			continue
		seen[name] = true
		expressions.append({"name": name, "offsets": offsets})
	return expressions


## The TRI's base and extra vertices with the NPC's FaceGen applied, or empty
## when the EGM does not hold the TRI's V + K vertices.
static func _tri_face_positions(tri: TriReader, egm: EgmReader, symmetric: PackedFloat32Array,
		asymmetric: PackedFloat32Array) -> PackedVector3Array:
	var flat := tri.get_vertices()
	@warning_ignore("integer_division")
	var count := flat.size() / 3
	if count != egm.get_vertex_count():
		return PackedVector3Array()
	var positions := PackedVector3Array()
	positions.resize(count)
	for v in count:
		positions[v] = Vector3(flat[v * 3], flat[v * 3 + 1], flat[v * 3 + 2])
	return egm.morph(positions, symmetric, asymmetric)


## An EGM fits a shape whose vertex count is its own, or the paired TRI's V
## when the EGM holds the TRI's V + K vertices (heads and eyes).
static func _fits(vertex_count: int, base: Dictionary) -> bool:
	var egm := base["egm"] as EgmReader
	if vertex_count == egm.get_vertex_count():
		return true
	var tri_vertex_count := int(base["tri_vertex_count"])
	var tri_extra := int(base["tri_extra_vertex_count"])
	return vertex_count == tri_vertex_count and tri_vertex_count + tri_extra == egm.get_vertex_count()


func _on_morphed(job: Dictionary, surfaces: Array, morphed: Array[PackedVector3Array], expressions: Array) -> void:
	var key := String(job["key"])
	var waiters: Array = _morph_waiters.get(key, [])
	_morph_waiters.erase(key)
	var result: ArrayMesh = null
	if morphed.is_empty():
		_stats["vertex_mismatch_count"] += 1
		_warn_once(String(job["egm_path"]), "FaceGenServer: %s does not fit its shape's vertex count" % job["egm_path"])
	else:
		result = _build_mesh(job["mesh"] as ArrayMesh, surfaces, morphed, expressions)
		result.set_meta(META_EGM_PATH, job["egm_path"])
		_morphed[key] = weakref(result)
		_stats["morph_count"] += 1
	for waiter in waiters:
		_queue_delivery(waiter, result)


## The morphed mesh, with one blend shape per expression, named as in the TRI,
## on every surface. Blend shapes are normalized: each holds the morphed
## positions plus its offsets, with the surface's own normals and tangents
## (Godot stores normals compressed, so zero normal offsets cannot be given).
static func _build_mesh(source: ArrayMesh, surfaces: Array, morphed: Array[PackedVector3Array],
		expressions: Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	mesh.blend_shape_mode = Mesh.BLEND_SHAPE_MODE_NORMALIZED
	for expression in expressions:
		mesh.add_blend_shape(String(expression["name"]))
	for surface in surfaces.size():
		var arrays: Array = surfaces[surface]
		arrays[Mesh.ARRAY_VERTEX] = morphed[surface]
		var blend_shapes := _blend_shape_arrays(arrays, expressions)
		mesh.add_surface_from_arrays(source.surface_get_primitive_type(surface), arrays, blend_shapes)
		mesh.surface_set_material(surface, source.surface_get_material(surface))
	mesh.resource_name = source.resource_name
	return mesh


## One array set per expression, as add_surface_from_arrays wants: the
## surface's positions plus the expression's offsets, and the surface's own
## normals and tangents.
static func _blend_shape_arrays(arrays: Array, expressions: Array) -> Array:
	var blend_shapes: Array = []
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for expression in expressions:
		var offsets: PackedVector3Array = expression["offsets"]
		var shaped := PackedVector3Array()
		shaped.resize(positions.size())
		for v in positions.size():
			shaped[v] = positions[v] + offsets[v]
		var blend_shape := []
		blend_shape.resize(Mesh.ARRAY_MAX)
		blend_shape[Mesh.ARRAY_VERTEX] = shaped
		blend_shape[Mesh.ARRAY_NORMAL] = arrays[Mesh.ARRAY_NORMAL]
		blend_shape[Mesh.ARRAY_TANGENT] = arrays[Mesh.ARRAY_TANGENT]
		blend_shapes.append(blend_shape)
	return blend_shapes


## Main thread, a coroutine: the facemod through TextureServer, else a face
## map built from the head EGT; then the body offset; then queues delivery.
func _resolve_skin(job: Dictionary, npc: NpcBase) -> void:
	var coefficients := texture_coordinates(npc)
	var face_map: Texture2D = null
	if _texture_server != null:
		face_map = await _texture_server.request(facemod_path_for(npc))
	if face_map != null:
		_stats["facemod_count"] += 1
	else:
		face_map = await _built_face_map(head_egt_path_for(npc), coefficients)
	var body_offset := Color(0, 0, 0)
	var body_egt := await _egt(body_egt_path_for(npc))
	if body_egt != null:
		body_offset = _mean_offset(body_egt, coefficients)
	_queue_delivery(job, {"face_map": face_map, "body_offset": body_offset})


## The face map for `egt_path` at `coefficients`, built on a worker once and
## shared while anyone holds it; null when the EGT does not load.
func _built_face_map(egt_path: String, coefficients: PackedFloat32Array) -> Texture2D:
	var egt := await _egt(egt_path)
	if egt == null:
		return null
	var parts := PackedStringArray([egt_path])
	for value in coefficients:
		parts.append(String.num(value, SCALE_KEY_DIGITS))
	var key := ",".join(parts)
	if _face_maps.has(key):
		var cached := (_face_maps[key] as WeakRef).get_ref() as Texture2D
		if cached != null:
			return cached
		_face_maps.erase(key)
	var build: WorkerResult = _face_map_builds.get(key)
	if build == null:
		build = WorkerResult.new()
		_face_map_builds[key] = build
		WorkerThreadPool.add_task(_build_face_map_task.bind(egt, coefficients, build))
	var image: Image = build.value if build.done else await build.finished
	_face_map_builds.erase(key)
	if _face_maps.has(key):
		var built := (_face_maps[key] as WeakRef).get_ref() as Texture2D
		if built != null:
			return built
	if image == null:
		return null
	var texture := ImageTexture.create_from_image(image)
	_face_maps[key] = weakref(texture)
	_stats["face_map_build_count"] += 1
	return texture


## Worker: the face map image, with mipmaps.
static func _build_face_map_task(egt: EgtReader, coefficients: PackedFloat32Array, build: WorkerResult) -> void:
	var image := egt.build_offset_image(coefficients)
	if image != null:
		image.generate_mipmaps()
	build.finish.call_deferred(image)


## The EGT at `egt_path`, read and parsed once on a worker; null when it is
## missing or does not load.
func _egt(egt_path: String) -> EgtReader:
	if egt_path.is_empty():
		return null
	if _egts.has(egt_path):
		return _egts[egt_path]
	var loading: WorkerResult = _egt_loads.get(egt_path)
	if loading == null:
		loading = WorkerResult.new()
		_egt_loads[egt_path] = loading
		WorkerThreadPool.add_task(_load_egt_task.bind(egt_path, loading))
	var egt: EgtReader = loading.value if loading.done else await loading.finished
	if not _egts.has(egt_path):
		_egts[egt_path] = egt
		_egt_loads.erase(egt_path)
	return egt


## Worker: reads and parses one EGT.
func _load_egt_task(egt_path: String, loading: WorkerResult) -> void:
	var egt: EgtReader = null
	var result: Dictionary = _archive_server.read(egt_path)
	if bool(result["found"]):
		var reader := EgtReader.new()
		if reader.load(PackedByteArray(result["data"]), egt_path):
			egt = reader
		else:
			_warn_once.bind(egt_path, "FaceGenServer: %s failed to load (%s)" % [egt_path, reader.get_last_error()]).call_deferred()
	loading.finish.call_deferred(egt)


## The mean texel offset of `egt` at `coefficients`, per channel, in 8-bit
## levels / 255.
static func _mean_offset(egt: EgtReader, coefficients: PackedFloat32Array) -> Color:
	var offsets := egt.get_offsets(coefficients)
	@warning_ignore("integer_division")
	var texels := offsets.size() / 3
	if texels == 0:
		return Color(0, 0, 0)
	var sums := [0.0, 0.0, 0.0]
	for texel in texels:
		for channel in 3:
			sums[channel] += offsets[texel * 3 + channel]
	return Color(sums[0] / texels / 255.0, sums[1] / texels / 255.0, sums[2] / texels / 255.0)


func _queue_delivery(job: Dictionary, result) -> void:
	_deliveries.append({"job": job, "result": result})


func _deliver(job: Dictionary, result) -> void:
	var owner_node = job.get("owner")
	var cb: Callable = job.get("cb", Callable())
	if owner_node == null or not is_instance_valid(owner_node) or not cb.is_valid():
		_stats["owner_gone_count"] += 1
		return
	cb.call(result)


func _warn_once(key: String, message: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	push_warning(message)
