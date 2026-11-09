class_name SpawnLists
extends RefCounted

## The spawn menu's Spawnlists (SpawnMenuTab's first category): Favourites,
## Common and Recent, each a list of form ids.
##
## - Favourites: records added from the context menu, in the order added.
## - Common: `common` (a SpawnList, by EditorID), resolved by the caller.
## - Recent: records spawned, given or equipped, newest first, at most
##   RECENT_LIMIT, each once.
##
## Favourites and Recent are saved to `path` (a ConfigFile) on every change and
## read back on creation, so they last across sessions.

const FAVOURITES := &"favourites"
const COMMON := &"common"
const RECENT := &"recent"
## The lists, in tree order, and their names.
const LISTS := [FAVOURITES, COMMON, RECENT]
const LIST_NAMES := {FAVOURITES: "Favourites", COMMON: "Common", RECENT: "Recent"}
const DEFAULT_PATH := "user://spawn_menu.cfg"
const COMMON_LIST := "res://spawn_menu/common_spawnlist.tres"
const RECENT_LIMIT := 50

## Emitted when Favourites or Recent changes.
signal changed(list: StringName)

var path := DEFAULT_PATH
var common: SpawnList
var _favourites := PackedInt64Array()
var _recent := PackedInt64Array()

func _init(save_path := DEFAULT_PATH, common_list: SpawnList = null) -> void:
	path = save_path
	common = common_list if common_list != null else load(COMMON_LIST) as SpawnList
	load_saved()

## The form ids of Favourites or Recent (Common is by EditorID: `common`).
func ids(list: StringName) -> PackedInt64Array:
	return _favourites if list == FAVOURITES else _recent if list == RECENT else PackedInt64Array()

func is_favourite(form_id: int) -> bool:
	return _favourites.has(form_id)

## Adds `form_id` to Favourites, or takes it out; true when it is now a
## favourite.
func toggle_favourite(form_id: int) -> bool:
	var index := _favourites.find(form_id)
	if index >= 0:
		_favourites.remove_at(index)
	else:
		_favourites.append(form_id)
	_save()
	changed.emit(FAVOURITES)
	return index < 0

## Puts `form_id` at the front of Recent.
func add_recent(form_id: int) -> void:
	var index := _recent.find(form_id)
	if index == 0:
		return
	if index > 0:
		_recent.remove_at(index)
	_recent.insert(0, form_id)
	if _recent.size() > RECENT_LIMIT:
		_recent.resize(RECENT_LIMIT)
	_save()
	changed.emit(RECENT)

## Empties Favourites and Recent (and their saved copy).
func clear() -> void:
	_favourites.clear()
	_recent.clear()
	_save()
	changed.emit(FAVOURITES)
	changed.emit(RECENT)

func load_saved() -> void:
	var file := ConfigFile.new()
	if file.load(path) != OK:
		return
	_favourites = PackedInt64Array(file.get_value("lists", "favourites", PackedInt64Array()))
	_recent = PackedInt64Array(file.get_value("lists", "recent", PackedInt64Array()))

func _save() -> void:
	var file := ConfigFile.new()
	file.set_value("lists", "favourites", _favourites)
	file.set_value("lists", "recent", _recent)
	file.save(path)
