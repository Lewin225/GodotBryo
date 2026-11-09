class_name RecordVisuals
extends RefCounted

## What picture a record has: its inventory icon and the model to render or
## preview, found from its raw subrecords. ThumbnailServer asks it for single
## records on the main thread; SpawnCatalog builds one per worker thread for
## whole types. It holds an EsmReader, which is not thread-safe, so one
## instance belongs to one thread.
##
## The rules are about subrecords and record types, never about particular
## records:
## - a record shows the first of its icon subrecords (SHOWN_ICON_TAGS; ICON
##   for most types) and of its model subrecords (SHOWN_MODEL_TAGS; MODL) an
##   archive has;
## - a CREA's MODL is its skeleton, so it shows its body parts instead (NIFZ's
##   file names in MODL's folder, those an archive has), as one model, turned
##   to face the camera (ACTOR_PREFIX). One with no NIFZ takes its TPLT
##   template's;
## - a leveled list (LVLI, LVLC, or a CREA templated on an LVLC) shows the
##   first of its entries, lowest level first, that has a picture, through
##   nested lists; its visual is `leveled`, as the record placed can differ;
## - NPC_ and LVLN show none yet: an NPC's body comes from its race and head
##   parts, not a model list (spawn menu build step 9).
##
## A visual is {icon, model, leveled, parts}: `icon` under textures/, "" for
## none; `model` a model key (ThumbnailServer.request_model()), "" for none;
## `parts` the body-part paths under meshes/ of a CREA or LVLC.

## Marks a model key as an actor's: request_model() turns it to face the
## camera.
const ACTOR_PREFIX := "actor:"
## Types whose visual is a creature's body parts.
const PART_TYPES := ["CREA", "LVLC"]
## Types with no visual yet (actors with no model list; spawn menu step 9).
const NO_VISUAL_TYPES := ["NPC_", "LVLN"]
## The model subrecords tried for a record's model, in order, by record type
## (MODL alone for any other); the first an archive has wins. ARMO's MODL and
## MOD3 are its worn (biped) models, shown unposed. WEAP leaves out MOD2, which
## names a shell casing or a projectile rather than the weapon.
const SHOWN_MODEL_TAGS := {"ARMO": ["MOD2", "MOD4", "MODL", "MOD3"], "WEAP": ["MODL", "MOD4"]}
## The icon subrecords tried, as SHOWN_MODEL_TAGS (ICON alone for any other).
const SHOWN_ICON_TAGS := {"ARMO": ["ICON", "ICO2"]}
## How deep template chains and nested lists are followed; they are short, so
## this only guards a loop.
const MAX_DEPTH := 8

var _reader
var _archives

## `reader`: an EsmReader (or anything with get_record_data()) this thread
## owns. `archives`: anything with contains(path), ArchiveServer or an
## ArchiveCatalog; null takes every path as present.
func _init(reader, archives) -> void:
	_reader = reader
	_archives = archives

## The visual of the record `form_id`.
func visual_of(form_id: int) -> Dictionary:
	return visual(_reader.get_record_data(form_id) if _reader != null else {})

## The visual of a raw record (EsmReader.get_record_data()).
func visual(raw: Dictionary) -> Dictionary:
	var result := {"icon": "", "model": "", "leveled": false, "parts": PackedStringArray()}
	var record_type := String(raw.get("record_type", ""))
	if record_type.is_empty() or record_type in NO_VISUAL_TYPES:
		return result
	if record_type in PART_TYPES:
		var found := creature_parts(raw)
		var parts: PackedStringArray = found[0]
		result["parts"] = parts
		result["leveled"] = found[1]
		if not parts.is_empty():
			result["model"] = ACTOR_PREFIX + "|".join(Array(parts).map(func(path: String) -> String: return "meshes/" + path))
		return result
	var shown := leveled_item_assets(raw) if record_type == "LVLI" else shown_assets(record_type, raw)
	result["icon"] = shown[0]
	result["model"] = "meshes/" + String(shown[1]) if not String(shown[1]).is_empty() else ""
	result["leveled"] = record_type == "LVLI" and not (String(shown[0]).is_empty() and String(shown[1]).is_empty())
	return result

## [icon, model] for a record of `record_type`, paths under textures/ and
## meshes/: the first of its icon and model subrecords an archive has.
func shown_assets(record_type: String, raw: Dictionary) -> Array:
	var model_tags: Array = SHOWN_MODEL_TAGS.get(record_type, ["MODL"])
	var icon_tags: Array = SHOWN_ICON_TAGS.get(record_type, ["ICON"])
	var found := {}
	for sub: Dictionary in raw.get("subrecords", []):
		var tag := String(sub["type"])
		if not found.has(tag) and (tag in model_tags or tag in icon_tags):
			found[tag] = sub["data"]
	return [_first_in_archive(found, icon_tags, "textures/"), _first_in_archive(found, model_tags, "meshes/")]

func _first_in_archive(found: Dictionary, tags: Array, root: String) -> String:
	for tag: String in tags:
		if not found.has(tag):
			continue
		var path := asset_path(found[tag], root)
		if not path.is_empty() and (_archives == null or _archives.contains(root + path)):
			return path
	return ""

## An LVLI's [icon, model]: those of the first of its entries, lowest level
## first, that has either; a nested list is searched the same way, so an entry
## that leads nowhere (an empty nested list) passes to the next.
func leveled_item_assets(raw: Dictionary, depth := 0) -> Array:
	if String(raw.get("record_type", "")) != "LVLI":
		return shown_assets(String(raw.get("record_type", "")), raw)
	if depth >= MAX_DEPTH or _reader == null:
		return ["", ""]
	for entry in leveled_entries(raw):
		var found := leveled_item_assets(_reader.get_record_data(entry), depth + 1)
		if not (String(found[0]).is_empty() and String(found[1]).is_empty()):
			return found
	return ["", ""]

## A CREA's or LVLC's body parts (paths under meshes/) and whether a leveled
## list chose them: [parts, leveled]. A CREA with NIFZ uses its own; one
## without follows its TPLT template; an LVLC takes the first of its entries,
## lowest level first, that leads to parts.
func creature_parts(raw: Dictionary, depth := 0) -> Array:
	var none := [PackedStringArray(), false]
	var record_type := String(raw.get("record_type", ""))
	if not record_type in PART_TYPES or depth >= MAX_DEPTH:
		return none
	if record_type == "LVLC":
		for entry in leveled_entries(raw):
			var found := creature_parts(_reader.get_record_data(entry), depth + 1) if _reader != null else none
			if not (found[0] as PackedStringArray).is_empty():
				return [found[0], true]
		return none
	var skeleton := ""
	var template := 0
	var names := PackedStringArray()
	for sub: Dictionary in raw.get("subrecords", []):
		var tag := String(sub["type"])
		var data: PackedByteArray = sub["data"]
		if tag == "MODL" and skeleton.is_empty():
			skeleton = asset_path(data, "meshes/")
		elif tag == "NIFZ":
			names.append_array(nul_strings(data))
		elif tag == "TPLT" and data.size() >= 4:
			template = data.decode_u32(0)
	if names.is_empty():
		return creature_parts(_reader.get_record_data(template), depth + 1) if template != 0 and _reader != null else none
	var parts := PackedStringArray()
	var folder := skeleton.get_base_dir()
	for name in names:
		var path := asset_path(name.to_ascii_buffer(), "meshes/")
		path = (folder + "/" + path) if not folder.is_empty() else path
		if _archives == null or _archives.contains("meshes/" + path):
			parts.append(path)
	return [parts, false]

## A leveled list's entry forms (LVLO), lowest level first, in record order
## within a level.
static func leveled_entries(raw: Dictionary) -> PackedInt64Array:
	var entries := []
	for sub: Dictionary in raw.get("subrecords", []):
		var data: PackedByteArray = sub["data"]
		# LVLO: level (u16), 2 unused bytes, the entry's form (u32).
		if String(sub["type"]) == "LVLO" and data.size() >= 8:
			entries.append([data.decode_u16(0), entries.size(), data.decode_u32(4)])
	entries.sort()
	var forms := PackedInt64Array()
	for entry: Array in entries:
		forms.append(entry[2])
	return forms

## The NUL-separated strings of a subrecord (NIFZ).
static func nul_strings(data: PackedByteArray) -> PackedStringArray:
	var result := PackedStringArray()
	var start := 0
	for index in data.size() + 1:
		if index == data.size() or data[index] == 0:
			if index > start:
				result.append(data.slice(start, index).get_string_from_ascii())
			start = index + 1
	return result

## A subrecord's asset path, lower case with forward slashes and without the
## `root` folder ("meshes/", "textures/") or a leading slash.
static func asset_path(data: PackedByteArray, root: String) -> String:
	var path := data.get_string_from_ascii().strip_edges().replace("\\", "/").to_lower()
	while path.begins_with("/"):
		path = path.substr(1)
	if path.begins_with(root):
		path = path.substr(root.length())
	return path
