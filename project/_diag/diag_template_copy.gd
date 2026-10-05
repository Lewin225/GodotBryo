extends Node3D

## Physicalises COUNT actors in WastelandNV, lets NifServer settle, then times
## Node.duplicate() of every cached template (NifServer._trees) and prints the
## costliest, with node counts and what kinds of nodes they hold.

const COUNT := 20

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	NpcSimulationServer.records_per_frame = 512
	NpcSimulationServer.seed()
	if not NpcSimulationServer.is_seeded:
		await NpcSimulationServer.seed_finished
	var wasteland := EsmServer.find_form_id_by_editor_id("WastelandNV")
	var physicaliser := EsmReferencePhysicaliser.new()
	var count := 0
	for actor: ActorReference in NpcSimulationServer.get_actors_in_space(wasteland):
		if actor.is_disabled():
			continue
		physicaliser.physicalise(actor, self)
		count += 1
		if count >= COUNT:
			break
	var idle := 0
	for frame in 6000:
		await get_tree().process_frame
		idle = idle + 1 if NifServer.get_stats()["pending_build_count"] == 0 else 0
		if idle >= 300:
			break
	var rows := []
	for key: String in NifServer._trees:
		var template: Node = NifServer._trees[key]
		if template == null or not is_instance_valid(template):
			continue
		var started := Time.get_ticks_usec()
		for i in 5:
			template.duplicate().free()
		var usec := (Time.get_ticks_usec() - started) / 5
		var kinds := {}
		for node in template.find_children("*", "", true, false):
			kinds[node.get_class()] = int(kinds.get(node.get_class(), 0)) + 1
		rows.append({"key": key, "usec": usec, "nodes": NifServer._tree_nodes.get(key, 0), "kinds": kinds})
	rows.sort_custom(func(a, b): return a["usec"] > b["usec"])
	var total := 0
	for row in rows:
		total += row["usec"]
	print("%d templates, %.1f ms to copy them all once" % [rows.size(), total / 1000.0])
	for row in rows.slice(0, 15):
		var kinds: Dictionary = row["kinds"]
		var top := kinds.keys()
		top.sort_custom(func(a, b): return kinds[a] > kinds[b])
		var parts := []
		for kind in top.slice(0, 5):
			parts.append("%s %d" % [kind, kinds[kind]])
		print("%7.2f ms  %5d nodes  %s  [%s]" % [row["usec"] / 1000.0, row["nodes"], row["key"], ", ".join(parts)])
	if OS.get_cmdline_user_args().has("growth"):
		await _growth()
	get_tree().quit()

## Times copies of one small template as copies of it accumulate, kept out of
## the tree and then in it.
func _growth() -> void:
	var key := ""
	for candidate: String in NifServer._trees:
		if candidate.contains("teethlower"):
			key = candidate
	if key.is_empty():
		key = NifServer._trees.keys()[0]
	var template: Node = NifServer._trees[key]
	print("growth with %s (%d nodes)" % [key, NifServer._tree_nodes.get(key, 0)])
	for in_tree in [false, true]:
		var kept := []
		var holder := Node3D.new()
		if in_tree:
			add_child(holder)
		for batch in 8:
			var started := Time.get_ticks_usec()
			for i in 1000:
				var copy := template.duplicate()
				kept.append(copy)
				if in_tree:
					holder.add_child(copy)
			print("  %s: copies %d-%d, %.3f ms each" % ["in tree" if in_tree else "out of tree", batch * 1000, batch * 1000 + 999, (Time.get_ticks_usec() - started) / 1000.0 / 1000.0])
			await get_tree().process_frame
		for copy in kept:
			copy.free()
		holder.free()
