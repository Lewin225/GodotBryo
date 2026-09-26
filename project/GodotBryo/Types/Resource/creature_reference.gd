@tool
class_name CreatureReference
extends EsmReference

@export var health: float = -1.0
@export var count: int = 1
@export var radius: float = 0.0
@export var merchant_container_form_id: int = 0
@export var owner_form_id: int = 0
@export var faction_rank: int = -1
@export var idle_time: float = 0.0
@export var idle_form_id: int = 0
@export var topic_form_id: int = 0
@export var alive: bool = true
@export var contents: Inventory
## Actor values: what has changed from the base record's derived values.
## Created on first use.
@export var actor_values: ActorValues

func get_actor_values() -> ActorValues:
	if actor_values == null:
		actor_values = ActorValues.new()
	actor_values.owner = self
	return actor_values
