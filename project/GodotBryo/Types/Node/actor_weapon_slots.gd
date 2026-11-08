@tool
class_name ActorWeaponSlots
extends Node

## Hangs an actor's weapons on its body: each weapon slot's EsmWeaponNode, on
## its holster point or, for the drawn slot, on the `Weapon` bone. A child of
## the actor node (esm_actor_node.tscn). The slots are the actor reference's
## (ActorReference.weapon_right_hip, weapon_left_hip, weapon_back,
## drawn_weapon_slot). Plan: Plans/Weapons/weapons.md.
##
## A holster point is the weapon family's holster clip: its `prn:` text key
## names the bone and its `Weapon` track holds the pose in that bone's space;
## its visibility tracks hide parts while holstered (2hhholster hides the heavy
## weapons' guns). The left hip has no clip: it is the right hip's point
## mirrored across the body. A part naming a bone (EsmWeaponNode
## get_bone_parts(): the heavy weapons' Backpack) hangs from that bone
## whether the weapon is drawn or holstered.

## The bone a drawn weapon hangs from, under the right hand.
const DRAWN_BONE := "Weapon"
## The text key naming a holster clip's bone: `prn: Bip01 Pelvis`.
const PARENT_KEY_PREFIX := "prn:"
## The holster clip's track holding the weapon's pose.
const WEAPON_TRACK := "Weapon"
## A visibility track's path suffix (NifServer's NifAnimationBuilder).
const VISIBILITY_SUFFIX := ":visible"
## The bones whose rest positions give the body's left-right axis.
const LEFT_THIGH := "Bip01 L Thigh"
const RIGHT_THIGH := "Bip01 R Thigh"

## Holster clip path -> {bone: String, pose: Transform3D, hidden: {part NIF
## name -> visible}}, shared by every actor; a path with an empty Dictionary
## failed to load.
static var _holster_points := {}

var _reference: ActorReference
var _skeleton: Skeleton3D
## Weapon reference -> its EsmWeaponNode.
var _nodes := {}
## Weapon reference -> the parts moved from its model to a bone.
var _bone_parts := {}
## Holster clips requested and not yet delivered.
var _requested := {}


## Follows `reference`'s weapon slots.
func watch(reference: ActorReference) -> void:
	if _reference != null and _reference.weapon_slots_changed.is_connected(refresh):
		_reference.weapon_slots_changed.disconnect(refresh)
	_reference = reference
	if _reference != null:
		_reference.weapon_slots_changed.connect(refresh)
	refresh()


## The body is built: weapons hang from `skeleton` from now on.
func set_body(skeleton: Skeleton3D) -> void:
	_skeleton = skeleton
	_free_all()
	refresh()


## The body is going: frees the weapon nodes.
func forget_body() -> void:
	_free_all()
	_skeleton = null


## The EsmWeaponNode of `weapon`, or null when it has none.
func get_weapon_node(weapon: WeaponReference) -> EsmWeaponNode:
	return _nodes.get(weapon) as EsmWeaponNode


## Builds, moves and frees weapon nodes to match the slots.
func refresh() -> void:
	if _skeleton == null or _reference == null:
		_free_all()
		return
	var wanted := {}
	for slot: ActorReference.WeaponSlot in [ActorReference.WeaponSlot.RIGHT_HIP, ActorReference.WeaponSlot.LEFT_HIP, ActorReference.WeaponSlot.BACK]:
		var weapon := _reference.get_weapon(slot)
		if weapon != null:
			wanted[weapon] = slot
	for weapon: WeaponReference in _nodes.keys():
		if not wanted.has(weapon):
			_free_node(weapon)
	for weapon: WeaponReference in wanted:
		_hang(weapon, wanted[weapon])


## Hangs `weapon`'s node at its point for `slot`: the drawn bone when the slot is
## drawn, else the holster point (once its clip is loaded).
func _hang(weapon: WeaponReference, slot: ActorReference.WeaponSlot) -> void:
	var bone := DRAWN_BONE
	var pose := Transform3D.IDENTITY
	if slot != _reference.drawn_weapon_slot:
		var point := _holster_point(weapon.base as WeaponBase)
		if point.is_empty():
			return
		bone = String(point["bone"])
		pose = point["pose"]
		if slot == ActorReference.WeaponSlot.LEFT_HIP:
			pose = _mirrored(bone, pose)
	var bone_index := _skeleton.find_bone(bone)
	if bone_index == -1:
		return
	var node := _nodes.get(weapon) as EsmWeaponNode
	if node == null:
		node = EsmReferencePhysicaliser.new().physicalise_held(weapon)
		if node == null:
			return
		_nodes[weapon] = node
		node.visual_detail_applied.connect(_on_weapon_visual.bind(weapon))
	var attachment := _attachment(bone, bone_index)
	if node.get_parent() != attachment:
		if node.get_parent() != null:
			node.get_parent().remove_child(node)
		attachment.add_child(node)
	node.transform = pose
	# A weapon with biped models (power fists, gloves) is worn through them
	# (ActorEquipment); its world model would show twice.
	var base := weapon.base as WeaponBase
	node.visible = base == null or base.biped_model_list == null
	_apply_part_visibility(weapon, slot)
	_hang_bone_parts(weapon)
	_own_in_editor(attachment)
	for part: Node in _bone_parts.get(weapon, []):
		_own_in_editor(part.get_parent())
	# The possessed actor shows only its shadow in first person; a weapon hung
	# after the body was built takes that too.
	var actor := get_parent() as EsmActorNode
	if actor != null:
		actor.refresh_first_person_render_mode()


## A new model came: the parts moved from the old one go with it.
func _on_weapon_visual(_detail: int, weapon: WeaponReference) -> void:
	for part: Node in _bone_parts.get(weapon, []):
		if is_instance_valid(part):
			part.queue_free()
	_bone_parts.erase(weapon)
	refresh()


## Shows or hides `weapon`'s parts as its holster clip keys them while it is
## holstered; drawn, every keyed part shows.
func _apply_part_visibility(weapon: WeaponReference, slot: ActorReference.WeaponSlot) -> void:
	var node := _nodes.get(weapon) as EsmWeaponNode
	var point := _holster_point(weapon.base as WeaponBase)
	if node == null or point.is_empty():
		return
	var holstered := slot != _reference.drawn_weapon_slot
	var keyed: Dictionary = point["hidden"]
	for part_name: String in keyed:
		var part := node.get_part(part_name)
		if part == null:
			continue
		part.visible = bool(keyed[part_name]) if holstered else true


## Moves `weapon`'s parts that name a bone (its Backpack) under that bone, once
## its model has loaded. Their local transform is kept: the Backpack node sits at
## the weapon's origin, its shapes offset inside it, read as authored in the
## bone's space (inferred; no data states it).
func _hang_bone_parts(weapon: WeaponReference) -> void:
	if _bone_parts.has(weapon):
		return
	var node := _nodes.get(weapon) as EsmWeaponNode
	var parts := node.get_bone_parts(_skeleton) if node != null else {}
	if parts.is_empty():
		return
	var moved: Array[Node3D] = []
	for part: Node3D in parts:
		var bone := String(parts[part])
		# A part can have its own rigid body (the minigun's Backpack does),
		# which would move it back to where it was built.
		EsmWeaponNode.hold_bodies(part, true)
		var local := part.transform
		part.get_parent().remove_child(part)
		_attachment(bone, _skeleton.find_bone(bone)).add_child(part)
		part.transform = local
		moved.append(part)
	_bone_parts[weapon] = moved


## The holster point of `base`'s family, {} until its clip has loaded or when
## it has none.
func _holster_point(base: WeaponBase) -> Dictionary:
	if base == null:
		return {}
	var path := base.holster_clip_path()
	if path.is_empty():
		return {}
	if _holster_points.has(path):
		return _holster_points[path]
	if not _requested.has(path):
		_requested[path] = true
		NifServer.request_kf(path, self, _on_holster_clip.bind(path))
	return {}


func _on_holster_clip(library: AnimationLibrary, path: String) -> void:
	_requested.erase(path)
	_holster_points[path] = _read_holster_point(library)
	refresh()


## A holster clip's bone (its `prn:` key) and its `Weapon` pose at the start;
## {} when it has neither.
static func _read_holster_point(library: AnimationLibrary) -> Dictionary:
	if library == null or library.get_animation_list().is_empty():
		return {}
	var clip := library.get_animation(library.get_animation_list()[0])
	var bone := ""
	for key: Dictionary in clip.get_meta("nif_text_keys", []):
		var text := String(key.get("value", "")).strip_edges()
		if text.to_lower().begins_with(PARENT_KEY_PREFIX):
			bone = text.substr(PARENT_KEY_PREFIX.length()).strip_edges()
	if bone.is_empty():
		return {}
	var pose := Transform3D.IDENTITY
	var hidden := {}
	for track in clip.get_track_count():
		var path := String(clip.track_get_path(track))
		if clip.track_get_type(track) == Animation.TYPE_VALUE and path.ends_with(VISIBILITY_SUFFIX):
			var part := NifNames.unescape(path.trim_suffix(VISIBILITY_SUFFIX))
			hidden[part] = bool(clip.value_track_interpolate(track, 0.0))
			continue
		if path != WEAPON_TRACK:
			continue
		if clip.track_get_type(track) == Animation.TYPE_POSITION_3D:
			pose.origin = clip.position_track_interpolate(track, 0.0)
		elif clip.track_get_type(track) == Animation.TYPE_ROTATION_3D:
			pose.basis = Basis(clip.rotation_track_interpolate(track, 0.0))
	return {"bone": bone, "pose": pose, "hidden": hidden}


## `pose`, in `bone`'s space, mirrored across the body: reflected in the plane
## through the pelvis normal to the thighs' left-right axis, at rest.
## `# ASSUMPTION` the left hip is the right hip mirrored; the original has no
## left hip slot.
func _mirrored(bone: String, pose: Transform3D) -> Transform3D:
	var bone_index := _skeleton.find_bone(bone)
	var left := _skeleton.find_bone(LEFT_THIGH)
	var right := _skeleton.find_bone(RIGHT_THIGH)
	if bone_index == -1 or left == -1 or right == -1:
		return pose
	var bone_rest := _skeleton.get_bone_global_rest(bone_index)
	var across := _skeleton.get_bone_global_rest(left).origin - _skeleton.get_bone_global_rest(right).origin
	if across.length_squared() < 0.000001:
		return pose
	var normal := across.normalized()
	var centre := (_skeleton.get_bone_global_rest(left).origin + _skeleton.get_bone_global_rest(right).origin) * 0.5
	var global := bone_rest * pose
	var reflection := Basis(Vector3.RIGHT - 2.0 * normal.x * normal, Vector3.UP - 2.0 * normal.y * normal, Vector3.BACK - 2.0 * normal.z * normal)
	var origin := global.origin - 2.0 * normal * normal.dot(global.origin - centre)
	# Reflecting the basis on both sides keeps it a rotation (determinant 1).
	var mirrored := Transform3D(reflection * global.basis * reflection, origin)
	return bone_rest.affine_inverse() * mirrored


## In the editor, gives `node` and everything under it to the edited scene, so
## the Scene dock shows them (as ActorEquipment does for its models).
func _own_in_editor(node: Node) -> void:
	if not Engine.is_editor_hint() or node == null or not is_inside_tree():
		return
	var scene_root := get_tree().edited_scene_root
	if scene_root == null or not scene_root.is_ancestor_of(node):
		return
	node.owner = scene_root
	for child in node.get_children():
		_own_in_editor(child)


## The BoneAttachment3D on `bone`, made on first use under the skeleton.
func _attachment(bone: String, bone_index: int) -> BoneAttachment3D:
	var attachment_name := "WeaponSlot_" + NifNames.escape(bone)
	var attachment := _skeleton.get_node_or_null(NodePath(attachment_name)) as BoneAttachment3D
	if attachment != null:
		return attachment
	attachment = BoneAttachment3D.new()
	attachment.name = attachment_name
	attachment.bone_name = bone
	_skeleton.add_child(attachment)
	attachment.bone_idx = bone_index
	return attachment


func _free_node(weapon: WeaponReference) -> void:
	var node := _nodes.get(weapon) as Node
	_nodes.erase(weapon)
	for part: Node in _bone_parts.get(weapon, []):
		if is_instance_valid(part):
			part.queue_free()
	_bone_parts.erase(weapon)
	if node != null and is_instance_valid(node):
		node.queue_free()


func _free_all() -> void:
	for weapon: WeaponReference in _nodes.keys():
		_free_node(weapon)
