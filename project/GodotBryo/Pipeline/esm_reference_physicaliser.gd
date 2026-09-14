@tool
class_name EsmReferencePhysicaliser
extends RefCounted

## Converts an authored EsmReference into its typed worldspace node. Asset
## construction deliberately belongs to the EsmNode after it enters a tree:
## this factory never blocks on NIF or texture work.

const DoorNodeScript := preload("res://GodotBryo/Types/Node/esm_door_node.gd")
const ItemNodeScript := preload("res://GodotBryo/Types/Node/esm_item_node.gd")
const StaticNodeScript := preload("res://GodotBryo/Types/Node/esm_static_node.gd")
const LightNodeScript := preload("res://GodotBryo/Types/Node/esm_light_node.gd")
const ActivatorNodeScript := preload("res://GodotBryo/Types/Node/esm_activator_node.gd")
const ContainerNodeScript := preload("res://GodotBryo/Types/Node/esm_container_node.gd")
const FurnitureNodeScript := preload("res://GodotBryo/Types/Node/esm_furniture_node.gd")
const StaticCollectionNodeScript := preload("res://GodotBryo/Types/Node/esm_static_collection_node.gd")
const MovableStaticNodeScript := preload("res://GodotBryo/Types/Node/esm_movable_static_node.gd")
const TalkingActivatorNodeScript := preload("res://GodotBryo/Types/Node/esm_talking_activator_node.gd")
const TerminalNodeScript := preload("res://GodotBryo/Types/Node/esm_terminal_node.gd")
const LeveledItemPreviewNodeScript := preload("res://GodotBryo/Types/Node/esm_leveled_item_preview_node.gd")
const NpcActorScene := preload("res://gamebryo/esm_npc_actor.tscn")
const GAMEBRYO_TO_GODOT_BASIS := Basis(Vector3.RIGHT, -PI / 2.0)

## Creates and configures one semantic node synchronously. Once parented, the
## node's own @tool/runtime startup requests NifServer as appropriate. The
## desired visual tier is assigned before tree entry, so a distant VWD tile
## never first queues its full-detail model.
func physicalise(reference: EsmReference, parent: Node3D = null, initial_visual_detail: int = EsmNode.VisualDetail.FULL) -> Node3D:
	if reference == null:
		return null
	var root: EsmNode = _make_node(reference)
	root.configure(reference)
	root.visual_detail = initial_visual_detail
	root.name = _node_name(reference)
	# NifServer returns a Godot-facing NIF tree. Convert the placement into that
	# same frame by conjugation, avoiding a second axis correction on the NIF.
	root.transform = _placement_transform(reference.position, reference.rotation, reference.scale)
	root.set_meta("gamebryo_placement_space", true)
	if parent != null:
		parent.add_child(root)
	return root

## Build one derived SCOL part as an ordinary StaticReference. Parts have no
## REFR identity of their own, so their synthetic ID is traceability-only.
func physicalise_scol_part(part: Dictionary, index: int) -> Node3D:
	var base_form_id := int(part.get("base_form_id", 0))
	if base_form_id == 0:
		return null
	var tree := Engine.get_main_loop()
	var server = tree.root.get_node_or_null("EsmServer") if tree != null else null
	if server == null:
		return null
	var base: EsmBase = server.get_base(base_form_id)
	if not base is StaticBase:
		return null
	var reference := StaticReference.new()
	reference.base_form_id = base_form_id
	reference.base = base
	reference.instance_id = "scolpart:%08X:%d" % [base_form_id, index]
	reference.position = part.get("position", Vector3.ZERO)
	reference.rotation = part.get("rotation", Vector3.ZERO)
	reference.scale = float(part.get("scale", 1.0))
	return physicalise(reference)

func _make_node(reference: EsmReference) -> EsmNode:
	if reference is ActorReference and reference.base is NpcBase:
		return NpcActorScene.instantiate()
	if reference is DoorReference:
		return DoorNodeScript.new()
	if reference is LeveledItemReference:
		return LeveledItemPreviewNodeScript.new()
	if reference is MiscReference or reference is AlchemyReference \
			or reference is AmmoReference or reference is KeyReference \
			or reference is WeaponReference or reference is ArmorReference \
			or reference is BookReference or reference is CaravanCardReference \
			or reference is CaravanMoneyReference:
		return ItemNodeScript.new()
	if reference is StaticReference:
		return StaticNodeScript.new()
	if reference is LightReference:
		return LightNodeScript.new()
	if reference is ActivatorReference:
		return ActivatorNodeScript.new()
	if reference is ContainerReference:
		return ContainerNodeScript.new()
	if reference is FurnitureReference:
		return FurnitureNodeScript.new()
	if reference is StaticCollectionReference:
		return StaticCollectionNodeScript.new()
	if reference is MovableStaticReference:
		return MovableStaticNodeScript.new()
	if reference is TalkingActivatorReference:
		return TalkingActivatorNodeScript.new()
	if reference is TerminalReference:
		return TerminalNodeScript.new()
	return EsmNode.new()

func _node_name(reference: EsmReference) -> String:
	var form_id := _reference_form_id(reference)
	var type_name := String(reference.base.record_type) if reference.base != null else "REFR"
	var label := String(reference.base.full_name).strip_edges() if reference.base != null else ""
	if label.is_empty() and reference.base != null:
		label = String(reference.base.editor_id).strip_edges()
	if label.is_empty():
		label = type_name
	label = label.validate_node_name()
	var suffix := "%08X" % form_id if form_id != 0 else reference.instance_id.replace(":", "_")
	return "%s_%s_%s" % [type_name, label, suffix]

func _reference_form_id(reference: EsmReference) -> int:
	var marker := reference.instance_id.find(":")
	if marker < 0:
		return 0
	return _parse_hex(reference.instance_id.substr(marker + 1))

func _parse_hex(value: String) -> int:
	var result := 0
	for character in value.to_upper():
		var digit := "0123456789ABCDEF".find(character)
		if digit < 0:
			return 0
		result = result * 16 + digit
	return result

func _placement_transform(position: Vector3, rotation: Vector3, scale: float) -> Transform3D:
	var authored_basis := _authored_rotation_basis(rotation)
	var authored := Transform3D(authored_basis * Basis().scaled(Vector3.ONE * scale), position)
	var conversion := Transform3D(GAMEBRYO_TO_GODOT_BASIS, Vector3.ZERO)
	return conversion * authored * conversion.affine_inverse()

## Gamebryo stores REFR Euler angles in radians. The established NV path uses
## the negated authored angles in X/Y/Z composition order.
func _authored_rotation_basis(rotation: Vector3) -> Basis:
	var bx := Basis(Vector3.RIGHT, -rotation.x)
	var by := Basis(Vector3.UP, -rotation.y)
	var bz := Basis(Vector3.BACK, -rotation.z)
	return bx * by * bz
