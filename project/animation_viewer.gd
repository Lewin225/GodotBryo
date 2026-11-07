extends Node3D

## Animation viewer (launcher: Animation viewer): one NPC_'s actor node on a
## floor, with no cell, streaming or controller, so it starts and stops in
## seconds. Plans/Actors/animation_blending.md. The NPC drop-down lists every
## NPC_ base form by EditorID (the filter narrows it); picking one builds it
## from a reference made for the base (EsmServer.create_reference_for_base,
## so it wears what its base's inventory gives it), and nothing is shown until
## one is picked. Back returns to the launcher.
##
## ActorAnimator's KfAnimator plays NifServer's clips directly, one slot per
## animation group section; ActorAnimator's own locomotion choice is turned off
## once it loads. Movement plays a locomotion KF in slot 1 (Movement). The IDLE list
## holds every IDLE with a KF under characters\_male\, filtered by section (DATA
## byte 0, low six bits) and by text; Play starts the selected IDLE's KF in its
## section's slot, with its StartLoop / EndLoop keys as the loop section, and
## Stop fades that slot out. The weapon panel on the right lists the KFs
## directly in meshes/characters/_male/ (the shared and weapon clips, which no
## IDLE names) and plays the selected one, without root tracks, in the slot
## chosen above it. Clear empties every slot and returns the skeleton to its rest pose. Fade, tie mode, update interval and pause set the
## KfAnimator's; the slider seeks the last slot played. Look At toggles
## ActorHeadTracking's LookAtModifier3D; IK adds a TwoBoneIK3D on the right arm
## reaching for a target circling the hand. Right mouse drag orbits the camera,
## the wheel zooms.
##
## The section list's "Doc (VCG01)" entry holds the IDLEs Doc Mitchell plays in
## VCG01 (_diag/diag_doc_idles: his chair, dialogue responses, packages and
## scripts). IDLEs play through ActorAnimator.play_idle, which puts each in its
## section's slot and ends a once-only one when it finishes. "Sit, idles,
## stand" plays his chair enter, the seated loop, each of his seated VCG01
## idles over it in turn (SEATED_IDLES) and the exit, as FurnitureSeating and
## dialogue would; "Idle fades" sets ActorAnimator's fade_from_text_keys. Root motion sets the
## KfAnimator's root_motion_mode and hold_unkeyed_root; the actor node is moved
## by get_root_motion(), from where it stood when each root clip started, and
## Reset puts it back at the origin. With "Emulate furniture", the sit sequence
## moves the actor onto the seat when the enter ends (by the enter's Bip01
## translation and NonAccum yaw change, start to end), puts it back in the
## enter's frame when the exit starts, and turns it by stop_idle()'s reported
## torso turn when the exit ends, as FurnitureSeating does on standing up.
## With "Whole Body ends other idles", an IDLE of section 20 (Whole Body), once
## its clip plays, ends the idles in every other slot: the section read as
## taking the whole body (the chair exit ends the seated loop under it).
##
## ANIMATION_VIEWER_NPC (an EditorID) picks that NPC at start. With
## KF_TEST_PROBE set as well, it prints the IK hand distance and quits.

const ACTOR_SCENE := preload("res://GodotBryo/Types/Node/esm_actor_node.tscn")
const LAUNCHER_SCENE := "res://launcher.tscn"
const SECTION_MASK := 0x3F
const SECTION_NAMES := {
	0: "Idle",
	4: "Weapon",
	7: "Special Idle",
	20: "Whole Body",
	21: "Upper Body",
}
const MOVEMENT_SLOT := 1
## Animation group section 20, Whole Body.
const WHOLE_BODY_SECTION := 20
## How many frames _play_idle waits for a Whole Body idle's clip to start.
const START_WAIT_FRAMES := 300
## The section list's entry for Doc's VCG01 IDLEs, not a section number.
const DOC_SOURCE := -2
## Doc Mitchell's VCG01 IDLEs in the order he meets them: his chair's enter and
## seated loop, the dialogue gestures, his packages' and script's idles, the
## chair's exit (_diag/diag_doc_idles).
const DOC_IDLES := ["ChairFrontSit", "ChairDynamicIdle", "SitChairTalkPlayerA", "SitChairTalkPlayerD",
	"VCG01DocWhoaThere", "VCG01DocCardPoint01", "VCG01DocCardPoint02", "VCG01DocCardPoint03",
	"VCG01DocShrug", "VCG01DocGiveMirror", "GivePipBoy", "LooseDoctorHealPlayer", "NPCSmokingIdle",
	"ChairFrontStand"]
## How long the seated loop plays before the first seated idle, and after the
## last before the exit, in the sit sequence, seconds.
const SEQUENCE_PAUSE := 2.0
## The idles Doc plays seated in VCG01, played in turn over the seated loop by
## the sit sequence (_diag/diag_doc_idles).
const SEATED_IDLES := ["SitChairTalkPlayerA", "VCG01DocCardPoint01", "VCG01DocCardPoint02",
	"VCG01DocCardPoint03", "VCG01DocShrug", "VCG01DocWhoaThere", "VCG01DocGiveMirror"]
## The longest a seated idle plays in the sequence before it is ended (a
## looping one would not finish), and the gap after each, seconds.
const SEATED_IDLE_LONGEST := 6.0
const SEQUENCE_GAP := 0.5
## Slots a weapon KF can be played in: every animation group section.
const WEAPON_SLOTS := {
	1: "Movement",
	2: "Left Arm",
	3: "Left Hand",
	4: "Weapon",
	5: "Weapon Up",
	6: "Weapon Down",
	7: "Special Idle",
	20: "Whole Body",
	21: "Upper Body",
}
const CHARACTER_FOLDER := "meshes/characters/_male/"
const IDLE_FOLDER := "characters\\_male\\"
const LOCOMOTION_FOLDER := "meshes/characters/_male/locomotion/"
## Movement choices: label -> KF below LOCOMOTION_FOLDER, or "" for none.
const MOVEMENTS := {
	"None": "",
	"Idle": "mtidle.kf",
	"Forward": "male/mtforward.kf",
	"Backward": "male/mtbackward.kf",
	"Left": "male/mtleft.kf",
	"Right": "male/mtright.kf",
	"Fast Forward": "male/mtfastforward.kf",
	"Turn Left": "mtturnleft.kf",
	"Turn Right": "mtturnright.kf",
}
const IK_ROOT_BONE := "Bip01 R UpperArm"
const IK_MIDDLE_BONE := "Bip01 R Forearm"
const IK_END_BONE := "Bip01 R Hand"
const IK_TARGET_RADIUS := 0.15
## How far the pole sits out from the elbow, metres.
const IK_POLE_DISTANCE := 0.3
const CAMERA_FOCUS := Vector3(0.0, 1.0, 0.0)
const ORBIT_SPEED := 0.01

var _actor: EsmActorNode = null
var _animator: KfAnimator = null
var _camera: Camera3D = null
var _yaw := PI
var _pitch := -0.2
var _distance := 3.0
var _orbiting := false
var _idles_by_section := {}
## The KFs directly in CHARACTER_FOLDER, canonical paths.
var _weapon_kfs := PackedStringArray()
## The slot the seek slider moves.
var _seek_slot := MOVEMENT_SLOT
## Each request's number by slot; a KF that arrives after a newer request for
## its slot is dropped.
var _request_serials := {}
## The root clip get_root_motion() was last measured from, and the actor
## node's transform when it started.
var _root_serial := 0
var _root_base := Transform3D.IDENTITY
## Bumped to cancel a running sit sequence.
var _sequence := 0
var _ik: TwoBoneIK3D = null
var _ik_target: Marker3D = null
var _ik_pole: Marker3D = null
## Where the IK target circles: the hand's position when IK was first turned on.
var _ik_centre := Vector3.ZERO
var _ik_time := 0.0

var _movement: OptionButton = null
var _npc_filter: LineEdit = null
var _npc: OptionButton = null
## Every NPC_ base form: [EditorID, FormID], sorted by EditorID.
var _npc_bases: Array = []
var _section: OptionButton = null
var _filter: LineEdit = null
var _idle_list: ItemList = null
var _weapon_slot: OptionButton = null
var _weapon_filter: LineEdit = null
var _weapon_list: ItemList = null
var _fade: SpinBox = null
var _tie_mode: OptionButton = null
var _interval: SpinBox = null
var _pause: CheckButton = null
var _scrub: HSlider = null
var _look_at: CheckButton = null
var _ik_toggle: CheckButton = null
var _root_mode: OptionButton = null
var _hold_root: CheckButton = null
var _emulate_furniture: CheckButton = null
var _whole_body_ends_others: CheckButton = null
var _fade_source: OptionButton = null
var _status: Label = null


func _ready() -> void:
	_build_world()
	_build_ui()
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	_collect_idles()
	_collect_weapon_kfs()
	_fill_idle_list()
	_fill_weapon_list()
	_collect_npcs()
	_fill_npc_list()
	if OS.has_environment("ANIMATION_VIEWER_NPC"):
		_pick_npc(OS.get_environment("ANIMATION_VIEWER_NPC"))


## Selects and shows the NPC_ base with EditorID `editor_id`, if there is one.
func _pick_npc(editor_id: String) -> void:
	for index in _npc.item_count:
		if _npc.get_item_text(index).get_slice(" ", 0).to_lower() == editor_id.to_lower():
			_npc.select(index)
			_on_npc_selected(index)
			return
	push_warning("AnimationViewer: no NPC_ with EditorID " + editor_id)

## Every NPC_ base form in the record index, by EditorID.
func _collect_npcs() -> void:
	_npc_bases.clear()
	for row: Dictionary in EsmServer.get_record_index():
		if String(row.get("record_type", "")) != "NPC_":
			continue
		var editor_id := String(row.get("editor_id", ""))
		if editor_id.is_empty():
			continue
		_npc_bases.append([editor_id, int(row["form_id"])])
	_npc_bases.sort_custom(func(a: Array, b: Array) -> bool: return String(a[0]).naturalnocasecmp_to(String(b[0])) < 0)


## Fills the NPC drop-down with the bases whose EditorID contains the filter's
## text, after a "Pick an NPC" entry.
func _fill_npc_list() -> void:
	_npc.clear()
	_npc.add_item("Pick an NPC (%d)" % _npc_bases.size(), 0)
	var needle := _npc_filter.text.strip_edges().to_lower()
	for entry: Array in _npc_bases:
		if needle.is_empty() or String(entry[0]).to_lower().contains(needle):
			_npc.add_item("%s  %08X" % [entry[0], entry[1]], int(entry[1]))
	_npc.select(0)


func _on_npc_selected(index: int) -> void:
	var form_id := _npc.get_item_id(index)
	if form_id != 0:
		_show_npc(form_id)


## Replaces the shown actor with one built for base `form_id`.
func _show_npc(form_id: int) -> void:
	_sequence += 1
	_request_serials.clear()
	_animator = null
	_ik = null
	_ik_toggle.set_pressed_no_signal(false)
	_ik_target.visible = false
	if _actor != null and is_instance_valid(_actor):
		remove_child(_actor)
		_actor.queue_free()
	# The actor node's own preview path: a reference made for the base.
	_actor = ACTOR_SCENE.instantiate() as EsmActorNode
	_actor.preset = "Custom"
	_actor.custom_base_form_id = "%X" % form_id
	add_child(_actor)
	_actor._editor_load()
	if _actor.reference == null:
		push_warning("AnimationViewer: base %08X is not an actor" % form_id)
		return
	_actor.load_actor()
	_actor.animation_load_completed.connect(_on_animation_loaded)


func _build_world() -> void:
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.25, 0.27, 0.3)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color(0.6, 0.6, 0.6)
	add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-50.0), deg_to_rad(30.0), 0.0)
	sun.shadow_enabled = true
	add_child(sun)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(10.0, 10.0)
	floor_mesh.mesh = plane
	add_child(floor_mesh)
	_camera = Camera3D.new()
	add_child(_camera)
	_update_camera()
	_ik_target = Marker3D.new()
	_ik_target.name = "IkTarget"
	add_child(_ik_target)
	var target_mesh := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.03
	sphere.height = 0.06
	target_mesh.mesh = sphere
	_ik_target.add_child(target_mesh)
	_ik_target.visible = false
	_ik_pole = Marker3D.new()
	_ik_pole.name = "IkPole"
	add_child(_ik_pole)


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(8, 8)
	panel.custom_minimum_size = Vector2(400, 0)
	layer.add_child(panel)
	var box := VBoxContainer.new()
	panel.add_child(box)

	var back := Button.new()
	back.text = "Back to launcher"
	back.pressed.connect(func() -> void: get_tree().change_scene_to_file(LAUNCHER_SCENE))
	box.add_child(back)

	_npc_filter = LineEdit.new()
	_npc_filter.placeholder_text = "Filter NPCs by EditorID"
	_npc_filter.text_changed.connect(func(_text: String) -> void: _fill_npc_list())
	box.add_child(_npc_filter)
	_npc = OptionButton.new()
	_npc.add_item("Loading...", 0)
	_npc.item_selected.connect(_on_npc_selected)
	box.add_child(_labelled("NPC", _npc))

	_movement = OptionButton.new()
	for movement: String in MOVEMENTS:
		_movement.add_item(movement)
	_movement.item_selected.connect(_on_movement_selected)
	box.add_child(_labelled("Movement (slot 1)", _movement))

	_section = OptionButton.new()
	for section: int in SECTION_NAMES:
		_section.add_item("%d %s" % [section, SECTION_NAMES[section]], section)
	_section.add_item("Doc (VCG01)", DOC_SOURCE)
	_section.select(2)
	_section.item_selected.connect(func(_index: int) -> void: _fill_idle_list())
	box.add_child(_labelled("IDLE section", _section))

	_filter = LineEdit.new()
	_filter.placeholder_text = "Filter IDLEs"
	_filter.text_changed.connect(func(_text: String) -> void: _fill_idle_list())
	box.add_child(_filter)

	_idle_list = ItemList.new()
	_idle_list.custom_minimum_size = Vector2(0, 240)
	_idle_list.item_activated.connect(func(_index: int) -> void: _play_selected_idle())
	box.add_child(_idle_list)

	var idle_buttons := HBoxContainer.new()
	var play := Button.new()
	play.text = "Play in its section's slot"
	play.pressed.connect(_play_selected_idle)
	idle_buttons.add_child(play)
	var stop := Button.new()
	stop.text = "Stop section slot"
	stop.pressed.connect(_stop_section)
	idle_buttons.add_child(stop)
	var clear := Button.new()
	clear.text = "Clear all"
	clear.pressed.connect(_clear_slots)
	idle_buttons.add_child(clear)
	box.add_child(idle_buttons)

	_fade = SpinBox.new()
	_fade.min_value = 0.0
	_fade.max_value = 2.0
	_fade.step = 0.05
	_fade.value = 0.2
	box.add_child(_labelled("Fade seconds", _fade))

	_tie_mode = OptionButton.new()
	_tie_mode.add_item("Blend", KfAnimator.TIE_BLEND)
	_tie_mode.add_item("Newest", KfAnimator.TIE_NEWEST)
	_tie_mode.item_selected.connect(func(_index: int) -> void: _apply_settings())
	box.add_child(_labelled("Equal priority", _tie_mode))

	_interval = SpinBox.new()
	_interval.min_value = 1
	_interval.max_value = 60
	_interval.value = 1
	_interval.value_changed.connect(func(_value: float) -> void: _apply_settings())
	box.add_child(_labelled("Update every N frames", _interval))

	_pause = CheckButton.new()
	_pause.text = "Pause"
	_pause.toggled.connect(func(_on: bool) -> void: _apply_settings())
	box.add_child(_pause)

	_scrub = HSlider.new()
	_scrub.step = 0.0
	_scrub.value_changed.connect(_on_scrub)
	box.add_child(_labelled("Seek (paused)", _scrub))

	_look_at = CheckButton.new()
	_look_at.text = "Look At (head)"
	_look_at.button_pressed = true
	_look_at.toggled.connect(_on_look_at_toggled)
	box.add_child(_look_at)

	_ik_toggle = CheckButton.new()
	_ik_toggle.text = "IK (right arm)"
	_ik_toggle.toggled.connect(_on_ik_toggled)
	box.add_child(_ik_toggle)

	_root_mode = OptionButton.new()
	_root_mode.add_item("None", KfAnimator.ROOT_MOTION_NONE)
	_root_mode.add_item("Bip01 translation", KfAnimator.ROOT_MOTION_BIP01)
	_root_mode.add_item("Bip01 + NonAccum yaw", KfAnimator.ROOT_MOTION_BIP01_NONACCUM_YAW)
	_root_mode.add_item("NonAccum (XY + yaw)", KfAnimator.ROOT_MOTION_NONACCUM)
	_root_mode.add_item("Root transform (Bip01 then NonAccum facing)", KfAnimator.ROOT_MOTION_ROOT_TRANSFORM)
	_root_mode.select(_root_mode.get_item_index(KfAnimator.ROOT_MOTION_ROOT_TRANSFORM))
	_root_mode.item_selected.connect(func(_index: int) -> void:
		_apply_settings()
		_on_movement_selected(_movement.selected))
	box.add_child(_labelled("Root motion", _root_mode))

	var root_row := HBoxContainer.new()
	_hold_root = CheckButton.new()
	_hold_root.text = "Unkeyed Bip01 at clip origin"
	_hold_root.toggled.connect(func(_on: bool) -> void: _apply_settings())
	root_row.add_child(_hold_root)
	var reset := Button.new()
	reset.text = "Reset position"
	reset.pressed.connect(_reset_position)
	root_row.add_child(reset)
	box.add_child(root_row)

	var sequence_row := HBoxContainer.new()
	var sequence := Button.new()
	sequence.text = "Sit, idles, stand"
	sequence.pressed.connect(_play_sit_sequence)
	sequence_row.add_child(sequence)
	_emulate_furniture = CheckButton.new()
	_emulate_furniture.text = "Emulate furniture"
	sequence_row.add_child(_emulate_furniture)
	box.add_child(sequence_row)

	_fade_source = OptionButton.new()
	_fade_source.add_item("Fixed 0.2 s")
	_fade_source.add_item("Blend text keys (N/30 s)")
	_fade_source.item_selected.connect(func(index: int) -> void: _actor.animator.fade_from_text_keys = index == 1)
	box.add_child(_labelled("Idle fades", _fade_source))

	_whole_body_ends_others = CheckButton.new()
	_whole_body_ends_others.text = "Whole Body ends other idles"
	_whole_body_ends_others.button_pressed = true
	box.add_child(_whole_body_ends_others)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)

	_build_weapon_panel(layer)


## The right-hand panel: the weapon KFs, the slot they play in, Play and Stop.
func _build_weapon_panel(layer: CanvasLayer) -> void:
	var panel := PanelContainer.new()
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.offset_left = -368
	panel.offset_right = -8
	panel.offset_top = 8
	layer.add_child(panel)
	var box := VBoxContainer.new()
	panel.add_child(box)

	_weapon_slot = OptionButton.new()
	for slot: int in WEAPON_SLOTS:
		_weapon_slot.add_item("%d %s" % [slot, WEAPON_SLOTS[slot]], slot)
	_weapon_slot.select(3)
	box.add_child(_labelled("Weapon KF slot", _weapon_slot))

	_weapon_filter = LineEdit.new()
	_weapon_filter.placeholder_text = "Filter weapon KFs"
	_weapon_filter.text_changed.connect(func(_text: String) -> void: _fill_weapon_list())
	box.add_child(_weapon_filter)

	_weapon_list = ItemList.new()
	_weapon_list.custom_minimum_size = Vector2(0, 400)
	_weapon_list.item_activated.connect(func(_index: int) -> void: _play_selected_weapon_kf())
	box.add_child(_weapon_list)

	var buttons := HBoxContainer.new()
	var play := Button.new()
	play.text = "Play in slot"
	play.pressed.connect(_play_selected_weapon_kf)
	buttons.add_child(play)
	var stop := Button.new()
	stop.text = "Stop slot"
	stop.pressed.connect(_stop_weapon_slot)
	buttons.add_child(stop)
	box.add_child(buttons)


func _labelled(text: String, control: Control) -> Control:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(160, 0)
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row


## Every IDLE with a KF under IDLE_FOLDER, by section.
func _collect_idles() -> void:
	for row: Dictionary in EsmServer.get_record_index():
		if String(row.get("record_type", "")) != "IDLE":
			continue
		var idle := EsmServer.get_base(int(row["form_id"])) as IdleBase
		if idle == null or not idle.has_kf():
			continue
		if not idle.model_path.to_lower().begins_with(IDLE_FOLDER):
			continue
		var section := idle.animation_group_section & SECTION_MASK
		if not _idles_by_section.has(section):
			_idles_by_section[section] = []
		_idles_by_section[section].append(idle)


## The KFs directly in CHARACTER_FOLDER.
func _collect_weapon_kfs() -> void:
	for path in ArchiveServer.list_files_with_prefix(CHARACTER_FOLDER):
		var canonical := String(path).replace("\\", "/").to_lower()
		if not canonical.ends_with(".kf"):
			continue
		if canonical.trim_prefix(CHARACTER_FOLDER).contains("/"):
			continue
		_weapon_kfs.append(canonical)
	_weapon_kfs.sort()


func _fill_idle_list() -> void:
	_idle_list.clear()
	var section := _section.get_selected_id()
	var filter_text := _filter.text.to_lower().strip_edges()
	var idles: Array = _idles_by_section.get(section, [])
	if section == DOC_SOURCE:
		idles = DOC_IDLES.map(func(editor_id: String) -> IdleBase: return EsmServer.find_base_by_editor_id(editor_id) as IdleBase)
	for idle: IdleBase in idles:
		if idle == null:
			continue
		var text := "%s  %s" % [idle.editor_id, idle.model_path.get_file()]
		if not filter_text.is_empty() and not text.to_lower().contains(filter_text):
			continue
		var index := _idle_list.add_item(text)
		_idle_list.set_item_metadata(index, idle)


func _fill_weapon_list() -> void:
	_weapon_list.clear()
	var filter_text := _weapon_filter.text.to_lower().strip_edges()
	for path in _weapon_kfs:
		var file := path.get_file()
		if not filter_text.is_empty() and not file.contains(filter_text):
			continue
		var index := _weapon_list.add_item(file)
		_weapon_list.set_item_metadata(index, path)


## ActorAnimator has loaded: takes over its KfAnimator, with ActorAnimator's
## own locomotion choice turned off.
func _on_animation_loaded(clip_count: int) -> void:
	var idle_count := 0
	for idles: Array in _idles_by_section.values():
		idle_count += idles.size()
	print("AnimationViewer: %d locomotion clips, %d IDLEs with a KF" % [clip_count, idle_count])
	_actor.animator.set_physics_process(false)
	_animator = _actor.animator.get_kf_animator()
	_animator.clip_finished.connect(_on_clip_finished)
	_animator.text_key.connect(_on_text_key)
	_apply_settings()
	_on_look_at_toggled(_look_at.button_pressed)
	_movement.select(1)
	_on_movement_selected(1)
	if OS.has_environment("KF_TEST_PROBE"):
		_probe.call_deferred()


## Headless check: the right hand's distance to the IK target with IK off and
## on, measured on skeleton_updated, after the modifiers and before Skeleton3D
## restores the pose.
func _probe() -> void:
	var skeleton := _skeleton()
	var hand := skeleton.find_bone(IK_END_BONE)
	for on in [false, true]:
		_on_ik_toggled(on)
		for i in 30:
			await get_tree().process_frame
		await skeleton.skeleton_updated
		var hand_position := (skeleton.global_transform * skeleton.get_bone_global_pose(hand)).origin
		print("PROBE ik %s: hand %.3f m from target" % [on, hand_position.distance_to(_ik_target.global_position)])
	await _probe_timing()
	print("PROBE weapon KFs: %d, first %s" % [_weapon_kfs.size(), _weapon_kfs[0] if not _weapon_kfs.is_empty() else ""])
	_request(4, _weapon_kfs[0], false)
	for i in 30:
		await get_tree().process_frame
	print("PROBE status: ", _status.text.replace("\n", " | "))
	_clear_slots()
	await get_tree().process_frame
	print("PROBE after clear: ", _status.text)
	var enter := EsmServer.find_base_by_editor_id("ChairFrontSit") as IdleBase
	for mode in [KfAnimator.ROOT_MOTION_BIP01_NONACCUM_YAW, KfAnimator.ROOT_MOTION_ROOT_TRANSFORM]:
		_reset_position()
		_root_mode.select(_root_mode.get_item_index(mode))
		_apply_settings()
		_actor.animator.play_idle(enter)
		await _idle_finished(enter)
		await get_tree().process_frame
		print("PROBE root mode %d: chair enter moves Doc %.2f m, turns him %.0f degrees" % [mode,
			_actor.position.length(), rad_to_deg(_actor.rotation.y)])
		var after_enter := _actor.position
		var loop := EsmServer.find_base_by_editor_id("ChairDynamicIdle") as IdleBase
		_actor.animator.play_idle(loop)
		for frame in 30:
			await get_tree().process_frame
		print("PROBE root mode %d: seated loop leaves Doc %.2f m from the seat" % [mode, _actor.position.distance_to(after_enter)])
		var exit := EsmServer.find_base_by_editor_id("ChairFrontStand") as IdleBase
		_on_movement_selected(_movement.selected)
		_play_idle(exit)
		await _idle_finished(exit)
		if mode == KfAnimator.ROOT_MOTION_ROOT_TRANSFORM:
			await _probe_heights("exit end into %s" % _actor.animator.playing_clip())
		await get_tree().process_frame
		print("PROBE root mode %d: after the exit Doc is %.2f m from where he started, turned %.0f degrees" % [mode,
			_actor.position.length(), rad_to_deg(_actor.rotation.y)])
		_actor.animator.stop_idle()
		await get_tree().process_frame
	get_tree().quit()


## Headless timing: the cost of one pose write with 1, 2 and 3 clips playing.
func _probe_timing() -> void:
	const RUNS := 1000
	var kfs := [LOCOMOTION_FOLDER + "male/mtforward.kf",
		"meshes/characters/_male/idleanims/specialidle_cardpoint01.kf",
		"meshes/characters/_male/1gtaim.kf"]
	var slots := [MOVEMENT_SLOT, 7, 4]
	_animator.stop_all()
	for i in kfs.size():
		_request(slots[i], kfs[i], i == 1)
		for frame in 20:
			await get_tree().process_frame
		var begin := Time.get_ticks_usec()
		for run in RUNS:
			_animator.update_pose()
		var usec := float(Time.get_ticks_usec() - begin) / RUNS
		print("PROBE KfAnimator pose write, %d clips: %.1f us" % [i + 1, usec])
	_animator.stop_all()


## Prints, for 40 frames, the pelvis's and the left calf's height above the
## actor's origin and the left knee's bend (calf rotation from rest), with
## each slot's clip and weight.
func _probe_heights(label: String) -> void:
	var skeleton := _skeleton()
	var pelvis := skeleton.find_bone(NifNames.escape("Bip01 Pelvis"))
	var calf := skeleton.find_bone(NifNames.escape("Bip01 L Calf"))
	var non_accum := skeleton.find_bone(NifNames.escape("Bip01 NonAccum"))
	print("PROBE heights, %s" % label)
	for frame in 40:
		await skeleton.skeleton_updated
		var pelvis_height := (skeleton.global_transform * skeleton.get_bone_global_pose(pelvis)).origin.y - _actor.global_position.y
		var non_accum_height := (skeleton.global_transform * skeleton.get_bone_global_pose(non_accum)).origin.y - _actor.global_position.y
		var bend := rad_to_deg(skeleton.get_bone_pose_rotation(calf).angle_to(skeleton.get_bone_rest(calf).basis.get_rotation_quaternion()))
		print("PROBE   frame %2d  pelvis %.3f m  non_accum %.3f m  knee %.0f  slots %s" % [frame, pelvis_height, non_accum_height, bend, _animator.get_slots()])


## The skeleton the body is skinned to: the one ActorHeadTracking put its
## modifier on.
func _skeleton() -> Skeleton3D:
	var tracking := _actor.head_tracking if _actor != null else null
	var modifier := tracking.get_modifier() if tracking != null else null
	if modifier == null:
		return null
	return modifier.get_parent() as Skeleton3D


func _apply_settings() -> void:
	if _animator == null:
		return
	_animator.tie_mode = _tie_mode.get_selected_id()
	_animator.update_interval = int(_interval.value)
	_animator.paused = _pause.button_pressed
	_animator.root_motion_mode = _root_mode.get_selected_id()
	_animator.hold_unkeyed_root = _hold_root.button_pressed


func _on_movement_selected(index: int) -> void:
	if _animator == null:
		return
	var file: String = MOVEMENTS[_movement.get_item_text(index)]
	if file.is_empty():
		_request_serials[MOVEMENT_SLOT] = int(_request_serials.get(MOVEMENT_SLOT, 0)) + 1
		_animator.stop(MOVEMENT_SLOT, _fade.value)
		return
	# Under ROOT_TRANSFORM locomotion plays its root tracks, as ActorAnimator
	# does; _apply_root_motion drops its motion.
	var keeps_root := _root_mode.get_selected_id() == KfAnimator.ROOT_MOTION_ROOT_TRANSFORM
	_request(MOVEMENT_SLOT, LOCOMOTION_FOLDER + file, keeps_root)


func _play_selected_idle() -> void:
	var selected := _idle_list.get_selected_items()
	if selected.is_empty() or _animator == null:
		return
	var idle := _idle_list.get_item_metadata(selected[0]) as IdleBase
	_play_idle(idle)
	_seek_slot = idle.animation_group_section & SECTION_MASK


func _stop_section() -> void:
	if _animator == null:
		return
	var selected := _idle_list.get_selected_items()
	if selected.is_empty():
		_actor.animator.stop_idle()
		return
	_actor.animator.stop_idle(_idle_list.get_item_metadata(selected[0]) as IdleBase)


## Doc's chair enter, the seated loop, his seated idles over it in turn, then the
## exit; each step waits for the one before as FurnitureSeating does.
func _play_sit_sequence() -> void:
	if _animator == null:
		return
	_sequence += 1
	var sequence := _sequence
	var animator := _actor.animator
	animator.stop_idle()
	var enter := EsmServer.find_base_by_editor_id("ChairFrontSit") as IdleBase
	var before_sitting := _actor.transform
	_play_idle(enter)
	await _idle_finished(enter)
	if sequence != _sequence:
		return
	var enter_change := Transform3D.IDENTITY
	if _emulate_furniture.button_pressed:
		var enter_slot := enter.animation_group_section & SECTION_MASK
		enter_change = _clip_root_change(_animator.get_animation(enter_slot))
		_actor.transform = before_sitting * _to_actor(enter_change)
	_play_idle(EsmServer.find_base_by_editor_id("ChairDynamicIdle") as IdleBase)
	await get_tree().create_timer(SEQUENCE_PAUSE).timeout
	for editor_id: String in SEATED_IDLES:
		if sequence != _sequence:
			return
		var gesture := EsmServer.find_base_by_editor_id(editor_id) as IdleBase
		_play_idle(gesture)
		await _idle_finished_or(gesture, SEATED_IDLE_LONGEST)
		if sequence != _sequence:
			return
		_actor.animator.stop_idle(gesture)
		await get_tree().create_timer(SEQUENCE_GAP).timeout
	await get_tree().create_timer(SEQUENCE_PAUSE).timeout
	if sequence != _sequence:
		return
	var exit := EsmServer.find_base_by_editor_id("ChairFrontStand") as IdleBase
	if _emulate_furniture.button_pressed:
		_actor.transform = _exit_frame(before_sitting, enter_change)
	_play_idle(exit)
	await _idle_finished(exit)
	if sequence != _sequence:
		return
	animator.stop_idle()


## Plays `idle` through ActorAnimator; a Whole Body one, with the toggle on,
## then ends the idles in every other slot once its clip plays.
func _play_idle(idle: IdleBase) -> void:
	var slot := idle.animation_group_section & SECTION_MASK
	var previous := _animator.get_animation(slot)
	_actor.animator.play_idle(idle)
	if slot != WHOLE_BODY_SECTION or not _whole_body_ends_others.button_pressed:
		return
	for frame in START_WAIT_FRAMES:
		var playing := _animator.get_animation(slot)
		if playing != null and playing != previous:
			break
		await get_tree().process_frame
	var idles: Dictionary = _actor.animator.get_idles()
	for other: int in idles:
		if other != slot:
			_actor.animator.stop_idle(idles[other])


## Waits until the actor's animator reports `idle` finished, or `seconds`.
func _idle_finished_or(idle: IdleBase, seconds: float) -> void:
	var done := [false]
	var on_finished := func(finished: IdleBase) -> void:
		if finished == idle:
			done[0] = true
	_actor.animator.idle_finished.connect(on_finished)
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while not done[0] and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_actor.animator.idle_finished.disconnect(on_finished)


## Waits until the actor's animator reports `idle` finished.
func _idle_finished(idle: IdleBase) -> void:
	while true:
		var finished: IdleBase = await _actor.animator.idle_finished
		if finished == idle:
			return


func _reset_position() -> void:
	_actor.transform = Transform3D.IDENTITY
	_root_base = Transform3D.IDENTITY


## Where the actor stands for the exit, which is authored in the enter's frame:
## where the enter started when the clips draw their own root (mode None), and
## moved by the enter's translation but not its turn when root motion moves
## the actor (the exit's own motion then carries it back off the seat).
func _exit_frame(before_sitting: Transform3D, enter_change: Transform3D) -> Transform3D:
	if _root_mode.get_selected_id() == KfAnimator.ROOT_MOTION_NONE:
		return before_sitting
	return before_sitting * _to_actor(Transform3D(Basis.IDENTITY, enter_change.origin))


## `animation`'s root change from start to end, skeleton space: Bip01's
## translation and Bip01 NonAccum's yaw about Z (identity for either it lacks).
func _clip_root_change(animation: Animation) -> Transform3D:
	if animation == null:
		return Transform3D.IDENTITY
	var translation := Vector3.ZERO
	var root_track := animation.find_track(NodePath("Bip01"), Animation.TYPE_POSITION_3D)
	if root_track != -1:
		translation = animation.position_track_interpolate(root_track, animation.length) \
				- animation.position_track_interpolate(root_track, 0.0)
	var yaw := 0.0
	var non_accum := NodePath(NifNames.escape("Bip01 NonAccum"))
	var rotation_track := animation.find_track(non_accum, Animation.TYPE_ROTATION_3D)
	if rotation_track != -1:
		yaw = _yaw_about_z(animation.rotation_track_interpolate(rotation_track, animation.length)) \
				- _yaw_about_z(animation.rotation_track_interpolate(rotation_track, 0.0))
	return Transform3D(Basis(Vector3(0.0, 0.0, 1.0), yaw), translation)


## Rotation about Z of `rotation`'s X axis, radians.
func _yaw_about_z(rotation: Quaternion) -> float:
	var axis := rotation * Vector3(1.0, 0.0, 0.0)
	return atan2(axis.y, axis.x)


## A skeleton-space transform in the actor node's space.
func _to_actor(motion: Transform3D) -> Transform3D:
	var skeleton := _skeleton()
	var axes := (_actor.global_basis.inverse() * skeleton.global_basis).orthonormalized()
	return Transform3D(axes * motion.basis * axes.inverse(), axes * motion.origin * _skeleton_scale(skeleton))


## Moves the actor node by the KfAnimator's root motion: from where it stood
## when the current root clip started, through the skeleton's axes. A
## locomotion clip's (slot 1) is dropped: walking, the controller moves the
## actor.
func _apply_root_motion() -> void:
	var serial := _animator.get_root_clip_serial()
	if serial != _root_serial:
		_root_serial = serial
		_root_base = _actor.transform
	if serial == 0 or _animator.get_root_clip_slot() == MOVEMENT_SLOT:
		return
	_actor.transform = _root_base * _to_actor(_animator.get_root_motion())


## How many metres one skeleton unit is in the actor node's space.
func _skeleton_scale(skeleton: Skeleton3D) -> float:
	return (_actor.global_basis.inverse() * skeleton.global_basis).get_scale().x


func _play_selected_weapon_kf() -> void:
	var selected := _weapon_list.get_selected_items()
	if selected.is_empty() or _animator == null:
		return
	_request(_weapon_slot.get_selected_id(), String(_weapon_list.get_item_metadata(selected[0])), false)


func _stop_weapon_slot() -> void:
	if _animator == null:
		return
	var slot := _weapon_slot.get_selected_id()
	_request_serials[slot] = int(_request_serials.get(slot, 0)) + 1
	_animator.stop(slot, _fade.value)


## Empties every slot, drops KFs still on their way and puts the skeleton back
## in its rest pose.
func _clear_slots() -> void:
	if _animator == null:
		return
	for slot: int in _request_serials:
		_request_serials[slot] = int(_request_serials[slot]) + 1
	_animator.stop_all()
	_skeleton().reset_bone_poses()
	_movement.select(0)


## Requests `path` from NifServer and plays its first clip in `slot`.
func _request(slot: int, path: String, keep_root: bool) -> void:
	var serial := int(_request_serials.get(slot, 0)) + 1
	_request_serials[slot] = serial
	NifServer.request_kf(path, self, _on_kf_delivered.bind(slot, serial, keep_root))


func _on_kf_delivered(library: AnimationLibrary, slot: int, serial: int, keep_root: bool) -> void:
	if library == null or serial != int(_request_serials.get(slot, 0)) or _animator == null:
		return
	var animation := library.get_animation(library.get_animation_list()[0])
	_animator.play(slot, animation, _fade.value, keep_root, 1.0)
	var section := _loop_section(animation)
	if section.y > section.x:
		_animator.set_loop_section(slot, section.x, section.y)
	_seek_slot = slot


## The clip's StartLoop and EndLoop text key times (rebased like its tracks),
## or (-1, -1) when it has none.
func _loop_section(animation: Animation) -> Vector2:
	var start := float(animation.get_meta("nif_start_time", 0.0))
	var section := Vector2(-1.0, -1.0)
	for key: Dictionary in animation.get_meta("nif_text_keys", []):
		var value := String(key.get("value", "")).to_lower()
		if value == "startloop":
			section.x = float(key["time"]) - start
		elif value == "endloop":
			section.y = float(key["time"]) - start
	return section


func _on_clip_finished(slot: int, animation: Animation) -> void:
	print("AnimationViewer: slot %d finished %s" % [slot, animation.get_meta("nif_sequence_name", "")])


func _on_text_key(slot: int, key: String, time: float) -> void:
	print("AnimationViewer: slot %d key '%s' at %.2f" % [slot, key, time])


func _on_scrub(value: float) -> void:
	if _animator == null or not _pause.button_pressed:
		return
	_animator.seek(_seek_slot, value)
	_animator.update_pose()


func _on_look_at_toggled(on: bool) -> void:
	var tracking := _actor.head_tracking if _actor != null else null
	var modifier := tracking.get_modifier() if tracking != null else null
	if modifier != null:
		modifier.active = on


func _on_ik_toggled(on: bool) -> void:
	_ik_target.visible = on
	if on and _ik == null:
		_ik = _make_ik()
	if _ik != null:
		_ik.active = on


## A TwoBoneIK3D on the right arm, the last modifier on the skeleton, reaching
## for the IK target, which circles the hand's current position. The pole sits
## out from the elbow, away from the line from shoulder to hand, so the elbow
## keeps bending the way it is.
func _make_ik() -> TwoBoneIK3D:
	var skeleton := _skeleton()
	if skeleton == null:
		return null
	var shoulder := _bone_position(skeleton, IK_ROOT_BONE)
	var elbow := _bone_position(skeleton, IK_MIDDLE_BONE)
	var hand := _bone_position(skeleton, IK_END_BONE)
	_ik_centre = hand
	var middle := (shoulder + hand) * 0.5
	_ik_pole.global_position = elbow + (elbow - middle).normalized() * IK_POLE_DISTANCE
	var ik := TwoBoneIK3D.new()
	ik.name = "TestRightArmIK"
	skeleton.add_child(ik)
	ik.set_setting_count(1)
	ik.set_root_bone_name(0, IK_ROOT_BONE)
	ik.set_middle_bone_name(0, IK_MIDDLE_BONE)
	ik.set_end_bone_name(0, IK_END_BONE)
	ik.set_target_node(0, ik.get_path_to(_ik_target))
	ik.set_pole_node(0, ik.get_path_to(_ik_pole))
	return ik


func _bone_position(skeleton: Skeleton3D, bone_name: String) -> Vector3:
	var bone := skeleton.find_bone(bone_name)
	return (skeleton.global_transform * skeleton.get_bone_global_pose(bone)).origin


func _process(delta: float) -> void:
	_ik_time += delta
	_ik_target.global_position = _ik_centre + Vector3(cos(_ik_time), sin(_ik_time), 0.0) * IK_TARGET_RADIUS
	if _animator == null:
		_status.text = "Pick an NPC" if _actor == null or _actor.reference == null else "Loading %s..." % _actor.reference.base.editor_id
		return
	_apply_root_motion()
	_update_status()


func _update_status() -> void:
	var lines := PackedStringArray()
	for slot in _animator.get_slots():
		var animation := _animator.get_animation(slot)
		var name := String(animation.get_meta("nif_sequence_name", "")) if animation != null else ""
		var length := animation.length if animation != null else 0.0
		lines.append("Slot %d: %s  %.2f / %.2f s  priorities %s" % [
			slot, name, _animator.get_time(slot), length, _priority_summary(animation)])
		if slot == _seek_slot and not _pause.button_pressed:
			_scrub.max_value = maxf(length, 0.001)
			_scrub.set_value_no_signal(_animator.get_time(slot))
	_status.text = "\n".join(lines) if not lines.is_empty() else "No slots playing"


## The clip's distinct controlled block priorities with how many tracks carry each.
func _priority_summary(animation: Animation) -> String:
	if animation == null or not animation.has_meta("nif_track_priorities"):
		return "(none)"
	var counts := {}
	var priorities: Dictionary = animation.get_meta("nif_track_priorities")
	for path: String in priorities:
		var priority: int = priorities[path]
		counts[priority] = int(counts.get(priority, 0)) + 1
	var keys := counts.keys()
	keys.sort()
	var parts := PackedStringArray()
	for priority: int in keys:
		parts.append("%d x%d" % [priority, counts[priority]])
	return ", ".join(parts)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_RIGHT:
			_orbiting = button.pressed
		elif button.button_index == MOUSE_BUTTON_WHEEL_UP and button.pressed:
			_distance = maxf(0.5, _distance * 0.9)
			_update_camera()
		elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN and button.pressed:
			_distance = minf(20.0, _distance * 1.1)
			_update_camera()
	elif event is InputEventMouseMotion and _orbiting:
		var motion := event as InputEventMouseMotion
		_yaw -= motion.relative.x * ORBIT_SPEED
		_pitch = clampf(_pitch - motion.relative.y * ORBIT_SPEED, -1.4, 1.4)
		_update_camera()


func _update_camera() -> void:
	var offset := Vector3(sin(_yaw) * cos(_pitch), -sin(_pitch), cos(_yaw) * cos(_pitch)) * _distance
	_camera.position = CAMERA_FOCUS + offset
	_camera.look_at(CAMERA_FOCUS)
