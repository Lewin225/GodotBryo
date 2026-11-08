@tool
@icon("res://GodotBryo/Types/Node/item.svg")
class_name EsmWeaponNode
extends EsmItemNode

## A WEAP reference's world model: on the ground, held or holstered. The
## weapon's state (loaded ammo, jammed) is on its WeaponReference, so it
## survives this node. Works with no actor holding it: fire(), reload() and
## aim() play the weapon's `_male` clips on its own parts (the template
## scene's KfAnimator, with node targets), and the inspector's buttons call
## them in the editor. Built from esm_weapon_node.tscn.
## Plan: Plans/Weapons/weapons.md.

signal fired
signal reloaded
signal jam_cleared

## NIF node the shot leaves from. Present on every pistol, automatic, rifle and
## launcher model.
const MUZZLE_NODE := "ProjectileNode"
## The muzzle's name on lasergatling.nif.
const MUZZLE_NODE_PARTED := "##ProjectileNode"
## NIF node spent shells leave from. Present on 32 of the 66 pistol, automatic
## and rifle models.
const SHELL_EJECTION_NODE := "ShellCasingNode"
## NIF node the sights line up on. Present on 47 of the 66 pistol, automatic
## and rifle models; on no launcher or non-gun.
const SIGHTING_NODE := "##SightingNode"

## KfAnimator slot of the aim clip, under the actions.
const SLOT_AIM := 0
## KfAnimator slot of attack, reload and jam clips.
const SLOT_ACTION := 1
## Seconds a clip fades in and out over.
const FADE_SECONDS := 0.1

## The action a weapon is playing: reload and jam clips play one at a time and
## block the other inputs. Attacks do not block (fire rate comes with WEAP's
## DNAM fields; attackloop clips loop and never finish).
enum Action { NONE, RELOAD, JAM }

@export_tool_button("Fire") var _fire_button := fire
@export_tool_button("Reload") var _reload_button := reload
@export_tool_button("Toggle aim") var _aim_button := toggle_aim
@export_tool_button("Jam") var _jam_button := jam

## The NIF string extra data naming the bone a part hangs from: `Backpack`
## carries `UPB` = `Bip01 Spine2` on 17 weapon NIFs (the heavy weapons and the
## Shishkebab); no other `UPB` of the 1,606 on the 362 weapon NIFs is a bone
## name.
const BONE_PART_KEY := "UPB"

## The model's muzzle node; null before the model loads or when it has none.
var muzzle: Node3D
## The model's shell ejection node; null before the model loads or when it has
## none.
var shell_ejection: Node3D
## The model's sighting node; null before the model loads or when it has none.
var sighting: Node3D
## Whether the weapon is aimed (its aim clip playing).
var is_aiming := false
## Whether an actor holds the weapon (ActorWeaponSlots): its model sits in the
## holder's frame (a bone's) with no placement turn, and its body stays frozen
## with collision off and never writes a resting place to the reference.
var is_held := false:
	set(value):
		is_held = value
		_apply_held()

## Plays the clips on the model's parts: the template scene's WeaponAnimator
## (esm_weapon_node.tscn), node_root set to the model when it loads.
@onready var _animator: KfAnimator = $WeaponAnimator
## Clip paths delivered by NifServer -> their Animation; a null value is a
## clip that failed to load.
var _clips := {}
## The action playing, and its clip's path ("" when it has none).
var _action := Action.NONE
var _action_path := ""


## The reference as a WeaponReference; null when the node holds another type.
func get_weapon_reference() -> WeaponReference:
	return reference as WeaponReference


## The reference's WEAP base; null before the reference resolves.
func get_weapon_base() -> WeaponBase:
	if reference == null:
		return null
	return reference.base as WeaponBase


## Fires one round: spends a loaded round and plays the attack clip. Does
## nothing while a reload or jam plays, while jammed, or with nothing loaded.
## True when it fired.
func fire() -> bool:
	var weapon := get_weapon_reference()
	if weapon == null or _action != Action.NONE or weapon.is_jammed:
		return false
	if weapon.loaded_ammo_count <= 0:
		return false
	weapon.loaded_ammo_count -= 1
	_play(SLOT_ACTION, get_weapon_base().attack_clip_path())
	fired.emit()
	return true


## Reloads: plays the reload clip and fills the clip when it ends. Does nothing
## while an action plays or when the clip is full. With no holder the rounds
## come from nowhere. True when it started.
func reload() -> bool:
	var weapon := get_weapon_reference()
	var base := get_weapon_base()
	if weapon == null or base == null or _action != Action.NONE:
		return false
	if weapon.loaded_ammo_count >= base.clip_size:
		return false
	_play_action(Action.RELOAD, base.reload_clip_path())
	return true


## Aims (plays the aim clip) or lowers the weapon.
func aim(aimed: bool) -> void:
	var base := get_weapon_base()
	if base == null or aimed == is_aiming:
		return
	is_aiming = aimed
	if aimed:
		_play(SLOT_AIM, base.aim_clip_path())
	elif _animator != null:
		_animator.stop(SLOT_AIM, FADE_SECONDS)


func toggle_aim() -> void:
	aim(not is_aiming)


## Jams the weapon: it plays its jam clip, which clears the jam when it ends,
## as the original clears it with no input.
func jam() -> void:
	var weapon := get_weapon_reference()
	if weapon == null or _action != Action.NONE:
		return
	weapon.is_jammed = true
	_play_action(Action.JAM, get_weapon_base().jam_clip_path())


## The model's parts that hang from a bone of `skeleton` rather than from the
## weapon: part node -> bone name. Empty before the model loads.
func get_bone_parts(skeleton: Skeleton3D) -> Dictionary:
	var result := {}
	var visual := _visual_node(VisualDetail.FULL)
	if visual == null or skeleton == null:
		return result
	for part: Node in visual.find_children("*", "Node3D", true, false):
		var strings: Dictionary = part.get_meta("nif_string_extra_data", {})
		var bone := String(strings.get(BONE_PART_KEY, "")).strip_edges()
		if not bone.is_empty() and skeleton.find_bone(bone) != -1:
			result[part] = bone
	return result


## The model's part whose authored NIF name is `nif_name`, or null.
func get_part(nif_name: String) -> Node3D:
	var visual := _visual_node(VisualDetail.FULL)
	if visual == null:
		return null
	return _find_nif_node(visual, nif_name)


## The action playing.
func get_action() -> Action:
	return _action


func _play_action(action: Action, path: String) -> void:
	_action = action
	_action_path = path
	if path.is_empty():
		_finish_action()
		return
	_play(SLOT_ACTION, path)


## Plays the clip at `path` in `slot`, loading it first; an action whose clip
## cannot load or bind finishes at once.
func _play(slot: int, path: String) -> void:
	if path.is_empty():
		return
	if not _clips.has(path):
		NifServer.request_kf(path, self, _on_clip_delivered.bind(slot, path))
		return
	var clip: Animation = _clips[path]
	var serial := 0
	if clip != null and _animator != null:
		serial = _animator.play(slot, clip, FADE_SECONDS, false, 1.0, path, 0)
	if serial == 0 and slot == SLOT_ACTION and _action_path == path:
		_finish_action()


func _on_clip_delivered(library: AnimationLibrary, slot: int, path: String) -> void:
	var clip: Animation = null
	if library != null and not library.get_animation_list().is_empty():
		clip = library.get_animation(library.get_animation_list()[0])
	_clips[path] = clip
	var still_wanted := slot == SLOT_ACTION or (slot == SLOT_AIM and is_aiming)
	if slot == SLOT_ACTION and _action != Action.NONE and _action_path != path:
		still_wanted = false
	if still_wanted:
		_play(slot, path)


func _on_clip_finished(slot: int, _animation: Animation) -> void:
	if slot == SLOT_ACTION and _action != Action.NONE:
		_animator.stop(SLOT_ACTION, FADE_SECONDS)
		_finish_action()


## Ends the action: a reload fills the clip, a jam clears.
func _finish_action() -> void:
	var finished := _action
	_action = Action.NONE
	_action_path = ""
	var weapon := get_weapon_reference()
	var base := get_weapon_base()
	if weapon == null or base == null:
		return
	if finished == Action.RELOAD:
		weapon.loaded_ammo_count = base.clip_size
		reloaded.emit()
	elif finished == Action.JAM:
		weapon.is_jammed = false
		jam_cleared.emit()


## Puts the model in the holder's frame and stops its physics while held.
func _apply_held() -> void:
	var visual := _visual_node(VisualDetail.FULL)
	if visual == null:
		return
	if is_held:
		visual.transform = Transform3D.IDENTITY
	if body != null:
		body.freeze = true
	hold_bodies(visual, is_held)


## Stops (`held`) or restarts every rigid body under `root` and turns their
## collision off or on. A NifRigidBody is top level and moves the node owning
## its meshes to itself each frame it is not asleep, which a frozen body is
## not: held, it would pin those meshes where it was built. Not processing, it
## leaves them to follow the holder's bone. A model can have several: the
## minigun's Backpack has its own.
static func hold_bodies(root: Node, held: bool) -> void:
	for found: Node in root.find_children("*", "RigidBody3D", true, false):
		var rigid := found as RigidBody3D
		if held:
			rigid.freeze = true
		rigid.process_mode = Node.PROCESS_MODE_DISABLED if held else Node.PROCESS_MODE_INHERIT
	set_collision_disabled(root, held)


## A held weapon's body is never released.
func _release_when_surroundings_built() -> void:
	if is_held:
		return
	super._release_when_surroundings_built()


## A held weapon never writes a resting place.
func _settle() -> void:
	if is_held:
		return
	super._settle()


func _on_nif_visual_ready(tree: Node3D) -> void:
	super._on_nif_visual_ready(tree)
	_apply_held()
	if _animator == null:
		return
	if not _animator.clip_finished.is_connected(_on_clip_finished):
		_animator.clip_finished.connect(_on_clip_finished)
	# In the editor the template scene's children belong to the instance, so
	# the Scene dock hides them; owned by the edited scene they show, as the
	# actor's do.
	if Engine.is_editor_hint() and owner != null:
		_animator.owner = get_tree().edited_scene_root
	_animator.stop_all()
	_animator.node_root = _animator.get_path_to(tree)
	muzzle = _find_nif_node(tree, MUZZLE_NODE)
	if muzzle == null:
		muzzle = _find_nif_node(tree, MUZZLE_NODE_PARTED)
	shell_ejection = _find_nif_node(tree, SHELL_EJECTION_NODE)
	sighting = _find_nif_node(tree, SIGHTING_NODE)


func _clear_generated_children() -> void:
	muzzle = null
	shell_ejection = null
	sighting = null
	super._clear_generated_children()


## The first Node3D under `tree` whose authored NIF name is `nif_name`. The
## anchors are not always direct children of the weapon node (the Minigun's
## ProjectileNode is under ##MinigunGun), so the whole tree is searched.
func _find_nif_node(tree: Node3D, nif_name: String) -> Node3D:
	for node: Node in tree.find_children("*", "Node3D", true, false):
		if String(node.get_meta(NifNames.META_NIF_NAME, "")) == nif_name:
			return node as Node3D
	return null
