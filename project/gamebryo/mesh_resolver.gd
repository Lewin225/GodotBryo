class_name GamebryoMeshResolver
extends RefCounted

## BSA-priority search + NIF/DDS resolution, shared by every object factory.
## Previously duplicated per-script across test_integration.gd, test_dds.gd,
## test_interior_cell.gd, cell_viewer.gd, and cell_viewer_editor.gd — worth
## extracting now that phases/1/01-object-type-registry.md's factories are
## real, reusable architecture rather than one-off test scripts. Same
## BSA-priority heuristic as native/tools/dump_object.cpp (Update.bsa, then
## DLC archives, then the base SArchiveList reversed) — see
## phases/0/results.md for why it's an approximation, not a load-order
## simulation.
##
## phases/2/00-resource-caching-instancing.md: every resolved NIF, built
## ArrayMesh/collision Shape3D, and decoded texture is now cached by its
## resolved path, since Fallout cells routinely place the same base object
## (rocks, fence posts, clutter) dozens of times. Confirmed before this was
## added: none of this was cached at all — every placement rebuilt its
## geometry/collision and re-decoded its textures from scratch, even for an
## object already resolved earlier in the same load. Node instances
## (MeshInstance3D, CollisionShape3D) are still created fresh per placement
## (they're scene-graph position/parenting, not shareable), but the
## Resources they reference (Mesh, Shape3D, Texture2D, Material) are shared
## across every instance of the same base object.

const DATA_DIR := "/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/"

## Bethesda/Gamebryo world units are NOT meters (~70 units/m — see
## native/src/common/units.h for the sourced conversion and rationale). The
## conversion is applied at the true source, in the pure-C++ core
## (nif_loader.cpp's vertex/translation data, esm_file.cpp's REFR/SCOL
## position data) — NOT here. Every value this resolver hands back
## (positions, transforms) is already in meters by the time it reaches
## GDScript. Do not re-apply a scale on top of it.

var _bsa_readers := {}
var _bsa_order: Array[String] = []

var _nif_cache := {} # model_path -> NifReader or null (null cached too, so a
		# missing/unparseable NIF isn't re-attempted on every repeat placement)
var _mesh_cache := {} # "model_path#submesh_index" -> ArrayMesh
var _texture_cache := {} # tex_path -> ImageTexture or null
var _material_cache := {} # tex_path -> StandardMaterial3D
var _collision_cache := {} # model_path -> Array of collision descriptor Dictionaries
		# ({ "kind": "shape"/"fallback_bbox", "shape": Resource, "transform": Transform3D, "name": String })

## Cache hit/miss counters — phases/2/00-resource-caching-instancing.md asks
## for a measured before/after, not just an assumed improvement. Cheap
## enough to always track; call reset_cache_stats() to zero between
## measurement runs.
var mesh_cache_hits := 0
var mesh_cache_misses := 0
var texture_cache_hits := 0
var texture_cache_misses := 0
## Material cache is checked BEFORE texture cache in _get_material() (a
## material-cache hit never calls load_texture() at all) — track it
## separately, since texture_cache_hits alone would misleadingly read ~0
## even though repeats are genuinely being caught, one layer up.
var material_cache_hits := 0
var material_cache_misses := 0

func reset_cache_stats() -> void:
	mesh_cache_hits = 0
	mesh_cache_misses = 0
	texture_cache_hits = 0
	texture_cache_misses = 0
	material_cache_hits = 0
	material_cache_misses = 0

func get_cache_stats() -> Dictionary:
	return {
		"mesh_cache_hits": mesh_cache_hits,
		"mesh_cache_misses": mesh_cache_misses,
		"texture_cache_hits": texture_cache_hits,
		"texture_cache_misses": texture_cache_misses,
		"material_cache_hits": material_cache_hits,
		"material_cache_misses": material_cache_misses,
		"unique_nifs_loaded": _nif_cache.size(),
		"unique_textures_loaded": _texture_cache.size(),
	}

## phases/2/10-threaded-streaming-workers.md, step 4: copies every cache
## entry `other` has that `self` doesn't into `self` -- used by
## GamebryoResolverPool to keep a canonical shared resolver's caches
## eventually consistent with every per-task-private context that's
## completed a resolve, and to warm a freshly-checked-out context with
## everything already learned by others, WITHOUT ever letting two
## concurrently-running WorkerThreadPool tasks touch the same cache
## dictionary at once -- both checkout() and checkin() (where this gets
## called) are main-thread-only by that class's own design, so this method
## itself never needs to be thread-safe.
##
## Deliberately does NOT merge _bsa_readers/_bsa_order -- those hold live
## file handles (BsaArchive, documented not-thread-safe at its own source),
## and sharing one between two contexts that could later be checked out to
## different concurrent tasks would reintroduce exactly the hazard per-
## context readers exist to avoid. Only the pure-data caches (parsed NIFs,
## built meshes, decoded textures, materials, collision descriptors) are
## safe to share once fully built -- see resolve_geometry_entries()'s own
## doc comment for why mesh entries specifically needed a cache-miss-only
## material bake before this was safe to do at all.
func merge_from(other: GamebryoMeshResolver) -> void:
	_merge_dict(_nif_cache, other._nif_cache)
	_merge_dict(_mesh_cache, other._mesh_cache)
	_merge_dict(_texture_cache, other._texture_cache)
	_merge_dict(_material_cache, other._material_cache)
	_merge_dict(_collision_cache, other._collision_cache)

static func _merge_dict(target: Dictionary, source: Dictionary) -> void:
	for key in source:
		if not target.has(key):
			target[key] = source[key]

func _init() -> void:
	_build_bsa_order()

func _build_bsa_order() -> void:
	var dir := DirAccess.open(DATA_DIR)
	var all_names: Array[String] = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.to_lower().ends_with(".bsa"):
			all_names.append(fname)
		fname = dir.get_next()
	dir.list_dir_end()

	var remaining := all_names.duplicate()
	var ordered: Array[String] = []
	if remaining.has("Update.bsa"):
		ordered.append("Update.bsa")
		remaining.erase("Update.bsa")
	var dlc: Array[String] = []
	for n in remaining:
		if not n.begins_with("Fallout - "):
			dlc.append(n)
	dlc.sort()
	for n in dlc:
		ordered.append(n)
		remaining.erase(n)
	var base_order := ["Fallout - Misc.bsa", "Fallout - Sound.bsa", "Fallout - Voices1.bsa",
			"Fallout - Meshes.bsa", "Fallout - Textures2.bsa", "Fallout - Textures.bsa"]
	for n in base_order:
		if remaining.has(n):
			ordered.append(n)
			remaining.erase(n)
	remaining.sort()
	for n in remaining:
		ordered.append(n)
	_bsa_order = ordered

func _get_reader(bsa_name: String) -> BsaReader:
	if _bsa_readers.has(bsa_name):
		return _bsa_readers[bsa_name]
	var r := BsaReader.new()
	if not r.open(DATA_DIR + bsa_name):
		_bsa_readers[bsa_name] = null
		return null
	_bsa_readers[bsa_name] = r
	return r

## Returns { "bsa": String, "data": PackedByteArray } or {} if not found in
## any archive.
func resolve_bytes(rel_path: String) -> Dictionary:
	for bsa_name in _bsa_order:
		var r := _get_reader(bsa_name)
		if r == null:
			continue
		var data := r.extract(rel_path)
		if data.size() > 0:
			return { "bsa": bsa_name, "data": data }
	return {}

## Loads a NIF from its Data/Meshes/-relative path (as stored in a MODL
## subrecord — the "meshes\" prefix is added here, see
## phases/1/00-interior-cell-loader.md's MODL-path finding). Returns null if
## not found or unparseable. Cached by model_path — repeat placements of the
## same base object (the common case) skip the BSA extract + NIF parse
## entirely after the first resolution.
func load_nif(model_path: String) -> NifReader:
	if _nif_cache.has(model_path):
		return _nif_cache[model_path]
	var found := resolve_bytes("meshes\\" + model_path)
	var nif: NifReader = null
	if not found.is_empty():
		var candidate := NifReader.new()
		if candidate.load(found["data"]):
			nif = candidate
	_nif_cache[model_path] = nif
	return nif

## Loads a texture from its Data/-relative path (as stored in a NIF's
## texture slot, already including "textures\"). Returns null if not found
## or undecodable. Cached by tex_path.
func load_texture(tex_path: String) -> ImageTexture:
	if tex_path == "":
		return null
	if _texture_cache.has(tex_path):
		texture_cache_hits += 1
		return _texture_cache[tex_path]
	texture_cache_misses += 1
	var tex: ImageTexture = null
	var found := resolve_bytes(tex_path)
	if not found.is_empty():
		var img := Image.new()
		if img.load_dds_from_buffer(found["data"]) == OK:
			tex = ImageTexture.create_from_image(img)
	_texture_cache[tex_path] = tex
	return tex

## Same texture set + alpha mode, same StandardMaterial3D — shared across
## every submesh that uses it, not just the decoded textures. Godot
## Materials are Resources like any other; many MeshInstance3D nodes
## referencing one Material is the normal, supported pattern (this is what
## an imported glTF scene with repeated materials does too).
##
## phases/2/01-material-pipeline.md: normal map (slot 1) and glow/emissive
## (slot 2) wired in alongside diffuse, plus NiAlphaProperty's blend/test
## mode — confirmed against real FO3/NV data before trusting the slot
## convention (see that task's write-up). Bethesda's normal maps are
## DirectX-convention (green channel down); Godot's StandardMaterial3D
## expects OpenGL-convention (green channel up) like glTF. Not corrected
## here — needs a visual check against a known normal-mapped object before
## deciding whether a channel flip is actually needed, not assumed either
## way. Slots 3+ (height/parallax, environment map/mask) are not extracted
## at all yet (core-layer gap, not just unwired here — see nif_types.h).
##
## phases/2/06-vertex-color-transparency.md: `has_vertex_colors` is part of
## the cache key (not just the texture/alpha inputs) because it changes
## which pixels this material actually is, not just how it looks — a
## texture-less shape with real per-vertex alpha (Bethesda's soft shadow/AO
## "blob" decals under furniture) has nothing else to blend against, and
## rendered as a solid opaque white blob before this was wired in.
##
## `is_unlit` mirrors the shape's own NIF shader: BSShaderNoLightingProperty
## instead of the normal BSShaderPPLightingProperty — Bethesda's own signal
## that scene lighting shouldn't affect this shape, confirmed against real
## data rather than inferred from "no texture" alone (a shadow/AO blob's
## intended dark-to-transparent gradient washes out to lit gray under normal
## ambient/directional shading, which is what NoLighting exists to prevent).
func _get_material(tex_path: String, normal_path: String, glow_path: String, alpha: Dictionary, has_vertex_colors: bool, is_unlit: bool) -> StandardMaterial3D:
	if tex_path == "" and normal_path == "" and glow_path == "" and not has_vertex_colors and not bool(alpha.get("has_alpha_property", false)):
		return null
	var key := "%s|%s|%s|%s|%s|%.4f|%s|%s" % [tex_path, normal_path, glow_path,
			bool(alpha.get("blend_enabled", false)), bool(alpha.get("test_enabled", false)),
			float(alpha.get("threshold", 0.5)), has_vertex_colors, is_unlit]
	if _material_cache.has(key):
		material_cache_hits += 1
		return _material_cache[key]
	material_cache_misses += 1

	var mat := StandardMaterial3D.new()
	var have_content := false

	if is_unlit:
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		have_content = true

	if has_vertex_colors:
		mat.vertex_color_use_as_albedo = true
		have_content = true

	var albedo := load_texture(tex_path)
	if albedo != null:
		mat.albedo_texture = albedo
		have_content = true

	var normal_tex := load_texture(normal_path)
	if normal_tex != null:
		mat.normal_enabled = true
		mat.normal_texture = normal_tex
		have_content = true

	var glow_tex := load_texture(glow_path)
	if glow_tex != null:
		mat.emission_enabled = true
		mat.emission_texture = glow_tex
		have_content = true

	if bool(alpha.get("blend_enabled", false)):
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		have_content = true
	elif bool(alpha.get("test_enabled", false)):
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		mat.alpha_scissor_threshold = float(alpha.get("threshold", 0.5))
		have_content = true

	var result := mat if have_content else null
	_material_cache[key] = result
	return result

func build_submesh(nif: NifReader, index: int) -> ArrayMesh:
	var pos_flat := nif.get_positions(index)
	var norm_flat := nif.get_normals(index)
	var uv_flat := nif.get_uvs(index)
	var idx_flat := nif.get_indices(index)
	var colors := nif.get_colors(index)

	var verts := PackedVector3Array()
	verts.resize(pos_flat.size() / 3)
	for i in range(verts.size()):
		verts[i] = Vector3(pos_flat[i * 3], pos_flat[i * 3 + 1], pos_flat[i * 3 + 2])

	var normals := PackedVector3Array()
	if norm_flat.size() == pos_flat.size():
		normals.resize(norm_flat.size() / 3)
		for i in range(normals.size()):
			normals[i] = Vector3(norm_flat[i * 3], norm_flat[i * 3 + 1], norm_flat[i * 3 + 2])

	var uvs := PackedVector2Array()
	if uv_flat.size() == (pos_flat.size() / 3) * 2:
		uvs.resize(uv_flat.size() / 2)
		for i in range(uvs.size()):
			uvs[i] = Vector2(uv_flat[i * 2], uv_flat[i * 2 + 1])

	var indices := PackedInt32Array()
	indices.resize(idx_flat.size())
	for i in range(idx_flat.size()):
		indices[i] = idx_flat[i]

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	if normals.size() == verts.size():
		arrays[Mesh.ARRAY_NORMAL] = normals
	if uvs.size() == verts.size():
		arrays[Mesh.ARRAY_TEX_UV] = uvs
	if colors.size() == verts.size():
		arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

## Builds every MeshInstance3D child (one per NIF submesh, with resolved
## texture) under `parent`. Shared by every GamebryoVisual-shaped factory.
## `model_path` is the same string passed to load_nif() for this `nif` —
## required (not derived from `nif` itself) so the per-submesh ArrayMesh can
## be cached the same way load_nif() caches the parsed NIF.
##
## `geometry` (2.10 step 1, optional): a pre-resolved result from
## resolve_geometry_entries() for this exact (nif, model_path) — pass it when
## the caller already resolved it (e.g. also needs populate_collision_children()
## for the same placement, or a future threaded resolve task handed back
## already-resolved data), so resolution doesn't happen twice. Resolves it
## itself (the original all-in-one behavior) when omitted.
func populate_mesh_children(parent: Node3D, nif: NifReader, model_path: String, geometry: Dictionary = {}) -> void:
	if geometry.is_empty():
		geometry = resolve_geometry_entries(nif, model_path)
	var i := 0
	for entry in geometry["mesh_entries"]:
		var mi := MeshInstance3D.new()
		mi.name = "sub%d" % i
		mi.mesh = entry["mesh"]
		mi.transform = entry["transform"]
		parent.add_child(mi)
		i += 1

## Builds a CollisionShape3D child per extracted bhk* shape (phases/1/02-
## collision-extraction.md), or one bounding-box fallback collider (from the
## render mesh's own AABB) if the NIF has no collision data at all — per
## the phase doc's explicit requirement that meshless-collision objects
## still get *something* walkable rather than no collision. The underlying
## Shape3D Resources (and the fallback box's size/position) are cached per
## model_path — only the CollisionShape3D *nodes* are built fresh per
## placement, same reasoning as populate_mesh_children().
##
## `geometry` (2.10 step 1, optional): see populate_mesh_children()'s own doc
## comment — same pre-resolved-data-sharing purpose.
func populate_collision_children(parent: Node3D, nif: NifReader, model_path: String, geometry: Dictionary = {}) -> void:
	if geometry.is_empty():
		geometry = resolve_geometry_entries(nif, model_path)
	for entry in geometry["shape_entries"]:
		var col := CollisionShape3D.new()
		col.name = String(entry.get("name", "collision"))
		col.shape = entry["shape"]
		col.transform = entry["transform"]
		parent.add_child(col)

## The single resolve step every geometry-bearing factory builds from --
## introduced in phases/2/09-direct-server-static-geometry.md (step 2) as
## get_direct_geometry_entries(), for DirectGeometryBatch's RID-based path
## (no Node to attach children to at all); generalized in phases/2/10-
## threaded-streaming-workers.md (step 1) to be the ONE place resolve work
## happens at all -- populate_mesh_children()/populate_collision_children()
## (the Node-based path) now build their children from this same data
## instead of duplicating the cache/material/collision-descriptor logic
## inline. Matters beyond just not-repeating-yourself: 2.10's threaded tile
## resolve needs a resolve step with zero Node/RenderingServer/
## PhysicsServer3D involvement at all so it's safe to run on a worker
## thread -- this already was exactly that shape for the RID path, it just
## wasn't yet the Node path's own source of truth too.
##
## Returns plain data only: { "mesh_entries": Array of { "mesh": ArrayMesh,
## "transform": Transform3D }, "shape_entries": Array of { "shape": Shape3D,
## "transform": Transform3D, "name": String } }. Reuses the exact same
## _mesh_cache/_get_material()/_build_collision_descriptors() caching
## regardless of caller, so this is purely a different way of presenting
## data already being built today, not new asset/parsing work.
##
## Material is baked directly onto the cached ArrayMesh's own surface
## (surface_set_material()) rather than applied as a per-instance override
## the way populate_mesh_children() used to via MeshInstance3D.
## material_override -- RenderingServer instances have no per-instance
## override concept as cheap as a Node property, and since material is
## already a pure function of (model_path, submesh index) with no
## placement-specific inputs (the same invariant the existing material
## cache already relies on), baking it onto the shared cached mesh resource
## is correct for every placement that reuses it, Node-based or RID-based
## alike.
##
## Only baked on an actual cache MISS (first build), not on every repeat
## resolve -- this used to be unconditional ("safe to call repeatedly,
## idempotent"), which was true for a single-threaded caller but stopped
## being safe once phases/2/10-threaded-streaming-workers.md started
## sharing already-built ArrayMesh resources across resolver instances via
## merge_from() below: two different WorkerThreadPool tasks could then both
## hold a reference to the SAME cached mesh and, without this guard, both
## call surface_set_material() on it concurrently on a cache hit -- Godot's
## own docs are explicit that concurrent Resource modification from
## multiple threads is unsafe, same-value writes or not. Gating on cache
## miss means the only thread that ever calls surface_set_material() on a
## given mesh is whichever one built it in the first place, before it's
## ever merged/shared anywhere.
func resolve_geometry_entries(nif: NifReader, model_path: String) -> Dictionary:
	var mesh_entries := []
	for i in range(nif.get_submesh_count()):
		var mesh_key := "%s#%d" % [model_path, i]
		var mesh: ArrayMesh
		if _mesh_cache.has(mesh_key):
			mesh_cache_hits += 1
			mesh = _mesh_cache[mesh_key]
		else:
			mesh_cache_misses += 1
			mesh = build_submesh(nif, i)
			var mat := _get_material(nif.get_texture_path(i), nif.get_normal_texture_path(i),
					nif.get_glow_texture_path(i), nif.get_alpha_info(i), nif.get_colors(i).size() > 0, nif.is_unlit(i))
			if mat != null:
				mesh.surface_set_material(0, mat)
			_mesh_cache[mesh_key] = mesh
		mesh_entries.append({ "mesh": mesh, "transform": nif.get_transform(i) })

	var shape_entries := []
	var descriptors: Array
	if _collision_cache.has(model_path):
		descriptors = _collision_cache[model_path]
	else:
		descriptors = _build_collision_descriptors(nif)
		_collision_cache[model_path] = descriptors
	for d in descriptors:
		shape_entries.append({ "shape": d["shape"], "transform": d["transform"], "name": d.get("name", "collision") })

	return { "mesh_entries": mesh_entries, "shape_entries": shape_entries }

## The transform every placed object resolves to from its raw REFR
## placement fields, relative to its RefrRoot parent -- extracted out of
## GamebryoObjectRegistry._finalize() so both the Node-based path (which
## sets node.transform directly, inheriting RefrRoot's own -90 X rotation
## for free via ordinary Godot parent-child transform composition) and
## DirectGeometryBatch's RID-based path share one source, not two copies of
## the same math. NOT a true world transform on its own -- despite the
## name/doc comment this originally had, which was wrong (caught directly:
## RenderingServer.instance_create2() places objects in genuine world
## space with no parent Node to inherit RefrRoot's rotation from, so
## reusing this value unmodified as a direct-RID world_transform produced
## objects with Y/Z swapped -- a full missing 90-degree rotation, visible
## as "cell 0,0 content rotated into one big flat sheet"). Callers with no
## real RefrRoot parent (the direct-RID path) must additionally compose
## refr_root_basis() -- see world_transform_no_parent() below, which does
## exactly that.
static func refr_transform(pos: Vector3, rot: Vector3, scale: float) -> Transform3D:
	return Transform3D(refr_basis(rot) * Basis().scaled(Vector3.ONE * scale), pos)

## Every RefrRoot node in this codebase (CellLoader/CellStreamBuilder/
## WorldStreamer alike) applies this exact fixed rotation
## (rotation_degrees.x = -90) and nothing else (no translation, no scale) --
## the real Z-up (Bethesda/NIF) -> Y-up (Godot) axis conversion every
## Node-based placement gets for free by being parented under one. A
## caller placing geometry in true world space with no such parent (RID-
## based, no Node at all) must compose this explicitly instead.
static func refr_root_basis() -> Basis:
	return Basis(Vector3.RIGHT, deg_to_rad(-90))

## refr_transform()'s result, but as a genuine world transform -- composes
## refr_root_basis() on top, for callers with no actual RefrRoot parent
## Node to inherit it from (DirectGeometryBatch's RID-based objects).
static func world_transform_no_parent(pos: Vector3, rot: Vector3, scale: float) -> Transform3D:
	return Transform3D(refr_root_basis(), Vector3.ZERO) * refr_transform(pos, rot, scale)

func _build_collision_descriptors(nif: NifReader) -> Array:
	var shapes: Array = nif.get_collision_shapes()
	if shapes.is_empty():
		# Only fabricate a bounding-box collider when Havok collision was
		# actually authored on this NIF but our parser couldn't extract it
		# (composite bhkListShape/bhkConvexListShape, bhkBlendCollisionObject/
		# bhkNPCollisionObject — see nif_loader.cpp) -- a real parser gap
		# where "something walkable" beats nothing. A NIF with NO collision
		# data at all (has_collision_data == false) means the artist never
		# intended this to be solid -- window-light volumetrics, markers
		# (project/gamebryo/marker_node.gd) -- and must stay collision-free,
		# not get an invented box the original engine never had either.
		if nif.has_collision_data():
			return _build_fallback_collision_descriptors(nif)
		return []

	var out: Array = []
	for s in shapes:
		var kind: String = s.get("kind", "")
		var shape: Resource = null
		var transform: Transform3D = s.get("transform", Transform3D.IDENTITY)

		match kind:
			"triangle_mesh":
				var tri := ConcavePolygonShape3D.new()
				tri.set_faces(_expand_triangles(s.get("positions", PackedFloat32Array()), s.get("indices", PackedInt32Array())))
				# Godot's ConcavePolygonShape3D is one-sided by default
				# (backface_collision = false). Havok's own triangle winding
				# (a separate data source from the render mesh, which needed
				# its own winding fix — see nif_loader.cpp) was never
				# independently verified; rather than guess at a second
				# unverified winding convention, make trimesh collision
				# solid from both sides. Confirmed necessary: a physics test
				# ball fell straight through a real floor's triangle-mesh
				# collision before this was added.
				tri.backface_collision = true
				shape = tri
			"convex_hull":
				var hull := ConvexPolygonShape3D.new()
				hull.points = _flat_to_vector3(s.get("positions", PackedFloat32Array()))
				shape = hull
			"box":
				var box := BoxShape3D.new()
				var he: Vector3 = s.get("half_extents", Vector3.ONE)
				box.size = he * 2.0
				shape = box
			"sphere":
				var sph := SphereShape3D.new()
				sph.radius = max(float(s.get("radius", 0.1)), 0.01)
				shape = sph
			"capsule":
				var cap := CapsuleShape3D.new()
				var a: Vector3 = s.get("point_a", Vector3.ZERO)
				var b: Vector3 = s.get("point_b", Vector3.ZERO)
				cap.radius = max(float(s.get("capsule_radius", 0.1)), 0.01)
				cap.height = max(a.distance_to(b) + cap.radius * 2.0, cap.radius * 2.0)
				# CapsuleShape3D is aligned along local Y by convention — build
				# a basis whose Y axis points from a to b, positioned at the
				# midpoint, then compose with the shape's own base transform.
				var mid := (a + b) * 0.5
				var dir := b - a
				var cap_basis := _basis_aligned_to_y(dir) if dir.length() > 0.0001 else Basis.IDENTITY
				transform = transform * Transform3D(cap_basis, mid)
				shape = cap
			_:
				continue
		out.append({ "kind": kind, "shape": shape, "transform": transform, "name": "collision_%s" % String(s.get("name", "")) })
	return out

func _expand_triangles(positions: PackedFloat32Array, indices: PackedInt32Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(indices.size())
	for i in range(indices.size()):
		var idx := indices[i]
		out[i] = Vector3(positions[idx * 3], positions[idx * 3 + 1], positions[idx * 3 + 2])
	return out

func _flat_to_vector3(positions: PackedFloat32Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(positions.size() / 3)
	for i in range(out.size()):
		out[i] = Vector3(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2])
	return out

func _basis_aligned_to_y(dir: Vector3) -> Basis:
	var y := dir.normalized()
	var reference := Vector3.RIGHT if absf(y.dot(Vector3.UP)) > 0.99 else Vector3.UP
	var x := reference.cross(y).normalized()
	var z := x.cross(y).normalized()
	return Basis(x, y, z)

func _build_fallback_collision_descriptors(nif: NifReader) -> Array:
	var combined := AABB()
	var have := false
	for i in range(nif.get_submesh_count()):
		var pos_flat := nif.get_positions(i)
		if pos_flat.size() < 3:
			continue
		var local_aabb := AABB()
		local_aabb.position = Vector3(pos_flat[0], pos_flat[1], pos_flat[2])
		for v in range(pos_flat.size() / 3):
			local_aabb = local_aabb.expand(Vector3(pos_flat[v * 3], pos_flat[v * 3 + 1], pos_flat[v * 3 + 2]))
		var world_aabb: AABB = nif.get_transform(i) * local_aabb
		combined = world_aabb if not have else combined.merge(world_aabb)
		have = true
	if not have:
		return []

	var box := BoxShape3D.new()
	box.size = combined.size.max(Vector3.ONE * 0.05) # avoid a degenerate zero-thickness box
	return [{ "kind": "fallback_bbox", "shape": box, "transform": Transform3D(Basis.IDENTITY, combined.get_center()), "name": "collision_fallback_bbox" }]

## Bethesda REFR.DATA rotation: X/Y/Z Euler radians, angles NEGATED before
## building each per-axis rotation — see phases/1/00-interior-cell-loader.md
## for that finding (OpenMW source cross-check). Composition order corrected
## in Phase 2 (phases/2/03-refr-rotation-order.md): the OpenMW cross-check's
## `zr*yr*xr` order (Morrowind/Oblivion-era) does not hold for FO3/NV.
## Real, visually-confirmed counterexample: GSProspectorSaloonInterior's
## TornPaintingLg01 (rotation ~(90°, 0°, 90°)) rendered face-up against the
## ceiling instead of flush on the wall under the old order; `bx*by*bz`
## fixes it (confirmed with a direct before/after render from the same
## camera) while leaving every rotation with at most one non-zero axis
## (the common case, and every case checked as "already correct" before
## this fix) mathematically unchanged. `bx*by*bz` is exactly Godot's own
## Basis.from_euler(rot, EULER_ORDER_XYZ) convention — confirmed by direct
## comparison against Godot's implementation, not assumed from the name.
static func refr_basis(rot: Vector3) -> Basis:
	var bx := Basis(Vector3(1, 0, 0), -rot.x)
	var by := Basis(Vector3(0, 1, 0), -rot.y)
	var bz := Basis(Vector3(0, 0, 1), -rot.z)
	return bx * by * bz
