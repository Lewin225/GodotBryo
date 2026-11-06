class_name SimulationMapView
extends Control

## Top-down map of one space for the Simulation debug tab: its navmesh
## triangles, the actors NpcSimulationServer indexes there coloured by state,
## the routes of actors it is moving, and the player. North is up. Positions
## are authored (Z up, metres), drawn by their X and Y.

const BACKGROUND := Color(0.08, 0.09, 0.1)
const NAVMESH_COLOR := Color(0.35, 0.4, 0.45, 0.35)
const LEASED_COLOR := Color(0.4, 0.9, 0.4)
const MOVING_COLOR := Color(0.3, 0.85, 1.0)
const IDLE_COLOR := Color(0.35, 0.5, 1.0)
const DISABLED_COLOR := Color(0.45, 0.45, 0.45)
const ROUTE_COLOR := Color(0.3, 0.85, 1.0, 0.5)
const PLAYER_COLOR := Color(1.0, 0.85, 0.2)
const ACTOR_RADIUS := 3.0
const HOVER_PIXELS := 8.0
## Navmesh record meshes built per frame; records still unbuilt are drawn on
## a later frame.
const RECORD_BUILDS_PER_FRAME := 64

## Emitted when `radius_metres` changes.
signal zoom_changed

## Metres from the centre to the nearer edge of the map.
var radius_metres := 150.0:
	set(value):
		radius_metres = maxf(value, 5.0)
		queue_redraw()
		zoom_changed.emit()
## Whether disabled actors are drawn.
var show_disabled := true
## Whether the map fills its rect with BACKGROUND; off for the corner overlay
## shown over the game.
var draw_background := true

var _space_form_id := 0
var _center := Vector2.ZERO
var _player: ActorReference = null
var _actors: Array[ActorReference] = []
## Navmesh record index -> an ArrayMesh of its triangle edges in authored X/Y,
## built when the record is first in view and drawn through a transform.
var _record_meshes: Dictionary = {}
## Navmesh record index -> Rect2 of its authored X/Y bounds, for the space.
var _record_bounds: Dictionary = {}
var _hovered: ActorReference = null


## Shows `space_form_id` centred on `center` (authored), with `player` marked.
func show_space(space_form_id: int, center: Vector3, player: ActorReference) -> void:
	if space_form_id != _space_form_id:
		_space_form_id = space_form_id
		_record_meshes.clear()
		_index_records()
	_center = Vector2(center.x, center.y)
	_player = player
	_actors = NpcSimulationServer.get_actors_in_space(space_form_id) if NpcSimulationServer.is_seeded else []
	queue_redraw()


## Counts of the shown space's actors: {"leased", "moving", "idle", "disabled"}.
func count_actors() -> Dictionary:
	var counts := {"leased": 0, "moving": 0, "idle": 0, "disabled": 0}
	for actor in _actors:
		counts[_state_of(actor)] += 1
	return counts


func _index_records() -> void:
	_record_bounds.clear()
	var navmesh: NavmeshReader = NpcSimulationServer.navmesh
	if navmesh == null or _space_form_id == 0:
		return
	for record_index in navmesh.get_records_in_space(_space_form_id):
		var info: Dictionary = navmesh.get_record_info(record_index)
		var low: Vector3 = info["bounds_min"]
		var high: Vector3 = info["bounds_max"]
		_record_bounds[record_index] = Rect2(Vector2(low.x, low.y), Vector2(high.x - low.x, high.y - low.y))


func _state_of(actor: ActorReference) -> String:
	if actor.is_disabled():
		return "disabled"
	if actor.simulation_mode == ActorReference.SimulationMode.PHYSICAL_LEASED:
		return "leased"
	if actor.has_move_target:
		return "moving"
	return "idle"


func _color_of(state: String) -> Color:
	match state:
		"leased":
			return LEASED_COLOR
		"moving":
			return MOVING_COLOR
		"disabled":
			return DISABLED_COLOR
	return IDLE_COLOR


func _scale() -> float:
	return minf(size.x, size.y) * 0.5 / radius_metres


func _to_screen(authored: Vector3) -> Vector2:
	var offset := (Vector2(authored.x, authored.y) - _center) * _scale()
	return size * 0.5 + Vector2(offset.x, -offset.y)


func _view_rect() -> Rect2:
	var half := size * 0.5 / _scale()
	return Rect2(_center - half, half * 2.0)


func _draw() -> void:
	if draw_background:
		draw_rect(Rect2(Vector2.ZERO, size), BACKGROUND)
	if _space_form_id == 0:
		return
	_draw_navmesh()
	_draw_routes()
	_draw_actors()
	_draw_player()
	_draw_hover()


func _draw_navmesh() -> void:
	var view := _view_rect()
	var scale := _scale()
	# Authored X/Y to the screen: scaled, Y flipped, the centre in the middle.
	draw_set_transform(size * 0.5 - Vector2(_center.x, -_center.y) * scale, 0.0, Vector2(scale, -scale))
	var builds_left := RECORD_BUILDS_PER_FRAME
	for record_index: int in _record_bounds:
		if not view.intersects(_record_bounds[record_index]):
			continue
		if not _record_meshes.has(record_index):
			if builds_left == 0:
				queue_redraw.call_deferred()
				continue
			builds_left -= 1
			_record_meshes[record_index] = _build_record_mesh(record_index)
		var mesh: ArrayMesh = _record_meshes[record_index]
		if mesh != null:
			draw_mesh(mesh, null, Transform2D.IDENTITY, NAVMESH_COLOR)
	draw_set_transform(Vector2.ZERO)


## The edges of a navmesh record's triangles as a line mesh in authored X/Y;
## null for a record with none.
func _build_record_mesh(record_index: int) -> ArrayMesh:
	var points: PackedVector3Array = NpcSimulationServer.navmesh.get_record_triangle_points(record_index)
	if points.size() < 3:
		return null
	var lines := PackedVector2Array()
	lines.resize(points.size() * 2)
	var line_index := 0
	for corner in range(0, points.size() - 2, 3):
		var a := Vector2(points[corner].x, points[corner].y)
		var b := Vector2(points[corner + 1].x, points[corner + 1].y)
		var c := Vector2(points[corner + 2].x, points[corner + 2].y)
		lines[line_index] = a
		lines[line_index + 1] = b
		lines[line_index + 2] = b
		lines[line_index + 3] = c
		lines[line_index + 4] = c
		lines[line_index + 5] = a
		line_index += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = lines
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return mesh


func _draw_routes() -> void:
	var travel: LowLevelTravel = NpcSimulationServer.low_level_travel
	for actor in _actors:
		if _state_of(actor) != "moving":
			continue
		var waypoints := travel.get_remaining_waypoints(actor)
		if waypoints.is_empty():
			continue
		var line := PackedVector2Array([_to_screen(actor.position)])
		for waypoint in waypoints:
			line.append(_to_screen(waypoint))
		draw_polyline(line, ROUTE_COLOR, 1.0)


func _draw_actors() -> void:
	for actor in _actors:
		var state := _state_of(actor)
		if state == "disabled" and not show_disabled:
			continue
		draw_circle(_to_screen(actor.position), ACTOR_RADIUS, _color_of(state))


func _draw_player() -> void:
	if _player == null or _player.current_space_form_id != _space_form_id:
		return
	var at := _to_screen(_player.position)
	# Authored heading turns clockwise from north; the screen's Y points down.
	var heading := _player.rotation.z
	var facing := Vector2(sin(heading), -cos(heading))
	draw_circle(at, 9.0, PLAYER_COLOR, false, 2.0)
	draw_circle(at, 4.0, PLAYER_COLOR)
	draw_line(at, at + facing * 18.0, PLAYER_COLOR, 2.0)


func _draw_hover() -> void:
	if _hovered == null:
		return
	var font := get_theme_default_font()
	var text := _describe(_hovered)
	var at := _to_screen(_hovered.position) + Vector2(10, -10)
	draw_multiline_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, -1, Color.WHITE)


func _describe(actor: ActorReference) -> String:
	var lines := PackedStringArray()
	var base_name := actor.base.editor_id if actor.base != null else "?"
	lines.append("%s  %s" % [base_name, actor.instance_id])
	lines.append(_state_of(actor))
	if actor.active_package != null:
		lines.append("package: %s" % actor.active_package.editor_id)
	return "\n".join(lines)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_hovered = _actor_near((event as InputEventMouseMotion).position)
		queue_redraw()
	elif event is InputEventMouseButton and event.pressed:
		var button := (event as InputEventMouseButton).button_index
		if button == MOUSE_BUTTON_WHEEL_UP:
			radius_metres *= 0.8
		elif button == MOUSE_BUTTON_WHEEL_DOWN:
			radius_metres *= 1.25


func _actor_near(screen: Vector2) -> ActorReference:
	var nearest: ActorReference = null
	var nearest_distance := HOVER_PIXELS
	for actor in _actors:
		if actor.is_disabled() and not show_disabled:
			continue
		var distance := _to_screen(actor.position).distance_to(screen)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = actor
	return nearest
