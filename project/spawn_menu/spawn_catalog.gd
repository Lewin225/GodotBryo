class_name SpawnCatalog
extends RefCounted

## The spawn menu's data (Plans/SpawnMenu/spawn_menu.md): for each spawnable
## record type, one row per record, the tree that groups them, the top-tab
## categories, and the search filter. Plain data and no nodes, so a headless
## test runs it.
##
## Rows come from EsmServer's record index (names) plus the record's raw
## subrecords (model and icon paths, NPC_ race and faction). A type's rows are
## built the first time they are asked for, either now (rows_for_type()) or on
## a worker thread (request_type(), then poll() each frame until type_ready).
## Measured on FalloutNV.esm (2026-11-09), first builds on the main thread take
## NPC_ ~215 ms, STAT ~180 ms, LVLI ~110 ms, every other type under 75 ms, so
## the tab builds on the worker. The worker has its own EsmReader (EsmReader is
## not thread-safe) and runs one type at a time; the main thread takes each
## result in poll().
##
## A row is a Dictionary:
## - `form_id`, `record_type`, `editor_id`, `full_name`: from the index;
## - `display_name`: display_name() of those;
## - `model`: the world model under meshes/ (MODL; ARMO's MOD2), lower case
##   with forward slashes, "" when none;
## - `icon`: the inventory icon under textures/ (ICON), as `model`;
## - `model_missing`: a model is named but no archive has it;
## - `shown_icon`, `shown_model`, `shown_leveled`, `parts`: the record's
##   picture (RecordVisuals.visual(): `icon`, `model`, `leveled`, `parts`),
##   what the grid's thumbnail and hover preview show. `shown_icon` is under
##   textures/; `shown_model` is a model key (ThumbnailServer.request_model()),
##   "" for none. They can differ from `icon` and `model`, which are the
##   record's own: another of its model subrecords, a creature's body parts, a
##   leveled list's entry;
## - `group`: the tree path, `/`-separated (see group rules on build_tree());
## - `search`: search_text(), what matches() looks in.

const ACTION_INVENTORY := &"inventory"
const ACTION_PLACE := &"place"
## Resolve a leveled list first, then add (LVLI) or place (LVLN, LVLC).
const ACTION_RESOLVE := &"resolve"
## The Spawnlists category: no types of its own, but lists of records of any
## type (SpawnLists), whose rows come from row_for().
const ACTION_LISTS := &"lists"
## The category index of Spawnlists.
const LISTS_CATEGORY := 0

## The top tabs: each groups record types, which are the first tree level.
## Favourites is not a row here; the tab shows starred records of any type.
const CATEGORIES := [
	{"name": "Spawnlists", "types": [], "action": ACTION_LISTS},
	{"name": "Items", "types": ["WEAP", "ARMO", "AMMO", "ALCH", "MISC", "KEYM", "BOOK", "NOTE", "CCRD", "CMNY", "CHIP", "IMOD"], "action": ACTION_INVENTORY},
	{"name": "Actors", "types": ["NPC_", "CREA"], "action": ACTION_PLACE},
	{"name": "Objects", "types": ["STAT", "MSTT", "SCOL"], "action": ACTION_PLACE},
	{"name": "Interactive", "types": ["ACTI", "TACT", "CONT", "DOOR", "FURN", "TERM", "LIGH"], "action": ACTION_PLACE},
	{"name": "Leveled", "types": ["LVLI", "LVLN", "LVLC"], "action": ACTION_RESOLVE},
]

## Each type's name, as the GECK's object window names it.
const TYPE_NAMES := {
	"WEAP": "Weapon", "ARMO": "Armor", "AMMO": "Ammunition", "ALCH": "Ingestible", "MISC": "Misc Item",
	"KEYM": "Key", "BOOK": "Book", "NOTE": "Note", "CCRD": "Caravan Card", "CMNY": "Caravan Money",
	"CHIP": "Casino Chip", "IMOD": "Item Mod", "NPC_": "NPC", "CREA": "Creature", "STAT": "Static",
	"MSTT": "Moveable Static", "SCOL": "Static Collection", "ACTI": "Activator", "TACT": "Talking Activator",
	"CONT": "Container", "DOOR": "Door", "FURN": "Furniture", "TERM": "Terminal", "LIGH": "Light",
	"LVLI": "Leveled Item", "LVLN": "Leveled NPC", "LVLC": "Leveled Creature",
}

## `record_type`'s name with its tag: `Static [STAT]`.
static func type_label(record_type: String) -> String:
	return "%s [%s]" % [TYPE_NAMES.get(record_type, record_type), record_type]

## Types whose items can go into an inventory (the Items tab, and LVLI's
## results).
const INVENTORY_TYPES := ["WEAP", "ARMO", "AMMO", "ALCH", "MISC", "KEYM", "BOOK", "NOTE", "CCRD", "CMNY", "CHIP", "IMOD"]
const LEVELED_TYPES := ["LVLI", "LVLN", "LVLC"]

## Between rows' texts in a search blob; no search text holds it.
const ROW_SEPARATOR := "\u0001"

## The tree node of records that name no model.
const NO_MODEL_GROUP := "(no model)"
## The tree node of models directly under meshes/.
const ROOT_GROUP := "(root)"
## The tree node of NPC_ records with no faction, under their race.
const NO_FACTION_GROUP := "(no faction)"

## Emitted from poll() when a requested type's rows are ready.
signal type_ready(record_type: String)

var _reader
var _archives: Node
var _record_index: Array
var _index_by_type := {}
var _rows_by_type := {}
## Per type, every row's search_text() joined by ROW_SEPARATOR, and where each
## row's text starts in it: search() finds matches with native String.find().
var _search_blob_by_type := {}
var _search_starts_by_type := {}
var _trees_by_type := {}
var _name_cache := {}
## Rows built one at a time by row_for(), by form id, for types not built.
var _single_rows := {}
## Form id -> [record type, index row], and lower-case EditorID -> form id,
## over every type the menu shows; built by the first row_for() or
## form_id_for_editor_id().
var _index_by_form := {}
var _form_by_editor_id := {}
## Milliseconds each type's first build took, by type.
var build_ms := {}

# Worker builds: the types still to build, in order; the running task and the
# type it builds; what it built (written by the worker, read by poll() once
# the task is done); the worker's own EsmReader and name cache.
var _queue := PackedStringArray()
var _task_id := -1
var _task_type := ""
var _task_result := {}
var _worker_reader
var _worker_name_cache := {}

## `reader` is an EsmReader (EsmServer.reader on the main thread);
## `record_index` is EsmServer.get_record_index(); `archives` is ArchiveServer,
## or null to skip the missing-model check.
func _init(reader, record_index: Array, archives: Node = null) -> void:
	_reader = reader
	_archives = archives
	_record_index = record_index

## Splits the record index by type, once. Runs on whichever thread builds
## first; rows_for_type() waits for a running worker task, so it never runs
## on two threads at once.
func _ensure_index_by_type() -> void:
	if not _index_by_type.is_empty():
		return
	var buckets := {}
	for type: String in all_types():
		buckets[type] = []
	for row: Dictionary in _record_index:
		var bucket: Variant = buckets.get(String(row.get("record_type", "")))
		if bucket != null:
			(bucket as Array).append(row)
	_index_by_type = buckets

## Every type the menu shows, in tab order.
static func all_types() -> PackedStringArray:
	var result := PackedStringArray()
	for category: Dictionary in CATEGORIES:
		for type: String in category["types"]:
			result.append(type)
	return result

## The category Dictionary that holds `record_type`, or {}.
static func category_for_type(record_type: String) -> Dictionary:
	for category: Dictionary in CATEGORIES:
		if (category["types"] as Array).has(record_type):
			return category
	return {}

## What a plain click does for a record of this type.
static func default_action(record_type: String) -> StringName:
	return StringName(category_for_type(record_type).get("action", ACTION_PLACE))

## The rows of `record_type`, sorted by display name. Built now on first
## call, after any running worker task finishes.
func rows_for_type(record_type: String) -> Array:
	if not _rows_by_type.has(record_type):
		_finish_task(true)
	if not _rows_by_type.has(record_type):
		var started := Time.get_ticks_usec()
		_ensure_index_by_type()
		var rows := _build_rows(record_type, _reader, _name_cache)
		_store(record_type, rows, _search_blob(rows))
		build_ms[record_type] = (Time.get_ticks_usec() - started) / 1000.0
		_queue.erase(record_type)
	return _rows_by_type[record_type]

func _store(record_type: String, rows: Array, blob: Dictionary) -> void:
	_rows_by_type[record_type] = rows
	_search_blob_by_type[record_type] = blob["text"]
	_search_starts_by_type[record_type] = blob["starts"]

## Rows' search texts joined into one string, and where each starts.
static func _search_blob(rows: Array) -> Dictionary:
	var texts := PackedStringArray()
	var starts := PackedInt32Array()
	var at := 0
	for row: Dictionary in rows:
		var text: String = row["search"]
		starts.append(at)
		texts.append(text)
		at += text.length() + ROW_SEPARATOR.length()
	return {"text": ROW_SEPARATOR.join(texts), "starts": starts}

## The rows of `record_type` that match `needle` (as matches() decides), in
## row order. Uses the type's search blob: each match is one native find(),
## so a narrow search does not visit every row.
func search(record_type: String, needle: String) -> Array:
	var rows := rows_for_type(record_type)
	var lowered := needle.strip_edges().to_lower()
	if lowered.is_empty():
		return rows
	var blob: String = _search_blob_by_type[record_type]
	var starts: PackedInt32Array = _search_starts_by_type[record_type]
	var hits := {}
	_find_rows(blob, starts, lowered, hits)
	# A FormID written as the console writes one (0xE3778) is not in the text;
	# its 8-digit hex is.
	var form_id := ConsoleCompleter.parse_form_id(lowered)
	if form_id >= 0:
		_find_rows(blob, starts, "%08x" % form_id, hits)
	var indices: Array = hits.keys()
	if form_id >= 0:
		indices.sort()
	var result := []
	result.resize(indices.size())
	for i in indices.size():
		result[i] = rows[indices[i]]
	return result

static func _find_rows(blob: String, starts: PackedInt32Array, needle: String, hits: Dictionary) -> void:
	var at := blob.find(needle)
	while at >= 0:
		var row := starts.bsearch(at, false) - 1
		hits[row] = true
		if row + 1 >= starts.size():
			break
		at = blob.find(needle, starts[row + 1])

## Whether `record_type`'s rows are built.
func is_type_ready(record_type: String) -> bool:
	return _rows_by_type.has(record_type)

## Whether a worker build is queued or running.
func is_building() -> bool:
	return _task_id >= 0 or not _queue.is_empty()

## The type the worker is building, or "".
func building_type() -> String:
	return _task_type

## Queues `record_type` for a worker build; type_ready is emitted from poll()
## when it is done. Does nothing for a built or queued type.
func request_type(record_type: String) -> void:
	if _rows_by_type.has(record_type) or _queue.has(record_type) or _task_type == record_type:
		return
	if not all_types().has(record_type):
		return
	_queue.append(record_type)
	_start_next()

## Takes a finished worker build and starts the next one. Call every frame
## while is_building().
func poll() -> void:
	_finish_task(false)
	_start_next()

func _start_next() -> void:
	if _task_id >= 0 or _queue.is_empty():
		return
	_task_type = _queue[0]
	_queue.remove_at(0)
	_task_result = {}
	_task_id = WorkerThreadPool.add_task(_worker_build.bind(_task_type), false, "SpawnCatalog %s" % _task_type)

## On the worker: builds one type with the worker's own EsmReader.
func _worker_build(record_type: String) -> void:
	var started := Time.get_ticks_usec()
	if _worker_reader == null:
		_worker_reader = _open_worker_reader()
	if _worker_reader == null:
		_task_result = {"failed": true}
		return
	_ensure_index_by_type()
	var rows := _build_rows(record_type, _worker_reader, _worker_name_cache)
	var blob := _search_blob(rows)
	_task_result = {"rows": rows, "blob": blob, "ms": (Time.get_ticks_usec() - started) / 1000.0}

## A private EsmReader on the same plugin as the main thread's, or null when
## none can be opened; the main thread then builds the type itself.
func _open_worker_reader():
	var data := GameDataConfig.resolve()
	var reader := EsmReader.new()
	if reader.open(String(data.get("data_dir", "")) + GameDataConfig.ESM_FILE):
		return reader
	return null

## Moves a finished task's rows in and emits type_ready. With `wait`, waits
## for a running task first.
func _finish_task(wait: bool) -> void:
	if _task_id < 0:
		return
	if not wait and not WorkerThreadPool.is_task_completed(_task_id):
		return
	WorkerThreadPool.wait_for_task_completion(_task_id)
	var record_type := _task_type
	_task_id = -1
	_task_type = ""
	var result := _task_result
	_task_result = {}
	if result.get("failed", false):
		push_warning("SpawnCatalog: no worker EsmReader; building %s on the main thread" % record_type)
		rows_for_type(record_type)
	elif not result.is_empty() and not _rows_by_type.has(record_type):
		_store(record_type, result["rows"], result["blob"])
		build_ms[record_type] = result["ms"]
	type_ready.emit(record_type)

## The rows of every type in a category, in the category's type order.
func rows_for_category(category: Dictionary) -> Array:
	var result := []
	for type: String in category.get("types", []):
		result.append_array(rows_for_type(type))
	return result

## The row for a FormID of a type, or {}.
func row_for_form_id(record_type: String, form_id: int) -> Dictionary:
	for row: Dictionary in rows_for_type(record_type):
		if int(row["form_id"]) == form_id:
			return row
	return {}

## The row of record `form_id`, of any type the menu shows; {} for none. From
## its type's rows when built, else built alone on the main thread, so a list
## of records of many types (SpawnLists) does not build every type.
func row_for(form_id: int) -> Dictionary:
	_ensure_index_by_form()
	var entry: Array = _index_by_form.get(form_id, [])
	if entry.is_empty():
		return {}
	var record_type: String = entry[0]
	if _rows_by_type.has(record_type):
		return row_for_form_id(record_type, form_id)
	if not _single_rows.has(form_id):
		_single_rows[form_id] = _make_row(entry[1], record_type, _reader, RecordVisuals.new(_reader, _archives), _name_cache)
	return _single_rows[form_id]

## The form id of the record with EditorID `editor_id` (any case) among the
## types the menu shows; 0 for none.
func form_id_for_editor_id(editor_id: String) -> int:
	_ensure_index_by_form()
	return int(_form_by_editor_id.get(editor_id.to_lower(), 0))

func _ensure_index_by_form() -> void:
	if not _index_by_form.is_empty():
		return
	if _index_by_type.is_empty():
		# A worker may be splitting the index now; wait for it rather than race.
		_finish_task(true)
		_ensure_index_by_type()
	for record_type: String in _index_by_type:
		for index_row: Dictionary in _index_by_type[record_type]:
			var form_id := int(index_row["form_id"])
			_index_by_form[form_id] = [record_type, index_row]
			var editor_id := String(index_row.get("editor_id", ""))
			if not editor_id.is_empty():
				_form_by_editor_id[editor_id.to_lower()] = form_id

## The index in CATEGORIES of the category that holds `record_type`; -1 for
## none.
static func category_index_for_type(record_type: String) -> int:
	for index in CATEGORIES.size():
		if (CATEGORIES[index]["types"] as Array).has(record_type):
			return index
	return -1

## The tree of `record_type`, as nested nodes: {name, path, count, children}.
## `path` is the group path the node selects (see filter()); the type's own
## node has path "". Children are sorted by name, with the `(...)` nodes
## last. `count` is every row at or below the node.
##
## Group rules:
## - default: the model's folders under meshes/, without the file name
##   (`dungeons/vault/roomkit`); a model directly under meshes/ is `(root)`;
## - NPC_: race, then first faction (SNAM), else `(no faction)`; an NPC_'s
##   MODL is a shared skeleton, so it says nothing about the NPC;
## - leveled lists: the first word of the humanized EditorID (`Loot`, `LL`);
## - a record with no model: `(no model)`.
func build_tree(record_type: String) -> Dictionary:
	if not _trees_by_type.has(record_type):
		_trees_by_type[record_type] = tree_from_rows(record_type, rows_for_type(record_type))
	return _trees_by_type[record_type]

## The tree (as build_tree() gives it) of just `rows`, as for the rows of a
## type that match a search.
static func tree_from_rows(record_type: String, rows: Array) -> Dictionary:
	# Rows share few groups (STAT: 6785 rows, a few hundred groups), so count
	# rows per group first and walk each group's path once.
	var per_group := {}
	for row: Dictionary in rows:
		var group: String = row["group"]
		per_group[group] = int(per_group.get(group, 0)) + 1
	var root := {"name": record_type, "path": "", "count": rows.size(), "children": {}}
	for group: String in per_group:
		var n: int = per_group[group]
		var node := root
		var path := ""
		for part in group.split("/", false):
			path = part if path.is_empty() else path + "/" + part
			var children: Dictionary = node.children
			if not children.has(part):
				children[part] = {"name": part, "path": path, "count": 0, "children": {}}
			node = children[part]
			node.count += n
	return _sorted_tree(root)

## The rows of `rows` in the tree node at `group_path` ("" for all) whose
## text matches `needle` (matches()).
static func filter(rows: Array, needle: String, group_path: String = "") -> Array:
	var lowered := needle.strip_edges().to_lower()
	var form_id := ConsoleCompleter.parse_form_id(lowered) if not lowered.is_empty() else -1
	var result := []
	for row: Dictionary in rows:
		if not in_group(row, group_path):
			continue
		if lowered.is_empty() or _matches_lowered(row, lowered, form_id):
			result.append(row)
	return result

## Whether a row is at or below the tree node at `group_path`.
static func in_group(row: Dictionary, group_path: String) -> bool:
	if group_path.is_empty():
		return true
	var group := String(row["group"])
	return group == group_path or group.begins_with(group_path + "/")

## Whether a row matches a search: its display name, EditorID or FormID hex
## contains the text (case-insensitive), or the text is the row's FormID as
## the console writes one (`0xE3778`, `000e3778`).
static func matches(row: Dictionary, needle: String) -> bool:
	var lowered := needle.strip_edges().to_lower()
	if lowered.is_empty():
		return true
	return _matches_lowered(row, lowered, ConsoleCompleter.parse_form_id(lowered))

static func _matches_lowered(row: Dictionary, lowered: String, form_id: int) -> bool:
	if form_id >= 0 and int(row["form_id"]) == form_id:
		return true
	var text: Variant = row.get("search")
	return (text if text != null else search_text(row)).contains(lowered)

## What a search looks in, lower case: the display name, EditorID and FormID
## hex, a line each so no match spans two of them. Built once per row (on the
## worker), so a search is one contains() per row.
static func search_text(row: Dictionary) -> String:
	return ("%s\n%s\n%08x" % [row["display_name"], row["editor_id"], int(row["form_id"])]).to_lower()

## A record's name for the menu: its FULL name, unless empty or only the
## type's tag; else its humanized EditorID; else its FormID. The editor
## browser (addons/godotbryo_browser) uses the same rule.
static func display_name(full_name: String, editor_id: String, record_type: String, form_id: int) -> String:
	var full := full_name.strip_edges()
	if not full.is_empty() and full.to_lower() != record_type.strip_edges().to_lower():
		return full
	var editor := editor_id.strip_edges()
	return humanize(editor) if not editor.is_empty() else "0x%08X" % form_id

## An EditorID split into words: `WeapNV9mmPistol` -> `Weap NV 9 mm Pistol`.
## The editor browser's rule, on character codes (it runs on every row).
static func humanize(value: String) -> String:
	var length := value.length()
	if length == 0:
		return value
	var kinds := PackedByteArray()
	kinds.resize(length)
	for i in length:
		kinds[i] = _char_kind(value.unicode_at(i))
	var output := PackedStringArray()
	var word_start := 0
	for i in range(1, length):
		var c := kinds[i]
		var previous := kinds[i - 1]
		var next := kinds[i + 1] if i + 1 < length else KIND_NONE
		var boundary := (c == KIND_UPPER and previous == KIND_LOWER) \
				or (c == KIND_UPPER and previous == KIND_UPPER and next == KIND_LOWER) \
				or (c == KIND_DIGIT and previous != KIND_DIGIT) \
				or (c != KIND_DIGIT and previous == KIND_DIGIT and value.unicode_at(i) != 0x78)
		if boundary and value.unicode_at(i - 1) != 0x20:
			output.append(value.substr(word_start, i - word_start))
			word_start = i
	output.append(value.substr(word_start))
	return " ".join(output)

const KIND_NONE := 0
const KIND_UPPER := 1
const KIND_LOWER := 2
const KIND_DIGIT := 3
const KIND_OTHER := 4

static func _char_kind(code: int) -> int:
	if code >= 0x41 and code <= 0x5A:
		return KIND_UPPER
	if code >= 0x61 and code <= 0x7A:
		return KIND_LOWER
	if code >= 0x30 and code <= 0x39:
		return KIND_DIGIT
	if code < 0x80:
		return KIND_OTHER
	var text := char(code)
	var upper := text.to_upper()
	var lower := text.to_lower()
	if text == upper and text != lower:
		return KIND_UPPER
	if text == lower and text != upper:
		return KIND_LOWER
	return KIND_OTHER

# --- Building --------------------------------------------------------------

func _build_rows(record_type: String, reader, name_cache: Dictionary) -> Array:
	# One per build: it holds `reader`, which belongs to this thread.
	var visuals := RecordVisuals.new(reader, _archives)
	var rows := []
	for index_row: Dictionary in _index_by_type.get(record_type, []):
		rows.append(_make_row(index_row, record_type, reader, visuals, name_cache))
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var an := String(a["display_name"]).naturalnocasecmp_to(String(b["display_name"]))
		return an < 0 if an != 0 else int(a["form_id"]) < int(b["form_id"]))
	return rows

## One record's row (see the class doc) from its index row and raw record.
func _make_row(index_row: Dictionary, record_type: String, reader, visuals: RecordVisuals, name_cache: Dictionary) -> Dictionary:
	var model_tag := "MOD2" if record_type == "ARMO" else "MODL"
	var form_id := int(index_row["form_id"])
	var editor_id := String(index_row.get("editor_id", ""))
	var row := {
		"form_id": form_id,
		"record_type": record_type,
		"editor_id": editor_id,
		"full_name": String(index_row.get("full_name", "")),
		"model": "",
		"icon": "",
		"model_missing": false,
		"group": "",
	}
	row["display_name"] = display_name(row["full_name"], editor_id, record_type, form_id)
	row["search"] = search_text(row)
	var race_form_id := 0
	var faction_form_id := 0
	var raw: Dictionary = reader.get_record_data(form_id) if reader != null else {}
	var visual := visuals.visual(raw)
	row["shown_icon"] = visual["icon"]
	row["shown_model"] = visual["model"]
	row["shown_leveled"] = visual["leveled"]
	row["parts"] = visual["parts"]
	for sub: Dictionary in raw.get("subrecords", []):
		var tag := String(sub["type"])
		var data: PackedByteArray = sub["data"]
		if tag == model_tag and String(row["model"]).is_empty():
			row["model"] = _asset_path(data, "meshes/")
		elif tag == "ICON" and String(row["icon"]).is_empty():
			row["icon"] = _asset_path(data, "textures/")
		elif record_type == "NPC_" and tag == "RNAM" and data.size() >= 4:
			race_form_id = data.decode_u32(0)
		elif record_type == "NPC_" and tag == "SNAM" and faction_form_id == 0 and data.size() >= 4:
			faction_form_id = data.decode_u32(0)
	var model := String(row["model"])
	if not model.is_empty() and _archives != null:
		row["model_missing"] = not _archives.contains("meshes/" + model)
	row["group"] = _group(row, race_form_id, faction_form_id, reader, name_cache)
	return row

func _group(row: Dictionary, race_form_id: int, faction_form_id: int, reader, name_cache: Dictionary) -> String:
	var record_type := String(row["record_type"])
	if record_type == "NPC_":
		var race := _record_name(race_form_id, reader, name_cache) if race_form_id != 0 else "(no race)"
		var faction := _record_name(faction_form_id, reader, name_cache) if faction_form_id != 0 else NO_FACTION_GROUP
		return race + "/" + faction
	if record_type in LEVELED_TYPES:
		var words := humanize(String(row["editor_id"])).split(" ", false)
		return _segment(words[0]) if not words.is_empty() else "(no EditorID)"
	var model := String(row["model"])
	if model.is_empty():
		return NO_MODEL_GROUP
	var slash := model.rfind("/")
	return model.substr(0, slash) if slash > 0 else ROOT_GROUP

## A record's display name, for a tree node (race, faction), cached.
func _record_name(form_id: int, reader, name_cache: Dictionary) -> String:
	if name_cache.has(form_id):
		return name_cache[form_id]
	var full := ""
	var editor := ""
	var record_type := ""
	var raw: Dictionary = reader.get_record_data(form_id) if reader != null else {}
	record_type = String(raw.get("record_type", ""))
	for sub: Dictionary in raw.get("subrecords", []):
		var tag := String(sub["type"])
		if tag == "EDID" and editor.is_empty():
			editor = (sub["data"] as PackedByteArray).get_string_from_ascii()
		elif tag == "FULL" and full.is_empty():
			full = (sub["data"] as PackedByteArray).get_string_from_utf8()
	var result := _segment(display_name(full, editor, record_type, form_id))
	name_cache[form_id] = result
	return result

## A name made safe as one `/`-separated group segment.
static func _segment(value: String) -> String:
	var cleaned := value.replace("/", "-").strip_edges()
	return cleaned if not cleaned.is_empty() else "(unnamed)"

## A raw path subrecord as a lower-case, forward-slash path under `root`
## (meshes/, textures/), without that root.
static func _asset_path(data: PackedByteArray, root: String) -> String:
	return RecordVisuals.asset_path(data, root)

static func _sorted_tree(node: Dictionary) -> Dictionary:
	var names: Array = (node.children as Dictionary).keys()
	names.sort_custom(func(a: String, b: String) -> bool:
		var a_special := a.begins_with("(")
		var b_special := b.begins_with("(")
		if a_special != b_special:
			return b_special
		return a.naturalnocasecmp_to(b) < 0)
	var children := []
	for child_name: String in names:
		children.append(_sorted_tree(node.children[child_name]))
	return {"name": node.name, "path": node.path, "count": node.count, "children": children}
