@tool
extends VBoxContainer

const GameDataConfigScript := preload("res://game_data_config.gd")
const MountDir := "res://esm_mount"
const SupportedTypes := ["NPC_", "RACE", "HAIR", "EYES", "ARMO", "ARMA", "FLST", "WEAP"]
signal loader_ready(reader: EsmReader)

var reader: EsmReader
var factory: EsmResourceFactory
var records: Array = []
var visible_indices: PackedInt32Array = []
var type_option: OptionButton
var filter_edit: LineEdit
var list: ItemList
var status: Label

func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	_build_ui()
	_open_esm()

func _build_ui() -> void:
	var title := Label.new()
	title.text = "ESM Resources"
	add_child(title)
	var controls := HBoxContainer.new()
	add_child(controls)
	type_option = OptionButton.new()
	type_option.add_item("All")
	for type_tag in SupportedTypes:
		type_option.add_item(type_tag)
	type_option.item_selected.connect(func(_index: int) -> void: _refresh())
	controls.add_child(type_option)
	filter_edit = LineEdit.new()
	filter_edit.placeholder_text = "Filter EditorID, name, or FormID..."
	filter_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	filter_edit.text_changed.connect(func(_text: String) -> void: _refresh())
	controls.add_child(filter_edit)
	var materialize := Button.new()
	materialize.text = "Mount ESM"
	materialize.tooltip_text = "Generate ignored .nvrecord paths for supported typed records"
	materialize.pressed.connect(_mount_esm)
	controls.add_child(materialize)
	list = ItemList.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(list)
	status = Label.new()
	add_child(status)

func _open_esm() -> void:
	reader = EsmReader.new()
	var config := GameDataConfigScript.resolve()
	var path := String(config.get("data_dir", "")) + GameDataConfigScript.ESM_FILE
	if not reader.open(path):
		status.text = "ESM unavailable: %s" % reader.get_last_error()
		return
	if not reader.has_method("get_record_index"):
		status.text = "ESM index API unavailable; rebuild nv_engine"
		return
	factory = EsmResourceFactory.new(reader)
	loader_ready.emit(reader)
	status.text = "ESM ready — click Mount ESM to create FileSystem paths"

func _refresh() -> void:
	if list == null:
		return
	list.clear()
	visible_indices.clear()
	var type_filter := "All" if type_option.selected == 0 else type_option.get_item_text(type_option.selected)
	var needle := filter_edit.text.to_lower().strip_edges()
	for i in records.size():
		var record: Dictionary = records[i]
		if type_filter != "All" and String(record.get("record_type", "")) != type_filter:
			continue
		var form_text := "0x%08X" % int(record.get("form_id", 0))
		var label := "%s  %s  %s" % [String(record.get("record_type", "")), String(record.get("editor_id", "")), form_text]
		if not String(record.get("full_name", "")).is_empty():
			label += " — " + String(record.get("full_name", ""))
		if needle != "" and label.to_lower().find(needle) == -1:
			continue
		list.add_item(label)
		visible_indices.append(i)
	status.text = "%d shown / %d indexed" % [visible_indices.size(), records.size()]

func _mount_esm() -> void:
	if reader == null or not reader.has_method("get_record_index"):
		status.text = "ESM index API unavailable; rebuild nv_engine"
		return
	records = reader.get_record_index()
	var mount_dir := ProjectSettings.globalize_path(MountDir)
	for type_tag in SupportedTypes:
		DirAccess.make_dir_recursive_absolute(mount_dir.path_join(type_tag))
	var created := 0
	for row in records:
		var type_tag := String(row.get("record_type", ""))
		if not SupportedTypes.has(type_tag):
			continue
		var editor_id := String(row.get("editor_id", ""))
		if editor_id.is_empty():
			editor_id = type_tag
		var full_name := String(row.get("full_name", ""))
		var display_name := full_name if not full_name.is_empty() else editor_id
		# FULL is the useful human-facing label in the FileSystem dock;
		# EditorID and FormID retain stable identity and disambiguation.
		var filename_stem := "%s__%s" % [display_name, editor_id]
		var form_id := int(row.get("form_id", 0))
		var path := "%s/%s/%s_%08X.nvrecord" % [MountDir, type_tag, filename_stem.validate_filename(), form_id]
		if not FileAccess.file_exists(path):
			var file := FileAccess.open(path, FileAccess.WRITE)
			if file != null:
				file.store_string("# ESM-backed record; identity is encoded by this path.\n")
				created += 1
	EditorInterface.get_resource_filesystem().scan()
	status.text = "Mounted %d new records; paths are under %s" % [created, MountDir]
