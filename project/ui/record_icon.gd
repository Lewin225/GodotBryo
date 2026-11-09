class_name RecordIcon
extends TextureRect

## Shows a record's picture: its inventory icon, else a render of its model
## (ThumbnailServer.request()). For any UI that names a record: an overlay on
## what the player looks at, a console suggestion, a list row.
##
## Set `form_id`; the picture shows when it is ready (at once when it already
## is), with `placeholder` until then and when the record has none. Setting
## another form id before the first arrives drops the first.

## Emitted when the picture for the current form id is showing, or the record
## turned out to have none (null).
signal picture_shown(texture: Texture2D)

## The record to show; 0 for none.
@export var form_id := 0:
	set(value):
		form_id = value
		_show()
## Shown while the picture loads, and when the record has none; null for
## nothing.
@export var placeholder: Texture2D:
	set(value):
		placeholder = value
		if not _has_picture:
			texture = placeholder

var _has_picture := false

func _init() -> void:
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED

## Whether the record's own picture is showing (not the placeholder).
func has_picture() -> bool:
	return _has_picture

func _show() -> void:
	var wanted := form_id
	_has_picture = false
	if wanted == 0:
		texture = placeholder
		return
	var ready := ThumbnailServer.cached(wanted)
	if ready != null:
		_set_picture(ready)
		return
	texture = placeholder
	var loaded := await ThumbnailServer.request(wanted)
	if wanted == form_id:
		_set_picture(loaded)

func _set_picture(picture: Texture2D) -> void:
	_has_picture = picture != null
	texture = picture if picture != null else placeholder
	picture_shown.emit(picture)
