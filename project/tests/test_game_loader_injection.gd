extends Node

var failures := 0

func check(condition: bool, message: String) -> void:
	if condition:
		print("  OK   ", message)
	else:
		print("  FAIL ", message)
		failures += 1

func _ready() -> void:
	var game: Node = load("res://game.tscn").instantiate()
	add_child(game)
	var cell: CellLoader = game.get_node("CellLoader")
	var objects: WorldStreamer = game.get_node("WorldStreamer")
	var terrain: TerrainStreamer = game.get_node("TerrainStreamer")
	check(cell.esm != null and cell.esm == objects.esm and cell.esm == terrain.esm,
			"Game._enter_tree injects one shared main-thread EsmReader before child readiness")
	check(cell.resolver != null and cell.resolver == objects.resolver and cell.resolver == terrain.resolver,
			"Game._enter_tree injects one shared main-thread mesh resolver before child readiness")
	check(objects.terrain_streamer == terrain,
			"WorldStreamer receives only the scene-authored terrain priority owner")
	game.free()
	print("=======================")
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(1 if failures else 0)
