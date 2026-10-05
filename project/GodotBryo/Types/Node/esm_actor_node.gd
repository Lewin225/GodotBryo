@tool
class_name EsmActorNode
extends EsmNode

## The one node that renders an actor (NPC or creature): its MODL skeleton and
## the model parts its base lists, assembled under Body. Children of the
## template scene do the specialised work: ActorSkinning binds skinned parts,
## ActorAnimator loads and plays animation, ActorEquipment attaches what is
## equipped. It has no Player, NPC-controller, WorldStreamer or legacy-resolver
## dependency; a controller owns gameplay, this node only its visual tree.

signal visual_load_completed()
signal visual_load_failed(reason: String)
signal animation_load_completed(clip_count: int)
signal animation_load_failed(reason: String)

@export_enum("Custom", "Doc Mitchell (Goodsprings)") var preset: String = "Doc Mitchell (Goodsprings)"
@export var custom_base_form_id: String = ""
@export var wearing_hat: bool = false:
	set(value):
		wearing_hat = value
		_apply_hair_variant()

@export var show_gore: bool = false:
	set(value):
		show_gore = value
		_apply_gore_visibility()

## Ragdolls are served by NifServer,  but aren't ready to use yet. disable them for now
@export var ragdoll_simulator_enabled: bool = false:
	set(value):
		ragdoll_simulator_enabled = value
		_apply_ragdoll_simulator_state()

@export var possessed_first_person: bool = false:
	set(value):
		possessed_first_person = value
		_apply_possessed_first_person_render_mode()


@export_tool_button("Import Actor Data From Preset Or FormID") var load_button: Callable = _editor_load
@export_tool_button("Load Actor") var apply_data_button: Callable = _editor_apply_actor_data
@export_tool_button("Unload Actor") var unload_button: Callable = unload_actor
@export_tool_button("Refresh Equipment") var refresh_equipment_button: Callable = _editor_refresh_equipment

const PRESET_FORM_IDS := {"Doc Mitchell (Goodsprings)": 0x00104C0C,}
const BODY_NODE_NAME := "Body"
const STAGING_NODE_NAME := "HumanoidStaging"
const LOOK_TARGET_NODE_NAME := "Look Target"
const LOOK_TARGET_BONE_NAME := "Bip01 Head"


# This is a placeholder for hiding gore, not the real implementation
const SECTION_CAP_FIRST := 101 # Found from NifSkope & Geck
const SECTION_CAP_LAST := 113
const TORSO_CAP_FIRST := 201
const TORSO_CAP_LAST := 213

## How the controller that owns this actor is moving it (PlayerController,
## NpcController). Assigned once by the controller, which updates it in place;
## ActorAnimator reads it to choose clips. Null without a controller: the actor
## idles.
var motion: ActorMotion = null

var _active_record: ActorBase = null

## Whether the actor being shown uses female body parts and animations.
func is_female() -> bool:
	return _is_female
var _is_female := false

var _standalone_preview := false
var _load_generation := 0
var _loading := false
var _load_requested := false
var _humanoid_visual_built := false
var _rehydrate_queued := false
var _rehydrating_reference := false
var _pending_requests := 0
var _requested_assets := {}
var _delivered_trees := {}
var _load_failures: Array[String] = []
var _staging_root: Node3D = null
var hair_no_hat_meshes: Array[MeshInstance3D] = []
var hair_hat_meshes: Array[MeshInstance3D] = []
# Every emitted BSDismember partition is indexed by its raw part ID. This
# contains nude body and current equipment alike; selection of caps is a
# separate debug-visual policy below, not a NifServer concern.
var _dismember_meshes_by_part_id := {}

## The child that binds skinned parts to the skeleton. Looked up on each
## access: the template's children exist from instantiation, before _ready(),
## and reference changes reach this node before it enters the tree.
var skinning: ActorSkinning:
	get:
		return get_node_or_null(^"ActorSkinning") as ActorSkinning
## The child that loads, binds and plays the actor's animation (looked up as
## skinning is).
var animator: ActorAnimator:
	get:
		return get_node_or_null(^"ActorAnimator") as ActorAnimator
## The child that builds and attaches the equipped items' models (looked up as
## skinning is).
var equipment: ActorEquipment:
	get:
		return get_node_or_null(^"ActorEquipment") as ActorEquipment



func _ready() -> void:
	animator.load_completed.connect(animation_load_completed.emit)
	animator.load_failed.connect(animation_load_failed.emit)
	equipment.committed.connect(_on_equipment_committed)
	equipment.watch(reference as ActorReference)
	_queue_rehydrate_and_build()


func _exit_tree() -> void:
	_cancel_visual_load()
	animator.cancel()


## Humanoids request several authored NIFs, rather than the one generic model
## handled by EsmNode. Each request remains full-detail and hierarchical.
func _should_request_nif() -> bool:
	return false


func _reference_changed() -> void:
	_cancel_visual_load()
	if equipment != null:
		equipment.forget_body()
	if animator != null:
		animator.cancel()
	_active_record = null
	if not _rehydrating_reference:
		_load_requested = false
	_humanoid_visual_built = false
	_queue_rehydrate_and_build()


func _queue_rehydrate_and_build() -> void:
	if not is_inside_tree() or _rehydrate_queued:
		return
	_rehydrate_queued = true
	call_deferred("_rehydrate_and_build")


func _rehydrate_and_build() -> void:
	_rehydrate_queued = false
	if not is_inside_tree() or reference == null:
		return
	var server := get_tree().root.get_node_or_null("EsmServer")
	if reference.base == null and server != null:
		if not server.is_ready():
			if not _waiting_for_esm:
				_waiting_for_esm = true
				server.esm_ready.connect(_on_esm_ready, CONNECT_ONE_SHOT)
			return
		var hydrated: EsmReference = server.get_reference(reference.instance_id) if not reference.instance_id.is_empty() else null
		if hydrated == null and reference.base_form_id != 0:
			hydrated = server.create_reference_for_base(reference.base_form_id)
		if hydrated != null:
			_rehydrating_reference = true
			reference = hydrated
			_rehydrating_reference = false
			return

	if reference.base == null:
		push_warning("EsmActorNode: reference has no base record")
		return
	if _loading or _humanoid_visual_built:
		return
	equipment.watch(reference as ActorReference)
	if _load_requested:
		_start_visual_load(reference.base)


## The explicit near-residency entry point. Rehydration/importing only makes
## typed data available; it never starts model work by itself.
func load_actor() -> void:
	_load_requested = true
	if not is_inside_tree():
		return
	if reference == null:
		return
	if reference.base is ActorBase:
		if not _loading and not _humanoid_visual_built:
			_start_visual_load(reference.base as ActorBase)
		return
	_queue_rehydrate_and_build()


func _start_visual_load(reference_base: ActorBase) -> void:
	_cancel_visual_load()
	_load_generation += 1
	_loading = true
	equipment.forget_body()
	_active_record = reference_base
	_is_female = reference_base.is_female()
	_requested_assets = _requested_asset_set(reference_base)
	_delivered_trees.clear()
	_load_failures.clear()
	# The staging root is used to hold nodes before they become visible
	_staging_root = Node3D.new()
	_staging_root.name = STAGING_NODE_NAME
	_staging_root.visible = false
	add_child(_staging_root)
	if Engine.is_editor_hint() and owner != null: _own_recursive(_staging_root)
	
	var nif_server := get_tree().root.get_node_or_null("NifServer")
	if nif_server == null:
		_finish_visual_load(false, "NifServer autoload is unavailable")
		return
	var generation := _load_generation
	for asset_key in _requested_assets:
		var asset: Dictionary = _requested_assets[asset_key]
		_pending_requests += 1
		# NifServer owns parsing, cache sharing, coordinate conversion and pacing.
		# Humanoid parts must never request flattened/static or paired LOD trees.
		nif_server.request(String(asset.path), self, _on_nif_delivered.bind(generation, String(asset_key)), false)


## The NIFs this actor is assembled from: its MODL skeleton and the parts its
## base lists (ActorBase.get_model_parts).
func _requested_asset_set(record: ActorBase) -> Dictionary:
	var assets := {}
	_add_requested_asset(assets, "skeleton", record.model_path, true, "skeleton")
	for part in record.get_model_parts(_is_female):
		var extra := part.duplicate()
		for key in ["key", "path", "required", "kind"]:
			extra.erase(key)
		_add_requested_asset(assets, String(part.key), String(part.path), bool(part.required), String(part.kind), extra)
	return assets


func _add_requested_asset(assets: Dictionary, key: String, path: String, required: bool, kind: String, extra := {}) -> void:
	if path.strip_edges().is_empty():
		if required:
			assets[key] = {"path": "", "required": true, "kind": kind}
		return
	var asset := {"path": path, "required": required, "kind": kind}
	for extra_key in extra:
		asset[extra_key] = extra[extra_key]
	assets[key] = asset


func _on_nif_delivered(tree: Node3D, generation: int, asset_key: String) -> void:
	if generation != _load_generation or not _loading or not is_instance_valid(_staging_root):
		if tree != null:
			tree.free()
		return
	var asset: Dictionary = _requested_assets.get(asset_key, {})
	if tree == null:
		var message := "%s NIF could not be loaded: %s" % [String(asset.get("kind", asset_key)), String(asset.get("path", ""))]
		if bool(asset.get("required", false)):
			_load_failures.append(message)
		else:
			push_warning("EsmActorNode: optional " + message)
	else:
		tree.name = "Nif_%s" % asset_key.validate_node_name()
		tree.set_meta("esm_humanoid_asset_key", asset_key)
		tree.set_meta("esm_humanoid_asset_kind", String(asset.get("kind", "")))
		_staging_root.add_child(tree)
		_delivered_trees[asset_key] = tree
	_pending_requests -= 1
	if _pending_requests == 0:
		_complete_nif_requests(generation)


func _complete_nif_requests(generation: int) -> void:
	if generation != _load_generation or not _loading:
		return
	if not _load_failures.is_empty():
		_finish_visual_load(false, "; ".join(_load_failures))
		return
	_assemble_staged_body(generation)


## Skeleton and body-part trees each retain NifServer's one root conversion as
## siblings below Body. They must not be nested beneath one another: doing so
## would compose the R_x(-90) conversion twice.
func _assemble_staged_body(generation: int) -> void:
	if generation != _load_generation or _staging_root == null: return

	var skeleton_tree := _delivered_trees.get("skeleton") as Node3D
	if skeleton_tree == null:
		_finish_visual_load(false, "NifServer delivered no skeleton tree")
		return
	var skeleton := skeleton_tree.find_child("Skeleton3D", true, false) as Skeleton3D
	if skeleton == null:
		_finish_visual_load(false, "skeleton NIF contains no Skeleton3D")
		return

	# Construct a root node
	var body := Node3D.new()
	body.name = BODY_NODE_NAME
	body.visible = false
	_staging_root.add_child(body)

	#Attach the returned skeleton to the body node, 99% it's _male/skeleton.nif
	_move_tree(skeleton_tree, body, "SkeletonModel")

	#Attach a look at node to the skeleton head and configure it
	_ensure_humanoid_look_target(skeleton)

	# Nude body stores the meshes used when no armour is equipped, but it's actually a vest and shorts
	# This is allways built, and just left as not visible
	var nude_body := Node3D.new()
	nude_body.name = "NudeBody"
	body.add_child(nude_body)
	for asset_key in _requested_assets:
		var asset: Dictionary = _requested_assets[asset_key]
		if String(asset.get("kind", "")) != "body":
			continue
		var part_tree := _delivered_trees.get(asset_key) as Node3D
		if part_tree == null:
			_finish_visual_load(false, "required body tree is missing: " + String(asset.get("path", "")))
			return
		_move_tree(part_tree, nude_body, "BodyPart_%s" % String(asset_key).validate_node_name())
		skinning.compact_external_skin_part(part_tree)
		if not skinning.bind_external_skins(part_tree, skeleton):
			_finish_visual_load(false, "body tree has unresolved skeleton binds: " + String(asset.get("path", "")))
			return
		_tag_nude_body_meshes(part_tree, asset)

	# Attach the head and setup it's face/eyes/teeth/hair
	var appearance := Node3D.new()
	appearance.name = "AppearanceStaging"
	appearance.visible = false
	body.add_child(appearance)
	_assemble_staged_appearance(body, skeleton, appearance)
	_commit_staged_body(body, generation)
	# The base body is now constructed
	# Whoo

func _move_tree(tree: Node3D, new_parent: Node, node_name: String) -> void:
	## Utily func for new_parent.add_child(tree.get_parent.remove_child(tree))
	if tree.get_parent() != null:
		tree.get_parent().remove_child(tree)
	tree.name = node_name
	new_parent.add_child(tree)


## Human skeletons receive one shared look at modifier 3D.
## TODO - This should really be part of the base scene somehow rather than code configured
func _ensure_humanoid_look_target(skeleton: Skeleton3D) -> void:
	if skeleton == null or skeleton.get_node_or_null(NodePath(LOOK_TARGET_NODE_NAME)) != null:
		return
	if skeleton.find_bone(LOOK_TARGET_BONE_NAME) == -1:
		push_warning("EsmActorNode: human skeleton has no %s bone for look target" % LOOK_TARGET_BONE_NAME)
		return
	var look_target := LookAtModifier3D.new()
	look_target.name = LOOK_TARGET_NODE_NAME
	look_target.position = Vector3(0.04669869, 1.0496129, 1.6604441)
	look_target.target_node = NodePath(".")
	look_target.bone_name = LOOK_TARGET_BONE_NAME
	look_target.duration = 1.0
	look_target.transition_type = Tween.TRANS_SINE
	look_target.ease_type = Tween.EASE_IN_OUT
	look_target.forward_axis = SkeletonModifier3D.BONE_AXIS_PLUS_Y
	look_target.primary_rotation_axis = Vector3.AXIS_X
	# The X value here nudges their eyeline down
	# If it's too high they'll stare at your balls ( Feature? )
	look_target.origin_offset = Vector3(0.15, 0.0, 0.0)
	look_target.origin_safe_margin = 10.0
	look_target.use_angle_limitation = true
	look_target.symmetry_limitation = true
	look_target.primary_limit_angle = 110.0
	look_target.secondary_limit_angle = 80.0
	skeleton.add_child(look_target)


func _tag_nude_body_meshes(root: Node3D, asset: Dictionary) -> void:
	for child in root.find_children("*", "MeshInstance3D", true, false):
		child.set_meta("gamebryo_nude_body", true)
		child.set_meta("gamebryo_nude_body_original_visible", child.visible)
		child.set_meta("gamebryo_race_body_part_index", int(asset.get("race_part_index", -1)))
		child.set_meta("gamebryo_model_path", String(asset.get("path", "")))


## Unskinned Fallout head assets are authored in facial-bone space. The shared
## skeleton tree already carries NifServer's root conversion, so only the
## delivered NifRoot is reset before it is nested under the bone attachment.
## Skinned heads remain sibling model roots, exactly like the nude body parts.
func _assemble_staged_appearance(body: Node3D, skeleton: Skeleton3D, staging: Node3D) -> void:
	var skinned_parts := Node3D.new()
	skinned_parts.name = "SkinnedHeadParts"
	body.add_child(skinned_parts)
	var facial_attachment: BoneAttachment3D = null
	for asset_key in _requested_assets:
		var asset: Dictionary = _requested_assets[asset_key]
		var kind := String(asset.get("kind", ""))
		if kind == "skeleton" or kind == "body":
			continue
		var tree := _delivered_trees.get(asset_key) as Node3D
		if tree == null:
			continue
		if skinning.tree_has_skin(tree):
			# MeshInstance3D.skeleton is a relative NodePath. Reparent before
			# deriving it so it remains valid after this appearance tree leaves
			# HumanoidStaging (the body-part path already follows this order).
			_move_tree(tree, skinned_parts, "Skinned_%s" % String(asset_key).validate_node_name())
			skinning.compact_external_skin_part(tree)
			if not skinning.bind_external_skins(tree, skeleton):
				push_warning("EsmActorNode: optional appearance has unresolved skeleton binds: " + String(asset.get("path", "")))
				tree.queue_free()
				continue
			_tag_appearance_meshes(tree, asset)
			continue
		if facial_attachment == null:
			facial_attachment = _create_facial_attachment(skeleton)
		if facial_attachment == null:
			push_warning("EsmActorNode: optional appearance has no usable facial bone: " + String(asset.get("path", "")))
			tree.queue_free()
			continue
		_move_tree(tree, facial_attachment, "Attached_%s" % String(asset_key).validate_node_name())
		tree.transform = Transform3D.IDENTITY
		if kind == "hair":
			# Standalone HAIR meshes carry the same outer coordinate-system
			# marker as their NIF nodes. They are already in HeadAnims space,
			# so retaining that marker rotates them a second time. This matches
			# the established legacy humanoid assembly policy.
			_reset_hair_mesh_transforms(tree)
		_tag_appearance_meshes(tree, asset)
	if skinned_parts.get_child_count() == 0:
		skinned_parts.queue_free()
	staging.queue_free()


func _create_facial_attachment(skeleton: Skeleton3D) -> BoneAttachment3D:
	var bone_name := "HeadAnims" if skeleton.find_bone("HeadAnims") != -1 else "Bip01 Head"
	var bone_index := skeleton.find_bone(bone_name)
	if bone_index == -1:
		return null
	var attachment := BoneAttachment3D.new()
	attachment.name = "FacialHeadAssembly"
	attachment.bone_name = bone_name
	skeleton.add_child(attachment)
	return attachment


func _reset_hair_mesh_transforms(root: Node3D) -> void:
	for child in root.find_children("*", "MeshInstance3D", true, false):
		(child as MeshInstance3D).transform = Transform3D.IDENTITY


func _tag_appearance_meshes(root: Node3D, asset: Dictionary) -> void:
	var part_type := String(asset.get("part_type", asset.get("kind", "")))
	for child in root.find_children("*", "MeshInstance3D", true, false):
		child.set_meta("gamebryo_model_path", String(asset.get("path", "")))
		child.set_meta("gamebryo_head_part_type", part_type)
		if part_type == "hair":
			var authored_name := String(child.get_meta("nif_name", "")).to_lower()
			if authored_name.contains("nohat") or authored_name.contains("no hat"):
				child.set_meta("gamebryo_hair_variant", "no_hat")
			elif authored_name.contains("hat"):
				child.set_meta("gamebryo_hair_variant", "hat")


func _track_hair_meshes(body: Node) -> void:
	hair_no_hat_meshes.clear()
	hair_hat_meshes.clear()
	if body == null:
		return
	for child in body.find_children("*", "MeshInstance3D", true, false):
		if String(child.get_meta("gamebryo_head_part_type", "")) != "hair":
			continue
		match String(child.get_meta("gamebryo_hair_variant", "")):
			"no_hat": hair_no_hat_meshes.append(child)
			"hat": hair_hat_meshes.append(child)
	_apply_hair_variant()


func _rebuild_dismember_partition_index(body: Node) -> void:
	_dismember_meshes_by_part_id.clear()
	if body == null:
		return
	for child in body.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		if not mesh.has_meta("nif_dismember_part_id"):
			continue
		var part_id := int(mesh.get_meta("nif_dismember_part_id"))
		var meshes: Array = _dismember_meshes_by_part_id.get(part_id, [])
		meshes.append(mesh)
		_dismember_meshes_by_part_id[part_id] = meshes
	_apply_gore_visibility()


func _is_gore_cap_part_id(part_id: int) -> bool:
	return (part_id >= SECTION_CAP_FIRST and part_id <= SECTION_CAP_LAST) \
			or (part_id >= TORSO_CAP_FIRST and part_id <= TORSO_CAP_LAST)


func _is_gore_cap_mesh(mesh: MeshInstance3D) -> bool:
	return mesh.has_meta("nif_dismember_part_id") \
			and _is_gore_cap_part_id(int(mesh.get_meta("nif_dismember_part_id")))


func _commit_staged_body(body: Node3D, generation: int) -> void:
	if generation != _load_generation or not _loading:
		body.queue_free()
		return
	var old_body := get_node_or_null(NodePath(BODY_NODE_NAME))
	if old_body != null:
		remove_child(old_body)
	body.get_parent().remove_child(body)
	body.visible = true
	add_child(body)
	if Engine.is_editor_hint() and get_tree().edited_scene_root != null:
		_own_recursive(body)
	if old_body != null:
		old_body.queue_free()
	_humanoid_visual_built = true
	_loading = false
	_clear_staging()
	_track_hair_meshes(body)
	_rebuild_dismember_partition_index(body)
	_apply_ragdoll_simulator_state()
	_apply_possessed_first_person_render_mode()
	var skeleton := body.find_child("Skeleton3D", true, false) as Skeleton3D
	equipment.set_body(body, skeleton, _is_female)
	animator.load_locomotion(_active_record.animation_search_paths(), body, skeleton)
	visual_load_completed.emit()


func _finish_visual_load(success: bool, reason: String) -> void:
	_loading = false
	if not success:
		_clear_staging()
		push_warning("EsmActorNode: visual load failed: " + reason)
		visual_load_failed.emit(reason)


func _cancel_visual_load() -> void:
	_load_generation += 1
	_loading = false
	_pending_requests = 0
	_requested_assets.clear()
	_delivered_trees.clear()
	_load_failures.clear()
	_clear_staging()


func _clear_staging() -> void:
	if _staging_root != null and is_instance_valid(_staging_root):
		_staging_root.queue_free()
	_staging_root = null


func _apply_equipment_body_coverage(body: Node3D) -> void:
	var occupied := 0
	for child in body.find_children("*", "MeshInstance3D", true, false):
		# Body and clothing caps can also carry nude-body metadata. They remain
		# exclusively governed by show_gore, never ordinary coverage restoration.
		if _is_gore_cap_mesh(child as MeshInstance3D):
			continue
		if bool(child.get_meta("gamebryo_nude_body", false)):
			child.visible = bool(child.get_meta("gamebryo_nude_body_original_visible", true))
		if bool(child.get_meta("gamebryo_equipment", false)):
			occupied |= int(child.get_meta("gamebryo_equipment_biped_flags", 0))
	for child in body.find_children("*", "MeshInstance3D", true, false):
		if not bool(child.get_meta("gamebryo_nude_body", false)):
			continue
		var path := String(child.get_meta("gamebryo_model_path", "")).to_lower().replace("/", "\\")
		var coverage := 0
		if path.contains("upperbody") or path.contains("torso"):
			coverage = 0x4
		elif path.contains("lefthand"):
			coverage = 0x8
		elif path.contains("righthand"):
			coverage = 0x10
		elif path.contains("head"):
			coverage = 0x1
		if coverage != 0 and (occupied & coverage) != 0:
			child.visible = false


func _apply_hair_variant() -> void:
	for mesh in hair_no_hat_meshes:
		if is_instance_valid(mesh):
			mesh.visible = not wearing_hat
	for mesh in hair_hat_meshes:
		if is_instance_valid(mesh):
			mesh.visible = wearing_hat


func _apply_gore_visibility() -> void:
	for part_id in _dismember_meshes_by_part_id:
		if not _is_gore_cap_part_id(int(part_id)):
			continue
		for mesh in _dismember_meshes_by_part_id[part_id]:
			if is_instance_valid(mesh):
				mesh.visible = show_gore


func _apply_ragdoll_simulator_state() -> void:
	for child in find_children("*", "PhysicalBoneSimulator3D", true, false):
		var simulator := child as PhysicalBoneSimulator3D
		simulator.active = ragdoll_simulator_enabled
		simulator.visible = ragdoll_simulator_enabled


func _apply_possessed_first_person_render_mode() -> void:
	for child in find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		if not mesh.has_meta("esm_actor_original_cast_shadow"):
			mesh.set_meta("esm_actor_original_cast_shadow", mesh.cast_shadow)
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY if possessed_first_person else int(mesh.get_meta("esm_actor_original_cast_shadow"))


func _editor_load() -> void:
	_standalone_preview = true
	var form_id: int = PRESET_FORM_IDS.get(preset, 0)
	if preset == "Custom":
		form_id = custom_base_form_id.hex_to_int()
	var server := get_tree().root.get_node_or_null("EsmServer") if is_inside_tree() else null
	if server == null or not server.is_ready():
		push_warning("EsmActorNode: EsmServer is not ready")
		return
	var candidate: EsmReference = server.create_reference_for_base(form_id)
	if candidate == null or not candidate is ActorReference:
		push_error("EsmActorNode: base_form_id 0x%X is not an NPC_ or CREA" % form_id)
		return
	reference = candidate


func _editor_apply_actor_data() -> void:
	if reference == null or not reference.base is ActorBase:
		push_warning("EsmActorNode: assign an ActorReference before loading")
		return
	load_actor()


## Drops the actor: cancels loading, frees its body, equipment and clips and
## clears the reference. load_actor() builds it again once a reference is set.
func unload_actor() -> void:
	_cancel_visual_load()
	equipment.clear()
	animator.cancel()
	_active_record = null
	_is_female = false
	hair_no_hat_meshes.clear()
	hair_hat_meshes.clear()
	_dismember_meshes_by_part_id.clear()
	var body := get_node_or_null(NodePath(BODY_NODE_NAME))
	if body != null:
		body.queue_free()
	reference = null
	equipment.equipment_state = null
	_standalone_preview = false
	_load_requested = false
	_humanoid_visual_built = false


func _editor_refresh_equipment() -> void:
	equipment.refresh()

## New equipment is attached: the dismember index, nude-body coverage and the
## first-person shadow mode cover it too.
func _on_equipment_committed(body: Node3D) -> void:
	# Clothing carries its own SECTIONCAP_/TORSOCAP_ meshes. Re-index after
	# every replacement before restoring ordinary body coverage.
	_rebuild_dismember_partition_index(body)
	_apply_equipment_body_coverage(body)
	_apply_possessed_first_person_render_mode()


func _own_recursive(node: Node) -> void:
	node.owner = get_tree().edited_scene_root
	for child in node.get_children():
		_own_recursive(child)
