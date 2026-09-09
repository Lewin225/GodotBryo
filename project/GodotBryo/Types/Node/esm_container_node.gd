@tool
@icon("res://GodotBryo/Types/Node/container.svg")
class_name EsmContainerNode
extends EsmNode

const InventoryComponentScript := preload("res://gamebryo/inventory_component.gd")
@export_tool_button("Activate") var activate_button: Callable = activate
var inventory_component: InventoryComponent

func build_visual(resolver: GamebryoMeshResolver) -> void:
	var container_ref := reference as ContainerReference
	if container_ref == null or not container_ref.base is ContainerBase:
		return
	var base := container_ref.base as ContainerBase
	build_dynamic_visual(resolver, base.model_path)
	_ensure_inventory_component()
	var authored := container_ref.contents if not container_ref.contents.is_empty() else base.items
	inventory_component.set_authored_entries(authored)
	_add_sound("OpenSound", resolver, base.open_sound_path)
	_add_sound("CloseSound", resolver, base.close_sound_path)
	_add_sound("RandomSound", resolver, base.random_sound_path)
	_visual_built = true

func activate(_actor: Node = null) -> Dictionary:
	var container_ref := reference as ContainerReference
	if container_ref == null: return {}
	var opening := not container_ref.is_open
	var player := get_node_or_null("AnimationPlayer") as AnimationPlayer
	var animation_name := "Open" if opening else "Close"
	if player != null and player.has_animation(animation_name): player.play(animation_name)
	_play_sound("OpenSound" if opening else "CloseSound")
	container_ref.is_open = opening
	return {}

func _ensure_inventory_component() -> void:
	if inventory_component != null and is_instance_valid(inventory_component): return
	inventory_component = get_node_or_null(^"InventoryComponent") as InventoryComponent
	if inventory_component == null:
		inventory_component = InventoryComponentScript.new()
		inventory_component.name = "InventoryComponent"
		add_child(inventory_component)

func _add_sound(node_name: String, resolver: GamebryoMeshResolver, path: String) -> void:
	if path.is_empty(): return
	var stream := resolver.load_sound(path)
	if stream == null: return
	var player := AudioStreamPlayer3D.new()
	player.name = node_name
	player.stream = stream.duplicate()
	add_child(player)

func _play_sound(node_name: String) -> void:
	var player := get_node_or_null(node_name) as AudioStreamPlayer3D
	if player != null: player.play()
