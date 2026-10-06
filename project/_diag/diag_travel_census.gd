extends Node

## Census of Travel packages in FalloutNV.esm: Location 1 types and how many
## have no Location 1, radii, and how many carry On Begin / On End / On Change
## events with a script, idle or topic.

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var types := {}
	var radius_zero := 0
	var no_location := 0
	var events := {"on begin": [0, 0, 0], "on end": [0, 0, 0], "on change": [0, 0, 0]}
	var total := 0
	for row: Dictionary in EsmServer.get_record_index():
		if String(row.get("record_type", "")) != "PACK":
			continue
		var package := EsmServer.get_base(int(row["form_id"])) as PackageBase
		if package == null or package.package_type != PackageBase.PackageType.TRAVEL:
			continue
		total += 1
		if not package.has_location_1:
			no_location += 1
			continue
		var name: String = PackageBase.LocationType.keys()[package.location_1_type] if package.location_1_type < PackageBase.LocationType.size() else str(package.location_1_type)
		types[name] = int(types.get(name, 0)) + 1
		if package.location_1_radius == 0:
			radius_zero += 1
		for pair in [["on begin", package.on_begin], ["on end", package.on_end], ["on change", package.on_change]]:
			var event: PackageEventCollection = pair[1]
			if event == null:
				continue
			var counts: Array = events[pair[0]]
			if not event.script_source.strip_edges().is_empty():
				counts[0] += 1
			if event.idle_form_id != 0:
				counts[1] += 1
			if event.topic_form_id != 0:
				counts[2] += 1
	print("Travel packages: %d; no Location 1: %d; radius 0: %d" % [total, no_location, radius_zero])
	print("Location 1 types: %s" % types)
	print("events [script, idle, topic]: %s" % events)
	get_tree().quit()
