extends Node

const GAME_SCRIPT := preload("res://game.gd")

var failures := 0

func check(ok: bool, message: String) -> void:
	print("  OK   " if ok else "  FAIL ", message)
	if not ok:
		failures += 1

func _ready() -> void:
	var xcll_basis := GAME_SCRIPT._xcll_directional_basis(0, 270)
	check((xcll_basis * Vector3.FORWARD).is_equal_approx(Vector3.DOWN), "XCLL 0/270 directional rotation emits vertically down after axis conversion")

	var game := GAME_SCRIPT.new()
	game._interior_directional_light = DirectionalLight3D.new()
	game.add_child(game._interior_directional_light)
	game._apply_xcll_directional_light({
		"directional_color": Color(0.2, 0.3, 0.4),
		"directional_fade": 0.5,
		"directional_rotation_xy": 0,
		"directional_rotation_z": 270,
	})
	check(game._interior_directional_light.visible, "enables a non-black XCLL directional light")
	check(is_equal_approx(game._interior_directional_light.light_energy, 0.5), "uses XCLL directional fade as directional-light energy")
	game._apply_xcll_directional_light({
		"directional_color": Color.BLACK,
		"directional_fade": 1.0,
		"directional_rotation_xy": 35,
		"directional_rotation_z": 270,
	})
	check(not game._interior_directional_light.visible, "keeps a black XCLL directional source disabled")

	var streamed_content := Node.new()
	streamed_content.name = "CellLoader"
	game.add_child(streamed_content)
	for index in 200:
		var child := Node.new()
		streamed_content.add_child(child)

	var first := CharacterBody3D.new()
	first.name = "Character"
	game.add_child(first)
	check(game._get_character_body() == first, "resolves the scene-authored direct Character child")
	check(game._get_character_body() == first, "reuses the cached CharacterBody3D")

	first.free()
	var replacement := CharacterBody3D.new()
	replacement.name = "Character"
	game.add_child(replacement)
	check(game._get_character_body() == replacement, "re-resolves direct Character child after cache invalidation")

	game.free()
	_finish()

func _finish() -> void:
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
