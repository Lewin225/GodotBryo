class_name TerminalSession
extends CanvasLayer

## Player-facing TERM session: shows a TerminalReference's base-record menu
## and owns navigation, the UI and the mouse while open. It does not touch the
## player; whoever opens it reacts to `closed`.

## The session was closed (Exit, Escape, or close_session()).
signal closed
## A menu item was chosen: its terminal data, including "script_source" (the
## item's result script, empty when it has none).
signal item_chosen(item: Dictionary)

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
## The TerminalBase of each _terminal_stack entry, for its items' conditions.
var _base_stack: Array[TerminalBase] = []
## Item conditions run on the user, and follow the placed terminal's linked
## reference.
var _condition_context: ConditionContext = null
var _view: View = View.WELCOME
var _pending_note_form_id: int = 0
var _pending_submenu_form_id: int = 0

func _ready() -> void:
	visible = false
	_choices.item_activated.connect(func(_index: int) -> void: _select_current())
	_select.pressed.connect(_select_current)
	_back.pressed.connect(_go_back)
	_exit.pressed.connect(close_session)

## Opens `terminal`'s menu for `user`, the actor using it. Items whose
## conditions fail are hidden. Returns false when its base has no terminal
## data.
func open_session(terminal: TerminalReference, esm: EsmReader, user: EsmReference = null) -> bool:
	var terminal_data: Dictionary = {}
	if terminal != null and terminal.base != null:
		terminal_data = esm.get_terminal_data(terminal.base.form_id)
	if terminal_data.is_empty():
		push_warning("TerminalSession: activated TERM has no parsed terminal data")
		return false
	_esm = esm
	_terminal_stack = [terminal_data]
	_base_stack = [terminal.base as TerminalBase]
	_condition_context = ConditionContext.new(user)
	_condition_context.linked_from = terminal
	_condition_context.owner_label = "TERM %s" % terminal.base.editor_id
	if not visible:
		ScriptServer.enter_menu(ScriptServer.MENU_COMPUTERS)
	visible = true
	var welcome: String = String(terminal_data.get("welcome_text", ""))
	if welcome.is_empty():
		_show_menu()
	else:
		_show_welcome(welcome)
	return true

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
	var base: TerminalBase = _base_stack.back() if not _base_stack.is_empty() else null
	for i in items.size():
		var item: Dictionary = items[i]
		# TerminalBase.menu_items is built from the same items, in order.
		if base != null and i < base.menu_items.size() and not _item_available(base.menu_items[i]):
			continue
		var index: int = _choices.add_item(String(item.get("text", "")))
		_choices.set_item_metadata(index, item)
	_choices.visible = true
	_select.visible = true
	_select.text = "Open"
	_back.visible = _terminal_stack.size() > 1
	_status.text = ""
	if _choices.item_count > 0:
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
			item_chosen.emit(item)
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
	_base_stack.append(EsmServer.get_base(form_id) as TerminalBase)
	if not String(submenu.get("welcome_text", "")).is_empty():
		_show_welcome(String(submenu.get("welcome_text", "")))
	else:
		_show_menu()

func _go_back() -> void:
	match _view:
		View.MENU:
			if _terminal_stack.size() > 1:
				_terminal_stack.pop_back()
				_base_stack.pop_back()
				_show_menu()
		View.RESULT, View.NOTE:
			_show_menu()
		_:
			_show_menu()

func _current_terminal() -> Dictionary:
	return _terminal_stack.back() if not _terminal_stack.is_empty() else {}

## Whether a menu item's conditions pass for the session's user.
func _item_available(item: TerminalMenuItemCollection) -> bool:
	return item.conditions.is_empty() or ScriptServer.evaluate_conditions(item.conditions, _condition_context)

func _terminal_title() -> String:
	var terminal: Dictionary = _current_terminal()
	var title: String = String(terminal.get("full_name", ""))
	return title if not title.is_empty() else String(terminal.get("editor_id", "Terminal"))

func close_session() -> void:
	if not visible:
		return
	visible = false
	_terminal_stack.clear()
	_base_stack.clear()
	ScriptServer.exit_menu(ScriptServer.MENU_COMPUTERS)
	closed.emit()

func _unhandled_key_input(event: InputEvent) -> void:
	if not visible or not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.keycode == KEY_ESCAPE:
		close_session()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
		_select_current()
		get_viewport().set_input_as_handled()
