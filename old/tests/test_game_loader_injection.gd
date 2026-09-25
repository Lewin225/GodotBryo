extends Node

const NifServerScript := preload("res://GodotBryo/Servers/NifServer/nif_server.gd")

var failures := 0
var _editor_fixture: Node3D = null
var _editor_model_fixtures: Array[Node3D] = []
var _editor_fixture_holder: Node3D = null

func check(condition: bool, message: String) -> void:
	if condition:
		print("  OK   ", message)
	else:
		print("  FAIL ", message)
		failures += 1

func _on_editor_fixture(tree: Node3D) -> void:
	_editor_fixture = tree


func _on_editor_model_fixture(tree: Node3D) -> void:
	if tree != null:
		_editor_model_fixtures.append(tree)
		if _editor_fixture_holder != null:
			_editor_fixture_holder.add_child(tree)

func _ready() -> void:
	var game: Node = load("res://game.tscn").instantiate()
	add_child(game)
	var cell: CellStreamerV2 = game.get_node("CellStreamerV2")
	var objects: WorldStreamerV2 = game.get_node("WorldStreamer")
	var terrain: TerrainStreamer = game.get_node("TerrainStreamer")
	check(cell != null
			and (cell.spawn_reference_types & CellStreamerV2.SPAWN_REFR) != 0
			and (cell.spawn_reference_types & CellStreamerV2.SPAWN_ACHR) != 0
			and (cell.spawn_reference_types & CellStreamerV2.SPAWN_CREA) == 0,
			"Game scene authors the typed interior streamer with REFR and ACHR enabled")
	check(terrain.esm != null and terrain.resolver != null,
			"Game._enter_tree still injects LAND's separate raw ESM/resolver pair")
	check(objects != null, "Game retains the typed WorldStreamerV2 exterior path")
	var editor_markers_check := game.get_node("Debug Tools/TabContainer/Editing/Margin/VBox/ShowEditorMarkers") as CheckBox
	check(editor_markers_check != null and not editor_markers_check.button_pressed,
			"Editing tab exposes Show Editor Markers off by default")
	var debug_menu := game.get_node_or_null("MenuBar/Debug") as PopupMenu
	check(debug_menu == null or debug_menu.get_item_index(100) < 0,
		"no top-bar menu owns the editor marker toggle")
	check(NifServerScript.is_editor_object_name("EditorMarker:0")
			and NifServerScript.is_editor_object_name("VisibilityEditorMarker:0")
			and not NifServerScript.is_editor_object_name("DustBillBoard01:0"),
			"NifServer identifies only verified embedded marker primitive names")
	check(NifServerScript.is_standalone_marker_model("MarkerCOCHeading.nif")
			and NifServerScript.is_standalone_marker_model("MarkerXHeading.nif")
			and NifServerScript.is_standalone_marker_model("Marker_Audio.NIF")
			and NifServerScript.is_standalone_marker_model("Marker_Map.nif")
			and not NifServerScript.is_standalone_marker_model("Effects/Ambient/Industrial/IndFXLightRays01.NIF"),
			"NifServer identifies standalone marker models from their NIF model identity")
	var nif_server = get_node("/root/NifServer")
	check(not nif_server.editor_objects_visible, "NifServer hides editor objects by default")
	editor_markers_check.button_pressed = true
	check(nif_server.editor_objects_visible and editor_markers_check.button_pressed,
			"Editing tab enables NifServer's shared editor-object policy")
	editor_markers_check.button_pressed = false
	check(not nif_server.editor_objects_visible and not editor_markers_check.button_pressed,
			"Editing tab disables NifServer's shared editor-object policy")
	var delivered_marker := MeshInstance3D.new()
	delivered_marker.set_meta(NifServerScript.META_EDITOR_OBJECT, true)
	delivered_marker.add_to_group(NifServerScript.EDITOR_OBJECT_GROUP)
	game.add_child(delivered_marker)
	nif_server.set_editor_objects_visible(false)
	nif_server.call("_apply_editor_object_visibility", delivered_marker)
	check(not delivered_marker.visible, "editor-object policy hides a late NifServer delivery without removing it")
	nif_server.set_editor_objects_visible(true)
	check(delivered_marker.visible, "editor-object policy restores a live marker mesh")
	delivered_marker.free()
	nif_server.request("effects/ambient/fxdustmeshsky01.nif", self, _on_editor_fixture)
	for _frame in 600:
		if _editor_fixture != null:
			break
		await get_tree().process_frame
	check(_editor_fixture != null, "NifServer delivers the real EditorMarker fixture")
	if _editor_fixture != null:
		game.add_child(_editor_fixture)
		var real_markers := get_tree().get_nodes_in_group("nif_editor_objects")
		check(not real_markers.is_empty(), "real NifServer fixture retains its EditorMarker mesh identity")
		nif_server.set_editor_objects_visible(false)
		var hidden := not real_markers.is_empty() and not (real_markers[0] as Node3D).visible
		check(hidden, "Debug policy hides the real NifServer EditorMarker mesh")
		nif_server.set_editor_objects_visible(true)
	var fixture_holder := Node3D.new()
	add_child(fixture_holder)
	_editor_fixture_holder = fixture_holder
	for marker_model in ["MarkerCOCHeading.nif", "MarkerXHeading.nif", "Marker_Audio.NIF", "Marker_Map.nif"]:
		nif_server.request(marker_model, self, _on_editor_model_fixture)
	for _frame in 600:
		if _editor_model_fixtures.size() == 4:
			break
		await get_tree().process_frame
	check(_editor_model_fixtures.size() == 4 and _editor_model_fixtures.all(func(fixture): return fixture.is_in_group(NifServerScript.EDITOR_OBJECT_GROUP)),
			"real COC, heading/spawn, audio, and map marker models retain NifServer editor-object identity")
	nif_server.set_editor_objects_visible(false)
	check(_editor_model_fixtures.size() == 4 and _editor_model_fixtures.all(func(fixture): return not fixture.visible),
			"Debug policy hides the real COC, heading/spawn, audio, and map marker model roots")
	nif_server.set_editor_objects_visible(true)
	game.free()
	print("=======================")
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(1 if failures else 0)
