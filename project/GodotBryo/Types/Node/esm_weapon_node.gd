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
## A pull with nothing loaded: the no-ammo sound played.
signal dry_fired
signal reloaded
signal jam_cleared
## A clip's `prn: <bone>` text key: the weapon moves to that bone (Bip01 R Hand,
## the hand; another, its holster point). Equip and unequip clips carry one.
signal parent_key(bone: String)
## An equip (drawn true) or unequip clip ended, or could not play.
signal equip_finished(drawn: bool)

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

## KfAnimator slot of the aim clip, under the actions: the holder's stance
## slot.
const SLOT_AIM := ActorAnimator.WEAPON_STANCE_SLOT
## KfAnimator slot of equip, attack, reload and jam clips: the holder's action
## slot, which follows this one.
const SLOT_ACTION := ActorAnimator.WEAPON_ACTION_SLOT
## The text key naming a sound a clip plays: `Sound: WPNPistol10mmReloadOut`, a
## SOUN EditorID (1,731 of the 2,069 such keys in the `_male` and `_1stperson`
## KFs name one; the rest are quest scenes').
const SOUND_KEY_PREFIX := "sound:"
## How many plays of one sound overlap.
const SOUND_POLYPHONY := 4
## Game units per metre, for a SOUN's attenuation distances.
const UNITS_PER_METRE := 70.0
## A spin clip's text keys: its first shot, and the end of its firing loop.
const SPIN_FIRE_KEY := "fire"
const SPIN_LOOP_KEY := "loop"
## The text key naming the bone a clip moves the weapon to: `prn: Bip01 R Hand`.
const PARENT_KEY_PREFIX := "prn:"
## Seconds a clip fades out over when stopped.
const FADE_SECONDS := 0.1
## Seconds a clip fades in over: none. The parts are mechanical: a slide
## crossfaded from the last shot's held end pose would barely move (its travel
## falls inside the fade), so each clip starts at full weight.
const START_FADE_SECONDS := 0.0

## The action a weapon is playing: reload, jam, equip and unequip clips play
## one at a time and block the other inputs. Attacks are not actions: the
## trigger's shot interval paces them, and a looping attack clip never ends.
enum Action { NONE, RELOAD, JAM, EQUIP, UNEQUIP }

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

## The template scene's node the sound players are built under.
@onready var _sounds: Node3D = $Sounds
## SOUN -> its AudioStreamPlayer3D, built on first use.
var _sound_players := {}
## SOUN -> the looping player of a shoot loop (NAM7), and the player of its
## wind-down.
var _loop_players := {}
var _wind_down_players := {}
## SOUN EditorID (lower case) -> its SoundBase, null when none, for clip keys.
var _key_sounds := {}

## Plays the clips on the model's parts: the template scene's WeaponAnimator
## (esm_weapon_node.tscn), node_root set to the model when it loads.
@onready var _animator: KfAnimator = $WeaponAnimator
## Clip paths delivered by NifServer -> their Animation; a null value is a
## clip that failed to load.
var _clips := {}
## The action playing, its clip's path ("" when it has none) and its clip once
## it plays: only that clip reaching its end finishes the action.
var _action := Action.NONE
var _action_path := ""
var _action_clip: Animation = null
## Whether the holder holds the trigger, and whether this pull has fired.
var _trigger_held := false
var _fired_this_pull := false
## Ticks (msec) before which the next shot cannot fire.
var _next_shot_msec := 0
## Whether a spin clip is held in its firing loop (from the pull that started
## it until the release).
var _spinning := false


## The reference as a WeaponReference; null when the node holds another type.
func get_weapon_reference() -> WeaponReference:
	return reference as WeaponReference


## The reference's WEAP base; null before the reference resolves.
func get_weapon_base() -> WeaponBase:
	if reference == null:
		return null
	return reference.base as WeaponBase


## The trigger, held (true) or released, set by the holder each frame from its
## input. Held, an automatic weapon (Flags 1 Is Automatic) fires every 1 /
## Attack Shots/Sec seconds; any other fires once per pull, no sooner than that
## after its last shot. A looping attack clip (attackloop) plays while it is
## held and stops when it is released. A spin clip (one with `Fire` and `Loop`
## text keys: the 42 attackspin clips) plays once per pull: no shot before its
## `Fire` key, its `Fire` to `Loop` section repeated while held, and on release
## it plays on to its end. `# ASSUMPTION` that reading of the spin clips' keys:
## the data gives only their names and times (Fire before Loop in all 42).
func set_trigger(held: bool) -> void:
	if held == _trigger_held:
		return
	_trigger_held = held
	if held:
		_fired_this_pull = false
		_pull_trigger()
		return
	_stop_attack_loop()
	_stop_loop_sound()


## Fires one shot now if the weapon can (the inspector's Fire button): spends a
## loaded round and plays the attack clip. Does nothing while a reload, jam or
## equip plays, while jammed, before the shot interval has passed or with
## nothing loaded (which plays the no-ammo sound). True when it fired.
func fire() -> bool:
	var weapon := get_weapon_reference()
	var base := get_weapon_base()
	if weapon == null or base == null or _action != Action.NONE or weapon.is_jammed:
		return false
	if Time.get_ticks_msec() < _next_shot_msec:
		return false
	if weapon.loaded_ammo_count <= 0:
		_stop_loop_sound()
		play_sound(base.no_ammo_sound)
		dry_fired.emit()
		return false
	weapon.loaded_ammo_count -= 1
	_next_shot_msec = Time.get_ticks_msec() + int(shot_interval() * 1000.0)
	_play_shot_sound(base)
	var path := base.attack_clip_path()
	if not _attack_clip_playing(path):
		_play(SLOT_ACTION, path)
	fired.emit()
	return true


## Whether the attack clip at `path` is the action slot's clip and keeps
## playing across shots: a looping clip, or a spin clip from the pull that
## started it until the release (after it, its spin-down ends and a new pull
## starts it again).
func _attack_clip_playing(path: String) -> bool:
	var clip: Animation = _clips.get(path)
	if clip == null or _animator == null or String(_animator.get_start(SLOT_ACTION).get("path", "")) != path:
		return false
	if _spin_section(clip) != Vector2():
		return _spinning
	return clip.loop_mode != Animation.LOOP_NONE


## A spin clip's `Fire` and `Loop` key times (seconds from its start); empty for
## a clip without both.
static func _spin_section(clip: Animation) -> Vector2:
	if clip == null:
		return Vector2()
	var start := float(clip.get_meta("nif_start_time", 0.0))
	var fire_time := -1.0
	var loop_time := -1.0
	for key: Dictionary in clip.get_meta("nif_text_keys", []):
		var value := String(key.get("value", "")).strip_edges().to_lower()
		if value == SPIN_FIRE_KEY:
			fire_time = float(key.get("time", 0.0)) - start
		elif value == SPIN_LOOP_KEY:
			loop_time = float(key.get("time", 0.0)) - start
	if fire_time < 0.0 or loop_time <= fire_time:
		return Vector2()
	return Vector2(fire_time, loop_time)


## Whether a spin clip playing in the action slot has reached its `Fire` key;
## true when no spin clip plays.
func _spun_up() -> bool:
	var base := get_weapon_base()
	if base == null or _animator == null:
		return true
	var path := base.attack_clip_path()
	var spin := _spin_section(_clips.get(path))
	if spin == Vector2() or String(_animator.get_start(SLOT_ACTION).get("path", "")) != path:
		return true
	return _animator.get_time(SLOT_ACTION) >= spin.x


## Seconds between shots: 1 / Attack Shots/Sec, 0 when it is not set.
func shot_interval() -> float:
	var base := get_weapon_base()
	if base == null or base.attack_shots_per_second <= 0.0:
		return 0.0
	return 1.0 / base.attack_shots_per_second


func is_automatic() -> bool:
	var base := get_weapon_base()
	return base != null and (base.flags1 & WeaponBase.FLAG1_IS_AUTOMATIC) != 0


func _process(_delta: float) -> void:
	if _trigger_held:
		_pull_trigger()


## A spin clip's first shot waits for its `Fire` key: the pull starts the clip
## with its firing loop set, and the shots come once it has spun up. False when
## the attack clip is no spin clip, or one is already playing.
func _start_spin() -> bool:
	var base := get_weapon_base()
	var weapon := get_weapon_reference()
	if base == null or weapon == null or _animator == null or _action != Action.NONE or weapon.is_jammed:
		return false
	var path := base.attack_clip_path()
	var spin := _spin_section(_clips.get(path))
	if spin == Vector2() or _attack_clip_playing(path):
		return false
	_play(SLOT_ACTION, path)
	_animator.set_loop_section(SLOT_ACTION, spin.x, spin.y, -1)
	_spinning = true
	return true


## Fires while the trigger is held: every shot interval when automatic, once
## per pull otherwise.
func _pull_trigger() -> void:
	# Empty, a pull clicks once (fire() plays the no-ammo sound), automatic or
	# not; holding on does not click again.
	var weapon := get_weapon_reference()
	if weapon != null and weapon.loaded_ammo_count <= 0:
		if not _fired_this_pull:
			fire()
			_fired_this_pull = true
		return
	if _fired_this_pull and not is_automatic():
		return
	if _start_spin() or not _spun_up():
		return
	if fire():
		_fired_this_pull = true


## On release: stops a looping attack clip; lets a spin clip play on from its
## loop section to its end (the spin-down).
func _stop_attack_loop() -> void:
	var base := get_weapon_base()
	if base == null or _animator == null:
		return
	var path := base.attack_clip_path()
	var clip: Animation = _clips.get(path)
	if clip == null or String(_animator.get_start(SLOT_ACTION).get("path", "")) != path:
		return
	if _spin_section(clip) != Vector2():
		_animator.set_loop_section(SLOT_ACTION, 0.0, -1.0, 0)
		_spinning = false
		return
	if clip.loop_mode != Animation.LOOP_NONE:
		_animator.stop(SLOT_ACTION, FADE_SECONDS)


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


## Draws the weapon: plays its equip clip, whose `prn:` key moves it to the
## hand (parent_key). False when it has no equip clip.
func play_equip() -> bool:
	if get_weapon_base() != null:
		play_sound(get_weapon_base().equip_sound)
	return _play_equip_action(Action.EQUIP, get_weapon_base().equip_clip_path() if get_weapon_base() != null else "")


## Holsters the weapon: plays its unequip clip, whose `prn:` key moves it to its
## holster point. False when it has no unequip clip.
func play_unequip() -> bool:
	if get_weapon_base() != null:
		play_sound(get_weapon_base().unequip_sound)
	return _play_equip_action(Action.UNEQUIP, get_weapon_base().unequip_clip_path() if get_weapon_base() != null else "")


## The KfAnimator playing the weapon's clips: the clock its holder follows.
func get_animator() -> KfAnimator:
	return _animator


func _play_equip_action(action: Action, path: String) -> bool:
	if path.is_empty() or _animator == null:
		return false
	# Drawing or holstering replaces whatever action plays.
	_action = Action.NONE
	_play_action(action, path)
	return true


## The action playing.
func get_action() -> Action:
	return _action


func _play_action(action: Action, path: String) -> void:
	_stop_loop_sound()
	_action = action
	_action_path = path
	_action_clip = null
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
		serial = _animator.play(slot, clip, START_FADE_SECONDS, false, 1.0, path, 0)
	if slot == SLOT_ACTION and _action_path == path:
		_action_clip = clip if serial != 0 else null
		if serial == 0:
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


## An action ends when its own clip reaches its end (the closing `end` key: the
## reload and jam clips mark no earlier finish), not when another clip in the
## slot does, nor when it is replaced.
func _on_clip_finished(slot: int, animation: Animation) -> void:
	if slot != SLOT_ACTION or _action == Action.NONE or animation == null or animation != _action_clip:
		return
	_animator.stop(SLOT_ACTION, FADE_SECONDS)
	_finish_action()


## Ends the action: a reload fills the clip, a jam clears.
func _finish_action() -> void:
	var finished := _action
	_action = Action.NONE
	_action_path = ""
	_action_clip = null
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
	elif finished == Action.EQUIP or finished == Action.UNEQUIP:
		equip_finished.emit(finished == Action.EQUIP)


func _on_text_key(slot: int, key: String, _time: float) -> void:
	var text := key.strip_edges()
	if text.to_lower().begins_with(SOUND_KEY_PREFIX):
		play_sound(_key_sound(text.substr(SOUND_KEY_PREFIX.length()).strip_edges()))
		return
	if slot != SLOT_ACTION or not text.to_lower().begins_with(PARENT_KEY_PREFIX):
		return
	parent_key.emit(text.substr(PARENT_KEY_PREFIX.length()).strip_edges())


## Plays `sound` from the weapon: its player, built on first use, holds every
## file its FNAM names, in an AudioStreamRandomizer when there are several.
## Nothing plays for a null sound or one with no files.
func play_sound(sound: SoundBase) -> void:
	if sound == null or _sounds == null:
		return
	var player := _sound_players.get(sound) as AudioStreamPlayer3D
	if player == null:
		player = _make_sound_player(sound)
		_sound_players[sound] = player
	if player.stream != null:
		player.play()


## A shot's sound: an automatic weapon with Shoot 3D Looping (NAM7) runs that
## loop while it fires, in place of a sound per shot; any other plays Shoot 3D
## (SNAM) per shot. `# ASSUMPTION` the loop replaces SNAM: 37 of the 97
## automatic WEAP have NAM7 (the minigun only it), 58 SNAM alone, and nothing
## says how the 8 with both play.
func _play_shot_sound(base: WeaponBase) -> void:
	if not is_automatic() or base.shoot_loop_sound == null:
		play_sound(base.shoot_sound)
		return
	var player := _loop_players.get(base.shoot_loop_sound) as AudioStreamPlayer3D
	if player == null:
		player = _make_sound_player(base.shoot_loop_sound, true)
		_loop_players[base.shoot_loop_sound] = player
	if player.stream != null and not player.playing:
		player.play()


## Stops a running shoot loop: the trigger released, the weapon dry, or an
## action (reload, jam, equip) begun. A loop with loop points then plays its
## wind-down.
func _stop_loop_sound() -> void:
	for sound: SoundBase in _loop_players:
		var player := _loop_players[sound] as AudioStreamPlayer3D
		if player == null or not player.playing:
			continue
		player.stop()
		_play_wind_down(sound)


func _play_wind_down(sound: SoundBase) -> void:
	var player := _wind_down_players.get(sound) as AudioStreamPlayer3D
	if player == null:
		player = _make_sound_player(sound)
		player.stream = _wind_down_chunk(sound)
		_wind_down_players[sound] = player
	if player.stream != null:
		player.play()


## `sound`'s loop, from SoundServer's cached chunks of its first file: with
## loop points, the file up to the loop end, looping from the loop begin, so its
## wind-up (the frames before) plays once and the loop follows on the sample;
## without, the whole file looping.
static func _loop_chunk(sound: SoundBase) -> AudioStream:
	var paths := SoundServer.get_paths(sound)
	if paths.is_empty():
		return null
	if not _has_loop_points(sound):
		return SoundServer.get_stream_chunk(paths[0], -1, -1, true)
	return SoundServer.get_stream_chunk(paths[0], -1, sound.loop_end, true, sound.loop_begin)


## `sound`'s wind-down: the frames after its loop end, played once when the
## loop stops; null for a sound without loop points.
static func _wind_down_chunk(sound: SoundBase) -> AudioStream:
	var paths := SoundServer.get_paths(sound)
	if paths.is_empty() or not _has_loop_points(sound):
		return null
	return SoundServer.get_stream_chunk(paths[0], sound.loop_end, -1)


static func _has_loop_points(sound: SoundBase) -> bool:
	return sound != null and sound.loop_end > sound.loop_begin


## The SOUN of a clip key's EditorID, null when there is none.
func _key_sound(editor_id: String) -> SoundBase:
	var key := editor_id.to_lower()
	if not _key_sounds.has(key):
		_key_sounds[key] = EsmServer.find_base_by_editor_id(editor_id) as SoundBase
	return _key_sounds[key]


## A player for `sound` under Sounds. Its distances are the SOUN's attenuation
## distances in metres: `# ASSUMPTION` the minimum is Godot's unit size (full
## volume within it) and the maximum where it falls silent; the original's
## attenuation curve (SNDD) is not read.
func _make_sound_player(sound: SoundBase, looping := false) -> AudioStreamPlayer3D:
	var player := AudioStreamPlayer3D.new()
	player.name = NifNames.escape(sound.editor_id) if not sound.editor_id.is_empty() else "Sound"
	# Shots overlap: a new one does not cut the last.
	player.max_polyphony = SOUND_POLYPHONY
	var streams := SoundServer.get_streams(sound)
	if looping and not streams.is_empty():
		player.stream = _loop_chunk(sound)
		streams = []
	if streams.size() == 1:
		player.stream = streams[0]
	elif streams.size() > 1:
		var randomizer := AudioStreamRandomizer.new()
		for stream in streams:
			randomizer.add_stream(-1, stream)
		player.stream = randomizer
	player.unit_size = maxf(sound.minimum_attenuation_distance / UNITS_PER_METRE, 1.0)
	if sound.maximum_attenuation_distance > 0.0:
		player.max_distance = sound.maximum_attenuation_distance / UNITS_PER_METRE
	_sounds.add_child(player)
	return player


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
	if not _animator.text_key.is_connected(_on_text_key):
		_animator.text_key.connect(_on_text_key)
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
