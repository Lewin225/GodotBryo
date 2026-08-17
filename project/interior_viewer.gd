@tool
extends Node3D

# Editor-mode interior cell viewer (formerly cell_viewer_editor.gd — renamed
# once exterior_viewer.gd gave world cells their own editor tool). Populates
# a single interior CELL's REFRs as real child nodes of this scene while
# open in the Godot editor, so you can use the editor's own 3D viewport
# navigation (right-click + WASD, scroll to zoom) and the Scene dock /
# inspector to poke around individual objects, instead of the standalone
# runtime viewer's (cell_viewer.gd) custom free-cam. Loading only happens
# when you press the "Load Cell" button in the Inspector (not automatically
# on scene open) since it's a few hundred BSA/NIF/DDS resolutions — not
# instant, and re-triggering on every editor hiccup would be annoying.
#
# Interior-only — no WRLD/LAND handling. exterior_viewer.gd is the world-cell
# counterpart.
#
# Routes through the real GamebryoObjectRegistry
# (phases/1/01-object-type-registry.md) instead of the ad hoc "any REFR with
# a model" heuristic this started as — typed nodes (DoorNode/ContainerNode/
# ...) show up correctly named in the Scene dock.

const DATA_DIR := "/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/"

@export var cell_editor_id: String = "GSDocMitchellHouse"
@export_tool_button("Load Cell") var load_button: Callable = _do_load

# Adds `child` under `parent` and, when running in the editor, sets its
# owner (and every descendant's, recursively — registry.build() returns
# whole subtrees already populated with MeshInstance3D children, not just a
# single node) so everything actually shows up in the Scene dock with a
# real, copyable NodePath instead of only being visible in the 3D viewport.
func _add_child(parent: Node, child: Node) -> void:
	parent.add_child(child)
	if Engine.is_editor_hint():
		_own_recursive(child)

func _own_recursive(node: Node) -> void:
	node.owner = get_tree().edited_scene_root
	for c in node.get_children():
		_own_recursive(c)

func ensure_lighting() -> void:
	if not has_node("EditorPreviewLight"):
		var sun := DirectionalLight3D.new()
		sun.name = "EditorPreviewLight"
		sun.rotation_degrees = Vector3(-45, -30, 0)
		sun.light_energy = 1.3
		_add_child(self, sun)
	if not has_node("EditorPreviewEnv"):
		var env_node := WorldEnvironment.new()
		env_node.name = "EditorPreviewEnv"
		var env := Environment.new()
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.5, 0.6, 0.75)
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(0.6, 0.6, 0.65)
		env.ambient_light_energy = 0.8
		env_node.environment = env
		_add_child(self, env_node)

func _ready() -> void:
	ensure_lighting()

func _do_load() -> void:
	if has_node("CellRoot"):
		get_node("CellRoot").queue_free()

	var esm := EsmReader.new()
	if not esm.open(DATA_DIR + "FalloutNV.esm"):
		push_error("could not open FalloutNV.esm")
		return

	var cell: Dictionary = esm.find_cell_by_editor_id(cell_editor_id)
	if cell.is_empty():
		push_error("cell not found: " + cell_editor_id)
		return

	var world := Node3D.new()
	world.name = "CellRoot"
	world.rotation_degrees.x = -90 # NIF Z-up -> Godot Y-up
	_add_child(self, world)

	var resolver := GamebryoMeshResolver.new()
	var registry := GamebryoObjectRegistry.new(resolver, esm)

	var refs: Array = esm.get_cell_references(int(cell["form_id"]))
	print("placing ", refs.size(), " references from ", cell_editor_id, "...")

	var placed := 0
	for p in refs:
		var node := registry.build(p)
		if node == null:
			continue
		_add_child(world, node)
		placed += 1

	print("placed ", placed, "/", refs.size())
