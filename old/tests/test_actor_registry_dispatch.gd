extends Node

# Issue #52 chunk 5: real-data verification that GamebryoObjectRegistry
# dispatches ACHR/ACRE placements (EsmReader.get_cell_actors(), NOT
# get_cell_references() -- confirmed separate in chunk 1) to NPCActor/
# CreatureActor. NPCActor gets the real full humanoid assembly (chunks 2/4's
# own confirmed ESM structure: skeleton from NPC_.MODL, gender-selected
# body parts from RACE's real INDX blocks via esm.get_race_body_parts());
# CreatureActor stays deliberately thin (see creature_actor.gd's own doc
# comment for why -- no ESM-declared body-mesh path for creatures, unlike
# RACE for NPC_).

const DATA_DIR := "../fresh_nv_copy/Data/"

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func _ready() -> void:
	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened FalloutNV.esm")

	var resolver := GamebryoMeshResolver.new()
	var registry := GamebryoObjectRegistry.new(resolver, esm)

	check(registry.is_registered("NPC_"), "NPC_ is registered")
	check(registry.is_registered("CREA"), "CREA is registered")

	# --- Doc Mitchell: real ACHR -> NPC_ -> full humanoid assembly ---
	var house: Dictionary = esm.find_cell_by_editor_id("GSDocMitchellHouse")
	check(not house.is_empty(), "found GSDocMitchellHouse")
	if not house.is_empty():
		var actors: Array = esm.get_cell_actors(int(house["form_id"]))
		var doc_placement: Dictionary = {}
		for a in actors:
			if String(a.get("editor_id", "")) == "DocMitchell":
				doc_placement = a
		check(not doc_placement.is_empty(), "found Doc Mitchell's real ACHR placement")
		if not doc_placement.is_empty():
			check(int(doc_placement["race_form_id"]) != 0, "placement carries a real race_form_id")
			var node := registry.build(doc_placement)
			check(node != null, "registry.build() on an NPC_ placement returns a node")
			check(node is NPCActor, "built node is an NPCActor")
			if node != null:
				check(node.editor_id == "DocMitchell", "identity carried through _finalize()")

				var body: Node = node.get_node_or_null(^"Body")
				check(body != null, "generated content lives under a dedicated Body container (see npc_actor.gd's own doc comment)")
				check(body != null and body.get_node_or_null(^"NudeBody") != null, "nude body meshes have a dedicated Body/NudeBody container")
				check(body != null and body.get_node_or_null(^"Equipment") != null, "equipment has a dedicated Body/Equipment container")
				var skeleton: Skeleton3D = null
				var mesh_instances := 0
				if body != null:
					for child in body.find_children("*", "Skeleton3D", true, false):
						skeleton = child
					for child in body.find_children("*", "MeshInstance3D", true, false):
						if bool(child.get_meta("gamebryo_nude_body", false)):
							mesh_instances += 1
				check(skeleton != null, "real Skeleton3D built from NPC_.MODL")
				if skeleton != null:
					check(skeleton.get_bone_count() == 66, "real 66-bone skeleton (same as test_humanoid_assembly.gd's own direct check, got %d)" % skeleton.get_bone_count())
				check(mesh_instances == 8, "8 real MeshInstance3D from RACE's male body parts (upper body + 2 hands, got %d)" % mesh_instances)
				add_child(node)

				# Equipment refresh is intentionally narrower than populate(): it
				# replaces only Body/Equipment and keeps the actor's live rig.
				var body_before_refresh := body
				var skeleton_before_refresh := skeleton
				var equipment_before_refresh := body.get_node_or_null(^"Equipment")
				node.equipment_state = EquipmentState.new()
				check(node.get_node_or_null(^"Body") == body_before_refresh, "equipment refresh preserves the Body container")
				check(node.get_node_or_null(^"Body/Skeleton3D") == skeleton_before_refresh, "equipment refresh preserves the Skeleton3D")
				check(not is_instance_valid(equipment_before_refresh), "equipment refresh removes only the previous Equipment subtree")
				check(node.get_node_or_null(^"Body/Equipment") != null, "equipment refresh recreates the dedicated Equipment subtree")

				# Real regression guard for the actual reason Body exists as
				# its own container (see npc_actor.gd's own top doc comment):
				# a hand-authored SIBLING of Body (e.g. a future
				# AnimationTree) must survive populate() being called again
				# on an already-built node, not get wiped by an
				# indiscriminate "clear every child" pass.
				var fake_sibling := Node.new()
				fake_sibling.name = "FakeHandAuthoredSibling"
				node.add_child(fake_sibling)
				var old_body := body
				node.populate(doc_placement, esm, registry.resolver)
				check(is_instance_valid(fake_sibling) and fake_sibling.get_parent() == node,
						"a hand-authored sibling of Body survives populate() being called again")
				var new_body: Node = node.get_node_or_null(^"Body")
				check(new_body != null and new_body != old_body,
						"Body itself is genuinely rebuilt (a new instance), not left stale")

	# --- Goodsprings raven: real ACRE -> CREA -> thin leaf ---
	var wrld: Dictionary = esm.find_worldspace_by_editor_id("WastelandNV")
	check(not wrld.is_empty(), "found WastelandNV worldspace")
	if not wrld.is_empty():
		var ext_cell: Dictionary = esm.find_exterior_cell(int(wrld["form_id"]), -17, 0)
		check(not ext_cell.is_empty(), "found Goodsprings (-17,0) cell")
		if not ext_cell.is_empty():
			var actors: Array = esm.get_cell_actors(int(ext_cell["form_id"]))
			var crow_placement: Dictionary = {}
			for a in actors:
				if String(a.get("base_type", "")) == "CREA":
					crow_placement = a
			check(not crow_placement.is_empty(), "found the real Goodsprings ACRE (raven) placement")
			if not crow_placement.is_empty():
				var node := registry.build(crow_placement)
				check(node != null, "registry.build() on a CREA placement returns a node")
				check(node is CreatureActor, "built node is a CreatureActor")
				if node != null:
					var has_skeleton := false
					for child in node.get_children():
						if child is Skeleton3D:
							has_skeleton = true
					check(not has_skeleton, "CreatureActor stays a deliberately thin leaf -- no auto skeleton wiring yet (see creature_actor.gd)")
					add_child(node)

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
