@tool
class_name CreatureNode
extends GamebryoActor

const GameDataConfigScript := preload("res://game_data_config.gd")

## Issue #52 chunk 5 (+ later): thin leaf for a placed CREA. No fields of
## its own yet (same "genuinely thin leaf" shape as NPCNode).
##
## `creature_node.tscn` (this script's own scene) is the hand-authored
## template GamebryoObjectRegistry._build_creature() instantiates — see
## NPCNode's own doc comment for why a real scene exists here at all
## instead of pure-code construction.
##
## populate() is inherited as a no-op from GamebryoActor and deliberately
## NOT overridden here — a real, confirmed gap, not an oversight: CREA.MODL
## only ever points at a bone-only Skeleton.nif (confirmed real against
## creatures\NVRaven\Skeleton.nif: 0 skin entries, same shape as the human
## skeleton.nif), and the real body mesh (creatures\NVRaven\nvraven.nif,
## confirmed to carry real skin data whose bone names resolve against that
## skeleton) is only discoverable by a same-folder file-naming CONVENTION —
## unlike RACE's own explicit ESM-declared INDX-tagged part list for NPC_.
## Wiring automatic resolution here would mean guessing a per-creature
## filename rule from a single confirmed sample rather than a real ESM
## structure; left as a follow-up once that convention (or a better one) is
## confirmed across more than one real creature.
##
## Still a standalone @tool preview like NPCNode, though there's nothing to
## build yet -- "Load Actor" resolves and prints the real CREA identity so
## this is ready to extend once creature body-mesh resolution is solved.

@export_enum("Custom", "Goodsprings Raven (CREA)") var preset: String = "Goodsprings Raven (CREA)"

## Only read when preset == "Custom". Hex CREA FormID, e.g. "0x00140DB0".
@export var custom_base_form_id: String = ""

@export_tool_button("Load Actor") var load_button: Callable = _editor_load

const PRESET_FORM_IDS := {
	"Goodsprings Raven (CREA)": 0x00140DB0,
}

func _editor_load() -> void:
	for child in get_children():
		remove_child(child)
		child.free()

	var esm := EsmReader.new()
	var data_dir := String(GameDataConfigScript.resolve().get("data_dir", ""))
	if not esm.open(data_dir + GameDataConfigScript.ESM_FILE):
		push_error("CreatureNode: could not open FalloutNV.esm")
		return

	var form_id: int = PRESET_FORM_IDS.get(preset, 0)
	if preset == "Custom":
		form_id = custom_base_form_id.hex_to_int()
	if form_id == 0:
		push_error("CreatureNode: no base_form_id -- set custom_base_form_id (preset is Custom)")
		return

	var placement: Dictionary = esm.get_actor_by_form_id(form_id)
	if placement.is_empty():
		push_error("CreatureNode: base_form_id 0x%X not found (or not a CREA)" % form_id)
		return

	var resolver := GamebryoMeshResolver.new(data_dir)
	populate(placement, esm, resolver) # inherited no-op -- see this file's own doc comment

	print("CreatureNode: loaded %s (0x%X) -- model=%s (no auto mesh wiring yet, see this file's own doc comment)" %
			[placement.get("editor_id", "?"), form_id, placement.get("model", "")])
