class_name NavmeshDebugView
extends Node3D

## Draws navmesh for debugging, set by ToggleNavMesh (TNM):
##
## - MODE_NSS: NpcSimulationServer's NAVM triangles within RADIUS of the
##   camera, in the player's space, coloured by their NVTR Flags (door, water,
##   preferred, no large creatures; see the NSS README), with each
##   triangle's outline, link-flagged edges (record crossings) and open edges,
##   and a quad standing on each edge that carries Cover Flags. Rebuilt when
##   the camera moves REBUILD_DISTANCE or the player changes space.
## - MODE_GODOT: LocalNavigation's map for the player's space, as Godot holds
##   it, within RADIUS of the camera: each region's polygons, the pathways of
##   the edge connections Godot made between regions, and the seam links.
##
## A legend in the top corner names the colours. Cover Flags: bits 0-5 describe
## edge 0-1 and bits 6-11 edge 1-2 (navm_triangle_flag_census); within each
## group the low four bits are drawn as the quad's height (value x
## COVER_HEIGHT_STEP) and colour, the next two as dark bars at the edge's
## first and second corner. That split of each group is not established; the
## view is how to check it against the objects the cover stands beside.

enum { MODE_OFF, MODE_NSS, MODE_GODOT, MODE_COUNT }

## Metres around the camera whose triangles are drawn.
const RADIUS := 40.0
## Metres the camera moves before the triangles are fetched again.
const REBUILD_DISTANCE := 5.0
## Seconds between checks of the camera's position.
const CHECK_SECONDS := 0.25
## Metres the drawing sits above the navmesh, so it is not hidden in it.
const LIFT := 0.04
## Metres of cover quad per step of a cover group's low four bits.
const COVER_HEIGHT_STEP := 0.2

const FLAG_DOOR := 0x0400
const FLAG_WATER := 0x0200
const FLAG_PREFERRED := 0x0040
const FLAG_NO_LARGE_CREATURES := 0x0010

const COLOR_PLAIN := Color(0.85, 0.2, 0.15, 0.35)
const COLOR_DOOR := Color(0.75, 0.2, 0.9, 0.55)
const COLOR_WATER := Color(0.15, 0.4, 1.0, 0.45)
const COLOR_PREFERRED := Color(0.15, 1.0, 0.2, 0.6)
const COLOR_NO_LARGE_CREATURES := Color(0.85, 0.85, 0.85, 0.55)
const COLOR_OUTLINE := Color(0.1, 0.05, 0.05, 0.6)
const COLOR_LINK_EDGE := Color(0.0, 0.95, 0.95, 1.0)
const COLOR_OPEN_EDGE := Color(1.0, 0.95, 0.2, 1.0)
const COLOR_COVER_LOW := Color(0.1, 0.15, 0.6, 0.6)
const COLOR_COVER_HIGH := Color(1.0, 1.0, 1.0, 0.6)
const COLOR_COVER_SIDE := Color(0.0, 0.0, 0.0, 0.85)
const COLOR_SEAM_LINK := Color(1.0, 0.2, 1.0, 1.0)

var mode := MODE_OFF
## The NavmeshReader drawn in MODE_NSS; NpcSimulationServer sets it.
var navmesh: NavmeshReader
## The local maps drawn in MODE_GODOT; NpcSimulationServer sets it.
var local_navigation: LocalNavigation

var _mesh_instance := MeshInstance3D.new()
var _legend_layer := CanvasLayer.new()
var _legend := Label.new()
var _built_space := 0
var _built_center := Vector3.INF
var _since_check := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_mesh_instance.name = "Triangles"
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh_instance.material_override = _material()
	add_child(_mesh_instance)
	_legend_layer.layer = 90
	_legend_layer.visible = false
	add_child(_legend_layer)
	_legend.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_legend.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_legend.position.y = 8.0
	_legend.add_theme_color_override("font_outline_color", Color.BLACK)
	_legend.add_theme_constant_override("outline_size", 4)
	_legend_layer.add_child(_legend)


## Shows `new_mode` (MODE_OFF, MODE_NSS or MODE_GODOT); -1 moves to the next
## mode, after MODE_GODOT back to MODE_OFF. Returns the mode now shown.
func set_mode(new_mode: int) -> int:
	if new_mode < 0:
		new_mode = (mode + 1) % MODE_COUNT
	mode = clampi(new_mode, MODE_OFF, MODE_COUNT - 1)
	_mesh_instance.visible = mode != MODE_OFF
	_legend_layer.visible = mode != MODE_OFF
	_legend.text = _legend_text()
	_built_center = Vector3.INF
	if mode == MODE_OFF:
		_mesh_instance.mesh = null
	return mode


func _process(delta: float) -> void:
	if mode == MODE_OFF:
		return
	_since_check += delta
	if _since_check < CHECK_SECONDS:
		return
	_since_check = 0.0
	var camera := get_viewport().get_camera_3d()
	var player := ScriptServer.player_reference
	if camera == null or player == null:
		return
	var center := LocalNavigation.GAMEBRYO_TO_GODOT_BASIS.inverse() * camera.global_position
	var space := player.current_space_form_id
	if space == _built_space and Vector2(center.x - _built_center.x, center.y - _built_center.y).length() < REBUILD_DISTANCE:
		return
	if mode == MODE_NSS and navmesh != null:
		_build(space, center)
	elif mode == MODE_GODOT and local_navigation != null:
		_build_godot(space, center)


## Fetches the triangles of `space` within RADIUS of `center` (Gamebryo axes)
## and replaces the drawing with them.
func _build(space: int, center: Vector3) -> void:
	_built_space = space
	_built_center = center
	var data: Dictionary = navmesh.get_triangles_near(space, center, RADIUS)
	var points: PackedVector3Array = data["points"]
	var flags: PackedInt32Array = data["flags"]
	var cover: PackedInt32Array = data["cover_flags"]
	var open_edges: PackedInt32Array = data["open_edges"]
	var fill := SurfaceTool.new()
	fill.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lines := SurfaceTool.new()
	lines.begin(Mesh.PRIMITIVE_LINES)
	var lift := Vector3(0.0, LIFT, 0.0)
	for triangle in flags.size():
		var corners: Array[Vector3] = []
		for corner in 3:
			corners.append(LocalNavigation.to_godot(points[triangle * 3 + corner]) + lift)
		fill.set_color(_triangle_color(flags[triangle]))
		for corner in corners:
			fill.add_vertex(corner)
		for edge in 3:
			var a := corners[edge]
			var b := corners[(edge + 1) % 3]
			_add_line(lines, a, b, _edge_color(flags[triangle], open_edges[triangle], edge))
		for group in 2:
			var bits := (cover[triangle] >> (group * 6)) & 0x3F
			if bits != 0:
				_add_cover(fill, corners[group], corners[group + 1], bits)
	var mesh := ArrayMesh.new()
	if flags.size() > 0:
		fill.commit(mesh)
		lines.commit(mesh)
	_mesh_instance.mesh = mesh


## LocalNavigation's regions of `space` with polygons within RADIUS of
## `center` (Gamebryo axes), their edge-connection pathways and seam links.
func _build_godot(space: int, center: Vector3) -> void:
	_built_space = space
	_built_center = center
	var focus := LocalNavigation.to_godot(center)
	var fill := SurfaceTool.new()
	fill.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lines := SurfaceTool.new()
	lines.begin(Mesh.PRIMITIVE_LINES)
	var lift := Vector3(0.0, LIFT, 0.0)
	var drawn := 0
	for node in local_navigation.get_space_nodes(space):
		var region := node as NavigationRegion3D
		if region != null and region.navigation_mesh != null:
			drawn += _add_region(fill, lines, region, focus, lift)
			var rid := region.get_rid()
			for index in NavigationServer3D.region_get_connections_count(rid):
				var a := NavigationServer3D.region_get_connection_pathway_start(rid, index)
				var b := NavigationServer3D.region_get_connection_pathway_end(rid, index)
				if _near(a, focus):
					_add_line(lines, a + lift * 2.0, b + lift * 2.0, COLOR_LINK_EDGE)
					if a.distance_to(b) < 0.05:
						_add_line(lines, a + lift * 2.0, a + Vector3(0.0, 0.5, 0.0), COLOR_LINK_EDGE)
		var link := node as NavigationLink3D
		if link != null and _near(link.start_position, focus):
			_add_line(lines, link.start_position + lift, link.end_position + lift, COLOR_SEAM_LINK)
	var mesh := ArrayMesh.new()
	if drawn > 0:
		fill.commit(mesh)
		lines.commit(mesh)
	_mesh_instance.mesh = mesh


## One region's polygons within RADIUS of `focus` (Godot axes): filled and
## outlined. Returns how many were drawn.
func _add_region(fill: SurfaceTool, lines: SurfaceTool, region: NavigationRegion3D, focus: Vector3, lift: Vector3) -> int:
	var mesh := region.navigation_mesh
	var vertices := mesh.vertices
	var drawn := 0
	var color := Color.from_hsv(fmod(region.get_instance_id() * 0.618, 1.0), 0.6, 0.9, 0.35)
	for index in mesh.get_polygon_count():
		var polygon := mesh.get_polygon(index)
		if not _near(vertices[polygon[0]], focus):
			continue
		drawn += 1
		fill.set_color(color)
		for corner in range(1, polygon.size() - 1):
			fill.add_vertex(vertices[polygon[0]] + lift)
			fill.add_vertex(vertices[polygon[corner]] + lift)
			fill.add_vertex(vertices[polygon[corner + 1]] + lift)
		for corner in polygon.size():
			_add_line(lines, vertices[polygon[corner]] + lift, vertices[polygon[(corner + 1) % polygon.size()]] + lift, COLOR_OUTLINE)
	return drawn


func _near(point: Vector3, focus: Vector3) -> bool:
	return Vector2(point.x - focus.x, point.z - focus.z).length() <= RADIUS


## A quad standing on edge (a, b), its height and colour from the low four
## bits; a dark bar at a for bit 4 and at b for bit 5.
func _add_cover(fill: SurfaceTool, a: Vector3, b: Vector3, bits: int) -> void:
	var value := bits & 0x0F
	var height := maxf(value, 0.5) * COVER_HEIGHT_STEP
	_add_quad(fill, a, b, height, COLOR_COVER_LOW.lerp(COLOR_COVER_HIGH, value / 15.0))
	var bar := (b - a).normalized() * minf(0.15, a.distance_to(b) / 4.0)
	if bits & 0x10:
		_add_quad(fill, a, a + bar, height + 0.1, COLOR_COVER_SIDE)
	if bits & 0x20:
		_add_quad(fill, b - bar, b, height + 0.1, COLOR_COVER_SIDE)


func _add_quad(fill: SurfaceTool, a: Vector3, b: Vector3, height: float, color: Color) -> void:
	var up := Vector3(0.0, height, 0.0)
	fill.set_color(color)
	for corner in [a, b, b + up, a, b + up, a + up]:
		fill.add_vertex(corner)


func _add_line(lines: SurfaceTool, a: Vector3, b: Vector3, color: Color) -> void:
	lines.set_color(color)
	lines.add_vertex(a)
	lines.add_vertex(b)


func _triangle_color(flags: int) -> Color:
	if flags & FLAG_DOOR:
		return COLOR_DOOR
	if flags & FLAG_WATER:
		return COLOR_WATER
	if flags & FLAG_PREFERRED:
		return COLOR_PREFERRED
	if flags & FLAG_NO_LARGE_CREATURES:
		return COLOR_NO_LARGE_CREATURES
	return COLOR_PLAIN


## Link-flagged edges (Flags bit e) cross into another record; open edges
## have no neighbour at all.
func _edge_color(flags: int, open_edges: int, edge: int) -> Color:
	if flags & (1 << edge):
		return COLOR_LINK_EDGE
	if open_edges & (1 << edge):
		return COLOR_OPEN_EDGE
	return COLOR_OUTLINE


func _legend_text() -> String:
	if mode == MODE_GODOT:
		return "\n".join(PackedStringArray([
			"TNM 2: Godot's local navigation map within %d m" % RADIUS,
			"one colour per region (NAVM record)",
			"cyan: edge-connection pathway between regions (a post where it is a single point)",
			"magenta: seam link",
		]))
	if mode != MODE_NSS:
		return ""
	return "\n".join(PackedStringArray([
		"TNM 1: NSS navmesh within %d m" % RADIUS,
		"red: plain   purple: door (0x0400)   blue: water (0x0200)",
		"green: preferred (0x0040)   white: no large creatures (0x0010)",
		"cyan edge: crosses into another record   yellow edge: open",
		"quad: cover on that edge, height = low 4 bits x %.1f m, dark to white; black bars: bits 4, 5" % COVER_HEIGHT_STEP,
	]))


func _material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = false
	return material
