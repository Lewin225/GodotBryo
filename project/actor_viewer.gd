@tool
extends Node3D

const GameDataConfigScript := preload("res://game_data_config.gd")

# Standalone actor viewer (issue #52) -- interior_viewer.gd's own sibling,
# but for ACHR/ACRE (EsmReader.get_cell_actors()) instead of REFR
# (get_cell_references()). Populates a single cell's placed
# NPC_/CREA actors as real child nodes while open in the Godot editor, via
# the exact same GamebryoObjectRegistry.build() dispatch interior_viewer.gd
# uses -- NPCNode gets the real full humanoid assembly (issue #52 chunks
# 2/4), CreatureNode stays a thin leaf (see creature_node.gd's own doc
# comment for why).
#
# Interior AND exterior both work here (unlike interior_viewer.gd) since
# actors don't need LAND/terrain -- just find_cell_by_editor_id() (interior)
# or find_exterior_cell() via worldspace_editor_id+grid (exterior).

@export var cell_editor_id: String = "GSDocMitchellHouse"
@export var worldspace_editor_id: String = "" # non-empty switches to exterior lookup via cell_grid_x/y instead of cell_editor_id
@export var cell_grid_x: int = -17
@export var cell_grid_y: int = 0
@export_tool_button("Load Actors") var load_button: Callable = _do_load

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
	if has_node("ActorRoot"):
		get_node("ActorRoot").queue_free()

	var esm := EsmReader.new()
	var data_dir := String(GameDataConfigScript.resolve().get("data_dir", ""))
	if not esm.open(data_dir + GameDataConfigScript.ESM_FILE):
		push_error("could not open FalloutNV.esm")
		return

	var cell: Dictionary
	if worldspace_editor_id != "":
		var wrld: Dictionary = esm.find_worldspace_by_editor_id(worldspace_editor_id)
		if wrld.is_empty():
			push_error("worldspace not found: " + worldspace_editor_id)
			return
		cell = esm.find_exterior_cell(int(wrld["form_id"]), cell_grid_x, cell_grid_y)
		if cell.is_empty():
			push_error("exterior cell not found: %s (%d,%d)" % [worldspace_editor_id, cell_grid_x, cell_grid_y])
			return
	else:
		cell = esm.find_cell_by_editor_id(cell_editor_id)
		if cell.is_empty():
			push_error("cell not found: " + cell_editor_id)
			return

	var world := Node3D.new()
	world.name = "ActorRoot"
	world.rotation_degrees.x = -90 # NIF Z-up -> Godot Y-up
	_add_child(self, world)

	var resolver := GamebryoMeshResolver.new(data_dir)
	var registry := GamebryoObjectRegistry.new(resolver, esm)

	var actors: Array = esm.get_cell_actors(int(cell["form_id"]))
	print("placing ", actors.size(), " actors...")

	var placed := 0
	for p in actors:
		var node := registry.build(p)
		if node == null:
			continue
		_add_child(world, node)
		placed += 1
		print("  placed ", node.name, " (", node.get_class(), ")")

	print("placed ", placed, "/", actors.size())
