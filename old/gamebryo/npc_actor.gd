@tool
class_name NPCActor
extends GamebryoActor

signal actor_load_started
signal actor_load_progress(progress: float, stage: String)
signal actor_load_completed
signal actor_load_failed(message: String)

const GameDataConfigScript := preload("res://game_data_config.gd")
const FacialAnimationControllerScript := preload("res://gamebryo/facial_animation_controller.gd")
const InventoryComponentScript := preload("res://gamebryo/inventory_component.gd")

## Issue #52 chunk 5 (+ later): thin leaf for a placed NPC_ (enginedocs/
## nv_class_hierarchy.md's "Actors" section — "a rich shared GamebryoActor
## base... with genuinely thin NPCActor/CreatureActor leaves"). Equipment is
## an explicit typed resource graph; actor runtime state, dialogue, and
## pickpocket-able state remain future composition work.
##
## `npc_actor.tscn` (this script's own scene) is the hand-authored actor
## template GamebryoObjectRegistry._build_npc() instantiates for every real
## placed NPC_ — a deliberate exception to this codebase's "everything
## built purely in code" convention, since actors are meaningfully more
## complex (skeleton/animation, and eventually armor/items) than anything
## else placed in the world.
##
## populate() builds ALL of its own generated content (skeleton, meshes,
## LocomotionAnimationPlayer) inside one dedicated child container, named
## BODY_NODE_NAME ("Body") — never directly under `self`. This is
## deliberate: populate()/_editor_apply_actor_data() need to freely clear and rebuild
## whatever they generated on a reload, but must NOT touch anything
## hand-authored directly in npc_actor.tscn as a SIBLING of Body (e.g. a
## future animation controller wired to LocomotionAnimationPlayer via a NodePath,
## or armor/weapon attach markers) — a real problem hit in practice: an
## earlier version of this file cleared every child indiscriminately,
## which would destroy any such hand-authored node on every reload. A
## NodePath into Body (e.g. "Body/LocomotionAnimationPlayer") stays valid
## across rebuilds even though the actual AnimationPlayer instance gets
## destroyed and recreated each time, since NodePath resolution happens at
## the moment it's used, not once at authoring time — so hand-authored
## scaffolding CAN safely reference generated content by path, just not
## hold a direct node reference to it.
##
## Also a standalone @tool preview: open npc_actor.tscn directly, pick a
## preset (or type a custom base_form_id) in the Inspector, press
## "Import Actor Data From Preset Or FormID", edit the typed resource graph,
## then press "Load Actor" — the exact same populate() method used by runtime
## construction then builds the preview, so there is no separate bespoke
## preview implementation to drift from what ships.

@export_enum("Custom", "Doc Mitchell (Goodsprings)") var preset: String = "Doc Mitchell (Goodsprings)"

## Only read when preset == "Custom". Hex NPC_ FormID, e.g. "0x00104C0C".
@export var custom_base_form_id: String = ""
@export var npc_record: NpcRecord:
	set(value):
		_disconnect_npc_record_signal()
		npc_record = value
		_connect_npc_record_signal()
		if is_inside_tree():
			_sync_inventory_from_record()
@export var equipment_state: EquipmentState:
	set(value):
		_disconnect_equipment_state_signals()
		equipment_state = value
		_connect_equipment_state_signals()
		if _active_record != null and _active_mesh_resolver != null and not _rebuilding:
			_rebuild_from_active_record()

## Bethesda hair NIFs commonly contain two authored submeshes (for example
## `sub0_Nohat` and `sub1_Hat`).  The HAIR record selects the NIF; this state
## selects which of that NIF's variants is currently visible.
@export var wearing_hat: bool = false:
	set(value):
		wearing_hat = value
		_apply_hair_variant()

## Gore-cap meshes are authored as ordinary race head parts, but represent
## damaged/exposed anatomy rather than the normal nude body appearance.
@export var show_gore: bool = false:
	set(value):
		show_gore = value
		_apply_gore_visibility()

@export_tool_button("Import Actor Data From Preset Or FormID") var load_button: Callable = _editor_load
@export_tool_button("Load Actor") var apply_data_button: Callable = _editor_apply_actor_data
@export_tool_button("Unload Actor") var unload_button: Callable = _editor_unload_actor
## Reconciles only the generated Equipment child using the currently loaded
## record. This deliberately exercises the same dynamic path used when the
## EquipmentState resource changes, without rebuilding the actor body.
@export_tool_button("Refresh Equipment") var refresh_equipment_button: Callable = _editor_refresh_equipment

const PRESET_FORM_IDS := {
	"Doc Mitchell (Goodsprings)": 0x00104C0C,
}

## Name of the dedicated child container populate() builds all of its own
## generated content into — see this file's own top doc comment.
const BODY_NODE_NAME := "Body"

## Real movement locomotion .kf files -- confirmed against the actual
## Meshes/Update BSAs (native/tools/find_kf_animations.cpp): a bare .kf
## carries exactly one top-level NiControllerSequence with NO owning
## NiControllerManager (see nif_loader.cpp's own extract_sequence() doc
## comment for why that needed a native fix), meant to be applied against a
## skeleton loaded from elsewhere -- unlike a self-contained NIF's own
## embedded animation (populate_skeleton()'s
## _populate_skeleton_animation_player()).
##
## The base "mt" set and the currently equipped weapon family are imported
## via GamebryoMeshResolver.list_files_with_prefix(); unrelated weapon
## families are left unloaded. Real clips are kept under their own names (no
## remapping to invented aliases like "forward"/"backward" -- confirmed via
## review that Godot's AnimationLibrary rejects "/" in a name outright, so
## a file's real relative path becomes its clip name with "/" -> "__").
## set_move_input() remains a compatibility hook for the future locomotion
## controller; everything stays loaded and available without being played by
## an unfinished generated blend tree.
const LOCOMOTION_FOLDER_PREFIX := "meshes/characters/_male/locomotion/"
const THIRD_PERSON_ANIMATION_FOLDER_PREFIX := "meshes/characters/_male/"

var _facial_controller: Node = null
var _is_female := false
var _is_child := false
var _active_record: NpcRecord = null
var _active_mesh_resolver: GamebryoMeshResolver = null
var _rebuilding := false
var _standalone_preview := false
var _weapon_animation_player: AnimationPlayer = null
var _active_weapon: WeaponRecord = null
var _weapon_clip_names: Array[String] = []
var _animation_alias_names: Array[String] = []
var _observed_equipment_resources: Array[Resource] = []
var hair_no_hat_meshes: Array[MeshInstance3D] = []
var hair_hat_meshes: Array[MeshInstance3D] = []
var gore_meshes: Array[MeshInstance3D] = []
var inventory_component: Node = null
var _observed_inventory_component: Node = null
var _observed_npc_record: NpcRecord = null
var _observed_npc_inventory_entries: Array[InventoryEntryResource] = []
var _soft_load_generation := 0
var _soft_loading := false
var _soft_prepare_pool: GamebryoResolverPool = null
var _soft_prepare_context: GamebryoResolveContext = null
var _soft_prepare_task := -1
var load_progress := 0.0
var load_stage := "Idle"

func _ready() -> void:
	# Exported Resource fields can be restored without going through the
	# setter in every editor/runtime load path. Reconnect defensively here.
	_connect_equipment_state_signals()
	_ensure_inventory_component()
	_connect_npc_record_signal()
	_sync_inventory_from_record()

func _exit_tree() -> void:
	if _soft_prepare_task != -1:
		WorkerThreadPool.wait_for_task_completion(_soft_prepare_task)
		_soft_release_prepare_context(_active_mesh_resolver)
	_soft_load_generation += 1
	_soft_loading = false

func _ensure_inventory_component() -> Node:
	if _observed_inventory_component != null and _observed_inventory_component != inventory_component:
		if is_instance_valid(_observed_inventory_component) and _observed_inventory_component.is_connected("inventory_changed", _on_inventory_changed):
			_observed_inventory_component.disconnect("inventory_changed", _on_inventory_changed)
		_observed_inventory_component = null
	if inventory_component != null and is_instance_valid(inventory_component):
		_connect_inventory_signal()
		return inventory_component
	inventory_component = get_node_or_null(^"InventoryComponent")
	if inventory_component == null:
		inventory_component = InventoryComponentScript.new()
		inventory_component.name = "InventoryComponent"
		add_child(inventory_component)
		if Engine.is_editor_hint() and get_tree().edited_scene_root != null:
			inventory_component.owner = get_tree().edited_scene_root
	_connect_inventory_signal()
	return inventory_component

func _connect_inventory_signal() -> void:
	if inventory_component == null or not is_instance_valid(inventory_component):
		return
	if not inventory_component.is_connected("inventory_changed", _on_inventory_changed):
		inventory_component.connect("inventory_changed", _on_inventory_changed)
	_observed_inventory_component = inventory_component

func _on_inventory_changed() -> void:
	_project_equipment_from_inventory()

func _project_equipment_from_inventory() -> void:
	if inventory_component == null or not is_instance_valid(inventory_component):
		return
	var projected := EquipmentState.new()
	for entry in inventory_component.get_equipped_entries():
		if entry.item_record is ArmorRecord:
			projected.armor_records.append(entry.item_record)
		elif entry.item_record is WeaponRecord:
			# EquipmentState currently exposes one active weapon. Preserve the
			# authored inventory order and let the last equipped weapon win.
			projected.weapon = entry.item_record
		else:
			projected.diagnostics.append("Equipped entry has no supported visual record: 0x%08X" % entry.item_form_id)
	equipment_state = projected

func _connect_npc_record_signal() -> void:
	if npc_record == null:
		return
	_observed_npc_record = npc_record
	if not npc_record.changed.is_connected(_on_npc_record_changed):
		npc_record.changed.connect(_on_npc_record_changed)
	for entry in npc_record.inventory:
		if entry == null or entry.changed.is_connected(_on_npc_record_changed):
			continue
		entry.changed.connect(_on_npc_record_changed)
		_observed_npc_inventory_entries.append(entry)

func _disconnect_npc_record_signal() -> void:
	if _observed_npc_record != null and is_instance_valid(_observed_npc_record):
		if _observed_npc_record.changed.is_connected(_on_npc_record_changed):
			_observed_npc_record.changed.disconnect(_on_npc_record_changed)
	_observed_npc_record = null
	for entry in _observed_npc_inventory_entries:
		if is_instance_valid(entry) and entry.changed.is_connected(_on_npc_record_changed):
			entry.changed.disconnect(_on_npc_record_changed)
	_observed_npc_inventory_entries.clear()

func _on_npc_record_changed() -> void:
	_sync_inventory_from_record()

func _sync_inventory_from_record() -> void:
	if npc_record == null:
		return
	_ensure_inventory_component().set_authored_entries(npc_record.inventory)

func _connect_equipment_state_signals() -> void:
	_disconnect_equipment_state_signals()
	if equipment_state == null:
		return
	var resources: Array[Resource] = [equipment_state]
	for armor in equipment_state.armor_records:
		_add_equipment_resource(resources, armor)
		if armor != null:
			_add_equipment_resource(resources, armor.biped_model_list)
			if armor.biped_model_list != null:
				for addon in armor.biped_model_list.entries:
					_add_equipment_resource(resources, addon)
	_add_equipment_resource(resources, equipment_state.weapon)
	if equipment_state.weapon != null:
		_add_equipment_resource(resources, equipment_state.weapon.biped_model_list)
		if equipment_state.weapon.biped_model_list != null:
			for addon in equipment_state.weapon.biped_model_list.entries:
				_add_equipment_resource(resources, addon)
	for resource in resources:
		if resource == null or resource.changed.is_connected(_on_equipment_resource_changed):
			continue
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
	# Resource.changed covers edits to the state and its nested typed records.
	# The setter remains the path for replacing the whole EquipmentState.
	_connect_equipment_state_signals()
	if _active_record != null and _active_mesh_resolver != null and not _rebuilding:
		_rebuild_from_active_record()

## Real NPC_ construction — the full humanoid assembly confirmed real in
## issue #52 chunks 2/4. `placement["model"]` is the NPC_'s own MODL (the
## shared skeleton path, e.g. Characters\_Male\Skeleton.NIF — see
## EsmFile::get_cell_actors()'s doc comment, NOT a self-contained mesh);
## `placement["race_form_id"]`/`["is_female"]` resolve the real
## gender-selected body-part list via esm.get_race_body_parts() — RACE's
## own ESM-declared INDX blocks, not a guessed convention. Deliberately no
## head/face mesh (FaceGen is out of scope for this issue).
##
## Also wires a real LocomotionAnimationPlayer holding EVERY real file
## found under LOCOMOTION_FOLDER_PREFIX (see _discover_locomotion_clips())
## The imported clips are intentionally exposed directly through that player;
## generated AnimationTree blending is deferred until the animation layering
## and partial-body behavior are properly understood. Animation only: this
## does NOT move the actor through the world (no CharacterBody3D
## — see GamebryoActor's own doc comment for why that's deferred); a caller
## wanting real translation drives that separately and feeds the same
## direction into set_move_input().
func populate(placement: Dictionary, esm: EsmReader, mesh_resolver: GamebryoMeshResolver) -> void:
	var skeleton_path: String = placement.get("model", "")
	var race_form_id := int(placement.get("race_form_id", 0))
	if skeleton_path == "" or race_form_id == 0:
		return
	_is_female = bool(placement.get("is_female", false))
	_is_child = bool(placement.get("is_child", false))
	var body_part_paths: Array = []
	if esm != null:
		for part in esm.get_race_body_parts(race_form_id, _is_female):
			var body_path := String(part.get("model", ""))
			if not body_path.is_empty():
				body_part_paths.append({"model_path": body_path, "race_part_index": int(part.get("index", -1))})
	else:
		for part in placement.get("body_parts", []):
			var body_path := String(part.model_path if part is RacePartResource else part.get("model", ""))
			if not body_path.is_empty():
				body_part_paths.append({"model_path": body_path, "race_part_index": part.index})
	if body_part_paths.is_empty():
		return
	var head_part_specs: Array = []
	if placement.has("head_parts"):
		for part in placement.get("head_parts", []):
			var path := String(part.model_path if part is RacePartResource else part.get("model", ""))
			if not path.is_empty():
				head_part_specs.append({"model_path": path, "part_type": String(part.part_type if part is RacePartResource else part.get("part_type", ""))})
	var hair: Variant = placement.get("hair")
	if hair is HairRecord and not hair.model_path.is_empty():
		head_part_specs.append({"model_path": hair.model_path, "part_type": "hair"})
	var eyes: Variant = placement.get("eyes")
	if eyes is EyesRecord and not eyes.model_path.is_empty():
		head_part_specs.append({"model_path": eyes.model_path, "part_type": "eyes"})

	var body := _rebuild_body_container()
	var face_gen: FaceGenData = placement.get("face_gen") if placement.get("face_gen") is FaceGenData else null
	var skeleton := mesh_resolver.populate_humanoid_skeleton(body, skeleton_path, body_part_paths, head_part_specs, face_gen)
	if skeleton == null:
		return
	var initial_equipment: EquipmentState = equipment_state
	var placement_equipment: Variant = placement.get("equipment_state")
	if placement_equipment is EquipmentState:
		initial_equipment = placement_equipment
	refresh_equipment(mesh_resolver, initial_equipment)
	var facial_assembly := skeleton.get_node_or_null(^"FacialHeadAssembly")
	if facial_assembly == null:
		push_error("NPCActor: humanoid skeleton has no FacialHeadAssembly")
		return
	_track_hair_meshes(body)
	_track_gore_meshes(body)
	_facial_controller = FacialAnimationControllerScript.new()
	_facial_controller.name = "FacialAnimationController"
	facial_assembly.add_child(_facial_controller)
	var facial_meshes: Array = facial_assembly.find_children("*", "MeshInstance3D", true, false)
	# The base head is the one facial surface that remains a skinned sibling
	# of the head-part attachment. Include it explicitly; body/armor meshes
	# must not become part of the facial controller's target set.
	for candidate in body.find_children("*", "MeshInstance3D", true, false):
		var model_path := String(candidate.get_meta("gamebryo_model_path", "")).to_lower()
		if "characters\\head\\head" in model_path and not facial_meshes.has(candidate):
			facial_meshes.append(candidate)
	_facial_controller.configure(facial_meshes)

	var clips := _discover_locomotion_clips(mesh_resolver, _active_weapon)
	var player := mesh_resolver.populate_locomotion_animations(body, skeleton, clips)
	_register_animation_aliases(player, mesh_resolver, _active_weapon)
	_apply_possessed_first_person_render_mode()
	_weapon_animation_player = player
	_weapon_clip_names = _discovered_weapon_clip_names.duplicate()
	var animation_component: Node = get_node_or_null(^"ActorAnimationComponent")
	if animation_component != null:
		animation_component.set_equipped_weapon(_active_weapon)
	if player == null:
		return
	if animation_component != null:
		animation_component.play_default_idle()


func get_facial_controller() -> Node:
	return _facial_controller

func set_facial_morph(name: String, weight: float) -> bool:
	return _facial_controller != null and _facial_controller.set_morph_weight(name, weight)

func set_phoneme(name: String, weight: float = 1.0) -> bool:
	return _facial_controller != null and _facial_controller.set_phoneme(name, weight)

func set_expression(name: String, weight: float = 1.0) -> bool:
	return _facial_controller != null and _facial_controller.set_expression(name, weight)

## Plays one exact third-person weapon action from the shared authored clip
## library. Missing clips are deliberately strict: no cross-family fallback is
## allowed because a visually plausible substitute can represent the wrong
## grip, hand, or weapon behavior.
func _track_hair_meshes(body: Node) -> void:
	hair_no_hat_meshes.clear()
	hair_hat_meshes.clear()
	for child in body.find_children("*", "MeshInstance3D", true, false):
		if String(child.get_meta("gamebryo_head_part_type", "")) != "hair":
			continue
		match String(child.get_meta("gamebryo_hair_variant", "")):
			"no_hat": hair_no_hat_meshes.append(child)
			"hat": hair_hat_meshes.append(child)
	_apply_hair_variant()

func _apply_hair_variant() -> void:
	for mesh in hair_no_hat_meshes:
		if is_instance_valid(mesh):
			mesh.visible = not wearing_hat
	for mesh in hair_hat_meshes:
		if is_instance_valid(mesh):
			mesh.visible = wearing_hat

func _track_gore_meshes(body: Node) -> void:
	gore_meshes.clear()
	for child in body.find_children("*", "MeshInstance3D", true, false):
		var texture_path := String(child.get_meta("gamebryo_texture_path", "")).to_lower().replace("/", "\\")
		if texture_path.begins_with("textures\\gore\\") or texture_path.contains("\\gore\\"):
			gore_meshes.append(child)
	_apply_gore_visibility()

func _apply_gore_visibility() -> void:
	for mesh in gore_meshes:
		if is_instance_valid(mesh):
			mesh.visible = show_gore

## Resource-driven equivalent of populate(). The factory owns ESM decoding;
## this node only consumes the typed appearance graph.
func populate_from_record(record: NpcRecord, mesh_resolver: GamebryoMeshResolver) -> void:
	npc_record = record
	_active_record = record
	_active_mesh_resolver = mesh_resolver
	_sync_inventory_from_record()
	if record == null or record.race == null:
		return
	var placement := {
		"model": record.model_path,
		"race_form_id": record.race.form_id,
		"is_female": record.is_female,
		"is_child": record.is_child,
		"editor_id": record.editor_id,
		"base_form_id": record.form_id,
		"body_parts": record.race.body_parts(record.is_female),
		"head_parts": record.race.head_parts(record.is_female),
		"hair": record.hair,
		"eyes": record.eyes,
		"face_gen": record.face_gen,
		"equipment_state": equipment_state,
	}
	populate(placement, null, mesh_resolver)
	_apply_race_skin_overrides(record, mesh_resolver)
	_apply_equipment_body_coverage(get_node_or_null(^"Body"))

func _rebuild_from_active_record() -> void:
	if _active_record == null or _active_mesh_resolver == null:
		return
	_rebuilding = true
	refresh_equipment(_active_mesh_resolver)
	_rebuilding = false

## Reconciles only the generated equipment subtree. The Body, Skeleton3D,
## facial assembly, animation players, and all editor-facing actor state stay
## alive so changing clothes cannot reset an actor's pose or morph weights.
func refresh_equipment(mesh_resolver: GamebryoMeshResolver = null, state_override: EquipmentState = null) -> void:
	var resolver := mesh_resolver if mesh_resolver != null else _active_mesh_resolver
	var body := get_node_or_null(NodePath(BODY_NODE_NAME))
	var skeleton: Skeleton3D = body.get_node_or_null(^"Skeleton3D") if body != null else null
	if body == null or skeleton == null or resolver == null:
		return
	_remove_weapon_animation_clips()
	var old_equipment := body.get_node_or_null(^"Equipment")
	if old_equipment != null:
		old_equipment.free()
	var equipment := Node3D.new()
	equipment.name = "Equipment"
	body.add_child(equipment)
	var state := equipment_state if state_override == null else state_override
	_active_weapon = state.weapon if state != null else null
	var animation_component: Node = get_node_or_null(^"ActorAnimationComponent")
	if animation_component != null:
		animation_component.set_equipped_weapon(_active_weapon)
	for diagnostic in resolver.populate_equipment(equipment, skeleton, state, _is_female):
		push_warning("NPCActor equipment: %s" % diagnostic)
	if Engine.is_editor_hint():
		_own_recursive(equipment)
	_apply_equipment_body_coverage(body)
	_apply_possessed_first_person_render_mode()
	if _weapon_animation_player != null:
		var clips := _discover_locomotion_clips(resolver, _active_weapon)
		resolver.populate_locomotion_animations(body, skeleton, clips, _weapon_animation_player)
		_register_animation_aliases(_weapon_animation_player, resolver, _active_weapon)
		_weapon_clip_names = _discovered_weapon_clip_names.duplicate()
		if animation_component != null:
			animation_component.set_equipped_weapon(_active_weapon)
			animation_component.play_default_idle()

func _remove_weapon_animation_clips() -> void:
	if _weapon_animation_player == null:
		_weapon_clip_names.clear()
		return
	_weapon_animation_player.stop()
	var library := _weapon_animation_player.get_animation_library("")
	for clip_name in _weapon_clip_names:
		if library.has_animation(clip_name):
			library.remove_animation(clip_name)
	_weapon_clip_names.clear()

func _apply_standalone_preview_orientation() -> void:
	if not _standalone_preview:
		return
	var body := get_node_or_null(NodePath(BODY_NODE_NAME))
	if body != null:
		body.rotation_degrees.x = -90

func _apply_equipment_body_coverage(body: Node) -> void:
	if body == null:
		return
	var occupied := 0
	for child in body.find_children("*", "MeshInstance3D", true, false):
		# Gore-cap submeshes can carry the same nude-body metadata as their
		# source body NIF. They are a separate damage visual, however, and
		# must remain controlled only by show_gore rather than being restored
		# by the ordinary equipment-coverage pass.
		if gore_meshes.has(child):
			continue
		if bool(child.get_meta("gamebryo_nude_body", false)):
			child.visible = bool(child.get_meta("gamebryo_nude_body_original_visible", true))
	for child in body.find_children("*", "MeshInstance3D", true, false):
		if bool(child.get_meta("gamebryo_equipment", false)):
			occupied |= int(child.get_meta("gamebryo_equipment_biped_flags", 0))
	# The race body collection's authored model roles are the confirmed coarse
	# coverage targets. Keep gore/caps independent: they are not nude-body
	# replacements and remain governed by show_gore.
	for child in body.find_children("*", "MeshInstance3D", true, false):
		if int(child.get_meta("gamebryo_race_body_part_index", -1)) < 0:
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

func _apply_race_skin_overrides(record: NpcRecord, mesh_resolver: GamebryoMeshResolver) -> void:
	if record == null or record.race == null:
		return
	var overrides: Dictionary = {}
	for part in record.race.body_parts(record.is_female) + record.race.head_parts(record.is_female):
		if part.model_path.is_empty() or part.icon_path.is_empty():
			continue
		var icon := part.icon_path
		if not icon.to_lower().begins_with("textures\\"):
			icon = "textures\\" + icon
		overrides[part.model_path.to_lower()] = icon
	for child in _generated_mesh_instances():
		var model_path := String(child.get_meta("gamebryo_model_path", "")).to_lower()
		var source_texture := String(child.get_meta("gamebryo_texture_path", "")).to_lower()
		if not overrides.has(model_path) or not source_texture.begins_with("textures\\characters\\"):
			continue
		var material := child.get_active_material(0)
		if material == null or not material is StandardMaterial3D:
			continue
		var replacement: StandardMaterial3D = material.duplicate()
		replacement.albedo_texture = mesh_resolver.load_texture(overrides[model_path])
		child.material_override = replacement

func _generated_mesh_instances() -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	var body := get_node_or_null(NodePath(BODY_NODE_NAME))
	if body == null:
		return result
	for child in body.find_children("*", "MeshInstance3D", true, false):
		result.append(child)
	return result

## Clears and recreates the Body container (see this file's own top doc
## comment) — the ONLY thing populate() ever destroys, leaving every
## sibling (hand-authored scaffolding saved directly in npc_actor.tscn)
## untouched. Immediate free, not queue_free() -- same "avoids a same-name
## collision on reload" reasoning nif_viewer.gd's own doc comment gives for
## its identical pattern.
func _rebuild_body_container() -> Node3D:
	var existing := get_node_or_null(NodePath(BODY_NODE_NAME))
	if existing:
		remove_child(existing)
		existing.free()
	var body := Node3D.new()
	body.name = BODY_NODE_NAME
	add_child(body)
	return body

## Discovers every real .kf under LOCOMOTION_FOLDER_PREFIX (no hand-picked
## subset -- see this file's own doc comment on LOCOMOTION_FOLDER_PREFIX)
## and maps each to { real_relative_path_with_"__"_separators: load_path }.
## Same naming convention project/_diag/_diag_locomotion_review.gd uses
## (kept identical deliberately, so a clip name found there matches one
## found here exactly) -- "/" is stripped down to the LOCOMOTION_FOLDER_PREFIX's
## own subfolders (e.g. "male/mtforward.kf" -> "male__mtforward.kf";
## "mtidle.kf" at the shared top level stays "mtidle.kf" unprefixed).
var _discovered_weapon_clip_names: Array[String] = []

func _discover_locomotion_clips(mesh_resolver: GamebryoMeshResolver, weapon: WeaponRecord = null) -> Dictionary:
	var clips := {}
	_discovered_weapon_clip_names.clear()
	for entry in mesh_resolver.list_files_with_prefix(LOCOMOTION_FOLDER_PREFIX):
		var e := String(entry)
		if not e.ends_with(".kf"):
			continue
		var rel := e.trim_prefix(LOCOMOTION_FOLDER_PREFIX)
		var filename := rel.get_file().to_lower()
		if weapon == null:
			if not filename.begins_with("mt"):
				continue
		elif not filename.begins_with("mt") and not filename.begins_with(weapon.animation_family):
			continue
		var load_path := "characters\\_male\\locomotion\\" + rel.replace("/", "\\")
		clips[rel.replace("/", "__")] = load_path
		if weapon != null and filename.begins_with(weapon.animation_family):
			_discovered_weapon_clip_names.append(rel.replace("/", "__"))
	if weapon == null:
		return clips
	var desired_actions: Dictionary = {}
	for action in ["equip", "unequip", "idle", "block", "holster", "attack", "reload", "grip"]:
		var action_clip := weapon.action_clip_name(action)
		if not action_clip.is_empty():
			desired_actions[action_clip] = true
	for entry in mesh_resolver.list_files_with_prefix(THIRD_PERSON_ANIMATION_FOLDER_PREFIX):
		var e := String(entry).to_lower()
		if not e.ends_with(".kf") or "/locomotion/" in e:
			continue
		var rel := e.trim_prefix(THIRD_PERSON_ANIMATION_FOLDER_PREFIX)
		if rel.contains("/"):
			continue
		var filename := rel.get_file()
		if not desired_actions.has(filename):
			continue
		var clip_name := rel.replace("/", "__")
		var load_path := "characters\\_male\\" + rel.replace("/", "\\")
		clips[clip_name] = load_path
		_discovered_weapon_clip_names.append(clip_name)
	return clips


## Adds stable, per-actor names for the hand-authored AnimationTree. The
## source names remain the real relative KF paths and remain cache keys; these
## aliases only exist in this actor's AnimationLibrary.
func _register_animation_aliases(player: AnimationPlayer, _mesh_resolver: GamebryoMeshResolver, weapon: WeaponRecord = null) -> void:
	if player == null:
		return
	var library := player.get_animation_library("")
	if library == null:
		return
	for alias in _animation_alias_names:
		if library.has_animation(alias):
			library.remove_animation(alias)
	_animation_alias_names.clear()
	_add_blank_animation_alias(library, "animation_noop")
	var family := "child" if _is_child else ("female" if _is_female else "male")
	var direction_names := {
		"forward": "mtforward.kf",
		"backward": "mtbackward.kf",
		"left": "mtleft.kf",
		"right": "mtright.kf",
	}
	for direction in direction_names:
		var walk_source := _first_animation(player, [family + "__" + direction_names[direction], direction_names[direction]])
		_add_animation_alias(library, "locomotion_walk_" + direction, walk_source)
		var fast_source := ""
		var weapon_source := ""
		if weapon != null:
			var fast_name: String = weapon.animation_family + "fast" + direction + ".kf"
			fast_source = _first_animation(player, [fast_name])
			weapon_source = _first_animation(player, [weapon.animation_family + direction + ".kf"])
		else:
			# The filtered weapon branch still needs useful motion while
			# unarmed. Reuse the actor's normal directional locomotion clip;
			# the AnimationTree's upper-body filter prevents it from taking
			# ownership of the legs a second time.
			weapon_source = walk_source
		_add_animation_alias_or_blank(library, "locomotion_fast_" + direction, fast_source)
		_add_animation_alias_or_blank(library, "weapon_" + direction, weapon_source)
	_add_animation_alias(library, "locomotion_idle", _first_animation(player, ["mtidle.kf", family + "__mtidle.kf"]))
	for action in ["idle", "equip", "unequip", "block", "holster", "attack", "reload", "grip"]:
		var action_source := weapon.action_clip_name(action) if weapon != null else ""
		_add_animation_alias_or_blank(library, "weapon_" + action, _first_animation(player, [action_source]))

func _first_animation(player: AnimationPlayer, candidates: Array) -> String:
	for candidate in candidates:
		var name := String(candidate)
		if not name.is_empty() and player.has_animation(name):
			return name
	return ""

func _add_animation_alias(library: AnimationLibrary, alias: String, source: String) -> void:
	if source.is_empty() or library.has_animation(alias):
		return
	var animation := library.get_animation(source)
	if animation == null:
		return
	library.add_animation(alias, animation)
	_animation_alias_names.append(alias)

func _add_animation_alias_or_blank(library: AnimationLibrary, alias: String, source: String) -> void:
	if source.is_empty():
		_add_blank_animation_alias(library, alias)
	else:
		_add_animation_alias(library, alias, source)

func _add_blank_animation_alias(library: AnimationLibrary, alias: String) -> void:
	if library.has_animation(alias):
		return
	var animation := Animation.new()
	animation.length = 0.1
	animation.loop_mode = Animation.LOOP_LINEAR
	library.add_animation(alias, animation)
	_animation_alias_names.append(alias)

## Compatibility hook for callers that already provide movement input. The
## actor currently exposes the imported clips through AnimationPlayer only;
## locomotion selection/blending will be added once the real partial-body
## animation behavior is resolved.
func set_move_input(input: Vector2) -> void:
	pass

func _merge_inspector_inventory_state(loaded: NpcRecord, configured: NpcRecord) -> void:
	if loaded == null or configured == null:
		return
	for index in loaded.inventory.size():
		var loaded_entry := loaded.inventory[index]
		var configured_entry: InventoryEntryResource = null
		if index < configured.inventory.size() and configured.inventory[index].item_form_id == loaded_entry.item_form_id:
			configured_entry = configured.inventory[index]
		else:
			for candidate in configured.inventory:
				if candidate.item_form_id == loaded_entry.item_form_id:
					configured_entry = candidate
					break
		if configured_entry == null:
			continue
		loaded_entry.count = configured_entry.count
		loaded_entry.instance_id = configured_entry.instance_id
		loaded_entry.source_form_id = configured_entry.source_form_id
		loaded_entry.source_index = configured_entry.source_index
		loaded_entry.is_equipped = configured_entry.is_equipped

## Editor data-load entry point. Opens FalloutNV.esm and resolves the preset
## FormID into npc_record, but deliberately does not build the actor. This
## leaves the typed resource graph available for inspection/editing before
## Apply Actor Data performs construction.
func _editor_load() -> void:
	_standalone_preview = true
	var esm := EsmReader.new()
	var data_dir := String(GameDataConfigScript.resolve().get("data_dir", ""))
	if not esm.open(data_dir + GameDataConfigScript.ESM_FILE):
		push_error("NPCActor: could not open FalloutNV.esm")
		return

	var form_id: int = PRESET_FORM_IDS.get(preset, 0)
	if preset == "Custom":
		form_id = custom_base_form_id.hex_to_int()
	if form_id == 0:
		push_error("NPCActor: no base_form_id -- set custom_base_form_id (preset is Custom)")
		return

	var factory := EsmResourceFactory.new(esm)
	# Always use the factory's fresh record so every inventory entry has its
	# resolved item resource. Preserve mutable inspector state from the saved
	# record, especially is_equipped, across that refresh.
	var configured_record: NpcRecord = npc_record if npc_record != null and npc_record.form_id == form_id else null
	var record: NpcRecord = factory.load_npc(form_id)
	_merge_inspector_inventory_state(record, configured_record)
	if record == null:
		push_error("NPCActor: base_form_id 0x%X not found (or not an NPC_)" % form_id)
		return

	var resolver := GamebryoMeshResolver.new(data_dir)
	_active_record = null
	_active_mesh_resolver = resolver
	npc_record = record
	_sync_inventory_from_record()
	print("NPCActor: loaded actor data ", record.editor_id, " (0x%X)" % form_id)

## Editor construction entry point. Consumes the currently assigned typed
## npc_record, including inspector edits, and uses the same resource-driven
## population path as runtime actor construction.
func _editor_apply_actor_data() -> void:
	if npc_record == null:
		push_warning("NPCActor: import actor data or assign an NpcRecord before loading")
		return
	var resolver := _active_mesh_resolver
	if resolver == null:
		var data_dir := String(GameDataConfigScript.resolve().get("data_dir", ""))
		if data_dir.is_empty():
			push_error("NPCActor: no game data directory configured")
			return
		resolver = GamebryoMeshResolver.new(data_dir)
	# Project inventory while the actor is inactive so assigning the projected
	# EquipmentState cannot trigger a premature equipment-only refresh.
	_active_record = null
	_active_mesh_resolver = resolver
	_project_equipment_from_inventory()
	_start_soft_load(npc_record, resolver)
	return

	# NIF/REFR data is Z-up; Godot is Y-up. In a REAL placement this
	# correction comes for free from the cell's own root node
	# (world_streamer.gd's "refr_root" -- see that file's own comment), the
	# same way every other placed type relies on it rather than rotating
	# itself. A standalone preview has no such ancestor, so it's applied
	# here on Body specifically -- same "no cell root to inherit it from"
	# reasoning nif_viewer.gd's own doc comment gives for rotating its own
	# NifRoot child. Rotating Body specifically, not
	# `self`, keeps this purely a preview-only correction -- a real
	# placement's own populate() never applies it, so nothing here would
	# double-rotate once actors are wired into real cell loading.
	if Engine.is_editor_hint():
		for child in get_children():
			_own_recursive(child)

func _start_soft_load(record: NpcRecord, resolver: GamebryoMeshResolver) -> void:
	if _soft_loading:
		push_warning("NPCActor: an actor load is already in progress")
		return
	_soft_load_generation += 1
	_soft_loading = true
	load_progress = 0.0
	load_stage = "Starting"
	emit_signal("actor_load_started")
	_soft_load_actor(record, resolver, _soft_load_generation)

func _soft_load_actor(record: NpcRecord, resolver: GamebryoMeshResolver, generation: int) -> void:
	_rebuilding = true
	_active_record = record
	_active_mesh_resolver = resolver
	npc_record = record
	if record == null or record.race == null:
		_finish_soft_load(generation, false, "NPC record has no race")
		return

	var body := _rebuild_body_container()
	var body_parts: Array = []
	for part in record.race.body_parts(record.is_female):
		body_parts.append({"model_path": part.model_path, "race_part_index": part.index})
	var head_parts: Array = []
	for part in record.race.head_parts(record.is_female):
		head_parts.append({"model_path": part.model_path, "part_type": part.part_type})
	if record.hair != null and not record.hair.model_path.is_empty():
		head_parts.append({"model_path": record.hair.model_path, "part_type": "hair"})
	if record.eyes != null and not record.eyes.model_path.is_empty():
		head_parts.append({"model_path": record.eyes.model_path, "part_type": "eyes"})

	var nif_paths: Array[String] = [record.model_path]
	for part in body_parts:
		nif_paths.append(String(part.get("model_path", "")))
	for part in head_parts:
		nif_paths.append(String(part.get("model_path", "")))
	if not await _soft_prepare_nifs(resolver, nif_paths, generation):
		return
	_soft_stage(generation, 0.08, "Skeleton")
	var assembly := resolver.begin_humanoid_skeleton(body, record.model_path)
	if assembly.is_empty():
		_finish_soft_load(generation, false, "Could not build actor skeleton")
		return
	await get_tree().process_frame
	if not _soft_load_current(generation):
		return
	var skeleton: Skeleton3D = assembly["skeleton"]
	var facial_attachment: BoneAttachment3D = assembly["facial_attachment"]
	var nude_body: Node3D = assembly["nude_body"]
	var morphed_mesh_instances: Array = []

	for index in body_parts.size():
		_soft_stage(generation, 0.08 + 0.30 * float(index + 1) / maxf(body_parts.size(), 1), "Body")
		resolver.populate_humanoid_body_part(nude_body, skeleton, body_parts[index], morphed_mesh_instances)
		await get_tree().process_frame
		if not _soft_load_current(generation):
			return

	for index in head_parts.size():
		_soft_stage(generation, 0.38 + 0.30 * float(index + 1) / maxf(head_parts.size(), 1), "Head and FaceGen")
		resolver.populate_humanoid_head_part(body, skeleton, facial_attachment, head_parts[index], morphed_mesh_instances, record.face_gen)
		await get_tree().process_frame
		if not _soft_load_current(generation):
			return
	resolver.finish_humanoid_morphs(body, morphed_mesh_instances)

	_soft_stage(generation, 0.72, "Equipment")
	refresh_equipment(resolver, equipment_state)
	await get_tree().process_frame
	if not _soft_load_current(generation):
		return

	var facial_assembly := skeleton.get_node_or_null(^"FacialHeadAssembly")
	if facial_assembly == null:
		_finish_soft_load(generation, false, "Skeleton has no facial head assembly")
		return
	_track_hair_meshes(body)
	_track_gore_meshes(body)
	_facial_controller = FacialAnimationControllerScript.new()
	_facial_controller.name = "FacialAnimationController"
	facial_assembly.add_child(_facial_controller)
	var facial_meshes: Array = facial_assembly.find_children("*", "MeshInstance3D", true, false)
	for candidate in body.find_children("*", "MeshInstance3D", true, false):
		var model_path := String(candidate.get_meta("gamebryo_model_path", "")).to_lower()
		if "characters\\head\\head" in model_path and not facial_meshes.has(candidate):
			facial_meshes.append(candidate)
	_facial_controller.configure(facial_meshes)

	_soft_stage(generation, 0.86, "Animations")
	var clips := _discover_locomotion_clips(resolver, _active_weapon)
	var player := resolver.populate_locomotion_animations(body, skeleton, clips)
	_register_animation_aliases(player, resolver, _active_weapon)
	_weapon_animation_player = player
	_weapon_clip_names = _discovered_weapon_clip_names.duplicate()
	var animation_component: Node = get_node_or_null(^"ActorAnimationComponent")
	if animation_component != null:
		animation_component.set_equipped_weapon(_active_weapon)
		animation_component.play_default_idle()
	_apply_possessed_first_person_render_mode()
	_apply_race_skin_overrides(record, resolver)
	_apply_equipment_body_coverage(body)
	_apply_standalone_preview_orientation()
	await get_tree().process_frame
	if _soft_load_current(generation):
		_finish_soft_load(generation, true, "")

func _soft_stage(generation: int, progress: float, stage: String) -> void:
	if not _soft_load_current(generation):
		return
	load_progress = progress
	load_stage = stage
	emit_signal("actor_load_progress", progress, stage)

func _soft_load_current(generation: int) -> bool:
	return _soft_loading and generation == _soft_load_generation and is_inside_tree()

func _finish_soft_load(generation: int, success: bool, message: String) -> void:
	if generation != _soft_load_generation:
		return
	_soft_loading = false
	_rebuilding = false
	if success:
		load_progress = 1.0
		load_stage = "Ready"
		if Engine.is_editor_hint():
			for child in get_children():
				_own_recursive(child)
		emit_signal("actor_load_progress", load_progress, load_stage)
		emit_signal("actor_load_completed")
	else:
		load_stage = "Failed"
		emit_signal("actor_load_failed", message)
		push_error("NPCActor: soft load failed: %s" % message)

func _soft_prepare_nifs(resolver: GamebryoMeshResolver, paths: Array[String], generation: int) -> bool:
	_soft_stage(generation, 0.02, "Preparing NIF data")
	_soft_prepare_pool = GamebryoResolverPool.new(1)
	_soft_prepare_context = _soft_prepare_pool.checkout()
	if _soft_prepare_context == null:
		return true
	var holder: Array = [false]
	var unique_paths: Array[String] = []
	for path in paths:
		if not path.is_empty() and not unique_paths.has(path):
			unique_paths.append(path)
	_soft_prepare_task = WorkerThreadPool.add_task(func():
		for path in unique_paths:
			_soft_prepare_context.resolver.load_nif(path)
		holder[0] = true
	)
	while not WorkerThreadPool.is_task_completed(_soft_prepare_task):
		await get_tree().process_frame
		if not _soft_load_current(generation):
			WorkerThreadPool.wait_for_task_completion(_soft_prepare_task)
			_soft_release_prepare_context(resolver)
			return false
	WorkerThreadPool.wait_for_task_completion(_soft_prepare_task)
	_soft_release_prepare_context(resolver)
	return bool(holder[0])

func _soft_release_prepare_context(resolver: GamebryoMeshResolver) -> void:
	if _soft_prepare_context != null:
		resolver.merge_from(_soft_prepare_context.resolver)
		if _soft_prepare_pool != null:
			_soft_prepare_pool.checkin(_soft_prepare_context)
	_soft_prepare_context = null
	_soft_prepare_pool = null
	_soft_prepare_task = -1

## Editor reset entry point. Removes generated actor content and clears the
## imported record/equipment state; hand-authored children such as the
## AnimationTree and animation/inventory components remain in place for the
## next import.
func _editor_unload_actor() -> void:
	if _soft_prepare_task != -1:
		WorkerThreadPool.wait_for_task_completion(_soft_prepare_task)
		_soft_release_prepare_context(_active_mesh_resolver)
	_soft_load_generation += 1
	_soft_loading = false
	_rebuilding = true
	_active_record = null
	_active_mesh_resolver = null
	_active_weapon = null
	_weapon_animation_player = null
	_weapon_clip_names.clear()
	_animation_alias_names.clear()
	_facial_controller = null
	hair_no_hat_meshes.clear()
	hair_hat_meshes.clear()
	gore_meshes.clear()
	wearing_hat = false
	show_gore = false
	if inventory_component != null and is_instance_valid(inventory_component):
		inventory_component.clear()
	var animation_component: Node = get_node_or_null(^"ActorAnimationComponent")
	if animation_component != null:
		if animation_component.has_method("stop_action"):
			animation_component.stop_action()
		if animation_component.has_method("set_equipped_weapon"):
			animation_component.set_equipped_weapon(null)
	var animation_tree := get_node_or_null(^"AnimationTree") as AnimationTree
	if animation_tree != null:
		animation_tree.active = false
		animation_tree.anim_player = NodePath("")
	var body := get_node_or_null(NodePath(BODY_NODE_NAME))
	if body != null:
		body.free()
	npc_record = null
	equipment_state = null
	_standalone_preview = false
	_rebuilding = false
	load_progress = 0.0
	load_stage = "Idle"
	print("NPCActor: unloaded actor")


## Runtime construction entry point for an actor authored as a child of a
## controller (for example PlayerController). The serialized typed record is
## the source; this does not reopen the ESM or replace inspector-authored
## resource state.
func apply_runtime_actor_data() -> void:
	if npc_record == null:
		push_warning("NPCActor: no npc_record assigned for runtime construction")
		return
	var data_dir := String(GameDataConfigScript.resolve().get("data_dir", ""))
	if data_dir.is_empty():
		push_error("NPCActor: no game data directory configured")
		return
	var resolver := GamebryoMeshResolver.new(data_dir)
	_active_record = null
	_active_mesh_resolver = resolver
	_project_equipment_from_inventory()
	_standalone_preview = true
	_start_soft_load(npc_record, resolver)

## Editor testing entry point for the focused equipment update path. Load the
## actor once first; subsequent edits to the EquipmentState resource can be
## applied here without resetting the skeleton, facial assembly, animations,
## pose, or standalone preview orientation.
func _editor_refresh_equipment() -> void:
	if _active_record == null or _active_mesh_resolver == null:
		push_warning("NPCActor: load the actor before refreshing equipment")
		return
	# Inspector edits can be made on a nested entry without emitting through
	# every parent Resource. Explicitly rebuild the projection before using the
	# focused visual refresh path.
	_project_equipment_from_inventory()
	refresh_equipment(_active_mesh_resolver)
	if Engine.is_editor_hint():
		for child in get_children():
			_own_recursive(child)
	print("NPCActor: equipment refreshed")

func _own_recursive(node: Node) -> void:
	node.owner = get_tree().edited_scene_root
	for c in node.get_children():
		_own_recursive(c)
