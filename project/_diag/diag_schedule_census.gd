extends Node

## Census of PACK PSDT schedules over FalloutNV.esm: how often each value of
## month, day of week, date and time occurs, and the durations used with a
## set time, to know which schedule values selection has to handle.

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var months := {}
	var days := {}
	var dates := {}
	var times := {}
	var durations_with_time := {}
	var durations_without_time := {}
	var total := 0
	for row: Dictionary in EsmServer.get_record_index():
		if String(row.get("record_type", "")) != "PACK":
			continue
		var package := EsmServer.get_base(int(row["form_id"])) as PackageBase
		if package == null:
			continue
		total += 1
		_count(months, package.schedule_month)
		_count(days, package.schedule_day_of_week)
		_count(dates, package.schedule_date)
		_count(times, package.schedule_time)
		if package.schedule_time == -1:
			_count(durations_without_time, package.schedule_duration_hours)
		else:
			_count(durations_with_time, package.schedule_duration_hours)
	print("PACK records: %d" % total)
	print("month: %s" % _sorted(months))
	print("day of week: %s" % _sorted(days))
	print("date: %s" % _sorted(dates))
	print("time: %s" % _sorted(times))
	print("duration, time set: %s" % _sorted(durations_with_time))
	print("duration, time any: %s" % _sorted(durations_without_time))
	get_tree().quit()

func _count(counts: Dictionary, value: int) -> void:
	counts[value] = int(counts.get(value, 0)) + 1

func _sorted(counts: Dictionary) -> String:
	var keys := counts.keys()
	keys.sort()
	var parts := []
	for key in keys:
		parts.append("%s: %d" % [key, counts[key]])
	return ", ".join(parts)
