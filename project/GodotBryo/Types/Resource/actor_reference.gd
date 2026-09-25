@tool
class_name ActorReference
extends EsmReference

enum SimulationMode { LOW_LEVEL, PHYSICAL_LEASED }

## Immutable CELL which authored this ACHR placement. Save loading restores an
## overlay onto this shared Resource; it must never rewrite spawn provenance.
@export var spawn_cell_form_id: int = 0
## NSS hand-off state only. No controller or simulation behavior is attached
## to this prototype state transition.
@export var simulation_mode: SimulationMode = SimulationMode.LOW_LEVEL
## The selected PACK. Normal evaluation points this at one of
## `NpcBase.packages`; AddScriptPackage may temporarily select another
## authored PackageBase. Package selection/evaluation is not implemented yet.
@export var active_package: PackageBase

@export var health: float = -1.0
@export var count: int = 1
@export var radius: float = 0.0
@export var merchant_container_form_id: int = 0
@export var idle_time: float = 0.0
@export var idle_form_id: int = 0
@export var topic_form_id: int = 0
@export var alive: bool = true
@export var contents: Inventory
