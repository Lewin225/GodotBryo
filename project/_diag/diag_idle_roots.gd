extends Node

## The IDLE tree's top-level items (no ANAM parent) with their MODL, how many
## items lie under each, and the ancestry of the items named on the command
## line.

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var idles: Array[IdleBase] = []
	for row: Dictionary in EsmServer.get_record_index():
		if String(row.get("record_type", "")) == "IDLE":
			idles.append(EsmServer.get_base(int(row["form_id"])) as IdleBase)
	var under := {}
	for idle in idles:
		var root := idle
		while root.parent != null:
			root = root.parent
		under[root] = int(under.get(root, 0)) + 1
	var roots_with_children := 0
	for root: IdleBase in under:
		if under[root] > 1:
			roots_with_children += 1
			print("root %s %08X  %s  items %d  loose %s" % [root.editor_id, root.form_id, root.model_path, under[root], (root.animation_group_section & IdleBase.SECTION_FLAG_LOOSE) != 0])
	print("%d IDLE; %d top-level items, %d with items under them" % [idles.size(), under.size(), roots_with_children])
	for name in OS.get_cmdline_user_args():
		var idle := EsmServer.find_base_by_editor_id(name) as IdleBase
		var chain := []
		while idle != null:
			chain.append("%s (%s)" % [idle.editor_id, idle.model_path.get_file() if idle.has_kf() else idle.model_path])
			idle = idle.parent
		print("ancestry: " + " <- ".join(chain))
	get_tree().quit()
