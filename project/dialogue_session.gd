class_name DialogueSession
extends CanvasLayer

## Placeholder conversation screen: the speaker's name, the response being
## said, and the player's choices once the speaker finishes a line. It shows
## DialogueServer's conversation and sends the player's choice back; Escape
## ends the conversation. It changes no game state itself.

@onready var _speaker: Label = $Root/Panel/Margin/VBox/Speaker
@onready var _response: Label = $Root/Panel/Margin/VBox/Response
@onready var _choices: VBoxContainer = $Root/Panel/Margin/VBox/Choices

var _speaker_reference: EsmReference = null
var _previous_mouse_mode: Input.MouseMode = Input.MOUSE_MODE_CAPTURED

func _ready() -> void:
	visible = false
	DialogueServer.response_started.connect(_on_response_started)
	DialogueServer.choices_ready.connect(_on_choices_ready)

## Shows the conversation with `speaker`.
func open(speaker: EsmReference) -> void:
	_speaker_reference = speaker
	_speaker.text = speaker.base.full_name if speaker != null and speaker.base != null else ""
	_response.text = ""
	_clear_choices()
	_previous_mouse_mode = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	visible = true

func close() -> void:
	if not visible:
		return
	visible = false
	_speaker_reference = null
	_clear_choices()
	Input.mouse_mode = _previous_mouse_mode

func _on_response_started(line: DialogueLine, text: String) -> void:
	if visible and line.speaker == _speaker_reference:
		_response.text = text
		_clear_choices()

func _on_choices_ready(choices: Array[DialogueChoice]) -> void:
	if not visible:
		return
	_clear_choices()
	for i in choices.size():
		var button := Button.new()
		button.text = "%d.  %s" % [i + 1, choices[i].text]
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.pressed.connect(DialogueServer.choose.bind(i))
		_choices.add_child(button)
	if _choices.get_child_count() > 0:
		(_choices.get_child(0) as Button).grab_focus()

func _clear_choices() -> void:
	for child in _choices.get_children():
		_choices.remove_child(child)
		child.queue_free()

func _unhandled_key_input(event: InputEvent) -> void:
	if not visible or not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.keycode == KEY_ESCAPE:
		DialogueServer.end_conversation()
		get_viewport().set_input_as_handled()
	elif event.keycode >= KEY_1 and event.keycode <= KEY_9 and event.keycode - KEY_1 < _choices.get_child_count():
		DialogueServer.choose(event.keycode - KEY_1)
		get_viewport().set_input_as_handled()
