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
## transform, facing the furniture's heading plus the marker's orientation: the
## marker is where the actor stands before sitting, facing the seat (the chair
## enter KF carries the root 0.78 m forward from it; front marker orientation
## pi; Plans/Actors/stage_g.md). The controller stays there throughout.
##
## An actor with a built visual (an NpcController's actor node) is animated
## from the idle tree's FurnitureIdles: sit state 2 plays the enter idle, then 3
## with the seated loop (the item picked at sit state 1, DefaultSitIdle);
## standing picks the exit at 4 and plays it at 5, then 0 returns it to
## locomotion. Without a visual it goes straight to 3, or 0. GetSitting's values
## are inferred (Plans/Actors/stage_g.md).

## ActorReference.sit_state values (GetSitting; inferred).
const NOT_SITTING := 0
const WANTS_TO_SIT := 1
const SITTING_DOWN := 2
const SITTING := 3
const WANTS_TO_STAND := 4
const STANDING_UP := 5

## Canonical NIF path -> Array of {"position" (Godot axes, metres, the
## furniture's placement space), "heading" (radians), "marker_id"}.
var _markers_by_model: Dictionary = {}
## Canonical NIF path -> the actors waiting for that NIF's markers.
var _waiting: Dictionary = {}

## `actor` has started using `furniture`: seats it once the markers are known.
func seat(actor: ActorReference, furniture: FurnitureReference) -> void:
	# The furniture idles replace any idle the actor was asked to play.
	actor.special_idle = null
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

## `actor` is about to stop using furniture: the exit idle is picked while it
## still uses it (GetFurnitureMarkerID), then played.
func stand(actor: ActorReference) -> void:
	var animator := _animator_for(actor)
	if animator == null or actor.sit_state == NOT_SITTING:
		actor.sit_state = NOT_SITTING
		return
	actor.sit_state = WANTS_TO_STAND
	var exit := _pick(actor)
	actor.sit_state = STANDING_UP
	_play(animator, exit, _on_stood.bind(actor, animator))

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
	var animator := _animator_for(actor)
	if animator == null:
		actor.sit_state = SITTING
		return
	actor.sit_state = SITTING_DOWN
	_play(animator, _pick(actor), _on_sat_down.bind(actor, animator))

## `actor`'s animations have just loaded (EsmActorNode): shows the sit state it
## is already in. Seated, or sitting down, starts it in the seat (the enter idle
## from its last frame, then the seated loop); standing up finishes, as there
## was nothing on screen to stand up.
func restore(actor: ActorReference) -> void:
	var animator := _animator_for(actor)
	if animator == null:
		return
	if actor.sit_state == SITTING or actor.sit_state == SITTING_DOWN:
		actor.sit_state = SITTING_DOWN
		_play(animator, _pick_enter(actor), _on_sat_down.bind(actor, animator), true)
	elif actor.sit_state == WANTS_TO_STAND or actor.sit_state == STANDING_UP:
		actor.sit_state = NOT_SITTING

func _on_sat_down(_idle: IdleBase, actor: ActorReference, animator: ActorAnimator) -> void:
	if actor.sit_state != SITTING_DOWN:
		return
	actor.sit_state = SITTING
	var loop := _pick_seated_loop(actor)
	actor.last_idle = loop
	animator.play_idle(loop)

func _on_stood(_idle: IdleBase, actor: ActorReference, animator: ActorAnimator) -> void:
	if actor.sit_state != STANDING_UP:
		return
	actor.sit_state = NOT_SITTING
	var turn := animator.stop_idle()
	# The exit idle leaves the body facing away from the furniture: the actor
	# turns with it rather than the body snapping back to the old heading.
	var body := _body_for(actor)
	if body != null:
		body.rotation.y -= turn
		actor.rotation = EsmReferencePhysicaliser.authored_heading(body.rotation.y)

## Plays `idle` and calls `on_finished` with it when it ends.
func _play(animator: ActorAnimator, idle: IdleBase, on_finished: Callable, from_end := false) -> void:
	if animator.idle_finished.is_connected(on_finished):
		return
	var actor := (animator.get_parent() as EsmActorNode).reference as ActorReference
	if actor != null:
		actor.last_idle = idle
	animator.idle_finished.connect(on_finished, CONNECT_ONE_SHOT)
	animator.play_idle(idle, from_end)

## The enter idle: the item picked at sit state 2, with the state set to 2 for
## the pick only.
func _pick_enter(actor: ActorReference) -> IdleBase:
	var state := actor.sit_state
	actor.sit_state = SITTING_DOWN
	var idle := _pick(actor)
	actor.sit_state = state
	return idle

## The FurnitureIdles item `actor` qualifies for now.
func _pick(actor: ActorReference) -> IdleBase:
	return ScriptServer.idle_tree.pick(actor, ScriptServer.idle_tree.get_root(IdleTree.FURNITURE_ROOT))

## The seated loop: the item picked at sit state 1 (DefaultSitIdle, holding
## DynamicIdle_ChairSit for a chair), picked with the state set to 1 for the
## pick only.
func _pick_seated_loop(actor: ActorReference) -> IdleBase:
	var state := actor.sit_state
	actor.sit_state = WANTS_TO_SIT
	var idle := _pick(actor)
	actor.sit_state = state
	return idle

## The animator of `actor`'s actor node when its visual is built, else null
## (off screen, or still loading): an NpcController's, or the player's for the
## possessed actor.
static func _animator_for(actor: ActorReference) -> ActorAnimator:
	var actor_node: EsmActorNode = null
	var controller := EsmNode.node_for(actor) as NpcController
	if controller != null:
		actor_node = controller.actor
	var player: PlayerController = ScriptServer.player_node as PlayerController
	if actor_node == null and player != null and player.possessed == actor:
		actor_node = player.actor
	if actor_node == null or not actor_node.is_visual_built():
		return null
	return actor_node.animator

## The node that carries `actor`'s heading: its NpcController, or the player
## body for the possessed actor; null off screen.
static func _body_for(actor: ActorReference) -> Node3D:
	var controller := EsmNode.node_for(actor) as NpcController
	if controller != null:
		return controller
	var player := ScriptServer.player_node as PlayerController
	if player != null and player.possessed == actor:
		return player
	return null

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
