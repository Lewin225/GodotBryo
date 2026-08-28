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
## else placed in the world.
##
## populate() builds ALL of its own generated content (skeleton, meshes,
## LocomotionAnimationPlayer) inside one dedicated child container, named
## BODY_NODE_NAME ("Body") — never directly under `self`. This is
## deliberate: populate()/_editor_load() need to freely clear and rebuild
## whatever they generated on a reload, but must NOT touch anything
## hand-authored directly in npc_node.tscn as a SIBLING of Body (e.g. a
## future AnimationTree wired to LocomotionAnimationPlayer via a NodePath,
## or armor/weapon attach markers) — a real problem hit in practice: an
## earlier version of this file cleared every child indiscriminately,
## which would destroy any such hand-authored node on every reload. A
## NodePath into Body (e.g. "Body/LocomotionAnimationPlayer") stays valid
## across rebuilds even though the actual AnimationPlayer instance gets
## destroyed and recreated each time, since NodePath resolution happens at
## the moment it's used, not once at authoring time — so hand-authored
## scaffolding CAN safely reference generated content by path, just not
## hold a direct node reference to it.
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

## Name of the dedicated child container populate() builds all of its own
## generated content into — see this file's own top doc comment.
const BODY_NODE_NAME := "Body"

## Real movement locomotion .kf files -- confirmed against the actual
## Meshes/Update BSAs (native/tools/find_kf_animations.cpp): a bare .kf
## carries exactly one top-level NiControllerSequence with NO owning
## NiControllerManager (see nif_loader.cpp's own extract_sequence() doc
## comment for why that needed a native fix), meant to be applied against a
## skeleton loaded from elsewhere -- unlike a self-contained NIF's own
## embedded animation (populate_skeleton()'s
## _populate_skeleton_animation_player()).
##
## Every real file under this folder is imported (via
## GamebryoMeshResolver.list_files_with_prefix()), not a hand-picked subset
## -- the full weapon-type-specific sets (1hm/1hp/2ha/2hh/2hl/2hr/h2h/1gt/
## ...) alongside the base "mt" unarmed set, plus their hurt/child/female/
## male subfolders, all real, all kept under their own real names (no
## remapping to invented aliases like "forward"/"backward" -- confirmed via
## review that Godot's AnimationLibrary rejects "/" in a name outright, so
## a file's real relative path becomes its clip name with "/" -> "__").
## set_move_input() below only targets the base "mt" cardinal-direction
## subset for now; everything else stays loaded and available (e.g. for a
## later equipped-weapon-driven animation-set switch) without being played
## automatically.
const LOCOMOTION_FOLDER_PREFIX := "meshes/characters/_male/locomotion/"

## Below this magnitude, set_move_input() plays the idle clip rather than
## trying to pick a direction from near-zero noise.
const MOVE_INPUT_DEADZONE := 0.15

var _locomotion_player: AnimationPlayer = null
var _current_locomotion_clip := ""
var _is_female := false

## Real NPC_ construction — the full humanoid assembly confirmed real in
## issue #52 chunks 2/4. `placement["model"]` is the NPC_'s own MODL (the
## shared skeleton path, e.g. Characters\_Male\Skeleton.NIF — see
## EsmFile::get_cell_actors()'s doc comment, NOT a self-contained mesh);
## `placement["race_form_id"]`/`["is_female"]` resolve the real
## gender-selected body-part list via esm.get_race_body_parts() — RACE's
## own ESM-declared INDX blocks, not a guessed convention. Deliberately no
## head/face mesh (FaceGen is out of scope for this issue).
##
## Also wires a real LocomotionAnimationPlayer holding EVERY real file
## found under LOCOMOTION_FOLDER_PREFIX (see _discover_locomotion_clips())
## — see set_move_input() for driving the base cardinal-direction subset of
## it. Animation only: this does NOT move the actor through the world (no
## CharacterBody3D — see GamebryoActor's own doc comment for why that's
## deferred); a caller wanting real translation drives that separately and
## feeds the same direction into set_move_input().
func populate(placement: Dictionary, esm: EsmReader, mesh_resolver: GamebryoMeshResolver) -> void:
	var skeleton_path: String = placement.get("model", "")
	var race_form_id := int(placement.get("race_form_id", 0))
	if skeleton_path == "" or race_form_id == 0:
		return
	_is_female = bool(placement.get("is_female", false))
	var body_part_paths: Array = []
	for part in esm.get_race_body_parts(race_form_id, _is_female):
		body_part_paths.append(String(part["model"]))
	if body_part_paths.is_empty():
		return

	var body := _rebuild_body_container()
	var skeleton := mesh_resolver.populate_humanoid_skeleton(body, skeleton_path, body_part_paths)
	if skeleton == null:
		return

	var clips := _discover_locomotion_clips(mesh_resolver)
	_locomotion_player = mesh_resolver.populate_locomotion_animations(body, skeleton, clips)
	_current_locomotion_clip = ""
	set_move_input(Vector2.ZERO) # starts idle

## Clears and recreates the Body container (see this file's own top doc
## comment) — the ONLY thing populate() ever destroys, leaving every
## sibling (hand-authored scaffolding saved directly in npc_node.tscn)
## untouched. Immediate free, not queue_free() -- same "avoids a same-name
## collision on reload" reasoning nif_viewer.gd's own doc comment gives for
## its identical pattern.
func _rebuild_body_container() -> Node3D:
	var existing := get_node_or_null(NodePath(BODY_NODE_NAME))
	if existing:
		remove_child(existing)
		existing.free()
	var body := Node3D.new()
	body.name = BODY_NODE_NAME
	add_child(body)
	return body

## Discovers every real .kf under LOCOMOTION_FOLDER_PREFIX (no hand-picked
## subset -- see this file's own doc comment on LOCOMOTION_FOLDER_PREFIX)
## and maps each to { real_relative_path_with_"__"_separators: load_path }.
## Same naming convention project/_diag/_diag_locomotion_review.gd uses
## (kept identical deliberately, so a clip name found there matches one
## found here exactly) -- "/" is stripped down to the LOCOMOTION_FOLDER_PREFIX's
## own subfolders (e.g. "male/mtforward.kf" -> "male__mtforward.kf";
## "mtidle.kf" at the shared top level stays "mtidle.kf" unprefixed).
func _discover_locomotion_clips(mesh_resolver: GamebryoMeshResolver) -> Dictionary:
	var clips := {}
	for entry in mesh_resolver.list_files_with_prefix(LOCOMOTION_FOLDER_PREFIX):
		var e := String(entry)
		if not e.ends_with(".kf"):
			continue
		var rel := e.trim_prefix(LOCOMOTION_FOLDER_PREFIX)
		var load_path := "characters\\_male\\locomotion\\" + rel.replace("/", "\\")
		clips[rel.replace("/", "__")] = load_path
	return clips

## Pre-blendspace movement driving (issue #52 follow-up): picks the single
## closest of the 4 real cardinal "mt" (base/unarmed) locomotion clips (or
## the shared idle clip inside the deadzone) and switches the
## LocomotionAnimationPlayer to it -- no blending between clips yet, just
## discrete selection, and no weapon-type-specific set (1hm/1hp/...) yet
## either, both real future work. `input`: same convention as this
## project's own Input.get_vector(left, right, forward, backward) (see
## player_controller.gd) -- x: positive = right/strafe right, negative =
## left; y: NEGATIVE = forward, positive = backward (Godot's own
## get_vector() convention, not an arbitrary choice here). A no-op if
## populate() never built a real LocomotionAnimationPlayer, or the specific
## clip this input maps to didn't resolve on this install.
func set_move_input(input: Vector2) -> void:
	if _locomotion_player == null:
		return
	var clip := _locomotion_clip_for_input(input)
	if clip == _current_locomotion_clip:
		return
	if not _locomotion_player.has_animation(clip):
		return # a real, possible gap -- not every discovered file is guaranteed to have resolved to real animation data (see populate_locomotion_animations()'s own doc comment)
	_current_locomotion_clip = clip
	_locomotion_player.play(clip)

func _locomotion_clip_for_input(input: Vector2) -> String:
	if input.length() < MOVE_INPUT_DEADZONE:
		return "mtidle.kf" # shared, no gender subfolder -- confirmed real
	var gender_prefix := "female__" if _is_female else "male__"
	if absf(input.y) >= absf(input.x):
		return gender_prefix + ("mtbackward.kf" if input.y > 0.0 else "mtforward.kf")
	return gender_prefix + ("mtright.kf" if input.x > 0.0 else "mtleft.kf")

## Standalone preview entry point (see this file's own doc comment). Opens
## FalloutNV.esm directly, resolves the configured base_form_id via
## esm.get_actor_by_form_id() (no cell/placement context needed), and calls
## the exact same populate() real placements use. Deliberately does NOT
## clear this node's children itself -- populate() -> _rebuild_body_
## container() already clears exactly the one container it owns, and
## clearing anything broader here would destroy hand-authored sibling
## scaffolding (see this file's own top doc comment).
func _editor_load() -> void:
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
