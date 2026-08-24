extends Node

const GAME_SCRIPT := preload("res://game.gd")

var failures := 0

func check(ok: bool, message: String) -> void:
	print("  OK   " if ok else "  FAIL ", message)
	if not ok:
		failures += 1

func _ready() -> void:
	var game := GAME_SCRIPT.new()
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
