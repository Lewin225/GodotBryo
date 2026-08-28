@tool
class_name NPCNode
extends GamebryoActor

const GameDataConfigScript := preload("res://game_data_config.gd")

## Issue #52 chunk 5 (+ later): thin leaf for a placed NPC_ (enginedocs/
## nv_class_hierarchy.md's "Actors" section — "a rich shared GamebryoActor
## base... with genuinely thin NPCNode/CreatureNode leaves"). No extra
## fields yet: armor slots, dialogue, pickpocket-able state are all real
## future work, not invented ahead of a real need.
##
## `npc_node.tscn` (this script's own scene) is the hand-authored actor
## template GamebryoObjectRegistry._build_npc() instantiates for every real
## placed NPC_ — a deliberate exception to this codebase's "everything
## built purely in code" convention, since actors are meaningfully more
## complex (skeleton/animation, and eventually armor/items) than anything
## else placed in the world. Hand-authored scaffolding (e.g. future armor/
## weapon attach markers) belongs directly in npc_node.tscn, saved there —
## not reconstructed in code every time.
##
## Also a standalone @tool preview: open npc_node.tscn directly, pick a
## preset (or type a custom base_form_id) in the Inspector, press
## "Load Actor" — the exact same populate() method below runs, same "same
## code path in-editor and at runtime" discipline nif_viewer.gd already
## follows for NIFs (see that file's own doc comment), so there is no
## separate bespoke preview implementation to drift from what ships.

@export_enum("Custom", "Doc Mitchell (Goodsprings)") var preset: String = "Doc Mitchell (Goodsprings)"

## Only read when preset == "Custom". Hex NPC_ FormID, e.g. "0x00104C0C".
@export var custom_base_form_id: String = ""

@export_tool_button("Load Actor") var load_button: Callable = _editor_load

const PRESET_FORM_IDS := {
	"Doc Mitchell (Goodsprings)": 0x00104C0C,
}

## Real NPC_ construction — the full humanoid assembly confirmed real in
## issue #52 chunks 2/4. `placement["model"]` is the NPC_'s own MODL (the
## shared skeleton path, e.g. Characters\_Male\Skeleton.NIF — see
## EsmFile::get_cell_actors()'s doc comment, NOT a self-contained mesh);
## `placement["race_form_id"]`/`["is_female"]` resolve the real
## gender-selected body-part list via esm.get_race_body_parts() — RACE's
## own ESM-declared INDX blocks, not a guessed convention. Deliberately no
## SkeletonAnimationPlayer (populate_humanoid_skeleton() never builds one)
## and no head/face mesh (FaceGen is out of scope for this issue).
func populate(placement: Dictionary, esm: EsmReader, mesh_resolver: GamebryoMeshResolver) -> void:
	var skeleton_path: String = placement.get("model", "")
	var race_form_id := int(placement.get("race_form_id", 0))
	if skeleton_path == "" or race_form_id == 0:
		return
	var is_female := bool(placement.get("is_female", false))
	var body_part_paths: Array = []
	for part in esm.get_race_body_parts(race_form_id, is_female):
		body_part_paths.append(String(part["model"]))
	if not body_part_paths.is_empty():
		mesh_resolver.populate_humanoid_skeleton(self, skeleton_path, body_part_paths)

## Standalone preview entry point (see this file's own doc comment). Opens
## FalloutNV.esm directly, resolves the configured base_form_id via
## esm.get_actor_by_form_id() (no cell/placement context needed), and calls
## the exact same populate() real placements use.
func _editor_load() -> void:
	# Clear any previously built children before rebuilding -- same
	# "immediate free, not queue_free" convention nif_viewer.gd uses (avoids
	# a same-name collision on reload, see that file's own doc comment).
	for child in get_children():
		remove_child(child)
		child.free()

	var esm := EsmReader.new()
	var data_dir := String(GameDataConfigScript.resolve().get("data_dir", ""))
	if not esm.open(data_dir + GameDataConfigScript.ESM_FILE):
		push_error("NPCNode: could not open FalloutNV.esm")
		return

	var form_id: int = PRESET_FORM_IDS.get(preset, 0)
	if preset == "Custom":
		form_id = custom_base_form_id.hex_to_int()
	if form_id == 0:
		push_error("NPCNode: no base_form_id -- set custom_base_form_id (preset is Custom)")
		return

	var placement: Dictionary = esm.get_actor_by_form_id(form_id)
	if placement.is_empty():
		push_error("NPCNode: base_form_id 0x%X not found (or not an NPC_)" % form_id)
		return

	var resolver := GamebryoMeshResolver.new(data_dir)
	populate(placement, esm, resolver)

	if Engine.is_editor_hint():
		for child in get_children():
			_own_recursive(child)

	print("NPCNode: loaded ", placement.get("editor_id", "?"), " (0x%X)" % form_id)

func _own_recursive(node: Node) -> void:
	node.owner = get_tree().edited_scene_root
	for c in node.get_children():
		_own_recursive(c)
