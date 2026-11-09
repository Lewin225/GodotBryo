class_name SpawnPlacer
extends Node

## The one owner of spawning (Plans/SpawnMenu/spawn_menu.md): the spawn menu
## tab and the PlaceAtMe script function both place through it.
##
## A placed record becomes a `runtime:` reference (EsmServer's runtime table,
## so saves keep it, as for dropped items). set_location() puts it in a space;
## its cell changes and the streamers build its node. A leveled list is first
## resolved at the player's level: LVLN/LVLC to one actor, LVLI to its items.
##
## Every spawn of this session is kept in order for undo() and clear().

## Emitted after each spawn or undo, for a list or a count to refresh.
signal history_changed

## How far the crosshair ray reaches, in metres.
@export var ray_range := 20.0
## With nothing under the crosshair, the spawn is this far ahead of the player,
## at their feet, in metres.
@export var fallback_distance := 2.0
## Units of one spawn are spread across the facing direction this far apart,
## in metres, as ActorReference.drop_entry() does.
@export var spread := ActorReference.DROP_SPACING

const KIND_PLACED := &"placed"
const KIND_INVENTORY := &"inventory"
const KIND_EQUIPPED := &"equipped"
const KIND_WORN := &"worn"
## An actor's weapon slots, in ActorReference's own order.
const SLOTS: Array[ActorReference.WeaponSlot] = [ActorReference.WeaponSlot.RIGHT_HIP, ActorReference.WeaponSlot.LEFT_HIP, ActorReference.WeaponSlot.BACK]

## PlaceAtMe's Direction argument: 0 front, 1 back, 2 left, 3 right, about the
## caller's heading. From the GECK wiki's PlaceAtMe page; not checked against
## how the original engine offsets.
const PLACE_AT_ME_DIRECTIONS := [Vector2(0, 1), Vector2(0, -1), Vector2(-1, 0), Vector2(1, 0)]

## Each spawn, oldest first: {kind: KIND_PLACED, references: [...]},
## {kind: KIND_INVENTORY, holder, base_form_id, count} or
## {kind: KIND_EQUIPPED, holder, weapon, replaced} or
## {kind: KIND_WORN, holder, entry, was_equipped, taken_off}.
var _history: Array[Dictionary] = []
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_rng.randomize()

## How many spawns undo() can take back.
func history_size() -> int:
	return _history.size()

## The spawns of this session, oldest first (see _history).
func get_history() -> Array[Dictionary]:
	return _history.duplicate()

# --- Spawning ----------------------------------------------------------------

## Places `count` of `base_form_id` where the active camera's centre points,
## facing the camera; ahead of the player when the ray hits nothing. Returns the
## new references.
func place_at_crosshair(base_form_id: int, count := 1) -> Array[EsmReference]:
	var target := crosshair_target()
	if target.is_empty():
		return []
	return place(base_form_id, int(target["space"]), target["position"], float(target["heading"]), count)

## Places `count` of `base_form_id` at `anchor`, turned as it is, moved
## `distance` metres in `direction` (PLACE_AT_ME_DIRECTIONS). Returns the new
## references.
##
## An item placed at an actor with no distance goes ActorReference.DROP_DISTANCE
## in front of it instead, as drop_entry() places one: at the actor's own
## position it would start inside the actor's body.
func place_at_reference(base_form_id: int, anchor: EsmReference, count := 1, distance := 0.0, direction := 0) -> Array[EsmReference]:
	if anchor == null:
		return []
	var located := anchor.world_location()
	if located == null or located.current_space_form_id == 0:
		return []
	var heading := located.rotation.z
	var axis: Vector2 = PLACE_AT_ME_DIRECTIONS[clampi(direction, 0, PLACE_AT_ME_DIRECTIONS.size() - 1)]
	var offset := (_across(heading) * axis.x + _ahead(heading) * axis.y) * distance
	if is_zero_approx(distance) and located is ActorReference and _places_items(base_form_id):
		offset = _ahead(heading) * ActorReference.DROP_DISTANCE
	return place(base_form_id, located.current_space_form_id, located.position + offset, heading, count)

## Places `count` of `base_form_id` in `space_form_id` at `position` (metres,
## Gamebryo Z-up axes) with `heading` (radians about +Z), spread across the
## heading. A leveled list is resolved first. Records one undo entry and
## returns the new references.
##
## An item starts ActorReference.DROP_HEIGHT above `position` and falls to
## rest, as a dropped one does. Placed at `position` itself (an actor's feet, a
## floor hit) its body starts inside the floor and falls out of the world once
## woken. Statics have no body to fall; resting them on the surface is build
## step 4.
func place(base_form_id: int, space_form_id: int, position: Vector3, heading: float, count := 1) -> Array[EsmReference]:
	var placed: Array[EsmReference] = []
	var server := EsmReference.get_esm_server()
	if server == null or not server.is_ready() or space_form_id == 0:
		return placed
	var units := maxi(count, 1)
	var bases := _placeable_bases(server.get_base(base_form_id), units)
	var across := _across(heading)
	for i in bases.size():
		var reference: EsmReference = server.create_runtime_reference(bases[i])
		if reference == null:
			continue
		var offset := across * ((float(i) - float(bases.size() - 1) / 2.0) * spread)
		if reference.base != null and reference.base.is_item():
			offset.z += ActorReference.DROP_HEIGHT
		reference.rotation = Vector3(0.0, 0.0, heading)
		reference.set_location(space_form_id, position + offset)
		placed.append(reference)
	if not placed.is_empty():
		_history.append({"kind": KIND_PLACED, "references": placed.duplicate()})
		history_changed.emit()
	return placed

## Adds `count` of `base_form_id` to `holder`'s inventory (a LVLI adds what it
## resolves to). Records one undo entry and returns how many were added.
func add_to_inventory(base_form_id: int, holder: EsmReference, count := 1) -> int:
	var server := EsmReference.get_esm_server()
	if server == null or not server.is_ready() or holder == null:
		return 0
	var base: EsmBase = server.get_base(base_form_id)
	if base is LeveledItemBase:
		var added := 0
		var items := LeveledItemResolver.new(server).resolve(base, _player_level(), {"rng": _rng})
		for _unit in maxi(count, 1):
			for item: InventoryItem in items:
				var item_base: EsmBase = server.get_base(item.base_form_id)
				var n: int = server.add_inventory_items(holder, item_base, item.count)
				if n > 0:
					_history.append({"kind": KIND_INVENTORY, "holder": holder, "base_form_id": item.base_form_id, "count": n})
					added += n
		if added > 0:
			history_changed.emit()
		return added
	var added_count: int = server.add_inventory_items(holder, base, maxi(count, 1))
	if added_count > 0:
		_history.append({"kind": KIND_INVENTORY, "holder": holder, "base_form_id": base_form_id, "count": added_count})
		history_changed.emit()
	return added_count

## Gives `holder` one of `base_form_id` and equips it, as the EquipItem
## script function does: the new inventory entry is marked equipped. A weapon
## then goes into a holster slot (ActorReference.equip_weapon()), handing back
## any weapon already there; armor is worn, and the inventory unequips what
## shares a biped slot with it. Records one undo entry and returns the
## equipped WeaponReference or the worn InventoryItem; null when `holder` is
## not an actor or the base is neither a weapon nor armor.
func equip(base_form_id: int, holder: EsmReference) -> Object:
	var server := EsmReference.get_esm_server()
	var actor := holder as ActorReference
	if server == null or not server.is_ready() or actor == null or actor.contents == null:
		return null
	var base: EsmBase = server.get_base(base_form_id)
	if base is ArmorBase:
		return _wear(base, actor, server)
	if not base is WeaponBase:
		return null
	var before: Array[WeaponReference] = []
	for slot: ActorReference.WeaponSlot in SLOTS:
		before.append(actor.get_weapon(slot))
	var entry := _add_one(base, actor, server)
	if entry == null or not actor.contents.equip_item(entry):
		return null
	for i in SLOTS.size():
		var weapon := actor.get_weapon(SLOTS[i])
		if weapon != null and weapon != before[i] and weapon.base_form_id == base_form_id:
			_history.append({"kind": KIND_EQUIPPED, "holder": actor, "weapon": weapon, "replaced": before[i]})
			history_changed.emit()
			return weapon
	return null

func _wear(base: ArmorBase, actor: ActorReference, server: Node) -> InventoryItem:
	var worn_before := actor.contents.get_equipped_items()
	var entry := _add_one(base, actor, server)
	if entry == null:
		return null
	var was_equipped := entry.is_equipped
	if not actor.contents.equip_item(entry):
		return null
	var taken_off: Array[InventoryItem] = []
	for item in worn_before:
		if not item.is_equipped:
			taken_off.append(item)
	_history.append({"kind": KIND_WORN, "holder": actor, "entry": entry, "was_equipped": was_equipped, "taken_off": taken_off})
	history_changed.emit()
	return entry

## Adds one of `base` to `actor`'s inventory and returns the stack it is in.
func _add_one(base: EsmBase, actor: ActorReference, server: Node) -> InventoryItem:
	if server.add_inventory_items(actor, base, 1) <= 0:
		return null
	var entry: InventoryItem = null
	for item in actor.contents.get_items():
		if item.base_form_id == base.form_id and item.item_reference == null:
			entry = item
	return entry

## The registry's place_at_me_handler: `PlaceAtMe Object [Count] [Distance]
## [Direction]` on `caller`. Returns the first new reference, or 0.
func place_at_me(args: Array, caller: EsmReference) -> Variant:
	var server := EsmReference.get_esm_server()
	if caller == null or args.is_empty() or server == null:
		return 0
	var base: EsmBase = args[0] if args[0] is EsmBase else server.find_base_by_editor_id(str(args[0]))
	if base == null:
		push_warning("PlaceAtMe: no base record '%s'" % str(args[0]))
		return 0
	var count := maxi(int(args[1]) if args.size() > 1 else 1, 1)
	var distance := float(args[2]) if args.size() > 2 else 0.0
	var direction := int(args[3]) if args.size() > 3 else 0
	var placed := place_at_reference(base.form_id, caller, count, distance, direction)
	return placed[0] if not placed.is_empty() else 0

## Where a crosshair spawn goes: {space, position, heading, hit}, position in
## metres on Gamebryo axes, heading turned to face the camera. {} without a
## camera or a placed player.
func crosshair_target() -> Dictionary:
	var player := _player()
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	if player == null or camera == null or player.current_space_form_id == 0:
		return {}
	var origin := camera.global_position
	var forward := -camera.global_basis.z
	var query := PhysicsRayQueryParameters3D.create(origin, origin + forward * ray_range)
	query.exclude = _excluded_bodies(camera)
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(query)
	var yaw := camera.global_rotation.y
	var heading := EsmReferencePhysicaliser.authored_heading(yaw + PI).z
	if not hit.is_empty():
		return {"space": player.current_space_form_id, "position": EsmReferencePhysicaliser.authored_position(hit["position"]), "heading": heading, "hit": true}
	# The camera's heading, not the body's: Debug Tools keeps the camera still.
	var camera_heading := EsmReferencePhysicaliser.authored_heading(yaw).z
	return {"space": player.current_space_form_id, "position": player.position + _ahead(camera_heading) * fallback_distance, "heading": heading, "hit": false}

# --- Undo --------------------------------------------------------------------

## Takes back the newest spawn: removes its references that are still placed
## from the world and the runtime table, or the items it added. A reference
## that has left the world (picked up, moved into a container) is skipped.
## Returns whether there was a spawn to take back.
func undo() -> bool:
	if _history.is_empty():
		return false
	_take_back(_history.pop_back())
	history_changed.emit()
	return true

## Takes back every spawn of this session, newest first. Returns how many.
func clear() -> int:
	var n := _history.size()
	while not _history.is_empty():
		_take_back(_history.pop_back())
	if n > 0:
		history_changed.emit()
	return n

func _take_back(entry: Dictionary) -> void:
	var server := EsmReference.get_esm_server()
	if entry["kind"] == KIND_EQUIPPED:
		_take_back_equipped(entry, server)
		return
	if entry["kind"] == KIND_WORN:
		_take_back_worn(entry)
		return
	if entry["kind"] == KIND_PLACED:
		for reference: EsmReference in entry["references"]:
			if reference.current_space_form_id == 0 or not reference.holder_instance_id.is_empty():
				continue
			reference.set_location(0, Vector3.ZERO)
			if server != null:
				server.release_runtime_reference(reference)
		return
	var holder: EsmReference = entry["holder"]
	var inventory: Inventory = holder.get("contents") if holder != null and "contents" in holder else null
	if inventory == null:
		return
	var remaining := int(entry["count"])
	for item in inventory.get_items():
		if remaining <= 0:
			break
		if item.base_form_id != int(entry["base_form_id"]) or item.item_reference != null:
			continue
		var take := mini(item.count, remaining)
		if inventory.remove_inventory_item(item, take):
			remaining -= take

## Takes an equipped weapon out of its slot and the runtime table, and puts
## back the weapon it replaced when that is still in the inventory. A weapon no
## longer in a slot (unequipped, dropped) is skipped.
func _take_back_equipped(entry: Dictionary, server: Node) -> void:
	var actor: ActorReference = entry["holder"]
	var weapon: WeaponReference = entry["weapon"]
	var slot := actor.get_weapon_slot(weapon)
	if slot == ActorReference.WeaponSlot.NONE:
		return
	actor.remove_weapon(slot)
	if server != null:
		server.release_runtime_reference(weapon)
	var replaced: WeaponReference = entry["replaced"]
	if replaced == null or actor.contents == null:
		return
	for item in actor.contents.get_items():
		if item.item_reference == replaced:
			actor.equip_weapon(item)
			return

## Takes off armor equip() put on and removes the unit it added, then puts
## back on what it took off, where that is still in the inventory.
func _take_back_worn(entry: Dictionary) -> void:
	var actor: ActorReference = entry["holder"]
	var inventory := actor.contents
	var item: InventoryItem = entry["entry"]
	if inventory == null or not inventory.get_items().has(item):
		return
	inventory.begin_batch()
	if not entry["was_equipped"]:
		inventory.unequip_item(item)
	inventory.remove_inventory_item(item, 1)
	for taken_off: InventoryItem in entry["taken_off"]:
		if inventory.get_items().has(taken_off):
			inventory.equip_item(taken_off)
	inventory.end_batch()

# --- Helpers -----------------------------------------------------------------

## The base FormIDs `units` placements of `base` make: the base itself, or for
## a leveled list what it resolves to at the player's level (each unit
## resolved anew). Empty for a list that gives nothing.
func _placeable_bases(base: EsmBase, units: int) -> PackedInt32Array:
	var result := PackedInt32Array()
	if base == null:
		return result
	for _unit in units:
		if base is LeveledActorBase:
			var actor := LeveledActorResolver.resolve(base, _player_level(), _rng)
			if actor != null:
				result.append(actor.form_id)
		elif base is LeveledItemBase:
			var server := EsmReference.get_esm_server()
			for item: InventoryItem in LeveledItemResolver.new(server).resolve(base, _player_level(), {"rng": _rng}):
				for _n in maxi(item.count, 1):
					result.append(item.base_form_id)
		else:
			result.append(base.form_id)
	return result

## Whether placing `base_form_id` makes items: an item, or a LVLI.
func _places_items(base_form_id: int) -> bool:
	var server := EsmReference.get_esm_server()
	var base: EsmBase = server.get_base(base_form_id) if server != null and server.is_ready() else null
	return base != null and (base.is_item() or base is LeveledItemBase)

func _player() -> EsmReference:
	var script_server := get_node_or_null("/root/ScriptServer")
	var player: EsmReference = script_server.player_reference if script_server != null else null
	if player == null:
		var server := EsmReference.get_esm_server()
		player = server.get_player_reference() if server != null and server.is_ready() else null
	return player

func _player_level() -> int:
	var player := _player()
	var values: ActorValues = player.get_actor_values() if player != null else null
	return values.get_level() if values != null else 1

## The camera's own collision bodies (the player's), which the ray skips.
static func _excluded_bodies(camera: Node) -> Array[RID]:
	var result: Array[RID] = []
	var node := camera
	while node != null:
		if node is CollisionObject3D:
			result.append((node as CollisionObject3D).get_rid())
		node = node.get_parent()
	return result

## A Gamebryo heading turns clockwise from +Y about +Z.
static func _ahead(heading: float) -> Vector3:
	return Vector3(sin(heading), cos(heading), 0.0)

## To the right of a heading.
static func _across(heading: float) -> Vector3:
	return Vector3(cos(heading), -sin(heading), 0.0)
