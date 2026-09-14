@tool
class_name EsmNode
extends Node3D

## Runtime representation of one ESM reference. The reference is the only ESM
## data entry point; visual content is generated asynchronously by NifServer
## after this node enters either an editor or runtime scene tree.

@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EsmReference", PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var reference: EsmReference:
	set(value):
		reference = value
		_request_generation += 1
		_startup_complete = false
		_waiting_for_esm = false
		_clear_generated_children()
		_reference_changed()

var _waiting_for_esm := false
var _startup_complete := false
var _request_generation := 0
var _generated_children: Array[Node] = []
## Retained for EsmNpcActor's separate legacy actor/equipment assembly path.
var _visual_built := false

## Default activation hook for all physicalized ESM nodes.
## Type-specific nodes override this for their native default behavior.
func activate(_actor: Node = null) -> Dictionary:
	return {}

func _ready() -> void:
	call_deferred("_rehydrate_and_start")

func configure(esm_reference: EsmReference) -> void:
	reference = esm_reference

## Compatibility hook for specialized nodes such as EsmNpcActor. Normal nodes
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
		_request_nif()

func _request_nif() -> void:
	# An editor-saved scene may already contain the generated visual tree.
	# Reuse it rather than appending a second copy after reopening the scene.
	if get_node_or_null("NifVisual") != null:
		return
	var model_path := _model_path()
	if model_path.is_empty():
		return
	var nif_server := get_tree().root.get_node_or_null("NifServer")
	if nif_server == null:
		push_warning("EsmNode: NifServer autoload is unavailable for %s" % model_path)
		return
	var generation := _request_generation
	nif_server.request(model_path, self, _on_nif_ready.bind(generation))

func _on_nif_ready(tree: Node3D, generation: int) -> void:
	if generation != _request_generation or not is_inside_tree():
		if tree != null:
			tree.queue_free()
		return
	if tree == null:
		return
	tree.name = "NifVisual"
	add_generated_child(tree)
	_on_nif_visual_ready(tree)

## Typed nodes can inspect NifServer's collision/animation hierarchy here.
func _on_nif_visual_ready(_tree: Node3D) -> void:
	pass

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

func _set_owner_recursive(node: Node, scene_owner: Node) -> void:
	node.owner = scene_owner
	for child in node.get_children():
		_set_owner_recursive(child, scene_owner)

func _on_esm_ready() -> void:
	_waiting_for_esm = false
	_reference_changed()
