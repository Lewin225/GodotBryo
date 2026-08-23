@tool
extends Node3D

# Editor-mode NIF node-graph inspector — load any single NIF by its
# MODL-style relative path (no "meshes\" prefix, e.g.
# "dlc04\architecture\backwoodshacks\dlc04shackdooranim01.nif", same
# convention as GamebryoMeshResolver.load_nif()) and see the REAL, full
# SceneNode hierarchy as real, named Node3D children right in the editor's
# own Scene dock and 3D viewport — no need to press Play. Same "press a
# button, not on scene open" convention as interior_viewer.gd/
# exterior_viewer.gd (a NIF this complex is real BSA/texture/mesh I/O, not
# instant — re-running it on every editor hiccup would be annoying). Click
# any built node to see its real local Transform in the Inspector; click a
# submesh to see its resolved material/texture.
#
# Deliberately thin: the actual hierarchy-building logic (mesh AND
# collision, both parented per their real owning_node_index) lives in
# GamebryoMeshResolver.populate_dynamic_children() (phases/3/00-door-
# completion.md step 5) — the SAME production code a real Dynamic object
# (a door, a lift) will be built through once something wires it in. This
# scene exists to exercise and inspect that real code path, not a
# parallel bespoke implementation of its own that could silently drift
# from what ships.
#
# Runs the exact same build in-editor and at runtime (Play): the editor
# path additionally owns every built node (so it's selectable via a real
# NodePath, not just visible) — mirrors interior_viewer.gd's own
# _add_child()/_own_recursive() convention. Don't save this scene with a
# NIF loaded unless you mean to commit that content; reload (or pick a
# different preset) first to clear it back out.

@export_enum(
	"Custom",
	"Door - Animated (DLC04 Shack)",
	"Elevator - Silo (complex)",
	"Door - Static/Teleport (Craftsman)",
	"Light - Chandelier (NiAmbientLight)"
) var preset: String = "Door - Animated (DLC04 Shack)"

## Only read when preset == "Custom". MODL-style relative path, no
## "meshes\" prefix -- e.g. "architecture\ncr\ncrgate01.nif".
@export var custom_nif_path: String = ""

## populate_dynamic_children() always builds real collision (a shipped
## Dynamic object always wants it) — this just hides it afterward for a
## cleaner view, purely a viewer convenience, not a parameter the
## production function itself needs.
@export var show_collision: bool = true

@export_tool_button("Load NIF") var load_button: Callable = _do_load

const PRESET_PATHS := {
	"Door - Animated (DLC04 Shack)": "dlc04\\architecture\\backwoodshacks\\dlc04shackdooranim01.nif",
	"Elevator - Silo (complex)": "nvdlc04\\dungeons\\silo\\silo_elevator\\nvdlc04_silo-elevator-shaft.nif",
	"Door - Static/Teleport (Craftsman)": "dungeons\\nv_craftsmanhomesinterior\\nvcraftsmanrmdoor.nif",
	# scene_nodes covers every NiAVObject, not just render shapes -- this
	# NiAmbientLight ('object0') shows up as a real, named node like any
	# other, confirmed via native/tools/light_survey.cpp (throwaway, not
	# committed) scanning for a real NiLight-bearing NIF rather than
	# guessing one. No Light3D is actually built from it yet (nif_loader.cpp
	# doesn't extract light data at all) -- this is here to inspect the
	# node graph, not to render the light.
	"Light - Chandelier (NiAmbientLight)": "dungeons\\caves\\lamplight\\lamplightchandelier.nif",
}

func _ready() -> void:
	if Engine.is_editor_hint():
		return # loading only happens on "Load NIF" -- see this file's own doc comment
	_do_load()

## Adds `child` under `parent` and, when running in the editor, sets its
## owner (and every descendant's, recursively) so it shows up in the Scene
## dock with a real, copyable NodePath instead of only being visible in the
## 3D viewport -- same convention as interior_viewer.gd's identically-named
## helper.
func _add_child(parent: Node, child: Node) -> void:
	parent.add_child(child)
	if Engine.is_editor_hint():
		_own_recursive(child)

func _own_recursive(node: Node) -> void:
	node.owner = get_tree().edited_scene_root
	for c in node.get_children():
		_own_recursive(c)

func _do_load() -> void:
	if has_node("NifRoot"):
		get_node("NifRoot").queue_free()

	var model_path: String = PRESET_PATHS.get(preset, custom_nif_path)
	if model_path.is_empty():
		push_error("nif_viewer: no path -- set custom_nif_path (preset is Custom)")
		return

	var resolver := GamebryoMeshResolver.new()
	var nif := resolver.load_nif(model_path)
	if nif == null:
		push_error("nif_viewer: could not load '" + model_path + "' -- not found in any BSA or unparseable")
		return

	# Own child, isolated from `self` -- carries the fixed NIF/REFR Z-up ->
	# Godot Y-up axis conversion (world_streamer.gd's refr_root does the
	# same thing at the cell root, in the real game; a lone NIF here has no
	# cell root of its own to inherit it from) without also rotating this
	# script's own node (which, at runtime, additionally parents the
	# free-fly camera -- rotating that too would make WASD fly sideways).
	var nif_root := Node3D.new()
	nif_root.name = "NifRoot"
	nif_root.rotation_degrees.x = -90
	_add_child(self, nif_root)

	var geometry := resolver.build_geometry_entries(resolver.resolve_raw_geometry(nif, model_path))
	resolver.populate_dynamic_children(nif_root, nif, model_path, geometry)
	if not show_collision:
		for body in _collision_bodies(nif_root):
			body.free()
	if Engine.is_editor_hint():
		_own_recursive(nif_root) # populate_dynamic_children() adds its own children directly, bypassing _add_child()

	_print_report(model_path, nif)

	if Engine.is_editor_hint():
		return # editor's own viewport already has camera/navigation -- nothing more to add
	_setup_runtime_camera(nif_root)

func _setup_runtime_camera(nif_root: Node3D) -> void:
	var combined_aabb := AABB()
	var have_aabb := false
	for mi in _mesh_instances(nif_root):
		var world_aabb: AABB = mi.global_transform * mi.mesh.get_aabb()
		combined_aabb = world_aabb if not have_aabb else combined_aabb.merge(world_aabb)
		have_aabb = true

	var cam := Camera3D.new()
	cam.set_script(load("res://free_cam.gd"))
	add_child(cam)
	if have_aabb:
		var center: Vector3 = combined_aabb.get_center()
		var radius: float = maxf(combined_aabb.size.length() * 0.6, 2.0)
		cam.global_position = center + Vector3(radius * 0.7, radius * 0.5, radius * 0.7)
		cam.look_at(center, Vector3.UP)
	cam.far = 2000.0
	cam.make_current()

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, -30, 0)
	sun.light_energy = 1.3
	add_child(sun)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.5, 0.6, 0.75)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.65)
	env.ambient_light_energy = 0.8
	env_node.environment = env
	add_child(env_node)

	print("--- WASD to move, mouse to look, Space/Ctrl for up/down, Shift to go faster, Escape to release the mouse ---")

func _print_report(model_path: String, nif: NifReader) -> void:
	print("=== ", model_path, " (", nif.get_nif_version(), ") ===")
	print("  submeshes: ", nif.get_submesh_count(), "  scene_nodes: ", nif.get_scene_nodes().size(),
			"  collision_shapes: ", nif.get_collision_shapes().size())
	var seqs: Array = nif.get_animation_sequences()
	print("  animation sequences: ", seqs.size())
	for s in seqs:
		var targets: Array = []
		for t in s["tracks"]:
			targets.append(t["target_node_name"])
		print("    '", s["name"], "' cycle_type=", s["cycle_type"], " tracks=", s["tracks"].size(), " targets=", targets)

func _mesh_instances(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D:
		out.append(node)
	for c in node.get_children():
		out.append_array(_mesh_instances(c))
	return out

func _collision_bodies(node: Node) -> Array:
	var out: Array = []
	if node is GamebryoCollisionBody:
		out.append(node)
	for c in node.get_children():
		out.append_array(_collision_bodies(c))
	return out
