@tool
extends Node

## TextureServer -- the project's one DDS decode/upload/cache primitive.
## Implements Plans/texture_server.md.
##
## Two callers need this and neither owns a NIF: the NIF material builder and
## terrain. Folding texture ownership into NifServer would relocate the wrong
## owner rather than fix it.
##
## Threading, same constraint as NifServer and for the same reason: Image is a
## plain pixel buffer and decodes safely on a worker; ImageTexture issues a real
## RenderingServer call and is main-thread only. _decode() is therefore a pure
## function that touches no shared state, and every cache, counter and queue is
## main-thread-owned -- so no atomics anywhere on the worker path.

const UPLOAD_BUDGET_DEFAULT := 8

## Max _upload() calls drained per frame.
@export var uploads_per_frame_budget: int = UPLOAD_BUDGET_DEFAULT
## 0 = count-based only; >0 time-boxes the drain instead.
@export var upload_time_budget_usec: int = 0
## Admission cap on this server's concurrent decode tasks -- not a thread count.
@export var num_workers: int = -1


class TextureJob extends RefCounted:
	signal finished(texture: ImageTexture)
	var key := ""
	var path := ""
	var alpha_safe := false
	var waiters := 0


## Deliberately NOT cached: the decoded Image is consumed by _upload() and then
## dropped. Keeping it would hold a second, CPU-side copy of every texture --
## the full corpus is 4.26 GB of DDS bytes, so an Image cache alongside the
## ImageTexture cache would roughly double the resident footprint for a buffer
## nothing reads back.
var _textures := {}      # key -> ImageTexture | null
var _jobs := {}          # key -> TextureJob (queued or in flight)
var _admission := []     # keys awaiting a worker slot
var _uploads := []       # [{key, image}] awaiting main-thread upload
var _active := 0
## Resolved once on the main thread. _decode() runs on workers, where any
## scene-tree query (get_node/has_node) is forbidden by Godot, so the
## reference must be captured up front rather than looked up per call.
var _archive_server: Node = null

var _stats := {
	"decode_cache_hits": 0,
	"decode_cache_misses": 0,
	"upload_cache_hits": 0,
	"upload_cache_misses": 0,
	"uploads_this_frame": 0,
	"warm_attach_count": 0,
	"decode_failure_count": 0,
	"total_upload_count": 0,
	"purge_count": 0,
}


## Cache identity, carried over verbatim from mesh_resolver._tex_variant_key().
## A texture decoded for an alpha-safe use must stay a distinct entry from the
## same path decoded normally, or the two uses collide and reintroduce the
## black-background decal bug this project already fixed once.
static func cache_key(tex_path: String, alpha_safe: bool) -> String:
	return tex_path + "#rgba" if (alpha_safe and tex_path != "") else tex_path


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var root := get_tree().root
	if root.has_node("ArchiveServer"):
		_archive_server = root.get_node("ArchiveServer")
	else:
		push_error("TextureServer: ArchiveServer autoload not found; texture loads will fail")


# --- public surface --------------------------------------------------------

## Worker-safe, pure: reads bytes through ArchiveServer and decodes them.
## Touches no cache, no counter and no queue, so it is safe to call directly
## from any thread. Returns null when the texture is missing or undecodable.
func _decode(tex_path: String, alpha_safe: bool = false) -> Image:
	if tex_path.is_empty():
		return null
	var archive := _archive()
	if archive == null:
		return null
	var result: Dictionary = archive.read(tex_path)
	if not bool(result["found"]):
		return null
	var img := Image.new()
	if img.load_dds_from_buffer(PackedByteArray(result["data"])) != OK:
		return null
	# Only DXT1 needs this: its 1-bit alpha is lost on GPU upload, so a submesh
	# whose NiAlphaProperty actually needs that alpha gets RGBA8 instead. DXT3
	# and DXT5 alpha reaches the GPU intact and stays compressed.
	if alpha_safe and img.get_format() == Image.FORMAT_DXT1:
		var had_mips := img.has_mipmaps()
		if img.decompress() == OK and had_mips and not img.has_mipmaps():
			img.generate_mipmaps()
	return img


## Main-thread only: uploads a decoded Image and caches the result.
func _upload(tex_path: String, image: Image, alpha_safe: bool = false) -> ImageTexture:
	var key := cache_key(tex_path, alpha_safe)
	if _textures.has(key):
		_stats["upload_cache_hits"] += 1
		return _textures[key]
	_stats["upload_cache_misses"] += 1
	var tex: ImageTexture = null
	if image != null:
		tex = ImageTexture.create_from_image(image)
	_textures[key] = tex
	_stats["total_upload_count"] += 1
	return tex


## Fire-and-forget. Callable from any thread: the enqueue is marshalled through
## call_deferred rather than mutating the pending queue on the caller's thread.
func warm(tex_path: String, alpha_safe: bool = false) -> void:
	if tex_path.is_empty():
		return
	_enqueue.bind(tex_path, alpha_safe, false).call_deferred()


## Coroutine. Resident -> returns immediately with no queue interaction.
## Warming -> attaches a waiter to the existing job. Cold -> queues one.
func request(tex_path: String, alpha_safe: bool = false) -> ImageTexture:
	if tex_path.is_empty():
		return null
	var key := cache_key(tex_path, alpha_safe)
	if _textures.has(key):
		_stats["upload_cache_hits"] += 1
		return _textures[key]
	var job: TextureJob = _enqueue(tex_path, alpha_safe, true)
	if job == null:
		return _textures.get(key)
	return await job.finished


## True once a key has reached a terminal state -- success or failure alike.
## "Finished" is deliberately not "usable": a failed texture is finished, and
## must never become a permanent blocker for whoever is waiting on it.
func is_finished(tex_path: String, alpha_safe: bool = false) -> bool:
	return _textures.has(cache_key(tex_path, alpha_safe))


## Drops a cached entry. Manual eviction, not a policy: V1 is resident-forever
## (Plans/texture_server.md) and this exists for callers that walk large sets --
## the full corpus is 26,840 textures / 4.26 GB, which fits fine but is
## pointless to hold while looking at one texture at a time.
##
## Caveat, measured: ImageTexture is refcounted, so this frees nothing while a
## material still holds the texture, and the next request() then decodes a
## SECOND independent copy. Do not use it as a memory-pressure valve without
## first filtering on external reference count. Does nothing to an entry that
## is still queued or in flight.
func purge(tex_path: String, alpha_safe: bool = false) -> void:
	var key := cache_key(tex_path, alpha_safe)
	if _jobs.has(key):
		return
	_textures.erase(key)
	_stats["purge_count"] += 1


## Drops every resident entry. Queued and in-flight jobs are left alone.
func purge_all() -> void:
	for key in _textures.keys():
		if not _jobs.has(key):
			_textures.erase(key)
			_stats["purge_count"] += 1


func get_stats() -> Dictionary:
	var out := _stats.duplicate()
	out["pending_queue_count"] = _jobs.size()
	out["pending_upload_count"] = _uploads.size()
	out["active_decode_count"] = _active
	out["resident_texture_count"] = _textures.size()
	return out


func reset_stats() -> void:
	for k in _stats.keys():
		_stats[k] = 0


# --- internals (all main-thread) -------------------------------------------

func _enqueue(tex_path: String, alpha_safe: bool, want_waiter: bool) -> TextureJob:
	var key := cache_key(tex_path, alpha_safe)
	if _textures.has(key):
		return null # already resident; nothing to queue
	if _jobs.has(key):
		var existing: TextureJob = _jobs[key]
		if want_waiter:
			existing.waiters += 1
			_stats["warm_attach_count"] += 1
		return existing
	var job := TextureJob.new()
	job.key = key
	job.path = tex_path
	job.alpha_safe = alpha_safe
	job.waiters = 1 if want_waiter else 0
	_jobs[key] = job
	_admission.append(key)
	_admit()
	return job


func _worker_cap() -> int:
	if num_workers == -1:
		return maxi(2, OS.get_processor_count() - 1)
	return maxi(1, num_workers)


func _admit() -> void:
	while not _admission.is_empty() and _active < _worker_cap():
		var key: String = _admission.pop_front()
		if not _jobs.has(key):
			continue
		var job: TextureJob = _jobs[key]
		_active += 1
		WorkerThreadPool.add_task(_decode_task.bind(key, job.path, job.alpha_safe))


## Worker thread body. Pure decode; the result is handed back to the main
## thread, which owns every cache and counter.
func _decode_task(key: String, tex_path: String, alpha_safe: bool) -> void:
	var img := _decode(tex_path, alpha_safe)
	_on_decoded.bind(key, img).call_deferred()


func _on_decoded(key: String, image: Image) -> void:
	_active = maxi(0, _active - 1)
	if image == null:
		_stats["decode_failure_count"] += 1
	_stats["decode_cache_misses"] += 1
	_uploads.append({"key": key, "image": image})
	_admit()


func _process(_delta: float) -> void:
	_stats["uploads_this_frame"] = 0
	var budget: int = maxi(1, uploads_per_frame_budget)
	var started := Time.get_ticks_usec()
	while not _uploads.is_empty():
		if upload_time_budget_usec > 0:
			if Time.get_ticks_usec() - started >= upload_time_budget_usec and _stats["uploads_this_frame"] > 0:
				break
		elif _stats["uploads_this_frame"] >= budget:
			break
		var entry: Dictionary = _uploads.pop_front()
		var key: String = entry["key"]
		var job: TextureJob = _jobs.get(key)
		var tex_path := job.path if job != null else key
		var alpha_safe := job.alpha_safe if job != null else false
		var tex := _upload(tex_path, entry["image"], alpha_safe)
		_stats["uploads_this_frame"] += 1
		_jobs.erase(key)
		if job != null:
			# A failed texture still finishes; waiters get null, never a hang.
			job.finished.emit(tex)


func _archive() -> Node:
	return _archive_server
