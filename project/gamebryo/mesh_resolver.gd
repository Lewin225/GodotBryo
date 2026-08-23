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
##
## phases/2/10-threaded-streaming-workers.md's real fix: this class now has
## two strictly separate halves that must never be called from the wrong
## thread. Confirmed directly (a real, repeatable crash — RID-table
## corruption, "Attempting to initialize the wrong RID"/"Initializing
## already initialized RID") that ArrayMesh/ImageTexture/StandardMaterial3D/
## Shape3D construction all issue real RenderingServer/PhysicsServer3D calls
## under the hood despite looking like plain Resource construction — Godot's
## own RID_Owner<T> template compiles its locking out entirely
## (`if constexpr (THREAD_SAFE)`) unless the Separate rendering thread model
## is enabled, which the project decided against (its own docs warn it still
## stalls on exactly this pattern — creating textures off the main thread).
##   - "Raw resolve" methods (resolve_bytes/load_nif/_load_image/
##     resolve_raw_geometry) touch only NifReader/BsaReader/Image — none of
##     which are RenderingServer/PhysicsServer3D-backed — and are safe to
##     call from a WorkerThreadPool task, via a GamebryoResolveContext's own
##     private instance (see that class + GamebryoResolverPool).
##   - "Final build" methods (build_geometry_entries and everything it
##     calls) construct the actual ArrayMesh/ImageTexture/StandardMaterial3D/
##     Shape3D Resources and MUST only ever be called from the main thread,
##     via GamebryoObjectRegistry's own single, non-pooled `resolver`
##     instance -- never a pool context's.
## Both halves happen to live on the same class (populate_mesh_children()/
## populate_collision_children() and the old build() path use both in
## sequence, always on the main thread, which is safe) rather than two
## separate classes, since splitting them would touch many more call sites
## for no safety benefit -- the discipline is which INSTANCE's methods get
## called from which thread, not the class boundary itself.

const DATA_DIR := "/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/"

## Bethesda/Gamebryo world units are NOT meters (~70 units/m — see
## native/src/common/units.h for the sourced conversion and rationale). The
## conversion is applied at the true source, in the pure-C++ core
## (nif_loader.cpp's vertex/translation data, esm_file.cpp's REFR/SCOL
## position data) — NOT here. Every value this resolver hands back
## (positions, transforms) is already in meters by the time it reaches
## GDScript. Do not re-apply a scale on top of it.

# --- Raw-resolve state (worker-safe; per-context, private, merged via
# GamebryoResolverPool -- see merge_from()) ---
var _bsa_readers := {}
var _bsa_order: Array[String] = []
var _nif_cache := {} # model_path -> NifReader or null (null cached too, so a
		# missing/unparseable NIF isn't re-attempted on every repeat placement)
var _image_cache := {} # tex_path -> Image or null (decoded pixels only, no RID)
var _lod_path_cache := {} # model_path -> lod companion path (String) or "" if none -- see lod_companion_path()

# --- Final-build state (main-thread-only; lives solely on
# GamebryoObjectRegistry's own single, non-pooled `resolver` instance) ---
var _mesh_cache := {} # "model_path#submesh_index" -> ArrayMesh
var _texture_cache := {} # tex_path -> ImageTexture or null
var _material_cache := {} # material key -> StandardMaterial3D
var _collision_cache := {} # model_path -> Array of { "shape": Shape3D, "transform": Transform3D, "name": String }

## Cache hit/miss counters — phases/2/00-resource-caching-instancing.md asks
## for a measured before/after, not just an assumed improvement.
var mesh_cache_hits := 0
var mesh_cache_misses := 0
var texture_cache_hits := 0
var texture_cache_misses := 0
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

## phases/2/10-threaded-streaming-workers.md: copies every RAW-resolve cache
## entry `other` has that `self` doesn't into `self` -- used by
## GamebryoResolverPool to keep worker contexts warm with everything
## already parsed/decoded by any other context. Deliberately does NOT merge
## the final-build caches (_mesh_cache/_texture_cache/_material_cache/
## _collision_cache) -- those never get populated on a worker-context
## instance at all anymore (build_geometry_entries() is main-thread-only,
## called only on GamebryoObjectRegistry's own single resolver instance),
## so merging them would just be copying empty dictionaries around.
##
## Also deliberately does NOT merge _bsa_readers/_bsa_order -- those hold
## live file handles (BsaArchive, documented not-thread-safe at its own
## source), and sharing one between two contexts that could later be
## checked out to different concurrent tasks would reintroduce exactly the
## hazard per-context readers exist to avoid. NifReader (fully parsed,
## read-only getters, confirmed via its own header) and Image (plain pixel
## data, no RID) are both safe to share once built.
func merge_from(other: GamebryoMeshResolver) -> void:
	_merge_dict(_nif_cache, other._nif_cache)
	_merge_dict(_image_cache, other._image_cache)
	_merge_dict(_lod_path_cache, other._lod_path_cache)

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
## any archive. Worker-safe -- BsaReader I/O only, no RenderingServer/
## PhysicsServer3D involvement.
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
## entirely after the first resolution. Worker-safe.
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

## phases/2/12-distant-object-lod.md, step 2: derives `model_path`'s own
## `_lod.nif` companion path -- Bethesda's real paired-mesh convention
## (confirmed against real data, see enginedocs/lod.md: e.g.
## "architecture\barracks\barracks01.nif" has a real companion at
## "architecture\barracks\barracks01_lod.nif", both present in the same
## BSA), NOT a lookup table. Returns "" if `model_path` doesn't end in
## ".nif" at all, or no companion actually resolves via the same BSA-
## priority search everything else uses -- most models have no LOD
## companion, that's the common, valid case, not an error. Cached by
## model_path (worker-safe, same reasoning as _nif_cache/_image_cache --
## only touches resolve_bytes(), no RS/PS3D).
func lod_companion_path(model_path: String) -> String:
	if _lod_path_cache.has(model_path):
		return _lod_path_cache[model_path]
	var result := ""
	var lower := model_path.to_lower()
	if lower.ends_with(".nif"):
		var candidate := model_path.substr(0, model_path.length() - 4) + "_lod.nif"
		if not resolve_bytes("meshes\\" + candidate).is_empty():
			result = candidate
	_lod_path_cache[model_path] = result
	return result

## Black-background decal fix (see memory: black-background-decal-findings):
## a DXT1 (BC1) texture's 1-bit punch-through alpha survives CPU decode but
## is LOST on GPU upload (confirmed with a real-GPU render census -- a
## correctly-scissored DXT1 quad rendered fully opaque), so a submesh whose
## NiAlphaProperty actually needs that alpha gets its diffuse decompressed
## to RGBA8 on the worker thread instead. Cached under a distinct "#rgba"
## variant key so the same texture used elsewhere WITHOUT an alpha property
## keeps its compressed (8x smaller VRAM/upload) form -- first-upload-wins
## collisions between the two uses would silently reintroduce the bug.
static func _tex_variant_key(tex_path: String, alpha_safe: bool) -> String:
	return tex_path + "#rgba" if (alpha_safe and tex_path != "") else tex_path

## Decodes a texture's raw pixel data from its Data/-relative path (as
## stored in a NIF's texture slot, already including "textures\"). Returns
## an Image (plain pixel buffer, no RID -- confirmed safe to construct off
## the main thread) or null if not found/undecodable. Cached by tex_path
## (plus the "#rgba" variant suffix when `alpha_safe` -- see
## _tex_variant_key()). Worker-safe -- decompress()/generate_mipmaps() are
## plain CPU Image ops, no RS involvement. Deliberately stops at Image, NOT
## ImageTexture -- see this class's own doc comment for why the GPU-upload
## step has to wait for the main thread.
func _load_image(tex_path: String, alpha_safe: bool = false) -> Image:
	if tex_path == "":
		return null
	var key := _tex_variant_key(tex_path, alpha_safe)
	if _image_cache.has(key):
		return _image_cache[key]
	var img: Image = null
	var found := resolve_bytes(tex_path)
	if not found.is_empty():
		var candidate := Image.new()
		if candidate.load_dds_from_buffer(found["data"]) == OK:
			img = candidate
	# Only DXT1 needs the decompress -- DXT3/DXT5 alpha reaches the GPU
	# intact (confirmed in the same render census). Verified (2026-08-21,
	# Godot 4.7.1, _diag_decompress_mips.gd): decompress() preserves the
	# mipmap chain (1.6ms for a 1024x1024) -- the regenerate below is a
	# cheap guard against that behavior changing, not an expected path.
	if img != null and alpha_safe and img.get_format() == Image.FORMAT_DXT1:
		var had_mips := img.has_mipmaps()
		if img.decompress() == OK and had_mips and not img.has_mipmaps():
			img.generate_mipmaps()
	_image_cache[key] = img
	return img

## Main-thread-only convenience: decode + GPU-upload a texture in one call.
## Terrain building (CellStreamBuilder.build_terrain(), its own quadrant
## textures) is the real caller -- it was never part of the threaded
## resolve/construct split (terrain stays synchronous, main-thread, see
## phases/2/10's own scope notes) and just wants a usable ImageTexture
## directly, the same way this method worked before that split existed.
## NOT safe to call from a worker thread (see _get_texture_from_image()).
func load_texture(tex_path: String) -> ImageTexture:
	return _get_texture_from_image(tex_path, _load_image(tex_path))

## phases/2/10-threaded-streaming-workers.md: the resolve-only counterpart
## to build_geometry_entries() below -- pulls every piece of data a
## placement's mesh/collision needs (vertex arrays, texture paths, decoded
## Images, raw collision geometry) WITHOUT constructing a single
## RenderingServer/PhysicsServer3D-backed Resource. This is what makes it
## safe to call from a WorkerThreadPool task via a GamebryoResolveContext's
## own private resolver instance.
##
## Returns { "model_path": String, "mesh_entries": Array of { "cache_key",
## "positions"/"normals"/"uvs"/"indices" (PackedFloat32Array/PackedInt32Array,
## same flat layout NifReader's own getters use), "colors" (PackedColorArray),
## "transform", "texture_path"/"normal_texture_path"/"glow_texture_path",
## "alpha_info", "has_vertex_colors", "is_unlit", "diffuse_image"/
## "normal_image"/"glow_image" (Image or null) }, "shape_entries": Array of
## raw kind-tagged collision descriptors (NifReader.get_collision_shapes()'s
## own shape, or the fallback-bbox AABB case -- see _resolve_raw_collision())
## }. Hand this whole Dictionary to build_geometry_entries() (main thread
## only) to get the final { "mesh_entries": [{mesh,transform}],
## "shape_entries": [{shape,transform,name}] } shape every caller actually
## consumes.
##
## Rendering-issues punch-list item #4 ("leftover CK editor objects"):
## submeshes named "EditorMarker*" (confirmed, not guessed, across many real
## effect NIFs -- Effects\Ambient\FXDustMeshSky01.NIF etc. -- a CK-wide
## authoring convention, not one file's quirk) are Bethesda's own artist-
## only visualization gizmos, never rendered by the real game. Skipped here
## unless Engine.is_editor_hint() is true (CellLoader's own @tool editor-
## preview path, where seeing them is useful) -- filtering at this single
## source, rather than toggling Node.visible after the fact, is what makes
## it apply uniformly to BOTH the Node-based path and DirectGeometryBatch's
## RID-based structural-fallback path (which has no Node/visible property
## at all -- confirmed directly: MSTT, the base_type every one of these
## effect placements uses, is unregistered and always routes through the
## RID path at runtime).
func resolve_raw_geometry(nif: NifReader, model_path: String) -> Dictionary:
	var mesh_entries := []
	for i in range(nif.get_submesh_count()):
		if _is_editor_marker_submesh(nif.get_submesh_name(i)) and not Engine.is_editor_hint():
			continue
		var tex_path := nif.get_texture_path(i)
		var normal_path := nif.get_normal_texture_path(i)
		var glow_path := nif.get_glow_texture_path(i)
		var alpha_info := nif.get_alpha_info(i)
		# Only the diffuse slot ever needs its alpha channel on the GPU
		# (blend or scissor) -- normal/glow alpha is never sampled by the
		# materials we build, so those keep their compressed form always.
		var needs_alpha := bool(alpha_info.get("blend_enabled", false)) \
				or bool(alpha_info.get("test_enabled", false))
		mesh_entries.append({
			"cache_key": "%s#%d" % [model_path, i],
			"positions": nif.get_positions(i),
			"normals": nif.get_normals(i),
			"uvs": nif.get_uvs(i),
			"indices": nif.get_indices(i),
			"colors": nif.get_colors(i),
			"transform": nif.get_transform(i),
			"texture_path": tex_path,
			"texture_key": _tex_variant_key(tex_path, needs_alpha),
			"normal_texture_path": normal_path,
			"glow_texture_path": glow_path,
			"alpha_info": alpha_info,
			"has_vertex_colors": nif.get_colors(i).size() > 0,
			"is_unlit": nif.is_unlit(i),
			"diffuse_image": _load_image(tex_path, needs_alpha),
			"normal_image": _load_image(normal_path),
			"glow_image": _load_image(glow_path),
		})
	return {
		"model_path": model_path,
		"mesh_entries": mesh_entries,
		"shape_entries": _resolve_raw_collision(nif),
	}

## Prefix match, not exact -- real names seen include "EditorMarker:0" (a
## NifSkope/3ds Max-style ":<index>" suffix for repeated node names).
static func _is_editor_marker_submesh(submesh_name: String) -> bool:
	return submesh_name.to_lower().begins_with("editormarker")

## phases/2/10-threaded-streaming-workers.md: the main-thread-only "commit"
## half of resolve_raw_geometry() -- builds the actual ArrayMesh/
## ImageTexture/StandardMaterial3D/Shape3D Resources from raw data, using
## this instance's own final-build caches. Must only ever be called on
## GamebryoObjectRegistry's own single, non-pooled `resolver` -- see this
## class's own top-of-file doc comment for why.
##
## `raw` empty (no geometry resolved at all, e.g. a meshless light) returns
## empty mesh/shape_entries, not an error.
##
## `lod_raw` (optional, phases/2/12-distant-object-lod.md step 5): a
## placement's own optional "lod_geometry" raw block (see
## GamebryoObjectRegistry._resolve_lod_geometry(), step 4) -- when present,
## its mesh Resources are built into `lod_mesh_entries` the same way `raw`'s
## own are, sharing the same `_mesh_cache` (an LOD mesh built for one
## placement is reused by every other placement of the same base object,
## same as any other cached mesh). Deliberately mesh-only, no matching
## "lod_shape_entries" -- collision always comes from the full-detail mesh
## (`raw`'s own shape_entries); the LOD variant is a visual-only distance
## substitute, never separately collidable, and the object's own full-detail
## geometry is always resolved alongside it regardless of streaming band
## (see step 4's own doc comment). Empty (the common case -- most placements
## have no LOD companion at all) returns an empty `lod_mesh_entries`.
func build_geometry_entries(raw: Dictionary, lod_raw: Dictionary = {}) -> Dictionary:
	if raw.is_empty():
		return { "mesh_entries": [], "shape_entries": [], "lod_mesh_entries": [] }

	var mesh_entries := _build_mesh_entries(raw["mesh_entries"])

	var shape_entries := []
	var model_path: String = raw["model_path"]
	var descriptors: Array
	if _collision_cache.has(model_path):
		descriptors = _collision_cache[model_path]
	else:
		descriptors = _build_collision_shapes(raw["shape_entries"])
		_collision_cache[model_path] = descriptors
	for d in descriptors:
		shape_entries.append({
			"shape": d["shape"], "transform": d["transform"], "name": d.get("name", "collision"),
			# phases/3/00-door-completion.md step 5: which scene_nodes entry
			# this shape is really attached to in the source NIF (-1 if the
			# NIF's root, or a fabricated fallback_bbox that isn't tied to
			# any single node) -- see populate_dynamic_children()'s own doc
			# comment for why this now flows all the way through instead of
			# being dropped here.
			"owning_node_index": d.get("owning_node_index", -1),
		})

	var lod_mesh_entries := _build_mesh_entries(lod_raw["mesh_entries"]) if not lod_raw.is_empty() else []

	return { "mesh_entries": mesh_entries, "shape_entries": shape_entries, "lod_mesh_entries": lod_mesh_entries }

## The shared per-submesh mesh-Resource-building loop -- same cache-by-key
## (`_mesh_cache`) discipline used for both the full-detail tier and the
## optional LOD tier (step 5), so an LOD mesh is exactly as cheap to reuse
## across repeat placements as a full-detail one already is.
func _build_mesh_entries(mesh_entries_raw: Array) -> Array:
	var mesh_entries := []
	for e in mesh_entries_raw:
		var mesh_key: String = e["cache_key"]
		var mesh: ArrayMesh
		if _mesh_cache.has(mesh_key):
			mesh_cache_hits += 1
			mesh = _mesh_cache[mesh_key]
		else:
			mesh_cache_misses += 1
			mesh = _build_mesh_from_raw(e)
			var mat := _build_material_from_raw(e)
			if mat != null:
				mesh.surface_set_material(0, mat)
			_mesh_cache[mesh_key] = mesh
		mesh_entries.append({ "mesh": mesh, "transform": e["transform"] })
	return mesh_entries

## Builds every MeshInstance3D child (one per NIF submesh, with resolved
## texture) under `parent`. Shared by every GamebryoVisual-shaped factory.
## `model_path` is the same string passed to load_nif() for this `nif` —
## required (not derived from `nif` itself) so the per-submesh ArrayMesh can
## be cached the same way load_nif() caches the parsed NIF.
##
## `geometry` (optional): an already-built (FINAL, not raw) result from
## build_geometry_entries() for this exact (nif, model_path) — pass it when
## the caller already resolved it, so resolution doesn't happen twice.
## Resolves-then-builds itself (both steps, always safe here since this
## whole call is main-thread-only) when omitted. NOTE: the omitted-geometry
## path calls resolve_raw_geometry()/build_geometry_entries() with no
## lod_raw, so it never attaches an LOD tier — a caller wanting one must
## build+pass `geometry` itself (see GamebryoObjectRegistry._resolve_lod_geometry()
## + this class's own build_geometry_entries(), step 5).
##
## phases/2/12-distant-object-lod.md, step 6: when `geometry["lod_mesh_entries"]`
## is non-empty (the small minority — a VWD-flagged placement with a
## resolvable _lod.nif companion, see step 4), a second MeshInstance3D is
## built per LOD submesh alongside the full-detail ones, and BOTH tiers get
## their visibility_range set (_apply_lod_visibility_range()) so Godot's own
## per-frame distance check — not this function, not WorldStreamer — decides
## which one actually renders. The overwhelming common case (no LOD tier)
## is completely unaffected: no visibility range touched at all, same as
## before this step.
func populate_mesh_children(parent: Node3D, nif: NifReader, model_path: String, geometry: Dictionary = {}) -> void:
	if geometry.is_empty():
		geometry = build_geometry_entries(resolve_raw_geometry(nif, model_path))
	var lod_entries: Array = geometry.get("lod_mesh_entries", [])
	var i := 0
	for entry in geometry["mesh_entries"]:
		var mi := MeshInstance3D.new()
		mi.name = "sub%d" % i
		mi.mesh = entry["mesh"]
		mi.transform = entry["transform"]
		if not lod_entries.is_empty():
			_apply_lod_visibility_range(mi, true)
		parent.add_child(mi)
		i += 1
	i = 0
	for entry in lod_entries:
		var mi := MeshInstance3D.new()
		mi.name = "lod%d" % i
		mi.mesh = entry["mesh"]
		mi.transform = entry["transform"]
		_apply_lod_visibility_range(mi, false)
		parent.add_child(mi)
		i += 1

## phases/3/00-door-completion.md step 5: the Dynamic-path counterpart to
## populate_mesh_children() above — for objects that can move and/or carry
## a script (see enginedocs/nv_class_hierarchy.md's Dynamic/Static split),
## builds the NIF's REAL SceneNode hierarchy (nif_types.h's own doc
## comment) as real Node3D children of `parent`, instead of the single
## flattened transform every submesh gets on the Static path. Same
## resolved-texture/material MeshInstance3D construction as
## populate_mesh_children() (shares `geometry`'s mesh_entries, same cache),
## just parented differently: each submesh's MeshInstance3D goes under its
## owning_node_index's Node3D with an IDENTITY local transform — the owning
## node's own composed transform chain already reconstructs
## get_transform(i)'s flattened result (both walk the same NiAVObject
## parent chain — see flatten_via_scene_nodes()'s and SceneNode's own doc
## comments in native/src/nif/nif_loader.cpp / nif_types.h), so this
## deliberately never also applies the flattened per-submesh transform
## (that would double it).
##
## Collision is built hierarchically too, via `geometry`'s shape_entries
## (each carrying its own owning_node_index — see build_geometry_entries()):
## one GamebryoCollisionBody per DISTINCT owning node (not one for the
## whole object, unlike populate_collision_children()'s always-single-body
## convention) — a real NIF can attach separate collision shapes to
## separate NiAVObjects (e.g. a shape on the door leaf, another on its
## static frame), and each needs its own PhysicsServer3D body/transform.
## An animated node's collision therefore actually follows it when it
## moves, matching the source NIF exactly — this is the whole point of
## Dynamic objects using this function instead of the flattened Static
## path (see this project's own "generation of an object from a NIF should
## be a consistent code path" principle, phases/3/00-door-completion.md).
##
## Returns the array of built Node3D, indexed exactly like
## NifReader.get_scene_nodes() — entry i's Node3D is the return value's
## [i], so a caller (e.g. a future animation player resolving a track's
## target_node_name) can look up the right node directly.
func populate_dynamic_children(parent: Node3D, nif: NifReader, model_path: String, geometry: Dictionary = {}) -> Array:
	if geometry.is_empty():
		geometry = build_geometry_entries(resolve_raw_geometry(nif, model_path))

	var entries: Array = nif.get_scene_nodes()
	var built: Array = []
	built.resize(entries.size())
	for i in entries.size():
		var e: Dictionary = entries[i]
		var n3d := Node3D.new()
		var raw_name: String = e["name"] if not String(e["name"]).is_empty() else "SceneNode%d" % i
		n3d.name = raw_name.validate_node_name()
		n3d.transform = e["transform"]
		built[i] = n3d

	# Real NIFs always emit a parent block before its children (needed for
	# the format's own streaming parse), so a single forward pass normally
	# suffices — this loop still tolerates any order via repeated passes,
	# since scene_nodes is small enough (bounded by one NIF's own block
	# count) for that to cost nothing real.
	var attached: Array = []
	attached.resize(entries.size())
	attached.fill(false)
	var remaining := entries.size()
	while remaining > 0:
		var progressed := false
		for i in entries.size():
			if attached[i]:
				continue
			var parent_index: int = entries[i]["parent_index"]
			var node_parent: Node3D = parent if parent_index == -1 else (built[parent_index] if attached[parent_index] else null)
			if parent_index != -1 and not attached[parent_index]:
				continue
			node_parent.add_child(built[i])
			attached[i] = true
			remaining -= 1
			progressed = true
		if not progressed:
			push_error("populate_dynamic_children: scene_nodes has a parent_index cycle -- %d node(s) left unattached" % remaining)
			break

	# owning_node_index == -1 means "attached directly to the NIF's root" --
	# `parent` IS this tree's own root-equivalent (scene_nodes never
	# contains an entry for the file's own root, by design; see SceneNode's
	# doc comment), never built[0], which is just the block-index-order
	# FIRST scene node -- an arbitrary, unrelated node whenever one exists
	# at all. A real, previously-shipped bug: the -1 case used built[0] as
	# a fallback meant only for the (much rarer) truly-empty-scene_nodes
	# case, silently misplacing anything legitimately root-attached
	# whenever the NIF ALSO had other scene nodes -- confirmed via real
	# visual inspection in nif_viewer.tscn (a door's collision showing up
	# offset from its mesh).
	var i := 0
	for entry in geometry["mesh_entries"]:
		var owning: int = nif.get_submesh_owning_node_index(i)
		var mesh_parent: Node3D = built[owning] if owning >= 0 and owning < built.size() else parent
		var mi := MeshInstance3D.new()
		mi.name = ("sub%d_%s" % [i, nif.get_submesh_name(i)]).validate_node_name()
		mi.mesh = entry["mesh"]
		mesh_parent.add_child(mi)
		i += 1

	# Real hierarchy for collision too -- see this function's own doc
	# comment. Grouped by owning_node_index rather than one single body:
	# two shapes attached to two different NiAVObjects in the source NIF
	# (a real case -- e.g. one shape on the door leaf, another on its
	# frame) need two separate GamebryoCollisionBody instances, one per
	# owning node, since a PhysicsServer3D body has exactly one transform/
	# parent of its own; shapes sharing the same owning_node_index still
	# share one body, same as populate_collision_children()'s existing
	# convention.
	var bodies_by_owner: Dictionary = {}
	var owner_local: Dictionary = {} # owning_node_index -> its Node3D's own transform relative to `parent`
	for entry in geometry["shape_entries"]:
		var owning: int = entry.get("owning_node_index", -1)
		if not bodies_by_owner.has(owning):
			var shape_parent: Node3D = built[owning] if owning >= 0 and owning < built.size() else parent
			var body := GamebryoCollisionBody.new()
			body.name = "CollisionBody" if bodies_by_owner.is_empty() else "CollisionBody%d" % bodies_by_owner.size()
			body.owner_ref = parent # the logical object this collider represents, not its immediate Node3D parent -- same convention as populate_collision_children()
			shape_parent.add_child(body)
			bodies_by_owner[owning] = body
			# Deliberately NOT global_transform: this whole subtree is
			# commonly built OFF-tree (every other factory in
			# object_registry.gd builds its node fully before the caller
			# add_child()s it into the real scene) and global_transform
			# requires is_inside_tree() -- confirmed the hard way, a real
			# crash the first time this ran through object_registry.gd's
			# _instantiate_dynamic() instead of nif_viewer.gd (which
			# happens to attach `parent` to a live tree first). Walking
			# .transform (always LOCAL, always valid regardless of tree
			# membership) up from shape_parent to `parent` gives the same
			# "shape_parent as seen from parent" frame entry["transform"]
			# (native's flattened-to-NIF-root value) is expressed in,
			# without that dependency.
			owner_local[owning] = _local_transform_relative_to(shape_parent, parent)
		var col := CollisionShape3D.new()
		col.name = String(entry.get("name", "collision"))
		col.shape = entry["shape"]
		# entry["transform"] is flattened all the way to the NIF's root
		# (native's flatten_via_scene_nodes()) -- but col's real parent
		# (via `body`, which carries no offset of its own) is shape_parent,
		# which ALREADY supplies everything up to and including that same
		# node via ordinary Node3D composition. Applying the full
		# root-relative transform on top double-composes it -- a real bug,
		# not a NIF-authoring quirk: confirmed visually (a door's collision
		# sitting offset from its own mesh by roughly the door's own
		# width, in nif_viewer.tscn) before this fix.
		col.transform = owner_local[owning].affine_inverse() * entry["transform"]
		bodies_by_owner[owning].add_child(col)

	return built

## `node`'s transform as seen from `ancestor` (which MUST actually be an
## ancestor of `node` in the Node tree) -- composes only .transform (each
## Node3D's own LOCAL value, relative to its immediate parent), never
## global_transform, so this works identically whether or not the subtree
## is attached to a live SceneTree yet. Godot's own composition rule is
## child.global_transform == parent.global_transform * child.transform;
## walking that same rule upward from `node` and stopping the instant the
## current node's PARENT is `ancestor` (excluding ancestor's own transform)
## gives exactly "node relative to ancestor".
func _local_transform_relative_to(node: Node3D, ancestor: Node3D) -> Transform3D:
	var result := Transform3D.IDENTITY
	var current: Node3D = node
	while current != ancestor:
		result = current.transform * result
		var p := current.get_parent()
		if not (p is Node3D):
			push_error("_local_transform_relative_to: '%s' is not an ancestor of '%s'" % [ancestor.name, node.name])
			break
		current = p
	return result

## phases/3/00-door-completion.md step 6 prep: builds a real AnimationPlayer
## as a child of `parent`, with one Animation per NifReader.get_animation_
## sequences() entry (named exactly as authored, e.g. "Open"/"Close"),
## targeting the real nodes `built` (populate_dynamic_children()'s own
## return value) already placed — Option 1 from that phase doc's own
## research: native typed TYPE_POSITION_3D/TYPE_ROTATION_3D/TYPE_SCALE_3D
## tracks, playable with zero extra code via Godot's own AnimationPlayer
## editor panel (select the node, the bottom panel lists every animation).
## Returns null if the NIF has no animation data at all (the common case).
##
## Per-track interpolation is decided per KEY's own recorded type (see
## nif_types.h's KeyInterpolation), using the FIRST key as representative
## (Godot's Animation track interpolation is a per-TRACK setting, not
## per-key — a real, if rare, loss of fidelity for a track whose keys mix
## interpolation types, no different in kind from the CUBIC-standing-in-for-
## QUADRATIC-and-TBC approximation this project already accepted, see this
## function's own doc comment further down):
##   none/constant -> NEAREST, linear -> LINEAR, quadratic/tbc -> CUBIC.
##
## Quaternion-keyed tracks map straight onto TYPE_ROTATION_3D (Godot wants
## exactly what NiTransformData's quaternionKeys already are). Per-axis
## (XYZ) rotation tracks are the real complication: real data confirmed
## x/y/z key COUNTS and TIMES can all differ (e.g. a real door: x=1 y=1
## z=3 keys) yet Godot's TYPE_ROTATION_3D wants one Quaternion per
## keyframe, not three independent curves — resampled here at the union of
## every axis's own key times, each axis's SOURCE value linearly
## interpolated at that time (not its own authored interpolation type —
## a second, smaller approximation on top of the per-track one above,
## since combining three curves with three different authored
## interpolation types into one sampled point has no single "correct"
## per-key type to assign anyway), then combined via
## Basis.from_euler(Vector3(x,y,z), EULER_ORDER_XYZ) -- Godot's own named
## XYZ order, matching NiKeyType's own "XYZ_ROTATION_KEY" name, but NOT
## independently verified against a primary NIF-format spec (nifly itself
## only stores these curves, never composes/evaluates them -- no reference
## implementation to check against in this codebase). Flagged, not silently
## assumed: verify by actually playing a real per-axis-keyed animation
## (the door case) in the editor and confirming it swings the way real
## gameplay footage does -- exactly the acceptance test this feature's own
## phase step already calls for.
func populate_animation_player(parent: Node3D, nif: NifReader, built: Array) -> AnimationPlayer:
	var sequences: Array = nif.get_animation_sequences()
	if sequences.is_empty() or built.is_empty():
		return null

	var name_to_index: Dictionary = {}
	var scene_node_entries: Array = nif.get_scene_nodes()
	for i in scene_node_entries.size():
		name_to_index[String(scene_node_entries[i]["name"])] = i

	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	parent.add_child(player)
	player.root_node = NodePath("..") # `parent` itself -- every NodePath below is parent.get_path_to(...)

	var library := AnimationLibrary.new()
	for seq in sequences:
		var anim := Animation.new()
		anim.length = maxf(float(seq["stop_time"]) - float(seq["start_time"]), 0.01)
		match int(seq["cycle_type"]): # nif::SequenceCycleType: 0=loop, 1=reverse, 2=clamp
			0: anim.loop_mode = Animation.LOOP_LINEAR
			_: anim.loop_mode = Animation.LOOP_NONE # reverse/clamp both play once and hold -- Godot has no native ping-pong-once mode; reverse is a real gap, not silently faked

		for track in seq["tracks"]:
			var target_name: String = track["target_node_name"]
			if not name_to_index.has(target_name):
				continue # target isn't one of THIS NIF's own scene_nodes -- a real, if unexpected, case; skip rather than crash
			var target_node: Node3D = built[name_to_index[target_name]]
			var node_path: NodePath = parent.get_path_to(target_node)

			if bool(track["has_quaternion_keys"]):
				var idx := anim.add_track(Animation.TYPE_ROTATION_3D)
				anim.track_set_path(idx, node_path)
				var keys: Array = track["quaternion_keys"]
				anim.track_set_interpolation_type(idx, _godot_interp(int(keys[0]["interp"])) if not keys.is_empty() else Animation.INTERPOLATION_LINEAR)
				for k in keys:
					anim.track_insert_key(idx, float(k["time"]), k["value"])
			elif bool(track["has_axis_keys"]):
				var idx := anim.add_track(Animation.TYPE_ROTATION_3D)
				anim.track_set_path(idx, node_path)
				anim.track_set_interpolation_type(idx, Animation.INTERPOLATION_LINEAR) # resampled below -- see this function's own doc comment
				for sample in _resample_axis_rotation(track["x_rotation_keys"], track["y_rotation_keys"], track["z_rotation_keys"]):
					anim.track_insert_key(idx, sample["time"], sample["quat"])

			var translation_keys: Array = track["translation_keys"]
			if not translation_keys.is_empty():
				var idx := anim.add_track(Animation.TYPE_POSITION_3D)
				anim.track_set_path(idx, node_path)
				anim.track_set_interpolation_type(idx, _godot_interp(int(translation_keys[0]["interp"])))
				for k in translation_keys:
					anim.track_insert_key(idx, float(k["time"]), k["value"])

			var scale_keys: Array = track["scale_keys"]
			if not scale_keys.is_empty():
				var idx := anim.add_track(Animation.TYPE_SCALE_3D)
				anim.track_set_path(idx, node_path)
				anim.track_set_interpolation_type(idx, _godot_interp(int(scale_keys[0]["interp"])))
				for k in scale_keys:
					anim.track_insert_key(idx, float(k["time"]), Vector3.ONE * float(k["value"]))

		library.add_animation(String(seq["name"]), anim)
	player.add_animation_library("", library)
	return player

## nif::KeyInterpolation (0=none/1=linear/2=quadratic/3=tbc/4=constant) ->
## Godot's own Animation.InterpolationType. See populate_animation_player()'s
## own doc comment for why quadratic/tbc both collapse to CUBIC.
func _godot_interp(nif_interp: int) -> int:
	match nif_interp:
		1: return Animation.INTERPOLATION_LINEAR
		2, 3: return Animation.INTERPOLATION_CUBIC
		_: return Animation.INTERPOLATION_NEAREST # 0=none, 4=constant

## See populate_animation_player()'s own doc comment for the real
## misaligned-key-time problem this resamples around, and the unverified
## EULER_ORDER_XYZ composition assumption. Each axis is linearly
## interpolated at every OTHER axis's key times too (not just its own),
## since Godot's single combined Quaternion track needs one shared sample
## grid — this is a real precision loss on top of nif_loader.cpp's own
## per-key tangent data, deliberately accepted per this project's existing
## "CUBIC approximates QUADRATIC/TBC" precedent.
func _resample_axis_rotation(x_keys: Array, y_keys: Array, z_keys: Array) -> Array:
	var times: Dictionary = {} # used as an ordered set (Godot Dictionaries preserve insertion order; sorted explicitly below anyway)
	for k in x_keys: times[float(k["time"])] = true
	for k in y_keys: times[float(k["time"])] = true
	for k in z_keys: times[float(k["time"])] = true
	if times.is_empty():
		return []
	var sorted_times: Array = times.keys()
	sorted_times.sort()

	var out: Array = []
	for t in sorted_times:
		var euler := Vector3(_eval_float_keys_linear(x_keys, t), _eval_float_keys_linear(y_keys, t), _eval_float_keys_linear(z_keys, t))
		out.append({ "time": t, "quat": Quaternion(Basis.from_euler(euler, EULER_ORDER_XYZ)) })
	return out

## Linear-interpolated value of a nif::FloatKey array at time `t` (clamped
## at the ends, matching Animation.LOOP_NONE's own hold-last-value
## behavior). Empty `keys` (an axis that never animates at all -- a real,
## common case) returns 0.0, not an error.
func _eval_float_keys_linear(keys: Array, t: float) -> float:
	if keys.is_empty():
		return 0.0
	if t <= float(keys[0]["time"]):
		return float(keys[0]["value"])
	if t >= float(keys[keys.size() - 1]["time"]):
		return float(keys[keys.size() - 1]["value"])
	for i in range(keys.size() - 1):
		var t0 := float(keys[i]["time"])
		var t1 := float(keys[i + 1]["time"])
		if t >= t0 and t <= t1:
			var u := (t - t0) / (t1 - t0) if t1 > t0 else 0.0
			return lerpf(float(keys[i]["value"]), float(keys[i + 1]["value"]), u)
	return float(keys[keys.size() - 1]["value"]) # unreachable given the bounds checks above, kept as a safe fallback

## phases/2/12-distant-object-lod.md, step 8: the real (single-sourced, not
## duplicated across GDScript/C++) configurable crossover distance and
## hysteresis margin, defaulting to the same placeholder values step 6/7
## shipped with. One flat global number, not the real per-category/
## size-proportional system enginedocs/lod.md's own [LOD] ini excerpt
## describes — per that task doc's explicit scoping, a starting value to
## get the mechanism correct, not a tuned one. Set via set_lod_crossover()
## (a caller with a real @export, e.g. WorldStreamer/CellLoader, threads its
## own inspector-tunable value in) rather than editing these fields
## directly, mirroring DirectGeometryBatch's own identically-named method on
## the RID-based side.
var lod_crossover_distance_m := 100.0
var lod_crossover_margin_m := 5.0

func set_lod_crossover(distance_m: float, margin_m: float) -> void:
	lod_crossover_distance_m = distance_m
	lod_crossover_margin_m = margin_m

## Sets one MeshInstance3D's crossover visibility range: `is_full_detail`
## true -> visible only within lod_crossover_distance_m
## (visibility_range_end, Godot's own "hide beyond this distance" field);
## false -> visible only beyond it (visibility_range_begin, "hide closer
## than this distance"). VISIBILITY_RANGE_FADE_DISABLED — hard cutover +
## margin-based hysteresis — per this task doc's own Design section: Godot's
## docs call this the cheapest manual-LOD approach; revisit FADE_SELF
## crossfading later (step 10) only if the hard cut looks bad in real play.
func _apply_lod_visibility_range(mi: MeshInstance3D, is_full_detail: bool) -> void:
	mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
	if is_full_detail:
		mi.visibility_range_end = lod_crossover_distance_m
		mi.visibility_range_end_margin = lod_crossover_margin_m
	else:
		mi.visibility_range_begin = lod_crossover_distance_m
		mi.visibility_range_begin_margin = lod_crossover_margin_m

## Builds a CollisionShape3D child per extracted bhk* shape (phases/1/02-
## collision-extraction.md), or one bounding-box fallback collider (from the
## render mesh's own AABB) if the NIF has no collision data at all — per
## the phase doc's explicit requirement that meshless-collision objects
## still get *something* walkable rather than no collision. The underlying
## Shape3D Resources (and the fallback box's size/position) are cached per
## model_path — only the CollisionShape3D *nodes* are built fresh per
## placement, same reasoning as populate_mesh_children().
##
## `geometry` (optional): see populate_mesh_children()'s own doc comment —
## same pre-built-data-sharing purpose.
##
## CollisionShape3D children go under a GamebryoCollisionBody child of
## `parent`, not `parent` directly (enginedocs/nv_class_hierarchy.md:
## GamebryoReference is Node3D now, not StaticBody3D, so `parent` has no
## physics body of its own to hang shapes off — composition adds one here,
## lazily, only when there's at least one real shape to attach). A raycast
## hit resolves to this body as `collider`; callers walk `collider.owner_ref`
## to reach `parent` (see game.gd's interact raycast).
func populate_collision_children(parent: Node3D, nif: NifReader, model_path: String, geometry: Dictionary = {}) -> void:
	if geometry.is_empty():
		geometry = build_geometry_entries(resolve_raw_geometry(nif, model_path))
	var shape_entries: Array = geometry["shape_entries"]
	if shape_entries.is_empty():
		return
	var body := GamebryoCollisionBody.new()
	body.name = "CollisionBody"
	body.owner_ref = parent
	parent.add_child(body)
	for entry in shape_entries:
		var col := CollisionShape3D.new()
		col.name = String(entry.get("name", "collision"))
		col.shape = entry["shape"]
		col.transform = entry["transform"]
		body.add_child(col)

func _build_mesh_from_raw(e: Dictionary) -> ArrayMesh:
	var pos_flat: PackedFloat32Array = e["positions"]
	var norm_flat: PackedFloat32Array = e["normals"]
	var uv_flat: PackedFloat32Array = e["uvs"]
	var idx_flat: PackedInt32Array = e["indices"]
	var colors: PackedColorArray = e["colors"]

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
func _build_material_from_raw(e: Dictionary) -> StandardMaterial3D:
	var tex_path: String = e["texture_path"]
	var normal_path: String = e["normal_texture_path"]
	var glow_path: String = e["glow_texture_path"]
	var alpha: Dictionary = e["alpha_info"]
	var has_vertex_colors: bool = e["has_vertex_colors"]
	var is_unlit: bool = e["is_unlit"]

	if tex_path == "" and normal_path == "" and glow_path == "" and not has_vertex_colors and not bool(alpha.get("has_alpha_property", false)):
		return null
	var key := "%s|%s|%s|%s|%s|%.4f|%d|%s|%s" % [tex_path, normal_path, glow_path,
			bool(alpha.get("blend_enabled", false)), bool(alpha.get("test_enabled", false)),
			float(alpha.get("threshold", 0.5)), int(alpha.get("blend_func", 0)), has_vertex_colors, is_unlit]
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

	# `texture_key` (not tex_path) so the RGBA8 alpha-safe variant of a DXT1
	# diffuse gets its own _texture_cache slot -- see _tex_variant_key().
	# Falls back to tex_path for a pre-fix `raw` Dictionary shape.
	var albedo := _get_texture_from_image(String(e.get("texture_key", tex_path)), e.get("diffuse_image"))
	if albedo != null:
		mat.albedo_texture = albedo
		have_content = true

	var normal_tex := _get_texture_from_image(normal_path, e.get("normal_image"))
	if normal_tex != null:
		mat.normal_enabled = true
		mat.normal_texture = normal_tex
		have_content = true

	var glow_tex := _get_texture_from_image(glow_path, e.get("glow_image"))
	if glow_tex != null:
		mat.emission_enabled = true
		mat.emission_texture = glow_tex
		have_content = true

	if bool(alpha.get("blend_enabled", false)):
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		# phases/2/01-material-pipeline.md's known gap, closed: the real
		# src/dst blend-function bits, decoded in nif_loader.cpp
		# (nif::SubMesh::BlendFunc) against a real-data census of ~2,000
		# NIFs' NiAlphaProperty blocks -- 92% ordinary mix, ~5% additive
		# (light-shaft/glow effects like IndFXLightRays*.nif, which
		# genuinely ship src=SRC_ALPHA dst=ONE, not Godot's default mix),
		# ~3% multiply. blend_func is int-typed on the wire (not a Godot
		# enum) since nif_reader_gd's C++ side has no godot-cpp BaseMaterial3D
		# dependency to draw the enum from -- mapped explicitly here, not by
		# numeric coincidence (our kMultiply=2 is Godot's BLEND_MODE_MUL=3).
		match int(alpha.get("blend_func", 0)):
			1: mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
			2: mat.blend_mode = BaseMaterial3D.BLEND_MODE_MUL
			_: mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
		have_content = true
	elif bool(alpha.get("test_enabled", false)):
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		# Bethesda's test is "keep if alpha GREATER than threshold", and Godot's
		# scissor discards when alpha < threshold, so a shipped threshold of 0
		# (treejoshanv_lod.nif and friends -- 41 of ~330 test-enabled shapes
		# sampled ship exactly 0) discards NOTHING -- the tree-billboard
		# black-background bug. A literal epsilon floor (1/255) was tried
		# first and traded "solid black square" for "blobby thick black
		# fringe": the texture's own mip chain averages alpha outward across
		# black background texels, and near-zero-alpha fringe renders fully
		# opaque under a binary scissor. Confirmed by a real-GPU scale/
		# threshold matrix render (_diag_billboard_fringe.gd): 0.25-0.5 both
		# resolve individual branches at every mip level, 1/255 blobs. 0.5 is
		# used for the zero case -- the modal value Bethesda's own artists
		# authored (128/255 is the most common shipped threshold in the same
		# sample), and the value Godot's docs recommend against mip alpha
		# bleed. Real non-zero thresholds are used as-authored, including
		# deliberately soft ones (16/255 edge trims, 32/255 road strips --
		# visually confirmed correct in play). See memory:
		# black-background-decal-findings.
		var threshold := float(alpha.get("threshold", 0.5))
		mat.alpha_scissor_threshold = threshold if threshold > 0.0 else 0.5
		have_content = true

	var result := mat if have_content else null
	_material_cache[key] = result
	return result

## The GPU-upload step (ImageTexture.create_from_image()) -- main-thread-
## only, see this class's own top-of-file doc comment. `image` is the
## already-decoded pixel data resolve_raw_geometry() attached to the raw
## mesh entry; no BSA/DDS work happens here at all, just the RS upload +
## cache lookup.
func _get_texture_from_image(tex_path: String, image: Image) -> ImageTexture:
	if tex_path == "":
		return null
	if _texture_cache.has(tex_path):
		texture_cache_hits += 1
		return _texture_cache[tex_path]
	texture_cache_misses += 1
	var tex: ImageTexture = null
	if image != null:
		tex = ImageTexture.create_from_image(image)
	_texture_cache[tex_path] = tex
	return tex

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

## Worker-safe: returns raw, kind-tagged collision geometry (NifReader's own
## bhk*-derived descriptors, or a computed fallback-bbox AABB) -- no Shape3D
## constructed here at all. See _build_collision_shapes() for the main-
## thread-only counterpart that actually builds Shape3D Resources from this.
func _resolve_raw_collision(nif: NifReader) -> Array:
	var shapes: Array = nif.get_collision_shapes()
	if not shapes.is_empty():
		return shapes
	# Only fabricate a bounding-box collider when Havok collision was
	# actually authored on this NIF but our parser couldn't extract it
	# (composite bhkListShape/bhkConvexListShape, bhkBlendCollisionObject/
	# bhkNPCollisionObject — see nif_loader.cpp) -- a real parser gap
	# where "something walkable" beats nothing. A NIF with NO collision
	# data at all (has_collision_data == false) means the artist never
	# intended this to be solid -- window-light volumetrics, markers
	# (project/gamebryo/marker_node.gd) -- and must stay collision-free,
	# not get an invented box the original engine never had either.
	if not nif.has_collision_data():
		return []
	return _resolve_raw_fallback_bbox(nif)

func _resolve_raw_fallback_bbox(nif: NifReader) -> Array:
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
	return [{ "kind": "fallback_bbox", "center": combined.get_center(), "size": combined.size }]

## Main-thread-only: constructs the actual Shape3D Resources from
## _resolve_raw_collision()'s plain kind-tagged descriptors -- the part of
## the old _build_collision_descriptors() that touched PhysicsServer3D.
func _build_collision_shapes(raw_shapes: Array) -> Array:
	var out: Array = []
	for s in raw_shapes:
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
			"fallback_bbox":
				var fbox := BoxShape3D.new()
				var size: Vector3 = s.get("size", Vector3.ONE)
				fbox.size = size.max(Vector3.ONE * 0.05) # avoid a degenerate zero-thickness box
				transform = Transform3D(Basis.IDENTITY, s.get("center", Vector3.ZERO))
				shape = fbox
			_:
				continue
		out.append({
			"kind": kind, "shape": shape, "transform": transform, "name": "collision_%s" % String(s.get("name", kind)),
			"owning_node_index": s.get("owning_node_index", -1), # absent (fallback_bbox) -> -1, not tied to a single node
		})
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
