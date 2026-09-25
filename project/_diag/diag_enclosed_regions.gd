extends Node

## Can an enclosed exterior region -- a fenced compound whose only way out runs
## through a building -- actually be routed out of? This is the NCR Correctional
## Facility case. Before component-aware routing these produced a straight line
## clipping through the fence.

const NavNpcSimulationServerScript := preload("res://GodotBryo/Servers/NpcSimulationServer/nav_npc_simulation_server.gd")

func _ready() -> void:
	var esm = get_node("/root/EsmServer")
	if not esm.is_ready():
		await esm.esm_ready
	var sim = NavNpcSimulationServerScript.new()
	sim.records_per_frame = 256
	add_child(sim)
	await sim.seed_finished

	var navmesh = sim.navmesh
	print("components in whole navmesh: %d" % navmesh.get_component_count())

	# Largest exterior space
	var space_ids: PackedInt32Array = navmesh.get_space_ids()
	var biggest := 0
	var biggest_n := 0
	for s in space_ids:
		var n: int = navmesh.get_records_in_space(s).size()
		if n > biggest_n:
			biggest_n = n
			biggest = s

	# Group grounded actors in the exterior by walkable component.
	var by_component := {}
	for actor in sim.get_actors_in_space(biggest):
		if not sim.is_grounded(actor):
			continue
		var grounding: Dictionary = sim.grounding_by_instance_id[actor.instance_id]
		var component := int(grounding.get("component", -1))
		if component < 0:
			continue
		if not by_component.has(component):
			by_component[component] = []
		by_component[component].append(actor)

	var main_component := -1
	var main_count := -1
	for component in by_component:
		if by_component[component].size() > main_count:
			main_count = by_component[component].size()
			main_component = component
	print("exterior actor-bearing components: %d | main component holds %d actors" % [by_component.size(), main_count])

	var reachable := 0
	var unreachable := 0
	var walkable := 0
	var examples := 0
	for component in by_component:
		if component == main_component:
			continue
		var path: Array = sim.find_component_paths(component, main_component, 6, 1)
		if path.is_empty():
			unreachable += 1
			continue
		reachable += 1
		var from_actor = by_component[component][0]
		var to_actor = by_component[main_component][0]
		var route: Dictionary = sim.route_across_spaces(
			biggest, sim.get_ground_position(from_actor),
			biggest, sim.get_ground_position(to_actor))
		if bool(route.get("walkable", false)):
			walkable += 1
			if examples < 5:
				examples += 1
				print("  enclosed component %d -> main: %d doors, %d legs, %.0f m, walkable" % [
					component, int(route["door_count"]), (route["legs"] as Array).size(),
					float(route["total_length"])])
	print("enclosed exterior regions: %d reachable via doors, %d with no door route" % [reachable, unreachable])
	print("of the reachable, %d produced a FULLY WALKABLE route (no fence clipping)" % walkable)
	get_tree().quit(0)
