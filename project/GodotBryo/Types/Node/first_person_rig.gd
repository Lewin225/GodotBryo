@tool
class_name FirstPersonRig
extends Node3D

## The possessed actor's first-person body (Plans/Actors/first_person.md): the
## first-person skeleton, meshes/characters/_1stperson/skeleton.nif, wearing the
## actor's own skinned meshes, played by its own KfAnimator. A child of the
## player (player.tscn), placed there by hand; no camera is attached yet.
##
## first_person_rig.tscn holds the parts: SkeletonModel, where the skeleton
## NIF's tree goes once NifServer has built it (from the game data, so not
## saved in the scene); Meshes, the copies of the actor's meshes; KfAnimator,
## pointed at the skeleton once it is built; KfClipSync, which makes the
## KfAnimator play what the actor's KfAnimator is asked to play, each start's
## KF remapped to its first-person file (KfClipSync.path_remap), in the same
## slot and on the actor's clock, without Bip01 and Bip01 NonAccum (the player
## controller moves the body). A start with no first-person file leaves its
## slot empty. Following starts once both the skeleton and the actor's
## animation are loaded, and again whenever the actor's animation reloads.
##
## The player places the rig with the camera each frame (place_at_camera(),
## called by PlayerController straight after it sets the camera, so the two
## move in lockstep and the arms do not shake against the view): at the
## camera's position, head bob included, lowered by the camera's eye height
## above the body, turned by the camera's yaw, not its pitch. The rig's
## placement relative to its parent, as set in player.tscn, is kept on top.
## Like the camera it is top_level at runtime: as a plain child, the body's turn
## from mouse look, applied after the rig is placed, would swing it off the
## camera until the next frame.
##
## In the editor, "Preview" builds the skeleton and a preview actor
## (PREVIEW_REFERENCE, PREVIEW_OFFSET to the side) and wears its meshes, so the
## rig can be seen and placed in player.tscn; "Clear Preview" removes them.
## The preview's skeleton tree is owned by the edited scene so it shows in the
## Scene dock and its bones can be selected: clear the preview before saving,
## or the built skeleton is saved into the scene.
##
## follow() copies every skinned mesh under the actor's Body onto this
## skeleton once the actor is built and its equipment attached, and again when
## the equipment changes. A copy shares the mesh, Skin (binds by bone name, with
## their bind poses) and materials, keeps its source mesh's transform relative
## to the actor's skeleton (a skinned vertex is placed by the mesh node's own
## transform as well as the bones; the actor's part roots carry NifServer's
## Z-up conversion), shows whenever its source shows (so it follows the actor's
## equipment rules: the nude body hides under clothing), and casts no shadow.
## Left out: the skinned head parts, and any mesh bound only to head bones (a
## hat), as the first-person view has no head. Meshes that are not skinned
## (head parts and hair on bone attachments) are not copied. A mesh whose binds
## name a bone this skeleton lacks is not copied either (none of Doc Mitchell's
## 49 skinned meshes do; _diag/first_person_test).

const SKELETON_PATH := "meshes/characters/_1stperson/skeleton.nif"
## The first-person skeleton's camera bone, below Bip01 Looking.
const CAMERA_BONE := "Camera1st"
## The bone the first-person body hangs from at the eye. No first-person clip
## rotates it (native/tools/kf_bip01_looking_census: 4 of 442 KFs have a block
## on it, none with rotation keys); the rig's KfAnimator never writes it.
const LOOK_BONE := "Bip01 Looking"
## Bones the rig's KfAnimator never writes (KfAnimator.disabled_bones), so
## they keep their rest pose: LOOK_BONE, which the body hangs from at the eye.
## The spine is played (the arms are posed for its bend) and straightened
## afterwards by FirstPersonViewPitch.
@export var held_bones := PackedStringArray([LOOK_BONE]):
	set(value):
		held_bones = value
		if animator != null:
			animator.disabled_bones = held_bones
const ACTOR_SCENE := preload("res://GodotBryo/Types/Node/esm_actor_node.tscn")
## The editor preview's actor: a placed reference, whose inventory dresses it.
const PREVIEW_REFERENCE := "DocMitchellREF"
## Where the preview actor stands, beside the rig, metres.
const PREVIEW_OFFSET := Vector3(1.0, 0.0, 0.0)

@export_tool_button("Preview") var preview_button: Callable = _editor_preview
@export_tool_button("Clear Preview") var clear_preview_button: Callable = _editor_clear_preview
## The actor's Body child holding its skinned head parts, not copied.
const HEAD_PARTS_GROUP := "SkinnedHeadParts"
## Bind names whose bones count as the head (Bip01 Head, Bip01 Neck, and the
## facial bones below them).
const HEAD_BONE_WORDS := ["Head", "Neck"]

## The rig's skeleton once its NIF has been built, else null.
var skeleton: Skeleton3D = null
## The KfAnimator playing the first-person clips on `skeleton`.
@onready var animator: KfAnimator = $KfAnimator
## Makes `animator` follow the actor's KfAnimator.
@onready var clip_sync: KfClipSync = $KfClipSync
@onready var _skeleton_model: Node3D = $SkeletonModel
@onready var _meshes: Node3D = $Meshes
var _actor: EsmActorNode = null
var _preview_actor: EsmActorNode = null
var _skeleton_requested := false
## The modifier turning the arms and neck with the view's pitch.
var _view_pitch: FirstPersonViewPitch = null
## The rig's placement relative to its parent, as set in the scene.
var _placement := Transform3D.IDENTITY
## Each copy -> the actor mesh it shows with.
var _sources: Dictionary = {}


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_placement = transform
	top_level = true
	_request_skeleton()


## Places the rig with `camera`: at its position lowered by `eye_height` (how
## far the camera's eye sits above the body), turned by its yaw about the
## world's up axis, without pitch or roll, with the scene placement on top.
## The arms and neck turn by `pitch` (radians, up positive) about the eye,
## around the rig's right axis (FirstPersonViewPitch), so they follow the view
## up and down while the body below keeps its pose.
func place_at_camera(camera: Node3D, eye_height: float, pitch := 0.0) -> void:
	var origin := camera.global_position - Vector3(0.0, eye_height, 0.0)
	global_transform = Transform3D(Basis(Vector3.UP, camera.global_basis.get_euler().y), origin) * _placement
	if _view_pitch != null and is_instance_valid(_view_pitch) and skeleton != null:
		_view_pitch.pitch = pitch
		_view_pitch.axis = skeleton.global_basis.inverse() * global_basis.x


## CAMERA_BONE's change from where it rests under LOOK_BONE as it is posed, as
## a world-space transform: what the bone's clips do to the view, identity at
## rest or with no skeleton. The
## camera is moved by it (PlayerController), the rig is not.
func camera_offset() -> Transform3D:
	if skeleton == null or not is_instance_valid(skeleton):
		return Transform3D.IDENTITY
	var bone := skeleton.find_bone(CAMERA_BONE)
	if bone == -1:
		return Transform3D.IDENTITY
	var posed := skeleton.global_transform * skeleton.get_bone_global_pose(bone)
	var rest := skeleton.global_transform * skeleton.get_bone_global_rest(bone)
	var look := skeleton.find_bone(LOOK_BONE)
	if look != -1:
		# Camera1st at rest relative to LOOK_BONE, carried by LOOK_BONE's pose.
		var rest_under_look := skeleton.get_bone_global_rest(look).affine_inverse() * skeleton.get_bone_global_rest(bone)
		rest = skeleton.global_transform * skeleton.get_bone_global_pose(look) * rest_under_look
	return posed * rest.affine_inverse()


func _request_skeleton() -> void:
	if _skeleton_requested:
		return
	_skeleton_requested = true
	NifServer.request(SKELETON_PATH, self, _on_skeleton_delivered)


## Editor: builds the skeleton and a preview actor beside the rig, and wears it.
func _editor_preview() -> void:
	if not EsmServer.is_ready():
		push_warning("FirstPersonRig: EsmServer is not ready")
		return
	_request_skeleton()
	if _preview_actor == null or not is_instance_valid(_preview_actor):
		_preview_actor = ACTOR_SCENE.instantiate() as EsmActorNode
		_preview_actor.name = "PreviewActor"
		_preview_actor.position = PREVIEW_OFFSET
		_preview_actor.placed_by_parent = true
		_preview_actor.configure(EsmServer.find_reference_by_editor_id(PREVIEW_REFERENCE))
		add_child(_preview_actor)
		_preview_actor.load_actor()
	follow(_preview_actor)


## Editor: removes the preview actor, the skeleton and the worn meshes.
func _editor_clear_preview() -> void:
	follow(null)
	if _preview_actor != null and is_instance_valid(_preview_actor):
		_preview_actor.queue_free()
	_preview_actor = null
	for child in _skeleton_model.get_children():
		child.queue_free()
	skeleton = null
	_skeleton_requested = false
	if clip_sync != null:
		clip_sync.set_source(null)


## Wears `actor`'s meshes, now and whenever its visual or equipment changes.
func follow(actor: EsmActorNode) -> void:
	if _actor == actor:
		return
	_actor = actor
	if actor == null:
		_clear_meshes()
		_sync()
		return
	if not actor.visual_load_completed.is_connected(_refresh):
		actor.visual_load_completed.connect(_refresh)
	if not actor.equipment.committed.is_connected(_on_equipment_committed):
		actor.equipment.committed.connect(_on_equipment_committed)
	if not actor.animation_load_completed.is_connected(_on_animation_loaded):
		actor.animation_load_completed.connect(_on_animation_loaded)
	_refresh()
	_sync()


func _on_animation_loaded(_clip_count: int) -> void:
	_sync()


## Follows the actor's KfAnimator once the skeleton is built (the follower's
## clips bind to its bones); nothing without an actor or its animation.
func _sync() -> void:
	if clip_sync == null:
		return
	var source: KfAnimator = null
	if skeleton != null and _actor != null and is_instance_valid(_actor) and _actor.animator != null:
		source = _actor.animator.get_kf_animator()
	if source == clip_sync.get_source():
		return
	clip_sync.set_source(source)


func _on_skeleton_delivered(tree: Node3D) -> void:
	if tree == null:
		push_warning("FirstPersonRig: NifServer could not build " + SKELETON_PATH)
		return
	_skeleton_model.add_child(tree)
	skeleton = tree.find_child("Skeleton3D", true, false) as Skeleton3D
	if skeleton == null:
		# Returned as plain nodes, as EsmActorNode handles a skeleton NIF that
		# declares no bones.
		skeleton = ActorSkinning.new().build_skeleton_from_nodes(tree)
	if skeleton == null:
		push_warning("FirstPersonRig: %s has no Skeleton3D and no nodes" % SKELETON_PATH)
		return
	animator.skeleton_path = animator.get_path_to(skeleton)
	# Held bones are not played (a clip's block on LOOK_BONE: h2hstomp.kf's
	# translation, the unset static poses of issue #91).
	animator.disabled_bones = held_bones
	_view_pitch = FirstPersonViewPitch.new()
	_view_pitch.name = "ViewPitch"
	skeleton.add_child(_view_pitch)
	if Engine.is_editor_hint() and get_tree().edited_scene_root != null:
		_own_for_editor(tree, get_tree().edited_scene_root)
	_refresh()
	_sync()


## Owns `node` and everything under it by `scene_root`, so the editor's Scene
## dock lists them.
static func _own_for_editor(node: Node, scene_root: Node) -> void:
	node.owner = scene_root
	for child in node.get_children():
		_own_for_editor(child, scene_root)


func _on_equipment_committed(_body: Node3D) -> void:
	_refresh()


## Copies the actor's meshes when the actor is built, its equipment attached
## and the skeleton ready.
func _refresh() -> void:
	if skeleton == null or _actor == null or not _actor.is_visual_built() or _actor.equipment.is_loading():
		return
	var body := _actor.get_node_or_null(NodePath(EsmActorNode.BODY_NODE_NAME)) as Node3D
	if body == null:
		return
	var actor_skeleton := body.find_child("Skeleton3D", true, false) as Skeleton3D
	if actor_skeleton == null:
		return
	_clear_meshes()
	# Carries a transform relative to the actor's skeleton onto this one.
	var carry := skeleton.global_transform * actor_skeleton.global_transform.affine_inverse()
	for node in body.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if _copies(mesh, body):
			_add_copy(mesh, carry)


## Whether `mesh` is worn by the rig: skinned, not a head part, not bound only
## to head bones, and every bind a bone of this skeleton.
func _copies(mesh: MeshInstance3D, body: Node3D) -> bool:
	if mesh.skin == null or mesh.skin.get_bind_count() == 0:
		return false
	if _part_of(mesh, body) == HEAD_PARTS_GROUP:
		return false
	var only_head := true
	for bind in mesh.skin.get_bind_count():
		var bone_name := String(mesh.skin.get_bind_name(bind))
		if skeleton.find_bone(bone_name) == -1:
			return false
		only_head = only_head and _is_head_bone(bone_name)
	return not only_head


static func _is_head_bone(bone_name: String) -> bool:
	for word: String in HEAD_BONE_WORDS:
		if bone_name.contains(word):
			return true
	return false


## The name of the child of `body` that `mesh` is under.
static func _part_of(mesh: Node, body: Node) -> String:
	var node := mesh
	while node.get_parent() != body and node.get_parent() != null:
		node = node.get_parent()
	return String(node.name)


func _add_copy(mesh: MeshInstance3D, carry: Transform3D) -> void:
	var copy := MeshInstance3D.new()
	copy.name = mesh.name
	copy.mesh = mesh.mesh
	copy.skin = mesh.skin
	copy.material_override = mesh.material_override
	for surface in mesh.get_surface_override_material_count():
		copy.set_surface_override_material(surface, mesh.get_surface_override_material(surface))
	copy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	copy.visible = mesh.is_visible_in_tree()
	_meshes.add_child(copy)
	copy.global_transform = carry * mesh.global_transform
	copy.skeleton = copy.get_path_to(skeleton)
	_sources[copy] = mesh


func _clear_meshes() -> void:
	_sources.clear()
	for child in _meshes.get_children():
		_meshes.remove_child(child)
		child.queue_free()


## Shows each copy whenever its source does, whatever hid it (the nude body under clothing, a hair variant; the first-person
## shadow mode on the actor counts as shown).
func _process(_delta: float) -> void:
	for copy: MeshInstance3D in _sources:
		var source: MeshInstance3D = _sources[copy]
		if not is_instance_valid(source):
			continue
		var shown := source.visible and _ancestors_shown(source)
		if copy.visible != shown:
			copy.visible = shown


## Whether every ancestor of `node` below the actor node is visible; the
## actor node itself may be hidden or shadow-only for first person.
func _ancestors_shown(node: Node) -> bool:
	var parent := node.get_parent()
	while parent != null and parent != _actor:
		if parent is Node3D and not (parent as Node3D).visible:
			return false
		parent = parent.get_parent()
	return true
