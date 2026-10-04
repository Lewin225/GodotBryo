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
const ActorNodeScene := preload("res://GodotBryo/Types/Node/esm_actor_node.tscn")
const GAMEBRYO_TO_GODOT_BASIS := Basis(Vector3.RIGHT, -PI / 2.0)

## Creates and configures one semantic node synchronously. Once parented, the
## node's own @tool/runtime startup requests NifServer as appropriate. The
## desired visual tier is assigned before tree entry, so a distant VWD tile
## never first queues its full-detail model.
func physicalise(ref: EsmReference, parent: Node3D = null, initial_visual_detail: int = EsmNode.VisualDetail.FULL) -> Node3D:
	if ref == null:
		return null
	var root: EsmNode = _make_node(ref)
	root.configure(ref)
	root.visual_detail = initial_visual_detail as EsmNode.VisualDetail
	root.name = _node_name(ref)
	# NifServer returns a Godot-facing NIF tree. Convert the placement into that
	# same frame by conjugation, avoiding a second axis correction on the NIF.
	root.transform = placement_transform(ref.position, ref.rotation, ref.scale)
	root.set_meta("gamebryo_placement_space", true)
	# Humanoids have a multi-NIF body assembly rather than EsmNode's one-model
	# lifecycle. A physicalised actor is a near, previewable instance, so start
	# that assembly as soon as its typed reference has been assigned.
	if root is EsmActorNode:
		(root as EsmActorNode).load_actor()
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
	var ref := StaticReference.new()
	ref.base_form_id = base_form_id
	ref.base = base
	ref.instance_id = "scolpart:%08X:%d" % [base_form_id, index]
	ref.position = part.get("position", Vector3.ZERO)
	ref.rotation = part.get("rotation", Vector3.ZERO)
	ref.scale = float(part.get("scale", 1.0))
	return physicalise(ref)

func _make_node(ref: EsmReference) -> EsmNode:
	if ref is ActorReference:
		return ActorNodeScene.instantiate()
	if ref is DoorReference:
		return DoorNodeScript.new()
	if ref is LeveledItemReference:
		return LeveledItemPreviewNodeScript.new()
	if ref is MiscReference or ref is AlchemyReference \
			or ref is AmmoReference or ref is KeyReference \
			or ref is WeaponReference or ref is ArmorReference \
			or ref is BookReference or ref is CaravanCardReference \
			or ref is CaravanMoneyReference:
		return ItemNodeScript.new()
	if ref is StaticReference:
		return StaticNodeScript.new()
	if ref is LightReference:
		return LightNodeScript.new()
	if ref is ActivatorReference:
		return ActivatorNodeScript.new()
	if ref is ContainerReference:
		return ContainerNodeScript.new()
	if ref is FurnitureReference:
		return FurnitureNodeScript.new()
	if ref is StaticCollectionReference:
		return StaticCollectionNodeScript.new()
	if ref is MovableStaticReference:
		return MovableStaticNodeScript.new()
	if ref is TalkingActivatorReference:
		return TalkingActivatorNodeScript.new()
	if ref is TerminalReference:
		return TerminalNodeScript.new()
	return EsmNode.new()

func _node_name(ref: EsmReference) -> String:
	var form_id := _reference_form_id(ref)
	var type_name := String(ref.base.record_type) if ref.base != null else "REFR"
	var label := String(ref.base.full_name).strip_edges() if ref.base != null else ""
	if label.is_empty() and ref.base != null:
		label = String(ref.base.editor_id).strip_edges()
	if label.is_empty():
		label = type_name
	label = label.validate_node_name()
	var suffix := "%08X" % form_id if form_id != 0 else ref.instance_id.replace(":", "_")
	return "%s_%s_%s" % [type_name, label, suffix]

func _reference_form_id(ref: EsmReference) -> int:
	var marker := ref.instance_id.find(":")
	if marker < 0:
		return 0
	return _parse_hex(ref.instance_id.substr(marker + 1))

func _parse_hex(value: String) -> int:
	var result := 0
	for character in value.to_upper():
		var digit := "0123456789ABCDEF".find(character)
		if digit < 0:
			return 0
		result = result * 16 + digit
	return result

static func placement_transform(position: Vector3, rotation: Vector3, scale: float = 1.0) -> Transform3D:
	var authored_basis := authored_rotation_basis(rotation)
	var authored := Transform3D(authored_basis * Basis().scaled(Vector3.ONE * scale), position)
	var conversion := Transform3D(GAMEBRYO_TO_GODOT_BASIS, Vector3.ZERO)
	return conversion * authored * conversion.affine_inverse()

## Inverse of placement_transform()'s translation: a Godot-space position as
## an authored one (metres, Gamebryo Z-up axes).
static func authored_position(godot_position: Vector3) -> Vector3:
	return GAMEBRYO_TO_GODOT_BASIS.inverse() * godot_position

## A Godot yaw (rotation about +Y) as an authored rotation: a heading about
## Gamebryo +Z, which placement_transform() maps back to -z about Godot +Y.
static func authored_heading(godot_yaw: float) -> Vector3:
	return Vector3(0.0, 0.0, -godot_yaw)

## Gamebryo stores REFR Euler angles in radians. The established NV path uses
## the negated authored angles in X/Y/Z composition order.
static func authored_rotation_basis(rotation: Vector3) -> Basis:
	var bx := Basis(Vector3.RIGHT, -rotation.x)
	var by := Basis(Vector3.UP, -rotation.y)
	var bz := Basis(Vector3.BACK, -rotation.z)
	return bx * by * bz
