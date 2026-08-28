extends Node

# Issue #52 chunk 5: real-data verification that GamebryoObjectRegistry
# dispatches ACHR/ACRE placements (EsmReader.get_cell_actors(), NOT
# get_cell_references() -- confirmed separate in chunk 1) to NPCNode/
# CreatureNode. NPCNode gets the real full humanoid assembly (chunks 2/4's
# own confirmed ESM structure: skeleton from NPC_.MODL, gender-selected
# body parts from RACE's real INDX blocks via esm.get_race_body_parts());
# CreatureNode stays deliberately thin (see creature_node.gd's own doc
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
			check(node is NPCNode, "built node is an NPCNode")
			if node != null:
				check(node.editor_id == "DocMitchell", "identity carried through _finalize()")
				check(node.get_character_body() != null, "NPCNode got its composed CharacterBody")

				var skeleton: Skeleton3D = null
				var mesh_instances := 0
				for child in node.get_children():
					if child is Skeleton3D:
						skeleton = child
					elif child is MeshInstance3D:
						mesh_instances += 1
				check(skeleton != null, "real Skeleton3D built from NPC_.MODL")
				if skeleton != null:
					check(skeleton.get_bone_count() == 66, "real 66-bone skeleton (same as test_humanoid_assembly.gd's own direct check, got %d)" % skeleton.get_bone_count())
				check(mesh_instances == 8, "8 real MeshInstance3D from RACE's male body parts (upper body + 2 hands, got %d)" % mesh_instances)
				add_child(node)

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
				check(node is CreatureNode, "built node is a CreatureNode")
				if node != null:
					check(node.get_character_body() != null, "CreatureNode got its composed CharacterBody")
					var has_skeleton := false
					for child in node.get_children():
						if child is Skeleton3D:
							has_skeleton = true
					check(not has_skeleton, "CreatureNode stays a deliberately thin leaf -- no auto skeleton wiring yet (see creature_node.gd)")
					add_child(node)

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
