extends Control

## Debug Tools -> Lighting.  This is deliberately an inspection surface, not
## a lighting control panel: issue #34 needs the real LIGH.DATA values next
## to the resulting Light3D before replacing any of the old global defaults.
const REFRESH_INTERVAL_SEC := 0.25

@onready var _summary_label: Label = $Margin/VBox/Summary
@onready var _show_lights_check: CheckBox = $Margin/VBox/Controls/ShowLights
@onready var _solo_light_check: CheckBox = $Margin/VBox/Controls/SoloLight
@onready var _ligh_linear_color_check: CheckBox = $Margin/VBox/ColorControls/LighLinearColor
@onready var _xemi_emission_spin: SpinBox = $Margin/VBox/ColorControls/XemiEmission
@onready var _auto_exposure_check: CheckBox = $Margin/VBox/Controls/AutoExposure
@onready var _auto_exposure_scale_spin: SpinBox = $Margin/VBox/Controls/AutoExposureScale
@onready var _min_sensitivity_spin: SpinBox = $Margin/VBox/Controls/MinSensitivity
@onready var _max_sensitivity_spin: SpinBox = $Margin/VBox/Controls/MaxSensitivity
@onready var _light_list: ItemList = $Margin/VBox/HSplit/LightList
@onready var _details_label: TextEdit = $Margin/VBox/HSplit/Details

var _game: Node3D
var _refresh_timer := 0.0
var _cell_form_id := 0
var _entries: Array[Dictionary] = []

func _ready() -> void:
	_game = get_tree().root.get_node_or_null("Game") as Node3D
	_light_list.item_selected.connect(_on_light_selected)
	_show_lights_check.toggled.connect(_on_show_lights_toggled)
	_solo_light_check.toggled.connect(_on_solo_light_toggled)
	_ligh_linear_color_check.toggled.connect(_on_ligh_linear_color_toggled)
	# These controls mutated legacy GamebryoObjectRegistry material/light
	# construction. CellStreamerV2 builds typed EsmLightNodes through NifServer,
	# so make their absence explicit rather than silently changing no runtime.
	_ligh_linear_color_check.disabled = true
	_xemi_emission_spin.editable = false
	_xemi_emission_spin.value_changed.connect(_on_xemi_emission_changed)
	_auto_exposure_check.toggled.connect(_on_auto_exposure_toggled)
	if _game != null and _game.world_environment != null:
		var camera_attributes: CameraAttributesPractical = _game.world_environment.camera_attributes as CameraAttributesPractical
		if camera_attributes != null:
			_auto_exposure_check.button_pressed = camera_attributes.auto_exposure_enabled
			_auto_exposure_scale_spin.value = camera_attributes.auto_exposure_scale
			_min_sensitivity_spin.value = camera_attributes.auto_exposure_min_sensitivity
			_max_sensitivity_spin.value = camera_attributes.auto_exposure_max_sensitivity
	_auto_exposure_scale_spin.value_changed.connect(_on_auto_exposure_scale_changed)
	_min_sensitivity_spin.value_changed.connect(_on_min_sensitivity_changed)
	_max_sensitivity_spin.value_changed.connect(_on_max_sensitivity_changed)
	_refresh()

func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_refresh_timer -= delta
	if _refresh_timer <= 0.0:
		_refresh_timer = REFRESH_INTERVAL_SEC
		_refresh()

func _refresh() -> void:
	if _game == null or _game.cell_streamer == null or EsmServer.reader == null:
		_summary_label.text = "(Game/CellStreamerV2/EsmServer not found)"
		return
	var cell_form_id: int = _game._hud_cell_form_id
	if cell_form_id == 0:
		_summary_label.text = "(no cell loaded yet)"
		return
	if cell_form_id != _cell_form_id:
		_cell_form_id = cell_form_id
		_rebuild_entries()
	_refresh_runtime_values()

func _rebuild_entries() -> void:
	_entries.clear()
	_light_list.clear()
	_details_label.text = "Select a LIGH source for authored and applied values."
	var esm: EsmReader = EsmServer.reader
	for reference: EsmReference in _game.cell_streamer.get_current_refs():
		if reference == null or not reference is LightReference:
			continue
		var data: Dictionary = esm.get_light_data(reference.base_form_id)
		if data.is_empty():
			continue
		_entries.append({ "reference": reference, "data": data, "light": null })
	_entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return _reference_name(a["reference"]) < _reference_name(b["reference"]))
	for entry in _entries:
		var reference: EsmReference = entry["reference"]
		var data: Dictionary = entry["data"]
		var type_label := "spot" if bool(data.get("is_spot", false)) else "omni"
		_light_list.add_item("%s  [%s]" % [_reference_name(reference), type_label])
	_summary_label.text = "%d typed LIGH sources in current CellStreamerV2 cell" % _entries.size()
	_apply_light_visibility()

func _refresh_runtime_values() -> void:
	var root: Node = _game.cell_streamer._current
	var live_count := 0
	for entry in _entries:
		var reference: EsmReference = entry["reference"]
		var node := _find_light_node(root, reference.instance_id)
		var light: Light3D = _direct_light_child(node)
		entry["light"] = light
		if light != null:
			live_count += 1
	_summary_label.text = "%d typed LIGH sources; %d live Light3D nodes\nLegacy XEMI and registry colour toggles: unavailable on CellStreamerV2" % [
		_entries.size(), live_count]
	_apply_light_visibility()

func _on_light_selected(index: int) -> void:
	# Keep the selection's text stable for copying.  Runtime discovery still
	# refreshes in the background, but details change only on an explicit row
	# selection rather than every diagnostic refresh interval.
	_show_entry(index)
	_apply_light_visibility()

func _on_show_lights_toggled(_enabled: bool) -> void:
	_apply_light_visibility()

func _on_solo_light_toggled(_enabled: bool) -> void:
	_apply_light_visibility()

func _on_ligh_linear_color_toggled(_enabled: bool) -> void:
	push_warning("LIGH colour encoding is controlled by EsmLightNode; legacy registry toggle is unavailable")

func _on_xemi_emission_changed(_value: float) -> void:
	push_warning("XEMI emission override is unavailable on CellStreamerV2")

func _apply_xemi_emission_energy(node: Node, value: float) -> void:
	_apply_xemi_emission_energy_recursive(node, value)
	_refresh_runtime_values()

func _apply_xemi_emission_energy_recursive(node: Node, value: float) -> void:
	if node == null:
		return
	if node is MeshInstance3D and bool(node.get_meta("gamebryo_xemi_emission", false)):
		var shader_material := node.material_override as ShaderMaterial
		if shader_material != null:
			shader_material.set_shader_parameter("emission_energy", value)
	for child in node.get_children():
		_apply_xemi_emission_energy_recursive(child, value)

func _xemi_emission_readback(node: Node) -> Dictionary:
	var result := { "count": 0, "peak": 0.0 }
	if node == null:
		return result
	if node is MeshInstance3D and bool(node.get_meta("gamebryo_xemi_emission", false)):
		var shader_material := node.material_override as ShaderMaterial
		if shader_material != null:
			result["count"] = int(result["count"]) + 1
			var tint: Color = shader_material.get_shader_parameter("emittance_tint")
			var energy := float(shader_material.get_shader_parameter("emission_energy"))
			result["peak"] = maxf(float(result["peak"]), maxf(tint.r, maxf(tint.g, tint.b)) * energy)
	for child in node.get_children():
		var child_result := _xemi_emission_readback(child)
		result["count"] = int(result["count"]) + int(child_result["count"])
		result["peak"] = maxf(float(result["peak"]), float(child_result["peak"]))
	return result

func _apply_light_visibility() -> void:
	var selected := _light_list.get_selected_items()
	var solo_index := int(selected[0]) if _solo_light_check.button_pressed and not selected.is_empty() else -1
	for index in _entries.size():
		var entry: Dictionary = _entries[index]
		var light: Light3D = entry.get("light")
		if light != null:
			var data: Dictionary = entry["data"]
			light.visible = _show_lights_check.button_pressed and (solo_index < 0 or index == solo_index) and not bool(data.get("off_by_default", false))

func _on_auto_exposure_toggled(enabled: bool) -> void:
	var camera_attributes := _camera_attributes()
	if camera_attributes != null:
		camera_attributes.auto_exposure_enabled = enabled

func _on_max_sensitivity_changed(value: float) -> void:
	var camera_attributes := _camera_attributes()
	if camera_attributes != null:
		camera_attributes.auto_exposure_max_sensitivity = value

func _on_min_sensitivity_changed(value: float) -> void:
	var camera_attributes := _camera_attributes()
	if camera_attributes != null:
		camera_attributes.auto_exposure_min_sensitivity = value

func _on_auto_exposure_scale_changed(value: float) -> void:
	var camera_attributes := _camera_attributes()
	if camera_attributes != null:
		camera_attributes.auto_exposure_scale = value

func _camera_attributes() -> CameraAttributesPractical:
	if _game == null or _game._world_environment == null:
		return null
	return _game._world_environment.camera_attributes as CameraAttributesPractical

func _show_entry(index: int) -> void:
	if index < 0 or index >= _entries.size():
		return
	var entry: Dictionary = _entries[index]
	var reference: EsmReference = entry["reference"]
	var data: Dictionary = entry["data"]
	var authored_color: Color = data.get("color", Color.BLACK)
	var lines := PackedStringArray([
		"%s" % _reference_name(reference),
		"REFR %s   base 0x%X" % [reference.instance_id, reference.base_form_id],
		"authored: %s   radius %.2fm   falloff %.3f" % [_color_str(authored_color, int(data.get("color_alpha", 0))), data.get("radius", 0.0), data.get("falloff", 0.0)],
		"flags: 0x%X   spot=%s   off by default=%s   FOV %.1f" % [data.get("flags", 0), data.get("is_spot", false), data.get("off_by_default", false), data.get("fov_degrees", 0.0)],
	])
	var light: Light3D = entry.get("light")
	if light == null:
		lines.append("applied: (Light3D not built/live yet)")
	else:
		lines.append("applied: %s   visible=%s   color=%s   energy %.3f   shadows=%s" % [light.get_class(), light.visible, _color_str(light.light_color), light.light_energy, light.shadow_enabled])
		if light is OmniLight3D:
			lines.append("applied omni: range %.2fm   attenuation %.3f" % [light.omni_range, light.omni_attenuation])
		elif light is SpotLight3D:
			lines.append("applied spot: range %.2fm   attenuation %.3f   angle %.1f" % [light.spot_range, light.spot_attenuation, light.spot_angle])
	_details_label.text = "\n".join(lines)

func _find_light_node(node: Node, instance_id: String) -> EsmLightNode:
	if node == null:
		return null
	if node is EsmLightNode and node.reference != null and node.reference.instance_id == instance_id:
		return node
	for child in node.get_children():
		var found := _find_light_node(child, instance_id)
		if found != null:
			return found
	return null

func _direct_light_child(node: EsmLightNode) -> Light3D:
	if node == null:
		return null
	for child in node.get_children():
		if child is Light3D:
			return child
	return null

func _reference_name(reference: EsmReference) -> String:
	if reference != null and reference.base != null and not reference.base.editor_id.is_empty():
		return reference.base.editor_id
	return "LIGH_%s" % (reference.instance_id if reference != null else "unknown")

func _color_str(color: Color, alpha: int = -1) -> String:
	var alpha_suffix := "" if alpha < 0 else " a=%d" % alpha
	return "rgb(%d,%d,%d)%s" % [roundi(color.r * 255.0), roundi(color.g * 255.0), roundi(color.b * 255.0), alpha_suffix]
