@tool
extends Node

## NifServer -- one NIF file in, one Godot node tree out.
## Implements Plans/NifServer/nif_server_v2.md sections 3 and 4.
##
## The queue, admission cap and per-frame build budget live here; the tree
## construction itself is NifTreeBuilder's. Callers never read the archive or
## construct a NifSource themselves.

const NifTreeBuilderScript := preload("res://GodotBryo/Servers/NifServer/nif_tree_builder.gd")

## Section 4.2: _build() calls started per frame.
@export var builds_per_frame_budget: int = 12
## Admission cap on concurrent _resolve() tasks -- NOT a thread count. -1 means
## max(2, cpus - 1). Never add_group_task() at tasks_needed = -1: it claims
## every thread in the pool this shares with TextureServer, and a build cannot
## finish without an uploaded texture, so starving TextureServer is a hang.
@export var num_workers: int = -1

## Canonical path -> NifSource. The parsed document only, so it is shared across
## both prefer_static settings: flattening happens at build time and changes the
## tree, never the parse. Section 10's (path, flatten) cache identity applies to
## a built-tree cache, which does not exist yet.
##
## A tree is built fresh per delivered instance. Caching built trees and handing out duplicate() is
## outstanding_issues.md #11 and is entangled with the mesh/material sharing
## decision, so it stays out until that is settled.
var _documents := {}
var _inflight := {}      # key -> { waiters: Array }
var _pending := []       # keys awaiting a worker slot
var _build_queue := []   # [{ key, waiter }]
var _active_resolves := 0
var _warned := {}        # canonical path -> true; section 3.4 warns once
var _orphan_watch := []  # [{ node, frame }] -- see _check_orphans()
var _archive_server: Node = null
var _shutting_down := false

var _stats := {
	"request_count": 0,
	"document_cache_hits": 0,
	"document_cache_misses": 0,
	"duplicate_waiter_count": 0,
	"resolve_failure_count": 0,
	"build_count": 0,
	"build_failure_count": 0,
	"builds_this_frame": 0,
	"owner_gone_count": 0,
	"orphan_freed_count": 0,
}


func _ready() -> void:
	# Resolved once here: _resolve_task() runs on a worker, where any
	# scene-tree query is forbidden.
	_archive_server = get_tree().root.get_node_or_null("ArchiveServer")
	if _archive_server == null:
		push_error("NifServer: ArchiveServer autoload not found; every request will fail")


func _exit_tree() -> void:
	_shutting_down = true


## Section 3.3: `\` -> `/`, lowercase, strip a leading `meshes/`. Both
## `Weapons\2HandRifle\Cell.NIF` and the meshes/-prefixed form are one identity.
static func canonical(nif_path: String) -> String:
	var p := nif_path.replace("\\", "/").strip_edges().to_lower()
	while p.begins_with("/"):
		p = p.substr(1)
	if p.begins_with("meshes/"):
		p = p.substr(7)
	return p


## Section 3.1. `on_complete` must be a method on `owner`, is invoked exactly
## once on the main thread, and receives the built Node3D or null.
##
## On success ownership transfers to the caller: parent it or free it. A result
## still unparented after delivery is freed by the safety net below.
## `prefer_static` asks for section 10's flattened form. A file with dynamic
## content -- animation, billboards, ragdoll, particles, a skeleton -- comes back
## hierarchical instead, with `nif_not_flattened_because` on the root saying
## which. A caller placing scenery does not know in advance whether a given SCOL
## animates, and should not have to.
func request(nif_path: String, owner: Node, on_complete: Callable, prefer_static := false) -> void:
	_stats["request_count"] += 1
	var waiter := { "owner": owner, "cb": on_complete, "prefer_static": prefer_static }
	if not _valid_callback(owner, on_complete):
		push_error("NifServer: on_complete must be a method on `owner` (nif_server_v2.md section 3.2); request for '%s' refused" % nif_path)
		return
	if _shutting_down or _archive_server == null:
		_deliver(waiter, null)
		return
	var key := canonical(nif_path)
	if key.is_empty():
		_warn_once(key, "NifServer: empty path is an invalid request")
		_deliver(waiter, null)
		return

	if _documents.has(key):
		_stats["document_cache_hits"] += 1
		_build_queue.append({ "key": key, "waiter": waiter })
		return
	if _inflight.has(key):
		_stats["duplicate_waiter_count"] += 1
		(_inflight[key]["waiters"] as Array).append(waiter)
		return

	_stats["document_cache_misses"] += 1
	_inflight[key] = { "waiters": [waiter] }
	_pending.append(key)
	_admit()


func get_stats() -> Dictionary:
	var out := _stats.duplicate()
	out["active_resolve_count"] = _active_resolves
	out["pending_admission_count"] = _pending.size()
	out["pending_build_count"] = _build_queue.size()
	out["resident_document_count"] = _documents.size()
	return out


func reset_stats() -> void:
	for k in _stats.keys():
		_stats[k] = 0


## Drops cached documents. Manual, not a policy -- there is no eviction yet.
func purge_all() -> void:
	_documents.clear()


## Section 3.4: warnings are emitted once per canonical path. A cell holding
## fifty copies of one broken model should say so once, not fifty times.
func _warn_once(key: String, message: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	push_warning(message)


func _worker_cap() -> int:
	return maxi(2, OS.get_processor_count() - 1) if num_workers < 0 else maxi(1, num_workers)


func _admit() -> void:
	while not _pending.is_empty() and _active_resolves < _worker_cap():
		var key: String = _pending.pop_front()
		if not _inflight.has(key):
			continue
		_active_resolves += 1
		WorkerThreadPool.add_task(_resolve_task.bind(key))


## Worker thread body (section 4). Archive read and parse only: no cache, no
## Node, no RID-backed resource. Textures are not warmed here -- build() warms
## the whole slot set as one batch and then awaits it, so starting earlier would
## only move the same work, and reaching TextureServer from a worker needs a
## reference resolved on the main thread.
func _resolve_task(key: String) -> void:
	var src: NifSource = null
	var error := ""
	var result: Dictionary = _archive_server.read("meshes/" + key)
	if not bool(result["found"]):
		error = String(result["error"])
	else:
		var loaded := NifSource.new()
		if loaded.load(PackedByteArray(result["data"])):
			src = loaded
		else:
			error = loaded.get_last_error()
	_on_resolved.bind(key, src, error).call_deferred()


func _on_resolved(key: String, src: NifSource, error: String) -> void:
	_active_resolves = maxi(0, _active_resolves - 1)
	var entry: Dictionary = _inflight.get(key, {})
	_inflight.erase(key)
	var waiters: Array = entry.get("waiters", [])
	if src == null:
		_stats["resolve_failure_count"] += 1
		_warn_once(key, "NifServer: %s failed to load (%s)" % [key, error])
		for w in waiters:
			_deliver(w, null)
	else:
		_documents[key] = src
		for w in waiters:
			_build_queue.append({ "key": key, "waiter": w })
	_admit()


func _process(_delta: float) -> void:
	_check_orphans()
	_stats["builds_this_frame"] = 0
	var budget := maxi(1, builds_per_frame_budget)
	while not _build_queue.is_empty() and _stats["builds_this_frame"] < budget:
		var entry: Dictionary = _build_queue.pop_front()
		_stats["builds_this_frame"] += 1
		# Deliberately not awaited: _build() suspends until its textures are
		# resident, and the budget counts builds STARTED this frame. Awaiting
		# here would stall the drain behind one texture decode.
		_build(entry)


func _build(entry: Dictionary) -> void:
	var waiter: Dictionary = entry["waiter"]
	# Section 3.2: an owner that went away before the build started means no
	# tree is constructed at all, rather than one built and then orphaned.
	if not _owner_alive(waiter):
		_stats["owner_gone_count"] += 1
		return
	var src: NifSource = _documents.get(entry["key"])
	if src == null:
		_deliver(waiter, null)
		return

	var root: Node3D = await NifTreeBuilderScript.build(src, true, bool(waiter.get("prefer_static", false)))
	if root == null:
		_stats["build_failure_count"] += 1
		_deliver(waiter, null)
		return
	_stats["build_count"] += 1
	# Re-checked after the await: the build spans frames.
	if not _owner_alive(waiter):
		_stats["owner_gone_count"] += 1
		root.queue_free()
		return
	_deliver(waiter, root)


## The liveness check below only means anything if the callable is bound to the
## owner: a closure capturing it stays valid after the owner is freed, and the
## result would be handed to something already gone.
static func _valid_callback(owner: Node, on_complete: Callable) -> bool:
	return owner != null and on_complete.is_valid() and on_complete.get_object() == owner


func _owner_alive(waiter: Dictionary) -> bool:
	var owner = waiter.get("owner")
	return owner != null and is_instance_valid(owner)


## Invoked exactly once per request (section 3.2). A result with no live taker
## is freed here rather than leaked.
func _deliver(waiter: Dictionary, root: Node3D) -> void:
	var cb: Callable = waiter.get("cb", Callable())
	if not (cb.is_valid() and _owner_alive(waiter)):
		if root != null:
			_stats["owner_gone_count"] += 1
			root.queue_free()
		return
	cb.call(root)
	if root != null:
		_orphan_watch.append({ "node": root, "frame": Engine.get_process_frames() })


## Section 3.2's safety net, and E7.
##
## Deliberately NOT call_deferred: a deferred call runs in the same frame's idle
## flush, which only protects a caller that parents synchronously inside the
## callback. A caller that parents on the NEXT frame is legitimate -- the gate
## requires it -- so a result is given a full frame to find a parent before it
## is treated as leaked.
func _check_orphans() -> void:
	if _orphan_watch.is_empty():
		return
	var now := Engine.get_process_frames()
	var still := []
	for entry in _orphan_watch:
		var node = entry["node"]
		if not is_instance_valid(node):
			continue # the caller freed it, which is the other legal outcome
		if node.get_parent() != null:
			continue # adopted
		if now > int(entry["frame"]) + 1:
			_stats["orphan_freed_count"] += 1
			node.queue_free()
			continue
		still.append(entry)
	_orphan_watch = still
