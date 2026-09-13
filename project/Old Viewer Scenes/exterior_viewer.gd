@tool
extends Node3D

const GameDataConfigScript := preload("res://game_data_config.gd")

# Editor-mode exterior (world) cell viewer — the WRLD/LAND counterpart to
# interior_viewer.gd. Loads a rectangular area of a worldspace's exterior
# cells (heightmap terrain + splatted textures + placed REFRs) as real child
# nodes of this scene while open in the Godot editor, so the editor's own 3D
# viewport navigation (right-click + WASD, scroll to zoom) and Scene dock
# work directly on the loaded area instead of only through a standalone
# runtime scene (test_exterior_cell.gd).
#
# Loading only happens when you press the "Load Area" button in the
# Inspector (not automatically on scene open) — each cell is its own
# terrain build plus up to ~100+ BSA/NIF/DDS object resolutions, and a wide
# grid range multiplies that fast.
#
# Terrain is built natively Y-up (see gamebryo/terrain_builder.gd's own
# doc comment on why) and placed as a sibling of the REFR content's
# rotated "world" node, not a child of it — same convention
# test_exterior_cell.gd / test_phase1_integration.gd use.
#
# Streamed/queued loading (a deliberate early preview of Phase 2's
# streaming needs, per phases/1/results.md's "world streaming needs
# deferred block/sub-block coordinate lookups" note — this is the loading-
# pacing half of that problem, not the coordinate-enumeration half):
# _do_load() is a coroutine that yields (`await get_tree().process_frame`)
# after every cell's terrain and every `objects_per_frame` placed REFRs,
# instead of building the whole area synchronously in one frame/one editor
# button click. Entirely GDScript-side — every individual EsmReader/
# BsaReader/NifReader call is already fast (single record/mesh), the cost
# is doing hundreds of them back to back with no yield point, so spreading
# them across frames is sufficient; no C++ threading was needed. A true
# background-thread loader (WorkerThreadPool et al) would be a further step
# beyond this, deliberately not attempted here: the GDExtension reader
# classes hold mutable internal state (BSA archive handle caches in
# GamebryoMeshResolver, the open ESM file handle in EsmReader) with no
# verified thread-safety, so calling them off the main thread needs its own
# investigation before it'd be safe, not assumed as a free upgrade from
# what's here.
const CELL_SIZE_UNITS := 4096.0
const GAMEBRYO_UNITS_TO_METERS := 1.0 / 70.0

@export var worldspace_editor_id: String = "WastelandNV"
@export var grid_x_min: int = -17
@export var grid_x_max: int = -17
@export var grid_y_min: int = 0
@export var grid_y_max: int = 0
## How many REFRs to place per frame before yielding — the knob for
## experimenting with streaming pace. 0 disables mid-cell yielding
## entirely (still yields once per cell), for comparing against the
## unbatched baseline.
@export var objects_per_frame: int = 20
@export_tool_button("Load Area") var load_button: Callable = _do_load
@export_tool_button("Cancel Load") var cancel_button: Callable = _cancel_load

var _loading := false
var _load_generation := 0

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

## Ends the previous in-flight load (if any) by bumping the generation
## counter. Every yield point in _do_load() below re-checks its own
## captured generation and bails out silently if it's stale, instead of
## touching a node tree a newer call has already replaced/freed — the
## simplest correct way to handle "user mashed the button again" without
## two coroutines racing to add children to the same/a freed AreaRoot.
func _cancel_load() -> void:
	if _loading:
		_load_generation += 1
		_loading = false
		print("exterior_viewer: cancelled in-flight load")

func _do_load() -> void:
	if grid_x_min > grid_x_max or grid_y_min > grid_y_max:
		push_error("grid_x_min/grid_y_min must not exceed grid_x_max/grid_y_max")
		return

	_load_generation += 1
	var my_generation := _load_generation
	_loading = true

	if has_node("AreaRoot"):
		# queue_free() defers actual removal to end-of-frame — the new
		# AreaRoot added a few lines below would collide names with the
		# still-present old one and get silently renamed "AreaRoot2" by
		# Godot, breaking get_node("AreaRoot") for callers/tests. Free
		# immediately instead; nothing here runs from a signal callback on
		# the freed node itself, so this is safe.
		var old_root := get_node("AreaRoot")
		remove_child(old_root)
		old_root.free()

	var esm := EsmReader.new()
	var data_dir := String(GameDataConfigScript.resolve().get("data_dir", ""))
	if not esm.open(data_dir + GameDataConfigScript.ESM_FILE):
		push_error("could not open FalloutNV.esm")
		_loading = false
		return

	var wrld: Dictionary = esm.find_worldspace_by_editor_id(worldspace_editor_id)
	if wrld.is_empty():
		push_error("worldspace not found: " + worldspace_editor_id)
		_loading = false
		return
	var wrld_form_id := int(wrld["form_id"])

	var area_root := Node3D.new()
	area_root.name = "AreaRoot"
	_add_child(self, area_root)

	var terrain_root := Node3D.new()
	terrain_root.name = "TerrainRoot"
	_add_child(area_root, terrain_root)

	var refr_root := Node3D.new()
	refr_root.name = "RefrRoot"
	refr_root.rotation_degrees.x = -90 # NIF/REFR Z-up -> Godot Y-up
	_add_child(area_root, refr_root)

	var resolver := GamebryoMeshResolver.new(data_dir)
	var registry := GamebryoObjectRegistry.new(resolver, esm)

	var cells_found := 0
	var cells_missing := 0
	var objects_placed := 0
	var objects_total := 0

	for gy in range(grid_y_min, grid_y_max + 1):
		for gx in range(grid_x_min, grid_x_max + 1):
			var cell: Dictionary = esm.find_exterior_cell(wrld_form_id, gx, gy)
			if cell.is_empty():
				cells_missing += 1
				continue
			cells_found += 1
			var cell_form_id := int(cell["form_id"])

			var land: Dictionary = esm.get_land_data(cell_form_id)
			if not land.is_empty():
				var quadrant_ltex: PackedInt64Array = land.get("quadrant_base_ltex", PackedInt64Array())
				var quadrant_textures: Array = []
				for i in range(quadrant_ltex.size()):
					var ltex_id := int(quadrant_ltex[i])
					var tex: Texture2D = null
					if ltex_id != 0:
						var tex_path := esm.resolve_ltex_texture_path(ltex_id)
						if tex_path != "":
							tex = resolver.load_texture("textures\\" + tex_path)
					quadrant_textures.append(tex)
				var terrain := GamebryoTerrainBuilder.build(land, quadrant_textures)
				if terrain != null:
					terrain.name = "terrain_%d_%d" % [gx, gy]
					terrain.position = Vector3(
							gx * CELL_SIZE_UNITS * GAMEBRYO_UNITS_TO_METERS,
							0.0,
							-(gy * CELL_SIZE_UNITS * GAMEBRYO_UNITS_TO_METERS))
					_add_child(terrain_root, terrain)

			var refs: Array = esm.get_cell_references(cell_form_id)
			objects_total += refs.size()
			var placed_since_yield := 0
			for p in refs:
				var node := registry.build(p)
				if node == null:
					continue
				_add_child(refr_root, node)
				objects_placed += 1
				placed_since_yield += 1
				if objects_per_frame > 0 and placed_since_yield >= objects_per_frame:
					placed_since_yield = 0
					print("exterior_viewer: streaming... cell (%d,%d), %d/%d objects placed so far" %
							[gx, gy, objects_placed, objects_total])
					await get_tree().process_frame
					if my_generation != _load_generation:
						return # superseded by a newer Load Area / Cancel Load press

			# One yield per cell minimum, even with objects_per_frame == 0 or
			# a cell with very few REFRs — keeps a wide-area, many-small-
			# cells load spread out too, not just large single cells.
			await get_tree().process_frame
			if my_generation != _load_generation:
				return

	print("exterior_viewer: done — %d cells loaded, %d probed coordinates empty, objects placed %d/%d" %
			[cells_found, cells_missing, objects_placed, objects_total])
	_loading = false
