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

@export_group("Placement")
## XLCM: Level Modifier (s32; 178 ACHR, 119 ACRE in FalloutNV.esm). Read; not
## used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var level_modifier: int = 0
## XEZN: the encounter zone (5 ACHR, 11 ACRE). Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var encounter_zone_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EncounterZoneBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var encounter_zone: EncounterZoneBase
## XMRC: the placed container holding this actor's merchant inventory (76
## ACHR, 1 ACRE). Read; not used yet (no barter).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var merchant_container_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EsmReference", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var merchant_container: EsmReference
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
## read.
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
## Runtime state with no ESM source: NpcSimulationServer's hand-off state. No
## controller or simulation behaviour is attached yet.
@export var simulation_mode: SimulationMode = SimulationMode.LOW_LEVEL
## Runtime state with no ESM source: the selected PACK, one of the base's
## `packages` or one AddScriptPackage gave. Package selection is not
## implemented yet.
@export var active_package: PackageBase
## Runtime state with no ESM source. Nothing sets or reads it yet.
@export var alive: bool = true
## Runtime state: the actor's live inventory, seeded from its base's Items.
@export var contents: Inventory
## Runtime state: what has changed from the base record's derived values.
## EsmServer creates it with the reference; otherwise created on first use.
@export var actor_values: ActorValues
@export_group("")

## Runtime state with no ESM source: the reference this actor is using
## (terminal, container, furniture, a door it is lockpicking), or null. One at
## a time. Set only by ScriptServer.begin_use / end_use; not saved.
var using: EsmReference = null
## Runtime state: the furniture marker index occupied while using furniture,
## else -1.
var using_marker: int = -1

func get_actor_values() -> ActorValues:
	if actor_values == null:
		actor_values = ActorValues.new()
	actor_values.owner = self
	return actor_values
