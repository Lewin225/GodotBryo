@tool
class_name EsmHumanoidActor
extends EsmNode

## Reusable, typed visual assembly for a humanoid reference. It has no Player,
## NPC-controller, WorldStreamer or legacy-resolver dependency. A controller
## owns gameplay and VWD policy; this node owns only its generated visual tree.

signal visual_load_completed()
signal visual_load_failed(reason: String)
signal animation_load_completed(clip_count: int)
signal animation_load_failed(reason: String)

@export_enum("Custom", "Doc Mitchell (Goodsprings)") var preset: String = "Doc Mitchell (Goodsprings)"
@export var custom_base_form_id: String = ""
@export var equipment_state: EsmActorEquipmentState:
	set(value):
		_disconnect_equipment_state_signals()
		equipment_state = value
		_connect_equipment_state_signals()
		if _active_record != null and not _rebuilding:
			refresh_equipment()

@export var wearing_hat: bool = false:
	set(value):
		wearing_hat = value
		_apply_hair_variant()

@export var show_gore: bool = false:
	set(value):
		show_gore = value
		_apply_gore_visibility()

## Ragdolls are authored in the skeleton NIF, but an inert humanoid should not
## expose their debug bodies or activate their simulator. This remains an
## explicit inspector opt-in until an NPC controller owns ragdoll state.
@export var ragdoll_simulator_enabled: bool = false:
	set(value):
		ragdoll_simulator_enabled = value
		_apply_ragdoll_simulator_state()

@export var possessed_first_person: bool = false:
	set(value):
		possessed_first_person = value
		_apply_possessed_first_person_render_mode()

## Opt-in construction/animation timing for streamed-actor investigation.
## The authored EsmHumanoidActor base scene keeps this off for normal runtime
## instances; enable that scene flag when collecting a focused trace.
@export var construction_profiling_enabled: bool = false

@export_tool_button("Import Actor Data From Preset Or FormID") var load_button: Callable = _editor_load
@export_tool_button("Load Actor") var apply_data_button: Callable = _editor_apply_actor_data
@export_tool_button("Unload Actor") var unload_button: Callable = _editor_unload_actor
@export_tool_button("Refresh Equipment") var refresh_equipment_button: Callable = _editor_refresh_equipment

const PRESET_FORM_IDS := {
	"Doc Mitchell (Goodsprings)": 0x00104C0C,
}
const BODY_NODE_NAME := "Body"
const STAGING_NODE_NAME := "HumanoidStaging"
const LOOK_TARGET_NODE_NAME := "Look Target"
const LOOK_TARGET_BONE_NAME := "Bip01 Head"
const LOCOMOTION_SUBDIRECTORY := "locomotion/"
const ANIMATION_CLIPS_PER_FRAME := 4
const NifNamesScript := preload("res://GodotBryo/Servers/NifServer/nif_names.gd")
# BSDismemberBodyPartType: NifSkope's FNV enum defines 101–113 as
# BP_SECTIONCAP_* and 201–213 as BP_TORSOCAP_*. GECK confirms these are the
# gore partitions shown on dismemberment. NifServer preserves raw IDs only;
# this visual policy belongs to the humanoid assembly.
const SECTION_CAP_FIRST := 101
const SECTION_CAP_LAST := 113
const TORSO_CAP_FIRST := 201
const TORSO_CAP_LAST := 213

var _active_record: NpcBase = null
var _is_female := false
var _rebuilding := false
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
var _construction_profile_started_usec := 0
var _construction_profile_last_usec := 0
var _animation_load_generation := 0
var _animation_loading := false
var _animation_root_path := ""
var _animation_pending_requests := 0
var _animation_requests_being_submitted := false
var _animation_binding_scheduled := false
var _pending_animation_libraries: Array[Dictionary] = []
var _locomotion_animation_player: AnimationPlayer = null
var _equipment_generation := 0
var _equipment_loading := false
var _equipment_pending := 0
var _equipment_desired_signature := ""
var _equipment_applied_signature := ""
var _equipment_descriptors: Array[Dictionary] = []
var _equipment_trees := {}
var _equipment_failures: Array[String] = []
var _equipment_staging: Node3D = null
var _observed_equipment_resources: Array[Resource] = []
var inventory: Inventory = null
var _observed_inventory: Inventory = null
var hair_no_hat_meshes: Array[MeshInstance3D] = []
var hair_hat_meshes: Array[MeshInstance3D] = []
# Every emitted BSDismember partition is indexed by its raw part ID. This
# contains nude body and current equipment alike; selection of caps is a
# separate debug-visual policy below, not a NifServer concern.
var _dismember_meshes_by_part_id := {}



func _ready() -> void:
	_connect_equipment_state_signals()
	_ensure_inventory()
	_connect_inventory_signal()
	_queue_rehydrate_and_build()


func _exit_tree() -> void:
	_cancel_visual_load()
	_cancel_equipment_refresh()
	_cancel_animation_load()
	_disconnect_inventory_signal()
	_disconnect_equipment_state_signals()


## Humanoids request several authored NIFs, rather than the one generic model
## handled by EsmNode. Each request remains full-detail and hierarchical.
func _should_request_nif() -> bool:
	return false


func _reference_changed() -> void:
	_cancel_visual_load()
	_cancel_equipment_refresh()
	_cancel_animation_load()
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
	var record := reference.base as NpcBase
	if record == null:
		push_warning("EsmHumanoidActor: reference is not backed by an NPC_ record")
		return
	if _loading or _humanoid_visual_built:
		return
	_ensure_inventory()
	_connect_inventory_signal()
	_project_equipment_from_inventory()
	if _load_requested:
		_start_visual_load(record)


## The explicit near-residency entry point. Rehydration/importing only makes
## typed data available; it never starts model work by itself.
func load_actor() -> void:
	_load_requested = true
	if not is_inside_tree():
		return
	if reference == null:
		return
	if reference.base is NpcBase:
		if not _loading and not _humanoid_visual_built:
			_start_visual_load(reference.base as NpcBase)
		return
	_queue_rehydrate_and_build()


func _start_visual_load(record: NpcBase) -> void:
	_begin_construction_profile(record)
	if record.race == null:
		_finish_visual_load(false, "NPC record has no race")
		return
	_cancel_visual_load()
	_load_generation += 1
	_loading = true
	_rebuilding = true
	_active_record = record
	_is_female = record.is_female
	_requested_assets = _requested_asset_set(record)
	_delivered_trees.clear()
	_load_failures.clear()
	_staging_root = Node3D.new()
	_staging_root.name = STAGING_NODE_NAME
	_staging_root.visible = false
	add_child(_staging_root)
	if Engine.is_editor_hint() and owner != null:
		_own_recursive(_staging_root)
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
	_construction_profile("NIF requests queued (%d assets)" % _pending_requests)


func _begin_construction_profile(record: NpcBase) -> void:
	if not construction_profiling_enabled:
		return
	_construction_profile_started_usec = Time.get_ticks_usec()
	_construction_profile_last_usec = _construction_profile_started_usec
	var label := record.editor_id if record != null else "<unknown NPC>"
	_construction_profile("load requested for " + label)


func _construction_profile(stage: String) -> void:
	if not construction_profiling_enabled or _construction_profile_started_usec == 0:
		return
	var now := Time.get_ticks_usec()
	var total_ms := float(now - _construction_profile_started_usec) / 1000.0
	var delta_ms := float(now - _construction_profile_last_usec) / 1000.0
	_construction_profile_last_usec = now
	print("EsmHumanoidActor construction [%s frame=%d total=%.2fms delta=%.2fms] %s" % [
		name, Engine.get_process_frames(), total_ms, delta_ms, stage,
	])


func _animation_profile(stage: String) -> void:
	if not construction_profiling_enabled or _construction_profile_started_usec == 0:
		return
	var total_ms := float(Time.get_ticks_usec() - _construction_profile_started_usec) / 1000.0
	print("EsmHumanoidActor animation [%s frame=%d total=%.2fms] %s" % [
		name, Engine.get_process_frames(), total_ms, stage,
	])


## The source of truth is NpcBase/ActorReference. This only records the exact
## NIF requests required to assemble that typed reference; it is not a second
## immutable actor-description layer.
func _requested_asset_set(record: NpcBase) -> Dictionary:
	var assets := {}
	_add_requested_asset(assets, "skeleton", record.model_path, true, "skeleton")
	for part in record.race.body_parts(record.is_female):
		_add_requested_asset(assets, "body:%d" % int(part.index), part.model_path, true, "body", {
			"race_part_index": int(part.index),
		})
	for part in record.race.head_parts(record.is_female):
		_add_requested_asset(assets, "head:%d" % int(part.index), part.model_path, false, "head", {
			"part_type": String(part.part_type),
		})
	if record.hair != null:
		_add_requested_asset(assets, "hair", record.hair.model_path, false, "hair")
	if record.eyes != null:
		_add_requested_asset(assets, "eyes", record.eyes.model_path, false, "eyes")
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
			push_warning("EsmHumanoidActor: optional " + message)
	else:
		tree.name = "Nif_%s" % asset_key.validate_node_name()
		tree.set_meta("esm_humanoid_asset_key", asset_key)
		tree.set_meta("esm_humanoid_asset_kind", String(asset.get("kind", "")))
		_staging_root.add_child(tree)
		_delivered_trees[asset_key] = tree
	_pending_requests -= 1
	_construction_profile("NIF delivered: %s (pending=%d)" % [asset_key, _pending_requests])
	if _pending_requests == 0:
		_complete_nif_requests(generation)


func _complete_nif_requests(generation: int) -> void:
	if generation != _load_generation or not _loading:
		return
	if not _load_failures.is_empty():
		_finish_visual_load(false, "; ".join(_load_failures))
		return
	_construction_profile("all NIFs delivered; beginning main-thread assembly")
	_assemble_staged_body(generation)


## Skeleton and body-part trees each retain NifServer's one root conversion as
## siblings below Body. They must not be nested beneath one another: doing so
## would compose the R_x(-90) conversion twice.
func _assemble_staged_body(generation: int) -> void:
	if generation != _load_generation or _staging_root == null: return
	_construction_profile("assembly begin")

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
	_construction_profile("skeleton attached and configured")

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
		_construction_profile("body part begin: " + String(asset_key))
		_move_tree(part_tree, nude_body, "BodyPart_%s" % String(asset_key).validate_node_name())
		_compact_external_skin_part(part_tree)
		if not _bind_external_skins(part_tree, skeleton):
			_finish_visual_load(false, "body tree has unresolved skeleton binds: " + String(asset.get("path", "")))
			return
		_tag_nude_body_meshes(part_tree, asset)
		_construction_profile("body part complete: " + String(asset_key))

	# Attach the head and setup it's face/eyes/teeth/hair
	var appearance := Node3D.new()
	appearance.name = "AppearanceStaging"
	appearance.visible = false
	body.add_child(appearance)
	_construction_profile("appearance assembly begin")
	_assemble_staged_appearance(body, skeleton, appearance)
	_construction_profile("appearance assembly complete")
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
		push_warning("EsmHumanoidActor: human skeleton has no %s bone for look target" % LOOK_TARGET_BONE_NAME)
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


# Gamebyro does not have the concept of skeletons in the way that godot and other engines do
# Gamebyro animations are simply targeted against NiNodes(Node3D) and skinned meshes target NiNodes
# like you would target a bone. NifServer detects possible skeletons and does the conversion for us
# but it's honest return policy also returns the original NiNodes that the skleton was built from which
# have no function for us, so this goes through the nodes and collapses the unneeded ones
func _compact_external_skin_part(root: Node3D) -> void:
	if root == null or not _tree_has_skin(root):
		return
	var leaves: Array[Dictionary] = []
	var stack: Array[Dictionary] = [{"node": root, "transform": Transform3D.IDENTITY}]
	while not stack.is_empty():
		var entry: Dictionary = stack.pop_back()
		var node := entry["node"] as Node
		var accumulated: Transform3D = entry["transform"]
		for child in node.get_children():
			var child_transform := accumulated
			if child is Node3D:
				child_transform = accumulated * (child as Node3D).transform
			stack.append({"node": child, "transform": child_transform})
		if node != root and node is MeshInstance3D:
			leaves.append({"mesh": node, "transform": accumulated})
	if leaves.is_empty():
		return

	# Detach every leaf before freeing the source nodes. Do not use global
	# transforms here: NifRoot's R_x(-90) conversion remains on the wrapper and
	# must not be composed into a child a second time.
	for leaf in leaves:
		var mesh := leaf["mesh"] as MeshInstance3D
		mesh.get_parent().remove_child(mesh)
	for child in root.get_children():
		child.free()
	for leaf in leaves:
		var mesh := leaf["mesh"] as MeshInstance3D
		root.add_child(mesh)
		mesh.transform = leaf["transform"]
	root.set_meta("esm_humanoid_external_skin_compacted", true)
	root.set_meta("esm_humanoid_external_skin_mesh_count", leaves.size())


## NifServer supplies named Skin binds for flat external skins but deliberately
## leaves MeshInstance3D.skeleton empty. The shared humanoid skeleton resolves
## those names here without altering any bind pose.
func _bind_external_skins(root: Node3D, skeleton: Skeleton3D) -> bool:
	var found_skin := false
	for child in root.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		if mesh.skin == null or mesh.skin.get_bind_count() == 0:
			continue
		found_skin = true
		for bind_index in mesh.skin.get_bind_count():
			if skeleton.find_bone(String(mesh.skin.get_bind_name(bind_index))) == -1:
				return false
		mesh.skeleton = mesh.get_path_to(skeleton)
		# A partitioned BSDismember shape keeps the old MeshInstance3D's
		# authored local transform on its Node3D source container. External
		# skins are still positioned solely by their bind poses, so reset that
		# exact replacement for the old mesh-local transform too.
		var partition_source := mesh.get_parent() as Node3D
		if mesh.has_meta("nif_dismember_source_shape") and partition_source != null \
				and not bool(root.get_meta("esm_humanoid_external_skin_compacted", false)):
			partition_source.transform = Transform3D.IDENTITY
		# External body/equipment skins are positioned solely by their bind poses
		# against the shared skeleton. Retaining this NIF node's local transform
		# would compose it a second time; the legacy humanoid path uses identity
		# here for the same Skin/Skeleton3D contract.
		mesh.transform = Transform3D.IDENTITY
	return found_skin


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
		if _tree_has_skin(tree):
			# MeshInstance3D.skeleton is a relative NodePath. Reparent before
			# deriving it so it remains valid after this appearance tree leaves
			# HumanoidStaging (the body-part path already follows this order).
			_move_tree(tree, skinned_parts, "Skinned_%s" % String(asset_key).validate_node_name())
			_compact_external_skin_part(tree)
			if not _bind_external_skins(tree, skeleton):
				push_warning("EsmHumanoidActor: optional appearance has unresolved skeleton binds: " + String(asset.get("path", "")))
				tree.queue_free()
				continue
			_tag_appearance_meshes(tree, asset)
			continue
		if facial_attachment == null:
			facial_attachment = _create_facial_attachment(skeleton)
		if facial_attachment == null:
			push_warning("EsmHumanoidActor: optional appearance has no usable facial bone: " + String(asset.get("path", "")))
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


func _tree_has_skin(root: Node3D) -> bool:
	for child in root.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		if mesh.skin != null and mesh.skin.get_bind_count() > 0:
			return true
	return false


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
	_construction_profile("commit begin")
	var old_body := get_node_or_null(NodePath(BODY_NODE_NAME))
	if old_body != null:
		remove_child(old_body)
	body.get_parent().remove_child(body)
	body.visible = true
	add_child(body)
	_construction_profile("committed body hierarchy")
	if Engine.is_editor_hint() and get_tree().edited_scene_root != null:
		_own_recursive(body)
	_construction_profile("editor ownership complete")
	if old_body != null:
		old_body.queue_free()
	_humanoid_visual_built = true
	_loading = false
	_rebuilding = false
	_clear_staging()
	_track_hair_meshes(body)
	_rebuild_dismember_partition_index(body)
	_apply_ragdoll_simulator_state()
	_apply_possessed_first_person_render_mode()
	_construction_profile("post-assembly visual policies complete")
	_equipment_applied_signature = ""
	refresh_equipment()
	_construction_profile("equipment refresh requested")
	_start_default_animation_load(_active_record, body, body.find_child("Skeleton3D", true, false) as Skeleton3D)
	_construction_profile("locomotion load requested")
	visual_load_completed.emit()
	_construction_profile("visual load complete")


func _finish_visual_load(success: bool, reason: String) -> void:
	_loading = false
	_rebuilding = false
	if not success:
		_clear_staging()
		push_warning("EsmHumanoidActor: visual load failed: " + reason)
		visual_load_failed.emit(reason)


func _cancel_visual_load() -> void:
	_load_generation += 1
	_loading = false
	_rebuilding = false
	_pending_requests = 0
	_requested_assets.clear()
	_delivered_trees.clear()
	_load_failures.clear()
	_clear_staging()


## The skeleton NIF supplies the rig but no default humanoid KF list. NpcBase
## owns the verified search root. NifServer owns KF extraction and its shared
## cross-run cache; this actor only binds raw authored targets to this specific
## composed rig. The eventual NPC/player controller decides which loaded
## clip/group to play.
func _start_default_animation_load(record: NpcBase, body: Node3D, skeleton: Skeleton3D) -> void:
	_cancel_animation_load()
	if record == null or body == null or skeleton == null or not is_inside_tree():
		return
	# The actor owns a stable playback endpoint as soon as its body exists.
	# NifServer resolves the external KFs asynchronously, so delaying this node
	# until those callbacks complete made a loaded actor look as if it had no
	# animation support at all.
	_ensure_locomotion_animation_player(body)
	var archive := get_tree().root.get_node_or_null("ArchiveServer")
	if archive == null or not archive.is_ready():
		animation_load_failed.emit("ArchiveServer is unavailable")
		return
	var discovery_started_usec := Time.get_ticks_usec()
	var paths := PackedStringArray()
	for search_path in record.animation_search_paths():
		for path in archive.list_files_with_prefix(String(search_path) + LOCOMOTION_SUBDIRECTORY):
			var canonical := String(path).replace("\\", "/").to_lower()
			if canonical.ends_with(".kf") and not paths.has(canonical):
				paths.append(canonical)
	paths.sort()
	_animation_profile("locomotion discovery: %d KF paths in %.2fms" % [
		paths.size(), float(Time.get_ticks_usec() - discovery_started_usec) / 1000.0,
	])
	if paths.is_empty():
		animation_load_failed.emit("no locomotion KFs found below NpcBase animation search paths")
		return
	var nif_server := get_tree().root.get_node_or_null("NifServer")
	if nif_server == null:
		animation_load_failed.emit("NifServer autoload is unavailable")
		return
	_animation_load_generation += 1
	_animation_loading = true
	_animation_root_path = String(record.animation_search_paths()[0]).replace("\\", "/").to_lower()
	var generation := _animation_load_generation
	_animation_pending_requests = paths.size()
	_animation_requests_being_submitted = true
	for path in paths:
		# The callback is owner-bound, coalesced, worker-built and cached by
		# NifServer. This actor must not read or parse raw KF data itself.
		nif_server.request_kf(path, self, _on_kf_library_delivered.bind(generation, path))
	_animation_requests_being_submitted = false
	_animation_profile("NifServer KF requests queued (%d assets)" % _animation_pending_requests)
	_schedule_animation_binding()


func _on_kf_library_delivered(raw_library: AnimationLibrary, generation: int, source_path: String) -> void:
	if generation != _animation_load_generation or not _animation_loading:
		return
	_animation_pending_requests = maxi(0, _animation_pending_requests - 1)
	if raw_library == null:
		push_warning("EsmHumanoidActor: NifServer could not load locomotion KF " + source_path)
	else:
		_pending_animation_libraries.append({"path": source_path, "library": raw_library})
	if not _animation_requests_being_submitted:
		_schedule_animation_binding()


func _schedule_animation_binding() -> void:
	if not _animation_loading or _animation_requests_being_submitted or _animation_binding_scheduled:
		return
	if _pending_animation_libraries.is_empty():
		_finish_animation_load_if_ready()
		return
	_animation_binding_scheduled = true
	call_deferred("_process_pending_animation_libraries")


## NifServer does the expensive authored-key conversion in its worker. Binding
## copies only the resulting resource and changes its track paths for this
## actor's Skeleton3D. A real process-frame yield is deliberate: call_deferred
## alone drains recursive batches inside the same frame.
func _process_pending_animation_libraries() -> void:
	while _animation_loading and not _pending_animation_libraries.is_empty():
		var body := get_node_or_null(NodePath(BODY_NODE_NAME)) as Node3D
		var skeleton := body.find_child("Skeleton3D", true, false) as Skeleton3D if body != null else null
		if body == null or skeleton == null:
			_cancel_animation_load()
			return
		var player := _ensure_locomotion_animation_player(body)
		var library := player.get_animation_library("")
		var batch_started_usec := Time.get_ticks_usec()
		var processed := 0
		while not _pending_animation_libraries.is_empty() and processed < ANIMATION_CLIPS_PER_FRAME:
			var entry: Dictionary = _pending_animation_libraries.pop_front()
			var raw_library := entry.get("library") as AnimationLibrary
			if raw_library != null:
				_bind_external_animation_library(library, String(entry.get("path", "")), raw_library, body, skeleton)
			processed += 1
		_animation_profile("locomotion bind batch: %d KF libraries, %.2fms (%d queued, %d pending)" % [
			processed, float(Time.get_ticks_usec() - batch_started_usec) / 1000.0,
			_pending_animation_libraries.size(), _animation_pending_requests,
		])
		if not _pending_animation_libraries.is_empty():
			await get_tree().process_frame
	_animation_binding_scheduled = false
	_finish_animation_load_if_ready()


func _finish_animation_load_if_ready() -> void:
	if not _animation_loading or _animation_pending_requests > 0 or not _pending_animation_libraries.is_empty():
		return
	_animation_loading = false
	var body := get_node_or_null(NodePath(BODY_NODE_NAME)) as Node3D
	var player := _ensure_locomotion_animation_player(body) if body != null else null
	var library := player.get_animation_library("") if player != null else null
	if library == null:
		animation_load_failed.emit("locomotion animation player was unavailable")
		return
	var idle_clip := _animation_clip_name(_animation_root_path + "locomotion/mtidle.kf", 0)
	if library.has_animation(idle_clip):
		var play_started_usec := Time.get_ticks_usec()
		player.play(idle_clip)
		_animation_profile("idle play requested: %s in %.2fms" % [
			idle_clip, float(Time.get_ticks_usec() - play_started_usec) / 1000.0,
		])
		_profile_idle_activation_next_frame(_animation_load_generation,
			Engine.get_process_frames(), play_started_usec)
	else:
		push_warning("EsmHumanoidActor: default idle clip was not loaded: " + idle_clip)
	animation_load_completed.emit(library.get_animation_list().size())


func _profile_idle_activation_next_frame(generation: int, requested_frame: int,
		requested_usec: int) -> void:
	await get_tree().process_frame
	if generation != _animation_load_generation:
		return
	_animation_profile("idle first process frame: %d -> %d, %.2fms since play, process delta=%.2fms" % [
		requested_frame, Engine.get_process_frames(),
		float(Time.get_ticks_usec() - requested_usec) / 1000.0,
		get_process_delta_time() * 1000.0,
	])


func _ensure_locomotion_animation_player(body: Node3D) -> AnimationPlayer:
	if _locomotion_animation_player != null and is_instance_valid(_locomotion_animation_player):
		return _locomotion_animation_player
	var player := AnimationPlayer.new()
	player.name = "LocomotionAnimationPlayer"
	# Track paths below are relative to Body, the same assembly root that owns
	# SkeletonModel and will later own equipment animation targets.
	player.root_node = NodePath("..")
	player.add_animation_library("", AnimationLibrary.new())
	body.add_child(player)
	if Engine.is_editor_hint() and get_tree().edited_scene_root != null:
		_own_recursive(player)
	_locomotion_animation_player = player
	return player


func _bind_external_animation_library(library: AnimationLibrary, source_path: String,
		raw_library: AnimationLibrary, body: Node3D, skeleton: Skeleton3D) -> void:
	var sequence_index := 0
	for raw_name in raw_library.get_animation_list():
		var raw_animation := raw_library.get_animation(raw_name)
		var animation := _bind_external_skeleton_animation(raw_animation, body, skeleton)
		if animation != null:
			var clip_name := _animation_clip_name(source_path, sequence_index)
			while library.has_animation(clip_name):
				clip_name += "_"
			animation.set_meta("nif_source_path", source_path)
			library.add_animation(clip_name, animation)
		sequence_index += 1


func _animation_clip_name(source_path: String, sequence_index: int) -> String:
	var relative := source_path.trim_prefix(_animation_root_path)
	if relative.is_empty():
		relative = source_path.get_file()
	var name := relative.replace("/", "__")
	return name if sequence_index == 0 else "%s__%d" % [name, sequence_index]


func _bind_external_skeleton_animation(raw_animation: Animation, body: Node3D,
		skeleton: Skeleton3D) -> Animation:
	if raw_animation == null:
		return null
	var animation := raw_animation.duplicate(true) as Animation
	var skeleton_path := body.get_path_to(skeleton)
	var tracks := 0
	for track_index in animation.get_track_count():
		var authored_target := String(animation.track_get_path(track_index))
		if skeleton.find_bone(authored_target) == -1:
			animation.track_set_enabled(track_index, false)
			continue
		# Root motion must later drive the controller, not deform the in-place
		# visual rig. The authored non-accumulation helper has the same role.
		if authored_target == "Bip01" or authored_target == NifNamesScript.escape("Bip01 NonAccum"):
			animation.track_set_enabled(track_index, false)
			continue
		animation.track_set_path(track_index, NodePath("%s:%s" % [skeleton_path, authored_target]))
		tracks += 1
	return animation if tracks > 0 else null


func _cancel_animation_load() -> void:
	_animation_load_generation += 1
	_animation_loading = false
	_animation_root_path = ""
	_animation_pending_requests = 0
	_animation_requests_being_submitted = false
	_animation_binding_scheduled = false
	_pending_animation_libraries.clear()
	if _locomotion_animation_player != null and is_instance_valid(_locomotion_animation_player):
		_locomotion_animation_player.queue_free()
	_locomotion_animation_player = null


func _clear_staging() -> void:
	if _staging_root != null and is_instance_valid(_staging_root):
		_staging_root.queue_free()
	_staging_root = null


func _ensure_inventory() -> Inventory:
	var actor_ref := reference as ActorReference
	if actor_ref == null:
		return null
	if actor_ref.contents == null:
		actor_ref.contents = Inventory.new()
	inventory = actor_ref.contents
	return inventory


func _connect_inventory_signal() -> void:
	if inventory == null or not is_instance_valid(inventory):
		return
	if not inventory.is_connected("inventory_changed", _on_inventory_changed):
		inventory.connect("inventory_changed", _on_inventory_changed)
	_observed_inventory = inventory


func _disconnect_inventory_signal() -> void:
	if _observed_inventory != null and is_instance_valid(_observed_inventory) and _observed_inventory.is_connected("inventory_changed", _on_inventory_changed):
		_observed_inventory.disconnect("inventory_changed", _on_inventory_changed)
	_observed_inventory = null


func _on_inventory_changed() -> void:
	_project_equipment_from_inventory()


func _project_equipment_from_inventory() -> void:
	if inventory == null or not is_instance_valid(inventory):
		return
	var projected := EsmActorEquipmentState.new()
	for item in inventory.get_equipped_items():
		var item_base := item.item_reference.base if item.item_reference != null else null
		if item_base is ArmorBase:
			projected.armor_items.append(item)
		elif item_base is WeaponBase:
			projected.weapon_item = item
		else:
			projected.diagnostics.append("Equipped item has no supported typed resource")
	equipment_state = projected


func _connect_equipment_state_signals() -> void:
	_disconnect_equipment_state_signals()
	if equipment_state == null:
		return
	var resources: Array[Resource] = [equipment_state]
	for item in equipment_state.armor_items:
		_add_equipment_resource(resources, item)
		if item != null:
			_add_equipment_resource(resources, item.item_reference)
			_add_equipment_resource(resources, item.item_reference.base as ArmorBase if item.item_reference != null else null)
	_add_equipment_resource(resources, equipment_state.weapon_item)
	for resource in resources:
		if resource != null and not resource.changed.is_connected(_on_equipment_resource_changed):
			resource.changed.connect(_on_equipment_resource_changed)
			_observed_equipment_resources.append(resource)


func _add_equipment_resource(resources: Array[Resource], resource: Resource) -> void:
	if resource != null and not resources.has(resource):
		resources.append(resource)


func _disconnect_equipment_state_signals() -> void:
	for resource in _observed_equipment_resources:
		if is_instance_valid(resource) and resource.changed.is_connected(_on_equipment_resource_changed):
			resource.changed.disconnect(_on_equipment_resource_changed)
	_observed_equipment_resources.clear()


func _on_equipment_resource_changed() -> void:
	_connect_equipment_state_signals()
	if _active_record != null and not _rebuilding:
		refresh_equipment()


func refresh_equipment() -> void:
	var body := get_node_or_null(NodePath(BODY_NODE_NAME)) as Node3D
	var skeleton := body.find_child("Skeleton3D", true, false) as Skeleton3D if body != null else null
	if body == null or skeleton == null:
		return
	var descriptors := _equipment_model_descriptors()
	var signature := _equipment_signature(descriptors)
	if signature == _equipment_applied_signature and not _equipment_loading:
		return
	if _equipment_loading and signature == _equipment_desired_signature:
		return
	_cancel_equipment_refresh()
	_equipment_desired_signature = signature
	_equipment_descriptors = descriptors
	if descriptors.is_empty():
		_commit_equipment(body, Node3D.new(), signature)
		return
	var nif_server := get_tree().root.get_node_or_null("NifServer") if is_inside_tree() else null
	if nif_server == null:
		push_warning("EsmHumanoidActor: NifServer autoload is unavailable for equipment refresh")
		return
	_equipment_generation += 1
	_equipment_loading = true
	_equipment_staging = Node3D.new()
	_equipment_staging.name = "EquipmentStaging"
	_equipment_staging.visible = false
	body.add_child(_equipment_staging)
	var generation := _equipment_generation
	for index in descriptors.size():
		_equipment_pending += 1
		var descriptor := descriptors[index]
		nif_server.request(String(descriptor.path), self, _on_equipment_nif_delivered.bind(generation, index), false)


func _equipment_model_descriptors() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var state := equipment_state
	if state == null:
		return result
	var occupied := 0
	var accepted: Array[ArmorBase] = []
	for index in range(state.get_armor_bases().size() - 1, -1, -1):
		var armor := state.get_armor_bases()[index]
		if armor == null:
			continue
		if armor.biped_flags != 0 and (armor.biped_flags & occupied) != 0:
			push_warning("EsmHumanoidActor: skipped overlapping armor %s (%08X)" % [armor.editor_id, armor.biped_flags])
			continue
		accepted.push_front(armor)
		occupied |= armor.biped_flags
	for armor in accepted:
		var direct := armor.female_biped_model if _is_female else armor.male_biped_model
		_add_equipment_descriptor(result, direct, armor, armor.biped_flags, "MOD3" if _is_female else "MODL", "armor")
		var model_list := armor.biped_model_list as BipedModelListBase
		if model_list != null:
			for addon in model_list.entries:
				if addon != null:
					var addon_path := addon.female_biped_model if _is_female else addon.male_biped_model
					_add_equipment_descriptor(result, addon_path, addon, addon.biped_flags, "MOD3" if _is_female else "MODL", "armor")
	var weapon := state.get_weapon_base()
	if weapon != null:
		var weapon_models := weapon.biped_model_list as BipedModelListBase
		if weapon_models != null:
			for addon in weapon_models.entries:
				if addon != null:
					var addon_path := addon.female_biped_model if _is_female else addon.male_biped_model
					_add_equipment_descriptor(result, addon_path, addon, addon.biped_flags, "BIPL", "weapon")
		if not result.any(func(item): return String(item.get("kind", "")) == "weapon"):
			_add_equipment_descriptor(result, weapon.model_path, weapon, 0, "MODL", "weapon")
	return result


func _add_equipment_descriptor(target: Array[Dictionary], path: String, source: EsmBase, biped_flags: int, field: String, kind: String) -> void:
	if path.strip_edges().is_empty() or source == null:
		return
	target.append({
		"path": path,
		"source_form_id": source.form_id,
		"biped_flags": biped_flags,
		"field": field,
		"kind": kind,
	})


func _equipment_signature(descriptors: Array[Dictionary]) -> String:
	var parts: Array[String] = []
	for descriptor in descriptors:
		parts.append("%08X:%X:%s:%s" % [int(descriptor.source_form_id), int(descriptor.biped_flags), String(descriptor.field), String(descriptor.path).to_lower()])
	return "|".join(parts)


func _on_equipment_nif_delivered(tree: Node3D, generation: int, index: int) -> void:
	if generation != _equipment_generation or not _equipment_loading or _equipment_staging == null or not is_instance_valid(_equipment_staging):
		if tree != null:
			tree.free()
		return
	var descriptor := _equipment_descriptors[index]
	if tree == null:
		_equipment_failures.append(String(descriptor.path))
	else:
		tree.name = "Equipment_%d" % index
		_equipment_staging.add_child(tree)
		_equipment_trees[index] = tree
	_equipment_pending -= 1
	if _equipment_pending == 0:
		_complete_equipment_refresh(generation)


func _complete_equipment_refresh(generation: int) -> void:
	if generation != _equipment_generation or not _equipment_loading:
		return
	if not _equipment_failures.is_empty():
		push_warning("EsmHumanoidActor: retained current equipment; replacement NIFs failed: " + ", ".join(_equipment_failures))
		_cancel_equipment_refresh()
		return
	var body := get_node_or_null(NodePath(BODY_NODE_NAME)) as Node3D
	var skeleton := body.find_child("Skeleton3D", true, false) as Skeleton3D if body != null else null
	if body == null or skeleton == null:
		_cancel_equipment_refresh()
		return
	var equipment := Node3D.new()
	equipment.name = "Equipment"
	# External BoneAttachment paths need a common ancestor with Skeleton3D.
	# Keep the replacement hidden but in the live staging subtree until commit.
	_equipment_staging.add_child(equipment)
	for index in _equipment_descriptors.size():
		var descriptor := _equipment_descriptors[index]
		var tree := _equipment_trees.get(index) as Node3D
		if tree == null:
			equipment.free()
			_cancel_equipment_refresh()
			return
		if _tree_has_skin(tree):
			_compact_external_skin_part(tree)
			if not _bind_external_skins(tree, skeleton):
				push_warning("EsmHumanoidActor: retained current equipment; unresolved skeleton binds: " + String(descriptor.path))
				equipment.free()
				_cancel_equipment_refresh()
				return
			_move_tree(tree, equipment, "Skinned_%d" % index)
		else:
			if not _attach_unskinned_equipment(tree, equipment, skeleton, descriptor, index):
				push_warning("EsmHumanoidActor: retained current equipment; no supported attachment: " + String(descriptor.path))
				equipment.free()
				_cancel_equipment_refresh()
				return
		_tag_equipment_meshes(tree, descriptor)
	_commit_equipment(body, equipment, _equipment_desired_signature)


func _attach_unskinned_equipment(tree: Node3D, equipment: Node3D, skeleton: Skeleton3D, descriptor: Dictionary, index: int) -> bool:
	var path := String(descriptor.path).to_lower().replace("/", "\\")
	var candidates: Array[String] = []
	if String(descriptor.kind) == "weapon":
		candidates = ["Weapon", "Bip01 R Hand", "Bip01 R Forearm", "Bip01 Spine"]
	elif path.contains("\\hair\\") or path.contains("\\head\\") or path.contains("shades") or path.contains("glasses") or path.contains("hat"):
		candidates = ["HeadAnims", "Bip01 Head"]
	else:
		return false
	var bone_name := ""
	for candidate in candidates:
		if skeleton.find_bone(candidate) != -1:
			bone_name = candidate
			break
	if bone_name.is_empty():
		return false
	var attachment := BoneAttachment3D.new()
	attachment.name = "EquipmentAttachment_%d" % index
	attachment.bone_name = bone_name
	equipment.add_child(attachment)
	attachment.use_external_skeleton = true
	attachment.external_skeleton = attachment.get_path_to(skeleton)
	attachment.bone_idx = skeleton.find_bone(bone_name)
	attachment.on_skeleton_update()
	_move_tree(tree, attachment, "Attached_%d" % index)
	tree.transform = Transform3D.IDENTITY
	return true


func _tag_equipment_meshes(root: Node3D, descriptor: Dictionary) -> void:
	for child in root.find_children("*", "MeshInstance3D", true, false):
		child.set_meta("gamebryo_equipment", true)
		child.set_meta("gamebryo_equipment_form_id", int(descriptor.source_form_id))
		child.set_meta("gamebryo_equipment_biped_flags", int(descriptor.biped_flags))
		child.set_meta("gamebryo_equipment_model_field", String(descriptor.field))
		child.set_meta("gamebryo_model_path", String(descriptor.path))


func _commit_equipment(body: Node3D, equipment: Node3D, signature: String) -> void:
	var old_equipment := body.get_node_or_null(^"Equipment")
	if old_equipment != null:
		body.remove_child(old_equipment)
	if equipment.get_parent() != null:
		equipment.get_parent().remove_child(equipment)
	equipment.name = "Equipment"
	body.add_child(equipment)
	if Engine.is_editor_hint() and get_tree().edited_scene_root != null:
		_own_recursive(equipment)
	if old_equipment != null:
		old_equipment.queue_free()
	_equipment_applied_signature = signature
	_equipment_loading = false
	_equipment_pending = 0
	_equipment_trees.clear()
	_equipment_failures.clear()
	if _equipment_staging != null and is_instance_valid(_equipment_staging):
		_equipment_staging.queue_free()
	_equipment_staging = null
	# Clothing carries its own SECTIONCAP_/TORSOCAP_ meshes. Re-index after
	# every successful replacement before restoring ordinary body coverage.
	_rebuild_dismember_partition_index(body)
	_apply_equipment_body_coverage(body)
	_apply_possessed_first_person_render_mode()


func _cancel_equipment_refresh() -> void:
	_equipment_generation += 1
	_equipment_loading = false
	_equipment_pending = 0
	_equipment_descriptors.clear()
	_equipment_trees.clear()
	_equipment_failures.clear()
	if _equipment_staging != null and is_instance_valid(_equipment_staging):
		_equipment_staging.queue_free()
	_equipment_staging = null


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
		push_warning("EsmHumanoidActor: EsmServer is not ready")
		return
	var candidate: EsmReference = server.create_reference_for_base(form_id)
	if candidate == null or not candidate is ActorReference:
		push_error("EsmHumanoidActor: base_form_id 0x%X is not an NPC_" % form_id)
		return
	reference = candidate


func _editor_apply_actor_data() -> void:
	if reference == null or not reference.base is NpcBase:
		push_warning("EsmHumanoidActor: assign an ActorReference backed by NpcBase before loading")
		return
	load_actor()


func _editor_unload_actor() -> void:
	_cancel_visual_load()
	_cancel_equipment_refresh()
	_cancel_animation_load()
	_active_record = null
	_is_female = false
	hair_no_hat_meshes.clear()
	hair_hat_meshes.clear()
	_dismember_meshes_by_part_id.clear()
	_disconnect_inventory_signal()
	inventory = null
	var body := get_node_or_null(NodePath(BODY_NODE_NAME))
	if body != null:
		body.queue_free()
	reference = null
	equipment_state = null
	_standalone_preview = false
	_load_requested = false
	_humanoid_visual_built = false


func _editor_refresh_equipment() -> void:
	refresh_equipment()


func _own_recursive(node: Node) -> void:
	node.owner = get_tree().edited_scene_root
	for child in node.get_children():
		_own_recursive(child)
