@tool
class_name FirstPersonViewmodel
extends Node3D

## The possessed actor's drawn weapon as the first-person view shows it: a copy
## of the weapon's viewmodel on the first-person rig's `Weapon` bone. A child of
## FirstPersonRig (first_person_rig.tscn), which hands it the actor it follows
## and its skeleton. Plan: Plans/Weapons/weapons.md, Models.
##
## The viewmodel is the WEAP's WNAM STAT's model (the 1st Person Model), else
## its world model (MODL): 313 of the 378 WEAP with a MODL share one NIF, 17
## differ, 48 have no WNAM. It is built only while the actor has a weapon
## drawn, and only here: an actor's own weapon node shows the world model. Its
## rigid bodies and collision are removed; it casts no shadow, as the rig's
## other meshes do not.

## The rig bone the viewmodel hangs from.
const WEAPON_BONE := "Weapon"

## The weapon the viewmodel is a copy of, null when none is drawn.
var weapon: WeaponReference = null
## The viewmodel's built tree, null while none is drawn or it is loading.
var model: Node3D = null

var _actor: EsmActorNode = null
## The actor's reference whose slots are watched: read from the actor at each
## refresh, as the actor can be given its reference after follow() (the
## player's, in PlayerController.possess()).
var _reference: ActorReference = null
var _skeleton: Skeleton3D = null
var _attachment: BoneAttachment3D = null
## The model path requested last; a delivery for another path is dropped.
var _requested_path := ""
## Bone attachments holding parts moved off the model, freed with it.
var _part_holders: Array[BoneAttachment3D] = []


## Copies `actor`'s drawn weapon onto `skeleton` from now on; a null actor or
## skeleton clears it.
func follow(actor: EsmActorNode, skeleton: Skeleton3D) -> void:
	_actor = actor
	if skeleton != _skeleton:
		_clear()
		if _attachment != null:
			_attachment.queue_free()
			_attachment = null
		_skeleton = skeleton
	refresh()


## Builds, replaces or clears the copy to match the actor's drawn weapon.
func refresh() -> void:
	_watch_reference(_actor.reference as ActorReference if _actor != null else null)
	var drawn := _reference.get_drawn_weapon() if _reference != null else null
	if drawn == weapon and (model != null or not _requested_path.is_empty()):
		return
	_clear()
	weapon = drawn
	if weapon == null or _skeleton == null:
		return
	var path := viewmodel_path(weapon.base as WeaponBase)
	if path.is_empty():
		return
	_requested_path = path
	NifServer.request(path, self, _on_model_delivered.bind(path))


## Watches `reference`'s weapon slots in place of the previous reference's.
func _watch_reference(reference: ActorReference) -> void:
	if reference == _reference:
		return
	if _reference != null and _reference.weapon_slots_changed.is_connected(refresh):
		_reference.weapon_slots_changed.disconnect(refresh)
	_reference = reference
	if _reference != null:
		_reference.weapon_slots_changed.connect(refresh)


## The viewmodel's NIF: the WNAM STAT's model, else the world model; "" when it
## has neither.
static func viewmodel_path(base: WeaponBase) -> String:
	if base == null:
		return ""
	var server := EsmReference.get_esm_server()
	if server != null and base.first_person_form_id != 0:
		var first_person := server.get_base(base.first_person_form_id) as StaticBase
		if first_person != null and not first_person.model_path.is_empty():
			return first_person.model_path
	return base.model_path


func _on_model_delivered(tree: Node3D, path: String) -> void:
	if tree == null:
		return
	if path != _requested_path or _skeleton == null:
		tree.queue_free()
		return
	_requested_path = ""
	_strip_physics(tree)
	for mesh: MeshInstance3D in tree.find_children("*", "MeshInstance3D", true, false):
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_weapon_attachment().add_child(tree)
	tree.transform = Transform3D.IDENTITY
	model = tree
	_hang_bone_parts(tree)


## Moves the model's parts that name a rig bone (the heavy weapons' Backpack,
## EsmWeaponNode.BONE_PART_KEY) under that bone, keeping their transform, as
## ActorWeaponSlots does for the world model.
func _hang_bone_parts(tree: Node3D) -> void:
	for part: Node in tree.find_children("*", "Node3D", true, false):
		var strings: Dictionary = part.get_meta("nif_string_extra_data", {})
		var bone := String(strings.get(EsmWeaponNode.BONE_PART_KEY, "")).strip_edges()
		var bone_index := _skeleton.find_bone(bone) if not bone.is_empty() else -1
		if bone_index == -1:
			continue
		var holder := BoneAttachment3D.new()
		holder.name = "ViewmodelPart_" + NifNames.escape(bone)
		holder.bone_name = bone
		_skeleton.add_child(holder)
		holder.bone_idx = bone_index
		var local := (part as Node3D).transform
		part.get_parent().remove_child(part)
		holder.add_child(part)
		(part as Node3D).transform = local
		_part_holders.append(holder)


## Removes the model's rigid bodies and collision: a NifRigidBody would pin the
## meshes where it was built (EsmWeaponNode.hold_bodies()), and a viewmodel
## has nothing to collide.
static func _strip_physics(tree: Node3D) -> void:
	for body: Node in tree.find_children("*", "CollisionObject3D", true, false):
		body.get_parent().remove_child(body)
		body.free()


## The BoneAttachment3D on the rig's Weapon bone, made on first use.
func _weapon_attachment() -> BoneAttachment3D:
	if _attachment != null and is_instance_valid(_attachment):
		return _attachment
	_attachment = BoneAttachment3D.new()
	_attachment.name = "ViewmodelAttachment"
	_attachment.bone_name = WEAPON_BONE
	_skeleton.add_child(_attachment)
	_attachment.bone_idx = _skeleton.find_bone(WEAPON_BONE)
	return _attachment


func _clear() -> void:
	weapon = null
	_requested_path = ""
	if model != null and is_instance_valid(model):
		model.queue_free()
	model = null
	for holder in _part_holders:
		if is_instance_valid(holder):
			holder.queue_free()
	_part_holders.clear()
