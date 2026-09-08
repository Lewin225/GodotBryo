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
var contents: Array[EsmReference] = []
var equipped_instance_ids: PackedStringArray = []
