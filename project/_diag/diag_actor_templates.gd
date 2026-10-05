extends Node

## How placed actors get their appearance: base type (NPC_, CREA, LVLN,
## LVLC), and for NPC_ / CREA bases whether the Traits (NPC_) or
## Model/Animation (CREA) template flag sends it to a template, and what that
## template is.

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var by_base := {}
	var templated := {}
	for actor: ActorReference in EsmServer.get_all_placed_actor_references():
		var base := actor.base
		var kind: String = base.get_script().get_global_name() if base != null else "none"
		by_base[kind] = int(by_base.get(kind, 0)) + 1
		var actor_base := base as ActorBase
		if actor_base == null:
			continue
		var flag := ActorBase.TEMPLATE_USE_TRAITS if base is NpcBase else ActorBase.TEMPLATE_USE_MODEL_ANIMATION
		if (actor_base.template_flags & flag) == 0 or actor_base.template_form_id == 0:
			continue
		var template_kind: String = actor_base.template.get_script().get_global_name() if actor_base.template != null else "unresolved"
		var key := "%s -> %s" % [kind, template_kind]
		templated[key] = int(templated.get(key, 0)) + 1
	print("placed actors by base: %s" % by_base)
	print("appearance from a template: %s" % templated)
	get_tree().quit()
