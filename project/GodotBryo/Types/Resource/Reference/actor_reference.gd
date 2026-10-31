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

## The MODL the editor gives an NPC_ or CREA whose model comes from a leveled
## list (638 NPC_ in FalloutNV.esm).
const PLACEHOLDER_MODEL := "marker_creature.nif"

@export_group("Placement")
## XLCM: Level Modifier (s32; 178 ACHR, 119 ACRE in FalloutNV.esm). Read; not
## used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var level_modifier: int = 0
## XEZN: the encounter zone (5 ACHR, 11 ACRE). Read; not used yet.
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
@export var health: float = -1.0
## XCNT (Count). Present on no ACHR or ACRE in FalloutNV.esm; not read.
@export var count: int = 1
## XRDS (Radius). Present on no ACHR or ACRE in FalloutNV.esm; not read.
@export var radius: float = 0.0
## XPRD (Patrol Data Idle Time). Present on no ACHR or ACRE in FalloutNV.esm;
## not read.
@export var idle_time: float = 0.0
## INAM (Patrol Data Idle). Present on no ACHR or ACRE in FalloutNV.esm; not
## read. Not the idle the actor is playing, which is special_idle.
@export var idle_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "IdleBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var idle: IdleBase
## TNAM (Patrol Data Topic). Present on no ACHR or ACRE in FalloutNV.esm; not
## read.
@export var topic_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "DialogueTopicBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var topic: DialogueTopicBase

@export_group("State")
## Not an ESM field: the CELL that files this placement. Set by EsmServer;
## save loading restores an overlay onto this shared Resource and must never
## rewrite it.
@export var spawn_cell_form_id: int = 0
## Runtime state with no ESM source: who moves the actor. LOW_LEVEL:
## NpcSimulationServer; PHYSICAL_LEASED: its NpcController (or the player's
## PlayerController), which writes `position` and `rotation`.
@export var simulation_mode: SimulationMode = SimulationMode.LOW_LEVEL:
	set(value):
		if simulation_mode == value:
			return
		simulation_mode = value
		simulation_mode_changed.emit()
## Runtime state with no ESM source: where the actor is heading, metres in
## Gamebryo axes in its current space, while `has_move_target`. Set by
## NpcSimulationServer (and tests); NpcController follows a route to it.
@export var move_target: Vector3 = Vector3.ZERO
## Runtime state with no ESM source: whether `move_target` is set.
@export var has_move_target: bool = false
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
		active_package_changed.emit(old_package, value)
## Runtime state with no ESM source: the package AddScriptPackage gave, which
## selection chooses ahead of the base's `packages` until RemoveScriptPackage
## clears it. Set through NpcSimulationServer.package_runner
## .set_script_package(); read by its selection.
@export var script_package: PackageBase
## Runtime state with no ESM source: the active package has done its job (a
## Travel package arrived). It stays the active package while selection keeps
## choosing it, and is not run again. Set and cleared by PackageRunner.
@export var package_completed: bool = false
## Runtime state with no ESM source: the GetSitting value (inferred: 0 not
## sitting, 1 wants to sit, 2 sitting down, 3 sitting, 4 wants to stand, 5
## standing up). Set by ScriptServer's FurnitureSeating as the actor uses and
## leaves furniture; read by GetSitting, and so by the idle tree's furniture
## items.
@export var sit_state: int = 0
## Not an ACHR or ACRE field: no actor-reference subrecord holds the idle an
## actor is playing (the patrol INAM, `idle`, is present on none in
## FalloutNV.esm). Runtime state with no ESM source: the idle a script
## (PlayIdle) or a package event asked the actor to play, cleared when it ends.
## Set and cleared by ScriptServer's ActorIdles; played by the actor node's
## ActorAnimator.
@export var special_idle: IdleBase
## Runtime state with no ESM source: the idle the actor last started playing
## (any: PlayIdle, package and ambient idles, dialogue gestures, furniture).
## Set by ScriptServer's ActorIdles and FurnitureSeating; read by the condition
## function IsLastIdlePlayed, which the dialogue gestures chain on.
@export var last_idle: IdleBase
## Runtime state with no ESM source: the actor is moving (walking, running or
## sneaking along). Set by the controller driving it (PlayerController,
## NpcController) each physics frame; false while no controller drives it.
## Read by the condition function IsMoving, and so by the idle tree.
@export var is_moving: bool = false
## Runtime state with no ESM source: the actor moves at a run. Set by the
## controller driving it: the player's sprint or always-run, an NPC's package
## Always Run. Read by IsRunning.
@export var is_running: bool = false
## Runtime state with no ESM source: the actor is sneaking. Set by the
## controller driving it: the player's crouch, an NPC's package Always Sneak
## (until combat and AI set it). Read by IsSneaking.
@export var is_sneaking: bool = false
## Runtime state with no ESM source: what the actor looks at, set by the script
## function Look and cleared by StopLook. Read by the actor node's
## ActorHeadTracking, ahead of its other choices.
@export var look_target: EsmReference
## Runtime state with no ESM source. Nothing sets or reads it yet.
@export var alive: bool = true
## Runtime state: the actor's live inventory, seeded from its base's Items.
@export var contents: Inventory
## Runtime state: what has changed from the base record's derived values.
## EsmServer creates it with the reference; otherwise created on first use.
@export var actor_values: ActorValues
## Runtime state with no ESM source: the NPC_ or CREA chosen from the leveled
## list (LVLN, LVLC) in the base's template chain, chosen once on first use by
## get_leveled_template() at the player's level, seeded from instance_id. Null
## until chosen, and for an actor with no leveled list. Used by
## template_source().
@export var leveled_template: ActorBase
@export_group("")

## Runtime state with no ESM source: the reference this actor is using
## (terminal, container, furniture, a door it is lockpicking), or null. One at
## a time. Set only by ScriptServer.begin_use / end_use; not saved.
var using: EsmReference = null
## Runtime state: the furniture marker index occupied while using furniture,
## else -1.
var using_marker: int = -1

## XMRC's placed container, built on demand; null when there is none.
func get_merchant_container() -> EsmReference:
	var server := get_esm_server()
	if merchant_container_form_id == 0 or server == null:
		return null
	return server.get_reference("authored:%08X" % merchant_container_form_id)

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
func get_leveled_template() -> ActorBase:
	if leveled_template != null:
		return leveled_template
	var list := ActorBase.leveled_list_in_chain(base)
	if list == null:
		return null
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(instance_id)
	leveled_template = LeveledActorResolver.resolve(list, _player_level(), rng)
	return leveled_template

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
