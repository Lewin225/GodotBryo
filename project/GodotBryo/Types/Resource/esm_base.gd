@tool
class_name EsmBase
extends Resource

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var form_id: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var editor_id: String = ""
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var record_type: String = ""
@export var source_uri: String = "":
	set(value):
		source_uri = value
		if not _rehydrating and not source_uri.is_empty():
			call_deferred("_auto_rehydrate")
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var full_name: String = ""
var raw_subrecords: Array[Dictionary] = []
var diagnostics: PackedStringArray = []
var _rehydrating := false

func _notification(what: int) -> void:
	if what == NOTIFICATION_POSTINITIALIZE:
		# Resource deserialization can assign stored properties without invoking
		# their GDScript setters. The deferred post-init pass covers that path.
		call_deferred("_auto_rehydrate")

func _auto_rehydrate() -> void:
	if _rehydrating or source_uri.is_empty():
		return
	var tree := Engine.get_main_loop()
	var root = tree.root if tree != null else null
	var server = root.get_node_or_null("EsmServer") if root != null else null
	if server != null and server.has_method("rehydrate"):
		server.rehydrate(self)

func subrecord_data(tag: String) -> PackedByteArray:
	for subrecord in raw_subrecords:
		if String(subrecord.get("type", "")) == tag:
			return subrecord.get("data", PackedByteArray())
	return PackedByteArray()

func all_subrecord_data(tag: String) -> Array[PackedByteArray]:
	var result: Array[PackedByteArray] = []
	for subrecord in raw_subrecords:
		if String(subrecord.get("type", "")) == tag:
			result.append(subrecord.get("data", PackedByteArray()))
	return result

## Built-in activation of references of this type: what happens when
## `activator` activates `ref` and no script block replaces it. Stateless and
## shared by every placement, so the reference is passed in. Types with
## built-in activation override this and call ScriptServer primitives
## (move_reference, begin_use, lock, unlock) to do the work.
func activate(_ref: EsmReference, _activator: EsmReference) -> void:
	pass
