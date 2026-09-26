@tool
class_name CreatureReference
extends EsmReference

## XHLP (Health). Present on no ACHR or ACRE in FalloutNV.esm; not read.
## Not the actor's health, which is ActorValues' Health.
@export var health: float = -1.0
## XCNT (Count). Present on no ACHR or ACRE in FalloutNV.esm; not read.
@export var count: int = 1
## XRDS (Radius). Present on no ACHR or ACRE in FalloutNV.esm; not read.
@export var radius: float = 0.0
## XMRC: the REFR holding this actor's merchant inventory. On 76 ACHR and
## 1 ACRE in FalloutNV.esm; not read yet, so always 0.
@export var merchant_container_form_id: int = 0
## XOWN: the owning NPC_ or FACT. On 10 ACRE in FalloutNV.esm; not read yet,
## so always 0.
@export var owner_form_id: int = 0
## XRNK (owner faction rank). Present on no ACRE in FalloutNV.esm; not read.
@export var faction_rank: int = -1
## XPRD (patrol data Idle Time). Present on no ACHR or ACRE in
## FalloutNV.esm; not read.
@export var idle_time: float = 0.0
## INAM (patrol data Idle). Present on no ACHR or ACRE in FalloutNV.esm;
## not read.
@export var idle_form_id: int = 0
## TNAM (patrol data Topic). Present on no ACHR or ACRE in FalloutNV.esm;
## not read.
@export var topic_form_id: int = 0
## Runtime state with no ESM source. Nothing sets or reads it yet.
@export var alive: bool = true
## The actor's live inventory, seeded from its base record's CNTO.
@export var contents: Inventory
## Actor values: what has changed from the base record's derived values.
## EsmServer creates it with the reference; otherwise created on first use.
@export var actor_values: ActorValues

func get_actor_values() -> ActorValues:
	if actor_values == null:
		actor_values = ActorValues.new()
	actor_values.owner = self
	return actor_values
