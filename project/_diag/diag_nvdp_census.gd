extends Node

## Census of every NVDP door link in the six masters NpcSimulationServer loads:
## what each linked reference is (door with or without XTEL, locked, open by
## default), how many triangles and records each door has, whether the linked
## triangle index is in range for the owning record, and which NVTR Flags bits
## door triangles carry compared with all triangles.

const PLUGINS := [
	"FalloutNV.esm", "DeadMoney.esm", "HonestHearts.esm",
	"OldWorldBlues.esm", "LonesomeRoad.esm", "GunRunnersArsenal.esm",
]

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var data_dir := String(preload("res://game_data_config.gd").resolve().get("data_dir", ""))
	var paths := PackedStringArray()
	for plugin: String in PLUGINS:
		if FileAccess.file_exists(data_dir + plugin):
			paths.append(data_dir + plugin)
	var navmesh := NavmeshReader.new()
	navmesh.load_plugins(paths)

	var link_count := 0
	var out_of_range := 0
	var triangles_by_door := {}
	var records_by_door := {}
	var door_flag_bits := {}
	var all_flag_bits := {}
	var door_triangle_count := 0
	var all_triangle_count := 0
	for record in navmesh.get_record_count():
		var flags: PackedInt32Array = navmesh.get_record_triangle_flags(record)
		all_triangle_count += flags.size()
		for value in flags:
			_tally_bits(all_flag_bits, value)
		var links: Dictionary = navmesh.get_record_door_links(record)
		var doors: PackedInt32Array = links["door_form_ids"]
		var triangles: PackedInt32Array = links["triangles"]
		for index in doors.size():
			link_count += 1
			var door := doors[index]
			var triangle := triangles[index]
			if triangle >= flags.size():
				out_of_range += 1
				continue
			door_triangle_count += 1
			_tally_bits(door_flag_bits, flags[triangle])
			if not triangles_by_door.has(door):
				triangles_by_door[door] = 0
				records_by_door[door] = {}
			triangles_by_door[door] += 1
			records_by_door[door][record] = true

	_print_unresolved(triangles_by_door, records_by_door, navmesh)
	print("NVDP links: %d (triangle index out of range for the owning record: %d)" % [link_count, out_of_range])
	print("distinct linked references: %d" % triangles_by_door.size())
	_print_kinds(triangles_by_door)
	_print_histogram("triangles per door", triangles_by_door.values())
	var record_counts := []
	for door in records_by_door:
		record_counts.append(records_by_door[door].size())
	_print_histogram("records per door", record_counts)
	print("NVTR Flags bits, door triangles (%d) vs all triangles (%d):" % [door_triangle_count, all_triangle_count])
	for bit in 16:
		var on_doors: int = door_flag_bits.get(bit, 0)
		var on_all: int = all_flag_bits.get(bit, 0)
		if on_doors == 0 and on_all == 0:
			continue
		print("  0x%04X: %d of door triangles (%.1f%%), %d of all (%.2f%%)" % [1 << bit, on_doors, 100.0 * on_doors / maxi(door_triangle_count, 1), on_all, 100.0 * on_all / maxi(all_triangle_count, 1)])
	get_tree().quit()

## The unresolved door FormIDs by load-order byte and by the plugin of the
## NAVM record linking them, with a few examples.
func _print_unresolved(triangles_by_door: Dictionary, records_by_door: Dictionary, navmesh: NavmeshReader) -> void:
	var by_prefix := {}
	var examples := []
	for door_form_id: int in triangles_by_door:
		if EsmServer.get_reference("authored:%08X" % door_form_id) != null:
			continue
		var record: int = records_by_door[door_form_id].keys()[0]
		var navm_form_id := int(navmesh.get_record_info(record)["form_id"])
		var key := "door %02X / NAVM %02X" % [door_form_id >> 24, navm_form_id >> 24]
		by_prefix[key] = int(by_prefix.get(key, 0)) + 1
		if examples.size() < 5:
			examples.append("door %08X in NAVM %08X" % [door_form_id, navm_form_id])
	print("unresolved by load-order byte: %s" % by_prefix)
	print("unresolved examples: %s" % ", ".join(examples))

func _tally_bits(tally: Dictionary, value: int) -> void:
	for bit in 16:
		if value & (1 << bit):
			tally[bit] = int(tally.get(bit, 0)) + 1

## What each linked reference is, by kind.
func _print_kinds(triangles_by_door: Dictionary) -> void:
	var kinds := {}
	for door_form_id: int in triangles_by_door:
		var kind := _kind(EsmServer.get_reference("authored:%08X" % door_form_id))
		kinds[kind] = int(kinds.get(kind, 0)) + 1
	var names := kinds.keys()
	names.sort()
	for kind in names:
		print("  %s: %d" % [kind, kinds[kind]])

func _kind(reference: EsmReference) -> String:
	if reference == null:
		return "not found"
	if not reference is DoorReference:
		return "not a door (%s)" % reference.get_script().get_global_name()
	var door := reference as DoorReference
	var parts := ["XTEL" if door.has_teleport else "internal"]
	parts.append("locked" if door.is_locked else "unlocked")
	if door.is_open_by_default:
		parts.append("open by default")
	return ", ".join(parts)

func _print_histogram(label: String, values: Array) -> void:
	var counts := {}
	for value: int in values:
		counts[value] = int(counts.get(value, 0)) + 1
	var keys := counts.keys()
	keys.sort()
	var parts := []
	for key in keys:
		parts.append("%d: %d" % [key, counts[key]])
	print("%s: %s" % [label, ", ".join(parts)])
