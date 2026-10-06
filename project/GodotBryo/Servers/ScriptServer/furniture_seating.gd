class_name FurnitureSeating
extends Node

## Seats an actor that uses furniture (ScriptServer.begin_use) and gets it up
## again (end_use), for any actor, on screen or off. A child of ScriptServer.
##
## The furniture's markers come from its NIF: NifServer's tree for the model
## holds one Marker3D per BSFurnitureMarker position (FurnitureMarker0, ... in
## file order), with the raw orientation and posRef in metadata. Read once per
## model and the tree freed: each marker's position in the furniture's
## placement space, its orientation in radians, and its marker ID (posRef),
## which GetFurnitureMarkerID reports and the idle tree's furniture items test.
##
## Seating moves the actor to the used marker, placed by the furniture's
## transform, facing the furniture's heading plus the marker's orientation (an
## inference from the census: which way the actor faces is not verified), and
## sets `ActorReference.sit_state` to 3 (sitting). Getting up sets it to 0 and
## leaves the actor at the marker. The states between (1 wants to sit, 2
## sitting down, 4 wants to stand, 5 standing up) are for the animated
## sequence; GetSitting's values are inferred (Plans/Actors/stage_g.md).

## ActorReference.sit_state values (GetSitting; inferred).
const NOT_SITTING := 0
const WANTS_TO_SIT := 1
const SITTING := 3

## Canonical NIF path -> Array of {"position" (Godot axes, metres, the
## furniture's placement space), "heading" (radians), "marker_id"}.
var _markers_by_model: Dictionary = {}
## Canonical NIF path -> the actors waiting for that NIF's markers.
var _waiting: Dictionary = {}

## `actor` has started using `furniture`: seats it once the markers are known.
func seat(actor: ActorReference, furniture: FurnitureReference) -> void:
	actor.sit_state = WANTS_TO_SIT
	var model := _model_key(furniture)
	if _markers_by_model.has(model):
		_place(actor, furniture)
		return
	# NifServer may answer at once (markers it already has), so the actor is
	# waiting before the request goes out.
	var first := not _waiting.has(model)
	if first:
		_waiting[model] = []
	_waiting[model].append(actor)
	if first:
		NifServer.request(model, self, _on_tree.bind(model))

## `actor` has stopped using furniture.
func stand(actor: ActorReference) -> void:
	actor.sit_state = NOT_SITTING

## The marker ID (posRef) of the marker `actor` uses, or 0 when it uses no
## furniture or its markers are not known yet.
func get_marker_id(actor: ActorReference) -> int:
	var furniture := actor.using as FurnitureReference
	if furniture == null:
		return 0
	var marker := get_marker(furniture, actor.using_marker)
	return int(marker.get("marker_id", 0))

## Marker `index` of `furniture`'s NIF: {"position" (Godot axes, metres, the
## furniture's placement space), "heading" (radians), "marker_id"}; empty when
## unknown.
func get_marker(furniture: FurnitureReference, index: int) -> Dictionary:
	var markers: Array = _markers_by_model.get(_model_key(furniture), [])
	if index < 0 or index >= markers.size():
		return {}
	return markers[index]

## Where a marker puts an actor in the world: {"position", "rotation"} in
## Gamebryo axes, metres; empty when the marker is unknown.
func get_placement(furniture: FurnitureReference, index: int) -> Dictionary:
	var marker := get_marker(furniture, index)
	if marker.is_empty():
		return {}
	var placement := EsmReferencePhysicaliser.placement_transform(furniture.position, furniture.rotation, furniture.scale)
	var world := EsmReferencePhysicaliser.GAMEBRYO_TO_GODOT_BASIS.inverse() * (placement * Vector3(marker["position"]))
	var heading := furniture.rotation.z + float(marker["heading"])
	return {"position": world, "rotation": Vector3(0.0, 0.0, heading)}

func _on_tree(tree: Node3D, model: String) -> void:
	var markers := _read_markers(tree) if tree != null else []
	if tree != null:
		tree.free()
	_markers_by_model[model] = markers
	for actor: ActorReference in _waiting.get(model, []):
		var furniture := actor.using as FurnitureReference
		if furniture != null and _model_key(furniture) == model:
			_place(actor, furniture)
	_waiting.erase(model)

func _place(actor: ActorReference, furniture: FurnitureReference) -> void:
	var placement := get_placement(furniture, actor.using_marker)
	if not placement.is_empty():
		ScriptServer.move_reference(actor, furniture.current_space_form_id, placement["position"], placement["rotation"])
	actor.sit_state = SITTING

## The tree's furniture markers in file order, placed in the space the tree is
## parented in (the furniture's placement space).
static func _read_markers(tree: Node3D) -> Array:
	var nodes := tree.find_children("FurnitureMarker*", "Marker3D", true, false)
	nodes.sort_custom(func(a: Node, b: Node) -> bool: return String(a.name).trim_prefix("FurnitureMarker").to_int() < String(b.name).trim_prefix("FurnitureMarker").to_int())
	var markers := []
	for node: Marker3D in nodes:
		var xform := node.transform
		var parent := node.get_parent()
		while parent != null:
			xform = (parent as Node3D).transform * xform
			parent = parent.get_parent()
		markers.append({
			"position": xform.origin,
			"heading": float(node.get_meta("nif_furniture_orientation", 0)) / 1000.0,
			"marker_id": int(node.get_meta("nif_furniture_position_reference_1", 0)),
		})
	return markers

static func _model_key(furniture: FurnitureReference) -> String:
	var base := furniture.base as FurnitureBase
	return NifServer.canonical(base.model_path) if base != null else ""
