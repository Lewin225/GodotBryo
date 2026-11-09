@tool
class_name ActorReference
extends EsmReference

## A placed actor: the fields and state ACHR and ACRE share (Plans/Actors).
## Abstract: every actor is an NpcReference (ACHR) or a CreatureReference
## (ACRE). EsmReference holds NAME, DATA, XSCL, XLKR, XESP and the enable
## state.

enum SimulationMode { LOW_LEVEL, PHYSICAL_LEASED }

## Emitted when this actor starts or stops using a reference.
@warning_ignore("unused_signal")
signal using_changed(previous: EsmReference, current: EsmReference)
## Emitted when the actor reaches `move_target`, which is cleared first.
signal move_target_reached
## Emitted when `simulation_mode` changes.
signal simulation_mode_changed
## `active_package` changed; controllers read the new package's flags (Always
## Run and the like) from it.
signal active_package_changed(old_package: PackageBase, new_package: PackageBase)
## A weapon slot's weapon, or the drawn slot, changed.
signal weapon_slots_changed

## The MODL the editor gives an NPC_ or CREA whose model comes from a leveled
## list (638 NPC_ in FalloutNV.esm).
const PLACEHOLDER_MODEL := "marker_creature.nif"
## level_modifier without XLCM.
## The weapon slots (Plans/Weapons/weapons.md, Equip slots): two short guns on
## the belt and a long gun (or a heavy weapon's backpack) on the back.
enum WeaponSlot { NONE = -1, RIGHT_HIP = 0, LEFT_HIP = 1, BACK = 2 }

const LEVEL_MODIFIER_NONE := -1
const LEVEL_MODIFIER_EASY := 0
## The fraction of the space's level each XLCM value chooses at, Easy to Boss
## (GECK: 50%, 75%, 125%, 200%).
const LEVEL_MODIFIER_SCALES: Array[float] = [0.5, 0.75, 1.25, 2.0]

@export_group("Placement")
## XLCM: Level Modifier (s32; 178 ACHR, 119 ACRE in FalloutNV.esm, values 0
## to 3), LEVEL_MODIFIER_NONE without one. Read; used by get_leveled_template().
## 0-3 read as Easy, Medium, Hard and Boss is inferred: the GECK names those
## four besides None, and the data carries no other values.
@export_custom(PROPERTY_HINT_ENUM, "None:-1,Easy:0,Medium:1,Hard:2,Boss:3", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var level_modifier: int = LEVEL_MODIFIER_NONE
## XEZN: the encounter zone (5 ACHR, 11 ACRE). Read; used by
## get_leveled_template() before the cell's zone.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var encounter_zone_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EncounterZoneBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var encounter_zone: EncounterZoneBase
## XMRC: the placed container holding this actor's merchant inventory (76
## ACHR, 1 ACRE), resolved on demand by get_merchant_container(): placed
## references are world state, not record data. Read; not used yet (no barter).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var merchant_container_form_id: int = 0
## XRGD: Ragdoll Data, raw (278 ACHR, 109 ACRE). Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var ragdoll_data: PackedByteArray = PackedByteArray()
## XRGB: Ragdoll Biped Data, raw (277 ACHR, 14 ACRE). Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var ragdoll_biped_data: PackedByteArray = PackedByteArray()

@export_group("Activation")
## XATO: Activation Prompt (3 ACHR, 1 ACRE). Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var activation_prompt: String = ""
## XAPD: Parent Activate Only (3 ACHR, 1 ACRE). Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var parent_activate_only: bool = false
## XIBS: Ignored By Sandbox (6 ACHR, 0 ACRE). Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var ignored_by_sandbox: bool = false

@export_group("Unused in FalloutNV.esm")
## XHLP (Health). Present on no ACHR or ACRE in FalloutNV.esm; not read. Not
## the actor's health, which is ActorValues' Health.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var health: float = -1.0
## XCNT (Count). Present on no ACHR or ACRE in FalloutNV.esm; not read.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var count: int = 1
## XRDS (Radius). Present on no ACHR or ACRE in FalloutNV.esm; not read.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var radius: float = 0.0
## XPRD (Patrol Data Idle Time). Present on no ACHR or ACRE in FalloutNV.esm;
## not read.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var idle_time: float = 0.0
## INAM (Patrol Data Idle). Present on no ACHR or ACRE in FalloutNV.esm; not
## read. Not the idle the actor is playing, which is special_idle.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var idle_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "IdleBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var idle: IdleBase
## TNAM (Patrol Data Topic). Present on no ACHR or ACRE in FalloutNV.esm; not
## read.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var topic_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "DialogueTopicBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var topic: DialogueTopicBase

@export_group("State")
## Not an ESM field: the CELL that files this placement. Set by EsmServer;
## save loading restores an overlay onto this shared Resource and must never
## rewrite it.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var spawn_cell_form_id: int = 0
## Runtime state with no ESM source: who moves the actor. LOW_LEVEL:
## NpcSimulationServer; PHYSICAL_LEASED: its NpcController (or the player's
## PlayerController), which writes `position` and `rotation`. Not saved: a
## loaded actor starts LOW_LEVEL and is leased again.
@export_custom(PROPERTY_HINT_ENUM, "Low Level,Physical Leased", PROPERTY_USAGE_EDITOR) var simulation_mode: SimulationMode = SimulationMode.LOW_LEVEL:
	set(value):
		if simulation_mode == value:
			return
		simulation_mode = value
		mark_dirty()
		simulation_mode_changed.emit()
## Runtime state with no ESM source: where the actor is heading, metres in
## Gamebryo axes in its current space, while `has_move_target`. Set by
## NpcSimulationServer (and tests); NpcController follows a route to it.
@export var move_target: Vector3 = Vector3.ZERO:
	set(value):
		move_target = value
		mark_dirty()
## Runtime state with no ESM source: whether `move_target` is set.
@export var has_move_target: bool = false:
	set(value):
		has_move_target = value
		mark_dirty()
## Runtime state with no ESM source: the package selection chose, the
## `script_package` or else the first of the base's `packages` whose schedule
## and conditions hold. Set only by NpcSimulationServer's PackageRunner, which
## runs it (FOLLOW so far). Emits active_package_changed.
@export var active_package: PackageBase:
	set(value):
		if active_package == value:
			return
		var old_package := active_package
		active_package = value
		mark_dirty()
		active_package_changed.emit(old_package, value)
## Runtime state with no ESM source: the package AddScriptPackage gave, which
## selection chooses ahead of the base's `packages` until RemoveScriptPackage
## clears it. Set through NpcSimulationServer.package_runner
## .set_script_package(); read by its selection.
@export var script_package: PackageBase:
	set(value):
		script_package = value
		mark_dirty()
## Runtime state with no ESM source: the active package has done its job (a
## Travel package arrived). It stays the active package while selection keeps
## choosing it, and is not run again. Set and cleared by PackageRunner.
@export var package_completed: bool = false:
	set(value):
		package_completed = value
		mark_dirty()
## Runtime state with no ESM source: the GetSitting value (inferred: 0 not
## sitting, 1 wants to sit, 2 sitting down, 3 sitting, 4 wants to stand, 5
## standing up). Set by ScriptServer's FurnitureSeating as the actor uses and
## leaves furniture; read by GetSitting, and so by the idle tree's furniture
## items.
@export var sit_state: int = 0:
	set(value):
		sit_state = value
		mark_dirty()
## Not an ACHR or ACRE field: no actor-reference subrecord holds the idle an
## actor is playing (the patrol INAM, `idle`, is present on none in
## FalloutNV.esm). Runtime state with no ESM source: the idle a script
## (PlayIdle) or a package event asked the actor to play, cleared when it ends.
## Set and cleared by ScriptServer's ActorIdles; played by the actor node's
## ActorAnimator.
@export var special_idle: IdleBase:
	set(value):
		special_idle = value
		mark_dirty()
## Runtime state with no ESM source: the idle the actor last started playing
## (any: PlayIdle, package and ambient idles, dialogue gestures, furniture).
## Set by ScriptServer's ActorIdles and FurnitureSeating; read by the condition
## function IsLastIdlePlayed, which the dialogue gestures chain on.
@export var last_idle: IdleBase:
	set(value):
		last_idle = value
		mark_dirty()
## Runtime state with no ESM source: the actor is moving (walking, running or
## sneaking along). Set by the controller driving it (PlayerController,
## NpcController) each physics frame; false while no controller drives it.
## Read by the condition function IsMoving, and so by the idle tree. Not saved:
## the controller sets it again.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var is_moving: bool = false:
	set(value):
		is_moving = value
		mark_dirty()
## Runtime state with no ESM source: the actor moves at a run. Set by the
## controller driving it: the player's sprint or always-run, an NPC's package
## Always Run. Read by IsRunning. Not saved: the controller sets it again.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var is_running: bool = false:
	set(value):
		is_running = value
		mark_dirty()
## Runtime state with no ESM source: the actor is sneaking. Set by the
## controller driving it: the player's crouch, an NPC's package Always Sneak
## (until combat and AI set it). Read by IsSneaking. Not saved: the controller
## sets it again.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var is_sneaking: bool = false:
	set(value):
		is_sneaking = value
		mark_dirty()
## Runtime state with no ESM source: what the actor looks at, set by the script
## function Look and cleared by StopLook. Read by the actor node's
## ActorHeadTracking, ahead of its other choices.
@export var look_target: EsmReference:
	set(value):
		look_target = value
		mark_dirty()
## Runtime state with no ESM source. Nothing sets or reads it yet.
@export var alive: bool = true:
	set(value):
		alive = value
		mark_dirty()
## Runtime state: the actor's live inventory, seeded from its base's Items.
@export var contents: Inventory:
	set(value):
		_unwatch_inventory(contents)
		contents = value
		_watch_inventory(contents)
## Runtime state: what has changed from the base record's derived values.
## EsmServer creates it with the reference; otherwise created on first use.
@export var actor_values: ActorValues
## Runtime state with no ESM source: the weapon holstered or drawn at the right
## hip, out of the inventory while it is here. Saved as its instance_id. Set by
## equip_weapon(); read by the actor node's ActorWeaponSlots.
@export var weapon_right_hip: WeaponReference:
	set(value):
		weapon_right_hip = value
		_weapon_slots_changed()
## Runtime state with no ESM source: the weapon at the left hip, a slot the
## original does not have. As weapon_right_hip.
@export var weapon_left_hip: WeaponReference:
	set(value):
		weapon_left_hip = value
		_weapon_slots_changed()
## Runtime state with no ESM source: the long gun (or heavy weapon) on the back.
## As weapon_right_hip.
@export var weapon_back: WeaponReference:
	set(value):
		weapon_back = value
		_weapon_slots_changed()
## Runtime state with no ESM source: the slot whose weapon is in the hand, NONE
## when all are holstered. Set by draw_weapon() and holster_weapon().
@export var drawn_weapon_slot: WeaponSlot = WeaponSlot.NONE:
	set(value):
		drawn_weapon_slot = value
		_weapon_slots_changed()
## Runtime state with no ESM source: the slot drawn last, which a draw or fire
## input with nothing drawn draws again; NONE before any.
@export var last_drawn_weapon_slot: WeaponSlot = WeaponSlot.NONE:
	set(value):
		last_drawn_weapon_slot = value
		mark_dirty()
## Runtime state with no ESM source: the NPC_ or CREA chosen from the leveled
## list (LVLN, LVLC) in the base's template chain, chosen once on first use by
## get_leveled_template(). Null until chosen, and for an actor with no leveled
## list. Used by template_source().
@export var leveled_template: ActorBase:
	set(value):
		leveled_template = value
		mark_dirty()
## Runtime state with no ESM source: the level `leveled_template` was chosen
## at, after the XLCM scale; 0 until chosen. Shown by ActorDebugLabel.
@export var leveled_template_level: int = 0:
	set(value):
		leveled_template_level = value
		mark_dirty()
@export_group("")

## Runtime state with no ESM source: the reference this actor is using
## (terminal, container, furniture, a door it is lockpicking), or null. One at
## a time. Set only by ScriptServer.begin_use / end_use. Saved (as its
## instance_id) so a seated actor loads seated, with `using_marker`.
@export_storage var using: EsmReference = null
## Runtime state: the furniture marker index occupied while using furniture,
## else -1. Saved with `using`.
@export_storage var using_marker: int = -1

## _take_equipped_weapons() is running: equipping changes the inventory, which
## calls it again.
var _taking_weapons := false

## How far in front of the actor, and how high above its feet, drop() places
## an item, in metres.
const DROP_DISTANCE := 0.6
const DROP_HEIGHT := 1.0

## Takes the placed item `item` into this actor's inventory: the item's node
## wakes the items resting against it, the reference is held by this actor
## (no space, so the streamers free the node) and an inventory entry holds it.
## False when `item` is not an item or is already held.
func pick_up(item: EsmReference) -> bool:
	if item == null or item.base == null or not item.base.is_item():
		return false
	if item.get_holder() != null or contents == null:
		return false
	var node := EsmNode.node_for(item) as EsmItemNode
	if node != null:
		node.wake_neighbours()
	item.set_holder(self)
	contents.add_inventory_item(InventoryItem.make_reference(item))
	return true

## Places the held item `item` in the world in front of this actor, facing its
## heading, and removes its inventory entry; the streamers build its node from
## the cell change. False when this actor does not hold it.
func drop(item: EsmReference) -> bool:
	if item == null or item.get_holder() != self or contents == null:
		return false
	var entry := _entry_for(item)
	if entry == null:
		return false
	contents.remove_inventory_item(entry)
	# A Gamebryo heading turns clockwise from +Y about +Z.
	var heading := rotation.z
	var ahead := Vector3(sin(heading), cos(heading), 0.0) * DROP_DISTANCE
	item.rotation = Vector3(0.0, 0.0, heading)
	item.set_location(current_space_form_id, position + ahead + Vector3(0.0, 0.0, DROP_HEIGHT))
	return true

## How far apart drop_entry() places the units of a stack, in metres, in a
## row across the actor's front.
const DROP_SPACING := 0.15

## Drops `count` units of the inventory entry `entry` (all of them when
## negative) in front of this actor, and returns how many it dropped. An entry
## holding a reference drops that reference. A stack has no reference to drop,
## so each unit becomes a new runtime reference of its base, placed in a row so
## their bodies do not start inside each other.
func drop_entry(entry: InventoryItem, count := -1) -> int:
	if entry == null or contents == null or not contents.get_items().has(entry):
		return 0
	if entry.item_reference != null:
		return 1 if drop(entry.item_reference) else 0
	var server := get_esm_server()
	if server == null:
		return 0
	var units := entry.count if count < 0 else mini(count, entry.count)
	var heading := rotation.z
	# A Gamebryo heading turns clockwise from +Y about +Z; across is to its right.
	var ahead := Vector3(sin(heading), cos(heading), 0.0)
	var across := Vector3(cos(heading), -sin(heading), 0.0)
	var dropped := 0
	for unit in units:
		var item: EsmReference = server.create_runtime_reference(entry.base_form_id)
		if item == null:
			break
		var offset := (float(unit) - float(units - 1) / 2.0) * DROP_SPACING
		item.rotation = Vector3(0.0, 0.0, heading)
		item.set_location(current_space_form_id, position + ahead * DROP_DISTANCE + across * offset + Vector3(0.0, 0.0, DROP_HEIGHT))
		dropped += 1
	contents.remove_inventory_item(entry, dropped)
	return dropped

## The weapon in `slot`, or null.
func get_weapon(slot: WeaponSlot) -> WeaponReference:
	match slot:
		WeaponSlot.RIGHT_HIP:
			return weapon_right_hip
		WeaponSlot.LEFT_HIP:
			return weapon_left_hip
		WeaponSlot.BACK:
			return weapon_back
	return null


## The slot holding `weapon`, NONE when it is in none.
func get_weapon_slot(weapon: WeaponReference) -> WeaponSlot:
	for slot: WeaponSlot in [WeaponSlot.RIGHT_HIP, WeaponSlot.LEFT_HIP, WeaponSlot.BACK]:
		if weapon != null and get_weapon(slot) == weapon:
			return slot
	return WeaponSlot.NONE


## The weapon in the hand, or null.
func get_drawn_weapon() -> WeaponReference:
	return get_weapon(drawn_weapon_slot)


## Takes the weapon of the inventory entry `entry` out of the inventory into a
## slot: one unit of a stack becomes a runtime reference first. A long gun goes
## on the back, a short gun to the right hip, else the left. A slot in use
## gives its weapon back to the inventory first (the right hip for a short
## gun). Returns the slot, NONE when `entry` is not a weapon of this inventory.
func equip_weapon(entry: InventoryItem) -> WeaponSlot:
	if entry == null or contents == null or not contents.get_items().has(entry):
		return WeaponSlot.NONE
	var base := entry.base as WeaponBase
	if base == null:
		return WeaponSlot.NONE
	var weapon := entry.item_reference as WeaponReference
	if weapon == null:
		var server := get_esm_server()
		if server == null:
			return WeaponSlot.NONE
		weapon = server.create_runtime_reference(entry.base_form_id) as WeaponReference
		if weapon == null:
			return WeaponSlot.NONE
	var slot := _free_slot_for(base)
	if get_weapon(slot) != null:
		unequip_weapon(slot)
	contents.begin_batch()
	entry.is_equipped = false
	if entry.item_reference != null:
		contents.remove_inventory_item(entry)
	else:
		contents.remove_inventory_item(entry, 1)
	contents.end_batch()
	weapon.set_holder(self)
	_set_weapon(slot, weapon)
	last_drawn_weapon_slot = slot
	return slot


## Puts the weapon in `slot` back in the inventory, holding its reference. False
## when the slot is empty.
func unequip_weapon(slot: WeaponSlot) -> bool:
	var weapon := get_weapon(slot)
	if weapon == null or contents == null:
		return false
	if drawn_weapon_slot == slot:
		drawn_weapon_slot = WeaponSlot.NONE
	_set_weapon(slot, null)
	contents.add_inventory_item(InventoryItem.make_reference(weapon))
	return true


## Takes the weapon in `slot` away: not back to the inventory (RemoveItem).
## False when the slot is empty.
func remove_weapon(slot: WeaponSlot) -> bool:
	var weapon := get_weapon(slot)
	if weapon == null:
		return false
	if drawn_weapon_slot == slot:
		drawn_weapon_slot = WeaponSlot.NONE
	_set_weapon(slot, null)
	weapon.holder_instance_id = &""
	return true


## The slots holding a weapon of the base `base_form_id`, right hip first.
func get_weapon_slots_of(base_form_id: int) -> Array[WeaponSlot]:
	var result: Array[WeaponSlot] = []
	for slot: WeaponSlot in [WeaponSlot.RIGHT_HIP, WeaponSlot.LEFT_HIP, WeaponSlot.BACK]:
		var weapon := get_weapon(slot)
		if weapon != null and weapon.base_form_id == base_form_id:
			result.append(slot)
	return result


## Draws the weapon in `slot` (holstering the drawn one); NONE draws the last
## drawn. False when that slot is empty.
func draw_weapon(slot: WeaponSlot = WeaponSlot.NONE) -> bool:
	if slot == WeaponSlot.NONE:
		slot = last_drawn_weapon_slot
	if get_weapon(slot) == null:
		return false
	drawn_weapon_slot = slot
	last_drawn_weapon_slot = slot
	return true


## Holsters the drawn weapon.
func holster_weapon() -> void:
	drawn_weapon_slot = WeaponSlot.NONE


## The slot a weapon of `base` goes in: the back for a long gun; for a short
## gun the right hip, else the left hip when only the right is in use.
## `# ASSUMPTION` h2h (held on Bip01 R ForeTwist) takes a hip slot like a short
## gun: nothing says where it counts.
func _free_slot_for(base: WeaponBase) -> WeaponSlot:
	if base.holsters_on_back():
		return WeaponSlot.BACK
	if weapon_right_hip != null and weapon_left_hip == null:
		return WeaponSlot.LEFT_HIP
	return WeaponSlot.RIGHT_HIP


func _set_weapon(slot: WeaponSlot, weapon: WeaponReference) -> void:
	match slot:
		WeaponSlot.RIGHT_HIP:
			weapon_right_hip = weapon
		WeaponSlot.LEFT_HIP:
			weapon_left_hip = weapon
		WeaponSlot.BACK:
			weapon_back = weapon


## Takes every weapon the inventory marks equipped into a slot: is_equipped is
## the equip request (EquipItem, the player's UI).
func _take_equipped_weapons() -> void:
	if _taking_weapons or contents == null:
		return
	_taking_weapons = true
	for entry in contents.get_equipped_items():
		if entry.base is WeaponBase:
			equip_weapon(entry)
	_taking_weapons = false


func _weapon_slots_changed() -> void:
	mark_dirty()
	weapon_slots_changed.emit()


func _watch_inventory(inventory: Inventory) -> void:
	super._watch_inventory(inventory)
	if inventory != null and not inventory.inventory_changed.is_connected(_take_equipped_weapons):
		inventory.inventory_changed.connect(_take_equipped_weapons)


func _unwatch_inventory(inventory: Inventory) -> void:
	super._unwatch_inventory(inventory)
	if inventory != null and inventory.inventory_changed.is_connected(_take_equipped_weapons):
		inventory.inventory_changed.disconnect(_take_equipped_weapons)


## The inventory entry holding the reference `item`, or null.
func _entry_for(item: EsmReference) -> InventoryItem:
	for entry in contents.get_items():
		if entry.item_reference == item:
			return entry
	return null

## XMRC's placed container, built on demand; null when there is none.
func get_merchant_container() -> EsmReference:
	var server := get_esm_server()
	if merchant_container_form_id == 0 or server == null:
		return null
	return server.get_reference_by_form_id(merchant_container_form_id)

## Sends the actor toward `target` (metres, Gamebryo axes, current space).
func set_move_target(target: Vector3) -> void:
	move_target = target
	has_move_target = true

## Clears the target without arriving.
func clear_move_target() -> void:
	has_move_target = false

## The actor arrived: clears the target and emits move_target_reached.
func reach_move_target() -> void:
	has_move_target = false
	move_target_reached.emit()

## The actor record that supplies this actor's part named by the template flag
## `flag` (ActorBase.TEMPLATE_USE_*): ActorBase.template_source() of its base,
## continuing into the leveled list's choice when the chain reaches one.
func template_source(flag: int) -> ActorBase:
	return ActorBase.template_source(base, flag, get_leveled_template())

## The record supplying this actor's skeleton and animations: its
## Model/Animation template source, or, when that record's MODL is the editor's
## placeholder marker_creature.nif, the leveled choice's Model/Animation source.
## 44 placed actors in FalloutNV.esm reach a leveled list without taking
## Model/Animation from it and keep the placeholder (40 take Traits from it, 4
## take neither); taking the skeleton from the chosen actor is inferred, not
## confirmed.
func model_source() -> ActorBase:
	var source := template_source(ActorBase.TEMPLATE_USE_MODEL_ANIMATION)
	if source == null or not source.model_path.to_lower().ends_with(PLACEHOLDER_MODEL):
		return source
	var choice := get_leveled_template()
	if choice == null:
		return source
	return ActorBase.template_source(choice, ActorBase.TEMPLATE_USE_MODEL_ANIMATION)

## model_source() for `reference` when it is an ActorReference, else
## ActorBase.template_source() of its base for Model/Animation.
static func model_source_of(reference: EsmReference) -> ActorBase:
	if reference == null:
		return null
	if reference is ActorReference:
		return (reference as ActorReference).model_source()
	return ActorBase.template_source(reference.base, ActorBase.TEMPLATE_USE_MODEL_ANIMATION)

## template_source() for `reference` when it is an ActorReference, else
## ActorBase.template_source() of its base; null for a null reference.
static func template_source_of(reference: EsmReference, flag: int) -> ActorBase:
	if reference == null:
		return null
	if reference is ActorReference:
		return (reference as ActorReference).template_source(flag)
	return ActorBase.template_source(reference.base, flag)

## The actor chosen from the leveled list in the base's template chain
## (`leveled_template`), choosing it on the first call; null when the chain has
## no leveled list or it gives none.
##
## The level chosen at is the space's: the encounter zone's (XEZN, else the
## current cell's) resolved level, or the player's without a zone. Without
## XLCM the list's own LVLF rules apply at that level, seeded from instance_id.
## With XLCM the level is scaled by LEVEL_MODIFIER_SCALES; Easy takes any entry
## at or below it, the others only the closest, and the choice is seeded from
## the space, modifier and list, so every such actor in a space is the same.
func get_leveled_template() -> ActorBase:
	if leveled_template != null:
		return leveled_template
	var list := ActorBase.leveled_list_in_chain(base)
	if list == null:
		return null
	var zone := get_encounter_zone()
	var level := _player_level()
	if zone != null:
		level = zone.resolve_level(level)
	var rng := RandomNumberGenerator.new()
	if level_modifier == LEVEL_MODIFIER_NONE:
		rng.seed = hash(instance_id)
		leveled_template_level = level
		leveled_template = LeveledActorResolver.resolve(list, level, rng)
		return leveled_template
	var scaled := maxi(roundi(level * LEVEL_MODIFIER_SCALES[level_modifier]), 1)
	var space := zone.form_id if zone != null else _cell_form_id()
	rng.seed = hash([space, level_modifier, list.form_id])
	var mode := LeveledActorResolver.Mode.ALL_AT_OR_BELOW
	if level_modifier != LEVEL_MODIFIER_EASY:
		mode = LeveledActorResolver.Mode.CLOSEST
	leveled_template_level = scaled
	leveled_template = LeveledActorResolver.resolve(list, scaled, rng, mode)
	return leveled_template

## The actor's own encounter zone, else its cell's (_cell_form_id); null
## without one.
func get_encounter_zone() -> EncounterZoneBase:
	if encounter_zone != null:
		return encounter_zone
	var server := get_esm_server()
	if server == null or not server.is_ready():
		return null
	return server.encounter_zone_for_cell(_cell_form_id())

## current_cell_form_id, or the cell at the actor's space and position before
## it is set; 0 without a space or server.
func _cell_form_id() -> int:
	if current_cell_form_id != 0:
		return current_cell_form_id
	var server := get_esm_server()
	if server == null or current_space_form_id == 0:
		return 0
	return server.cell_at(current_space_form_id, position)

func _player_level() -> int:
	var server := get_esm_server()
	if server == null or not server.is_ready():
		return 1
	var player: EsmReference = server.get_player_reference()
	if player == null or player == self or player.get_actor_values() == null:
		return 1
	return player.get_actor_values().get_level()

func get_actor_values() -> ActorValues:
	if actor_values == null:
		actor_values = ActorValues.new()
	actor_values.owner = self
	return actor_values
