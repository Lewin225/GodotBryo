class_name TerminalSession
extends CanvasLayer

## Player-facing TERM session owned by Game. EsmTerminalNode supplies
## immutable base-record data; this node alone owns
## navigation, UI and the temporary player-input suspension.

enum View { WELCOME, MENU, RESULT, NOTE }

@onready var _title: Label = $Root/Panel/Margin/VBox/Title
@onready var _body: RichTextLabel = $Root/Panel/Margin/VBox/Body
@onready var _choices: ItemList = $Root/Panel/Margin/VBox/Choices
@onready var _select: Button = $Root/Panel/Margin/VBox/Buttons/Select
@onready var _back: Button = $Root/Panel/Margin/VBox/Buttons/Back
@onready var _exit: Button = $Root/Panel/Margin/VBox/Buttons/Exit
@onready var _status: Label = $Root/Panel/Margin/VBox/Status

var _esm: EsmReader
var _terminal_stack: Array[Dictionary] = []
var _view: View = View.WELCOME
var _pending_note_form_id: int = 0
var _pending_submenu_form_id: int = 0
var _player: Node = null
var _previous_mouse_mode: Input.MouseMode = Input.MOUSE_MODE_CAPTURED

func _ready() -> void:
	visible = false
	_choices.item_activated.connect(func(_index: int) -> void: _select_current())
	_select.pressed.connect(_select_current)
	_back.pressed.connect(_go_back)
	_exit.pressed.connect(close_session)

func open_session(terminal: Node, esm: EsmReader, player: Node) -> void:
	var terminal_data: Dictionary = {}
	if terminal is EsmTerminalNode:
		var reference := (terminal as EsmTerminalNode).reference
		if reference != null and reference.base != null:
			terminal_data = esm.get_terminal_data(reference.base.form_id)
	if terminal_data.is_empty():
		push_warning("TerminalSession: activated TERM has no parsed terminal data")
		return
	_esm = esm
	_terminal_stack = [terminal_data]
	_player = player
	_suspend_player_input()
	visible = true
	var welcome: String = String(terminal_data.get("welcome_text", ""))
	if welcome.is_empty():
		_show_menu()
	else:
		_show_welcome(welcome)

func _show_welcome(text: String) -> void:
	_view = View.WELCOME
	_title.text = _terminal_title()
	_body.text = text
	_choices.visible = false
	_select.visible = true
	_select.text = "Continue"
	_back.visible = false
	_status.text = ""

func _show_menu() -> void:
	_view = View.MENU
	_title.text = _terminal_title()
	_body.text = "Select an entry."
	_choices.clear()
	var items: Array = _current_terminal().get("items", [])
	for item_variant in items:
		var item: Dictionary = item_variant
		var unavailable: bool = int(item.get("condition_count", 0)) > 0 or not String(item.get("script_source", "")).is_empty()
		var label: String = String(item.get("text", ""))
		if unavailable:
			label += "  [unavailable]"
		var index: int = _choices.add_item(label)
		_choices.set_item_metadata(index, item)
		_choices.set_item_disabled(index, unavailable)
	_choices.visible = true
	_select.visible = true
	_select.text = "Open"
	_back.visible = _terminal_stack.size() > 1
	_status.text = "Choices with conditions or inline menu scripts are visible but unavailable in this browsing-only pass."
	if not items.is_empty():
		_choices.select(0)

func _show_result(item: Dictionary) -> void:
	_view = View.RESULT
	_title.text = String(item.get("text", ""))
	_body.text = String(item.get("result_text", ""))
	_pending_note_form_id = int(item.get("note_form_id", 0))
	_pending_submenu_form_id = int(item.get("submenu_form_id", 0))
	_choices.visible = false
	_select.visible = _pending_note_form_id != 0 or _pending_submenu_form_id != 0
	_select.text = "Read linked note" if _pending_note_form_id != 0 else "Open submenu"
	_back.visible = true
	_status.text = ""

func _show_note(note_form_id: int) -> void:
	var note: Dictionary = _esm.get_note_data(note_form_id)
	_view = View.NOTE
	_title.text = String(note.get("full_name", ""))
	if _title.text.is_empty():
		_title.text = String(note.get("editor_id", "Note"))
	_body.text = String(note.get("text", ""))
	_choices.visible = false
	_select.visible = false
	_back.visible = true
	_status.text = ""
	if note.is_empty() or String(note.get("text", "")).is_empty():
		_body.text = "This linked Note could not be read."
		_status.text = "NOTE FormID 0x%X did not resolve to displayable text." % note_form_id

func _select_current() -> void:
	match _view:
		View.WELCOME:
			_show_menu()
		View.MENU:
			var selected: PackedInt32Array = _choices.get_selected_items()
			if selected.is_empty():
				return
			var item: Dictionary = _choices.get_item_metadata(selected[0])
			_show_result(item)
		View.RESULT:
			if _pending_note_form_id != 0:
				_show_note(_pending_note_form_id)
			elif _pending_submenu_form_id != 0:
				_open_submenu(_pending_submenu_form_id)

func _open_submenu(form_id: int) -> void:
	var submenu: Dictionary = _esm.get_terminal_data(form_id)
	if submenu.is_empty():
		_status.text = "Submenu TERM 0x%X could not be read." % form_id
		return
	_terminal_stack.append(submenu)
	_show_welcome(String(submenu.get("welcome_text", ""))) if not String(submenu.get("welcome_text", "")).is_empty() else _show_menu()

func _go_back() -> void:
	match _view:
		View.MENU:
			if _terminal_stack.size() > 1:
				_terminal_stack.pop_back()
				_show_menu()
		View.RESULT, View.NOTE:
			_show_menu()
		_:
			_show_menu()

func _current_terminal() -> Dictionary:
	return _terminal_stack.back() if not _terminal_stack.is_empty() else {}

func _terminal_title() -> String:
	var terminal: Dictionary = _current_terminal()
	var title: String = String(terminal.get("full_name", ""))
	return title if not title.is_empty() else String(terminal.get("editor_id", "Terminal"))

func _suspend_player_input() -> void:
	if _player == null:
		return
	_player.set_physics_process(false)
	_player.set_process_input(false)
	_player.set_process_unhandled_input(false)
	_player.set_process_unhandled_key_input(false)
	_previous_mouse_mode = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func close_session() -> void:
	if not visible:
		return
	visible = false
	if _player != null:
		_player.set_physics_process(true)
		_player.set_process_input(true)
		_player.set_process_unhandled_input(true)
		_player.set_process_unhandled_key_input(true)
	Input.mouse_mode = _previous_mouse_mode
	_player = null
	_terminal_stack.clear()

func _unhandled_key_input(event: InputEvent) -> void:
	if not visible or not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.keycode == KEY_ESCAPE:
		close_session()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
		_select_current()
		get_viewport().set_input_as_handled()
