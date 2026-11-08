extends Node3D

## The weapon's trigger, with no holder. The minigun (automatic, its attack
## 2hhattackspin: Fire key 0.20 s, Loop key 0.87 s) fires no shot before its
## Fire key, then about Attack Shots/Sec times a second while the trigger is
## held, its clip kept inside the Fire to Loop section; released, it stops
## firing and its clip plays on to its end. The 10mm pistol (semi-automatic) fires once per pull however long
## it is held, and a second pull inside 1 / Attack Shots/Sec does not fire.
## Firing does nothing while a reload plays, and the reload refills only when
## its own clip ends, though an attack clip was fading out of the slot when it
## started. Empty, a held trigger clicks once. A second shot's attack clip
## starts at full weight, so the 10mm's slide follows it rather than a blend
## with the last shot's held end pose.

const MINIGUN := "WeapMinigun"
const PISTOL := "Weap10mmPistol"
const FRAMES := 900

var failures := 0


func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1


func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	await _check_automatic()
	await _check_semi_automatic()
	await _check_dry_fire_and_slide()
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _check_automatic() -> void:
	var minigun := await _place(MINIGUN)
	var reference := minigun.get_weapon_reference()
	var base := minigun.get_weapon_base()
	check(minigun.is_automatic(), "the minigun is automatic (Flags 1 0x%02x)" % base.flags1)
	reference.loaded_ammo_count = 200
	await _warm_clip(minigun, base.attack_clip_path())
	var animator := minigun.get_animator()
	var spin := EsmWeaponNode._spin_section(minigun._clips.get(base.attack_clip_path()))
	check(spin.x > 0.0 and spin.y > spin.x, "its attack clip is a spin clip (Fire %.2f s, Loop %.2f s)" % [spin.x, spin.y])
	minigun.set_trigger(true)
	await _frames(2)
	check(reference.loaded_ammo_count == 200, "no shot before the Fire key (clip at %.2f s)" % animator.get_time(EsmWeaponNode.SLOT_ACTION))
	await _wait_until(func() -> bool: return animator.get_time(EsmWeaponNode.SLOT_ACTION) >= spin.x and reference.loaded_ammo_count < 200)
	var start_msec := Time.get_ticks_msec()
	var start_count := reference.loaded_ammo_count
	var latest := 0.0
	for frame in 120:
		await get_tree().process_frame
		latest = maxf(latest, animator.get_time(EsmWeaponNode.SLOT_ACTION))
	var held_seconds := (Time.get_ticks_msec() - start_msec) / 1000.0
	var fired := start_count - reference.loaded_ammo_count
	var expected := base.attack_shots_per_second * held_seconds
	check(fired >= expected * 0.7 and fired <= expected * 1.3 + 1.0,
			"spun up and held for %.2f s it fires %d rounds (%.1f shots/s gives %.0f)" % [held_seconds, fired, base.attack_shots_per_second, expected])
	check(latest <= spin.y + 0.05, "held, its clip stays inside the Fire to Loop section (latest %.2f s)" % latest)
	minigun.set_trigger(false)
	var after := reference.loaded_ammo_count
	await _wait_until(func() -> bool: return animator.get_time(EsmWeaponNode.SLOT_ACTION) > spin.y + 0.05 or animator.get_start(EsmWeaponNode.SLOT_ACTION).is_empty())
	check(animator.get_time(EsmWeaponNode.SLOT_ACTION) > spin.y or animator.get_start(EsmWeaponNode.SLOT_ACTION).is_empty(),
			"released, the clip plays on past Loop (%.2f s)" % animator.get_time(EsmWeaponNode.SLOT_ACTION))
	check(reference.loaded_ammo_count == after, "released, it stops firing")


func _check_semi_automatic() -> void:
	var pistol := await _place(PISTOL)
	var reference := pistol.get_weapon_reference()
	var base := pistol.get_weapon_base()
	check(not pistol.is_automatic(), "the 10mm pistol is semi-automatic")
	reference.loaded_ammo_count = 10
	await _warm_clip(pistol, base.attack_clip_path())
	pistol.set_trigger(true)
	await get_tree().create_timer(1.0).timeout
	check(reference.loaded_ammo_count == 9, "held for 1 s it fires once (%d left)" % reference.loaded_ammo_count)
	pistol.set_trigger(false)
	pistol.set_trigger(true)
	pistol.set_trigger(false)
	check(reference.loaded_ammo_count == 8, "a new pull after the interval fires")
	pistol.set_trigger(true)
	pistol.set_trigger(false)
	check(reference.loaded_ammo_count == 8, "a pull inside 1 / %.2f s does not fire" % base.attack_shots_per_second)

	await get_tree().create_timer(pistol.shot_interval() + 0.05).timeout
	pistol.set_trigger(true)
	pistol.set_trigger(false)
	check(reference.loaded_ammo_count == 7, "a pull after the interval fires again")
	await _warm_clip(pistol, base.reload_clip_path())
	check(pistol.reload(), "the reload starts while the attack clip fades out")
	var reload_started := Time.get_ticks_msec()
	await get_tree().create_timer(pistol.shot_interval() + 0.05).timeout
	pistol.set_trigger(true)
	pistol.set_trigger(false)
	check(reference.loaded_ammo_count == 7, "firing during the reload does nothing")
	await _wait_until(func() -> bool: return reference.loaded_ammo_count == base.clip_size)
	var reload_seconds := (Time.get_ticks_msec() - reload_started) / 1000.0
	var clip: Animation = pistol._clips.get(base.reload_clip_path())
	check(clip != null and reload_seconds >= clip.length * 0.9, "the reload refills when its own %.2f s clip ends (%.2f s)" % [clip.length if clip != null else 0.0, reload_seconds])


func _check_dry_fire_and_slide() -> void:
	var pistol := await _place(PISTOL)
	var reference := pistol.get_weapon_reference()
	var base := pistol.get_weapon_base()
	var clicks := {"count": 0}
	pistol.dry_fired.connect(func() -> void: clicks["count"] += 1)
	reference.loaded_ammo_count = 0
	pistol.set_trigger(true)
	await get_tree().create_timer(1.0).timeout
	pistol.set_trigger(false)
	check(clicks["count"] == 1, "empty, a trigger held for 1 s clicks once (%d)" % clicks["count"])
	pistol.set_trigger(true)
	pistol.set_trigger(false)
	check(clicks["count"] == 2, "a new pull clicks again (%d)" % clicks["count"])

	reference.loaded_ammo_count = 5
	var path := base.attack_clip_path()
	await _warm_clip(pistol, path)
	await get_tree().create_timer(pistol.shot_interval() + 0.05).timeout
	pistol.set_trigger(true)
	pistol.set_trigger(false)
	await get_tree().create_timer(pistol.shot_interval() + 0.05).timeout
	pistol.set_trigger(true)
	pistol.set_trigger(false)
	check(reference.loaded_ammo_count == 3, "two shots fired")
	await _frames(3)
	var clip: Animation = pistol._clips.get(path)
	var slide := pistol.get_part("##Slide")
	var track := -1
	for index in clip.get_track_count():
		if String(clip.track_get_path(index)) == NifNames.escape("##Slide") and clip.track_get_type(index) == Animation.TYPE_POSITION_3D:
			track = index
	var time := pistol.get_animator().get_time(EsmWeaponNode.SLOT_ACTION)
	check(slide != null and track != -1 and slide.position.is_equal_approx(clip.position_track_interpolate(track, time)),
			"on the second shot ##Slide follows the attack clip at %.3f s at full weight (%s, clip %s)" % [time, slide.position if slide != null else Vector3(), clip.position_track_interpolate(track, time) if track != -1 else Vector3()])


## A WEAP's EsmWeaponNode, with no holder, once its model has loaded.
func _place(editor_id: String) -> EsmWeaponNode:
	var base := EsmServer.find_base_by_editor_id(editor_id) as WeaponBase
	var reference := EsmServer.create_runtime_reference(base.form_id) as WeaponReference
	var node := EsmReferencePhysicaliser.new().physicalise(reference, self) as EsmWeaponNode
	await _wait_until(func() -> bool: return node._visual_node(node.visual_detail) != null)
	return node


## Loads `path` into the node's clip cache, so timing checks do not wait on it.
func _warm_clip(node: EsmWeaponNode, path: String) -> void:
	if node._clips.has(path):
		return
	NifServer.request_kf(path, node, node._on_clip_delivered.bind(-1, path))
	await _wait_until(func() -> bool: return node._clips.has(path))


func _wait_until(condition: Callable) -> void:
	for frame in FRAMES:
		if condition.call():
			return
		await get_tree().process_frame


func _frames(count: int) -> void:
	for frame in count:
		await get_tree().process_frame
