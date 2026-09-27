extends Node

## Boots game.tscn and drives the player through real transitions: the
## startup spawn, a load door out of Doc Mitchell's house, a same-space
## teleport outside, the door back in, and COC into another interior.

const TIMEOUT_MSEC := 90000

var failures := 0

func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1

func _await_space(coordinator: TransitionCoordinator, space_form_id: int) -> bool:
	var deadline := Time.get_ticks_msec() + TIMEOUT_MSEC
	while (coordinator.loaded_space_form_id != space_form_id or coordinator.is_transitioning()) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	for _frame in 3:
		await get_tree().physics_frame
	return coordinator.loaded_space_form_id == space_form_id

func _body_at(player: PlayerController, position: Vector3) -> bool:
	return EsmReferencePhysicaliser.authored_position(player.global_position).distance_to(position) < 0.5

func _ready() -> void:
	var esm_server = get_node("/root/EsmServer")
	if not esm_server.is_ready():
		await esm_server.esm_ready
	var script_server = get_node("/root/ScriptServer")
	var house := int(esm_server.reader.find_cell_by_editor_id("GSDocMitchellHouse").get("form_id", 0))
	var wasteland := int(esm_server.reader.find_worldspace_by_editor_id("WastelandNV").get("form_id", 0))

	var game: Node3D = (load("res://game.tscn") as PackedScene).instantiate()
	add_child(game)
	var coordinator: TransitionCoordinator = game.transition_coordinator
	var player: PlayerController = game.player
	var player_ref: ActorReference = esm_server.get_player_reference()

	# Startup: the player's reference is moved to the default CELL's COC marker.
	check(await _await_space(coordinator, house), "startup loads GSDocMitchellHouse")
	check(player.possessed == player_ref and script_server.player_reference == player_ref, "the controller possesses the player's reference")
	check(player_ref.current_space_form_id == house and player_ref.current_cell_form_id == house, "the player's reference is in the house")
	check(not player.frozen, "the body is released after the load")
	check(EsmNode.node_for(player_ref) == null, "the possessed reference has no node of its own")
	var coc: EsmReference = null
	for reference in esm_server.get_references_in_cell(house):
		if reference.base != null and reference.base.editor_id == "COCMarkerHeading":
			coc = reference
	check(coc != null and _body_at(player, coc.position), "the body stands at the COC marker")
	var doc: EsmReference = esm_server.find_reference_by_editor_id("DocMitchellREF")
	check(script_server.is_reference_loaded(doc) and doc.script_instance != null, "Doc Mitchell's script is loaded with his house")
	check(doc.script_instance != null and doc.script_instance.get_local("PlayerLeft") == 0, "DocMitchellREF.PlayerLeft starts at 0")

	# Player-facing UI lives on the player.
	check(script_server.message_box == player.message_box and player.message_box != null, "ShowMessage presents on the player's message box")
	var terminal := TerminalReference.new()
	terminal.base = esm_server.get_base(0x00166B56)
	script_server.activate(terminal, player_ref)
	check(player_ref.using == terminal and player.terminal_session.visible, "using a terminal opens the player's terminal session")
	check(not player.is_physics_processing() and not player.is_processing_unhandled_input(), "the body takes no input while the terminal is open")
	player.terminal_session.close_session()
	check(player_ref.using == null and terminal.used_by == null, "closing the session ends the use")
	check(player.is_physics_processing() and player.is_processing_unhandled_input(), "input returns when the session closes")

	_check_locks_and_terminal_scripts(esm_server, script_server, player, player_ref)

	# The body writes its position to the reference.
	player.global_position += Vector3(0.5, 0, 0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	check(player_ref.position.is_equal_approx(EsmReferencePhysicaliser.authored_position(player.global_position)), "the body syncs its position to the reference")

	# Out through the front door, activated through the controller.
	var front_door: DoorReference = null
	for reference in esm_server.get_references_in_cell(house):
		if reference is DoorReference and reference.teleport != null and not reference.is_locked \
				and reference.teleport.get_destination_space_form_id() == wasteland:
			front_door = reference
	check(front_door != null and EsmNode.node_for(front_door) != null, "the house has a loaded load door to WastelandNV")
	if front_door == null:
		_finish()
		return
	player.interact_ray.current_target = EsmNode.node_for(front_door)
	player.request_activate()
	check(await _await_space(coordinator, wasteland), "activating the door loads WastelandNV")
	check(player_ref.current_space_form_id == wasteland and _body_at(player, front_door.teleport.position), "the body lands at the door's XTEL landing")
	check(doc.script_instance.get_local("PlayerLeft") == 1 and not script_server.is_reference_loaded(doc), "leaving sets PlayerLeft and unloads Doc's script")
	var tile_root: Node3D = game.world_streamer._resident.get(esm_server.exterior_grid_coord(player_ref.position))
	var outside_scripted: Array[EsmReference] = []
	for reference in (tile_root.get_meta("references", []) if tile_root != null else []):
		if reference.base != null and reference.base.script_form_id != 0:
			outside_scripted.append(reference)
	check(not outside_scripted.is_empty() and outside_scripted.all(func(r): return script_server.is_reference_loaded(r)),
			"scripted references in the player's tile are loaded (%d)" % outside_scripted.size())
	check(not player.frozen, "the body is released outside")
	check(game.sun.visible and game.world_environment.environment != game.INTERIOR_ENVIRONMENT, "the exterior environment is active")

	# A teleport within the loaded worldspace moves the body without a load.
	var aside: Vector3 = front_door.teleport.position + Vector3(3, 0, 0)
	script_server.move_reference(player_ref, wasteland, aside, front_door.teleport.rotation)
	await get_tree().process_frame
	await get_tree().physics_frame
	check(coordinator.loaded_space_form_id == wasteland and not coordinator.is_transitioning() and _body_at(player, aside), "a same-space teleport repositions the body directly")

	# Back in through the outside door.
	var outside_door: DoorReference = front_door.teleport.destination
	check(outside_door != null and outside_door.teleport.get_destination_space_form_id() == house, "the outside door leads back into the house")
	script_server.activate(outside_door, player_ref)
	check(await _await_space(coordinator, house), "activating it loads the house again")
	check(_body_at(player, outside_door.teleport.position), "the body lands inside at the door's XTEL landing")
	check(not game.sun.visible, "the interior environment is active again")
	check(not outside_scripted.any(func(r): return script_server.is_reference_loaded(r)), "the paused exterior's scripts are unloaded")

	# An exterior object with a node in the paused exterior moves into the house.
	var visitor: EsmReference = null
	for child in (tile_root.get_children() if tile_root != null else []):
		if child is EsmNode and not child.reference is ActorReference and not child.reference is CreatureReference:
			visitor = child.reference
			break
	check(visitor != null, "the paused exterior tile has a physicalised object")
	if visitor != null:
		var outside_node := EsmNode.node_for(visitor)
		var outside_position := visitor.position
		script_server.move_reference(visitor, house, outside_door.teleport.position + Vector3(0, 0, 1), visitor.rotation)
		await get_tree().process_frame
		await get_tree().process_frame
		var inside_node := EsmNode.node_for(visitor)
		check(inside_node != null and inside_node.get_parent() == game.cell_streamer._current, "an exterior object moved into the loaded interior appears there")
		check(not is_instance_valid(outside_node) or not outside_node.is_inside_tree(), "its node in the paused exterior is removed")
		script_server.move_reference(visitor, wasteland, outside_position, visitor.rotation)
		await get_tree().process_frame
		await get_tree().process_frame
		var back_node := EsmNode.node_for(visitor)
		check(back_node != null and back_node.get_parent() == tile_root, "moved back out, it returns to the retained exterior tile")

	# COC moves the player's reference; the load follows.
	var saloon := int(esm_server.reader.find_cell_by_editor_id("GSProspectorSaloonInterior").get("form_id", 0))
	var reply: Dictionary = script_server.run_debug_line("coc GSProspectorSaloonInterior")
	check(bool(reply.get("ok", false)), "coc is accepted")
	check(await _await_space(coordinator, saloon) and player_ref.current_space_form_id == saloon, "coc loads the saloon around the player")
	_finish()

## Hacking, password notes, lockpicking and terminal item scripts, driven
## through the player's own UI.
func _check_locks_and_terminal_scripts(esm_server, script_server, player: PlayerController, player_ref: ActorReference) -> void:
	var average: TerminalReference = null
	var keyed: TerminalReference = null
	var unhackable: TerminalReference = null
	for row: Dictionary in esm_server.get_record_index():
		if String(row.get("record_type", "")) != "TERM":
			continue
		var terminal := esm_server.create_reference_for_base(int(row["form_id"])) as TerminalReference
		if terminal == null or not terminal.is_locked:
			continue
		var note: int = (terminal.base as TerminalBase).password_note_form_id
		if terminal.lock_level == 2 and note == 0 and average == null:
			average = terminal
		elif terminal.lock_level < 5 and note != 0 and keyed == null:
			keyed = terminal
		elif terminal.lock_level == 5 and note == 0 and unhackable == null:
			unhackable = terminal
	check(average != null and keyed != null and unhackable != null, "locked terminals of each kind exist")

	script_server.activate(average, player_ref)
	check(player.unlock_session.visible and not player.terminal_session.visible and player_ref.using == average, "a locked terminal opens the hacking screen")
	player.unlock_session.cancel()
	check(average.is_locked and player_ref.using == null and player.is_processing_unhandled_input(), "cancelling leaves it locked and ends the use")
	script_server.activate(average, player_ref)
	player.unlock_session._slider.value = player.unlock_session._slider.max_value
	check(not average.is_locked and player.terminal_session.visible and player_ref.using == average, "sliding to the end unlocks it and opens its menu")
	player.terminal_session.close_session()
	check(player_ref.using == null, "closing the menu ends the use")

	player_ref.contents.add_item((keyed.base as TerminalBase).password_note_form_id)
	script_server.activate(keyed, player_ref)
	check(not keyed.is_locked and player.terminal_session.visible and not player.unlock_session.visible, "carrying the password note opens a locked terminal directly")
	player.terminal_session.close_session()

	script_server.activate(unhackable, player_ref)
	check(unhackable.is_locked and player_ref.using == null and not player.unlock_session.visible, "a level-5 terminal without its note does nothing")

	var door: DoorReference = null
	for candidate: DoorReference in esm_server.get_all_xtel_door_references():
		if candidate.is_locked and candidate.lock_key == null and candidate.lock_level < 255:
			door = candidate
			break
	script_server.activate(door, player_ref)
	check(player.unlock_session.visible and player_ref.using == door, "a pickable locked door opens the lockpick screen")
	player.unlock_session._slider.value = player.unlock_session._slider.max_value
	check(not door.is_locked and player_ref.using == null and not player.unlock_session.visible, "sliding to the end unlocks the door and ends the use")
	script_server.lock(door)

	# Lucky38MrHouseTerminal05: one menu item runs `Lucky38MrHouseElevatorDoorREF.unlock`.
	var elevator: EsmReference = esm_server.find_reference_by_editor_id("Lucky38MrHouseElevatorDoorREF")
	var house_terminal := esm_server.create_reference_for_base(0x00164B0F) as TerminalReference
	house_terminal.is_locked = false
	script_server.lock(elevator)
	script_server.activate(house_terminal, player_ref)
	var session := player.terminal_session
	if session._view == TerminalSession.View.WELCOME:
		session._select_current()
	var chosen := -1
	for i in session._choices.item_count:
		if String(session._choices.get_item_metadata(i).get("script_source", "")).to_lower().contains("elevatordoorref.unlock"):
			chosen = i
	check(chosen >= 0, "Mr. House's terminal lists the elevator unlock item")
	if chosen >= 0:
		session._choices.select(chosen)
		session._select_current()
		check(not elevator.is_locked, "choosing it runs its result script and unlocks the elevator door")
	session.close_session()

func _finish() -> void:
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
