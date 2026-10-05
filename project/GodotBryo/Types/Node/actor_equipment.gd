@tool
class_name ActorEquipment
extends Node

## Builds the models of what an actor has equipped and attaches them to its
## body. A child of the actor node (esm_actor_node.tscn). It watches the
## actor reference's inventory, projects the equipped items into
## `equipment_state`, requests their NIFs and, once all are delivered, swaps the
## Body's "Equipment" child for the new set and emits `committed`. A failed
## refresh keeps the current equipment.

signal committed(body: Node3D)

const EQUIPMENT_NODE_NAME := "Equipment"

## The equipped armour and weapon, projected from the inventory. Setting it
## refreshes the models once the body is built.
@export var equipment_state: EsmActorEquipmentState:
	set(value):
		_disconnect_state_signals()
		equipment_state = value
		_connect_state_signals()
		if _body != null:
			refresh()

## The inventory being watched: the actor reference's `contents`.
var inventory: Inventory = null

var _body: Node3D = null
var _skeleton: Skeleton3D = null
var _is_female := false
var _generation := 0
var _loading := false
var _pending := 0
var _desired_signature := ""
var _applied_signature := ""
var _descriptors: Array[Dictionary] = []
var _trees := {}
var _failures: Array[String] = []
var _staging: Node3D = null
var _observed_resources: Array[Resource] = []

## Watches `reference`'s inventory and projects what it has equipped.
func watch(reference: ActorReference) -> void:
	_stop_watching_inventory()
	if reference == null:
		return
	if reference.contents == null:
		reference.contents = Inventory.new()
	inventory = reference.contents
	if not inventory.inventory_changed.is_connected(_project_from_inventory):
		inventory.inventory_changed.connect(_project_from_inventory)
	_project_from_inventory()

## The body is built: equipment is attached to `body` and bound to `skeleton`
## from now on, using the female or male models.
func set_body(body: Node3D, skeleton: Skeleton3D, is_female: bool) -> void:
	_body = body
	_skeleton = skeleton
	_is_female = is_female
	_applied_signature = ""
	refresh()

## The body is being rebuilt or the actor changed: stops loading and refreshes
## nothing until set_body() is called again. The inventory stays watched.
func forget_body() -> void:
	cancel()
	_body = null
	_skeleton = null

## Stops loading, forgets the body and the inventory.
func clear() -> void:
	cancel()
	_body = null
	_skeleton = null
	_stop_watching_inventory()
	inventory = null

## Whether a refresh is waiting for NIFs.
func is_loading() -> bool:
	return _loading

## Rebuilds the equipment models when what is equipped has changed.
func refresh() -> void:
	if not is_instance_valid(_body) or not is_instance_valid(_skeleton):
		return
	var descriptors := _model_descriptors()
	var signature := _signature(descriptors)
	if signature == _applied_signature and not _loading:
		return
	if _loading and signature == _desired_signature:
		return
	cancel()
	_desired_signature = signature
	_descriptors = descriptors
	if descriptors.is_empty():
		_commit(Node3D.new(), signature)
		return
	var nif_server := get_tree().root.get_node_or_null("NifServer") if is_inside_tree() else null
	if nif_server == null:
		push_warning("ActorEquipment: NifServer autoload is unavailable")
		return
	_generation += 1
	_loading = true
	_staging = Node3D.new()
	_staging.name = "EquipmentStaging"
	_staging.visible = false
	_body.add_child(_staging)
	var generation := _generation
	for index in descriptors.size():
		_pending += 1
		nif_server.request(String(descriptors[index].path), self, _on_nif_delivered.bind(generation, index), false)

## Abandons a refresh in progress; the current equipment stays.
func cancel() -> void:
	_generation += 1
	_loading = false
	_pending = 0
	_descriptors.clear()
	_trees.clear()
	_failures.clear()
	if _staging != null and is_instance_valid(_staging):
		_staging.queue_free()
	_staging = null

func _ready() -> void:
	_connect_state_signals()

func _exit_tree() -> void:
	cancel()
	_stop_watching_inventory()
	_disconnect_state_signals()

func _stop_watching_inventory() -> void:
	if inventory != null and is_instance_valid(inventory) and inventory.inventory_changed.is_connected(_project_from_inventory):
		inventory.inventory_changed.disconnect(_project_from_inventory)

func _project_from_inventory() -> void:
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

func _connect_state_signals() -> void:
	_disconnect_state_signals()
	if equipment_state == null:
		return
	var resources: Array[Resource] = [equipment_state]
	for item in equipment_state.armor_items:
		_add_resource(resources, item)
		if item != null:
			_add_resource(resources, item.item_reference)
			_add_resource(resources, item.item_reference.base as ArmorBase if item.item_reference != null else null)
	_add_resource(resources, equipment_state.weapon_item)
	for resource in resources:
		if resource != null and not resource.changed.is_connected(_on_resource_changed):
			resource.changed.connect(_on_resource_changed)
			_observed_resources.append(resource)

func _add_resource(resources: Array[Resource], resource: Resource) -> void:
	if resource != null and not resources.has(resource):
		resources.append(resource)

func _disconnect_state_signals() -> void:
	for resource in _observed_resources:
		if is_instance_valid(resource) and resource.changed.is_connected(_on_resource_changed):
			resource.changed.disconnect(_on_resource_changed)
	_observed_resources.clear()

func _on_resource_changed() -> void:
	_connect_state_signals()
	if _body != null:
		refresh()

## The NIFs to load: the accepted armour (later armour loses to earlier armour
## occupying the same biped slots), each armour's biped model list, and the
## weapon's biped models or, without them, its world model.
func _model_descriptors() -> Array[Dictionary]:
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
			EsmActorNode._warn_once("ActorEquipment: skipped overlapping armor %s (%08X)" % [armor.editor_id, armor.biped_flags])
			continue
		accepted.push_front(armor)
		occupied |= armor.biped_flags
	var model_field := "MOD3" if _is_female else "MODL"
	for armor in accepted:
		var direct := armor.female_biped_model if _is_female else armor.male_biped_model
		_add_descriptor(result, direct, armor, armor.biped_flags, model_field, "armor")
		var model_list := armor.biped_model_list as FormListBase
		if model_list != null:
			for entry in model_list.entries:
				var addon := entry as ArmorAddonBase
				if addon != null:
					var addon_path := addon.female_biped_model if _is_female else addon.male_biped_model
					_add_descriptor(result, addon_path, addon, addon.biped_flags, model_field, "armor")
	var weapon := state.get_weapon_base()
	if weapon != null:
		var weapon_models := weapon.biped_model_list as FormListBase
		if weapon_models != null:
			for entry in weapon_models.entries:
				var addon := entry as ArmorAddonBase
				if addon != null:
					var addon_path := addon.female_biped_model if _is_female else addon.male_biped_model
					_add_descriptor(result, addon_path, addon, addon.biped_flags, "BIPL", "weapon")
		if not result.any(func(item): return String(item.get("kind", "")) == "weapon"):
			_add_descriptor(result, weapon.model_path, weapon, 0, "MODL", "weapon")
	return result

func _add_descriptor(target: Array[Dictionary], path: String, source: EsmBase, biped_flags: int, field: String, kind: String) -> void:
	if path.strip_edges().is_empty() or source == null:
		return
	target.append({"path": path, "source_form_id": source.form_id, "biped_flags": biped_flags, "field": field, "kind": kind})

func _signature(descriptors: Array[Dictionary]) -> String:
	var parts: Array[String] = []
	for descriptor in descriptors:
		parts.append("%08X:%X:%s:%s" % [int(descriptor.source_form_id), int(descriptor.biped_flags), String(descriptor.field), String(descriptor.path).to_lower()])
	return "|".join(parts)

func _on_nif_delivered(tree: Node3D, generation: int, index: int) -> void:
	if generation != _generation or not _loading or _staging == null or not is_instance_valid(_staging):
		if tree != null:
			tree.free()
		return
	if tree == null:
		_failures.append(String(_descriptors[index].path))
	else:
		tree.name = "Equipment_%d" % index
		_staging.add_child(tree)
		_trees[index] = tree
	_pending -= 1
	if _pending == 0:
		_complete(generation)

func _complete(generation: int) -> void:
	if generation != _generation or not _loading:
		return
	if not _failures.is_empty():
		EsmActorNode._warn_once("ActorEquipment: retained current equipment; replacement NIFs failed: " + ", ".join(_failures))
		cancel()
		return
	if not is_instance_valid(_body) or not is_instance_valid(_skeleton):
		cancel()
		return
	var skinning := get_node_or_null(^"../ActorSkinning") as ActorSkinning
	var equipment := Node3D.new()
	equipment.name = EQUIPMENT_NODE_NAME
	# External BoneAttachment paths need a common ancestor with Skeleton3D.
	# Keep the replacement hidden but in the live staging subtree until commit.
	_staging.add_child(equipment)
	for index in _descriptors.size():
		var descriptor := _descriptors[index]
		var tree := _trees.get(index) as Node3D
		if tree == null:
			equipment.free()
			cancel()
			return
		if skinning.tree_has_skin(tree):
			skinning.compact_external_skin_part(tree)
			if not skinning.bind_external_skins(tree, _skeleton):
				EsmActorNode._warn_once("ActorEquipment: retained current equipment; unresolved skeleton binds: " + String(descriptor.path))
				equipment.free()
				cancel()
				return
			_move_tree(tree, equipment, "Skinned_%d" % index)
		elif not _attach_unskinned(tree, equipment, descriptor, index):
			EsmActorNode._warn_once("ActorEquipment: retained current equipment; no supported attachment: " + String(descriptor.path))
			equipment.free()
			cancel()
			return
		_tag_meshes(tree, descriptor)
	_commit(equipment, _desired_signature)

## Attaches an unskinned model to the bone it belongs on: a weapon to the
## right hand (or the nearest bone the skeleton has), hair, head and eyewear
## to the head. False for anything else.
func _attach_unskinned(tree: Node3D, equipment: Node3D, descriptor: Dictionary, index: int) -> bool:
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
		if _skeleton.find_bone(candidate) != -1:
			bone_name = candidate
			break
	if bone_name.is_empty():
		return false
	var attachment := BoneAttachment3D.new()
	attachment.name = "EquipmentAttachment_%d" % index
	attachment.bone_name = bone_name
	equipment.add_child(attachment)
	attachment.use_external_skeleton = true
	attachment.external_skeleton = attachment.get_path_to(_skeleton)
	attachment.bone_idx = _skeleton.find_bone(bone_name)
	attachment.on_skeleton_update()
	_move_tree(tree, attachment, "Attached_%d" % index)
	tree.transform = Transform3D.IDENTITY
	return true

func _tag_meshes(root: Node3D, descriptor: Dictionary) -> void:
	for child in root.find_children("*", "MeshInstance3D", true, false):
		child.set_meta("gamebryo_equipment", true)
		child.set_meta("gamebryo_equipment_form_id", int(descriptor.source_form_id))
		child.set_meta("gamebryo_equipment_biped_flags", int(descriptor.biped_flags))
		child.set_meta("gamebryo_equipment_model_field", String(descriptor.field))
		child.set_meta("gamebryo_model_path", String(descriptor.path))

func _commit(equipment: Node3D, signature: String) -> void:
	var old_equipment := _body.get_node_or_null(NodePath(EQUIPMENT_NODE_NAME))
	if old_equipment != null:
		_body.remove_child(old_equipment)
	if equipment.get_parent() != null:
		equipment.get_parent().remove_child(equipment)
	equipment.name = EQUIPMENT_NODE_NAME
	_body.add_child(equipment)
	if Engine.is_editor_hint() and get_tree().edited_scene_root != null:
		_own_recursive(equipment)
	if old_equipment != null:
		old_equipment.queue_free()
	_applied_signature = signature
	_loading = false
	_pending = 0
	_trees.clear()
	_failures.clear()
	if _staging != null and is_instance_valid(_staging):
		_staging.queue_free()
	_staging = null
	committed.emit(_body)

func _move_tree(tree: Node3D, new_parent: Node, node_name: String) -> void:
	if tree.get_parent() != null:
		tree.get_parent().remove_child(tree)
	tree.name = node_name
	new_parent.add_child(tree)

func _own_recursive(node: Node) -> void:
	node.owner = get_tree().edited_scene_root
	for child in node.get_children():
		_own_recursive(child)
