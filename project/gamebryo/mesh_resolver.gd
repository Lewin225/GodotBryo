class_name GamebryoMeshResolver
extends RefCounted

const NO_LIGHTING_FALLOFF_SHADER := preload("res://gamebryo/no_lighting_falloff.gdshader")

const GameDataConfigScript := preload("res://game_data_config.gd")
const KF_ANIMATION_CACHE_VERSION := "kf-animation-v4"
const KF_ANIMATION_CACHE_DIR := "user://nv_kf_animation_cache"
const LOCOMOTION_FOLDER_PREFIX := "meshes/characters/_male/locomotion/"
const THIRD_PERSON_ANIMATION_FOLDER_PREFIX := "meshes/characters/_male/"

# Animation discovery is independent of an individual actor.  Keep the
# archive census process-wide so each resolver/actor does not walk every BSA
# entry again.  The clip-set entries remain keyed by the requested NIF path;
# two models may therefore have separate logical entries while sharing the
# same discovered source paths and converted Animation resources.
static var _shared_animation_file_lists: Dictionary = {}
static var _shared_animation_clip_sets: Dictionary = {}
static var _shared_converted_animation_cache: Dictionary = {}

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

var _data_dir := ""


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
var _tri_cache := {} # TRI path -> parsed TriReader or null

# --- Final-build state (main-thread-only; lives solely on
# GamebryoObjectRegistry's own single, non-pooled `resolver` instance) ---
var _mesh_cache := {} # "model_path#submesh_index" -> ArrayMesh
var _texture_cache := {} # tex_path -> ImageTexture or null
var _material_cache := {} # material key -> StandardMaterial3D
var _collision_cache := {} # model_path -> Array of { "shape": Shape3D, "transform": Transform3D, "name": String }
var _skin_mesh_cache := {} # "model_path#submesh_index#skin" -> ArrayMesh (see populate_skeleton()) -- kept separate from _mesh_cache since these surfaces carry ARRAY_BONES/ARRAY_WEIGHTS a non-skinned build of the same submesh must never pick up
var _facegen_geometry_cache := {} # EGM path -> FaceGenGeometryAsset or null
var _animation_cache := {} # cache key -> converted Animation resource

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
	_merge_dict(_tri_cache, other._tri_cache)

static func _merge_dict(target: Dictionary, source: Dictionary) -> void:
	for key in source:
		if not target.has(key):
			target[key] = source[key]

## Main-thread callers pass GameDataSettings' validated path. The fallback is
## retained for isolated tests/diagnostics; worker contexts always receive an
## explicit string from GamebryoResolverPool.
func _init(data_dir: String = "") -> void:
	_data_dir = data_dir if data_dir != "" else String(GameDataConfigScript.resolve().get("data_dir", ""))
	if _data_dir == "":
		push_error("GamebryoMeshResolver: no validated game data directory configured")
		return
	_build_bsa_order()

func _build_bsa_order() -> void:
	var dir := DirAccess.open(_data_dir)
	if dir == null:
		push_error("GamebryoMeshResolver: could not open data directory: " + _data_dir)
		_bsa_order = []
		return
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
	if not r.open(_data_dir + bsa_name):
		_bsa_readers[bsa_name] = null
		return null
	_bsa_readers[bsa_name] = r
	return r

## Lists every real file whose normalized path (lowercase, forward
## slashes -- BsaReader.list_entries()'s own convention) starts with
## `folder_prefix`, across every BSA in the same priority order
## resolve_bytes() uses -- for review/discovery tooling that needs to find
## real files by folder rather than load one already-known path (e.g. "what
## movement .kf files actually exist" rather than a hand-picked guess at
## their names). Deduplicated across archives -- first BSA in priority
## order wins for a given path, same precedence resolve_bytes() itself
## uses. Worker-safe (BsaReader I/O only).
func list_files_with_prefix(folder_prefix: String) -> PackedStringArray:
	var prefix := folder_prefix.to_lower().replace("\\", "/")
	var seen := {}
	var out := PackedStringArray()
	for bsa_name in _bsa_order:
		var r := _get_reader(bsa_name)
		if r == null:
			continue
		for entry_path in r.list_entries():
			if seen.has(entry_path):
				continue
			if entry_path.begins_with(prefix):
				seen[entry_path] = true
				out.append(entry_path)
	return out

## Returns the animation sources associated with a model NIF.  The public
## lookup is deliberately model-path keyed: callers do not need to know
## about the shared human skeleton or Bethesda's folder conventions.
##
## The optional weapon argument supplies the ESM-authored animation family
## and action names.  It is not part of the cache identity because a given
## model path is expected to have one authored animation association.  The
## returned dictionary contains source paths only; conversion to Godot
## Animation resources remains target-aware and is handled by the existing
## KF conversion cache.
func get_animation_clip_set(nif_path: String, weapon = null) -> Dictionary:
	var model_key := nif_path.to_lower().replace("/", "\\")
	if model_key.is_empty():
		return {"clips": {}, "weapon_clip_names": []}
	var source_key := _animation_source_key()
	var cache_key := source_key + "|" + model_key
	if _shared_animation_clip_sets.has(cache_key):
		return _shared_animation_clip_sets[cache_key]

	var locomotion := _shared_animation_file_list(source_key, LOCOMOTION_FOLDER_PREFIX)
	var third_person := _shared_animation_file_list(source_key, THIRD_PERSON_ANIMATION_FOLDER_PREFIX)
	var clips := {}
	var weapon_clip_names: Array[String] = []
	var family := String(weapon.animation_family).to_lower() if weapon != null else ""

	for entry in locomotion:
		var path := String(entry)
		if not path.ends_with(".kf"):
			continue
		var relative := path.trim_prefix(LOCOMOTION_FOLDER_PREFIX)
		var filename := relative.get_file().to_lower()
		if not filename.begins_with("mt") and (family.is_empty() or not filename.begins_with(family)):
			continue
		var clip_name := relative.replace("/", "__")
		clips[clip_name] = "characters\\_male\\locomotion\\" + relative.replace("/", "\\")
		if not family.is_empty() and filename.begins_with(family):
			weapon_clip_names.append(clip_name)

	if weapon != null:
		var desired_actions := {}
		for action in ["equip", "unequip", "idle", "block", "holster", "attack", "reload", "grip"]:
			var action_clip := String(weapon.action_clip_name(action)).to_lower()
			if not action_clip.is_empty():
				desired_actions[action_clip] = true
		for entry in third_person:
			var path := String(entry).to_lower()
			if not path.ends_with(".kf") or "/locomotion/" in path:
				continue
			var relative := path.trim_prefix(THIRD_PERSON_ANIMATION_FOLDER_PREFIX)
			if relative.contains("/"):
				continue
			var filename := relative.get_file()
			if not desired_actions.has(filename):
				continue
			var clip_name := relative.replace("/", "__")
			clips[clip_name] = "characters\\_male\\" + relative.replace("/", "\\")
			weapon_clip_names.append(clip_name)

	var result := {"clips": clips, "weapon_clip_names": weapon_clip_names}
	_shared_animation_clip_sets[cache_key] = result
	return result

func _animation_source_key() -> String:
	return _data_dir.to_lower() + "|" + ",".join(_bsa_order).to_lower()

func _shared_animation_file_list(source_key: String, folder_prefix: String) -> PackedStringArray:
	var key := source_key + "|" + folder_prefix
	if _shared_animation_file_lists.has(key):
		return _shared_animation_file_lists[key]
	var files := list_files_with_prefix(folder_prefix)
	_shared_animation_file_lists[key] = files
	return files

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

func load_facegen_geometry(model_path: String, variant: String = "") -> FaceGenGeometryAsset:
	var egm_path := model_path.to_lower().trim_suffix(".nif")
	if not variant.is_empty() and not egm_path.ends_with(variant):
		egm_path += variant
	egm_path += ".egm"
	if _facegen_geometry_cache.has(egm_path):
		return _facegen_geometry_cache[egm_path]
	var found := resolve_bytes("meshes\\" + egm_path)
	var asset: FaceGenGeometryAsset = null
	if not found.is_empty():
		asset = _parse_facegen_egm(found["data"], egm_path)
		if asset == null:
			push_warning("GamebryoMeshResolver: failed to parse FaceGen EGM '%s'" % egm_path)
	_facegen_geometry_cache[egm_path] = asset
	return asset

## FaceGen animation asset paired with a head NIF. Parsed TRI resources are
## shared across NPCs; the final ArrayMesh is always NPC-specific.
func load_tri(model_path: String) -> TriReader:
	var tri_path := model_path.to_lower().trim_suffix(".nif") + ".tri"
	if _tri_cache.has(tri_path):
		return _tri_cache[tri_path]
	var found := resolve_bytes("meshes\\" + tri_path)
	var asset: TriReader = null
	if not found.is_empty():
		var candidate := TriReader.new()
		if candidate.load(found["data"], tri_path):
			asset = candidate
		else:
			push_warning("GamebryoMeshResolver: failed to parse TRI '%s': %s" % [tri_path, candidate.get_last_error()])
	else:
		push_warning("GamebryoMeshResolver: TRI '%s' not found in any BSA" % tri_path)
	_tri_cache[tri_path] = asset
	return asset

func _parse_facegen_egm(data: PackedByteArray, source_path: String) -> FaceGenGeometryAsset:
	if data.size() < 64 or data.slice(0, 8).get_string_from_ascii() != "FREGM002":
		return null
	var vertex_count := int(data.decode_u32(8))
	var symmetric_count := int(data.decode_u32(12))
	var asymmetric_count := int(data.decode_u32(16))
	var mode_bytes := 4 + vertex_count * 3 * 2
	if vertex_count <= 0 or 64 + (symmetric_count + asymmetric_count) * mode_bytes != data.size():
		return null
	var asset := FaceGenGeometryAsset.new()
	asset.source_path = source_path
	asset.vertex_count = vertex_count
	asset.symmetric_mode_count = symmetric_count
	asset.asymmetric_mode_count = asymmetric_count
	var offset := 64
	for mode_index in symmetric_count + asymmetric_count:
		var scale := data.decode_float(offset)
		offset += 4
		var deltas := PackedFloat32Array()
		deltas.resize(vertex_count * 3)
		for i in vertex_count * 3:
			# EGM stores vertex deltas in raw Gamebryo units. NIF positions
			# have already been converted to meters by the native reader.
			deltas[i] = float(data.decode_s16(offset)) * scale / 70.0
			offset += 2
		if mode_index < symmetric_count:
			asset.symmetric_basis.append(deltas)
		else:
			asset.asymmetric_basis.append(deltas)
	return asset

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
	if found.is_empty():
		# Real bug report (2026-08-23): a placement can go permanently
		# missing -- geometry AND collision, consistent even standing right
		# next to it -- with zero signal why, because a failure here caches
		# `null` under model_path exactly like a real NifReader (see this
		# function's own return path below), and GamebryoResolverPool.
		# merge_from() then propagates that null into every other pooled
		# worker context forever. This warning is the only way to tell "not
		# found in any BSA" apart from "found, but NifReader.load() rejected
		# it" apart from "genuinely has no model" (that last case never
		# reaches this function at all -- callers already check
		# placement.model != "" first) after the fact, instead of guessing
		# offline.
		push_warning("GamebryoMeshResolver: %s not found in any BSA (meshes\\%s)" % [model_path, model_path])
	else:
		var candidate := NifReader.new()
		if candidate.load(found["data"]):
			nif = candidate
		else:
			push_warning("GamebryoMeshResolver: %s found in %s but NifReader.load() failed to parse it" % [model_path, found["bsa"]])
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
	if found.is_empty():
		# Same permanent-null-cache concern as load_nif()'s own comment --
		# a texture that fails here silently leaves whatever used it with no
		# diffuse/normal/glow, cached that way for the rest of the session.
		push_warning("GamebryoMeshResolver: %s not found in any BSA" % tex_path)
	else:
		var candidate := Image.new()
		var err := candidate.load_dds_from_buffer(found["data"])
		if err == OK:
			img = candidate
		else:
			push_warning("GamebryoMeshResolver: %s found in %s but failed to decode (err %d)" % [tex_path, found["bsa"], err])
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

## General-purpose, not tied to any one caller -- DOOR's Open/Close/Loop
## sounds today (phases/3/00-door-completion.md Part B), but this resolves
## ANY Sound/-relative path (EsmReader.resolve_soun_filename()'s own
## output, or any future caller's), same BSA-priority search everything
## else uses. `sound_path` has no "sound\" prefix (same convention as
## MODL/LTEX) -- added here. Cached by path, same reasoning as
## _texture_cache (a handful of real sounds -- door creaks, footsteps --
## get reused across many placements). Confirmed real-format feasibility
## directly: FNV's own DOOR sounds are plain .wav (not the Xbox-only .xwm
## some other Bethesda titles use), which Godot's own
## AudioStreamWAV.load_from_buffer() decodes natively -- no third-party
## decoder needed. Returns null if not found in any BSA or unparseable.
var _sound_cache := {} # sound_path -> AudioStreamWAV or null
func load_sound(sound_path: String) -> AudioStreamWAV:
	if sound_path == "":
		return null
	if _sound_cache.has(sound_path):
		return _sound_cache[sound_path]
	var found := resolve_bytes("sound\\" + sound_path)
	var stream: AudioStreamWAV = null
	if not found.is_empty():
		stream = AudioStreamWAV.load_from_buffer(found["data"])
	_sound_cache[sound_path] = stream
	return stream

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
	# Issue #47: real vertex morph targets -- keyed by the owning shape's own
	# name (NifReader.get_morph_data()'s own "target_node_name"), same join
	# convention as get_submesh_name(). Empty for the overwhelming majority
	# of NIFs; only real morph-capable content (e.g. cloth-ripple flags)
	# populates this.
	var morph_by_name: Dictionary = {}
	for morph in nif.get_morph_data():
		morph_by_name[String(morph["target_node_name"])] = morph

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
			"submesh_name": nif.get_submesh_name(i),
			# phases/3/00-door-completion.md follow-up: the TRUE native
			# NifReader submesh index, threaded through explicitly rather
			# than re-derived from a loop counter downstream -- a real,
			# confirmed bug otherwise: once ANY submesh is skipped here
			# (the EditorMarker case right above is the common one), every
			# entry after it in this array no longer lines up with its own
			# original index, silently misattaching owning_node_index/name
			# lookups in populate_dynamic_children() to the WRONG submesh
			# (confirmed against real data: IndDoorSmAnim01.NIF's doorframe
			# submesh (#3) got attached under its file's EditorMarker's own
			# owning node (#2's) instead of its own, because the build loop
			# assumed position-in-array == native index once #2 was
			# filtered out).
			"submesh_index": i,
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
			"no_lighting_falloff": nif.get_no_lighting_falloff(i),
			"double_sided": nif.is_double_sided(i),
			"diffuse_image": _load_image(tex_path, needs_alpha),
			"normal_image": _load_image(normal_path),
			"glow_image": _load_image(glow_path),
			"morph": morph_by_name.get(nif.get_submesh_name(i), {}),
			"tri": load_tri(model_path) if _is_facial_morph_model(model_path) else null,
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

static func _is_head_nif(model_path: String) -> bool:
	var p := model_path.to_lower().replace("/", "\\")
	return p.ends_with("characters\\head\\headhuman.nif") or p.ends_with("characters\\head\\headghoul.nif")

static func _is_head_part_model(model_path: String) -> bool:
	var p := model_path.to_lower().replace("/", "\\")
	return p.contains("characters\\head\\") or p.contains("characters\\hair\\")

static func _is_facial_morph_model(model_path: String) -> bool:
	var p := model_path.to_lower().replace("/", "\\")
	if not p.contains("characters\\head\\"):
		return false
	var file_name := p.get_file().get_basename()
	return file_name.begins_with("head") or file_name.begins_with("mouth") or file_name.begins_with("teeth") or file_name.begins_with("tongue")

static func _hair_variant_for_submesh(submesh_name: String) -> String:
	var n := submesh_name.to_lower().replace("_", "")
	if n.contains("nohat"):
		return "nohat"
	if n.ends_with("hat") or n.contains(":hat"):
		return "hat"
	return ""

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
			"physics_body_index": d.get("physics_body_index", -1),
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
			var morph: Dictionary = e.get("morph", {})
			if not morph.is_empty():
				mesh = _apply_morph_targets(mesh, morph)
			var mat := _build_material_from_raw(e)
			if mat != null:
				mesh.surface_set_material(0, mat)
			_mesh_cache[mesh_key] = mesh
		mesh_entries.append({
			"mesh": mesh,
			"transform": e["transform"],
			"submesh_index": e["submesh_index"],
			"texture_path": String(e.get("texture_path", "")),
			# Keep the source shader classification alongside the final mesh.
			# REFR.XEMI is a visual-effect tint, and must not recolour the
			# ordinary lit construction around an unlit pane/effect shape.
			"is_unlit": bool(e.get("is_unlit", false)),
		})
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
## `is_distant_tile` (issue #56): true for a placement whose REFR carries
## the XSRF/XSRD "distant skyline stand-in" marker (see
## ReferencePlacement::has_xsrf_or_xsrd's own doc comment,
## native/src/esm/esm_types.h) -- the caller reads that flag off the
## placement dict (`placement.get("has_xsrf_or_xsrd", false)`)
## since this function only ever sees a bare model_path, not the full
## placement. Gets a begin-only near-fade cutoff instead of the ordinary
## LOD0/LOD1 crossover.
func populate_mesh_children(parent: Node3D, nif: NifReader, model_path: String, geometry: Dictionary = {}, is_distant_tile: bool = false) -> void:
	if geometry.is_empty():
		geometry = build_geometry_entries(resolve_raw_geometry(nif, model_path))
	var lod_entries: Array = geometry.get("lod_mesh_entries", [])
	for entry in geometry["mesh_entries"]:
		var mi := MeshInstance3D.new()
		# entry["submesh_index"], not a loop counter -- a skipped submesh
		# (EditorMarker etc, see resolve_raw_geometry()'s own doc comment
		# on "submesh_index") would otherwise silently relabel every
		# following entry. Purely cosmetic here (no owning_node_index
		# lookup on the Static path), but a wrong label is still a real
		# debugging trap -- confirmed the hard way on the Dynamic path.
		mi.name = "sub%d" % int(entry["submesh_index"])
		mi.mesh = entry["mesh"]
		mi.transform = entry["transform"]
		mi.set_meta("gamebryo_is_unlit", bool(entry.get("is_unlit", false)))
		mi.set_meta("gamebryo_model_path", model_path)
		mi.set_meta("gamebryo_texture_path", String(entry.get("texture_path", "")))
		if is_distant_tile:
			_apply_distant_lod_visibility_range(mi)
		elif not lod_entries.is_empty():
			_apply_lod_visibility_range(mi, true)
		parent.add_child(mi)
	var i := 0
	for entry in lod_entries:
		var mi := MeshInstance3D.new()
		mi.name = "lod%d" % i
		mi.mesh = entry["mesh"]
		mi.set_meta("gamebryo_is_unlit", bool(entry.get("is_unlit", false)))
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
	# A REAL, CONFIRMED bug lived here: this used to look up owning_node_index/
	# name via a loop COUNTER over geometry["mesh_entries"], assuming
	# position-in-array == the native NifReader submesh index. That's only
	# true when nothing upstream was ever skipped -- but resolve_raw_geometry()
	# skips EditorMarker submeshes (a real, common case), so any submesh
	# AFTER a skipped one silently got the WRONG owning node and name.
	# Confirmed against real data: IndDoorSmAnim01.NIF (a real DOOR model,
	# REPCONNTopToMidDoor among others) has an EditorMarker as submesh #2 —
	# its real doorframe (#3) was misattached under submesh #2's own
	# (EditorMarker's) owning node instead of its own, visibly misplacing
	# the frame relative to the door leaf/doorway. Fixed by using each
	# entry's own `submesh_index` (threaded through explicitly since
	# resolve_raw_geometry(), see that function's own doc comment) instead
	# of a counter.
	for entry in geometry["mesh_entries"]:
		var submesh_index: int = entry["submesh_index"]
		var owning: int = nif.get_submesh_owning_node_index(submesh_index)
		var mesh_parent: Node3D = built[owning] if owning >= 0 and owning < built.size() else parent
		var mi := MeshInstance3D.new()
		mi.name = ("sub%d_%s" % [submesh_index, nif.get_submesh_name(submesh_index)]).validate_node_name()
		mi.mesh = entry["mesh"]
		mi.set_meta("gamebryo_is_unlit", bool(entry.get("is_unlit", false)))
		mesh_parent.add_child(mi)

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

## Issue #46: builds a real Skeleton3D + per-submesh Skin/MeshInstance3D for
## a skinned NIF (BSDismemberSkinInstance/NiSkinInstance + NiSkinData +
## NiSkinPartition — see nif_types.h's own SkinData doc comment), as
## children of `parent`. Deliberately a SEPARATE construction path from
## populate_dynamic_children() above, not a reuse of it: that function
## builds one Node3D per NiAVObject for a pivot-animated RIGID hierarchy
## (doors, the animated-static case from issue #44) where each mesh follows
## its own owning node's transform; a skinned mesh instead needs exactly one
## Skeleton3D (shared across the body's several skinned submeshes — real
## data confirms this sharing matters: upperbody.nif's 6
## BSDismemberSkinInstances all reference the same 27-bone pool) plus a
## Skin + MeshInstance3D per submesh, with the mesh's own node transform
## left at IDENTITY (the vertex position ends up in Skeleton3D's local space
## purely via each vertex's bone weights * that bone's current pose * its
## bind pose — the same architecture real-time GPU skinning always uses,
## matching Godot's own Skin/Skeleton3D contract, which composes no
## additional "global-to-skin" factor into the live vertex calc beyond the
## per-bone bind pose already captured in SkinData::bone_bind_transforms).
##
## Bone hierarchy comes from this same NIF's own scene_nodes parent_index
## chain — same source populate_dynamic_children() uses — NOT assumed to
## always be a real chain: confirmed real that a body-part mesh like
## upperbody.nif stores every one of its skinned bones as a FLAT list, each
## parent_index == -1 (directly under the file's own root), not nested under
## each other at all — the real hierarchical "Bip01" chain lives in a
## separate shared skeleton.nif THIS function never loads (see
## populate_humanoid_skeleton() below, issue #52 chunk 4, for the real
## multi-file assembly that does). Each flat bone's own recorded transform is
## still its correct bind-pose position relative to this file's root, so the
## REST pose still renders correctly with no chain composition needed here.
## A small standalone skinned prop (e.g. a flag) DOES carry its own real
## nested hierarchy in the same file, since it has no external skeleton to
## depend on — this function makes no assumption either way, just follows
## whatever parent_index actually says.
##
## Returns null if the NIF has no skin data at all (the common case — only
## real humanoid/creature meshes populate this).
func populate_skeleton(parent: Node3D, nif: NifReader, model_path: String) -> Skeleton3D:
	var skin_entries: Array = nif.get_skin_data()
	if skin_entries.is_empty():
		return null

	var skeleton := _build_skeleton_from_scene_nodes(nif, model_path, skin_entries)
	parent.add_child(skeleton)

	var morphed_mesh_instances: Array = []
	_populate_skinned_mesh_instances(parent, skeleton, nif, model_path, morphed_mesh_instances)

	if not morphed_mesh_instances.is_empty():
		_populate_morph_animation_player(parent, morphed_mesh_instances)

	_populate_skeleton_animation_player(parent, nif, skeleton)

	return skeleton

## Attaches the skinned geometry from `nif` to an existing skeleton. This is
## deliberately format/rendering-oriented and has no knowledge of which ESM
## record or caller selected either asset.
func populate_skinned_geometry(parent: Node3D, skeleton: Skeleton3D, nif: NifReader, model_path: String, metadata: Dictionary = {}) -> void:
	if skeleton == null or nif == null or nif.get_skin_data().is_empty():
		return
	_populate_skinned_mesh_instances(parent, skeleton, nif, model_path, [], null, metadata)

## Issue #52 chunk 4: a "full humanoid assembly" (enginedocs/
## nv_class_hierarchy.md; the real ESM structure confirmed on issue #52's own
## chunk 2 gate) — unlike populate_skeleton()'s single self-contained file,
## a human NPC's skeleton and its body-part meshes are separate NIFs:
## Characters\_Male\Skeleton.NIF carries the real hierarchical "Bip01" bone
## tree and NO skin data of its own (confirmed against real data: 66 scene
## nodes, 0 skin entries, 2 root nodes — a real nested chain, not the flat
## per-file list populate_skeleton()'s own doc comment describes for a
## standalone body-part mesh); UpperBody.nif/LeftHand.nif/RightHand.nif each
## carry real BSDismemberSkinInstance data whose bone_names all resolve by
## name against skeleton.nif's own bones (confirmed: zero missing names
## across all 3 real files) — no numeric bone-index remapping needed, name
## lookup is enough, same as populate_skeleton()'s existing Skin-binding code
## already does.
##
## Deliberately does NOT wire a SkeletonAnimationPlayer (unlike
## populate_skeleton()): real human idle/movement animation comes from
## separate .kf NiControllerSequence files, not from skeleton.nif itself —
## out of scope for this issue (see the issue #52 artifact's own chunk list;
## to be split into its own issue once chunk 5 lands, same as #47 split off
## #46).
##
## Returns null if skeleton_model_path fails to load.
func populate_humanoid_skeleton(parent: Node3D, skeleton_model_path: String, body_part_model_paths: Array, head_part_specs: Array = [], face_gen: FaceGenData = null) -> Skeleton3D:
	var skeleton_nif := load_nif(skeleton_model_path)
	if skeleton_nif == null:
		return null

	# Empty skin_entries signals "no skin data to filter bones by — this IS
	# the skeleton, every scene node in it is a real bone" (see
	# _build_skeleton_from_scene_nodes()'s own doc comment).
	var skeleton := _build_skeleton_from_scene_nodes(skeleton_nif, skeleton_model_path, [])
	parent.add_child(skeleton)
	var facial_attachment := BoneAttachment3D.new()
	facial_attachment.name = "FacialHeadAssembly"
	var facial_bone := "HeadAnims" if skeleton.find_bone("HeadAnims") != -1 else "Bip01 Head"
	if skeleton.find_bone(facial_bone) == -1:
		push_error("populate_humanoid_skeleton: skeleton has no usable facial head bone")
		facial_attachment.queue_free()
		facial_attachment = null
	else:
		# Standalone Fallout head parts are authored in facial head space and
		# intentionally carry no skin weights. This attachment supplies only
		# the inherited head transform; TRI/EGM supplies deformation below.
		facial_attachment.bone_name = facial_bone
		skeleton.add_child(facial_attachment)

	var nude_body := Node3D.new()
	nude_body.name = "NudeBody"
	parent.add_child(nude_body)
	var morphed_mesh_instances: Array = []
	for part_spec in body_part_model_paths:
		var part_path := String(part_spec if part_spec is String else part_spec.get("model_path", ""))
		var part_nif := load_nif(part_path)
		if part_nif == null:
			push_error("populate_humanoid_skeleton: failed to load body part '%s'" % part_path)
			continue
		var metadata := {"gamebryo_nude_body": true, "gamebryo_nude_body_original_visible": true, "gamebryo_race_body_part_index": int(part_spec.get("race_part_index", -1))} if part_spec is Dictionary else {"gamebryo_nude_body": true, "gamebryo_nude_body_original_visible": true}
		_populate_skinned_mesh_instances(nude_body, skeleton, part_nif, part_path, morphed_mesh_instances, null, metadata)
	for part_spec in head_part_specs:
		var part_path := String(part_spec if part_spec is String else part_spec.get("model_path", ""))
		var part_type := String("" if part_spec is String else part_spec.get("part_type", ""))
		if part_path.is_empty():
			continue
		var part_nif := load_nif(String(part_path))
		if part_nif == null:
			push_error("populate_humanoid_skeleton: failed to load head part '%s'" % part_path)
			continue
		var part_model_path := String(part_path)
		if part_nif.get_skin_data().is_empty():
			if facial_attachment != null:
				_populate_head_part_meshes(facial_attachment, part_nif, part_model_path, part_type, face_gen)
		else:
			_populate_skinned_mesh_instances(parent, skeleton, part_nif, part_model_path, morphed_mesh_instances, face_gen)

	if not morphed_mesh_instances.is_empty():
		_populate_morph_animation_player(parent, morphed_mesh_instances)

	return skeleton

## Soft-load construction primitives. These deliberately expose the same
## operations used by populate_humanoid_skeleton(), but let an actor commit
## one authored NIF at a time and yield between commits on the main thread.
## They must still only be called on the main thread because they create
## Skeleton3D/Mesh/Material resources and scene nodes.
func begin_humanoid_skeleton(parent: Node3D, skeleton_model_path: String) -> Dictionary:
	var skeleton_nif := load_nif(skeleton_model_path)
	if skeleton_nif == null:
		return {}
	var skeleton := _build_skeleton_from_scene_nodes(skeleton_nif, skeleton_model_path, [])
	parent.add_child(skeleton)
	var facial_attachment := BoneAttachment3D.new()
	facial_attachment.name = "FacialHeadAssembly"
	var facial_bone := "HeadAnims" if skeleton.find_bone("HeadAnims") != -1 else "Bip01 Head"
	if skeleton.find_bone(facial_bone) == -1:
		push_error("begin_humanoid_skeleton: skeleton has no usable facial head bone")
		facial_attachment.free()
		facial_attachment = null
	else:
		facial_attachment.bone_name = facial_bone
		skeleton.add_child(facial_attachment)
	var nude_body := Node3D.new()
	nude_body.name = "NudeBody"
	parent.add_child(nude_body)
	return {"skeleton": skeleton, "facial_attachment": facial_attachment, "nude_body": nude_body}

func populate_humanoid_body_part(nude_body: Node3D, skeleton: Skeleton3D, part_spec: Variant, morphed_mesh_instances: Array) -> void:
	var part_path := String(part_spec if part_spec is String else part_spec.get("model_path", ""))
	var part_nif := load_nif(part_path)
	if part_nif == null:
		push_error("populate_humanoid_body_part: failed to load '%s'" % part_path)
		return
	var metadata := {"gamebryo_nude_body": true, "gamebryo_nude_body_original_visible": true, "gamebryo_race_body_part_index": int(part_spec.get("race_part_index", -1))} if part_spec is Dictionary else {"gamebryo_nude_body": true, "gamebryo_nude_body_original_visible": true}
	_populate_skinned_mesh_instances(nude_body, skeleton, part_nif, part_path, morphed_mesh_instances, null, metadata)

func populate_humanoid_head_part(parent: Node3D, skeleton: Skeleton3D, facial_attachment: Node3D, part_spec: Variant, morphed_mesh_instances: Array, face_gen: FaceGenData = null) -> void:
	var part_path := String(part_spec if part_spec is String else part_spec.get("model_path", ""))
	var part_type := String("" if part_spec is String else part_spec.get("part_type", ""))
	if part_path.is_empty():
		return
	var part_nif := load_nif(part_path)
	if part_nif == null:
		push_error("populate_humanoid_head_part: failed to load '%s'" % part_path)
		return
	if part_nif.get_skin_data().is_empty():
		if facial_attachment != null:
			_populate_head_part_meshes(facial_attachment, part_nif, part_path, part_type, face_gen)
	else:
		_populate_skinned_mesh_instances(parent, skeleton, part_nif, part_path, morphed_mesh_instances, face_gen)

func finish_humanoid_morphs(parent: Node3D, morphed_mesh_instances: Array) -> void:
	if not morphed_mesh_instances.is_empty():
		_populate_morph_animation_player(parent, morphed_mesh_instances)

## Shared bone-building pass for populate_skeleton() (a single self-contained
## skinned NIF) and populate_humanoid_skeleton() (issue #52 chunk 4: a
## separate shared skeleton.nif with no skin data of its own). Bone hierarchy
## comes from `nif`'s own scene_nodes parent_index chain — same source
## populate_dynamic_children() uses — NOT assumed to always be a real chain:
## confirmed real that a body-part mesh like upperbody.nif stores every one
## of its skinned bones as a FLAT list, each parent_index == -1, while a
## small standalone skinned prop (e.g. a flag) or a real skeleton.nif DOES
## carry a real nested hierarchy — this function makes no assumption either
## way, just follows whatever parent_index actually says.
##
## `skin_entries`: when non-empty, only bones any entry actually references
## (plus their ancestors, for hierarchy/rest-pose composition) become real
## Skeleton3D bones — populate_skeleton()'s existing behavior, unchanged.
## When EMPTY, every scene node becomes a bone — for a file confirmed to
## carry no skin data of its own (skeleton.nif), "which bones are needed"
## can't be derived from skin data at all; the file's own contents already
## ARE exactly the skeleton.
func _build_skeleton_from_scene_nodes(nif: NifReader, model_path: String, skin_entries: Array) -> Skeleton3D:
	var scene_node_entries: Array = nif.get_scene_nodes()
	var scene_index_by_name: Dictionary = {}
	for i in scene_node_entries.size():
		scene_index_by_name[String(scene_node_entries[i]["name"])] = i

	var needed: Dictionary = {} # scene_node index -> true
	if skin_entries.is_empty():
		for i in scene_node_entries.size():
			needed[i] = true
	else:
		# Union of every bone name any skin entry references, PLUS every one
		# of its ancestors — a bone's parent chain up to the NIF root
		# commonly includes real skeleton structure (e.g. "Bip01" itself)
		# that no individual skin entry lists as one of ITS OWN weighted
		# bones, but which must still exist in Skeleton3D for the
		# hierarchy/rest pose composition to be correct.
		for skin in skin_entries:
			for bone_name_v in skin["bone_names"]:
				var bone_name := String(bone_name_v)
				if not scene_index_by_name.has(bone_name):
					push_error("_build_skeleton_from_scene_nodes: bone '%s' not found in this NIF's own scene_nodes -- %s" % [bone_name, model_path])
					continue
				var idx: int = scene_index_by_name[bone_name]
				while idx != -1 and not needed.has(idx):
					needed[idx] = true
					idx = int(scene_node_entries[idx]["parent_index"])

	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton3D"

	# Same iterative "attach once its own parent is already placed" pass
	# populate_dynamic_children() uses for its own Node3D hierarchy above --
	# real NIFs always emit a parent block before its children, but this
	# still tolerates any order at no real cost (bounded by one skeleton's
	# own bone count).
	var bone_index_by_scene_index: Dictionary = {}
	var remaining: Array = needed.keys()
	var progressed := true
	while not remaining.is_empty() and progressed:
		progressed = false
		var still_remaining: Array = []
		for idx in remaining:
			var parent_index: int = int(scene_node_entries[idx]["parent_index"])
			if parent_index != -1 and not bone_index_by_scene_index.has(parent_index):
				still_remaining.append(idx)
				continue
			var raw_name: String = String(scene_node_entries[idx]["name"])
			# Real data (skeleton.nif, "all bones" mode): a non-weighted
			# marker/anim-note leaf node ("HeadAnims:0") carries a ':' in its
			# own Gamebryo name -- Skeleton3D.add_bone() hard-rejects ':' and
			# '/' outright. Sanitized here rather than skipped so descendants
			# (none in this real file, but not guaranteed for every future
			# one) stay attached; safe for skin-bind name lookups too since
			# no real skin data was ever found referencing such a name (see
			# _diag_humanoid_assembly.gd's "missing_in_skeleton_nif" check).
			var safe_name := raw_name.replace(":", "_").replace("/", "_")
			var bone_idx := skeleton.add_bone(safe_name if not safe_name.is_empty() else "Bone%d" % idx)
			skeleton.set_bone_rest(bone_idx, scene_node_entries[idx]["transform"])
			if parent_index != -1:
				skeleton.set_bone_parent(bone_idx, bone_index_by_scene_index[parent_index])
			bone_index_by_scene_index[idx] = bone_idx
			progressed = true
		remaining = still_remaining
	if not remaining.is_empty():
		push_error("_build_skeleton_from_scene_nodes: bone parent_index cycle in '%s' -- %d bone(s) left unattached" % [model_path, remaining.size()])

	# A REAL, CONFIRMED bug lived here: Skeleton3D's per-bone POSE (what
	# get_bone_global_pose()/GPU skinning actually use) does NOT default to
	# the REST transform set_bone_rest() above just wrote -- it silently
	# stays at its own zeroed-out default (world origin, identity) until
	# reset_bone_poses() is called at least once. Confirmed via direct
	# inspection (get_bone_rest() returned the correct varied translations
	# while get_bone_global_pose() returned (0,0,0) for every single bone,
	# even after letting real frames process) -- this, not a transform-math
	# error, was the actual cause of a skinned mesh rendering "scrunched
	# into a tube": every vertex, regardless of which bone(s) it's weighted
	# to, got pulled toward the same world-origin pose.
	skeleton.reset_bone_poses()

	return skeleton

## Builds a standalone Fallout head-part NIF in the facial head assembly.
## Mouth, teeth, tongue, eyes, and most hair meshes have no skin blocks: the
## authored relationship to the actor is the shared HeadAnims head-space
## transform, while facial movement comes from each part's own TRI file.
func _populate_head_part_meshes(parent: Node3D, nif: NifReader, model_path: String, part_type: String, face_gen: FaceGenData = null) -> void:
	var raw := resolve_raw_geometry(nif, model_path)
	for raw_entry in raw["mesh_entries"]:
		var hair_variant := _hair_variant_for_submesh(String(raw_entry.get("submesh_name", ""))) if part_type == "hair" else ""
		var mesh := _build_mesh_from_raw(raw_entry)
		var nif_morph: Dictionary = raw_entry.get("morph", {})
		if not nif_morph.is_empty():
			mesh = _apply_morph_targets(mesh, nif_morph)
		var mat := _build_material_from_raw(raw_entry)
		if mat != null:
			mesh.surface_set_material(0, mat)

		if face_gen != null:
			var basis := load_facegen_geometry(model_path, hair_variant)
			var face_mesh := _apply_facegen_geometry(mesh, basis, face_gen)
			if face_mesh != null:
				mesh = face_mesh
			else:
				face_gen.diagnostics.append("No compatible EGM basis for %s" % model_path)

		var tri_asset: TriReader = raw_entry.get("tri")
		if tri_asset != null:
			mesh = _apply_tri_morph_targets(mesh, tri_asset)

		var submesh_index := int(raw_entry["submesh_index"])
		var mi := MeshInstance3D.new()
		mi.name = ("sub%d_%s" % [submesh_index, nif.get_submesh_name(submesh_index)]).validate_node_name()
		mi.mesh = mesh
		# Exhaustive HAIR/Head census: most standalone hair NIFs carry the same
		# outer coordinate-system marker (-90 X, +/-180 Y). Hair is already
		# attached below the actor's HeadAnims bone, so applying that marker here
		# rotates it a second time. Other head parts retain their authored mesh
		# transform; this exception is specific to unskinned HAIR head-space.
		mi.transform = Transform3D.IDENTITY if part_type == "hair" else raw_entry["transform"]
		mi.set_meta("gamebryo_is_unlit", bool(raw_entry.get("is_unlit", false)))
		mi.set_meta("gamebryo_model_path", model_path)
		mi.set_meta("gamebryo_texture_path", String(raw_entry.get("texture_path", "")))
		mi.set_meta("gamebryo_head_part_type", part_type)
		if part_type == "hair":
			mi.set_meta("gamebryo_hair_variant", "no_hat" if hair_variant == "nohat" else hair_variant)
		parent.add_child(mi)

## Shared per-skin submesh loop for populate_skeleton() and
## populate_humanoid_skeleton(): builds one Skin + MeshInstance3D per skin
## entry `nif` carries, bound against the ALREADY-BUILT `skeleton` by bone
## NAME (Skin.set_bind_bone() via skeleton.find_bone()) — this is already
## skeleton-source-agnostic (it never assumes `skeleton` was built from
## `nif` itself), which is exactly what makes reusing it for a separate
## shared skeleton.nif (chunk 4) safe. Appends to `morphed_mesh_instances`
## (caller decides whether/when to flush it via
## _populate_morph_animation_player() — populate_humanoid_skeleton() flushes
## once after every body part, populate_skeleton() once after its own single
## file) rather than building it here, since a caller processing several
## files needs one shared player, not one per file.
func _populate_skinned_mesh_instances(parent: Node3D, skeleton: Skeleton3D, nif: NifReader, model_path: String, morphed_mesh_instances: Array, face_gen: FaceGenData = null, extra_metadata: Dictionary = {}) -> void:
	var skin_entries: Array = nif.get_skin_data()
	if skin_entries.is_empty():
		return

	var submesh_index_by_name: Dictionary = {}
	for i in nif.get_submesh_count():
		submesh_index_by_name[nif.get_submesh_name(i)] = i

	var raw := resolve_raw_geometry(nif, model_path)
	var raw_entry_by_submesh_index: Dictionary = {}
	for e in raw["mesh_entries"]:
		raw_entry_by_submesh_index[int(e["submesh_index"])] = e

	for skin in skin_entries:
		var target_name: String = skin["target_node_name"]
		if not submesh_index_by_name.has(target_name):
			push_error("_populate_skinned_mesh_instances: skin target submesh '%s' not found -- %s" % [target_name, model_path])
			continue
		var submesh_index: int = submesh_index_by_name[target_name]
		if not raw_entry_by_submesh_index.has(submesh_index):
			continue # filtered upstream (e.g. an EditorMarker submesh) -- not expected for a real skinned shape, but not fatal
		var raw_entry: Dictionary = raw_entry_by_submesh_index[submesh_index]

		var mesh_key := "%s#%d#skin" % [model_path, submesh_index]
		var mesh: ArrayMesh
		if _skin_mesh_cache.has(mesh_key):
			mesh = _skin_mesh_cache[mesh_key]
		else:
			mesh = _build_skinned_mesh_from_raw(raw_entry, skin)
			var morph: Dictionary = raw_entry.get("morph", {})
			if not morph.is_empty():
				mesh = _apply_morph_targets(mesh, morph)
			var mat := _build_material_from_raw(raw_entry)
			if mat != null:
				mesh.surface_set_material(0, mat)
			_skin_mesh_cache[mesh_key] = mesh
		if face_gen != null and _is_head_part_model(model_path):
			var basis := load_facegen_geometry(model_path)
			var face_mesh := _apply_facegen_geometry(mesh, basis, face_gen)
			if face_mesh != null:
				mesh = face_mesh
				face_gen.geometry_asset_path = basis.source_path
				face_gen.geometry_applied = true
				face_gen.geometry_applied_vertex_count = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
				face_gen.geometry_applied_mode_count = basis.symmetric_mode_count + basis.asymmetric_mode_count
			elif basis == null:
				face_gen.diagnostics.append("No validated EGM basis for %s" % model_path)

		# TRI animation deltas are applied after the NPC-specific EGM shape.
		# Never put this result in _skin_mesh_cache: the same head asset is
		# reused by NPCs with different static FaceGen geometry.
		var tri_asset: TriReader = raw_entry.get("tri")
		if tri_asset != null and _is_head_part_model(model_path):
			var with_tri := _apply_tri_morph_targets(mesh, tri_asset)
			if with_tri != null:
				mesh = with_tri

		var mi := MeshInstance3D.new()
		mi.name = ("sub%d_%s" % [submesh_index, target_name]).validate_node_name()
		mi.mesh = mesh
		mi.set_meta("gamebryo_is_unlit", bool(raw_entry.get("is_unlit", false)))
		mi.set_meta("gamebryo_model_path", model_path)
		mi.set_meta("gamebryo_texture_path", String(raw_entry.get("texture_path", "")))
		for metadata_key in extra_metadata:
			mi.set_meta(String(metadata_key), extra_metadata[metadata_key])
		parent.add_child(mi)
		mi.skeleton = mi.get_path_to(skeleton) # MeshInstance3D.skeleton is relative to the MeshInstance3D itself, not `parent`

		var skin_resource := Skin.new()
		var bone_names: Array = skin["bone_names"]
		var bind_transforms: Array = skin["bone_bind_transforms"]
		skin_resource.set_bind_count(bone_names.size())
		for i in bone_names.size():
			skin_resource.set_bind_bone(i, skeleton.find_bone(String(bone_names[i])))
			skin_resource.set_bind_pose(i, bind_transforms[i])
		mi.skin = skin_resource

		var morph_for_anim: Dictionary = raw_entry.get("morph", {})
		if not morph_for_anim.get("weight_tracks", []).is_empty():
			morphed_mesh_instances.append({ "mesh_instance": mi, "morph": morph_for_anim })

## Adds the gender-selected, skin-backed equipment models to the actor's
## existing skeleton. Armor records are deliberately supplied by the caller;
## this method never interprets NPC_.CNTO as worn equipment.
func populate_equipment(parent: Node3D, skeleton: Skeleton3D, state, female: bool) -> Array[String]:
	var diagnostics: Array[String] = []
	if state == null:
		return diagnostics
	var armor_list: Array = state.get_armor_bases() if state is EsmActorEquipmentState else state.armor_records
	var accepted: Array = []
	var occupied := 0
	# The exported list is low -> high priority, so resolve conflicts from the
	# high end and render accepted records in authored order.
	for i in range(armor_list.size() - 1, -1, -1):
		var armor = armor_list[i]
		if armor == null:
			continue
		if armor.biped_flags != 0 and (armor.biped_flags & occupied) != 0:
			diagnostics.append("Skipped overlapping armor %s (%08X)" % [armor.editor_id, armor.biped_flags])
			continue
		accepted.push_front(armor)
		occupied |= armor.biped_flags
	var morphed: Array = []
	for armor in accepted:
		var paths: Array[Dictionary] = []
		var direct: String = armor.female_biped_model if female else armor.male_biped_model
		if not direct.is_empty():
			paths.append({"path": direct, "source": armor, "field": "MOD3" if female else "MODL"})
		if armor.biped_model_list != null:
			for addon in armor.biped_model_list.entries:
				if addon == null:
					continue
				var addon_path: String = addon.female_biped_model if female else addon.male_biped_model
				if not addon_path.is_empty():
					paths.append({"path": addon_path, "source": addon, "field": "MOD3" if female else "MODL"})
		for model in paths:
			var equipment_model_path := String(model.path)
			var nif_cache_hit := _nif_cache.has(equipment_model_path)
			var nif_load_start_usec := Time.get_ticks_usec()
			var equipment_nif := load_nif(equipment_model_path)
			_print_equipment_timing("nif_cache_%s" % ("hit" if nif_cache_hit else "miss"), equipment_model_path, nif_load_start_usec)
			if equipment_nif == null:
				diagnostics.append("Equipment NIF not found: %s" % model.path)
				continue
			var geometry_build_start_usec := Time.get_ticks_usec()
			if equipment_nif.get_skin_data().is_empty():
				if not _populate_unskinned_equipment(parent, skeleton, equipment_nif, String(model.path), model.source, model.field):
					diagnostics.append("Skipped unskinned armor model with no supported attachment bone: %s" % model.path)
				_print_equipment_timing("geometry_node_build", equipment_model_path, geometry_build_start_usec)
				continue
			_populate_skinned_mesh_instances(parent, skeleton, equipment_nif, String(model.path), morphed, null, {
				"gamebryo_equipment": true,
				"gamebryo_equipment_form_id": model.source.form_id,
				"gamebryo_equipment_biped_flags": model.source.biped_flags,
				"gamebryo_equipment_model_field": model.field
			})
			_print_equipment_timing("geometry_node_build", equipment_model_path, geometry_build_start_usec)
	var equipped_weapon: WeaponBase = state.get_weapon_base() if state is EsmActorEquipmentState else state.weapon
	if equipped_weapon != null:
		var weapon_models: Array[Dictionary] = []
		# WEAP.BIPL is the authored biped/equipped model collection. MODL is
		# retained as the fallback used by ordinary weapons without BIPL.
		if equipped_weapon.biped_model_list != null:
			for addon in equipped_weapon.biped_model_list.entries:
				if addon == null:
					continue
				var addon_path: String = addon.female_biped_model if female else addon.male_biped_model
				if not addon_path.is_empty():
					weapon_models.append({"path": addon_path, "source": addon, "field": "BIPL"})
		if weapon_models.is_empty() and not equipped_weapon.model_path.is_empty():
			weapon_models.append({"path": equipped_weapon.model_path, "source": equipped_weapon, "field": "MODL"})
		for model in weapon_models:
			var weapon_model_path := String(model.path)
			var nif_cache_hit := _nif_cache.has(weapon_model_path)
			var nif_load_start_usec := Time.get_ticks_usec()
			var weapon_nif := load_nif(weapon_model_path)
			_print_equipment_timing("nif_cache_%s" % ("hit" if nif_cache_hit else "miss"), weapon_model_path, nif_load_start_usec)
			if weapon_nif == null:
				diagnostics.append("Weapon NIF not found: %s" % model.path)
				continue
			var geometry_build_start_usec := Time.get_ticks_usec()
			if not _populate_weapon_model(parent, skeleton, weapon_nif, String(model.path), model.source, String(model.field), equipped_weapon):
				diagnostics.append("Skipped weapon model with no supported attachment: %s" % model.path)
			_print_equipment_timing("geometry_node_build", weapon_model_path, geometry_build_start_usec)
	return diagnostics

func _print_equipment_timing(stage: String, model_path: String, start_usec: int) -> void:
	var elapsed_ms := float(Time.get_ticks_usec() - start_usec) / 1000.0
	print("GamebryoMeshResolver timing [%s] %s: %.2f ms" % [stage, model_path, elapsed_ms])

## Adds one authored equipped weapon model to the actor's shared skeleton.
## Skin-backed BIPL models retain their own bone names and bind poses; plain
## MODL/BIPL models follow the authored Weapon bone (with a compatibility
## fallback for skeleton variants without that node) while retaining every
## transform authored in the NIF.
func _populate_weapon_model(parent: Node3D, skeleton: Skeleton3D, nif: NifReader, model_path: String, source: EsmBase, model_field: String, weapon = null) -> bool:
	var metadata := {
		"gamebryo_equipment": true,
		"gamebryo_equipment_form_id": source.form_id,
		"gamebryo_equipment_model_field": model_field,
		"gamebryo_weapon": true,
		"gamebryo_weapon_model_path": model_path,
	}
	if not nif.get_skin_data().is_empty():
		_populate_skinned_mesh_instances(parent, skeleton, nif, model_path, [], null, metadata)
		return true
	var hand := BoneAttachment3D.new()
	hand.name = ("WeaponAttachment_" + model_path.get_file().get_basename()).validate_node_name()
	for candidate in ["Weapon", "Bip01 R Hand", "Bip01 R Forearm", "Bip01 Spine"]:
		if skeleton.find_bone(candidate) != -1:
			hand.bone_name = candidate
			break
	if hand.bone_name.is_empty():
		return false
	parent.add_child(hand)
	_bind_external_equipment_attachment(hand, skeleton)
	var built := populate_dynamic_children(hand, nif, model_path)
	# Weapon NIF Havok collision is authored for the inventory/world item, not
	# for an equipped visual attached to an actor. Remove it after the generic
	# NIF construction has handed the completed hierarchy over; this keeps the
	# generic resolver's collision behavior intact for every other object type.
	for collision_body in hand.find_children("*", "GamebryoCollisionBody", true, false):
		collision_body.free()
	var local_player := populate_direct_controller_player(hand, nif, built)
	if local_player != null and local_player.has_animation("embedded"):
		local_player.play("embedded")
	for child in hand.find_children("*", "MeshInstance3D", true, false):
		for metadata_key in metadata:
			child.set_meta(String(metadata_key), metadata[metadata_key])
	return true

## Wearable accessories such as Characters\\Hair\\Shades.NIF are authored in
## head space and intentionally have no skin blocks. Keep them in Equipment,
## but bind their attachment to the actor's existing head bone rather than
## treating them as a static world mesh.
func _populate_unskinned_equipment(parent: Node3D, skeleton: Skeleton3D, nif: NifReader, model_path: String, source: EsmBase, model_field: String) -> bool:
	var normalized := model_path.to_lower().replace("/", "\\")
	var head_accessory := normalized.contains("\\hair\\") or normalized.contains("\\head\\") or normalized.contains("shades") or normalized.contains("glasses") or normalized.contains("hat")
	if not head_accessory:
		return false
	var attachment := BoneAttachment3D.new()
	attachment.name = ("Accessory_" + model_path.get_file().get_basename()).validate_node_name()
	for candidate in ["HeadAnims", "Bip01 Head"]:
		if skeleton.find_bone(candidate) != -1:
			attachment.bone_name = candidate
			break
	if attachment.bone_name.is_empty():
		return false
	parent.add_child(attachment)
	_bind_external_equipment_attachment(attachment, skeleton)
	populate_mesh_children(attachment, nif, model_path)
	for child in attachment.find_children("*", "MeshInstance3D", true, false):
		child.set_meta("gamebryo_equipment", true)
		child.set_meta("gamebryo_equipment_form_id", source.form_id)
		child.set_meta("gamebryo_equipment_biped_flags", source.biped_flags)
		child.set_meta("gamebryo_equipment_model_field", model_field)
	return true

func _bind_external_equipment_attachment(attachment: BoneAttachment3D, skeleton: Skeleton3D) -> void:
	# Adding a child to an in-tree Equipment node immediately enters it into
	# the scene tree. Configure the external skeleton first, then explicitly
	# resolve the bone index; otherwise BoneAttachment3D briefly sees
	# Equipment (not Skeleton3D) as its parent and remains unbound.
	attachment.use_external_skeleton = true
	attachment.external_skeleton = attachment.get_path_to(skeleton)
	attachment.bone_idx = skeleton.find_bone(attachment.bone_name)
	attachment.on_skeleton_update()

func _apply_facegen_geometry(base_mesh: ArrayMesh, basis: FaceGenGeometryAsset, face_gen: FaceGenData) -> ArrayMesh:
	if basis == null or face_gen == null or basis.vertex_count <= 0:
		return null
	var arrays := base_mesh.surface_get_arrays(0)
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if positions.is_empty() or positions.size() > basis.vertex_count:
		return null
	var result_positions := positions.duplicate()
	var apply_modes := func(modes: Array, coefficients: PackedFloat32Array) -> void:
		var count: int = mini(modes.size(), coefficients.size())
		for mode_index in count:
			var deltas: PackedFloat32Array = modes[mode_index]
			if deltas.size() < positions.size() * 3 or not is_finite(coefficients[mode_index]):
				continue
			var coefficient := coefficients[mode_index]
			for vertex_index in positions.size():
				result_positions[vertex_index] += Vector3(deltas[vertex_index * 3], deltas[vertex_index * 3 + 1], deltas[vertex_index * 3 + 2]) * coefficient
	apply_modes.call(basis.symmetric_basis, face_gen.fggs_values)
	apply_modes.call(basis.asymmetric_basis, face_gen.fgga_values)
	arrays[Mesh.ARRAY_VERTEX] = result_positions
	var result := ArrayMesh.new()
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	result.surface_set_material(0, base_mesh.surface_get_material(0))
	return result

## Adds the validated labelled TRI delta morphs to a head surface. TRI's
## statistical morphs remain available through TriReader but are intentionally
## not converted to blend shapes until their EGM relationship is verified.
func _apply_tri_morph_targets(base_mesh: ArrayMesh, tri: TriReader) -> ArrayMesh:
	var arrays := base_mesh.surface_get_arrays(0)
	var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if positions.size() != tri.get_vertex_count():
		push_warning("_apply_tri_morph_targets: TRI/head vertex mismatch (%d vs %d)" % [tri.get_vertex_count(), positions.size()])
		return base_mesh
	var valid: Array = []
	var seen_names := {}
	for i in tri.get_delta_morph_count():
		var deltas := tri.get_delta_morph_deltas(i)
		var morph_name := tri.get_delta_morph_name(i)
		if morph_name.is_empty() or seen_names.has(morph_name) or deltas.size() != positions.size() * 3:
			push_warning("_apply_tri_morph_targets: skipping malformed morph '%s'" % tri.get_delta_morph_name(i))
			continue
		seen_names[morph_name] = true
		valid.append({"name": morph_name, "deltas": deltas})
	if valid.is_empty():
		return base_mesh
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
	var mesh := ArrayMesh.new()
	mesh.blend_shape_mode = Mesh.BLEND_SHAPE_MODE_NORMALIZED
	var blend_arrays: Array = []
	for item in valid:
		var name := String(item["name"])
		mesh.add_blend_shape(name)
		var deltas: PackedFloat32Array = item["deltas"]
		var target := PackedVector3Array()
		target.resize(positions.size())
		for v in positions.size():
			target[v] = positions[v] + Vector3(deltas[v * 3], deltas[v * 3 + 1], deltas[v * 3 + 2])
		var blend := []; blend.resize(Mesh.ARRAY_MAX)
		blend[Mesh.ARRAY_VERTEX] = target
		if not normals.is_empty():
			blend[Mesh.ARRAY_NORMAL] = normals
		blend_arrays.append(blend)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, blend_arrays)
	mesh.surface_set_material(0, base_mesh.surface_get_material(0))
	return mesh

## Same base-array construction as _build_mesh_from_raw(), plus
## Mesh.ARRAY_BONES/ARRAY_WEIGHTS from the matching SkinData dict (see
## NifReader.get_skin_data()'s own doc comment for the flattened
## vertex_count*4 layout — already exactly the shape Godot's own ArrayMesh
## expects, no remapping needed). A distinct function rather than an extra
## parameter on _build_mesh_from_raw() so that function's own (shared,
## Static-path-cached) contract never silently gains skin-shaped output.
func _build_skinned_mesh_from_raw(e: Dictionary, skin: Dictionary) -> ArrayMesh:
	var base := _build_mesh_from_raw(e)
	var pos_flat: PackedFloat32Array = e["positions"]
	var vert_count := pos_flat.size() / 3
	var bone_indices: PackedInt32Array = skin["bone_indices"]
	var bone_weights: PackedFloat32Array = skin["bone_weights"]
	if bone_indices.size() != vert_count * 4 or bone_weights.size() != vert_count * 4:
		push_error("_build_skinned_mesh_from_raw: bone array size mismatch (verts=%d bone_indices=%d)" % [vert_count, bone_indices.size()])
		return base

	var arrays := base.surface_get_arrays(0)
	arrays[Mesh.ARRAY_BONES] = bone_indices
	arrays[Mesh.ARRAY_WEIGHTS] = bone_weights

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

## Issue #47: rebuilds `base_mesh` with real Godot blend shapes added, one
## per NifReader.get_morph_data() "targets" entry — see nif_types.h's own
## MorphTarget doc comment for why index 0 (the base shape's own copy, not
## a real target) is skipped. `morph["targets"][i]["vertex_deltas"]` are
## per-vertex OFFSETS (NiMorphData's own convention, confirmed real:
## relative_targets == true in every file sampled); Godot's own
## BLEND_SHAPE_MODE_NORMALIZED (the default, set explicitly here since a
## fresh ArrayMesh's default mode isn't assumed) expects each blend shape's
## ARRAY_VERTEX to be the target's ABSOLUTE position, so base + delta is
## computed here once at mesh-build time rather than deferred to the shader.
##
## Godot requires every add_blend_shape() call before the surface that
## references them is added (blend shape COUNT is fixed at surface-add
## time) — same reason _build_skinned_mesh_from_raw() above rebuilds a
## fresh ArrayMesh via surface_get_arrays() rather than mutating
## `base_mesh` in place; ARRAY_BONES/ARRAY_WEIGHTS already on `base_mesh`
## (a skinned+morphed submesh, the real motivating case — the Nevada flag
## carries both) pass through unchanged via that same surface_get_arrays()
## call, so a skinned mesh keeps its skinning after this runs.
func _apply_morph_targets(base_mesh: ArrayMesh, morph: Dictionary) -> ArrayMesh:
	var targets: Array = morph.get("targets", [])
	if targets.size() <= 1:
		return base_mesh # only (or not even) the base-copy entry -- nothing to blend

	var arrays := base_mesh.surface_get_arrays(0)
	var base_positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	# Godot requires a blend shape's Vertex/Normal/Tangent arrays to match
	# the main surface's own format -- NIF's NiMorphData only ever gives us
	# per-vertex POSITION deltas, never per-morph normals, so every blend
	# shape reuses the base mesh's own normals unchanged (a real, if minor,
	# fidelity approximation for a mesh whose morph deltas are small ripples
	# -- not incorrect for anything sharper, just not re-derived per morph).
	var base_normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()

	var blend_arrays: Array = []
	var mesh := ArrayMesh.new()
	mesh.blend_shape_mode = Mesh.BLEND_SHAPE_MODE_NORMALIZED
	for i in targets.size():
		if i == 0:
			continue
		var target: Dictionary = targets[i]
		var target_name: String = String(target.get("name", ""))
		mesh.add_blend_shape(target_name if target_name != "" else "Morph%d" % i)

		var deltas: PackedFloat32Array = target["vertex_deltas"]
		if deltas.size() != base_positions.size() * 3:
			push_error("_apply_morph_targets: vertex_deltas size mismatch for '%s' (verts=%d deltas=%d)" % [target_name, base_positions.size(), deltas.size()])
			continue
		var target_positions := PackedVector3Array()
		target_positions.resize(base_positions.size())
		for v in base_positions.size():
			target_positions[v] = base_positions[v] + Vector3(deltas[v * 3], deltas[v * 3 + 1], deltas[v * 3 + 2])

		var blend_surface := []
		blend_surface.resize(Mesh.ARRAY_MAX)
		blend_surface[Mesh.ARRAY_VERTEX] = target_positions
		if not base_normals.is_empty():
			blend_surface[Mesh.ARRAY_NORMAL] = base_normals
		blend_arrays.append(blend_surface)

	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, blend_arrays)
	return mesh

## Issue #47: real weight-animation playback for morph targets -- e.g. the
## Nevada flag's own cloth ripple. `entries` is an Array of
## { "mesh_instance": MeshInstance3D, "morph": Dictionary (NifReader.
## get_morph_data() entry) }, built by populate_skeleton() from the shapes
## it just constructed. A NiGeomMorpherController's own clock
## (morph["start_time"]/"stop_time"/"cycle_type") is a genuinely separate
## timeline from get_animation_sequences()'s own NiControllerSequence-based
## one (see nif_types.h's MorphData doc comment) -- this builds its own
## AnimationPlayer/library rather than folding into
## populate_animation_player()'s, and uses the FIRST entry's own
## start/stop/cycle as the built clip's length/loop mode (confirmed real
## that every morph controller on the one real sample checked shares the
## same file-wide timeline, not assumed in general).
func _populate_morph_animation_player(parent: Node3D, entries: Array) -> AnimationPlayer:
	var player := AnimationPlayer.new()
	player.name = "MorphAnimationPlayer"
	parent.add_child(player)
	player.root_node = NodePath("..") # `parent` itself -- same convention as populate_animation_player()'s own; every NodePath below is parent.get_path_to(...)

	var first_morph: Dictionary = entries[0]["morph"]
	var anim := Animation.new()
	anim.length = maxf(float(first_morph["stop_time"]) - float(first_morph["start_time"]), 0.01)
	match int(first_morph["cycle_type"]): # nif::SequenceCycleType: 0=loop, 1=reverse, 2=clamp
		0: anim.loop_mode = Animation.LOOP_LINEAR
		_: anim.loop_mode = Animation.LOOP_NONE # reverse/clamp both play once and hold -- same known gap as populate_animation_player()'s own reverse handling

	for entry in entries:
		var mi: MeshInstance3D = entry["mesh_instance"]
		var morph: Dictionary = entry["morph"]
		var mesh: ArrayMesh = mi.mesh
		var blend_shape_index_by_name: Dictionary = {}
		for i in mesh.get_blend_shape_count():
			blend_shape_index_by_name[mesh.get_blend_shape_name(i)] = i

		for track in morph["weight_tracks"]:
			var target_name: String = track["target_name"]
			if not blend_shape_index_by_name.has(target_name):
				continue # e.g. the always-zero "Base" weight track -- index 0 was never built as a real blend shape, see _apply_morph_targets()'s own doc comment
			var idx := anim.add_track(Animation.TYPE_BLEND_SHAPE)
			# TYPE_BLEND_SHAPE uses MeshInstance3D's `blend_shapes/<name>` property path --
			# same parent-relative NodePath convention populate_animation_player() uses.
			anim.track_set_path(idx, NodePath(str(parent.get_path_to(mi)) + ":blend_shapes/" + target_name))
			var keys: Array = track["keys"]
			# Deliberately always LINEAR here, NOT _godot_interp()'s own
			# quadratic/tbc->CUBIC mapping (populate_animation_player() uses
			# that for smooth positional/rotational curves, where it's a
			# reasonable fit) -- confirmed a real, bad mismatch for THIS kind
			# of data: these weight curves are dense, near-spike keyframes
			# (a value snapping to 1.0 for a single frame between long runs
			# of 0.0, real key counts of 98-223 per track), and Godot's
			# CUBIC auto-derives tangents from neighboring keys, which on a
			# spike shape overshoots wildly -- measured a sampled weight of
			# -18.79 (should be in 0..1) with CUBIC before this fix.
			anim.track_set_interpolation_type(idx, Animation.INTERPOLATION_LINEAR)
			for k in keys:
				anim.track_insert_key(idx, float(k["time"]), float(k["value"]))

	var library := AnimationLibrary.new()
	library.add_animation("Morph", anim)
	player.add_animation_library("", library)
	return player

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
	# Real NIF-authored playback speed reads slightly slow in practice
	# (user observation, real play) -- a flat 25% speedup, not a re-timed
	# curve; cheap, reversible, and correct in the specific dimension that
	# was actually flagged as off (nothing about direction/axis/keyframe
	# values was wrong, see phases/3/00-door-completion.md step 6/8).
	player.speed_scale = 1.25

	var resolve_target := func(target_name: String):
		if not name_to_index.has(target_name):
			return null # target isn't one of THIS NIF's own scene_nodes -- a real, if unexpected, case; skip rather than crash
		return parent.get_path_to(built[name_to_index[target_name]])

	var library := AnimationLibrary.new()
	for seq in sequences:
		library.add_animation(String(seq["name"]), _build_sequence_animation(seq, resolve_target))
	player.add_animation_library("", library)
	return player

## Builds the local animation layer for controllers attached directly to NIF
## nodes (rather than to a NiControllerManager sequence). This is used by
## weapon NIFs whose clips, slides, hammers, and shell nodes have their own
## NiTransformController/NiVisController chains.
func populate_direct_controller_player(parent: Node3D, nif: NifReader, built: Array) -> AnimationPlayer:
	var controllers: Array = nif.get_direct_animation_controllers()
	if controllers.is_empty() or built.is_empty():
		return null
	var player := AnimationPlayer.new()
	player.name = "DirectControllerAnimationPlayer"
	parent.add_child(player)
	player.root_node = NodePath("..")
	var animation := Animation.new()
	var length := 0.01
	for controller in controllers:
		length = maxf(length, float(controller.get("stop_time", 0.0)))
		var target_index := int(controller.get("target_node_index", -1))
		if target_index < 0 or target_index >= built.size():
			continue
		var target: Node3D = built[target_index]
		var target_path := parent.get_path_to(target)
		for track_data in controller.get("transform_tracks", []):
			var track_anim := _build_sequence_animation({
				"cycle_type": 0,
				"start_time": controller.get("start_time", 0.0),
				"stop_time": controller.get("stop_time", 0.0),
				"tracks": [track_data]
			}, func(_name: String): return target_path)
			for i in track_anim.get_track_count():
				var source_type := track_anim.track_get_type(i)
				var destination := animation.add_track(source_type)
				animation.track_set_path(destination, track_anim.track_get_path(i))
				animation.track_set_interpolation_type(destination, track_anim.track_get_interpolation_type(i))
				for key in track_anim.track_get_key_count(i):
					animation.track_insert_key(destination, track_anim.track_get_key_time(i, key), track_anim.track_get_key_value(i, key))
		for visibility in controller.get("visibility_keys", []):
			var visibility_track := animation.add_track(Animation.TYPE_VALUE)
			animation.track_set_path(visibility_track, NodePath(str(target_path) + ":visible"))
			animation.track_set_interpolation_type(visibility_track, Animation.INTERPOLATION_NEAREST)
			animation.track_insert_key(visibility_track, float(visibility["time"]), bool(visibility["value"]))
	if animation.get_track_count() == 0:
		player.queue_free()
		return null
	animation.length = length
	var library := AnimationLibrary.new()
	library.add_animation("embedded", animation)
	player.add_animation_library("", library)
	return player

## Loads standalone KF clips against an arbitrary NIF node hierarchy. This
## targets named local nodes instead of Skeleton3D bones, allowing a KF to
## animate weapon mechanisms when the authored clip names those nodes.
func populate_external_node_animations(parent: Node3D, built: Array, clips: Dictionary, existing_player: AnimationPlayer = null) -> AnimationPlayer:
	if built.is_empty() or clips.is_empty():
		return existing_player
	var name_to_node: Dictionary = {}
	for node in built:
		if node != null and not name_to_node.has(String(node.name)):
			name_to_node[String(node.name)] = node
	var library := existing_player.get_animation_library("") if existing_player != null else AnimationLibrary.new()
	var resolve_target := func(target_name: String):
		if not name_to_node.has(target_name):
			return null
		return parent.get_path_to(name_to_node[target_name])
	for clip_name in clips:
		if library.has_animation(String(clip_name)):
			continue
		var kf_nif := load_nif(String(clips[clip_name]))
		if kf_nif == null:
			continue
		var sequences: Array = kf_nif.get_animation_sequences()
		if sequences.is_empty():
			continue
		var anim := _build_sequence_animation(sequences[0], resolve_target)
		if anim.get_track_count() > 0:
			library.add_animation(String(clip_name), anim)
	if library.get_animation_list().is_empty():
		return existing_player
	if existing_player != null:
		return existing_player
	var player := AnimationPlayer.new()
	player.name = "WeaponAnimationPlayer"
	parent.add_child(player)
	player.root_node = NodePath("..")
	player.add_animation_library("", library)
	return player

## Issue #46 follow-up, surfaced by real play on the Nevada flag (#47's own
## test asset): a skinned NIF's bones can ALSO carry ordinary keyframed
## rotation/translation/scale animation via the SAME NiControllerSequence
## mechanism doors use (get_animation_sequences()) — confirmed real: the
## flag's own "Idle" sequence has 9 quaternion-rotation tracks targeting its
## exact bone names (TTail1, MTail1, ...), ~1270 keys each. This is NOT
## Havok cloth physics (an earlier, wrong assumption made before actually
## checking get_animation_sequences() against this file) — ordinary
## transform-track animation, already fully supported by
## get_animation_sequences()/_build_sequence_animation(), just never wired
## to a Skeleton3D's own bones until now. Godot resolves a Skeleton3D bone
## track via the same "<path>:<property>" NodePath convention as any other
## property track, using the bone's own name as the property (the
## "Skeleton3D:BoneName" convention Godot's own glTF/FBX importers use) —
## same pattern as _populate_morph_animation_player()'s own blend-shape-
## weight tracks. Called from populate_skeleton() itself; returns null if
## the NIF has no animation sequences, or none of them target a real bone
## on `skeleton` (e.g. a skinned mesh with no authored pose animation at
## all, the common case).
func _populate_skeleton_animation_player(parent: Node3D, nif: NifReader, skeleton: Skeleton3D) -> AnimationPlayer:
	var sequences: Array = nif.get_animation_sequences()
	if sequences.is_empty():
		return null

	var skeleton_path: NodePath = parent.get_path_to(skeleton)
	var resolve_bone := func(target_name: String):
		if skeleton.find_bone(target_name) == -1:
			return null
		return NodePath(str(skeleton_path) + ":" + target_name)

	var library := AnimationLibrary.new()
	for seq in sequences:
		var anim := _build_sequence_animation(seq, resolve_bone, skeleton)
		if anim.get_track_count() > 0:
			library.add_animation(String(seq["name"]), anim)
	if library.get_animation_list().is_empty():
		return null # no sequence in this file targets any of `skeleton`'s own bones

	var player := AnimationPlayer.new()
	player.name = "SkeletonAnimationPlayer"
	parent.add_child(player)
	player.root_node = NodePath("..")
	player.speed_scale = 1.25 # same real-play-observed correction populate_animation_player() applies
	player.add_animation_library("", library)
	return player

## Movement-animation counterpart to _populate_skeleton_animation_player():
## that function wires a skinned NIF's OWN embedded animation sequences
## (e.g. the flag's own "Idle" cloth sway) against its own skeleton; this
## one wires SEPARATE, standalone .kf animation files (real movement
## locomotion, e.g. characters\_male\locomotion\male\mtforward.kf) against
## an externally-built shared skeleton — the actual real-world shape of
## human/creature movement animation (confirmed: a bare .kf carries exactly
## one top-level NiControllerSequence with no owning NiControllerManager at
## all — see nif_loader.cpp's own extract_sequence() doc comment — meant to
## be applied to a skeleton loaded from elsewhere, unlike an
## embedded-in-a-mesh sequence).
##
## `clips`: { clip_name: String -> kf_model_path: String }. Each .kf's
## FIRST animation sequence becomes one named Animation in the returned
## player's library (real .kf files carry exactly one — confirmed against
## every real locomotion file checked; a file with none is skipped, not an
## error, since that's a real possible case for e.g. a malformed/DLC-only
## path that doesn't resolve on this install). Returns null if no clip
## resolved to a real animation.
func populate_locomotion_animations(parent: Node3D, skeleton: Skeleton3D, clips: Dictionary, existing_player: AnimationPlayer = null) -> AnimationPlayer:
	var skeleton_path: NodePath = parent.get_path_to(skeleton)
	var resolve_bone := func(target_name: String):
		if skeleton.find_bone(target_name) == -1:
			return null
		return NodePath(str(skeleton_path) + ":" + target_name)

	var library := AnimationLibrary.new()
	if existing_player != null:
		library = existing_player.get_animation_library("")
	for clip_name in clips:
		if library.has_animation(String(clip_name)):
			continue
		var kf_path: String = clips[clip_name]
		var anim := _load_or_build_kf_animation(kf_path, skeleton, resolve_bone, skeleton_path)
		if anim == null:
			continue
		if anim.get_track_count() > 0:
			library.add_animation(String(clip_name), anim)
	if existing_player != null:
		return existing_player

	if library.get_animation_list().is_empty():
		return null

	var player := AnimationPlayer.new()
	player.name = "LocomotionAnimationPlayer"
	parent.add_child(player)
	player.root_node = NodePath("..")
	player.add_animation_library("", library)
	return player

## Adds shared actor/weapon KF clips to one AnimationPlayer rooted at `parent`.
## A real actor KF can contain both Bip01 skeleton targets and weapon-local
## targets in the same sequence. Resolve both against the common Body root so
## one playback operation drives the actor and its equipped weapon together.
## `animated_nodes` is the current weapon subtree; its nodes are instance-
## specific, so these clips are rebuilt when the equipped weapon changes.
func populate_actor_kf_animations(parent: Node3D, skeleton: Skeleton3D, animated_nodes: Node3D, clips: Dictionary, existing_player: AnimationPlayer = null) -> AnimationPlayer:
	if clips.is_empty():
		return existing_player
	var player := existing_player
	if player == null:
		player = AnimationPlayer.new()
		player.name = "LocomotionAnimationPlayer"
		parent.add_child(player)
		player.root_node = NodePath("..")
	var library := player.get_animation_library("")
	if library == null:
		library = AnimationLibrary.new()
		player.add_animation_library("", library)
	var skeleton_path: NodePath = parent.get_path_to(skeleton)
	var node_by_name: Dictionary = {}
	if animated_nodes != null:
		for node in animated_nodes.find_children("*", "Node3D", true, false):
			if not node_by_name.has(String(node.name)):
				node_by_name[String(node.name)] = node
	var resolve_target := func(target_name: String):
		if skeleton.find_bone(target_name) != -1:
			return NodePath(str(skeleton_path) + ":" + target_name)
		# The actor KF visibility controller uses the authored pseudo-target
		# ##VisCtrl rather than the visible Weapon node itself. Resolve that
		# engine convention to the generated weapon hierarchy's Weapon node.
		if target_name == "##VisCtrl" and node_by_name.has("Weapon"):
			return parent.get_path_to(node_by_name["Weapon"])
		if node_by_name.has(target_name):
			return parent.get_path_to(node_by_name[target_name])
		return null
	for clip_name in clips:
		var name := String(clip_name)
		if library.has_animation(name):
			library.remove_animation(name)
		var target_signature := _animation_target_signature(skeleton, node_by_name)
		var cache_key := KF_ANIMATION_CACHE_VERSION + "|" + _animation_source_key() + "|combined|" + String(clips[clip_name]).to_lower() + "|" + target_signature
		var animation: Animation = _shared_converted_animation_cache.get(cache_key)
		if animation == null:
			var kf_nif := load_nif(String(clips[clip_name]))
			if kf_nif == null:
				continue
			var sequences: Array = kf_nif.get_animation_sequences()
			if sequences.is_empty():
				continue
			animation = _build_sequence_animation(sequences[0], resolve_target, skeleton)
			_shared_converted_animation_cache[cache_key] = animation
		if animation.get_track_count() > 0:
			library.add_animation(name, animation)
	return player

func _load_or_build_kf_animation(kf_path: String, skeleton: Skeleton3D, resolve_bone: Callable, skeleton_path: NodePath) -> Animation:
	var cache_key := KF_ANIMATION_CACHE_VERSION + "|" + _animation_source_key() + "|" + kf_path.to_lower() + "|" + String(skeleton_path)
	if _shared_converted_animation_cache.has(cache_key):
		return _shared_converted_animation_cache[cache_key]
	if _animation_cache.has(cache_key):
		return _animation_cache[cache_key]
	var disk_path := _kf_animation_cache_path(cache_key)
	if FileAccess.file_exists(disk_path):
		var cached := ResourceLoader.load(disk_path, "Animation", ResourceLoader.CACHE_MODE_REUSE)
		if cached is Animation:
			_animation_cache[cache_key] = cached
			return cached
	var kf_nif := load_nif(kf_path)
	if kf_nif == null:
		_animation_cache[cache_key] = null
		return null
	var sequences: Array = kf_nif.get_animation_sequences()
	if sequences.is_empty():
		_animation_cache[cache_key] = null
		return null
	var anim := _build_sequence_animation(sequences[0], resolve_bone, skeleton)
	_shared_converted_animation_cache[cache_key] = anim
	_animation_cache[cache_key] = anim
	_save_kf_animation_cache(anim, disk_path)
	return anim

func _animation_target_signature(skeleton: Skeleton3D, named_nodes: Dictionary = {}) -> String:
	var parts: Array[String] = []
	if skeleton != null:
		for index in skeleton.get_bone_count():
			parts.append(String(skeleton.get_bone_name(index)))
	var node_names: Array[String] = []
	for node_name in named_nodes:
		var node: Node = named_nodes[node_name]
		node_names.append(String(node_name) + "@" + String(node.get_path()))
	node_names.sort()
	return ",".join(parts) + "|" + ",".join(node_names)

func _kf_animation_cache_path(cache_key: String) -> String:
	return KF_ANIMATION_CACHE_DIR + "/" + str(abs(cache_key.hash())) + ".tres"

func _save_kf_animation_cache(anim: Animation, disk_path: String) -> void:
	var absolute_dir := ProjectSettings.globalize_path(KF_ANIMATION_CACHE_DIR)
	DirAccess.make_dir_recursive_absolute(absolute_dir)
	ResourceSaver.save(anim, disk_path, ResourceSaver.FLAG_COMPRESS)

## Real Bethesda convention, confirmed against actual movement .kf data and
## direct in-editor review (e.g. characters\_male\locomotion\male\
## mtforward.kf): the skeleton's own root bone ("Bip01") carries genuine
## baked translation across the whole clip -- 0 -> ~1.46 units over a 1.2s
## forward loop, a real walk-speed displacement, not noise -- meant to be
## EXTRACTED by game code to drive the actor's actual world position.
##
## "Bip01 NonAccum" (Bip01's own child, the real parent of the rest of the
## skeleton -- pelvis, spine, every limb) needs the SAME treatment, for a
## second, distinct, confirmed-real reason: its own translation track is
## present in some real clips (mtforward/mtleft/mtright, baseline ~0.93-0.94)
## but ABSENT in others (mtidle.kf, mtbackward.kf have no NonAccum track at
## all) -- and NonAccum's own REST transform (from skeleton.nif itself) is
## exactly (0,0,0). Blending between a clip that has the track and one that
## doesn't makes AnimationTree interpolate NonAccum from that (0,0,0) rest
## default toward ~0.93 proportional to blend weight -- since EVERYTHING
## else in the skeleton is a descendant of NonAccum, this is not a small
## local wobble, it's the WHOLE character's global pose rising by that
## amount, exactly reproducing a real user-observed bug ("floats up into
## the air... by the weight of the blend"). Its own name says why this is
## the right fix: "does NOT accumulate root motion" -- the same role
## Bip01 plays one level up, just inconsistently authored across files.
##
## Playing either bone's own translation track back onto the live
## Skeleton3D -- what naively applying every track would do -- makes the
## whole mesh visually slide/float during in-place playback, since nothing
## here extracts and reapplies that displacement to a physics body yet
## (this is deliberately animation-selection only for now, no
## CharacterBody3D -- see GamebryoActor's own doc comment). Stripped here
## rather than inside _build_sequence_animation() itself, since a
## self-contained animated prop's (e.g. a door's) own root NiNode
## legitimately needs its translation played back — this is specific to a
## skeleton's own root-motion-carrying bones, not a blanket rule for every
## animated root node in this codebase.
## DEPRECATED: the generated-tree path below is retained only as a historical
## reference and must not be used. The actor runtime uses the hand-authored
## npc_actor.tscn tree and ActorAnimationComponent's
## LowerLegLocomotionSpace/UpperLocomotionSpace contract. Keeping a second
## builder with a different parameter schema would make a future caller fail
## silently, so this entry point now fails explicitly.
##
## Real Bethesda locomotion convention (per the user's own review of actual
## gameplay): the legs and upper body are separate layers, not one clip
## driving the whole skeleton -- legs come from the cardinal-direction
## movement cycle, torso/arms come from a separate stance pose, combined so
## the arms don't fight whatever the legs are doing. Builds a real
## AnimationTree over `player`'s own already-loaded clips (see
## populate_locomotion_animations()):
##   - AnimationNodeBlendSpace2D "Locomotion": the 4 real cardinal clips
##     (cardinal_clips: {"forward","backward","left","right"} -> real clip
##     name already in player's library) at compass points, idle_clip at
##     center (0,0), BLEND_MODE_INTERPOLATED for real continuous 2D
##     blending (not discrete switching) -- driven by set_move_input()'s
##     own `parameters/Locomotion/blend_position`.
##   - AnimationNodeAnimation "UpperBodyPose": upper_body_clip (real generic
##     standing pose -- no weapon-equip system yet to pick a per-weapon
##     pose, see NPCActor's own doc comment).
##   - AnimationNodeBlend2 "UpperBodyLayer": Locomotion as the base ("in"),
##     UpperBodyPose as the filtered overlay ("blend", amount fixed at
##     1.0) -- filter_enabled with every bone at/under
##     `upper_body_root_bone` (walked via the live skeleton's own
##     hierarchy, not a hardcoded list) added as a filtered path, so
##     UpperBodyPose only ever touches spine/arms/head, never the legs
##     Locomotion is driving.
## Returns null if any of the 5 required clip names aren't actually in
## `player`'s library (a real possible gap -- see
## populate_locomotion_animations()'s own doc comment).
func populate_locomotion_tree(parent: Node3D, skeleton: Skeleton3D, player: AnimationPlayer, cardinal_clips: Dictionary, idle_clip: String, upper_body_clip: String, upper_body_root_bone: String) -> AnimationTree:
	push_error("GamebryoMeshResolver: populate_locomotion_tree() is deprecated; use the hand-authored actor AnimationTree")
	return null
	# Historical implementation retained below for source archaeology only.
	for required in [cardinal_clips.get("forward", ""), cardinal_clips.get("backward", ""), cardinal_clips.get("left", ""), cardinal_clips.get("right", ""), idle_clip, upper_body_clip]:
		if not player.has_animation(String(required)):
			return null

	# Real, confirmed-via-testing bug: with only 5 points in an exact "plus"
	# shape (4 cardinals + center, every point exactly axis-aligned),
	# BlendSpace2D's own auto-triangulation is a real degenerate edge case
	# -- it produced a working blend for "right" but a broken one for
	# "left" despite mtleft.kf carrying the exact same real 58-track full
	# leg data as mtforward/mtright (confirmed real, not a data gap). An
	# explicit fan triangulation from the center point (idle) to each
	# ADJACENT pair of cardinal points removes any ambiguity: each of the
	# 4 quadrants gets exactly one, unambiguous, correctly-oriented
	# triangle, so sampling directly at any cardinal point (or anywhere
	# between it and its neighbors) always resolves to real, predictable
	# barycentric weights instead of whatever the automatic triangulator
	# happened to produce for this axis-aligned point set.
	var locomotion := AnimationNodeBlendSpace2D.new()
	locomotion.blend_mode = AnimationNodeBlendSpace2D.BLEND_MODE_INTERPOLATED
	locomotion.auto_triangles = false
	const FORWARD_IDX := 0
	const BACKWARD_IDX := 1
	const LEFT_IDX := 2
	const RIGHT_IDX := 3
	const IDLE_IDX := 4
	locomotion.add_blend_point(_animation_node(String(cardinal_clips["forward"])), Vector2(0.0, 1.0))
	locomotion.add_blend_point(_animation_node(String(cardinal_clips["backward"])), Vector2(0.0, -1.0))
	locomotion.add_blend_point(_animation_node(String(cardinal_clips["left"])), Vector2(-1.0, 0.0))
	locomotion.add_blend_point(_animation_node(String(cardinal_clips["right"])), Vector2(1.0, 0.0))
	locomotion.add_blend_point(_animation_node(idle_clip), Vector2(0.0, 0.0))
	locomotion.add_triangle(IDLE_IDX, FORWARD_IDX, RIGHT_IDX)
	locomotion.add_triangle(IDLE_IDX, RIGHT_IDX, BACKWARD_IDX)
	locomotion.add_triangle(IDLE_IDX, BACKWARD_IDX, LEFT_IDX)
	locomotion.add_triangle(IDLE_IDX, LEFT_IDX, FORWARD_IDX)

	var upper_body_layer := AnimationNodeBlend2.new()
	upper_body_layer.filter_enabled = true
	var skeleton_path: NodePath = parent.get_path_to(skeleton)
	for bone_name in _bone_and_descendants(skeleton, upper_body_root_bone):
		upper_body_layer.set_filter_path(NodePath(str(skeleton_path) + ":" + bone_name), true)

	var tree_root := AnimationNodeBlendTree.new()
	tree_root.add_node("Locomotion", locomotion)
	tree_root.add_node("UpperBodyPose", _animation_node(upper_body_clip))
	tree_root.add_node("UpperBodyLayer", upper_body_layer)
	tree_root.connect_node("UpperBodyLayer", 0, "Locomotion")
	tree_root.connect_node("UpperBodyLayer", 1, "UpperBodyPose")
	tree_root.connect_node("output", 0, "UpperBodyLayer")

	var tree := AnimationTree.new()
	tree.name = "LocomotionAnimationTree"
	tree.tree_root = tree_root
	parent.add_child(tree)
	# AnimationTree.anim_player is relative to the AnimationTree node
	# ITSELF, not to `parent` -- a real bug caught here: `tree` and
	# `player` are siblings (both children of `parent`), so the correct
	# path is "../LocomotionAnimationPlayer", not the bare
	# "LocomotionAnimationPlayer" parent.get_path_to(player) would give.
	# Must be set AFTER add_child() too, since get_path_to() needs `tree`
	# to already be in the tree to resolve a path from it.
	tree.anim_player = tree.get_path_to(player)
	tree.active = true
	tree.set("parameters/UpperBodyLayer/blend_amount", 1.0)
	return tree

func _animation_node(clip_name: String) -> AnimationNodeAnimation:
	var node := AnimationNodeAnimation.new()
	node.animation = StringName(clip_name)
	node.resource_name = clip_name # suppresses AnimationNodeBlendSpace2D's own "no name provided" warning
	return node

## `root_bone_name` plus every bone whose parent chain passes through it --
## walked from the live Skeleton3D's own hierarchy (get_bone_parent()),
## never a hardcoded bone list, so this stays correct for any real skeleton
## shape, not just the one confirmed human one.
func _bone_and_descendants(skeleton: Skeleton3D, root_bone_name: String) -> Array:
	var root_idx := skeleton.find_bone(root_bone_name)
	if root_idx == -1:
		return []
	var out: Array = [root_bone_name]
	var included := { root_idx: true }
	var progressed := true
	while progressed:
		progressed = false
		for i in skeleton.get_bone_count():
			if included.has(i):
				continue
			if included.has(skeleton.get_bone_parent(i)):
				included[i] = true
				out.append(skeleton.get_bone_name(i))
				progressed = true
	return out

## Shared per-sequence Animation-building body for populate_animation_player()
## and _populate_skeleton_animation_player() — identical track-construction
## logic (see populate_animation_player()'s own doc comment for the
## interpolation/axis-key-resampling rationale), differing only in HOW a
## track's target_node_name resolves to a NodePath: a Node3D child
## (populate_animation_player, via `built`) vs. a Skeleton3D bone
## (_populate_skeleton_animation_player, via "Skeleton3D:BoneName").
## `resolve_target_path` is a Callable(String) -> Variant (NodePath or null
## if the track's target isn't one this caller can resolve — skipped, not
## an error, since a real sequence commonly targets a mix of nodes/bones
## only some of which exist in a given construction path).
func _build_sequence_animation(seq: Dictionary, resolve_target_path: Callable, skeleton: Skeleton3D = null) -> Animation:
	var anim := Animation.new()
	anim.length = maxf(float(seq["stop_time"]) - float(seq["start_time"]), 0.01)
	match int(seq["cycle_type"]): # nif::SequenceCycleType: 0=loop, 1=reverse, 2=clamp
		0: anim.loop_mode = Animation.LOOP_LINEAR
		_: anim.loop_mode = Animation.LOOP_NONE # reverse/clamp both play once and hold -- Godot has no native ping-pong-once mode; reverse is a real gap, not silently faked

	var non_accum_bone_name := _find_non_accum_bone(skeleton, String(seq.get("accum_root_name", "")))
	var non_accum_path: NodePath = resolve_target_path.call(non_accum_bone_name) if not non_accum_bone_name.is_empty() else NodePath()
	for track in seq["tracks"]:
		var target_name: String = track["target_node_name"]
		var resolved = resolve_target_path.call(target_name)
		if resolved == null:
			continue
		# NonAccum is the authored sibling of the accumulation root. Its
		# translation is retained as source data, but its authored rotation is
		# not a per-clip facing direction: the real runtime resets this node to
		# the skeleton reference transform while Bip01 carries locomotion
		# displacement. Drop only this node's rotation tracks here; a uniform
		# bind-pose track is inserted below, including for clips that authored no
		# rotation at all. This prevents AnimationTree blends from falling back
		# to the bone rest/default differently depending on track presence.
		var is_non_accum := not non_accum_bone_name.is_empty() and target_name == non_accum_bone_name
		if is_non_accum and (bool(track["has_quaternion_keys"]) or bool(track["has_axis_keys"])):
			continue
		var node_path: NodePath = resolved

		if bool(track["has_quaternion_keys"]):
			var idx := anim.add_track(Animation.TYPE_ROTATION_3D)
			anim.track_set_path(idx, node_path)
			var keys: Array = track["quaternion_keys"]
			anim.track_set_interpolation_type(idx, _godot_interp(int(keys[0]["interp"])) if not keys.is_empty() else Animation.INTERPOLATION_LINEAR)
			for k in keys:
				# Real data (movement locomotion .kf files, e.g.
				# characters\_male\locomotion\male\mtforward.kf): nifly's own
				# compressed-quaternion decompression leaves keys a fraction
				# of a percent off unit length (confirmed: length_squared as
				# low as ~0.9979) -- fine for nifly's own tolerance, but
				# Godot's Animation track interpolation hard-errors
				# ("end quaternion must be normalized") without this.
				anim.track_insert_key(idx, float(k["time"]), (k["value"] as Quaternion).normalized())
		elif bool(track["has_axis_keys"]):
			var idx := anim.add_track(Animation.TYPE_ROTATION_3D)
			anim.track_set_path(idx, node_path)
			anim.track_set_interpolation_type(idx, Animation.INTERPOLATION_LINEAR) # resampled below -- see populate_animation_player()'s own doc comment
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
	for track in seq.get("bool_tracks", []):
		var target_name: String = track["target_node_name"]
		var resolved = resolve_target_path.call(target_name)
		if resolved == null:
			continue
		# NiBoolInterpolator is the authored visibility-controller form in
		# supported FNV sequence/KF data. Keep the source property/controller
		# metadata in the native representation, but bind the runtime value to
		# Godot's ordinary Node.visible property here.
		var visibility_idx := anim.add_track(Animation.TYPE_VALUE)
		anim.track_set_path(visibility_idx, NodePath(str(resolved) + ":visible"))
		anim.track_set_interpolation_type(visibility_idx, Animation.INTERPOLATION_NEAREST)
		for key in track.get("keys", []):
			anim.track_insert_key(visibility_idx, float(key["time"]), bool(key["value"]))
	if skeleton != null and not non_accum_path.is_empty():
		var bone_index := skeleton.find_bone(non_accum_bone_name)
		if bone_index != -1:
			var rotation_track := anim.add_track(Animation.TYPE_ROTATION_3D)
			anim.track_set_path(rotation_track, non_accum_path)
			anim.track_set_interpolation_type(rotation_track, Animation.INTERPOLATION_LINEAR)
			var bind_rotation := skeleton.get_bone_rest(bone_index).basis.get_rotation_quaternion().normalized()
			anim.track_insert_key(rotation_track, float(seq.get("start_time", 0.0)), bind_rotation)

	return anim

## Resolve the Bethesda accumulation-root sibling from the live skeleton.
## `accum_root_name` identifies Bip01 itself; the ` NonAccum` suffix is a
## separate, confirmed engine convention and must remain an explicit name
## check. Requiring it to be a direct child prevents an unrelated accessory
## node with a similar suffix from being modified.
func _find_non_accum_bone(skeleton: Skeleton3D, accum_root_name: String) -> String:
	if skeleton == null or accum_root_name.is_empty():
		return ""
	var root_index := skeleton.find_bone(accum_root_name)
	if root_index == -1:
		return ""
	var expected_suffix := accum_root_name + " NonAccum"
	for i in skeleton.get_bone_count():
		if skeleton.get_bone_parent(i) != root_index:
			continue
		if skeleton.get_bone_name(i).to_lower() == expected_suffix.to_lower():
			return skeleton.get_bone_name(i)
	return ""

## nif::KeyInterpolation (0=none/1=linear/2=quadratic/3=tbc/4=constant) ->
## Godot's own Animation.InterpolationType. Runtime actor playback deliberately
## uses LINEAR for the NIF none/constant fallback too: NEAREST is faithful to
## the old low-rate interpretation but produces visible stepping at modern
## playback rates. See populate_animation_player()'s own doc comment for why
## quadratic/tbc both collapse to CUBIC.
func _godot_interp(nif_interp: int) -> int:
	match nif_interp:
		1: return Animation.INTERPOLATION_LINEAR
		2, 3: return Animation.INTERPOLATION_CUBIC
		_: return Animation.INTERPOLATION_LINEAR # 0=none, 4=constant

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

## GodotBryoSettings (issue #56) is the single source of truth for these —
## no default here means anything; a caller (WorldStreamer/CellLoader) must
## call set_lod_crossover()/set_distant_lod_range() before these are used.
## Previously these fields carried their own hardcoded 100.0/5.0 defaults,
## duplicating the values WorldStreamer/CellLoader's own @export vars AND
## DirectGeometryBatch's C++ defaults also carried — four copies of the same
## number that had to be kept in sync by hand. GodotBryoSettings now owns
## the one real value; these are 0.0 (visibly "unset") until a caller sets
## them for real.
var lod_crossover_distance_m := 0.0
var lod_crossover_margin_m := 0.0
var lod1_max_range_m := 0.0 # 0.0 == infinite, matches Godot's own end==0.0 "unbounded" convention

## The distant-cell "skyline" LOD tiles (issue #56, e.g. the Strip wall /
## McCarran building blocks under meshes\landscape\lod\<world>\blocks\) —
## meant to stay visible indefinitely (no far bound), but hidden once the
## camera gets close enough that real geometry should be showing instead.
var distant_lod_near_cutoff_m := 0.0
var distant_lod_near_margin_m := 0.0

func set_lod_crossover(distance_m: float, margin_m: float, lod1_range_m: float = 0.0) -> void:
	lod_crossover_distance_m = distance_m
	lod_crossover_margin_m = margin_m
	lod1_max_range_m = lod1_range_m

func set_distant_lod_range(cutoff_m: float, margin_m: float) -> void:
	distant_lod_near_cutoff_m = cutoff_m
	distant_lod_near_margin_m = margin_m

## Sets one MeshInstance3D's crossover visibility range: `is_full_detail`
## true -> visible only within lod_crossover_distance_m
## (visibility_range_end, Godot's own "hide beyond this distance" field);
## false -> visible from lod_crossover_distance_m out to lod1_max_range_m
## (0.0 == unbounded). VISIBILITY_RANGE_FADE_DISABLED — hard cutover +
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
		mi.visibility_range_end = lod1_max_range_m

## Issue #56: begin-only visibility range for a persistent-cell distant/
## skyline LOD tile — visible from distant_lod_near_cutoff_m outward with
## no far bound, the mirror image of _apply_lod_visibility_range's
## full-detail case.
func _apply_distant_lod_visibility_range(mi: MeshInstance3D) -> void:
	mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
	mi.visibility_range_begin = distant_lod_near_cutoff_m
	mi.visibility_range_begin_margin = distant_lod_near_margin_m
	mi.visibility_range_end = 0.0

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

## Item physics uses the same extracted/fallback shapes as static collision,
## but parents both mesh and shapes under a movable RigidBody3D. Keeping this
## separate prevents MISC from accidentally changing every existing prop.
func populate_rigid_body_children(parent: ItemNode, geometry: Dictionary, mass: float) -> GamebryoRigidBody:
	var body := GamebryoRigidBody.new()
	body.name = "RigidBody3D"
	body.owner_ref = parent
	# FNV inventory weight is a carry/balance unit, not Havok kilograms. A
	# direct mapping made light books almost massless and easy to push through
	# floors/other props; use a temporary stable conversion until Phase 4.
	body.mass = max(mass * 5.0, 1.0)
	# 2 is Godot's CAST_SHAPE CCD mode. Use the numeric enum value because
	# this project's 4.7 bindings do not expose CCD_MODE_CAST_SHAPE to GDScript.
	body.continuous_cd = 2
	body.contact_monitor = true
	body.max_contacts_reported = 8
	body.can_sleep = true
	body.freeze = true
	body.sleeping = true
	# Preview/initial construction is stationary; gameplay can explicitly
	# unfreeze the body when the item is released into the world.
	parent.add_child(body)
	populate_mesh_children(body, null, "", geometry)
	for entry in geometry["shape_entries"]:
		var col := CollisionShape3D.new()
		col.name = String(entry.get("name", "collision"))
		col.shape = entry["shape"]
		col.transform = entry["transform"]
		body.add_child(col)
	return body

## Builds movable bodies from the NIF's authored bhkRigidBody descriptors.
## The source body properties are applied directly; ESM inventory weight is
## intentionally not consulted. A NIF may contain more than one body, so
## each descriptor gets its own Godot RigidBody3D and only its associated
## collision shapes are attached to it. The visual hierarchy is attached to
## the first body, which is the normal single-body item case; the per-body
## extraction and shape associations remain intact for future compound-item
## visual composition.
func populate_authored_rigid_bodies(parent: Node3D, nif: NifReader, model_path: String, geometry: Dictionary = {}) -> Array:
	if geometry.is_empty():
		geometry = build_geometry_entries(resolve_raw_geometry(nif, model_path))
	var authored: Array = nif.get_physics_bodies()
	var bodies: Array = []
	if authored.is_empty():
		if geometry.get("shape_entries", []).is_empty():
			return bodies
		authored.append({
			"mass": 1.0, "linear_damping": 0.1, "angular_damping": 0.05,
			"gravity_factor": 1.0, "friction": 0.5, "restitution": 0.4,
			"collision_shape_indices": PackedInt32Array(),
		})
	for body_index in authored.size():
		var source: Dictionary = authored[body_index]
		var body := GamebryoRigidBody.new()
		body.name = "RigidBody3D" if body_index == 0 else "RigidBody3D%d" % body_index
		body.owner_ref = parent
		body.nif_node_name = String(source.get("node_name", ""))
		body.nif_physics_body_index = body_index
		body.nif_body_data = source.duplicate(true)
		body.set_meta("nif_node_name", body.nif_node_name)
		body.set_meta("nif_physics_body_index", body_index)
		body.set_meta("nif_body_data", source.duplicate(true))
		body.mass = max(float(source.get("mass", 1.0)), 0.001)
		body.linear_damp = max(float(source.get("linear_damping", 0.1)), 0.0)
		body.angular_damp = max(float(source.get("angular_damping", 0.05)), 0.0)
		body.gravity_scale = float(source.get("gravity_factor", 1.0))
		var material := PhysicsMaterial.new()
		material.friction = clampf(float(source.get("friction", 0.5)), 0.0, 1.0)
		material.bounce = clampf(float(source.get("restitution", 0.4)), 0.0, 1.0)
		body.physics_material_override = material
		body.continuous_cd = 2
		body.contact_monitor = true
		body.max_contacts_reported = 8
		body.can_sleep = true
		body.freeze = true
		body.sleeping = true
		parent.add_child(body)
		# The wrapper owns the authored REFR identity, but the body owns the
		# live transform. Keeping it top-level prevents the wrapper's mirrored
		# transform from being composed into the body a second time.
		body.top_level = true
		bodies.append(body)
		if body_index == 0:
			populate_mesh_children(body, null, "", geometry)
	for entry in geometry.get("shape_entries", []):
		var source_index := int(entry.get("physics_body_index", -1))
		if source_index < 0 or source_index >= bodies.size():
			source_index = 0
		var col := CollisionShape3D.new()
		col.name = String(entry.get("name", "collision"))
		col.shape = entry["shape"]
		col.transform = entry["transform"]
		bodies[source_index].add_child(col)
	return bodies

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
func _build_material_from_raw(e: Dictionary) -> Material:
	var tex_path: String = e["texture_path"]
	var normal_path: String = e["normal_texture_path"]
	var glow_path: String = e["glow_texture_path"]
	var alpha: Dictionary = e["alpha_info"]
	var has_vertex_colors: bool = e["has_vertex_colors"]
	var is_unlit: bool = e["is_unlit"]
	var double_sided: bool = e.get("double_sided", false)
	var no_lighting_falloff: Dictionary = e.get("no_lighting_falloff", {})

	if tex_path == "" and normal_path == "" and glow_path == "" and not has_vertex_colors and not bool(alpha.get("has_alpha_property", false)):
		return null
	var key := "%s|%s|%s|%s|%s|%.4f|%d|%s|%s|%s|%s" % [tex_path, normal_path, glow_path,
			bool(alpha.get("blend_enabled", false)), bool(alpha.get("test_enabled", false)),
			float(alpha.get("threshold", 0.5)), int(alpha.get("blend_func", 0)), has_vertex_colors, is_unlit, double_sided, no_lighting_falloff]
	if _material_cache.has(key):
		material_cache_hits += 1
		return _material_cache[key]
	material_cache_misses += 1
	# NoLighting's authored falloff is a per-fragment view-angle alpha fade,
	# not a generic object-distance setting. StandardMaterial3D has no
	# equivalent, so use the small dedicated additive effect shader only for
	# NIFs that explicitly request it (FXLightBeamW03 and peers).
	if is_unlit and bool(no_lighting_falloff.get("enabled", false)) \
			and bool(alpha.get("blend_enabled", false)) \
			and int(alpha.get("blend_func", 0)) == 1:
		var effect := ShaderMaterial.new()
		effect.shader = NO_LIGHTING_FALLOFF_SHADER
		effect.set_shader_parameter("falloff_start_angle", float(no_lighting_falloff.get("start_angle", 1.0)))
		effect.set_shader_parameter("falloff_stop_angle", float(no_lighting_falloff.get("stop_angle", 0.0)))
		effect.set_shader_parameter("falloff_start_opacity", float(no_lighting_falloff.get("start_opacity", 1.0)))
		effect.set_shader_parameter("falloff_stop_opacity", float(no_lighting_falloff.get("stop_opacity", 1.0)))
		var effect_texture := _get_texture_from_image(String(e.get("texture_key", tex_path)), e.get("diffuse_image"))
		if effect_texture != null:
			effect.set_shader_parameter("albedo_texture", effect_texture)
		_material_cache[key] = effect
		return effect

	var mat := StandardMaterial3D.new()
	var have_content := false

	# BSShaderNoLightingProperty is Bethesda's explicit per-shape instruction
	# that scene lights do not affect the material. This includes additive
	# light-beam effects: allowing a nearby OmniLight to shade their volume
	# produces a blown-out floating sphere (issue #26, GSGeneralStore).
	# Preserve texture/vertex alpha and the authored blend mode below; only
	# direct scene lighting is disabled here.
	if is_unlit:
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		have_content = true

	# BSShaderProperty::IsDoubleSided() (nif_loader.cpp) -- real per-shape
	# shaderFlags2 bit, previously not read at all (every shape was hard-
	# culled to Godot's CULL_BACK default regardless of what the NIF actually
	# specified). Doesn't force `have_content` -- a double-sided flag alone
	# on an otherwise textureless/vertex-colorless/alpha-less shape isn't
	# something this pipeline renders anyway (see the early-return above).
	if double_sided:
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED

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
			"physics_body_index": s.get("physics_body_index", -1),
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
