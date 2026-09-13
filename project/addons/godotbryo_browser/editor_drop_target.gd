@tool
extends Control

signal drop_received(position: Vector2, data: Variant)

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	set_process(true)

func _process(_delta: float) -> void:
	# The target lives above the editor's normal surface. Keep it completely
	# transparent to navigation and selection unless a GUI drag is active;
	# otherwise it would receive the event and pass it to its parent instead of
	# the sibling surface underneath.
	var drag_data := get_viewport().gui_get_drag_data()
	var should_accept := drag_data is Dictionary and String(drag_data.get("type", "")) == "resource" \
			and drag_data.get("resource") is EsmBase \
			and not drag_data.get("resource") is LeveledItemBase
	mouse_filter = Control.MOUSE_FILTER_PASS if should_accept else Control.MOUSE_FILTER_IGNORE

func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return data is Dictionary and String(data.get("type", "")) == "resource" \
			and data.get("resource") is EsmBase \
			and not data.get("resource") is LeveledItemBase

func _drop_data(at_position: Vector2, data: Variant) -> void:
	drop_received.emit(at_position, data)
