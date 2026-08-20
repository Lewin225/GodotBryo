class_name GamebryoObjectRegistry
extends RefCounted

## type_tag -> factory registry (phases/1/01-object-type-registry.md /
## phases/1/architecture.md's "Registry extensibility"). Runtime-populated,
## not a compiled switch — adding a type is one register() call, nothing
## else changes.

var resolver: GamebryoMeshResolver
var esm: EsmReader
var _factories := {} # String -> Callable(Dictionary, GamebryoMeshResolver) -> Node3D

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

## phases/2/09-direct-server-static-geometry.md: true for exactly the
## placements build()'s own third tier handles -- no registered factory for
## its base_type, not a marker, but has a resolvable model. Exposed
## separately (not just inlined into build_direct() below) so a caller can
## check "does this placement even need the RID path" without also paying
## for NIF loading if it turns out not to.
func is_structural_fallback(placement: Dictionary) -> bool:
	if MarkerNode.is_marker_model(placement.get("model", "")):
		return false
	if _factories.has(String(placement.get("base_type", ""))):
		return false
	return String(placement.get("model", "")) != ""

## The RID-based equivalent of build() for exactly the structural-fallback
## tier (is_structural_fallback() above) -- everything else (interactive
## registered types, markers) still goes through build() as a real Node;
## this is deliberately narrower, not a general replacement. Returns false
## if the placement isn't a structural-fallback candidate at all, or its
## model fails to resolve/has no submeshes (mirrors _instantiate_visual()'s
## own null-return case) -- either way, the caller should treat that as
## "nothing to place", the same meaning build() returning null already has.
func build_direct(placement: Dictionary, batch: DirectGeometryBatch) -> bool:
	if not is_structural_fallback(placement):
		return false
	var model: String = placement.get("model", "")
	var nif := resolver.load_nif(model)
	if nif == null or nif.get_submesh_count() == 0:
		return false
	var geometry: Dictionary = resolver.resolve_geometry_entries(nif, model)
	var pos: Vector3 = placement.get("position", Vector3.ZERO)
	var rot: Vector3 = placement.get("rotation", Vector3.ZERO)
	var scale: float = placement.get("scale", 1.0)
	var world_transform := GamebryoMeshResolver.world_transform_no_parent(pos, rot, scale)
	batch.add_object(world_transform, geometry["mesh_entries"], geometry["shape_entries"])
	return true

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
## than driven by _factories (already listed once in _register_defaults(),
## and implicitly a second time in is_structural_fallback()'s own "not
## registered" check) -- a third, bounded occurrence of a 6-case list that's
## been stable since Phase 1, not a maintenance burden worth a shared-Callable
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
##   "visual" -- { placement, type_tag (one of CONT/ACTI/FURN, or "" for the
##               structural-fallback/GamebryoVisual case), geometry }
##   "skip"   -- { placement } only -- mirrors build() returning null (no
##               model, unparseable NIF, or a LIGH with neither mesh nor
##               light data resolved)
func resolve_placement(placement: Dictionary, ctx: GamebryoResolveContext) -> Dictionary:
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
		"CONT", "ACTI", "FURN":
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
func resolve_tile(refs: Array, ctx: GamebryoResolveContext) -> Array:
	var out: Array = []
	for p in refs:
		out.append(resolve_placement(p, ctx))
	return out

func _resolve_visual(placement: Dictionary, ctx: GamebryoResolveContext, type_tag: String) -> Dictionary:
	var model: String = placement.get("model", "")
	if model == "":
		return { "kind": "skip", "placement": placement }
	var nif := ctx.resolver.load_nif(model)
	if nif == null or nif.get_submesh_count() == 0:
		return { "kind": "skip", "placement": placement }
	var geometry := ctx.resolver.resolve_geometry_entries(nif, model)
	return { "kind": "visual", "type_tag": type_tag, "geometry": geometry, "placement": placement }

func _resolve_door(placement: Dictionary, ctx: GamebryoResolveContext) -> Dictionary:
	var visual := _resolve_visual(placement, ctx, "DOOR")
	if visual["kind"] == "skip":
		return visual
	var refr_form_id := int(placement.get("refr_form_id", 0))
	visual["kind"] = "door"
	visual["destination"] = ctx.esm.get_door_destination(refr_form_id)
	return visual

func _resolve_scol(placement: Dictionary, ctx: GamebryoResolveContext) -> Dictionary:
	var parts: Array = ctx.esm.get_scol_parts(int(placement.get("base_form_id", 0)))
	var resolved_parts: Array = []
	for part in parts:
		resolved_parts.append(resolve_placement(part, ctx))
	return { "kind": "scol", "placement": placement, "parts": resolved_parts }

func _resolve_light(placement: Dictionary, ctx: GamebryoResolveContext) -> Dictionary:
	var geometry: Dictionary = {}
	var model: String = placement.get("model", "")
	if model != "":
		var nif := ctx.resolver.load_nif(model)
		if nif != null and nif.get_submesh_count() > 0:
			geometry = ctx.resolver.resolve_geometry_entries(nif, model)
	var light_data: Dictionary = ctx.esm.get_light_data(int(placement.get("base_form_id", 0)))
	if geometry.is_empty() and light_data.is_empty():
		return { "kind": "skip", "placement": placement }
	return { "kind": "light", "geometry": geometry, "light_data": light_data, "placement": placement }

func _register_defaults() -> void:
	register("DOOR", func(p, r): return _build_door(p, r))
	register("CONT", func(p, r): return _instantiate_visual(ContainerNode, p, r))
	register("ACTI", func(p, r): return _instantiate_visual(ActivatorNode, p, r))
	register("FURN", func(p, r): return _instantiate_visual(FurnitureNode, p, r))
	register("SCOL", func(p, r): return _build_scol(p, r))
	register("LIGH", func(p, r): return _build_light(p, r))
	# Every other Tier 1 type (WEAP/ARMO/AMMO/BOOK/KEYM/ALCH/NOTE/TREE/MSTT/
	# TACT/TERM/CCRD/IMOD/CMNY) is deliberately NOT registered — they share
	# the plain GamebryoVisual shape (confirmed identical EDID/OBND/MODL
	# structure per phases/1/architecture.md's evidence table) and fall
	# through to build()'s structural fallback tier. This exercises that
	# fallback with real, common data instead of only via a contrived test.

func _instantiate_visual(cls, placement: Dictionary, mesh_resolver: GamebryoMeshResolver) -> Node3D:
	var model: String = placement.get("model", "")
	if model == "":
		return null
	var nif := mesh_resolver.load_nif(model)
	if nif == null or nif.get_submesh_count() == 0:
		return null
	var node = cls.new()
	var geometry := mesh_resolver.resolve_geometry_entries(nif, model)
	mesh_resolver.populate_mesh_children(node, nif, model, geometry)
	mesh_resolver.populate_collision_children(node, nif, model, geometry)
	return _finalize(node, placement)

## DOOR: same shape as any other _instantiate_visual type, plus its teleport
## destination (if any) resolved once here — phases/2/07-runtime-cell-loader.md
## — rather than looked up lazily on interaction.
func _build_door(placement: Dictionary, mesh_resolver: GamebryoMeshResolver) -> Node3D:
	var node := _instantiate_visual(DoorNode, placement, mesh_resolver)
	if node is DoorNode:
		node.resolve_destination(esm)
	return node

## MARKER: identity + transform only, deliberately no mesh/collision (see
## MarkerNode's doc comment) — the inherited StaticBody3D has no shape
## attached, so it's inert. marker_kind is the model's own basename, the
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
			var geometry := mesh_resolver.resolve_geometry_entries(nif, model)
			mesh_resolver.populate_mesh_children(node, nif, model, geometry)
			mesh_resolver.populate_collision_children(node, nif, model, geometry)

	var light_data: Dictionary = esm.get_light_data(int(placement.get("base_form_id", 0)))
	if not light_data.is_empty():
		var radius: float = max(float(light_data.get("radius", 5.0)), 0.1)
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
			light = spot
		else:
			light = OmniLight3D.new()
			light.omni_range = radius

		light.name = "Light"
		light.light_color = color
		light.light_energy = 3.0 # approximate — see phases/1/03-light-sources.md
		light.visible = not bool(light_data.get("off_by_default", false))
		node.add_child(light)

	if node.get_child_count() == 0:
		return null # no mesh and no light data resolved — nothing to place
	return _finalize(node, placement)

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
	return node
