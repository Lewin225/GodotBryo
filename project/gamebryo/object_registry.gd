class_name GamebryoObjectRegistry
extends RefCounted

## type_tag -> factory registry (phases/1/01-object-type-registry.md /
## phases/1/architecture.md's "Registry extensibility"). Runtime-populated,
## not a compiled switch — adding a type is one register() call, nothing
## else changes.

var resolver: GamebryoMeshResolver
var esm: EsmReader
var _factories := {} # String -> Callable(Dictionary, GamebryoMeshResolver) -> Node3D

## Optional (null by default -- every @tool viewer and most test_*.tscn
## scenes construct a GamebryoObjectRegistry with no ScriptEngine at all,
## and that stays a real, valid, non-error configuration). When set (by
## game.gd, the only real runtime entry point that has one), _finalize()
## registers every placement with a real, non-zero script_form_id --
## phases/5/00-script-interpreter-foundation.md's actual live-game wiring.
var script_engine: ScriptEngine = null

func _init(mesh_resolver: GamebryoMeshResolver, esm_reader: EsmReader) -> void:
	resolver = mesh_resolver
	esm = esm_reader
	_register_defaults()

func register(type_tag: String, factory: Callable) -> void:
	_factories[type_tag] = factory

func unregister(type_tag: String) -> void:
	_factories.erase(type_tag)

func is_registered(type_tag: String) -> bool:
	return _factories.has(type_tag)

## Resolves one placement Dictionary (from EsmReader.get_cell_references() /
## get_scol_parts()) to a node, or null if it can't be placed. Three-tier
## fallback:
##   1. a registered factory for base_type -> use it
##   2. no registered factory, but the base record has a resolvable model ->
##      generic GamebryoVisual (keyed on MODL presence alone, not OBND —
##      see mesh_resolver.gd's note on why OBND isn't threaded through yet)
##   3. neither -> null; caller logs the skip (the registry doesn't hold
##      side-channel logging state, keep it simple)
func build(placement: Dictionary) -> Node3D:
	# Checked before base_type dispatch: markers share base_type=STAT with
	# thousands of legitimate props (see MarkerNode's doc comment), so this
	# can't be a registered "STAT" factory without hijacking every real STAT
	# placement too.
	if MarkerNode.is_marker_model(placement.get("model", "")):
		return _build_marker(placement)
	var type_tag: String = placement.get("base_type", "")
	if _factories.has(type_tag):
		return _factories[type_tag].call(placement, resolver)
	if String(placement.get("model", "")) != "":
		return _instantiate_visual(GamebryoVisual, placement, resolver)
	return null

## phases/2/10-threaded-streaming-workers.md, step 3: the resolve-only
## counterpart to build() -- same three-tier dispatch (marker / registered
## interactive type / structural fallback) and the same set of base_types
## _register_defaults() below wires up, but returns plain data instead of a
## Node, and reads ONLY `ctx` (never self.esm/self.resolver) so this is safe
## to call from a WorkerThreadPool task -- including calling it concurrently
## from multiple threads on the SAME GamebryoObjectRegistry instance, since
## nothing here touches this object's own mutable state (_factories is
## deliberately not consulted; the dispatch below is its own fixed list, not
## routed through the Callable registry, precisely so a caller can't swap in
## a non-thread-safe custom factory via register() and have it silently run
## on a worker thread).
##
## The base_type -> shape mapping is intentionally duplicated here rather
## than driven by _factories (already listed once in _register_defaults())
## -- a second, bounded occurrence of a 6-case list that's been stable since
## Phase 1, not a maintenance burden worth a shared-Callable
## redesign that would also have to solve "how does a caller know a given
## Callable is safe to run off-thread."
##
## Returns a Dictionary tagged "kind" (step 4, WorldStreamer's commit step,
## switches on this to build the right Node type or feed DirectGeometryBatch
## without re-touching the ESM):
##   "marker" -- { placement, marker_kind } (MarkerNode.kind_from_model()'s
##               result, precomputed here since it's a pure string function)
##   "door"   -- { placement, type_tag: "DOOR", geometry, destination }
##               (destination is {} for a plain non-teleporting door, same
##               "real, valid case" DoorNode.resolve_destination() already
##               treats it as)
##   "scol"   -- { placement, parts: Array of recursively-resolved results }
##               (SCOL bundles STAT placements inside its own record body,
##               same recursion build()'s own _build_scol() already does)
##   "light"  -- { placement, geometry (may be {} -- a meshless light rig,
##               the common case per phases/1/03), light_data }
##   "visual" -- { placement, type_tag (one of CONT/ACTI/FURN/TACT/TERM/MSTT,
##               or "" for the
##               structural-fallback/GamebryoVisual case), geometry,
##               lod_geometry (optional, phases/2/12-distant-object-lod.md
##               step 4 -- only present for a VWD-flagged placement with a
##               resolvable _lod.nif companion, the small minority; absent,
##               not {}-valued, otherwise) }
##   "skip"   -- { placement } only -- mirrors build() returning null (no
##               model, unparseable NIF, or a LIGH with neither mesh nor
##               light data resolved)
## phases/2/12-distant-object-lod.md, step 3: `full_detail` -- true for a
## tile within `RADIUS_LOAD_FULL` (resolve everything, as before); false for
## a tile out in `WorldStreamer`'s wider `RADIUS_LOAD_DISTANT`-only band, in
## which case ONLY a VWD-flagged placement (`visible_when_distant` -- the
## real per-REFR eligibility gate confirmed in enginedocs/lod.md) is worth
## resolving at all; everything else skips straight to `"kind": "skip"`
## before ever touching NIF/BSA, which is what keeps the wider band cheap --
## see that task doc's own real content-density survey (only ~10.85% of
## placements are VWD-flagged). Checked first, before the marker check or
## any base_type dispatch, since it's a free Dictionary read, cheaper than
## either.
func resolve_placement(placement: Dictionary, ctx: GamebryoResolveContext, full_detail: bool = true) -> Dictionary:
	if not full_detail and not bool(placement.get("visible_when_distant", false)):
		return { "kind": "skip", "placement": placement }

	if MarkerNode.is_marker_model(placement.get("model", "")):
		return { "kind": "marker", "placement": placement,
				"marker_kind": MarkerNode.kind_from_model(placement.get("model", "")) }

	var type_tag: String = placement.get("base_type", "")
	match type_tag:
		"DOOR":
			return _resolve_door(placement, ctx)
		"SCOL":
			return _resolve_scol(placement, ctx)
		"LIGH":
			return _resolve_light(placement, ctx)
		"CONT", "ACTI", "FURN", "TACT", "TERM", "MSTT":
			return _resolve_visual(placement, ctx, type_tag)
		_:
			if String(placement.get("model", "")) != "":
				return _resolve_visual(placement, ctx, "") # structural fallback
			return { "kind": "skip", "placement": placement }

## One WorkerThreadPool task's worth of work: resolve every placement in
## `refs` (a tile's, or the persistent root's, own ref list) through `ctx`.
## Plain data in, plain data out -- no Node/RenderingServer/PhysicsServer3D
## touched anywhere in the call chain from here down, which is what makes
## wrapping a call to this in WorkerThreadPool.add_task() safe at all.
func resolve_tile(refs: Array, ctx: GamebryoResolveContext, full_detail: bool = true) -> Array:
	var out: Array = []
	for p in refs:
		out.append(resolve_placement(p, ctx, full_detail))
	return out

func _resolve_visual(placement: Dictionary, ctx: GamebryoResolveContext, type_tag: String) -> Dictionary:
	var model: String = placement.get("model", "")
	if model == "":
		return { "kind": "skip", "placement": placement }
	var nif := ctx.resolver.load_nif(model)
	if nif == null or nif.get_submesh_count() == 0:
		return { "kind": "skip", "placement": placement }
	var geometry := ctx.resolver.resolve_raw_geometry(nif, model) # RAW -- construct_from_resolved() builds the actual Resources, main-thread-only
	# `nif` itself is worker-safe to retain (NifReader touches no
	# RenderingServer/PhysicsServer3D API at all -- see mesh_resolver.gd's
	# own top-of-file doc comment on which of its methods are worker-safe),
	# same as `geometry`'s own embedded Image objects already cross this
	# same thread boundary. Only DOOR's construct step actually reads this
	# key back out (populate_dynamic_children()/populate_animation_player()
	# need the real NifReader for scene_nodes/owning_node_index/
	# animation_sequences, none of which resolve_raw_geometry() itself
	# captures) -- every other type ignores it, cheap to carry regardless.
	var result := { "kind": "visual", "type_tag": type_tag, "geometry": geometry, "placement": placement, "nif": nif }
	var lod_geometry := _resolve_lod_geometry(placement, model, ctx.resolver)
	if not lod_geometry.is_empty():
		result["lod_geometry"] = lod_geometry
	return result

## phases/2/12-distant-object-lod.md, step 4: a second, optional RAW geometry
## block for `placement`'s own `_lod.nif` companion -- attached alongside the
## full-detail geometry whenever `placement` is actually eligible (VWD-
## flagged AND a companion resolves), which is a small minority of
## placements (see that task doc's own real content-density survey). Both
## variants are attached regardless of which streaming band resolved this
## tile (`full_detail` true or false) -- WHICH mesh actually renders is
## purely Godot's own per-frame visibility_range check (steps 6/7), not
## something decided here or by WorldStreamer. Returns {} (not attached at
## all) for the overwhelming common case -- not VWD-flagged, no `_lod.nif`
## companion, or the companion NIF itself has no real geometry.
##
## Takes a bare `mesh_resolver` (not a full GamebryoResolveContext) -- the
## only thing this ever touches is resolver-side methods, and step 6 needs
## the exact same logic from `_instantiate_visual()` (CellLoader's
## editor-preview `build()` path), which only has a GamebryoMeshResolver on
## hand, not a ctx. Worker-safe when called with a per-context resolver (the
## threaded path, via `ctx.resolver`), same reasoning as
## resolve_raw_geometry() itself -- only touches NifReader/BsaReader.
func _resolve_lod_geometry(placement: Dictionary, model: String, mesh_resolver: GamebryoMeshResolver) -> Dictionary:
	if not bool(placement.get("visible_when_distant", false)):
		return {}
	var lod_path := mesh_resolver.lod_companion_path(model)
	if lod_path == "":
		return {}
	var lod_nif := mesh_resolver.load_nif(lod_path)
	if lod_nif == null or lod_nif.get_submesh_count() == 0:
		return {}
	return mesh_resolver.resolve_raw_geometry(lod_nif, lod_path)

func _resolve_door(placement: Dictionary, ctx: GamebryoResolveContext) -> Dictionary:
	var visual := _resolve_visual(placement, ctx, "DOOR")
	if visual["kind"] == "skip":
		return visual
	var refr_form_id := int(placement.get("refr_form_id", 0))
	visual["kind"] = "door"
	visual["destination"] = ctx.esm.get_door_destination(refr_form_id)
	# phases/3/00-door-completion.md Part B: sounds + flags, resolved once
	# here (same reasoning as destination above) rather than lazily.
	var base_form_id := int(placement.get("base_form_id", 0))
	visual["door_data"] = ctx.esm.get_door_data(base_form_id)
	return visual

## Parts always resolve as if full_detail=true, regardless of the SCOL
## placement's own band -- by the time this runs, resolve_placement()'s own
## early-exit already confirmed the SCOL itself is in scope (either the
## full-detail band, or VWD-flagged in the distant band). SCOL parts have
## no REFR/visible_when_distant flag of their own (get_scol_parts() always
## defaults it to false, since they're not independent records -- see step
## 1's own doc comment), so re-applying the full_detail gate to them would
## incorrectly skip every part of an already-eligible SCOL.
func _resolve_scol(placement: Dictionary, ctx: GamebryoResolveContext) -> Dictionary:
	var parts: Array = ctx.esm.get_scol_parts(int(placement.get("base_form_id", 0)))
	var resolved_parts: Array = []
	for part in parts:
		resolved_parts.append(resolve_placement(part, ctx, true))
	return { "kind": "scol", "placement": placement, "parts": resolved_parts }

func _resolve_light(placement: Dictionary, ctx: GamebryoResolveContext) -> Dictionary:
	var geometry: Dictionary = {}
	var model: String = placement.get("model", "")
	if model != "":
		var nif := ctx.resolver.load_nif(model)
		if nif != null and nif.get_submesh_count() > 0:
			geometry = ctx.resolver.resolve_raw_geometry(nif, model) # RAW, same reasoning as _resolve_visual()
	var light_data: Dictionary = ctx.esm.get_light_data(int(placement.get("base_form_id", 0)))
	if geometry.is_empty() and light_data.is_empty():
		return { "kind": "skip", "placement": placement }
	return { "kind": "light", "geometry": geometry, "light_data": light_data, "placement": placement }

## phases/2/10-threaded-streaming-workers.md, step 4: the main-thread-only
## "commit" half of the resolve/commit split -- builds the real Node
## subtree (or feeds `batch`, a DirectGeometryBatch, for the structural-
## fallback case) from a resolve_placement()/resolve_tile() result. No I/O,
## no BSA/NIF/ESM access anywhere in this call chain -- every geometry/
## metadata input was already produced during resolve, main thread or a
## worker task, doesn't matter which by this point.
##
## Returns null both for "kind": "skip" (nothing to place, same meaning
## build() returning null already has) AND for a structural-fallback
## placement routed into `batch` (placed via RID, no Node at all) -- the
## caller doesn't need to tell those two apart, both mean "nothing to
## add_child()". `batch` is optional: pass null to always build a Node
## (GamebryoVisual) for the structural-fallback case too, for a caller with
## no DirectGeometryBatch at all.
func construct_from_resolved(result: Dictionary, batch: DirectGeometryBatch = null) -> Node3D:
	match result["kind"]:
		"marker":
			return _construct_marker(result)
		"door":
			return _construct_door(result)
		"light":
			return _construct_light(result)
		"scol":
			return _construct_scol(result)
		"visual":
			var type_tag: String = result.get("type_tag", "")
			match type_tag:
				"CONT":
					return _construct_visual(ContainerNode, result)
				"ACTI":
					return _construct_visual(ActivatorNode, result)
				"FURN":
					return _construct_visual(FurnitureNode, result)
				"TACT":
					return _construct_visual(TalkingActivatorNode, result)
				"TERM":
					return _construct_visual(TerminalNode, result)
				"MSTT":
					return _construct_visual(MovableStaticNode, result)
				_: # structural fallback
					if batch != null:
						_construct_direct(result, batch)
						return null
					return _construct_visual(GamebryoVisual, result)
		_: # "skip"
			return null

func _construct_visual(cls, result: Dictionary) -> Node3D:
	var node = cls.new()
	# result["geometry"] is RAW (built by a worker task, or by this same
	# thread's own _resolve_visual()) -- build_geometry_entries() is the
	# main-thread-only step that actually constructs the ArrayMesh/
	# ImageTexture/StandardMaterial3D/Shape3D Resources. Safe here: this
	# whole construct_from_resolved() call chain is main-thread-only by
	# design (see world_streamer.gd's own commit-step doc comment).
	# result["lod_geometry"] (phases/2/12-distant-object-lod.md, step 4/6) is
	# RAW too, absent for the overwhelming majority of placements -- {}
	# default means build_geometry_entries()'s own lod_raw stays {} and
	# populate_mesh_children() attaches no LOD tier at all, no behavior
	# change from before step 6.
	var geometry := resolver.build_geometry_entries(result.get("geometry", {}), result.get("lod_geometry", {}))
	resolver.populate_mesh_children(node, null, "", geometry)
	resolver.populate_collision_children(node, null, "", geometry)
	return _finalize(node, result["placement"])

## phases/3/00-door-completion.md step 7: doors are Dynamic (can script,
## and can animate -- see enginedocs/nv_class_hierarchy.md's Dynamic/Static
## split), so this deliberately does NOT go through _construct_visual()'s
## shared flattened-Static path the way ContainerNode/ActivatorNode/
## FurnitureNode/the structural fallback still do. Builds the real
## scene_nodes hierarchy (populate_dynamic_children()) and a real
## AnimationPlayer (populate_animation_player()) instead, so a door's mesh/
## collision genuinely follow its animated pivot node and "Open"/"Close"
## are real, playable Animations -- both already verified visually correct
## in nif_viewer.tscn before this was wired in here. `result["nif"]`
## (_resolve_visual()'s own addition, see that function's doc comment) is
## the live NifReader both new functions need directly; the RAW `geometry`
## Dictionary alone (what _construct_visual() gets by) has no scene_nodes/
## owning_node_index/animation_sequences in it at all.
func _construct_door(result: Dictionary) -> Node3D:
	var node := DoorNode.new()
	var nif: NifReader = result.get("nif")
	var geometry := resolver.build_geometry_entries(result.get("geometry", {}), result.get("lod_geometry", {}))
	var built := resolver.populate_dynamic_children(node, nif, "", geometry)
	resolver.populate_animation_player(node, nif, built)
	node = _finalize(node, result["placement"])
	if node is DoorNode:
		node.apply_destination(result.get("destination", {}))
		node.apply_door_data(resolver, result.get("door_data", {}))
	return node

func _construct_marker(result: Dictionary) -> Node3D:
	var node := MarkerNode.new()
	node.marker_kind = result.get("marker_kind", "")
	return _finalize(node, result["placement"])

func _construct_light(result: Dictionary) -> Node3D:
	var node := LightNode.new()
	var raw_geometry: Dictionary = result.get("geometry", {})
	if not raw_geometry.is_empty():
		var geometry := resolver.build_geometry_entries(raw_geometry)
		resolver.populate_mesh_children(node, null, "", geometry)
		resolver.populate_collision_children(node, null, "", geometry)
	_apply_light_data(node, result.get("light_data", {}))
	if node.get_child_count() == 0:
		return null
	return _finalize(node, result["placement"])

## SCOL parts always become real Node children, never routed through a
## DirectGeometryBatch -- matches _build_scol()'s existing behavior (which
## recurses through build(), always a Node), not a new restriction
## introduced here.
func _construct_scol(result: Dictionary) -> Node3D:
	var anchor := Node3D.new()
	for part_result in result.get("parts", []):
		var child := construct_from_resolved(part_result, null)
		if child != null:
			anchor.add_child(child)
	var parts: Array = result.get("parts", [])
	var placement: Dictionary = result["placement"]
	if anchor.get_child_count() != parts.size():
		push_warning("GamebryoObjectRegistry: SCOL %s built %d/%d parts as real children (the rest resolved to 'skip' -- see each part's own base_type/model)" % [
			placement.get("editor_id", "0x%X" % int(placement.get("refr_form_id", 0))), anchor.get_child_count(), parts.size(),
		])
	var finalized := _finalize(anchor, placement)
	# Real bug report (2026-08-23): a real, load-successful SCOL building
	# reported "missing" (no geometry, no collision) standing right next to
	# it -- load_nif()/_load_image()'s own new failure logging fired zero
	# times for it, ruling out a resolve failure. This is the other half of
	# that investigation: confirms whether the anchor actually ended up in
	# the world where the SCOL's own REFR position says it should be, vs
	# some other bug (a transform composition error, a Terrain3D/occlusion
	# issue, etc.) putting real, successfully-built geometry somewhere the
	# player never sees it.
	print("GamebryoObjectRegistry: SCOL %s finalized at local pos %s, %d/%d real children" % [
		finalized.name, finalized.transform.origin, anchor.get_child_count(), parts.size(),
	])
	return finalized

## The RID-based construct path for a structural-fallback placement --
## resolves the placement's own world transform and feeds `batch` directly.
## `result["geometry"]` is RAW (resolve_placement() already did the BSA/NIF
## work); build_geometry_entries() here is the main-thread-only step that
## actually constructs the ArrayMesh/Shape3D Resources batch.add_object()
## needs -- DirectGeometryBatch's own RenderingServer/PhysicsServer3D calls
## were always main-thread-only, this just makes sure the Resources it's
## handed were too.
func _construct_direct(result: Dictionary, batch: DirectGeometryBatch) -> void:
	var placement: Dictionary = result["placement"]
	# result["lod_geometry"] (phases/2/12-distant-object-lod.md, step 4/7):
	# this IS the primary real-world path for VWD content -- structural-
	# fallback placements (most STAT natural scenery/architecture, the
	# overwhelming majority of what's actually VWD-flagged, per that task
	# doc's own survey) always route through here at runtime, not
	# _construct_visual()'s Node-based path.
	var geometry := resolver.build_geometry_entries(result.get("geometry", {}), result.get("lod_geometry", {}))
	var pos: Vector3 = placement.get("position", Vector3.ZERO)
	var rot: Vector3 = placement.get("rotation", Vector3.ZERO)
	var scale: float = placement.get("scale", 1.0)
	var world_transform := GamebryoMeshResolver.world_transform_no_parent(pos, rot, scale)
	batch.add_object(world_transform, geometry["mesh_entries"], geometry["shape_entries"], geometry.get("lod_mesh_entries", []))

func _register_defaults() -> void:
	register("DOOR", func(p, r): return _build_door(p, r))
	register("CONT", func(p, r): return _instantiate_visual(ContainerNode, p, r))
	register("ACTI", func(p, r): return _instantiate_visual(ActivatorNode, p, r))
	register("FURN", func(p, r): return _instantiate_visual(FurnitureNode, p, r))
	register("TACT", func(p, r): return _instantiate_visual(TalkingActivatorNode, p, r))
	register("TERM", func(p, r): return _instantiate_visual(TerminalNode, p, r))
	register("MSTT", func(p, r): return _instantiate_visual(MovableStaticNode, p, r))
	register("SCOL", func(p, r): return _build_scol(p, r))
	register("LIGH", func(p, r): return _build_light(p, r))
	# Every other Tier 1 type (WEAP/ARMO/AMMO/BOOK/KEYM/ALCH/NOTE/TREE/CCRD/
	# IMOD/CMNY) is deliberately NOT registered — they share
	# the plain GamebryoVisual shape (confirmed identical EDID/OBND/MODL
	# structure per phases/1/architecture.md's evidence table) and fall
	# through to build()'s structural fallback tier. This exercises that
	# fallback with real, common data instead of only via a contrived test.

## phases/2/12-distant-object-lod.md, step 6: also resolves+attaches the
## same optional LOD tier _resolve_visual() does for the threaded path --
## this is the shared factory build() itself dispatches to (DOOR/CONT/ACTI/
## FURN/structural-fallback alike), and CellLoader's own @tool editor-preview
## build() routes through it, so this is what makes the Node-based LOD path
## visible in editor preview too, not just at runtime via WorldStreamer.
func _instantiate_visual(cls, placement: Dictionary, mesh_resolver: GamebryoMeshResolver) -> Node3D:
	var model: String = placement.get("model", "")
	if model == "":
		return null
	var nif := mesh_resolver.load_nif(model)
	if nif == null or nif.get_submesh_count() == 0:
		return null
	var node = cls.new()
	var lod_raw := _resolve_lod_geometry(placement, model, mesh_resolver)
	var geometry := mesh_resolver.build_geometry_entries(mesh_resolver.resolve_raw_geometry(nif, model), lod_raw)
	mesh_resolver.populate_mesh_children(node, nif, model, geometry)
	mesh_resolver.populate_collision_children(node, nif, model, geometry)
	return _finalize(node, placement)

## phases/3/00-door-completion.md step 7: DOOR is Dynamic (can script, and
## can animate — enginedocs/nv_class_hierarchy.md's Dynamic/Static split),
## so this builds through _instantiate_dynamic() (real scene_nodes
## hierarchy + AnimationPlayer) rather than _instantiate_visual() (the
## flattened Static path every other registered type still uses) — the
## same construction _construct_door() uses on the threaded
## resolve/construct split WorldStreamer runs at runtime, so this
## synchronous build() path (CellLoader's @tool editor-preview, direct
## test construction) can't silently show a different door than what
## actually ships. Teleport destination (if any) resolved once here —
## phases/2/07-runtime-cell-loader.md — rather than looked up lazily on
## interaction.
func _build_door(placement: Dictionary, mesh_resolver: GamebryoMeshResolver) -> Node3D:
	var node := _instantiate_dynamic(DoorNode, placement, mesh_resolver)
	if node is DoorNode:
		node.resolve_destination(esm)
		# phases/3/00-door-completion.md Part B: same real sounds/flags
		# _construct_door() (the threaded path) resolves -- see that
		# function's own doc comment on why DOOR can't have this on only
		# one of its two construction paths.
		node.apply_door_data(mesh_resolver, esm.get_door_data(int(placement.get("base_form_id", 0))))
	return node

## Dynamic-object counterpart to _instantiate_visual() (same signature) —
## builds the real scene_nodes hierarchy + AnimationPlayer
## (populate_dynamic_children()/populate_animation_player()) instead of the
## flattened Static path. No LOD tier (unlike _instantiate_visual()) — a
## real, deliberate gap: doors aren't realistically VWD-flagged/distant-LOD
## candidates in practice, and threading _resolve_lod_geometry() through
## the Dynamic hierarchy (which node would an LOD swap even attach under?)
## is unscoped work this step doesn't need, not something silently dropped.
func _instantiate_dynamic(cls, placement: Dictionary, mesh_resolver: GamebryoMeshResolver) -> Node3D:
	var model: String = placement.get("model", "")
	if model == "":
		return null
	var nif := mesh_resolver.load_nif(model)
	if nif == null or nif.get_submesh_count() == 0:
		return null
	var node = cls.new()
	var geometry := mesh_resolver.build_geometry_entries(mesh_resolver.resolve_raw_geometry(nif, model))
	var built := mesh_resolver.populate_dynamic_children(node, nif, model, geometry)
	mesh_resolver.populate_animation_player(node, nif, built)
	return _finalize(node, placement)

## MARKER: identity + transform only, deliberately no mesh/collision (see
## MarkerNode's doc comment) — GamebryoReference is Node3D, so it has no
## physics body at all unless a GamebryoCollisionBody child is composed in,
## and MarkerNode never does. marker_kind is the model's own basename, the
## only real distinguishing signal Bethesda left; future dedicated behavior
## (e.g. an Audio marker -> AudioStreamPlayer3D) keys off it here.
func _build_marker(placement: Dictionary) -> Node3D:
	var node := MarkerNode.new()
	node.marker_kind = MarkerNode.kind_from_model(placement.get("model", ""))
	return _finalize(node, placement)

## SCOL bundles multiple STAT placements inside its own record body (not via
## child REFRs) — see esm::EsmFile::get_scol_parts(). Each part resolves
## exactly like an ordinary REFR placement (same Dictionary shape), so it
## recurses through build() rather than duplicating _instantiate_visual's
## logic.
func _build_scol(placement: Dictionary, _mesh_resolver: GamebryoMeshResolver) -> Node3D:
	var anchor := Node3D.new()
	var parts: Array = esm.get_scol_parts(int(placement.get("base_form_id", 0)))
	for part in parts:
		var child := build(part)
		if child != null:
			anchor.add_child(child)
	return _finalize(anchor, placement)

## LIGH: mesh children if a fixture model is present (optional, unlike
## _instantiate_visual — a light with no mesh is still a valid, common
## result, e.g. GSDocMitchellHouse's ambient/fill/key rig), plus a real
## Light3D child driven by esm::LightData. Benchmark is correct placement
## and a plausible light, not falloff-curve fidelity — see
## phases/1/03-light-sources.md.
func _build_light(placement: Dictionary, mesh_resolver: GamebryoMeshResolver) -> Node3D:
	var node := LightNode.new()

	var model: String = placement.get("model", "")
	if model != "":
		var nif := mesh_resolver.load_nif(model)
		if nif != null and nif.get_submesh_count() > 0:
			var geometry := mesh_resolver.build_geometry_entries(mesh_resolver.resolve_raw_geometry(nif, model))
			mesh_resolver.populate_mesh_children(node, nif, model, geometry)
			mesh_resolver.populate_collision_children(node, nif, model, geometry)

	_apply_light_data(node, esm.get_light_data(int(placement.get("base_form_id", 0))))

	if node.get_child_count() == 0:
		return null # no mesh and no light data resolved — nothing to place
	return _finalize(node, placement)

## The actual Light3D-child construction, extracted out of _build_light() so
## phases/2/10-threaded-streaming-workers.md's _construct_light() (the
## threaded path's equivalent, working from an already-resolved light_data
## Dictionary instead of a fresh esm.get_light_data() call) shares it
## instead of duplicating this block. A no-op if `light_data` is empty (a
## mesh-only light fixture with no LIGH data resolved, or — normally —
## simply not called in that case).
func _apply_light_data(node: LightNode, light_data: Dictionary) -> void:
	if light_data.is_empty():
		return
	var radius: float = max(float(light_data.get("radius", 5.0)), 0.1) * 2.0
	var color: Color = light_data.get("color", Color.WHITE)
	var is_spot: bool = light_data.get("is_spot", false)

	var light: Light3D
	if is_spot:
		var spot := SpotLight3D.new()
		# Bethesda FOV is degrees; unclear whether it's already a
		# half-angle or a full cone angle. Godot's spot_angle is a
		# half-angle. Treating it as a full angle (halving) since that
		# matches "field of view" naming convention more commonly —
		# approximate, not byte-verified; benchmark is a plausible cone,
		# not an exact match.
		spot.spot_angle = clamp(float(light_data.get("fov_degrees", 90.0)) * 0.5, 1.0, 89.0)
		spot.spot_range = radius
		spot.spot_attenuation = 2.0
		light = spot
	else:
		light = OmniLight3D.new()
		light.omni_range = radius
		light.omni_attenuation = 2.0

	light.name = "SpotLight3D" if is_spot else "OmniLight3D"
	light.light_color = color
	light.light_energy = 2.1 # 30% below the previous approximate value; see phases/1/03-light-sources.md
	light.shadow_enabled = true
	light.visible = not bool(light_data.get("off_by_default", false))
	node.add_child(light)

## Node name + editor description, for every placed object regardless of
## whether it got a dedicated typed class (DoorNode, ...) or fell through to
## the generic structural fallback (GamebryoVisual — most base records that
## haven't gotten a dedicated factory yet, per
## phases/1/01-object-type-registry.md). Most base records have no
## EditorID at all (only a minority are human-authored with one in the
## CK) — falling back to a bare "REFR_<formid>" loses the one identifying
## thing left, the record type, so the fallback name includes base_type
## too. The editor_description carries the full picture (base type, both
## FormIDs in hex, resolved model path) so it's visible in the Godot
## Inspector even for objects whose class doesn't yet expose any of this as
## real fields — doesn't require the type to be implemented to stay
## identifiable.
func _finalize(node: Node3D, placement: Dictionary) -> Node3D:
	var editor_id: String = placement.get("editor_id", "")
	var base_type: String = placement.get("base_type", "")
	var refr_form_id := int(placement.get("refr_form_id", 0))
	var base_form_id := int(placement.get("base_form_id", 0))
	var model: String = placement.get("model", "")

	if editor_id != "":
		node.name = editor_id
	else:
		node.name = "%s_%X" % [base_type if base_type != "" else "REFR", refr_form_id]

	var desc_lines := PackedStringArray()
	desc_lines.append("base_type: %s" % (base_type if base_type != "" else "(unknown)"))
	desc_lines.append("base_editor_id: %s" % (editor_id if editor_id != "" else "(none)"))
	desc_lines.append("base_form_id: 0x%X" % base_form_id)
	desc_lines.append("refr_form_id: 0x%X" % refr_form_id)
	if model != "":
		desc_lines.append("model: %s" % model)
	node.editor_description = "\n".join(desc_lines)

	var pos: Vector3 = placement.get("position", Vector3.ZERO)
	var rot: Vector3 = placement.get("rotation", Vector3.ZERO)
	var scale: float = placement.get("scale", 1.0)
	node.transform = GamebryoMeshResolver.refr_transform(pos, rot, scale)
	if node is GamebryoReference:
		node.form_id = int(placement.get("refr_form_id", 0))
		node.base_form_id = int(placement.get("base_form_id", 0))
	if node is GamebryoObject:
		node.editor_id = editor_id
		node.record_type = String(placement.get("base_type", ""))

	var script_form_id := int(placement.get("script_form_id", 0))
	if script_engine != null and script_form_id != 0:
		script_engine.register_scripted_node(node, script_form_id)

	return node
