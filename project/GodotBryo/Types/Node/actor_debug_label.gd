class_name ActorDebugLabel
extends Label3D

## Floating text above an actor showing its level, leveled list choice, XLCM
## modifier and encounter zone. Hidden until toggled on for every actor with
## set_shown().

const HEIGHT := 2.2
const REFRESH_SECONDS := 0.5

## Whether every actor's label is shown.
static var shown := false

var _refresh_timer := 0.0


static func set_shown(value: bool) -> void:
	shown = value


func _ready() -> void:
	billboard = BaseMaterial3D.BILLBOARD_ENABLED
	no_depth_test = true
	fixed_size = true
	pixel_size = 0.0008
	font_size = 24
	outline_size = 6
	position = Vector3(0.0, HEIGHT, 0.0)
	visible = false


func _process(delta: float) -> void:
	visible = shown
	if not shown:
		return
	_refresh_timer -= delta
	if _refresh_timer > 0.0:
		return
	_refresh_timer = REFRESH_SECONDS
	var actor_node := get_parent() as EsmNode
	if actor_node == null or not actor_node.reference is ActorReference:
		text = ""
		return
	text = describe(actor_node.reference as ActorReference)


## The label's lines for `actor`.
static func describe(actor: ActorReference) -> String:
	var lines := PackedStringArray()
	var base := actor.base
	lines.append("%s  %s" % [_record_name(base), actor.instance_id])
	var values := actor.get_actor_values()
	if values != null:
		lines.append("level %d" % values.get_level())
	var list := ActorBase.leveled_list_in_chain(base)
	if list != null:
		var choice := actor.leveled_template
		var choice_name := _record_name(choice) if choice != null else "not chosen"
		lines.append("%s -> %s at level %d" % [_record_name(list), choice_name, actor.leveled_template_level])
	lines.append("XLCM: %s" % _modifier_name(actor.level_modifier))
	lines.append("zone: %s" % _zone_text(actor))
	return "\n".join(lines)


static func _zone_text(actor: ActorReference) -> String:
	var zone := actor.get_encounter_zone()
	if zone == null:
		return "none"
	var source := "own" if actor.encounter_zone != null else "cell"
	var level := str(zone.resolved_level) if zone.resolved_level > 0 else "unset"
	return "%s (%s) level %s, min %d" % [_record_name(zone), source, level, zone.minimum_level]


static func _modifier_name(modifier: int) -> String:
	match modifier:
		ActorReference.LEVEL_MODIFIER_NONE:
			return "none"
		ActorReference.LEVEL_MODIFIER_EASY:
			return "Easy"
		1:
			return "Medium"
		2:
			return "Hard"
		3:
			return "Boss"
	return str(modifier)


static func _record_name(record: Resource) -> String:
	if record == null:
		return "none"
	var editor_id := String(record.get("editor_id"))
	if not editor_id.is_empty():
		return editor_id
	return "0x%08X" % int(record.get("form_id"))
