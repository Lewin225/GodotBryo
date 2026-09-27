@tool
class_name EsmBase
extends Resource

## Record header FormID. Read; the record's identity everywhere.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var form_id: int = 0
## EDID. Read; used to find records by editor ID and for display.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var editor_id: String = ""
## Record header flag 0x400 on item records (xEdit: Quest Item). In
## FalloutNV.esm 252 item bases carry it (MISC 179, KEYM 52, ARMO 9, WEAP 8,
## ALCH 3, BOOK 1), among them the three Van Graff items scripts clear with
## `SetQuestObject ... 0`. On other record types the bit means something else.
const RECORD_FLAG_QUEST_ITEM := 0x400

## Record header flags. Read; used by QuestServer for an item's authored
## quest-item state (RECORD_FLAG_QUEST_ITEM).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var record_flags: int = 0
## Record header type tag (NPC_, DOOR, ...). Read; used by EsmServer to pick
## the Base and Reference classes and by type checks such as QUST.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var record_type: String = ""
## Not an ESM field: `esm://FalloutNV.esm/<type>/<FormID>`, the persisted link
## to the record. Set by EsmServer; used to rehydrate the record's fields when
## a saved resource or packed scene is loaded.
@export var source_uri: String = "":
	set(value):
		source_uri = value
		if not _rehydrating and not source_uri.is_empty():
			call_deferred("_auto_rehydrate")
## FULL: the display name. Read; used by EsmNode, the physicaliser and the
## GodotBryo browser for names and labels.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var full_name: String = ""
## SCRI: FormID of this record's SCPT script, or 0. Any record type may carry
## one; for placeable types it is the object script of every placement. Read;
## used by ScriptServer to run object and quest scripts.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var script_form_id: int = 0
## Every subrecord of the record, as {"type", "data"}. Read; used through
## subrecord_data() / all_subrecord_data() for fields not decoded into typed
## properties (CNTO inventory seeds, for one).
var raw_subrecords: Array[Dictionary] = []
## Not an ESM field: problems EsmServer met decoding the record (truncated or
## unexpected subrecord sizes in LVLI, PACK, BPTD). Set; not read by anything.
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

## Whether `actor` has an item with this base FormID in its inventory.
static func carries(actor: EsmReference, item_form_id: int) -> bool:
	if actor == null or item_form_id == 0 or not "contents" in actor:
		return false
	var inventory: Inventory = actor.get("contents")
	return inventory != null and inventory.has_item(item_form_id)
