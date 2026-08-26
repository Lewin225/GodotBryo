extends Node

var failures := 0

func check(condition: bool, message: String) -> void:
	if condition:
		print("  OK   ", message)
	else:
		print("  FAIL ", message)
		failures += 1

func _ready() -> void:
	check(sample_owner_candidates(17, 9) == [Vector2i(0, -1)],
			"an interior sample has one owner")
	check(sample_owner_candidates(32, 9) == [Vector2i(0, -1), Vector2i(1, -1)],
			"an X edge is ordered by lowest (x, y)")
	check(sample_owner_candidates(17, 0) == [Vector2i(0, -1), Vector2i(0, 0)],
			"a Z edge is ordered by lowest (x, y)")
	check(sample_owner_candidates(32, 0) == [
		Vector2i(0, -1), Vector2i(0, 0), Vector2i(1, -1), Vector2i(1, 0),
	], "a corner checks all contributors in lexicographic order")
	var candidates := sample_owner_candidates(32, 0)
	var usable := {Vector2i(0, 0): true, Vector2i(1, -1): true}
	var selected := Vector2i(999, 999)
	for candidate in candidates:
		if usable.has(candidate):
			selected = candidate
			break
	check(selected == Vector2i(0, 0),
			"a missing lowest contributor falls through to the next usable owner")
	print("=======================")
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(1 if failures else 0)

static func sample_owner_candidates(global_x: int, global_z: int) -> Array[Vector2i]:
	var primary := Vector2i(_floor_div(global_x, 32), -_floor_div(global_z, 32) - 1)
	var xs: Array[int] = [primary.x]
	var ys: Array[int] = [primary.y]
	if global_x % 32 == 0: xs.append(primary.x - 1)
	if global_z % 32 == 0: ys.append(primary.y + 1)
	var candidates: Array[Vector2i] = []
	for x in xs:
		for y in ys: candidates.append(Vector2i(x, y))
	candidates.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.x < b.x or (a.x == b.x and a.y < b.y))
	return candidates

static func _floor_div(value: int, divisor: int) -> int:
	var q := value / divisor
	var r := value % divisor
	if r != 0 and ((r < 0) != (divisor < 0)): q -= 1
	return q
