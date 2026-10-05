extends Node

## GSDocMitchellHouse's doors against its NAVM: each door reference (XTEL or
## internal, locked, base), the NVDP links, and the triangles nearest each
## door with their NVTR Flags.

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var data_dir := String(preload("res://game_data_config.gd").resolve().get("data_dir", ""))
	var navmesh := NavmeshReader.new()
	navmesh.load_plugins(PackedStringArray([data_dir + "FalloutNV.esm"]))
	var cell := EsmServer.find_form_id_by_editor_id("GSDocMitchellHouse")
	var records: PackedInt32Array = navmesh.get_records_in_space(cell)
	for record in records:
		var links: Dictionary = navmesh.get_record_door_links(record)
		print("NAVM %08X: %d triangles, NVDP %s -> triangles %s" % [int(navmesh.get_record_info(record)["form_id"]), navmesh.get_record_triangle_flags(record).size(), _hex_list(links["door_form_ids"]), links["triangles"]])
		var flags: PackedInt32Array = navmesh.get_record_triangle_flags(record)
		var flagged := []
		for triangle in flags.size():
			if flags[triangle] & 0x0400:
				flagged.append(triangle)
		print("  triangles with 0x0400: %s" % [flagged])
	for reference in EsmServer.get_references_in_cell(cell):
		if not reference is DoorReference:
			continue
		var door := reference as DoorReference
		print("door %s (base %08X): %s, %s, at %s" % [door.instance_id, door.base_form_id, "XTEL" if door.has_teleport else "internal", "locked" if door.is_locked else "unlocked", door.position])
		for record in records:
			_print_nearest(navmesh, record, door.position)
	get_tree().quit()

## The three triangles whose centres are nearest `position` (ignoring height),
## with their flags and distance.
func _print_nearest(navmesh: NavmeshReader, record: int, position: Vector3) -> void:
	var points: PackedVector3Array = navmesh.get_record_triangle_points(record)
	var flags: PackedInt32Array = navmesh.get_record_triangle_flags(record)
	var distances := []
	for triangle in points.size() / 3:
		var centre := (points[triangle * 3] + points[triangle * 3 + 1] + points[triangle * 3 + 2]) / 3.0
		distances.append([Vector2(centre.x, centre.y).distance_to(Vector2(position.x, position.y)), triangle])
	distances.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	for entry in distances.slice(0, 3):
		print("    triangle %d: %.2f m away, flags 0x%04X" % [entry[1], entry[0], flags[entry[1]]])

func _hex_list(values: PackedInt32Array) -> String:
	var parts := []
	for value in values:
		parts.append("%08X" % value)
	return "[%s]" % ", ".join(parts)
