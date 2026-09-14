@tool
class_name CellStreamerV2
extends Node3D

## Typed, interior-only single-cell streaming over:
## EsmServer -> EsmReferencePhysicaliser -> EsmNode -> NifServer.
##
## Population is deliberately the atomic boundary, not NIF completion.  A
## physicalised EsmNode is already the durable gameplay identity before its
## asynchronously paced visual arrives, so a fully populated hidden root can
## replace the old cell without making a transition wait on every NIF decode.

const PhysicaliserScript := preload("res://GodotBryo/Pipeline/esm_reference_physicaliser.gd")

signal load_started(cell_form_id: int)
signal load_progress(fraction: float)
signal load_completed(cell_form_id: int, success: bool)

const SPAWN_REFR := 1 << 0
const SPAWN_ACHR := 1 << 1
const SPAWN_CREA := 1 << 2

## Semantic nodes created per frame.  This budget applies only to typed
## reference construction; NifServer independently paces asset delivery.
@export var objects_per_frame := 20
## Interiors initially create ordinary REFRs only.  ACHR/CREA remain explicit
## opt-ins while their separate typed actor assembly paths mature.
@export_flags("REFR", "ACHR", "CREA") var spawn_reference_types := SPAWN_REFR

var esm_server: Node = null
var _physicaliser := PhysicaliserScript.new()
var _current: Node3D = null
var _current_refs: Array[EsmReference] = []
var _loading_root: Node3D = null
var _loading_refs: Array[EsmReference] = []
var _loading := false
var _generation := 0
var _job: Dictionary = {}
var _waiting_for_esm := false


func _ready() -> void:
	_resolve_esm_server()


func _process(_delta: float) -> void:
	if not _loading or _job.is_empty():
		return
	if int(_job.get("generation", -1)) != _generation:
		return
	var root := _job.get("root") as Node3D
	if root == null or not is_instance_valid(root):
		return
	var references: Array = _job.get("references", [])
	var next_index := int(_job.get("next_index", 0))
	var budget := maxi(1, objects_per_frame)
	while budget > 0 and next_index < references.size():
		var reference := references[next_index] as EsmReference
		next_index += 1
		if reference != null and _should_spawn(reference):
			# FULL is intentional: interior VWD/paired-LOD policy belongs only to
			# exterior tile residency, which this class deliberately does not own.
			_physicaliser.physicalise(reference, root, EsmNode.VisualDetail.FULL)
		budget -= 1
	_job["next_index"] = next_index
	load_progress.emit(float(next_index) / float(maxi(references.size(), 1)))
	if next_index >= references.size():
		_complete_population(int(_job.get("cell_form_id", 0)), root)


func load_cell(cell_form_id: int) -> void:
	_generation += 1
	var generation := _generation
	cancel_load(false)
	if not _esm_is_ready():
		# Do not construct a speculative legacy/fallback reader.  The typed
		# server is the source of typed bases and references.
		_job = {"generation": generation, "requested_cell_form_id": cell_form_id}
		_loading = true
		load_started.emit(cell_form_id)
		return
	if int(esm_server.reader.get_cell_worldspace(cell_form_id)) != -1:
		push_warning("CellStreamerV2: refusing exterior CELL 0x%X" % cell_form_id)
		load_started.emit(cell_form_id)
		load_completed.emit(cell_form_id, false)
		return
	_begin_load(cell_form_id, generation)


func cancel_load(advance_generation := true) -> void:
	if advance_generation:
		_generation += 1
	_loading = false
	_job.clear()
	_loading_refs.clear()
	if _loading_root != null and is_instance_valid(_loading_root):
		_loading_root.free()
	_loading_root = null


func unload_current() -> void:
	cancel_load()
	if _current != null and is_instance_valid(_current):
		_current.free()
	_current = null
	_current_refs.clear()


func is_loading() -> bool:
	return _loading


func get_current_cell_form_id() -> int:
	return int(_current.get_meta("cell_form_id", 0)) if _current != null and is_instance_valid(_current) else 0


func get_current_refs() -> Array[EsmReference]:
	return _current_refs.duplicate()


func find_ref_by_editor_id(editor_id: String) -> EsmReference:
	for reference in _current_refs:
		if reference != null and reference.base != null and reference.base.editor_id == editor_id:
			return reference
	return null


func find_ref_by_form_id(refr_form_id: int) -> EsmReference:
	var wanted := "authored:%08X" % refr_form_id
	for reference in _current_refs:
		if reference != null and reference.instance_id == wanted:
			return reference
	return null


## EsmNode calls this when a NIF arrives.  State is derived from the callback's
## actual ancestor, rather than a global "currently loading" boolean: the old
## CurrentCell must stay solid if one of *its* NIFs arrives while LoadingCell
## is still being populated.
func apply_streaming_state_to_subtree(node: Node) -> void:
	var loading_collision := _loading_root != null and is_instance_valid(_loading_root) \
		and (_loading_root == node or _loading_root.is_ancestor_of(node))
	CellStreamBuilder.set_collision_disabled(node, loading_collision)


func _begin_load(cell_form_id: int, generation: int) -> void:
	if generation != _generation:
		return
	_loading = true
	load_started.emit(cell_form_id)
	var root := Node3D.new()
	root.name = "LoadingCell"
	root.visible = false
	root.set_meta("cell_form_id", cell_form_id)
	add_child(root)
	_loading_root = root
	_loading_refs = esm_server.get_references_in_cell(cell_form_id)
	_job = {
		"generation": generation,
		"cell_form_id": cell_form_id,
		"root": root,
		"references": _loading_refs,
		"next_index": 0,
	}
	if _loading_refs.is_empty():
		_complete_population(cell_form_id, root)


func _complete_population(cell_form_id: int, root: Node3D) -> void:
	if not _loading or root != _loading_root or int(_job.get("generation", -1)) != _generation:
		return
	# The old root remains visible and solid through every semantic placement.
	# Only now expose and enable the replacement, then free the old sibling
	# before assigning CurrentCell so Godot cannot rename it on collision.
	CellStreamBuilder.set_collision_disabled(root, false)
	root.visible = true
	if _current != null and is_instance_valid(_current):
		_current.free()
	root.name = "CurrentCell"
	_current = root
	_current_refs = _loading_refs.duplicate()
	_loading_root = null
	_loading_refs.clear()
	_loading = false
	_job.clear()
	load_progress.emit(1.0)
	load_completed.emit(cell_form_id, true)


func _should_spawn(reference: EsmReference) -> bool:
	if reference is ActorReference:
		return (spawn_reference_types & SPAWN_ACHR) != 0
	if reference is CreatureReference:
		return (spawn_reference_types & SPAWN_CREA) != 0
	return (spawn_reference_types & SPAWN_REFR) != 0


func _resolve_esm_server() -> bool:
	if esm_server != null and is_instance_valid(esm_server):
		return true
	var root := get_tree().root if get_tree() != null else null
	esm_server = root.get_node_or_null("EsmServer") if root != null else null
	return esm_server != null


func _esm_is_ready() -> bool:
	if not _resolve_esm_server():
		return false
	if esm_server.has_method("is_ready") and esm_server.is_ready():
		return true
	if not _waiting_for_esm and esm_server.has_signal("esm_ready"):
		_waiting_for_esm = true
		esm_server.esm_ready.connect(_on_esm_ready, CONNECT_ONE_SHOT)
	return false


func _on_esm_ready() -> void:
	_waiting_for_esm = false
	if not _loading or _job.is_empty():
		return
	var cell_form_id := int(_job.get("requested_cell_form_id", 0))
	var generation := int(_job.get("generation", -1))
	if cell_form_id != 0:
		_begin_load(cell_form_id, generation)
