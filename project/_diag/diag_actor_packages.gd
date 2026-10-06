extends Node

## Prints each named placed actor's packages (PKID, template-aware) in order,
## with type, schedule, locations, targets, PKDD and conditions; for checking
## what a package should do before implementing it.

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	for name in OS.get_cmdline_user_args():
		var actor := EsmServer.find_reference_by_editor_id(name) as ActorReference
		if actor == null:
			print("%s: no placed actor" % name)
			continue
		var source := ActorBase.template_source(actor.base, PackageRunner.TEMPLATE_USE_AI_PACKAGES)
		print("===== %s (%s)" % [name, source.editor_id])
		for package: PackageBase in source.packages:
			_print_package(package)
	get_tree().quit()

func _print_package(p: PackageBase) -> void:
	print("--- %s %08X type %s flags %X" % [p.editor_id, p.form_id, PackageBase.PackageType.keys()[p.package_type], p.general_flags])
	print("    schedule time %d duration %d dow %d" % [p.schedule_time, p.schedule_duration_hours, p.schedule_day_of_week])
	if p.has_location_1:
		print("    location 1: %s %s radius %d" % [PackageBase.LocationType.keys()[p.location_1_type], _ref_name(p.location_1_form_id), p.location_1_radius])
	if p.has_location_2:
		print("    location 2: %s %s radius %d" % [PackageBase.LocationType.keys()[p.location_2_type], _ref_name(p.location_2_form_id), p.location_2_radius])
	if p.has_target_1:
		print("    target 1: %s %s count/distance %d" % [PackageBase.TargetType.keys()[p.target_1_type], _ref_name(p.target_1_form_id), p.target_1_count_or_distance])
	if p.has_dialogue_data:
		print("    PKDD: topic %s, flags %X, type %d, fov %.1f" % [p.dialogue_topic.editor_id if p.dialogue_topic != null else "none", p.dialogue_flags, p.dialogue_type, p.dialogue_field_of_view])
	for c: ConditionSubrecord in p.conditions:
		var function_name: String = ScriptConditionFunctions.BY_INDEX.get(c.function_index, ["#%d" % c.function_index])[0]
		print("    condition: %s(%s, %s) %s %s  run on %d flags %X" % [function_name, _ref_name(c.parameter_1), c.parameter_2, Condition_names[c.comparison] if c.comparison < Condition_names.size() else c.comparison, c.comparison_value, c.run_on, c.flags])
	for pair in [["on begin", p.on_begin], ["on end", p.on_end], ["on change", p.on_change]]:
		var event: PackageEventCollection = pair[1]
		if event != null and (not event.script_source.strip_edges().is_empty() or event.idle != null or event.topic != null):
			print("    %s: idle %s topic %s script %s" % [pair[0], event.idle.editor_id if event.idle != null else "-", event.topic.editor_id if event.topic != null else "-", event.script_source.strip_edges().replace("\n", " | ")])

const Condition_names := ["==", "!=", ">", ">=", "<", "<="]

func _ref_name(form_id: int) -> String:
	if form_id == 0:
		return "-"
	if form_id == PackageBase.PLAYER_REFERENCE_FORM_ID:
		return "player"
	var reference := EsmServer.get_reference("authored:%08X" % form_id)
	if reference != null:
		var label := "%s %08X" % [reference.get_class() if reference.get_script() == null else reference.get_script().get_global_name(), form_id]
		if reference.base != null:
			label += " of %s" % reference.base.editor_id
		return label
	var base := EsmServer.get_base(form_id)
	return base.editor_id if base != null else "%08X" % form_id
