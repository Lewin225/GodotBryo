extends Node3D

## Visualizer for the NpcSimulationServer autoload and the authored navmesh behind it.
##
## Unlike npc_simulation_viewer.gd, which plots raw authored vectors untouched
## and therefore renders the world on its side, this one applies the codebase's
## standard Bethesda-Z-up to Godot-Y-up conversion (see [method _to_godot]) so
## ground reads as ground. Everything else is real authored data with no further
## massaging.
##
## Renders one space at a time: the exterior Mojave alone is 4041 records, and
## nothing is served by drawing every interior in the game on top of it.

const NAVMESH_ALPHA := 0.45
## Distinct hues per record so the per-CELL record structure is visible. A
## navmesh that looks like one continuous sheet hides exactly the seams that
## matter.
const RECORD_HUE_STEP := 0.137

@onready var simulation: Node = get_node("/root/NpcSimulationServer")
@onready var navmesh_surface: MeshInstance3D = $NavmeshSurface
@onready var coarse_graph_lines: MeshInstance3D = $CoarseGraphLines
@onready var actor_points: MultiMeshInstance3D = $ActorPoints
@onready var grounding_lines: MeshInstance3D = $GroundingLines
@onready var portal_lines: MeshInstance3D = $PortalLines
@onready var portal_boxes: MultiMeshInstance3D = $PortalBoxes
@onready var route_line: MeshInstance3D = $RouteLine
@onready var batch_route_lines: MeshInstance3D = $BatchRouteLines
@onready var walker_marker: MeshInstance3D = $WalkerMarker
@onready var batch_walkers: MultiMeshInstance3D = $BatchWalkers
@onready var status_label: Label = $Hud/Panel/Status
@onready var camera: Camera3D = $Camera3D

var space_ids: PackedInt32Array = PackedInt32Array()
var current_space_index := 0
var current_space := 0
var current_space_stats: Dictionary = {}
var last_route: Dictionary = {}
var route_endpoints: Array[Vector3] = []

## Walking speed, in metres per second. A real walk is ~1.4 m/s, which makes a
## 2 km cross-worldspace route unwatchable, so this is deliberately fast and is
## a viewing convenience rather than a simulation parameter.
@export var walk_speed := 60.0
@export var camera_follows_walker := true

## The walking NPC: which cross-space route it is on, how far along, and which
## space it is currently in. Empty when nothing is walking.
var walker: Dictionary = {}
var cross_route: Dictionary = {}

## Bulk same-space route stress test. Deliberately stays in the current space --
## it never routes through a door -- so the camera holds still and all results
## are drawn in one coordinate frame.
const BATCH_SIZE := 100
var batch: Dictionary = {}

func _ready() -> void:
	camera.move_speed = 40.0
	camera.far = 20000.0
	var walker_material := StandardMaterial3D.new()
	walker_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	walker_material.albedo_color = Color(1.0, 0.95, 0.35)
	var walker_mesh := SphereMesh.new()
	walker_mesh.radius = 1.0
	walker_mesh.height = 2.0
	walker_mesh.material = walker_material
	walker_marker.mesh = walker_mesh
	walker_marker.visible = false
	simulation.seed_progress.connect(_on_seed_progress)
	simulation.seed_finished.connect(_on_seed_finished)
	if simulation.is_seeded:
		_on_seed_finished.call_deferred()
	else:
		simulation.seed()
	_refresh_status()

## The codebase's established Z-up -> Y-up mapping (terrain_grass_particles.gd,
## terrain3d_bridge.gd). NavmeshReader hands back raw authored axis order in
## meters, exactly like EsmReader, so the swap belongs here at the view layer.
static func _to_godot(v: Vector3) -> Vector3:
	return Vector3(v.x, v.z, -v.y)

func _on_seed_progress(_status: String, _completed: int, _total: int) -> void:
	_refresh_status()

func _on_seed_finished() -> void:
	space_ids = simulation.navmesh.get_space_ids()
	# Default to the largest space, which is the exterior worldspace in practice
	# -- the interesting one, and the one that stresses the query path.
	var biggest_count := -1
	for i in space_ids.size():
		var count: int = simulation.navmesh.get_records_in_space(space_ids[i]).size()
		if count > biggest_count:
			biggest_count = count
			current_space_index = i
	_show_space(current_space_index)

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_BRACKETLEFT:
			_step_space(-1)
		KEY_BRACKETRIGHT:
			_step_space(1)
		KEY_1:
			navmesh_surface.visible = not navmesh_surface.visible
		KEY_2:
			coarse_graph_lines.visible = not coarse_graph_lines.visible
		KEY_3:
			actor_points.visible = not actor_points.visible
			grounding_lines.visible = not grounding_lines.visible
		KEY_4:
			portal_boxes.visible = not portal_boxes.visible
			portal_lines.visible = portal_boxes.visible
		KEY_R:
			_route_between_random_actors()
		KEY_T:
			_walk_random_cross_space_route()
		KEY_C:
			camera_follows_walker = not camera_follows_walker
		KEY_P:
			_stress_test_routes()
		KEY_F:
			_frame_current_space()
	_refresh_status()

func _step_space(delta: int) -> void:
	if space_ids.is_empty():
		return
	current_space_index = wrapi(current_space_index + delta, 0, space_ids.size())
	_show_space(current_space_index)

func _show_space(index: int) -> void:
	if space_ids.is_empty():
		return
	current_space = space_ids[index]
	_build_navmesh_surface(current_space)
	_build_coarse_graph(current_space)
	_build_actor_points(current_space)
	_build_portals(current_space)
	_clear_route()
	_frame_current_space()
	_refresh_status()

## One bulk native call per space rather than one per record -- 4041 round-trips
## for the Mojave otherwise.
func _build_navmesh_surface(space_form_id: int) -> void:
	var geometry: Dictionary = simulation.navmesh.get_space_geometry(space_form_id)
	var points: PackedVector3Array = geometry.get("points", PackedVector3Array())
	var record_indices: PackedInt32Array = geometry.get("record_indices", PackedInt32Array())
	current_space_stats = {
		"records": int(geometry.get("record_count", 0)),
		"triangles": int(geometry.get("triangle_count", 0)),
	}
	if points.is_empty():
		navmesh_surface.mesh = null
		return

	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	vertices.resize(points.size())
	colors.resize(points.size())
	for t in record_indices.size():
		var color := Color.from_hsv(fposmod(record_indices[t] * RECORD_HUE_STEP, 1.0), 0.55, 1.0, NAVMESH_ALPHA)
		for corner in 3:
			var i := t * 3 + corner
			vertices[i] = _to_godot(points[i])
			colors[i] = color

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Navmesh triangles are authored single-sided but are worth seeing from
	# underneath too, which is where a hole in the mesh is most obvious.
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, material)
	navmesh_surface.mesh = mesh

## Authored NVEX record-to-record connectivity, drawn between authored bounds
## centers. The centers are only where the lines are drawn; the lines themselves
## exist if and only if NVEX says the records connect. Proximity never creates
## one -- that is the property that keeps a route off the far bank of a river.
func _build_coarse_graph(space_form_id: int) -> void:
	var records: PackedInt32Array = simulation.navmesh.get_records_in_space(space_form_id)
	var centers := {}
	for record_index in records:
		var info: Dictionary = simulation.navmesh.get_record_info(record_index)
		var center: Vector3 = info["center"]
		centers[record_index] = _to_godot(center)

	var mesh := ImmediateMesh.new()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(1.0, 0.85, 0.3, 0.35)
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	var drawn := {}
	var vertices := 0
	for record_index in records:
		for neighbor in simulation.navmesh.get_coarse_neighbors(record_index):
			if not centers.has(neighbor):
				continue
			var key := Vector2i(min(record_index, neighbor), max(record_index, neighbor))
			if drawn.has(key):
				continue
			drawn[key] = true
			mesh.surface_add_vertex(centers[record_index])
			mesh.surface_add_vertex(centers[neighbor])
			vertices += 2
	# An isolated space -- a single interior record with no NVEX links out -- has
	# no coarse graph at all, and surface_end() on an empty surface is an error.
	if vertices > 0:
		mesh.surface_end()
		coarse_graph_lines.mesh = mesh
	else:
		coarse_graph_lines.mesh = null

## Green = grounded onto real navmesh, red = no navmesh within the snap radius
## (and therefore refused by checkout()). The line from each actor shows the
## correction from the authored position to where they would actually stand.
func _build_actor_points(space_form_id: int) -> void:
	var actors: Array[ActorReference] = simulation.get_actors_in_space(space_form_id)

	# A 0.35 m marker is right for an interior and sub-pixel across the Mojave,
	# so scale it to the space actually being shown.
	var radius := 0.35
	var bounds: Dictionary = simulation.navmesh.get_space_bounds(space_form_id)
	if bool(bounds.get("found", false)):
		var bounds_min: Vector3 = bounds["min"]
		var bounds_max: Vector3 = bounds["max"]
		radius = clampf(maxf(bounds_max.x - bounds_min.x, bounds_max.y - bounds_min.y) * 0.0015, 0.35, 12.0)
	current_space_stats["marker_radius"] = radius

	var point_mesh := SphereMesh.new()
	point_mesh.radius = radius
	point_mesh.height = radius * 2.0
	point_mesh.radial_segments = 6
	point_mesh.rings = 3
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	point_mesh.material = material

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.instance_count = actors.size()
	multimesh.mesh = point_mesh

	var line_mesh := ImmediateMesh.new()
	var line_material := StandardMaterial3D.new()
	line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	line_material.albedo_color = Color(1.0, 1.0, 1.0, 0.5)
	line_mesh.surface_begin(Mesh.PRIMITIVE_LINES, line_material)

	var grounded_count := 0
	var line_vertices := 0
	for i in actors.size():
		var actor := actors[i]
		var authored := _to_godot(actor.position)
		var grounded: bool = simulation.is_grounded(actor)
		if grounded:
			grounded_count += 1
		var ground_position: Vector3 = simulation.get_ground_position(actor)
		# Lifted by its own radius so the marker sits on the navmesh rather than
		# half-buried in it (and z-fighting with it).
		var standing := _to_godot(ground_position) + Vector3(0.0, radius, 0.0)
		multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY, standing))
		multimesh.set_instance_color(i, Color(0.35, 1.0, 0.45) if grounded else Color(1.0, 0.3, 0.3))
		if grounded and authored.distance_to(standing) > 0.01:
			line_mesh.surface_add_vertex(authored)
			line_mesh.surface_add_vertex(standing)
			line_vertices += 2
	# surface_end() on an empty surface is an error, and a space where every
	# actor already sits exactly on the mesh legitimately adds no lines.
	if line_vertices > 0:
		line_mesh.surface_end()
		grounding_lines.mesh = line_mesh
	else:
		grounding_lines.mesh = null

	actor_points.multimesh = multimesh
	current_space_stats["actors"] = actors.size()
	current_space_stats["grounded"] = grounded_count

## Portals touching the current space only. Drawing all 1365 XTEL relations at
## once spans every space in the game at once and reads as noise, which is why
## this was hidden by default before it was filtered.
##
## A door is marked with a box oriented by its authored REFR rotation, through
## the same [method EsmReferencePhysicaliser.placement_transform] the real
## physicalisation path uses -- so a box sits exactly where and how that door
## would be placed, rather than being an axis-aligned approximation of it.
func _build_portals(space_form_id: int) -> void:
	var here: Array = []
	for portal in simulation.portals:
		var is_source: bool = portal.source_space_form_id == space_form_id
		var is_destination: bool = portal.destination_space_form_id == space_form_id
		if is_source or is_destination:
			here.append({"portal": portal, "is_source": is_source, "is_destination": is_destination})

	var size_scale := 1.0
	var bounds: Dictionary = simulation.navmesh.get_space_bounds(space_form_id)
	if bool(bounds.get("found", false)):
		var bounds_min: Vector3 = bounds["min"]
		var bounds_max: Vector3 = bounds["max"]
		size_scale = clampf(maxf(bounds_max.x - bounds_min.x, bounds_max.y - bounds_min.y) * 0.0015, 1.0, 24.0)

	# Roughly door-shaped at scale 1: a metre wide, two tall, shallow.
	var box := BoxMesh.new()
	box.size = Vector3(1.0, 2.0, 0.35) * size_scale
	var box_material := StandardMaterial3D.new()
	box_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	box_material.vertex_color_use_as_albedo = true
	box_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	box.material = box_material

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = box

	var transforms: Array[Transform3D] = []
	var colors: Array[Color] = []
	for entry in here:
		var portal = entry["portal"]
		var door: DoorReference = portal.source_reference
		if entry["is_source"]:
			# The door itself, as authored in this space.
			transforms.append(EsmReferencePhysicaliser.placement_transform(portal.source_position, door.rotation))
			colors.append(Color(1.0, 0.55, 0.15, 0.85))
		if entry["is_destination"]:
			# Where arriving through that door puts you, with the authored XTEL
			# arrival orientation.
			transforms.append(EsmReferencePhysicaliser.placement_transform(portal.destination_position, door.teleport.rotation))
			colors.append(Color(0.3, 0.75, 1.0, 0.85))

	multimesh.instance_count = transforms.size()
	for i in transforms.size():
		var authored := transforms[i]
		# placement_transform already converts to Godot space; lift the box so it
		# stands on the navmesh instead of straddling it.
		multimesh.set_instance_transform(i, Transform3D(authored.basis, authored.origin + Vector3(0.0, box.size.y * 0.5, 0.0)))
		multimesh.set_instance_color(i, colors[i])
	portal_boxes.multimesh = multimesh

	# Relation lines are drawn ONLY for doors whose two ends are both in this
	# space. A door leading somewhere else lands in a different coordinate space,
	# so a line to it is not a shortened or distant line -- it is two unrelated
	# frames joined by a segment that means nothing. Drawing those produced a
	# starburst of 700-odd lines converging near the origin, which looked like
	# structure and was pure artifact. Cross-space doors get a box and no line;
	# where they actually lead is a question for the cross-space route.
	var mesh := ImmediateMesh.new()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(1.0, 0.45, 0.25, 0.3)
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	var vertices := 0
	for entry in here:
		if not (entry["is_source"] and entry["is_destination"]):
			continue
		var portal = entry["portal"]
		mesh.surface_add_vertex(_to_godot(portal.source_position))
		mesh.surface_add_vertex(_to_godot(portal.destination_position))
		vertices += 2
	if vertices > 0:
		mesh.surface_end()
		portal_lines.mesh = mesh
	else:
		portal_lines.mesh = null
	current_space_stats["portals"] = here.size()

## Routes between two randomly chosen grounded actors in the current space,
## through the real A*. Async, so the viewport keeps responding while it runs.
func _route_between_random_actors() -> void:
	var grounded: Array[ActorReference] = []
	for actor in simulation.get_actors_in_space(current_space):
		var is_grounded: bool = simulation.is_grounded(actor)
		if is_grounded:
			grounded.append(actor)
	if grounded.size() < 2:
		last_route = {"found": false, "note": "need two grounded actors in this space"}
		_clear_route()
		return
	var from_actor := grounded[randi() % grounded.size()]
	var to_actor := grounded[randi() % grounded.size()]
	if from_actor == to_actor:
		@warning_ignore("integer_division")
		to_actor = grounded[(grounded.find(from_actor) + grounded.size() / 2) % grounded.size()]
	var from_position: Vector3 = simulation.get_ground_position(from_actor)
	var to_position: Vector3 = simulation.get_ground_position(to_actor)
	route_endpoints = [from_position, to_position]
	last_route = {"found": false, "note": "routing..."}
	_refresh_status()
	var request_id: int = simulation.request_route(current_space, route_endpoints[0], route_endpoints[1])
	var result: Array = await simulation.route_ready
	if int(result[0]) != request_id:
		return
	last_route = result[1]
	_draw_route(last_route)
	# A cross-worldspace route is kilometres long; leaving the camera where it
	# was almost guarantees the result is off-screen.
	_frame_route(last_route)
	_refresh_status()

func _frame_route(route: Dictionary) -> void:
	if not bool(route.get("found", false)):
		return
	var waypoints: PackedVector3Array = route.get("waypoints", PackedVector3Array())
	if waypoints.is_empty():
		return
	var low := _to_godot(waypoints[0])
	var high := low
	for point in waypoints:
		var converted := _to_godot(point)
		low = low.min(converted)
		high = high.max(converted)
	var centre := (low + high) * 0.5
	var extent: float = maxf(maxf(high.x - low.x, high.z - low.z), 20.0)
	camera.global_position = centre + Vector3(0.0, extent * 0.75, extent * 0.75)
	camera.look_at(centre, Vector3.UP)
	camera.rotation = Vector3(camera.rotation.x, camera.rotation.y, 0.0)
	camera.yaw = camera.rotation.y
	camera.pitch = camera.rotation.x
	camera.move_speed = clampf(extent * 0.08, 8.0, 400.0)

## Picks a grounded actor here and a grounded actor in some OTHER space that is
## actually reachable through authored doors, routes between them, then walks it.
func _walk_random_cross_space_route() -> void:
	var here: Array[ActorReference] = []
	for actor in simulation.get_actors_in_space(current_space):
		var grounded: bool = simulation.is_grounded(actor)
		if grounded:
			here.append(actor)
	if here.is_empty():
		cross_route = {"found": false, "note": "no grounded actor in this space to start from"}
		_refresh_status()
		return
	var from_actor := here[randi() % here.size()]
	var from_position: Vector3 = simulation.get_ground_position(from_actor)

	# Only consider spaces this one can actually reach through doors, so the
	# demo does not spend its time reporting "no route" for isolated interiors.
	var reachable: Array = []
	for candidate_space in space_ids:
		if candidate_space == current_space:
			continue
		if simulation.get_actors_in_space(candidate_space).is_empty():
			continue
		if simulation.find_portal_path(current_space, candidate_space, 4).is_empty():
			continue
		reachable.append(candidate_space)
		if reachable.size() >= 24:
			break
	if reachable.is_empty():
		cross_route = {"found": false, "note": "no other space reachable from here through authored doors"}
		_refresh_status()
		return

	var to_space: int = reachable[randi() % reachable.size()]
	var destinations: Array[ActorReference] = []
	for actor in simulation.get_actors_in_space(to_space):
		var grounded: bool = simulation.is_grounded(actor)
		if grounded:
			destinations.append(actor)
	if destinations.is_empty():
		cross_route = {"found": false, "note": "destination space has no grounded actor"}
		_refresh_status()
		return
	var to_actor := destinations[randi() % destinations.size()]
	var to_position: Vector3 = simulation.get_ground_position(to_actor)

	cross_route = {"found": false, "note": "routing across spaces..."}
	_refresh_status()
	var request_id: int = simulation.request_cross_space_route(current_space, from_position, to_space, to_position)
	var result: Array = await simulation.cross_space_route_ready
	if int(result[0]) != request_id:
		return
	cross_route = result[1]
	if not bool(cross_route.get("found", false)):
		_refresh_status()
		return
	_start_walker(cross_route)
	_refresh_status()

func _start_walker(route: Dictionary) -> void:
	var legs: Array = route.get("legs", [])
	if legs.is_empty():
		return
	walker = {
		"legs": legs,
		"leg_index": 0,
		"waypoint_index": 0,
		"position": Vector3.ZERO,
		"space": int(legs[0]["space_form_id"]),
		"finished": false,
		"camera_snap": true,
	}
	var first: PackedVector3Array = legs[0]["waypoints"]
	walker["position"] = first[0] if first.size() > 0 else Vector3.ZERO
	# Show the space the walk starts in, and draw that leg's path.
	_show_space_by_id(int(legs[0]["space_form_id"]))
	_draw_leg(0)

func _show_space_by_id(space_form_id: int) -> void:
	for i in space_ids.size():
		if space_ids[i] == space_form_id:
			if current_space != space_form_id:
				current_space_index = i
				_show_space(i)
			return

## Draws only the leg currently being walked. The other legs are in other
## spaces, so drawing them all at once would scatter lines across coordinate
## spaces that share no common frame.
func _draw_leg(leg_index: int) -> void:
	var legs: Array = walker.get("legs", [])
	if leg_index < 0 or leg_index >= legs.size():
		_clear_route()
		return
	var leg: Dictionary = legs[leg_index]
	var waypoints: PackedVector3Array = leg["waypoints"]
	var mesh := ImmediateMesh.new()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# A leg with no navmesh under it is drawn in red: it is a straight line the
	# NPC cannot actually walk, not a real path.
	material.albedo_color = Color(0.3, 0.9, 1.0) if bool(leg["has_navmesh"]) else Color(1.0, 0.35, 0.3)
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, material)
	for point in waypoints:
		mesh.surface_add_vertex(_to_godot(point) + Vector3(0.0, 0.3, 0.0))
	mesh.surface_end()
	route_line.mesh = mesh

var _recent_frame_ms := 0.0

func _process(delta: float) -> void:
	_recent_frame_ms = delta * 1000.0
	if not batch.is_empty() and bool(batch.get("running", false)):
		batch["worst_frame_ms"] = maxf(float(batch["worst_frame_ms"]), _recent_frame_ms)

	_update_batch_walkers(delta)

	if walker.is_empty() or bool(walker.get("finished", true)):
		return
	var legs: Array = walker["legs"]
	var leg_index: int = walker["leg_index"]
	if leg_index >= legs.size():
		walker["finished"] = true
		_refresh_status()
		return

	var leg: Dictionary = legs[leg_index]
	var waypoints: PackedVector3Array = leg["waypoints"]
	var waypoint_index: int = walker["waypoint_index"]
	var walker_position: Vector3 = walker["position"]
	var budget := walk_speed * delta

	while budget > 0.0:
		if waypoint_index + 1 >= waypoints.size():
			# End of this leg. If it ends at a door, step through it: the NPC
			# changes space, and its position jumps to the authored XTEL arrival
			# point rather than being interpolated across the transition.
			var exit_portal = leg["exit_portal"]
			walker["leg_index"] = leg_index + 1
			walker["waypoint_index"] = 0
			if leg_index + 1 >= legs.size():
				walker["finished"] = true
				walker["position"] = walker_position
				_refresh_status()
				return
			var next_leg: Dictionary = legs[leg_index + 1]
			var next_waypoints: PackedVector3Array = next_leg["waypoints"]
			walker["position"] = next_waypoints[0] if next_waypoints.size() > 0 else walker_position
			walker["space"] = int(next_leg["space_form_id"])
			if exit_portal != null:
				_show_space_by_id(int(next_leg["space_form_id"]))
				walker["camera_snap"] = true
			_draw_leg(leg_index + 1)
			_update_walker_marker()
			_refresh_status()
			return

		var target: Vector3 = waypoints[waypoint_index + 1]
		var to_target := target - walker_position
		var distance := to_target.length()
		if distance <= budget:
			walker_position = target
			waypoint_index += 1
			budget -= distance
		else:
			walker_position += to_target / distance * budget
			budget = 0.0

	walker["position"] = walker_position
	walker["waypoint_index"] = waypoint_index
	_update_walker_marker()

func _update_walker_marker() -> void:
	if walker.is_empty():
		walker_marker.visible = false
		return
	walker_marker.visible = true
	var walker_position: Vector3 = walker["position"]
	var converted := _to_godot(walker_position)
	var marker_radius: float = current_space_stats.get("marker_radius", 0.5)
	var marker_scale := maxf(marker_radius, 0.5)
	walker_marker.scale = Vector3.ONE * marker_scale
	walker_marker.global_position = converted + Vector3(0.0, marker_scale, 0.0)
	if camera_follows_walker:
		var offset := Vector3(0.0, marker_scale * 26.0, marker_scale * 26.0)
		# A door transition moves the NPC to an unrelated coordinate space, so
		# easing toward it would spend seconds flying through empty space. Snap
		# on the frame the space changes, ease only while walking within one.
		if bool(walker.get("camera_snap", false)):
			walker["camera_snap"] = false
			camera.global_position = walker_marker.global_position + offset
		else:
			camera.global_position = camera.global_position.lerp(walker_marker.global_position + offset, 0.08)
		camera.look_at(walker_marker.global_position, Vector3.UP)
		camera.rotation = Vector3(camera.rotation.x, camera.rotation.y, 0.0)
		camera.yaw = camera.rotation.y
		camera.pitch = camera.rotation.x

## Fires BATCH_SIZE route requests at once and measures what the player would
## actually notice: the worst main-thread frame while they run. Route latency
## itself is not the concern -- these are off-thread, and an offscreen actor can
## afford to think for a long time -- so the number that matters is whether the
## frame ever stalls, not how long the batch takes.
func _stress_test_routes() -> void:
	var grounded: Array[ActorReference] = []
	for actor in simulation.get_actors_in_space(current_space):
		var is_grounded: bool = simulation.is_grounded(actor)
		if is_grounded:
			grounded.append(actor)
	if grounded.size() < 2:
		batch = {"note": "need two grounded actors in this space"}
		_refresh_status()
		return

	batch = {
		"pending": {},
		"issued": 0,
		"done": 0,
		"found": 0,
		"paths": [],
		"started_ms": Time.get_ticks_msec(),
		"finished_ms": 0,
		"worst_frame_ms": 0.0,
		"baseline_frame_ms": _recent_frame_ms,
		"running": true,
	}
	if not simulation.route_ready.is_connected(_on_batch_route_ready):
		simulation.route_ready.connect(_on_batch_route_ready)

	for i in BATCH_SIZE:
		var from_actor := grounded[randi() % grounded.size()]
		var to_actor := grounded[randi() % grounded.size()]
		if from_actor == to_actor:
			continue
		var from_position: Vector3 = simulation.get_ground_position(from_actor)
		var to_position: Vector3 = simulation.get_ground_position(to_actor)
		var request_id: int = simulation.request_route(current_space, from_position, to_position)
		batch["pending"][request_id] = true
		batch["issued"] = int(batch["issued"]) + 1
	_refresh_status()

func _on_batch_route_ready(request_id: int, result: Dictionary) -> void:
	if batch.is_empty() or not batch.get("running", false):
		return
	var pending: Dictionary = batch["pending"]
	if not pending.has(request_id):
		return
	pending.erase(request_id)
	batch["done"] = int(batch["done"]) + 1
	if bool(result.get("found", false)):
		batch["found"] = int(batch["found"]) + 1
		(batch["paths"] as Array).append(result.get("waypoints", PackedVector3Array()))
	if pending.is_empty():
		batch["running"] = false
		batch["finished_ms"] = Time.get_ticks_msec()
		_draw_batch_paths()
		_start_batch_walkers()
	_refresh_status()

## Puts a walker on every path the batch found, so the result is a crowd
## actually traversing its routes rather than a static web of lines. They
## ping-pong rather than stopping, which keeps the scene readable without
## needing to re-issue the batch.
func _start_batch_walkers() -> void:
	var walkers: Array = []
	for path in batch.get("paths", []):
		var waypoints: PackedVector3Array = path
		if waypoints.size() < 2:
			continue
		walkers.append({
			"waypoints": waypoints,
			"index": 0,
			"position": waypoints[0],
			# Varied speeds so the crowd does not move as one block.
			"speed": randf_range(0.6, 1.6) * walk_speed,
			"direction": 1,
		})
	batch["walkers"] = walkers

	var marker_radius: float = current_space_stats.get("marker_radius", 0.5)
	var radius := maxf(marker_radius, 0.5)
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 6
	mesh.rings = 3
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 0.85, 0.25)
	mesh.material = material

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = walkers.size()
	batch_walkers.multimesh = multimesh
	_update_batch_walkers(0.0)

func _update_batch_walkers(delta: float) -> void:
	var walkers: Array = batch.get("walkers", [])
	if walkers.is_empty() or batch_walkers.multimesh == null:
		return
	var marker_radius: float = current_space_stats.get("marker_radius", 0.5)
	var lift := maxf(marker_radius, 0.5)
	for i in walkers.size():
		var w: Dictionary = walkers[i]
		var waypoints: PackedVector3Array = w["waypoints"]
		var budget: float = float(w["speed"]) * delta
		var walker_position: Vector3 = w["position"]
		var index: int = w["index"]
		var direction: int = w["direction"]
		while budget > 0.0:
			var next_index := index + direction
			if next_index < 0 or next_index >= waypoints.size():
				# Turn around at either end rather than stopping.
				direction = -direction
				next_index = index + direction
				if next_index < 0 or next_index >= waypoints.size():
					break
			var target: Vector3 = waypoints[next_index]
			var to_target := target - walker_position
			var distance := to_target.length()
			if distance <= budget:
				walker_position = target
				index = next_index
				budget -= distance
			else:
				walker_position += to_target / distance * budget
				budget = 0.0
		w["position"] = walker_position
		w["index"] = index
		w["direction"] = direction
		batch_walkers.multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY, _to_godot(walker_position) + Vector3(0.0, lift, 0.0)))

func _draw_batch_paths() -> void:
	var mesh := ImmediateMesh.new()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.4, 1.0, 0.8, 0.5)
	var vertices := 0
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	for path in batch.get("paths", []):
		var waypoints: PackedVector3Array = path
		for i in range(1, waypoints.size()):
			mesh.surface_add_vertex(_to_godot(waypoints[i - 1]) + Vector3(0.0, 0.4, 0.0))
			mesh.surface_add_vertex(_to_godot(waypoints[i]) + Vector3(0.0, 0.4, 0.0))
			vertices += 2
	if vertices > 0:
		mesh.surface_end()
		batch_route_lines.mesh = mesh
	else:
		batch_route_lines.mesh = null

func _draw_route(route: Dictionary) -> void:
	if not bool(route.get("found", false)):
		_clear_route()
		return
	var waypoints: PackedVector3Array = route.get("waypoints", PackedVector3Array())
	var mesh := ImmediateMesh.new()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.3, 0.9, 1.0)
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, material)
	for point in waypoints:
		# Lifted slightly so the route reads above the navmesh it lies on.
		mesh.surface_add_vertex(_to_godot(point) + Vector3(0.0, 0.3, 0.0))
	mesh.surface_end()
	route_line.mesh = mesh

func _clear_route() -> void:
	route_line.mesh = null

func _frame_current_space() -> void:
	var bounds: Dictionary = simulation.navmesh.get_space_bounds(current_space)
	if not bool(bounds.get("found", false)):
		return
	var bounds_min: Vector3 = bounds["min"]
	var bounds_max: Vector3 = bounds["max"]
	var low := _to_godot(bounds_min)
	var high := _to_godot(bounds_max)
	var center := (low + high) * 0.5
	var extent: float = maxf(absf(high.x - low.x), absf(high.z - low.z))
	camera.global_position = center + Vector3(0.0, maxf(extent * 0.6, 20.0), maxf(extent * 0.6, 20.0))
	camera.look_at(center, Vector3.UP)
	camera.rotation = Vector3(camera.rotation.x, camera.rotation.y, 0.0)
	camera.yaw = camera.rotation.y
	camera.pitch = camera.rotation.x
	camera.move_speed = clampf(extent * 0.08, 8.0, 400.0)

func _refresh_status() -> void:
	var stats: Dictionary = simulation.navmesh_load_stats
	var space_label := "space %d/%d  0x%08X" % [current_space_index + 1, space_ids.size(), current_space] if not space_ids.is_empty() else "(no space)"
	var route_text := "route: none  [R] to route two random actors"
	if last_route.has("note"):
		route_text = "route: %s" % String(last_route["note"])
	elif bool(last_route.get("found", false)):
		route_text = "route: %d waypoints, %.0f m, %d nodes visited" % [
			(last_route.get("waypoints", PackedVector3Array()) as PackedVector3Array).size(),
			float(last_route.get("length", 0.0)),
			int(last_route.get("visited_nodes", 0)),
		]
	elif not last_route.is_empty():
		route_text = "route: none found between those two actors"

	var cross_text := "cross-space: none  [T] to walk a route through doors"
	if cross_route.has("note"):
		cross_text = "cross-space: %s" % String(cross_route["note"])
	elif bool(cross_route.get("found", false)):
		var leg_count: int = (cross_route.get("legs", []) as Array).size()
		var walking := ""
		if not walker.is_empty():
			# leg_index runs one past the end once the walk completes, so the
			# display clamps rather than reporting "leg 5/4".
			var shown_leg: int = mini(int(walker.get("leg_index", 0)) + 1, leg_count)
			walking = "  |  NPC leg %d/%d in space 0x%08X%s" % [
				shown_leg, leg_count, int(walker.get("space", 0)),
				"  (arrived)" if bool(walker.get("finished", false)) else "",
			]
		cross_text = "cross-space: %d legs, %d doors, %.0f m%s%s" % [
			leg_count, int(cross_route.get("door_count", 0)), float(cross_route.get("total_length", 0.0)),
			"" if bool(cross_route.get("walkable", true)) else "  [NOT fully walkable: a leg has no navmesh]",
			walking,
		]

	var batch_text := "batch: none  [P] to fire %d routes at once (stays in this space)" % BATCH_SIZE
	if batch.has("note"):
		batch_text = "batch: %s" % String(batch["note"])
	elif not batch.is_empty():
		var elapsed: int = (int(batch["finished_ms"]) if int(batch["finished_ms"]) > 0 else Time.get_ticks_msec()) - int(batch["started_ms"])
		batch_text = "batch: %d/%d done, %d found, %d ms%s | %d walking | worst main-thread frame %.1f ms (idle ~%.1f ms)" % [
			int(batch["done"]), int(batch["issued"]), int(batch["found"]), elapsed,
			"" if bool(batch.get("running", false)) else " [complete]",
			(batch.get("walkers", []) as Array).size(),
			float(batch["worst_frame_ms"]), float(batch["baseline_frame_ms"]),
		]

	status_label.text = "\n".join([
		"NpcSimulationServer navmesh viewer — %s" % simulation.status,
		"navmesh: %d records, %s triangles, %.1f MB, loaded in %.0f ms" % [
			int(stats.get("records", 0)),
			String.num_int64(int(stats.get("triangles", 0))),
			float(stats.get("resident_bytes", 0)) / 1048576.0,
			float(stats.get("total_ms", 0.0)),
		],
		"%s — %d records, %s triangles, %d actors (%d grounded), %d portals" % [
			space_label,
			int(current_space_stats.get("records", 0)),
			String.num_int64(int(current_space_stats.get("triangles", 0))),
			int(current_space_stats.get("actors", 0)),
			int(current_space_stats.get("grounded", 0)),
			int(current_space_stats.get("portals", 0)),
		],
		route_text,
		cross_text,
		batch_text,
		"[ ] space  1 navmesh  2 coarse  3 actors  4 portals  R route  T cross-space walk  P x%d batch  C follow=%s  F frame" % [BATCH_SIZE, "on" if camera_follows_walker else "off"],
		"Green actor = grounded on real navmesh. Red = no navmesh under it (checkout refuses these).",
		"Yellow lines are authored NVEX record connectivity, drawn between authored bounds centers.",
		"Portal boxes: orange = an XTEL door in this space, blue = an arrival point into this space.",
	])
