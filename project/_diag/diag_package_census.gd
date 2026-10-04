extends Node

## Census A3 (Plans/Actors/census.md): the AI packages of every NPC placed in
## Goodsprings -- ACHRs filed in an interior CELL whose editor ID starts with
## "GS", and ACHRs in WastelandNV at grid x -19..-15, y -2..1 -- with the
## packages each runs (PKID, through TPLT when ACBS template flag 0x20, Use AI
## Packages, is set), then each package decoded, then counts by type.

const TEMPLATE_USE_AI_PACKAGES := 0x20
const TYPES := ["Find", "Follow", "Escort", "Eat", "Sleep", "Wander", "Travel", "Accompany", "Use Item At", "Ambush", "Flee Not Combat", "Cast Magic", "Sandbox", "Patrol", "Guard", "Dialogue", "Use Weapon"]
const LOCATION_TYPES := ["Near reference", "In cell", "Near current location", "Near editor location", "Object ID", "Object Type", "Near linked reference", "At package location"]
const TARGET_TYPES := ["Specific reference", "Object ID", "Object Type", "Linked reference"]
const UNITS_PER_CELL := 4096.0 / 70.0 # metres

var _edid_cache := {}

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var wasteland := _form_id_of_wrld("WastelandNV")
	var population: Array[ActorReference] = []
	for actor in EsmServer.get_all_placed_actor_references():
		var cell := int(EsmServer.get_filing_cell_form_id(int(actor.instance_id.trim_prefix("authored:").hex_to_int())))
		if actor.current_space_form_id == wasteland:
			var gx := floori(actor.position.x / UNITS_PER_CELL)
			var gy := floori(actor.position.y / UNITS_PER_CELL)
			if gx >= -19 and gx <= -15 and gy >= -2 and gy <= 1:
				population.append(actor)
		elif _edid(cell).begins_with("GS"):
			population.append(actor)
	print("## Population: %d ACHR" % population.size())
	var packages := {} # form id -> PackageBase
	var used_by := {} # package form id -> count of population actors
	for actor in population:
		var source_note := ""
		var source := ActorBase.template_source(actor.base, TEMPLATE_USE_AI_PACKAGES)
		if source != actor.base:
			source_note = " (packages from template %s)" % source.editor_id
		var record := actor.base as ActorBase
		if (record.template_flags & TEMPLATE_USE_AI_PACKAGES) != 0 and source == actor.base:
			source_note = " (Use AI Packages from %s %s, not followed)" % [_type_of(record.template_form_id), _edid(record.template_form_id)]
		var names: Array[String] = []
		var list: Array = source.get("packages") if source.get("packages") != null else []
		for package: PackageBase in list:
			if package == null:
				continue
			names.append(package.editor_id)
			packages[package.form_id] = package
			used_by[package.form_id] = int(used_by.get(package.form_id, 0)) + 1
		print("%s [%s] in %s%s: %s" % [_edid(int(actor.instance_id.trim_prefix("authored:").hex_to_int())), actor.base.editor_id, _edid(actor.current_cell_form_id), source_note, ", ".join(names)])
	for editor_id in ["VCG00PlayerSection0", "VCG00PlayerSection1", "VCG00PlayerSection2", "VCG01PlayerSection0", "VCG01PlayerSection1", "VCG01PlayerSection2", "SunnyTriggerGunfightDialoguePackage", "RingoTravelPackage", "SunnyTravelPackage", "GSRingoAfterVMS16DialoguePackage", "GSRingoDialoguePackage", "GSRingoAtCrimsonCaravanDialogue"]:
		var added := EsmServer.find_base_by_editor_id(editor_id) as PackageBase
		if added != null:
			packages[added.form_id] = added
			used_by[added.form_id] = 0
	print("\n## Packages: %d" % packages.size())
	var by_type := {}
	for id: int in packages:
		var p: PackageBase = packages[id]
		by_type[TYPES[p.package_type]] = int(by_type.get(TYPES[p.package_type], 0)) + 1
		print("%08X %s: %s, used by %d; flags 0x%X, type flags 0x%X" % [id, p.editor_id, TYPES[p.package_type], used_by[id], p.general_flags_raw, p.type_specific_flags_raw])
		for pair in [["loc1", p.location_1], ["loc2", p.location_2]]:
			if pair[1] != null:
				print("    %s %s" % [pair[0], _location(pair[1])])
		for pair in [["target1", p.target_1], ["target2", p.target_2]]:
			if pair[1] != null:
				print("    %s %s %s, count/distance %d" % [pair[0], TARGET_TYPES[pair[1].target_type] if pair[1].target_type < TARGET_TYPES.size() else str(pair[1].target_type), _value(pair[1].target_value, pair[1].target_type), pair[1].count_or_distance])
		if p.schedule != null:
			print("    schedule month %d, day %d, date %d, hour %d, %d h" % [p.schedule.month, p.schedule.day_of_week, p.schedule.date, p.schedule.time, p.schedule.duration_hours])
		for c in p.conditions:
			print("    if %s(%s, %s) %s %s%s" % [ScriptConditionFunctions.name_for_index(c.function_index), _edid(c.parameter_1) if c.parameter_1 > 0xFFFF else str(c.parameter_1), str(c.parameter_2), ["==", "!=", ">", ">=", "<", "<="][c.comparison], c.comparison_value, " OR" if c.is_or() else ""])
		if p.dialogue_data != null:
			print("    dialogue topic %s, type %d, flags 0x%X" % [_edid(p.dialogue_data.topic_form_id), p.dialogue_data.dialogue_type, p.dialogue_data.flags])
		if p.has_use_item_marker:
			print("    use item marker")
		if not p.idle_animation_form_ids.is_empty():
			print("    idles %s" % [p.idle_animation_form_ids.map(func(i): return _edid(i))])
		for pair in [["on begin", p.on_begin], ["on end", p.on_end], ["on change", p.on_change]]:
			var e: PackageEventCollection = pair[1]
			if e != null and (not e.script_source.strip_edges().is_empty() or e.idle_form_id != 0 or e.topic_form_id != 0):
				print("    %s: idle %s topic %s script %s" % [pair[0], _edid(e.idle_form_id), _edid(e.topic_form_id), e.script_source.strip_edges().replace("\r", "").replace("\n", " | ").left(200)])
	print("\n## By type")
	for t in by_type:
		print("%s: %d" % [t, by_type[t]])
	get_tree().quit()

func _location(l: PackageLocation) -> String:
	var v: PackageLocationValue = l.location_value
	var what := ""
	if v != null:
		if not v.reference_instance_id.is_empty():
			what = _edid(v.reference_instance_id.trim_prefix("authored:").hex_to_int())
		elif v.cell_form_id != 0:
			what = _edid(v.cell_form_id)
		elif v.object_base_form_id != 0:
			what = _edid(v.object_base_form_id)
		else:
			what = "object type %d" % v.object_type
	return "%s %s radius %d" % [LOCATION_TYPES[l.location_type] if l.location_type < LOCATION_TYPES.size() else str(l.location_type), what, l.radius]

func _value(value: int, type: int) -> String:
	return "object type %d" % value if type == 2 else _edid(value)

func _type_of(form_id: int) -> String:
	return String(EsmServer.reader.get_record_data(form_id).get("record_type", "?")) if form_id != 0 else ""

func _edid(form_id: int) -> String:
	if form_id == 0:
		return "-"
	if form_id == 0x14:
		return "PlayerRef"
	if _edid_cache.has(form_id):
		return _edid_cache[form_id]
	var raw: Dictionary = EsmServer.reader.get_record_data(form_id)
	var name := "%08X" % form_id
	for s in raw.get("subrecords", []):
		if s.get("type") == "EDID":
			name = s["data"].get_string_from_ascii()
			break
	_edid_cache[form_id] = name
	return name

func _form_id_of_wrld(editor_id: String) -> int:
	for row: Dictionary in EsmServer.get_record_index():
		if String(row.get("record_type", "")) == "WRLD" and String(row.get("editor_id", "")) == editor_id:
			return int(row["form_id"])
	return 0
