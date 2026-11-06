extends Node

## World item physics in Doc Mitchell's house, booted as a new game: every
## item with a moving body falls asleep soon after load without marking its
## reference dirty; a stacked item rests on another; freeing the bottom item's
## node is checked for whether Godot wakes the item above on its own; picking a
## bottom item up wakes the item above, which falls and sleeps again; a dropped
## item gets a node again in front of the player and comes to rest.

const SETTLE_SECONDS := 15.0

var failures := 0

func check(ok: bool, message: String) -> void:
	print("  OK   " if ok else "  FAIL ", message)
	if not ok:
		failures += 1

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var game := (load("res://game.tscn") as PackedScene).instantiate()
	add_child(game)
	var coordinator: TransitionCoordinator = game.transition_coordinator
	var house := int(EsmServer.reader.find_cell_by_editor_id("GSDocMitchellHouse").get("form_id", 0))
	var deadline := Time.get_ticks_msec() + 30000
	while (coordinator.loaded_space_form_id != house or coordinator.is_transitioning()) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	check(coordinator.loaded_space_form_id == house, "the game starts in Doc Mitchell's house")

	var items := await _items_with_bodies(game)
	check(items.size() > 0, "the house has items with moving bodies (%d)" % items.size())
	var started := Time.get_ticks_msec()
	while _awake(items) > 0 and Time.get_ticks_msec() - started < SETTLE_SECONDS * 1000.0:
		await get_tree().physics_frame
	var awake := _awake(items)
	check(awake == 0, "every item body is asleep after %.1f s (%d awake)" % [(Time.get_ticks_msec() - started) / 1000.0, awake])
	_report(items)
	var dirty := items.filter(func(item: EsmItemNode) -> bool: return item.reference.dirty)
	check(dirty.is_empty(), "settling marks no item reference dirty (%d dirty)" % dirty.size())

	var stacks := _stacks(items)
	check(stacks.size() > 0, "some items rest on others (%d stacks)" % stacks.size())
	if stacks.size() >= 2:
		await _free_without_waking(stacks.pop_back())
	if not stacks.is_empty():
		await _pick_up_bottom(stacks[0])

	await _drop_in_front(game)
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)


## Every EsmItemNode under `game` with a NifRigidBody, once their NIFs have
## stopped arriving.
func _items_with_bodies(game: Node) -> Array:
	var found: Array = []
	var stable_frames := 0
	var deadline := Time.get_ticks_msec() + 20000
	while stable_frames < 30 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		var now := _item_nodes(game)
		stable_frames = stable_frames + 1 if now.size() == found.size() else 0
		found = now
	return found


func _item_nodes(game: Node) -> Array:
	var result: Array = []
	for node in game.find_children("*", "Node3D", true, false):
		var item := node as EsmItemNode
		if item != null and item.body != null and item.body.is_inside_tree():
			result.append(item)
	return result


func _awake(items: Array) -> int:
	var count := 0
	for item: EsmItemNode in items:
		if is_instance_valid(item) and item.body != null and not item.body.sleeping:
			count += 1
	return count


## [bottom, top] pairs: a top item whose body rests over a bottom one, their
## bounds touching.
func _stacks(items: Array) -> Array:
	var result: Array = []
	var used := {}
	for top: EsmItemNode in items:
		for bottom: EsmItemNode in items:
			if top == bottom or used.has(top) or used.has(bottom):
				continue
			var top_bounds := top._collision_bounds()
			var bottom_bounds := bottom._collision_bounds().grow(EsmItemNode.NEIGHBOUR_MARGIN)
			var above := top.body.global_position.y > bottom.body.global_position.y + 0.005
			if above and top_bounds.intersects(bottom_bounds):
				result.append([bottom, top])
				used[top] = true
				used[bottom] = true
	return result


## Frees a bottom item's node without waking anything and reports whether the
## item above wakes on its own. Informational: the result says whether
## wake_neighbours() is needed on this physics engine.
func _free_without_waking(stack: Array) -> void:
	var bottom: EsmItemNode = stack[0]
	var top: EsmItemNode = stack[1]
	var name := String(top.reference.base.editor_id)
	bottom.get_parent().remove_child(bottom)
	bottom.queue_free()
	for i in 10:
		await get_tree().physics_frame
	print("  INFO freeing what %s rests on %s it (%s)" % [name, "wakes" if not top.body.sleeping else "does not wake", ProjectSettings.get_setting("physics/3d/physics_engine")])


## Picks up a bottom item as the player: the top item wakes, falls and sleeps
## again lower down.
func _pick_up_bottom(stack: Array) -> void:
	var bottom: EsmItemNode = stack[0]
	var top: EsmItemNode = stack[1]
	var player := EsmServer.get_player_reference()
	var top_start := top.body.global_position
	var picked := bottom.reference
	check(player.pick_up(picked), "the player picks up %s, under %s" % [picked.base.editor_id, top.reference.base.editor_id])
	check(picked.get_holder() == player and player.contents.get_items().any(func(entry: InventoryItem) -> bool: return entry.item_reference == picked),
		"it is in the player's inventory as its own reference")
	await get_tree().physics_frame
	check(not top.body.sleeping, "the item above wakes")
	var started := Time.get_ticks_msec()
	while not top.body.sleeping and Time.get_ticks_msec() - started < 5000:
		await get_tree().physics_frame
	check(top.body.sleeping and top.body.global_position.y < top_start.y - 0.005,
		"it falls and sleeps again (%.3f m lower)" % (top_start.y - top.body.global_position.y))
	await get_tree().process_frame
	check(EsmNode.node_for(picked) == null or not is_instance_valid(EsmNode.node_for(picked)), "the picked item's node is gone")


## Drops the first item the player holds: it is placed in the house, gets a
## node again and comes to rest, its reference dirty.
func _drop_in_front(game: Node) -> void:
	var player := EsmServer.get_player_reference()
	var held: EsmReference = null
	for entry in player.contents.get_items():
		if entry.item_reference != null:
			held = entry.item_reference
	if held == null:
		check(false, "the player holds an item to drop")
		return
	check(player.drop(held), "the player drops %s" % held.base.editor_id)
	check(held.get_holder() == null and held.current_cell_form_id == player.current_cell_form_id, "it is placed in the player's cell")
	var node: EsmItemNode = null
	var deadline := Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		node = EsmNode.node_for(held) as EsmItemNode
		if node != null and node.body != null and node.body.is_inside_tree():
			break
	check(node != null and node.body != null, "it gets a node with its body again")
	if node == null or node.body == null:
		return
	while not node.body.sleeping and Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
	check(node.body.sleeping, "it comes to rest")
	check(held.dirty and held.position.distance_to(player.position) < 3.0, "its reference is dirty, near the player")


## Prints each awake or moved item: how far its body is from its placement and
## how fast it moves.
func _report(items: Array) -> void:
	var lines := 0
	for item: EsmItemNode in items:
		var placed := EsmReferencePhysicaliser.placement_transform(item.reference.position, item.reference.rotation).origin
		var authored := EsmServer.get_authored_placement(item.reference)
		var moved := item.body.global_position.distance_to(item.global_position)
		if item.body.sleeping and not item.reference.dirty:
			continue
		if lines >= 25:
			return
		lines += 1
		var below := _below(item)
		print("  INFO below %s: %s" % [item.reference.base.editor_id, below])
		print("  INFO %s %s asleep=%s dirty=%s body y %.3f node y %.3f speed %.3f mass %.1f motion %d" % [item.reference.base.editor_id, item.reference.base.record_type, item.body.sleeping, item.reference.dirty, item.body.global_position.y, item.global_position.y, item.body.linear_velocity.length(), item.body.mass, item.body.motion_system])


## What a ray straight down from the item's placement hits within 3 m, by
## reference, and how far down.
func _below(item: EsmItemNode) -> String:
	var space := item.get_world_3d().direct_space_state
	var from := item.global_position + Vector3.UP * 0.2
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 3.0)
	var excluded: Array[RID] = [item.body.get_rid()]
	query.exclude = excluded
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return "nothing"
	var node: Node = hit["collider"]
	while node != null and not node is EsmNode:
		node = node.get_parent()
	var what := "%s %s" % [(node as EsmNode).reference.base.record_type, (node as EsmNode).reference.base.editor_id] if node != null else String(hit["collider"].name)
	return "%s at %.3f m down (%s)" % [what, from.y - (hit["position"] as Vector3).y - 0.2, hit["collider"].get_class()]
