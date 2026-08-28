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

## Real movement locomotion .kf files -- confirmed against the actual
## Meshes/Update BSAs (native/tools/find_kf_animations.cpp): a bare .kf
## carries exactly one top-level NiControllerSequence
## with NO owning NiControllerManager (see nif_loader.cpp's own
## extract_sequence() doc comment for why that needed a native fix), meant
## to be applied against a skeleton loaded from elsewhere -- unlike a
## self-contained NIF's own embedded animation (populate_skeleton()'s
## _populate_skeleton_animation_player()). "mt" = the base/unarmed
## locomotion set (every weapon-type-specific set -- 1hm/1hp/2ha/... --
## lives alongside it under the same folder for later work). mtidle has no
## gender-specific variant (shared, confirmed real); forward/backward/left/
## right do (separate male/female subfolders, same convention as RACE's own
## gendered body parts).
const LOCOMOTION_CLIPS_MALE := {
	"idle": "characters\\_male\\locomotion\\mtidle.kf",
	"forward": "characters\\_male\\locomotion\\male\\mtforward.kf",
	"backward": "characters\\_male\\locomotion\\male\\mtbackward.kf",
	"left": "characters\\_male\\locomotion\\male\\mtleft.kf",
	"right": "characters\\_male\\locomotion\\male\\mtright.kf",
}
const LOCOMOTION_CLIPS_FEMALE := {
	"idle": "characters\\_male\\locomotion\\mtidle.kf",
	"forward": "characters\\_male\\locomotion\\female\\mtforward.kf",
	"backward": "characters\\_male\\locomotion\\female\\mtbackward.kf",
	"left": "characters\\_male\\locomotion\\female\\mtleft.kf",
	"right": "characters\\_male\\locomotion\\female\\mtright.kf",
}

## Below this magnitude, set_move_input() plays "idle" rather than trying to
## pick a direction from near-zero noise.
const MOVE_INPUT_DEADZONE := 0.15

var _locomotion_player: AnimationPlayer = null
var _current_locomotion_clip := ""

## Real NPC_ construction — the full humanoid assembly confirmed real in
## issue #52 chunks 2/4. `placement["model"]` is the NPC_'s own MODL (the
## shared skeleton path, e.g. Characters\_Male\Skeleton.NIF — see
## EsmFile::get_cell_actors()'s doc comment, NOT a self-contained mesh);
## `placement["race_form_id"]`/`["is_female"]` resolve the real
## gender-selected body-part list via esm.get_race_body_parts() — RACE's
## own ESM-declared INDX blocks, not a guessed convention. Deliberately no
## head/face mesh (FaceGen is out of scope for this issue).
##
## Also wires a real LocomotionAnimationPlayer (see
## populate_locomotion_animations() in mesh_resolver.gd) from the gender-
## appropriate LOCOMOTION_CLIPS_* set — see set_move_input() for driving
## it. Animation only: this does NOT move the actor through the world (no
## CharacterBody3D — see GamebryoActor's own doc comment for why that's
## deferred); a caller wanting real translation drives that separately and
## feeds the same direction into set_move_input().
func populate(placement: Dictionary, esm: EsmReader, mesh_resolver: GamebryoMeshResolver) -> void:
	var skeleton_path: String = placement.get("model", "")
	var race_form_id := int(placement.get("race_form_id", 0))
	if skeleton_path == "" or race_form_id == 0:
		return
	var is_female := bool(placement.get("is_female", false))
	var body_part_paths: Array = []
	for part in esm.get_race_body_parts(race_form_id, is_female):
		body_part_paths.append(String(part["model"]))
	if body_part_paths.is_empty():
		return

	var skeleton := mesh_resolver.populate_humanoid_skeleton(self, skeleton_path, body_part_paths)
	if skeleton == null:
		return

	var clips: Dictionary = LOCOMOTION_CLIPS_FEMALE if is_female else LOCOMOTION_CLIPS_MALE
	_locomotion_player = mesh_resolver.populate_locomotion_animations(self, skeleton, clips)
	_current_locomotion_clip = ""
	set_move_input(Vector2.ZERO) # starts idle

## Pre-blendspace movement driving (issue #52 follow-up): picks the single
## closest of the 4 real cardinal locomotion clips (or "idle" inside the
## deadzone) and switches the LocomotionAnimationPlayer to it -- no
## blending between clips yet, just discrete selection. `input`: same
## convention as this project's own Input.get_vector(left, right, forward,
## backward) (see player_controller.gd) -- x: positive = right/strafe
## right, negative = left; y: NEGATIVE = forward, positive = backward
## (Godot's own get_vector() convention, not an arbitrary choice here). A
## no-op if populate() never built a real LocomotionAnimationPlayer (e.g.
## none of the gender's clips resolved on this install).
func set_move_input(input: Vector2) -> void:
	if _locomotion_player == null:
		return
	var clip := _locomotion_clip_for_input(input)
	if clip == _current_locomotion_clip:
		return
	if not _locomotion_player.has_animation(clip):
		return # a real, possible gap -- not every clip in LOCOMOTION_CLIPS_* is guaranteed to have resolved (see populate_locomotion_animations()'s own doc comment)
	_current_locomotion_clip = clip
	_locomotion_player.play(clip)

func _locomotion_clip_for_input(input: Vector2) -> String:
	if input.length() < MOVE_INPUT_DEADZONE:
		return "idle"
	if absf(input.y) >= absf(input.x):
		return "backward" if input.y > 0.0 else "forward"
	return "right" if input.x > 0.0 else "left"

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
