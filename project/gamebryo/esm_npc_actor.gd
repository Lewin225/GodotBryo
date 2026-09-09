@tool
class_name EsmNpcActor
extends EsmNode

signal actor_load_started
signal actor_load_progress(progress: float, stage: String)
signal actor_load_completed
signal actor_load_failed(message: String)

const GameDataConfigScript := preload("res://game_data_config.gd")
const FacialAnimationControllerScript := preload("res://gamebryo/facial_animation_controller.gd")

## Issue #52 chunk 5 (+ later): thin leaf for a placed NPC_ (enginedocs/
## nv_class_hierarchy.md's "Actors" section — "a rich shared GamebryoActor
## base... with genuinely thin EsmNpcActor/CreatureActor leaves"). Equipment is
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
@export var equipment_state: EsmActorEquipmentState:
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
## EsmActorEquipmentState resource changes, without rebuilding the actor body.
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
var _active_record: NpcBase = null
var _active_mesh_resolver: GamebryoMeshResolver = null
var _rebuilding := false
var _standalone_preview := false
var _weapon_animation_player: AnimationPlayer = null
var _active_weapon: WeaponBase = null
var _weapon_clip_names: Array[String] = []
var _animation_alias_names: Array[String] = []
var _observed_equipment_resources: Array[Resource] = []
var hair_no_hat_meshes: Array[MeshInstance3D] = []
var hair_hat_meshes: Array[MeshInstance3D] = []
var gore_meshes: Array[MeshInstance3D] = []
var inventory: Inventory = null
var _observed_inventory: Inventory = null
var _soft_load_generation := 0
var _soft_loading := false
var _soft_prepare_pool: GamebryoResolverPool = null
var _soft_prepare_context: GamebryoResolveContext = null
var _soft_prepare_task := -1
var load_progress := 0.0
var load_stage := "Idle"

@export var possessed_first_person: bool = false:
	set(value):
		possessed_first_person = value
		_apply_possessed_first_person_render_mode()

func _ready() -> void:
	# Exported Resource fields can be restored without going through the
	# setter in every editor/runtime load path. Reconnect defensively here.
	_connect_equipment_state_signals()
	_ensure_inventory()
	_connect_inventory_signal()
	# Packed previews intentionally contain only the typed reference and the
	# authored actor scaffold. Rehydrate/build the generated Body after the
	# scene enters the editor/runtime tree, using the same async path as a live
	# physicalised actor.
	call_deferred("_rehydrate_and_build")

func _exit_tree() -> void:
	if _soft_prepare_task != -1:
		WorkerThreadPool.wait_for_task_completion(_soft_prepare_task)
		_soft_release_prepare_context(_active_mesh_resolver)
	_soft_load_generation += 1
	_soft_loading = false

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
	if _observed_inventory != null and is_instance_valid(_observed_inventory):
		if _observed_inventory.is_connected("inventory_changed", _on_inventory_changed):
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
		var armor := item.item_reference.base as ArmorBase if item != null and item.item_reference != null else null
		_add_equipment_resource(resources, item.item_reference if item != null else null)
		_add_equipment_resource(resources, armor)
		if armor != null:
			_add_equipment_resource(resources, armor.biped_model_list)
			if armor.biped_model_list != null:
				for addon in armor.biped_model_list.entries:
					_add_equipment_resource(resources, addon)
	_add_equipment_resource(resources, equipment_state.weapon_item)
	var weapon := equipment_state.get_weapon_base()
	_add_equipment_resource(resources, weapon)
	if weapon != null:
		_add_equipment_resource(resources, weapon.biped_model_list)
		if weapon.biped_model_list != null:
			for addon in weapon.biped_model_list.entries:
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
	# The setter remains the path for replacing the whole EsmActorEquipmentState.
	_connect_equipment_state_signals()
	if _active_record != null and _active_mesh_resolver != null and not _rebuilding:
		_rebuild_from_active_record()

func _rebuild_from_active_record() -> void:
	if _active_record == null or _active_mesh_resolver == null:
		return
	_rebuilding = true
	refresh_equipment(_active_mesh_resolver)
	_rebuilding = false

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
		if is_instance_valid(mesh): mesh.visible = not wearing_hat
	for mesh in hair_hat_meshes:
		if is_instance_valid(mesh): mesh.visible = wearing_hat

func _track_gore_meshes(body: Node) -> void:
	gore_meshes.clear()
	for child in body.find_children("*", "MeshInstance3D", true, false):
		var texture_path := String(child.get_meta("gamebryo_texture_path", "")).to_lower().replace("/", "\\")
		if texture_path.begins_with("textures\\gore\\") or texture_path.contains("\\gore\\"):
			gore_meshes.append(child)
	_apply_gore_visibility()

func _apply_gore_visibility() -> void:
	for mesh in gore_meshes:
		if is_instance_valid(mesh): mesh.visible = show_gore

func _apply_possessed_first_person_render_mode() -> void:
	for child in find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		if not mesh.has_meta("esm_actor_original_cast_shadow"):
			mesh.set_meta("esm_actor_original_cast_shadow", mesh.cast_shadow)
		if possessed_first_person:
			mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		else:
			mesh.cast_shadow = int(mesh.get_meta("esm_actor_original_cast_shadow"))

## Direct typed NPC construction. The generated Body is the only subtree this
## class owns; the AnimationTree and actor components remain authored siblings.
func build_visual(resolver: GamebryoMeshResolver) -> void:
	if not is_inside_tree():
		return
	var npc := reference.base as NpcBase if reference != null else null
	if npc == null:
		return
	_ensure_inventory()
	_connect_inventory_signal()
	_project_equipment_from_inventory()
	_start_soft_load(npc, resolver)

func _reference_changed() -> void:
	call_deferred("_rehydrate_and_build")

func _rehydrate_and_build() -> void:
	if reference == null:
		return
	var root := get_tree().root if is_inside_tree() else null
	var server = root.get_node_or_null("EsmServer") if root != null else null
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
			reference = hydrated
			return
	if reference.base == null or _visual_built or _soft_loading:
		return
	var body := get_node_or_null(NodePath(BODY_NODE_NAME))
	if body != null and body.get_child_count() > 0:
		_visual_built = true
		return
	build_visual(GamebryoMeshResolver.new())

func refresh_equipment(mesh_resolver: GamebryoMeshResolver = null, state_override: EsmActorEquipmentState = null) -> void:
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
	_active_weapon = state.get_weapon_base() if state != null and state is EsmActorEquipmentState else (state.weapon if state != null else null)
	var animation_component: Node = get_node_or_null(^"ActorAnimationComponent")
	if animation_component != null:
		animation_component.set_equipped_weapon(_active_weapon)
	for diagnostic in resolver.populate_equipment(equipment, skeleton, state, _is_female):
		push_warning("EsmNpcActor equipment: %s" % diagnostic)
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

func _apply_race_skin_overrides(record: NpcBase, mesh_resolver: GamebryoMeshResolver) -> void:
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

func _discover_locomotion_clips(mesh_resolver: GamebryoMeshResolver, weapon: WeaponBase = null) -> Dictionary:
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
func _register_animation_aliases(player: AnimationPlayer, _mesh_resolver: GamebryoMeshResolver, weapon: WeaponBase = null) -> void:
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

## Editor data-load entry point. Selects a typed base through EsmServer and
## assigns a synthetic ActorReference; no legacy factory or record is involved.
func _editor_load() -> void:
	_standalone_preview = true
	var form_id: int = PRESET_FORM_IDS.get(preset, 0)
	if preset == "Custom":
		form_id = custom_base_form_id.hex_to_int()
	var server = get_tree().root.get_node_or_null("EsmServer") if is_inside_tree() else null
	if server == null or not server.is_ready():
		push_warning("EsmNpcActor: EsmServer is not ready")
		return
	var candidate: EsmReference = server.create_reference_for_base(form_id)
	if candidate == null or not candidate is ActorReference:
		push_error("EsmNpcActor: base_form_id 0x%X is not an NPC_" % form_id)
		return
	reference = candidate
	print("EsmNpcActor: loaded typed actor base 0x%X" % form_id)

## Editor construction entry point. Consumes the assigned typed reference.
func _editor_apply_actor_data() -> void:
	if reference == null or not reference.base is NpcBase:
		push_warning("EsmNpcActor: assign an ActorReference backed by NpcBase before loading")
		return
	var resolver := _active_mesh_resolver
	if resolver == null:
		resolver = GamebryoMeshResolver.new()
	_active_mesh_resolver = resolver
	_ensure_inventory()
	_connect_inventory_signal()
	_project_equipment_from_inventory()
	_start_soft_load(reference.base as NpcBase, resolver)

func _start_soft_load(record: NpcBase, resolver: GamebryoMeshResolver) -> void:
	if _soft_loading:
		push_warning("EsmNpcActor: an actor load is already in progress")
		return
	_soft_load_generation += 1
	_soft_loading = true
	load_progress = 0.0
	load_stage = "Starting"
	emit_signal("actor_load_started")
	_soft_load_actor(record, resolver, _soft_load_generation)

func _soft_load_actor(record: NpcBase, resolver: GamebryoMeshResolver, generation: int) -> void:
	_rebuilding = true
	_active_record = record
	_active_mesh_resolver = resolver
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
		_visual_built = true
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
		push_error("EsmNpcActor: soft load failed: %s" % message)

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
	_disconnect_inventory_signal()
	inventory = null
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
	reference = null
	equipment_state = null
	_standalone_preview = false
	_rebuilding = false
	load_progress = 0.0
	load_stage = "Idle"
	print("EsmNpcActor: unloaded actor")


## Runtime construction entry point for an actor authored as a child of a
## controller (for example PlayerController). The serialized typed record is
## the source; this does not reopen the ESM or replace inspector-authored
## resource state.
func apply_runtime_actor_data() -> void:
	if reference == null or not reference.base is NpcBase:
		return
	_active_mesh_resolver = GamebryoMeshResolver.new()
	_ensure_inventory()
	_connect_inventory_signal()
	_project_equipment_from_inventory()
	_start_soft_load(reference.base as NpcBase, _active_mesh_resolver)

## actor once first; subsequent edits to the EsmActorEquipmentState resource can be
## applied here without resetting the skeleton, facial assembly, animations,
## pose, or standalone preview orientation.
func _editor_refresh_equipment() -> void:
	if reference == null or not reference.base is NpcBase or _active_mesh_resolver == null:
		push_warning("EsmNpcActor: load the actor before refreshing equipment")
		return
	_project_equipment_from_inventory()
	refresh_equipment(_active_mesh_resolver)
	print("EsmNpcActor: equipment refreshed")

func _own_recursive(node: Node) -> void:
	node.owner = get_tree().edited_scene_root
	for c in node.get_children():
		_own_recursive(c)
