extends Node
## Every unskinned CREA NIFZ part: its Prn and its suppressed root transform.
var _pending := 0
var _rows := {}
func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var paths := {}
	for row: Dictionary in EsmServer.get_record_index():
		if String(row.get("record_type", "")) != "CREA":
			continue
		var base := EsmServer.get_base(int(row["form_id"])) as CreatureBase
		if base == null:
			continue
		for part in base.model_list_paths:
			paths[part.to_lower()] = part
	for key: String in paths:
		_pending += 1
		NifServer.request(paths[key], self, _on_tree.bind(paths[key]), false)
	while _pending > 0:
		await get_tree().process_frame
	var identity := 0
	var rotated := 0
	for path: String in _rows:
		var t: Transform3D = _rows[path][1]
		if t.is_equal_approx(Transform3D.IDENTITY):
			identity += 1
		else:
			rotated += 1
			print("ROT %s prn %s %s" % [path, _rows[path][0], t])
	print("rigid parts: identity root %d, non-identity root %d" % [identity, rotated])
	get_tree().quit()
func _on_tree(tree: Node3D, path: String) -> void:
	_pending -= 1
	if tree == null:
		return
	if not tree.find_children("*", "MeshInstance3D", true, false).filter(func(m): return m.skin != null).is_empty():
		tree.free()
		return
	var prn := ""
	var root_t := Transform3D.IDENTITY
	for node: Node in [tree] + tree.find_children("*", "Node3D", true, false):
		if node.has_meta("nif_suppressed_file_root_transform"):
			root_t = node.get_meta("nif_suppressed_file_root_transform")
		var strings: Dictionary = node.get_meta("nif_string_extra_data", {})
		if strings.has("Prn") and prn.is_empty():
			prn = strings["Prn"]
	_rows[path] = [prn, root_t]
	tree.free()
