@tool
extends Node

## NifServer -- one NIF file in, one Godot node tree out.
## Implements Plans/NifServer/nif_server_v2.md sections 3 and 4.
##
## The queue, admission cap and per-frame build budget live here; the tree
## construction itself is NifTreeBuilder's. Callers never read the archive or
## construct a NifSource themselves.

const NifTreeBuilderScript := preload("res://GodotBryo/Servers/NifServer/nif_tree_builder.gd")
const NifNamesScript := preload("res://GodotBryo/Servers/NifServer/nif_names.gd")

## All editor-object classification and visibility belongs here. Keeping the
## policy at NIF delivery means it covers every consumer (typed cells, world
## streaming, viewers, and future callers) without changing ESM semantics.
const META_EDITOR_OBJECT := "nif_editor_object"
const EDITOR_OBJECT_GROUP := "nif_editor_objects"

signal editor_object_visibility_changed(visible: bool)

## Section 4.2: _build() calls started per frame.
@export var builds_per_frame_budget: int = 12
## Wall-clock cap on one frame's drain, in microseconds. 0 disables it, leaving
## the count budget alone in charge.
##
## Both caps apply, because they bound different things: the count budget
## limits how many builds are STARTED, which paces worker and TextureServer
## pressure, while this limits how long the drain may actually spend, which is
## what a synchronous cache hit consumes. Whichever is reached first ends the
## frame's drain.
##
## A count budget alone stopped bounding frame time once the tree cache landed.
## A cache miss suspends at build()'s await and costs the frame almost nothing;
## a cache HIT duplicates synchronously and costs the full copy. Measured, the
## corpus worst case is `dlc04mansionwindows01.nif` at 20.4 ms per duplicate and
## `meshes/scol/villatest.nif` -- an SCOL, so on the World Streamer's own path --
## at 12.8 ms, which at a budget of 12 is a 245 ms and a 153 ms frame.
##
## As in TextureServer, at least one item is always processed, so a single
## duplicate costlier than the whole budget still makes progress rather than
## wedging the queue.
@export var build_time_budget_usec: int = 8000
## Admission cap on concurrent _resolve() tasks -- NOT a thread count. -1 means
## max(2, cpus - 1). Never add_group_task() at tasks_needed = -1: it claims
## every thread in the pool this shares with TextureServer, and a build cannot
## finish without an uploaded texture, so starving TextureServer is a hang.
@export var num_workers: int = -1

## Canonical path -> NifSource. The parsed document only, so it is shared across
## both prefer_static settings: flattening happens at build time and changes the
## tree, never the parse.
var _documents := {}

## Section 10's (path, flatten) identity -> a built tree kept as a TEMPLATE.
##
## A template is never delivered and never parented: callers receive
## `template.duplicate()`. Measured at 3-10x cheaper than rebuilding
## (tests/servers/test_nif_duplicate_bench.tscn), but the reason is the draw
## call, not the clock -- Godot coalesces on RID identity, and duplicate()
## assigns object-typed properties by reference, so every copy shares the
## template's mesh, material, shape, skin and Animation RIDs. Fifty placements
## become one instanced draw instead of fifty.
##
## The same sharing is a hazard: a caller that mutates a delivered node's
## material or mesh mutates it for every other instance of that model. See
## README.md. Property-track animation (outstanding_issues.md #5) is exactly
## that mutation and is still unimplemented for exactly this reason.
##
## There is no eviction policy. Templates are resident until purged, which
## pins their textures too -- TextureServer.purge() frees nothing while a
## reference is held. get_stats() reports residency so a caller can watch it.
var _trees := {}         # tree key -> Node3D template (orphan, never parented)
var _tree_nodes := {}    # tree key -> node count, for the residency figure
## Copying a template on a WorkerThreadPool task was built and measured, and is
## NOT used. It worked: eight concurrent copies of 2,100- and 2,500-node trees
## taken while the main thread kept rendering came back structurally and
## resource-identical to a main-thread copy, and it cut the worst frame from
## 14.4 ms to 8.3 ms. But every configuration of it aborted the process during
## engine shutdown -- with and without call_deferred, with and without waiting
## on the tasks, with the new gates disabled -- while the synchronous version
## of the same cache exits cleanly. Creating Nodes on a worker is evidently not
## viable here in 4.7.1, however correct the results look. See
## outstanding_issues.md #11.
var _inflight := {}      # key -> { waiters: Array }
var _pending := []       # keys awaiting a worker slot
var _build_queue := []   # [{ key, waiter }]
## Full-model canonical path -> canonical `_lod.nif` companion, or "" when
## absent. This is an asset-discovery cache, distinct from parsed documents.
var _lod_paths := {}
var _active_resolves := 0
var _warned := {}        # canonical path -> true; section 3.4 warns once
var _orphan_watch := []  # [{ node, frame }] -- see _check_orphans()
var _archive_server: Node = null
var _shutting_down := false
## Runtime policy for CK/GECK authoring gizmos embedded in NIF trees. This is
## intentionally visual-only: typed EsmNodes and any authored collision remain
## available to gameplay and diagnostics.
var editor_objects_visible := true

var _stats := {
	"request_count": 0,
	"lod_request_count": 0,
	"lod_path_cache_hits": 0,
	"lod_path_cache_misses": 0,
	"lod_missing_count": 0,
	"document_cache_hits": 0,
	"document_cache_misses": 0,
	"duplicate_waiter_count": 0,
	"resolve_failure_count": 0,
	"build_count": 0,
	"build_failure_count": 0,
	"builds_this_frame": 0,
	"owner_gone_count": 0,
	"orphan_freed_count": 0,
	"tree_cache_hits": 0,
	"tree_cache_misses": 0,
	"tree_purge_count": 0,
	"template_discarded_count": 0,
}


func _ready() -> void:
	# Resolved once here: _resolve_task() runs on a worker, where any
	# scene-tree query is forbidden.
	_archive_server = get_tree().root.get_node_or_null("ArchiveServer")
	if _archive_server == null:
		push_error("NifServer: ArchiveServer autoload not found; every request will fail")


func _exit_tree() -> void:
	_shutting_down = true
	# Templates are orphans by construction, so nothing else will ever free
	# them and Godot would report every one as a leaked instance at exit.
	_free_all_templates()


## Section 3.3: `\` -> `/`, lowercase, strip a leading `meshes/`. Both
## `Weapons\2HandRifle\Cell.NIF` and the meshes/-prefixed form are one identity.
static func canonical(nif_path: String) -> String:
	var p := nif_path.replace("\\", "/").strip_edges().to_lower()
	while p.begins_with("/"):
		p = p.substr(1)
	if p.begins_with("meshes/"):
		p = p.substr(7)
	return p


## Prefix match is based on authored NIF node identity, not Godot's escaped
## display name. `VisibilityEditorMarker` is OpenMW's second documented
## Gamebryo marker primitive spelling.
static func is_editor_object_name(authored_name: String) -> bool:
	var name := authored_name.to_lower()
	return name.begins_with("editormarker") or name.begins_with("visibilityeditormarker")


## OpenMW's ESM4 renderer treats a standalone model whose basename starts with
## `marker` as an editor primitive. This is model identity, not an ESM editor
## ID, and deliberately lives in this NIF-delivery policy only.
static func is_standalone_marker_model(nif_path: String) -> bool:
	return canonical(nif_path).get_file().begins_with("marker")


## Returns `nif_path`'s real paired `_lod.nif` path, or "" when the model has
## no companion. VWD's paired-file convention belongs here with the archive
## lookup and negative cache, not in WorldStreamer or EsmNode.
##
## This is deliberately a path resolver, not an in-NIF LOD interpretation:
## the paired NIFs contain no distance selector. `request()` still always
## serves the exact path it receives.
func lod_companion_path(nif_path: String) -> String:
	var key := canonical(nif_path)
	if key.is_empty():
		return ""
	if _lod_paths.has(key):
		_stats["lod_path_cache_hits"] += 1
		return String(_lod_paths[key])
	if _archive_server == null or (_archive_server.has_method("is_ready") and not _archive_server.is_ready()):
		# Archive startup is transient. Do not turn it into a permanent negative
		# cache entry, unlike a completed archive lookup.
		return ""
	_stats["lod_path_cache_misses"] += 1
	var result := ""
	if key.ends_with(".nif"):
		var candidate := key.trim_suffix(".nif") + "_lod.nif"
		if _archive_server.contains("meshes/" + candidate):
			result = candidate
	_lod_paths[key] = result
	return result


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


## Requests a full model's paired `_lod.nif` companion. The callback contract
## is identical to request(): it fires exactly once with an unparented tree or
## null. A missing companion is normal and returns null; it never falls back
## to the full path, which would make distant streaming parse full detail.
func request_lod(nif_path: String, owner: Node, on_complete: Callable, prefer_static := false) -> void:
	_stats["lod_request_count"] += 1
	var waiter := { "owner": owner, "cb": on_complete, "prefer_static": prefer_static }
	if not _valid_callback(owner, on_complete):
		push_error("NifServer: on_complete must be a method on `owner`; LOD request for '%s' refused" % nif_path)
		return
	if _shutting_down or _archive_server == null:
		_deliver(waiter, null)
		return
	var lod_path := lod_companion_path(nif_path)
	if lod_path.is_empty():
		_stats["lod_missing_count"] += 1
		_deliver(waiter, null)
		return
	request(lod_path, owner, on_complete, prefer_static)


func get_stats() -> Dictionary:
	var out := _stats.duplicate()
	out["active_resolve_count"] = _active_resolves
	out["pending_admission_count"] = _pending.size()
	out["pending_build_count"] = _build_queue.size()
	out["resident_document_count"] = _documents.size()
	out["resident_tree_count"] = _trees.size()
	out["lod_path_cache_size"] = _lod_paths.size()
	# Node count is the residency figure a template actually costs: its meshes,
	# materials and textures are shared with every other tree that references
	# them, so counting those would attribute the same bytes to several caches.
	var nodes := 0
	for n in _tree_nodes.values():
		nodes += int(n)
	out["resident_tree_node_count"] = nodes
	return out


func reset_stats() -> void:
	for k in _stats.keys():
		_stats[k] = 0


func set_editor_objects_visible(visible: bool) -> void:
	if editor_objects_visible == visible:
		return
	editor_objects_visible = visible
	var tree := get_tree()
	if tree != null:
		for node in tree.get_nodes_in_group(EDITOR_OBJECT_GROUP):
			if node is Node3D:
				(node as Node3D).visible = visible
	editor_object_visibility_changed.emit(visible)


func _apply_editor_object_visibility(root: Node) -> void:
	if root is Node3D and bool(root.get_meta(META_EDITOR_OBJECT, false)):
		(root as Node3D).visible = editor_objects_visible
	for child in root.get_children():
		_apply_editor_object_visibility(child)


## Called once on a freshly-built tree before it becomes a template. All
## supported marker representations converge on META_EDITOR_OBJECT: a
## standalone `marker*` model marks its complete tree, while embedded marker
## primitives mark only their matching render node. Consumers only need this
## one identifier/group; they never need to know which NIF convention matched.
func _tag_editor_objects(root: Node, nif_path: String) -> void:
	_tag_editor_objects_recursive(root, is_standalone_marker_model(nif_path), false)


func _tag_editor_objects_recursive(node: Node, whole_model_is_editor_object: bool,
		inherited_nif_marker_flag: bool) -> void:
	var nif_marker_flag := inherited_nif_marker_flag or _has_nif_marker_flag(node)
	var is_editor_object := whole_model_is_editor_object
	if node is Node3D:
		var authored_name := String(node.get_meta(NifNamesScript.META_NIF_NAME, ""))
		# `MRK`/BSX identifies this NIF subtree as marker-bearing; the authored
		# primitive name identifies which render node is the editor gizmo.
		# This mirrors OpenMW's Gamebryo loader rather than hiding an unrelated
		# gameplay mesh that happens to share an EditorMarker-like name.
		is_editor_object = is_editor_object or (nif_marker_flag and is_editor_object_name(authored_name))
		if is_editor_object:
			node.set_meta(META_EDITOR_OBJECT, true)
			node.add_to_group(EDITOR_OBJECT_GROUP)
	for child in node.get_children():
		_tag_editor_objects_recursive(child, whole_model_is_editor_object, nif_marker_flag)


func _has_nif_marker_flag(node: Node) -> bool:
	return String(node.get_meta("nif_extra_NiStringExtraData", "")) == "MRK" \
		or (int(node.get_meta("nif_extra_BSXFlags", 0)) & 32) != 0


## Drops one cached template. Manual eviction, not a policy -- V1 is
## resident-until-purged, matching TextureServer.
##
## Delivered duplicates are unaffected: they hold their own references to the
## shared resources, so purging a template frees the template's nodes and
## nothing else until the last instance is gone.
func purge(nif_path: String, prefer_static := false) -> void:
	_drop_template(_tree_key(canonical(nif_path), prefer_static))


## Drops every cached document and template.
func purge_all() -> void:
	_documents.clear()
	_free_all_templates()


## Copies a template. Synchronous, and therefore bounded by
## build_time_budget_usec in the drain above rather than by concurrency.
func _duplicate(template: Node3D) -> Node3D:
	if template == null or not is_instance_valid(template):
		return null
	return template.duplicate() as Node3D


## A template is an orphan: it has no parent and is in no tree, so queue_free()
## needs a message-queue flush that never comes during shutdown and the node is
## simply never freed. free() is correct for a node nothing else can be
## traversing -- the refcount above guarantees no worker still holds it.
func _free_template(template: Node) -> void:
	if template != null and is_instance_valid(template):
		template.free()


func _drop_template(tree_key: String) -> void:
	var template = _trees.get(tree_key)
	_trees.erase(tree_key)
	_tree_nodes.erase(tree_key)
	if template == null or not is_instance_valid(template):
		return
	_stats["tree_purge_count"] += 1
	_free_template(template)


func _free_all_templates() -> void:
	# keys() is snapshotted first: _drop_template() erases from _trees.
	for tree_key in _trees.keys().duplicate():
		_drop_template(tree_key)
	_trees.clear()
	_tree_nodes.clear()


## Section 10: a flattened tree and a hierarchical one are different artefacts
## from one document, so they are separate cache entries.
static func _tree_key(key: String, prefer_static: bool) -> String:
	return key + "#static" if prefer_static else key


static func _count_nodes(root: Node) -> int:
	var n := 1
	for c in root.get_children():
		n += _count_nodes(c)
	return n


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
	var started := Time.get_ticks_usec()
	while not _build_queue.is_empty():
		if _stats["builds_this_frame"] >= budget:
			break
		if build_time_budget_usec > 0 and _stats["builds_this_frame"] > 0 \
				and Time.get_ticks_usec() - started >= build_time_budget_usec:
			break
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
	var prefer_static := bool(waiter.get("prefer_static", false))
	var tree_key := _tree_key(entry["key"], prefer_static)

	# Cache hit: no build, no await, no frame boundary. The copy is synchronous,
	# so build_time_budget_usec above is what keeps a cell load's worth of them
	# from landing in one frame.
	var cached = _trees.get(tree_key)
	if cached != null and is_instance_valid(cached):
		_stats["tree_cache_hits"] += 1
		_deliver(waiter, _duplicate(cached as Node3D))
		return
	_stats["tree_cache_misses"] += 1

	var root: Node3D = await NifTreeBuilderScript.build(src, true, prefer_static)
	if root == null:
		_stats["build_failure_count"] += 1
		_deliver(waiter, null)
		return
	_tag_editor_objects(root, String(entry["key"]))
	_stats["build_count"] += 1
	# Re-checked after the await: the build spans frames.
	if not _owner_alive(waiter):
		_stats["owner_gone_count"] += 1
		root.queue_free()
		return
	if _shutting_down:
		_deliver(waiter, root)
		return

	# Two requests for one key can both miss, because the document cache
	# deduplicates the parse but the build queue still holds an entry per
	# waiter and each build spans frames. Whichever finishes first becomes the
	# template; the rest deliver the tree they already built rather than
	# discarding work or overwriting a template other instances now share.
	var winner = _trees.get(tree_key)
	if winner != null and is_instance_valid(winner):
		_stats["template_discarded_count"] += 1
		_deliver(waiter, root)
		return

	_trees[tree_key] = root
	_tree_nodes[tree_key] = _count_nodes(root)
	# The template is never delivered and never parented, so the caller gets a
	# copy even on the build that created it.
	_deliver(waiter, _duplicate(root))


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
	if root != null:
		# Applies to template duplicates and builds that completed after a menu
		# toggle but before their requesting EsmNode entered the scene tree.
		_apply_editor_object_visibility(root)
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
