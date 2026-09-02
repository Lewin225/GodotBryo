class_name GamebryoObjectRegistry
extends RefCounted

const XEMI_NO_LIGHTING_SHADER := preload("res://gamebryo/xemi_no_lighting.gdshader")
const XEMI_NO_LIGHTING_OPAQUE_SHADER := preload("res://gamebryo/xemi_no_lighting_opaque.gdshader")

## type_tag -> factory registry (phases/1/01-object-type-registry.md /
## phases/1/architecture.md's "Registry extensibility"). Runtime-populated,
## not a compiled switch — adding a type is one register() call, nothing
## else changes.

var resolver: GamebryoMeshResolver
var esm: EsmReader
var _factories := {} # String -> Callable(Dictionary, GamebryoMeshResolver) -> Node3D

# Debug-tunable while validating how Gamebryo's packed LIGH RGB reaches
# Godot. Kept on the registry so newly streamed/loaded lights use the same
# interpretation as existing ones, rather than the toggle affecting only
# the currently resident cell.
var ligh_bytes_are_linear := true

# XEMI supplies a colour but no separate intensity. For ordinary authored
# NoLighting window/backing layers, make that colour HDR self-lit so the
# project's already-enabled bloom can represent the deliberate sunlight
# blowout. Additive falloff effects retain their dedicated shader path.
var xemi_no_lighting_emission_energy := 12.0

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
	var model: String = placement.get("model", "")
	if model != "":
		# issue #44: no DirectGeometryBatch indoors, so the only thing this
		# path is missing for an animated structural-fallback placement is
		# a real scene_nodes hierarchy + AnimationPlayer to target -- see
		# _construct_animated_visual()'s own doc comment for why
		# _instantiate_visual()'s flattened mesh can't carry that.
		var nif := resolver.load_nif(model) # cached by path -- cheap, _instantiate_*() below reloads it regardless
		# issues #46/#47: real skeletal skinning (a humanoid/creature body, or
		# -- the real case that surfaced this path -- a skinned+morphed prop
		# like the Goodsprings NV_Nevadaflag.NIF) checked BEFORE the animated
		# case: populate_skeleton() already wires its own bone-pose
		# AnimationPlayer from get_animation_sequences() internally (see that
		# function's own doc comment), so a skinned NIF that's ALSO
		# "animated" (the flag is both) needs Skeleton3D construction, not
		# the rigid Node-per-NiAVObject hierarchy _instantiate_dynamic() below
		# builds -- that has no bone data at all.
		if nif != null and not nif.get_skin_data().is_empty():
			return _instantiate_skinned(GamebryoVisual, placement, resolver)
		if nif != null and not nif.get_animation_sequences().is_empty():
			return _autoplay_special_idle(_instantiate_dynamic(GamebryoVisual, placement, resolver))
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
		"MISC":
			return _resolve_item(placement, ctx)
		"KEYM":
			return _resolve_item(placement, ctx)
		"ALCH":
			return _resolve_item(placement, ctx)
		"WEAP":
			return _resolve_item(placement, ctx)
		"TERM":
			return _resolve_terminal(placement, ctx)
		"CONT", "ACTI", "FURN", "TACT", "MSTT":
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
	# issue #44: a structural-fallback placement whose NIF carries real
	# NiControllerSequence data fails the "Moves" half of nv_class_hierarchy.
	# md's Dynamic/Static test at runtime (its transform diverges from its
	# NIF-authored reference pose) even though its base_type never does.
	# `animated` itself isn't the batching decision -- see
	# `ineligible_for_batching` below for that -- it's kept separately
	# because construct_from_resolved() still needs to know WHICH real-Node
	# shape an ineligible placement requires (dynamic children +
	# AnimationPlayer, not just "a Node instead of a batch entry").
	# Worker-safe: NifReader.get_animation_sequences() touches no
	# RenderingServer/PhysicsServer3D API, same as this whole resolve step.
	if not nif.get_animation_sequences().is_empty():
		result["animated"] = true
	# issues #46/#47: real skeletal skinning (BSDismemberSkinInstance/
	# NiSkinInstance) -- takes priority over `animated` at the construct
	# site (populate_skeleton() already wires its own bone-pose
	# AnimationPlayer from get_animation_sequences() internally, see that
	# function's own doc comment) since a skinned NIF has no scene_nodes-
	# per-NiAVObject hierarchy the `animated`-only path could target
	# anyway. Worker-safe: NifReader.get_skin_data() touches no
	# RenderingServer/PhysicsServer3D API, same as get_animation_sequences().
	if not nif.get_skin_data().is_empty():
		result["skinned"] = true
	var emittance_form_id: int = int(placement.get("emittance_form_id", 0))
	if emittance_form_id != 0:
		var emittance_data: Dictionary = ctx.esm.get_emittance_data(emittance_form_id)
		if not emittance_data.is_empty():
			# XEMI belongs to this REFR, not its shared STAT. Carry the resolved
			# colour across the worker boundary so construction can make a small,
			# per-instance material override without defeating raw mesh caching.
			result["emittance_color"] = emittance_data["color"]
	var lod_geometry := _resolve_lod_geometry(placement, model, ctx.resolver)
	if not lod_geometry.is_empty():
		result["lod_geometry"] = lod_geometry
	# The single positive-eligibility gate construct_from_resolved() checks
	# before ever considering DirectGeometryBatch -- deliberately a named
	# concept computed once here, not separate ad hoc checks accumulating at
	# the construct site (the exact "bolt another exception on" pattern
	# issue #44 rejected for the batch-default in the first place). Extend
	# this line, not the construct-site branch, if a third disqualifying
	# reason ever comes up.
	result["ineligible_for_batching"] = result.get("animated", false) or result.get("skinned", false) or result.has("emittance_color")
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

func _resolve_item(placement: Dictionary, ctx: GamebryoResolveContext) -> Dictionary:
	var visual := _resolve_visual(placement, ctx, String(placement.get("base_type", "")))
	if visual["kind"] == "skip":
		return visual
	visual["kind"] = "item"
	visual["item_data"] = ctx.esm.get_item_data(int(placement.get("base_form_id", 0)))
	return visual

func _resolve_terminal(placement: Dictionary, ctx: GamebryoResolveContext) -> Dictionary:
	var visual := _resolve_visual(placement, ctx, "TERM")
	if visual["kind"] == "skip":
		return visual
	visual["terminal_data"] = ctx.esm.get_terminal_data(int(placement.get("base_form_id", 0)))
	return visual

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
		"item":
			return _construct_item(result)
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
					# issue #44: ineligible_for_batching (_resolve_visual()'s own
					# single positive-eligibility gate -- animated OR XEMI-tinted
					# today) decides ONLY whether this can go in DirectGeometryBatch
					# at all. `animated` is then consulted separately, purely to pick
					# WHICH real-Node shape an ineligible placement needs: an
					# animated one needs the real scene_nodes hierarchy
					# _construct_door() already proves works (dynamic children +
					# AnimationPlayer -- _construct_visual()'s flattened mesh has no
					# preserved per-node pivots for a track to target), while any
					# other ineligible reason (XEMI today) just needs an ordinary
					# Node instead of a shared-material batch entry.
					if result.get("ineligible_for_batching", false):
						if result.get("skinned", false):
							return _construct_skinned_visual(result)
						if result.get("animated", false):
							return _autoplay_special_idle(_construct_animated_visual(result))
						return _construct_visual(GamebryoVisual, result)
					# Issue #56: a VWD-flagged placement with a real lod_geometry
					# companion, OR one whose REFR carries the XSRF/XSRD
					# "distant skyline stand-in" marker (Strip wall / McCarran
					# skyline imposters -- ReferencePlacement::
					# has_distant_skyline_marker's own doc comment,
					# native/src/esm/esm_types.h), is ALSO routed to the
					# real-Node path, never DirectGeometryBatch --
					# DirectGeometryBatch groups every placement of a shared
					# mesh across a whole tile into ONE MultiMesh RenderingServer
					# instance with ONE shared visibility_range, and Godot
					# measures that range's distance from the camera to the
					# COMBINED instance AABB's center, not to each individual
					# placement. For repeated/spread-out meshes (e.g. the Strip
					# perimeter wall's segments, or its skyline imposters) that
					# broke the LOD/near-fade crossover: standing right next to
					# one instance doesn't put you near the combined AABB's
					# center, so the low-detail/imposter mesh never actually hid
					# up close (the real bug behind issue #56 -- confirmed
					# against real ESM data). The Node-based path gives every
					# placement its own MeshInstance3D with its own correctly-
					# measured visibility_range, so this is a correctness fix,
					# not a perf-neutral style choice.
					if not result.get("lod_geometry", {}).is_empty() or bool(result.get("placement", {}).get("has_distant_skyline_marker", false)):
						return _construct_visual(GamebryoVisual, result)
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
	resolver.populate_mesh_children(node, null, "", geometry, bool(result.get("placement", {}).get("has_distant_skyline_marker", false)))
	if result.has("emittance_color"):
		_apply_emittance_tint(node, result["emittance_color"])
	resolver.populate_collision_children(node, null, "", geometry)
	node = _finalize(node, result["placement"])
	if node is TerminalNode:
		node.configure_terminal(result.get("terminal_data", {}))
	return node

## XEMI is an authored colour link on a REFR. Duplicate only the final
## material Resource for this one visual; mesh/texture decoding stays shared.
## Using material_override preserves its real alpha mode and vertex alpha.
func _apply_emittance_tint(node: Node3D, tint: Color) -> void:
	for child in node.get_children():
		if child is MeshInstance3D and child.get_meta("gamebryo_is_unlit", false):
			var source: Material = child.mesh.surface_get_material(0)
			if source != null:
				var material := source.duplicate() as Material
				if material is StandardMaterial3D:
					var standard := material as StandardMaterial3D
					var effect := ShaderMaterial.new()
					effect.shader = XEMI_NO_LIGHTING_OPAQUE_SHADER if standard.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED else XEMI_NO_LIGHTING_SHADER
					effect.set_shader_parameter("albedo_texture", standard.albedo_texture)
					effect.set_shader_parameter("use_albedo_texture", standard.albedo_texture != null)
					# RCLR uses the same packed Gamebryo modulation convention as
					# LIGH.DATA: preserve its byte values as linear light before the
					# source_color shader uniform converts them for Godot.
					effect.set_shader_parameter("emittance_tint", tint.linear_to_srgb())
					effect.set_shader_parameter("emission_energy", xemi_no_lighting_emission_energy)
					material = effect
					child.set_meta("gamebryo_xemi_emission", true)
					child.set_meta("gamebryo_xemi_tint", tint)
				elif material is ShaderMaterial:
					# Existing specialised NoLighting shaders (light cookies/rays)
					# expose the same source_color uniform. Keep the XEMI RCLR
					# convention consistent with ordinary window backings.
					material.set_shader_parameter("emittance_tint", tint.linear_to_srgb())
				else:
					continue
				child.material_override = material
		if child is Node3D:
			_apply_emittance_tint(child, tint)

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

## issue #44: the same real scene_nodes hierarchy + AnimationPlayer
## _construct_door() builds above, for a placement that reached this via
## the structural-fallback branch but was flagged `animated` by
## _resolve_visual() (a real NiControllerSequence, not just a base_type
## that's always Dynamic like DOOR). No destination/door-data -- those are
## DOOR-specific, not part of what "animated" means here.
func _construct_animated_visual(result: Dictionary) -> Node3D:
	var node := GamebryoVisual.new()
	var nif: NifReader = result.get("nif")
	var geometry := resolver.build_geometry_entries(result.get("geometry", {}), result.get("lod_geometry", {}))
	var built := resolver.populate_dynamic_children(node, nif, "", geometry)
	if result.has("emittance_color"):
		_apply_emittance_tint(node, result["emittance_color"])
	resolver.populate_animation_player(node, nif, built)
	return _finalize(node, result["placement"])

## Issues #46/#47: the same real Skeleton3D/Skin/blend-shape construction
## nif_viewer.tscn's "Skinned - ..." presets already exercise, for a
## placement that reached this via the structural-fallback branch but was
## flagged `skinned` by _resolve_visual() -- real skeletal skinning data
## present (a humanoid/creature body, or -- the real case that surfaced
## this path, the Goodsprings NV_Nevadaflag.NIF -- a skinned+morphed prop).
## Deliberately NOT _construct_animated_visual()'s rigid Node-per-NiAVObject
## hierarchy (no bone data at all) or _construct_visual()'s flattened
## single-transform-per-submesh path -- see populate_skeleton()'s own doc
## comment for why skinning needs a genuinely separate construction path.
## `model_path` is threaded through for real (not "" like the other
## _construct_*() functions above pass when they already have a pre-built
## `geometry`) since populate_skeleton() resolves its own raw geometry
## internally rather than accepting one, and needs a real path for its own
## per-submesh mesh cache keys to actually be shared across repeat
## placements of the same base object.
func _construct_skinned_visual(result: Dictionary) -> Node3D:
	var node := GamebryoVisual.new()
	var nif: NifReader = result.get("nif")
	var model_path: String = String(result["placement"].get("model", ""))
	resolver.populate_skeleton(node, nif, model_path)
	if result.has("emittance_color"):
		_apply_emittance_tint(node, result["emittance_color"])
	return _autoplay_ambient_animations(_finalize(node, result["placement"]))

## Autoplay convention confirmed against real data (issue #44 comments):
## every ambient/idle-animated NIF sampled so far (a spinning windmill, the
## Goodsprings saloon sign) has exactly one sequence, always literally
## named "SpecialIdle", always cycleType=Loop -- distinct from a
## trigger-only object's sequences named for the action itself (a door's
## Open/Close). Only that exact name autoplays; anything else gets a real,
## populated AnimationPlayer with nothing wired up to trigger it yet --
## the same "correct but visually inert until a real trigger exists" gap
## _toggle_swing() fills for doors specifically, not a bug here.
func _autoplay_special_idle(node: Node3D) -> Node3D:
	if node == null:
		return null
	var player := node.get_node_or_null("AnimationPlayer") as AnimationPlayer
	if player != null and player.has_animation("SpecialIdle"):
		player.play("SpecialIdle")
	return node

## Issues #46/#47's own counterpart to _autoplay_special_idle() above, for
## populate_skeleton()'s two AnimationPlayers (MorphAnimationPlayer/
## SkeletonAnimationPlayer) -- neither is named "AnimationPlayer" nor plays
## a clip named "SpecialIdle" (confirmed real: the Nevada flag's own clips
## are literally named "Idle" and "Morph", the latter not even a name
## sourced from the NIF at all -- see populate_skeleton()'s own doc
## comment), so that function's exact-name matching can't and shouldn't be
## reused here. A general rule instead, using data already extracted
## rather than a second hardcoded name only one real sample could confirm:
## LOOP_LINEAR is this codebase's own established distinction for "ambient,
## always-playing" animation (see populate_animation_player()'s doc
## comment) vs LOOP_NONE for one-shot/triggered clips (a door's Open/Close)
## -- a skinned placement has no interaction/trigger mechanism of its own
## the way a door does, so every looping clip on it is autoplayed
## unconditionally, whichever player and whatever it's named.
func _autoplay_ambient_animations(node: Node3D) -> Node3D:
	if node == null:
		return null
	for child in node.get_children():
		if not (child is AnimationPlayer):
			continue
		var player: AnimationPlayer = child
		for anim_name in player.get_animation_list():
			var anim: Animation = player.get_animation(anim_name)
			if anim != null and anim.loop_mode == Animation.LOOP_LINEAR:
				player.play(anim_name)
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

func _construct_item(result: Dictionary) -> Node3D:
	var item_data: Dictionary = result.get("item_data", {})
	if item_data.is_empty(): return null
	item_data["model_path"] = result["placement"].get("model", "")
	item_data["base_type"] = result["placement"].get("base_type", "")
	var node := ItemNode.new()
	node.configure_item(item_data, int(result["placement"].get("base_form_id", 0)))
	var geometry := resolver.build_geometry_entries(result.get("geometry", {}))
	if result["placement"].get("base_type", "") == "KEYM":
		# Keys/keycards are pickup-only inventory objects, not loose Havok
		# props. Static collision keeps them selectable without shove/drag.
		resolver.populate_mesh_children(node, null, "", geometry)
		resolver.populate_collision_children(node, null, "", geometry)
		return _finalize(node, result["placement"])
	# Weight is only a loose placeholder mass until Phase 4 reads bhk mass.
	node.attach_rigid_body(resolver.populate_rigid_body_children(node, geometry, max(float(item_data.get("weight", 0.1)), 0.05)))
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
	# Issue #56: a placement whose REFR carries the XSRF/XSRD "distant
	# skyline stand-in" marker (Strip wall / McCarran skyline imposters
	# etc, see ReferencePlacement::has_distant_skyline_marker's own doc
	# comment, native/src/esm/esm_types.h) gets a near-fade cutoff instead
	# of the ordinary LOD0/LOD1 crossover. In practice construct_from_
	# resolved() already routes these to the Node-based path before this
	# function is ever reached (same reasoning as the lod_geometry case --
	# DirectGeometryBatch's per-tile MultiMesh batching breaks per-
	# placement visibility_range for spread-out repeated meshes), so this
	# is defense-in-depth for a caller that reaches _construct_direct()
	# some other way.
	var is_distant_tile := bool(placement.get("has_distant_skyline_marker", false))
	batch.add_object(world_transform, geometry["mesh_entries"], geometry["shape_entries"], geometry.get("lod_mesh_entries", []), is_distant_tile)

func _register_defaults() -> void:
	register("DOOR", func(p, r): return _build_door(p, r))
	register("CONT", func(p, r): return _instantiate_visual(ContainerNode, p, r))
	register("ACTI", func(p, r): return _instantiate_visual(ActivatorNode, p, r))
	register("FURN", func(p, r): return _instantiate_visual(FurnitureNode, p, r))
	register("TACT", func(p, r): return _instantiate_visual(TalkingActivatorNode, p, r))
	register("TERM", func(p, r): return _build_terminal(p, r))
	register("MSTT", func(p, r): return _instantiate_visual(MovableStaticNode, p, r))
	register("MISC", func(p, r): return _build_item(p, r))
	register("KEYM", func(p, r): return _build_item(p, r))
	register("ALCH", func(p, r): return _build_item(p, r))
	register("WEAP", func(p, r): return _build_item(p, r))
	register("SCOL", func(p, r): return _build_scol(p, r))
	register("LIGH", func(p, r): return _build_light(p, r))
	# Every other Tier 1 type (ARMO/AMMO/BOOK/NOTE/TREE/CCRD/IMOD/CMNY) is
	# deliberately NOT registered — they share
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
	mesh_resolver.populate_mesh_children(node, nif, model, geometry, bool(placement.get("has_distant_skyline_marker", false)))
	var emittance_form_id: int = int(placement.get("emittance_form_id", 0))
	if emittance_form_id != 0:
		var emittance_data: Dictionary = esm.get_emittance_data(emittance_form_id)
		if not emittance_data.is_empty():
			_apply_emittance_tint(node, emittance_data["color"])
	mesh_resolver.populate_collision_children(node, nif, model, geometry)
	return _finalize(node, placement)

func _build_terminal(placement: Dictionary, mesh_resolver: GamebryoMeshResolver) -> Node3D:
	var node := _instantiate_visual(TerminalNode, placement, mesh_resolver) as TerminalNode
	if node == null:
		return null
	node.configure_terminal(esm.get_terminal_data(int(placement.get("base_form_id", 0))))
	return node

func _build_item(placement: Dictionary, mesh_resolver: GamebryoMeshResolver) -> Node3D:
	var data: Dictionary = esm.get_item_data(int(placement.get("base_form_id", 0)))
	if data.is_empty(): return null
	var model: String = placement.get("model", "")
	if model == "": return null
	var nif := mesh_resolver.load_nif(model)
	if nif == null or nif.get_submesh_count() == 0: return null
	data["model_path"] = model
	data["base_type"] = placement.get("base_type", "")
	var node := ItemNode.new()
	node.configure_item(data, int(placement.get("base_form_id", 0)))
	var geometry := mesh_resolver.build_geometry_entries(mesh_resolver.resolve_raw_geometry(nif, model))
	if placement.get("base_type", "") == "KEYM":
		mesh_resolver.populate_mesh_children(node, nif, model, geometry)
		mesh_resolver.populate_collision_children(node, nif, model, geometry)
		return _finalize(node, placement)
	node.attach_rigid_body(mesh_resolver.populate_rigid_body_children(node, geometry, max(float(data.get("weight", 0.1)), 0.05)))
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

## Issues #46/#47's synchronous-build() counterpart to _construct_skinned_
## visual() (same signature convention as _instantiate_visual()/
## _instantiate_dynamic() above) -- real Skeleton3D/Skin/blend-shape
## construction (populate_skeleton()) for a placement whose NIF carries
## real skeletal skinning data, instead of _instantiate_dynamic()'s rigid
## Node-per-NiAVObject hierarchy (no bone data) or _instantiate_visual()'s
## flattened Static path.
func _instantiate_skinned(cls, placement: Dictionary, mesh_resolver: GamebryoMeshResolver) -> Node3D:
	var model: String = placement.get("model", "")
	if model == "":
		return null
	var nif := mesh_resolver.load_nif(model)
	if nif == null or nif.get_submesh_count() == 0:
		return null
	var node = cls.new()
	mesh_resolver.populate_skeleton(node, nif, model)
	return _autoplay_ambient_animations(_finalize(node, placement))

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
	# LIGH.DATA is packed 8-bit Gamebryo light modulation, not a Godot color
	# property. Godot's Light3D expects nonlinear sRGB and linearizes it for
	# lighting; treating the authored bytes as sRGB therefore applies an extra
	# gamma curve and makes the real warm office rig unnaturally yellow/green.
	# Preserve the authored component balance as linear light, then encode only
	# at Godot's Light3D API boundary.
	var authored_color: Color = light_data.get("color", Color.WHITE)
	var color: Color = authored_color.linear_to_srgb() if ligh_bytes_are_linear else authored_color
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
	# LIGH.DATA has no separate intensity field: its authored RGB luminance is
	# the source strength.  Do not multiply every ambient/fill/key/kicker by a
	# fabricated global energy value; Godot's default 1.0 preserves that
	# relative authored intensity through the active HDR/tonemap pipeline.
	light.light_energy = 1.0
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
