extends Node3D

## Weapon sounds. SoundServer returns a SOUN's one file, or every file of its
## folder. WeaponBase reads the 10mm pistol's sound fields. Its EsmWeaponNode,
## with no holder: firing plays its shoot sound, firing empty its no-ammo sound,
## and the reload clip's `Sound:` keys (1hpreloada: WPNPistol10mmReloadOut,
## ...N, ...Chamber) play those SOUN; a folder's files go in an
## AudioStreamRandomizer.

const PISTOL := "Weap10mmPistol"
const RELOAD_SOUND := "WPNPistol10mmReloadOut"
const FRAMES := 900

var failures := 0


func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1


func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var base := EsmServer.find_base_by_editor_id(PISTOL) as WeaponBase
	check(base.shoot_sound != null and base.equip_sound != null and base.unequip_sound != null and base.no_ammo_sound != null,
			"the 10mm reads its shoot, equip, unequip and no-ammo sounds (%s, %s)" % [_name(base.shoot_sound), _name(base.no_ammo_sound)])
	var shoot_streams := SoundServer.get_streams(base.shoot_sound)
	check(not shoot_streams.is_empty(), "its shoot sound has streams (%d, FNAM %s)" % [shoot_streams.size(), base.shoot_sound.file_name if base.shoot_sound != null else ""])
	var reload_sound := EsmServer.find_base_by_editor_id(RELOAD_SOUND) as SoundBase
	check(reload_sound != null and not SoundServer.get_streams(reload_sound).is_empty(), "%s has streams (FNAM %s)" % [RELOAD_SOUND, reload_sound.file_name if reload_sound != null else ""])

	var reference := EsmServer.create_runtime_reference(base.form_id) as WeaponReference
	var node := EsmReferencePhysicaliser.new().physicalise(reference, self) as EsmWeaponNode
	await _wait_until(func() -> bool: return node._visual_node(node.visual_detail) != null)
	reference.loaded_ammo_count = 3
	check(node.fire(), "the weapon fires")
	var shoot_player := node._sound_players.get(base.shoot_sound) as AudioStreamPlayer3D
	check(shoot_player != null and shoot_player.stream != null and shoot_player.get_parent() == node.get_node("Sounds"), "firing builds the shoot sound's player under Sounds")
	check(shoot_player != null and (shoot_player.stream is AudioStreamRandomizer) == (shoot_streams.size() > 1),
			"with an AudioStreamRandomizer exactly when the SOUN names several files")
	reference.loaded_ammo_count = 0
	node.fire()
	check(node._sound_players.has(base.no_ammo_sound), "firing empty plays the no-ammo sound")

	check(node.reload(), "the weapon reloads")
	await _wait_until(func() -> bool: return node._sound_players.has(reload_sound))
	check(node._sound_players.has(reload_sound), "the reload clip's Sound: key plays %s" % RELOAD_SOUND)
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _name(sound: SoundBase) -> String:
	return sound.editor_id if sound != null else "none"


func _wait_until(condition: Callable) -> void:
	for frame in FRAMES:
		if condition.call():
			return
		await get_tree().process_frame
