@tool
extends Node3D

# Editor-mode NIF node-graph inspector — load any single NIF by its
# MODL-style relative path (no "meshes\" prefix, e.g.
# "dlc04\architecture\backwoodshacks\dlc04shackdooranim01.nif", same
# convention as GamebryoMeshResolver.load_nif()) and see the REAL, full
# SceneNode hierarchy (phases/3/00-door-completion.md step 4) as real,
# named Node3D children right in the editor's own Scene dock and 3D
# viewport — no need to press Play. Same "press a button, not on scene
# open" convention as interior_viewer.gd/exterior_viewer.gd (a NIF this
# complex is real BSA/texture/mesh I/O, not instant — re-running it on
# every editor hiccup would be annoying). Click any built node to see its
# real local Transform in the Inspector; click a submesh to see its
# resolved material/texture, exactly like inspecting any other scene.
#
# Runs the exact same build in-editor and at runtime (Play): the editor
# path additionally owns every built node (so it's selectable via a real
# NodePath, not just visible) — mirrors interior_viewer.gd's own
# _add_child()/_own_recursive() convention. Don't save this scene with a
# NIF loaded unless you mean to commit that content; Reload/pick a
# different preset first to clear it back out.

@export_enum(
	"Custom",
	"Door - Animated (DLC04 Shack)",
	"Elevator - Silo (complex)",
	"Door - Static/Teleport (Craftsman)"
) var preset: String = "Door - Animated (DLC04 Shack)"

## Only read when preset == "Custom". MODL-style relative path, no
## "meshes\" prefix -- e.g. "architecture\ncr\ncrgate01.nif".
@export var custom_nif_path: String = ""

## Flattened collision wireframe via the same, already-proven
## populate_collision_children() Static-path helper -- not built
## hierarchically under scene_nodes (CollisionShape's own owning_node_index
## isn't threaded through build_geometry_entries()'s shape_entries), but
## correct in world position either way; good enough for visual sanity
## checking in this tool.
@export var show_collision: bool = true

@export_tool_button("Load NIF") var load_button: Callable = _do_load

const PRESET_PATHS := {
	"Door - Animated (DLC04 Shack)": "dlc04\\architecture\\backwoodshacks\\dlc04shackdooranim01.nif",
	"Elevator - Silo (complex)": "nvdlc04\\dungeons\\silo\\silo_elevator\\nvdlc04_silo-elevator-shaft.nif",
	"Door - Static/Teleport (Craftsman)": "dungeons\\nv_craftsmanhomesinterior\\nvcraftsmanrmdoor.nif",
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
	if has_node("World"):
		get_node("World").queue_free()

	var model_path: String = PRESET_PATHS.get(preset, custom_nif_path)
	if model_path.is_empty():
		push_error("nif_viewer: no path -- set custom_nif_path (preset is Custom)")
		return

	var resolver := GamebryoMeshResolver.new()
	var nif := resolver.load_nif(model_path)
	if nif == null:
		push_error("nif_viewer: could not load '" + model_path + "' -- not found in any BSA or unparseable")
		return

	var world := Node3D.new()
	world.name = "World"
	world.rotation_degrees.x = -90 # NIF Z-up -> Godot Y-up, same convention as cell_viewer.gd
	_add_child(self, world)

	var built := _build_scene_node_tree(world, nif)
	_populate_submeshes(built, resolver, nif, model_path)
	if show_collision:
		resolver.populate_collision_children(world, nif, model_path)
	if Engine.is_editor_hint():
		_own_recursive(world) # populate_mesh/collision_children() added their own children directly, bypassing _add_child()

	_print_report(model_path, nif)

	if Engine.is_editor_hint():
		return # editor's own viewport already has camera/navigation -- nothing more to add
	_setup_runtime_camera(world)

func _setup_runtime_camera(world: Node3D) -> void:
	var combined_aabb := AABB()
	var have_aabb := false
	for mi in _mesh_instances(world):
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

## Builds one real Node3D per nif::SceneNode entry (nif_types.h), parented
## and locally-transformed exactly per get_scene_nodes()'s own parent_index/
## transform fields -- this IS the Dynamic-path hierarchy a future
## mesh_resolver.gd builder would construct, just without the typed
## GamebryoReference/GamebryoCollisionBody wrapper classes, so a submesh's
## flattened get_transform(i) and this tree's composed result are
## mathematically identical (both walk the same NiAVObject parent chain --
## see flatten_to_root()'s and SceneNode's own doc comments in
## native/src/nif/nif_loader.cpp / nif_types.h).
##
## Returns the array of built Node3D, indexed exactly like get_scene_nodes()
## -- entry i's Node3D is built[i], so callers can resolve
## get_submesh_owning_node_index()/get_collision_shapes()'s
## "owning_node_index" directly.
func _build_scene_node_tree(root: Node3D, nif: NifReader) -> Array:
	var entries: Array = nif.get_scene_nodes()
	var built: Array = []
	built.resize(entries.size())
	for i in entries.size():
		var e: Dictionary = entries[i]
		var n3d := Node3D.new()
		var raw_name: String = e["name"] if not String(e["name"]).is_empty() else "SceneNode%d" % i
		n3d.name = raw_name.validate_node_name()
		n3d.transform = e["transform"]
		built[i] = n3d

	# Attach in dependency order: real NIFs always emit a parent block
	# before its children (needed for the format's own streaming parse), so
	# a single forward pass normally suffices -- but this loop tolerates
	# any order via repeated passes, since scene_nodes is small enough
	# (bounded by one NIF's own block count) for that to cost nothing real.
	var attached: Array = []
	attached.resize(entries.size())
	attached.fill(false)
	var remaining := entries.size()
	while remaining > 0:
		var progressed := false
		for i in entries.size():
			if attached[i]:
				continue
			var parent_index: int = entries[i]["parent_index"]
			var parent: Node3D = root if parent_index == -1 else (built[parent_index] if attached[parent_index] else null)
			if parent_index != -1 and not attached[parent_index]:
				continue
			parent.add_child(built[i])
			attached[i] = true
			remaining -= 1
			progressed = true
		if not progressed:
			push_error("nif_viewer: scene_nodes has a parent_index cycle -- %d node(s) left unattached" % remaining)
			break
	return built

## One MeshInstance3D per submesh (real resolved texture/material, via the
## same build_geometry_entries() the Static path itself uses), parented
## under its owning_node_index's Node3D with an IDENTITY local transform --
## the owning node's own composed transform chain already reconstructs
## get_transform(i)'s flattened result, so this deliberately does NOT also
## apply entry["transform"] (that would double-apply it).
func _populate_submeshes(built: Array, resolver: GamebryoMeshResolver, nif: NifReader, model_path: String) -> void:
	var geometry := resolver.build_geometry_entries(resolver.resolve_raw_geometry(nif, model_path))
	var i := 0
	for entry in geometry["mesh_entries"]:
		var owning: int = nif.get_submesh_owning_node_index(i)
		var parent: Node3D = built[owning] if owning >= 0 and owning < built.size() else built[0] if not built.is_empty() else null
		var mi := MeshInstance3D.new()
		mi.name = ("sub%d_%s" % [i, nif.get_submesh_name(i)]).validate_node_name()
		mi.mesh = entry["mesh"]
		if parent != null:
			parent.add_child(mi)
		else:
			add_child(mi) # no scene_nodes at all (rare -- e.g. a single-node NIF with everything on the excluded root)
		i += 1

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
