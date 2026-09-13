@tool
class_name EsmReferencePhysicaliser
extends RefCounted

## Converts an authored EsmReference into its *worldspace* physical representation.
## This should be treated as a singleton, not instanciated as needed

## The Provided EsmReference is placed into the returned node's EsmBase
## Worldspace is the key word - eg. WeaponReference passed in to this is returned like a dropped item

## Unknown reference types intentionally produce an empty Node3D root. This
## keeps editor inspection useful while missing physicalisations are added.

#region Script/Prefab References
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
var _mesh_resolver: GamebryoMeshResolver

const NifTreeBuilderScript := preload("res://GodotBryo/Servers/NifServer/nif_tree_builder.gd")

## Opt-in second visual path: build through NifServer's nifly-backed NifSource
## instead of GamebryoMeshResolver. Off by default -- the existing path is
## untouched and still the one everything ships on.
##
## Enable for a session with the project setting `godotbryo/use_nif_server`, or
## per-instance by setting this before calling physicalise(). The browser dock
## preview picks up the project setting with no changes of its own.
##
## What differs: nodes are typed from their real block type (section 3's node
## map -- a NiPointLight becomes an OmniLight3D, a NiCamera a Camera3D), names
## round-trip through the reversible escape rather than being sanitised, every
## node carries its authored name and block type as metadata, extra data lands
## as metadata, and all six texture slots are read.
var use_nif_server: bool = ProjectSettings.get_setting("godotbryo/use_nif_server", false)
#endregion

## Takes any EsmReference type and returns its world space representation, with the provided reference inserted
func physicalise(reference: EsmReference, parent: Node3D = null, world_space: bool = true) -> Node3D:
	if reference == null:
		return null
		
	var root: EsmNode
	var unsupported := false
	
	#region Lookup Table
	# This is the lookup table that binds the given EsmReference derived type to it's node representation
	
	# ACTI / ActorReference
	if reference is ActorReference and reference.base is NpcBase:
		var actor_node: EsmNpcActor = NpcActorScene.instantiate()
		actor_node.configure(reference)
		root = actor_node
		
	# DOOR/DoorReference
	elif reference is DoorReference:
		var door_node: EsmDoorNode = DoorNodeScript.new()
		door_node.configure(reference as DoorReference)
		root = door_node
		
	# LVLI/LeveledItem
	# These should never actually be physicalised, but this supports previewing them in the resource browser
	elif reference is LeveledItemReference:
		var leveled_preview: EsmLeveledItemPreviewNode = LeveledItemPreviewNodeScript.new()
		leveled_preview.configure(reference)
		root = leveled_preview
		
	# MISC/AMMO/WEAP(Dropped)/BOOK/CCRD
	# All of these are physics props that you can pick up to add to your inventory, so they all use ItemNodeScript
	elif reference is MiscReference or reference is AlchemyReference \
			or reference is AmmoReference or reference is KeyReference \
			or reference is WeaponReference or reference is ArmorReference \
			or reference is BookReference or reference is CaravanCardReference \
			or reference is CaravanMoneyReference:
		var item_node: EsmItemNode = ItemNodeScript.new()
		item_node.configure(reference)
		root = item_node
		
	# STAT / StaticReference
	elif reference is StaticReference:
		var static_node: EsmStaticNode = StaticNodeScript.new()
		static_node.configure(reference)
		root = static_node
		
	# LIGH / LightReference
	elif reference is LightReference:
		var light_node: EsmLightNode = LightNodeScript.new()
		light_node.configure(reference)
		root = light_node
		
	# ACTI / ActivatorReference
	elif reference is ActivatorReference:
		var activator_node: EsmActivatorNode = ActivatorNodeScript.new()
		activator_node.configure(reference)
		root = activator_node
		
	# CONT / ContainerReference
	elif reference is ContainerReference:
		var container_node: EsmContainerNode = ContainerNodeScript.new()
		container_node.configure(reference)
		root = container_node
		
	# FURN / FurnitureReference
	elif reference is FurnitureReference:
		var furniture_node: EsmFurnitureNode = FurnitureNodeScript.new()
		furniture_node.configure(reference)
		root = furniture_node
		
	# SCOL / StaticCollectionReference
	# These are a group of STAT, so configure just loops through and spawns a tree of STAT
	elif reference is StaticCollectionReference:
		var collection_node: EsmStaticCollectionNode = StaticCollectionNodeScript.new()
		collection_node.configure(reference)
		root = collection_node
		
	# MSST / MovableStaticReference - Pushable physics props, but can't be picked up
	elif reference is MovableStaticReference:
		var movable_node: EsmMovableStaticNode = MovableStaticNodeScript.new()
		movable_node.configure(reference)
		root = movable_node
		
	# TACT / TalkingActivatorReference - talk to intercoms, radios ect.
	elif reference is TalkingActivatorReference:
		var talking_activator_node = TalkingActivatorNodeScript.new()
		talking_activator_node.configure(reference)
		root = talking_activator_node
		
	# TERM / TerminalReference - TERM can be a real object or a screen used by another TERM
	# Best you check it has a non null world model before spawning it
	elif reference is TerminalReference:
		var terminal_node = TerminalNodeScript.new()
		terminal_node.configure(reference)
		root = terminal_node
		
	# Shouldn't happen, but will
	else:
		root = EsmNode.new()
		unsupported = true
	
	#endregion Lookup Table
		
	root.name = _node_name(reference)
	
	
	# REFR rotation/position are Bethesda-space values. A normal physicalized 
	# reference has no RefrRoot parent, so it needs the
	# fixed Bethesda Z-up -> Godot Y-up conversion here. SCOL parts are local
	# children of an already-converted collection anchor and must retain only
	# their authored relative transform; applying the conversion to both levels
	# rotates the collection onto its side.
	
	# TODO - This should be NifServer's job to return 
	root.transform = _world_transform(reference.position, reference.rotation, reference.scale) \
		if world_space else GamebryoMeshResolver.refr_transform(reference.position, reference.rotation, reference.scale)
	if _mesh_resolver == null:
		_mesh_resolver = GamebryoMeshResolver.new()
	var attached_before_build := false
	if root is EsmNpcActor and parent != null:
		parent.add_child(root)
		attached_before_build = true
	if root is EsmStaticCollectionNode:
		(root as EsmStaticCollectionNode).build_collection(self)
	elif use_nif_server:
		# Deliberately not awaited. NifServer's build() waits for texture
		# residency, so this completes over the next few frames and attaches
		# the visual when it is ready. Acceptable because use_nif_server is an
		# inspection flag, off by default; a caller that needs the node to
		# exist on return has to await build() itself.
		_build_visual_via_nif_server(root, reference)
	else:
		root.build_visual(_mesh_resolver)
	if unsupported:
		var label := Label3D.new()
		label.name = "UnsupportedTypeLabel"
		label.text = "Type not supported"
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.font_size = 64
		label.outline_size = 8
		label.modulate = Color(1.0, 0.75, 0.35, 1.0)
		root.add_child(label)
	if parent != null and not attached_before_build:
		parent.add_child(root)
	if parent != null:
		# NPC actors are attached before build so their deferred/async assembly
		# has a valid scene tree. Keep the authored NPC scene instance intact:
		# recursively assigning ownership here would flatten its authored
		# InventoryComponent/AnimationTree children and make Godot load them
		# twice when the temporary scene is reopened.
		if root is EsmNpcActor:
			root.owner = parent
		else:
			_set_owner_recursive(root, parent)
		if root is EsmItemNode:
			(root as EsmItemNode)._sync_physics_transform()
	return root

## Builds the visual through NifServer's NifSource. Returns false when there is
## nothing to build, so the caller falls back to the established path rather
## than producing an empty node.
##
## Deliberately does NOT apply NifTreeBuilder's own root basis: physicalise()
## already composes the Z-up -> Y-up conversion into the placement transform
## (see _world_transform), so applying it again would rotate the object twice.
## nif_server_v2.md has NifServer own that conversion and callers drop theirs;
## that migration is separate work and is not started here.
func _build_visual_via_nif_server(root: Node3D, reference: EsmReference) -> bool:
	if reference == null or reference.base == null:
		return false
	var model_path := String(reference.base.get("model_path") if reference.base.has_method("get") else "")
	if model_path.is_empty():
		return false

	var loop := Engine.get_main_loop()
	if loop == null or not (loop is SceneTree):
		return false
	var archive: Node = (loop as SceneTree).root.get_node_or_null("ArchiveServer")
	if archive == null or not archive.is_ready():
		push_warning("EsmReferencePhysicaliser: use_nif_server is on but ArchiveServer is unavailable")
		return false

	var result: Dictionary = archive.read("meshes/" + model_path)
	if not bool(result["found"]):
		push_warning("EsmReferencePhysicaliser: %s not found (%s)" % [model_path, result["error"]])
		return false

	var source := NifSource.new()
	if not source.load(PackedByteArray(result["data"])):
		push_warning("EsmReferencePhysicaliser: %s failed to parse (%s)" % [model_path, source.get_last_error()])
		return false

	var visual: Node3D = await NifTreeBuilderScript.build(source, false)
	if visual == null:
		return false
	visual.name = "NifServerVisual"
	visual.set_meta("nif_path", model_path)
	visual.set_meta("nif_block_count", source.get_block_count())
	root.add_child(visual)
	return true


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
	return physicalise(reference, null, false)

## PackedScene only serializes descendants that have an owner in the scene
## being packed. Physicalisation builds the visual hierarchy before the root
## is attached, so ownership must be assigned recursively after attachment or
## editor previews reopen as an empty typed node.
func _set_owner_recursive(node: Node, owner: Node) -> void:
	node.owner = owner
	for child in node.get_children():
		_set_owner_recursive(child, owner)

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

func _world_transform(position: Vector3, rotation: Vector3, scale: float) -> Transform3D:
	var authored_basis := _authored_rotation_basis(rotation)
	var authored := Transform3D(authored_basis * Basis().scaled(Vector3.ONE * scale), position)
	var z_up_to_y_up := Basis(Vector3.RIGHT, deg_to_rad(-90.0))
	return Transform3D(z_up_to_y_up, Vector3.ZERO) * authored

## Gamebryo stores REFR Euler angles in radians. The established NV path uses
## the negated authored angles in X/Y/Z composition order.
func _authored_rotation_basis(rotation: Vector3) -> Basis:
	var bx := Basis(Vector3.RIGHT, -rotation.x)
	var by := Basis(Vector3.UP, -rotation.y)
	var bz := Basis(Vector3.BACK, -rotation.z)
	return bx * by * bz
