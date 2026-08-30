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

## Real generic standing pose used to drive the upper body (spine/arms/
## head) regardless of what the legs are doing -- see
## populate_locomotion_tree()'s own doc comment in mesh_resolver.gd for why
## this needs to be a separate layer at all (real Bethesda convention: legs
## and upper body are separate animation layers, not one clip driving the
## whole skeleton). "mtidle.kf" is the only real generic full-body standing
## pose available without a weapon-equip system (real future work) to pick
## a per-weapon stance from instead.
const UPPER_BODY_POSE_CLIP := "mtidle.kf"
const UPPER_BODY_ROOT_BONE := "Bip01 Spine"

var _locomotion_tree: AnimationTree = null
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
## PLUS a real AnimationTree (populate_locomotion_tree()) layering the base
## "mt" cardinal-direction clips (legs) under a fixed upper-body pose
## (spine/arms/head) — see set_move_input() for driving it. Animation
## only: this does NOT move the actor through the world (no CharacterBody3D
## — see GamebryoActor's own doc comment for why that's deferred); a caller
## wanting real translation drives that separately and feeds the same
## direction into set_move_input().
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
	var player := mesh_resolver.populate_locomotion_animations(body, skeleton, clips)
	if player == null:
		return

	var gender_prefix := "female__" if _is_female else "male__"
	var cardinal_clips := {
		"forward": gender_prefix + "mtforward.kf",
		"backward": gender_prefix + "mtbackward.kf",
		"left": gender_prefix + "mtleft.kf",
		"right": gender_prefix + "mtright.kf",
	}
	_locomotion_tree = mesh_resolver.populate_locomotion_tree(body, skeleton, player, cardinal_clips, "mtidle.kf", UPPER_BODY_POSE_CLIP, UPPER_BODY_ROOT_BONE)
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

## Real blendspace movement driving (issue #52 follow-up, upgraded from an
## earlier discrete-clip-switching version once populate_locomotion_tree()
## landed): passes `input` through as the AnimationTree's own "Locomotion"
## blend_position parameter (see mesh_resolver.gd) for genuine continuous
## 2D blending between the 4 real cardinal clips -- no more snapping
## between whole clips. `input`: same convention as this project's own
## Input.get_vector(left, right, forward, backward) (see
## player_controller.gd) -- x: positive = right/strafe right, negative =
## left; y: NEGATIVE = forward, positive = backward (Godot's own
## get_vector() convention). The blend space's own points use ordinary
## Y-positive-is-forward axes (Vector2(0,1) = forward), so Y is flipped
## here to convert between the two conventions. Clamped to length 1 -- the
## blend space has no sample points past the 4 cardinal directions, so
## anything further would extrapolate rather than blend. A no-op if
## populate() never built a real AnimationTree (e.g. one of the required
## clips didn't resolve on this install — see
## populate_locomotion_tree()'s own doc comment).
func set_move_input(input: Vector2) -> void:
	if _locomotion_tree == null:
		return
	var blend_position := Vector2(input.x, -input.y)
	if blend_position.length() > 1.0:
		blend_position = blend_position.normalized()
	_locomotion_tree.set("parameters/Locomotion/blend_position", blend_position)

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

	# NIF/REFR data is Z-up; Godot is Y-up. In a REAL placement this
	# correction comes for free from the cell's own root node
	# (world_streamer.gd's "refr_root" -- see that file's own comment), the
	# same way every other placed type relies on it rather than rotating
	# itself. A standalone preview has no such ancestor, so it's applied
	# here on Body specifically -- same "no cell root to inherit it from"
	# reasoning nif_viewer.gd's own doc comment gives for rotating its own
	# NifRoot child, and the exact convention actor_viewer.gd's "ActorRoot"
	# wrapper already follows (this is what that scene gets right that a
	# bare npc_node.tscn preview didn't). Rotating Body specifically, not
	# `self`, keeps this purely a preview-only correction -- a real
	# placement's own populate() never applies it, so nothing here would
	# double-rotate once actors are wired into real cell loading.
	var body := get_node_or_null(NodePath(BODY_NODE_NAME))
	if body:
		body.rotation_degrees.x = -90

	if Engine.is_editor_hint():
		for child in get_children():
			_own_recursive(child)

	print("NPCNode: loaded ", placement.get("editor_id", "?"), " (0x%X)" % form_id)

func _own_recursive(node: Node) -> void:
	node.owner = get_tree().edited_scene_root
	for c in node.get_children():
		_own_recursive(c)
