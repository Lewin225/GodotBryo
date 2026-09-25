@tool
class_name EsmNode
extends Node3D

## The desired paired-model tier. This is per placement, rather than state on
## the shared EsmBase, because WorldStreamer chooses it from tile residency.
enum VisualDetail {
	FULL,
	LOD,
}

signal visual_detail_applied(detail: int)

## Runtime representation of one ESM reference. The reference is the only ESM
## data entry point; visual content is generated asynchronously by NifServer
## after this node enters either an editor or runtime scene tree.

@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EsmReference", PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var reference: EsmReference:
	set(value):
		reference = value
		_request_generation += 1
		_startup_complete = false
		_waiting_for_esm = false
		_active_visual_detail = -1
		_clear_generated_children()
		_reference_changed()

## The requested asset tier. Setting this does not hide the current visual:
## the old tree remains in place until NifServer delivers the requested tree.
## This makes LOD/full handover safe when callbacks are intentionally paced
## over many frames.
@export var visual_detail: VisualDetail = VisualDetail.FULL:
	set(value):
		if visual_detail == value:
			return
		visual_detail = value
		_request_generation += 1
		if is_inside_tree() and _startup_complete and _should_request_nif():
			_request_visual()

var _waiting_for_esm := false
var _startup_complete := false
var _request_generation := 0
## The tier actually represented by a live NIF child, or -1 while absent.
var _active_visual_detail := -1
var _generated_children: Array[Node] = []
const GAMEBRYO_TO_GODOT_BASIS := Basis(Vector3.RIGHT, -PI / 2.0)

## Recursively toggles every CollisionShape3D in a subtree.
##
## Streamers use this to keep a tile's collision inert while it is still being
## built, and to drop collision for paused content without tearing the nodes
## down. Static because it walks whatever subtree it is handed, including the
## NIF-generated children that are not EsmNodes themselves.
static func set_collision_disabled(node: Node, disabled: bool) -> void:
	if node is CollisionShape3D:
		node.disabled = disabled
	for child in node.get_children():
		set_collision_disabled(child, disabled)


## Default activation hook for all physicalized ESM nodes.
## Type-specific nodes override this for their native default behavior.
func activate(_actor: Node = null) -> Dictionary:
	return {}

func _ready() -> void:
	call_deferred("_rehydrate_and_start")

func configure(esm_reference: EsmReference) -> void:
	reference = esm_reference

## Compatibility hook for specialized nodes such as EsmHumanoidActor. Normal nodes
## start the shared NifServer lifecycle; specialized nodes may replace it.
func _reference_changed() -> void:
	if is_inside_tree():
		call_deferred("_rehydrate_and_start")

## Returns the live world transform used by gameplay. Static ESM nodes use
## their own transform; physical nodes can override this when they acquire a
## future dedicated physical representation.
func get_runtime_global_transform() -> Transform3D:
	return global_transform if is_inside_tree() else transform

func get_runtime_global_position() -> Vector3:
	return get_runtime_global_transform().origin

## Compact identity data for runtime diagnostics such as DebugHud. This stays
## on the semantic node, not its asynchronously-delivered NIF child, so it is
## available before a visual arrives and after it is replaced.
func get_debug_description() -> String:
	if reference == null:
		return "reference: <unassigned>"
	var lines := PackedStringArray()
	lines.append("reference: %s" % reference.instance_id)
	if reference.base == null:
		lines.append("base: 0x%08X (unresolved)" % reference.base_form_id)
		return "\n".join(lines)
	var base := reference.base
	lines.append("base: %s 0x%08X" % [base.record_type, base.form_id])
	if not base.full_name.is_empty():
		lines.append("name: %s" % base.full_name)
	if not base.editor_id.is_empty():
		lines.append("editor ID: %s" % base.editor_id)
	if "model_path" in base and not String(base.model_path).is_empty():
		lines.append("model: %s" % base.model_path)
	return "\n".join(lines)

## Returns this placement in authored Gamebryo REFR space. Physicaliser keeps
## the Resource authored, but presents its node in Godot space as C*T*C^-1;
## save/dirty code must compare through this accessor rather than global space.
func get_authored_transform() -> Transform3D:
	var runtime := global_transform if is_inside_tree() else transform
	if not has_meta("gamebryo_placement_space"):
		return runtime
	var conversion := Transform3D(GAMEBRYO_TO_GODOT_BASIS, Vector3.ZERO)
	return conversion.affine_inverse() * runtime * conversion

## Typed nodes use this to add editor/runtime-generated children. These
## children are owned recursively in the editor so they appear in the Scene
## dock and can be inspected. Runtime-generated children remain unowned.
func add_generated_child(child: Node) -> void:
	if child == null:
		return
	child.set_meta("esm_generated", true)
	add_child(child)
	_generated_children.append(child)
	if Engine.is_editor_hint() and owner != null:
		_set_owner_recursive(child, owner)

## Returns the first animation player supplied by the generated NIF tree.
func get_nif_animation_player() -> AnimationPlayer:
	var visual := get_node_or_null("NifVisual")
	if visual == null:
		return null
	return visual.find_child("AnimationPlayer", true, false) as AnimationPlayer

## Hook for typed semantic setup once reference.base is available. It runs
## before the NIF request, so semantic state exists while visual delivery is
## paced by NifServer.
func _on_reference_ready() -> void:
	pass

## SCOL and non-world preview nodes override this to suppress the generic
## model request and create their own generated children instead.
func _should_request_nif() -> bool:
	return true

func _model_path() -> String:
	if reference == null or reference.base == null or not ("model_path" in reference.base):
		return ""
	return String(reference.base.model_path)

func _rehydrate_and_start() -> void:
	if not is_inside_tree() or reference == null or _startup_complete:
		return
	var server := get_tree().root.get_node_or_null("EsmServer")
	if reference.base == null and server != null:
		if not server.is_ready():
			if not _waiting_for_esm:
				_waiting_for_esm = true
				server.esm_ready.connect(_on_esm_ready, CONNECT_ONE_SHOT)
			return
		var hydrated: EsmReference = null
		if not reference.instance_id.is_empty():
			hydrated = server.get_reference(reference.instance_id)
		if hydrated == null and reference.base_form_id != 0:
			hydrated = server.create_reference_for_base(reference.base_form_id)
		if hydrated != null:
			reference = hydrated
			return
	if reference.base == null:
		return

	_startup_complete = true
	_on_reference_ready()
	if _should_request_nif():
		_request_visual()

## Starts the desired exact NIF request. The full/LOD choice is the only
## difference; NifServer owns all parsing, caching and callback pacing.
func _request_visual() -> void:
	var visual_name := _visual_node_name(visual_detail)
	# An editor-saved scene may already contain this generated visual tree.
	# Reuse it rather than appending a second copy after reopening the scene.
	if get_node_or_null(visual_name) != null:
		_active_visual_detail = visual_detail
		return
	var model_path := _model_path()
	if model_path.is_empty():
		return
	var nif_server := get_tree().root.get_node_or_null("NifServer")
	if nif_server == null:
		push_warning("EsmNode: NifServer autoload is unavailable for %s" % model_path)
		return
	var generation := _request_generation
	if visual_detail == VisualDetail.LOD:
		nif_server.request_lod(model_path, self, _on_nif_ready.bind(generation, VisualDetail.LOD))
	else:
		nif_server.request(model_path, self, _on_nif_ready.bind(generation, VisualDetail.FULL))

func _on_nif_ready(tree: Node3D, generation: int, detail: VisualDetail) -> void:
	if generation != _request_generation or detail != visual_detail or not is_inside_tree():
		if tree != null:
			tree.queue_free()
		return
	if tree == null:
		return
	tree.name = _visual_node_name(detail)
	add_generated_child(tree)
	_apply_containing_stream_state(tree)
	var replaced_detail: VisualDetail = VisualDetail.LOD if detail == VisualDetail.FULL else VisualDetail.FULL
	var replaced := _visual_node(replaced_detail)
	if replaced != null:
		_remove_generated_child(replaced)
	_active_visual_detail = detail
	visual_detail_applied.emit(detail)
	if detail == VisualDetail.FULL:
		_on_nif_visual_ready(tree)

func _visual_node_name(detail: VisualDetail) -> String:
	return "NifVisual" if detail == VisualDetail.FULL else "NifLodVisual"

func _visual_node(detail: VisualDetail) -> Node3D:
	return get_node_or_null(_visual_node_name(detail)) as Node3D

## Typed nodes can inspect NifServer's collision/animation hierarchy here.
## XSRF/XSRD-marked persistent props are standalone skyline stand-ins, not
## paired LOD assets. They retain their authored full tree, are visible only
## beyond the established near cutoff, and never contribute invisible physics.
func _on_nif_visual_ready(tree: Node3D) -> void:
	if reference == null or not reference.has_xsrf_or_xsrd:
		return
	var near_cutoff := 300.0
	var near_margin := 20.0
	var root := get_tree().root if is_inside_tree() and get_tree() != null else null
	var settings := root.get_node_or_null("GodotBryoSettings") if root != null else null
	if settings != null:
		near_cutoff = float(settings.get("distant_lod_near_cutoff_m"))
		near_margin = float(settings.get("distant_lod_near_margin_m"))
	for mesh in tree.find_children("*", "MeshInstance3D", true, false):
		var instance := mesh as MeshInstance3D
		instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		instance.visibility_range_begin = near_cutoff
		instance.visibility_range_begin_margin = near_margin
		instance.visibility_range_end = 0.0
	set_collision_disabled(tree, true)

func _clear_generated_children() -> void:
	var children_to_clear: Array[Node] = _generated_children.duplicate()
	for child in get_children():
		if child.has_meta("esm_generated") and not children_to_clear.has(child):
			children_to_clear.append(child)
	for child in children_to_clear:
		if is_instance_valid(child):
			if child.get_parent() == self:
				remove_child(child)
			child.queue_free()
	_generated_children.clear()

func _remove_generated_child(child: Node) -> void:
	_generated_children.erase(child)
	if child.get_parent() == self:
		remove_child(child)
	child.queue_free()

func _set_owner_recursive(node: Node, scene_owner: Node) -> void:
	node.owner = scene_owner
	for child in node.get_children():
		_set_owner_recursive(child, scene_owner)

## A streamed tile can be paused while this node is waiting for its NIF
## callback. Apply the owning streamer's state before this subtree is live.
func _apply_containing_stream_state(node: Node) -> void:
	var ancestor := get_parent()
	while ancestor != null:
		if ancestor.has_method("apply_streaming_state_to_subtree"):
			ancestor.apply_streaming_state_to_subtree(node)
			return
		ancestor = ancestor.get_parent()

func _on_esm_ready() -> void:
	_waiting_for_esm = false
	_reference_changed()
