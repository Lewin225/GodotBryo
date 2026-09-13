@tool
extends Node

## ArchiveServer -- the project's one owner of archive discovery, BSA priority
## and byte reads. Implements Plans/archive_server.md.
##
## Lifecycle and configuration only: the catalog, the global path index and all
## I/O live in native `ArchiveCatalog` (src/bsa/bsa_catalog.{h,cpp}). This
## script keeps no per-worker readers and no second index.
##
## read() is callable from worker threads once initialization has completed:
## the catalog is immutable afterwards and reads are positional, so there is no
## shared cursor and no mutex on the data path.

var _catalog: ArchiveCatalog
var _ready_ok := false
var _init_error := ""
var _available := true


func _ready() -> void:
	var data_dir := _resolve_data_dir()
	if data_dir.is_empty():
		_init_error = "no data directory configured"
		push_error("ArchiveServer: " + _init_error)
		return
	_catalog = ArchiveCatalog.new()
	if not _catalog.open_data_dir(data_dir):
		_init_error = _catalog.get_last_error()
		push_error("ArchiveServer: " + _init_error)
		_catalog = null
		return
	_ready_ok = true
	for failure in _catalog.get_failed_archives():
		push_warning("ArchiveServer: archive skipped -- " + String(failure))


func _exit_tree() -> void:
	# Marks the catalog unavailable to new reads. Does not block waiting for
	# in-flight worker reads; the native catalog stays alive by refcount until
	# they return.
	_available = false


## Thread-safe after initialization.
## Returns {found: bool, archive: String, data: PackedByteArray, error: String}.
## `found == true` with zero bytes is a legitimate result -- never infer failure
## from data.size() alone.
func read(path: String) -> Dictionary:
	if not _available or not _ready_ok:
		return {
			"found": false,
			"archive": "",
			"data": PackedByteArray(),
			"error": _init_error if not _init_error.is_empty() else "archive server unavailable",
		}
	return _catalog.read(path)


## Thread-safe after initialization.
func contains(path: String) -> bool:
	return _ready_ok and _available and _catalog.contains(path)


## Winning archive for a path, or "" if not indexed. Index-only lookup, no
## extraction -- for diagnostics and priority audits. Thread-safe.
func winning_archive(path: String) -> String:
	if not _ready_ok or not _available:
		return ""
	return _catalog.winning_archive(path)


## Every normalized path under `prefix`, deduplicated by the same winner rule
## read() uses. Thread-safe after initialization.
func list_files_with_prefix(prefix: String) -> PackedStringArray:
	if not _ready_ok or not _available:
		return PackedStringArray()
	return _catalog.list_files_with_prefix(prefix)


func is_ready() -> bool:
	return _ready_ok and _available


func get_init_error() -> String:
	return _init_error


## Main-thread diagnostic snapshot. Deliberately carries no per-read counters:
## read() is the worker data path and touches no mutable state, so no atomics
## are needed anywhere (Plans/archive_server.md, settled open question).
func get_stats() -> Dictionary:
	return {
		"ready": _ready_ok,
		"available": _available,
		"init_error": _init_error,
		"archive_count": _catalog.get_archive_order().size() if _ready_ok else 0,
		"entry_count": _catalog.get_entry_count() if _ready_ok else 0,
		"failed_archives": _catalog.get_failed_archives() if _ready_ok else PackedStringArray(),
		"archive_order": _catalog.get_archive_order() if _ready_ok else PackedStringArray(),
	}


func _resolve_data_dir() -> String:
	var root := get_tree().root
	if root.has_node("GameDataSettings"):
		var dir := String(root.get_node("GameDataSettings").get_data_dir())
		if not dir.is_empty():
			return dir
	var cfg := ConfigFile.new()
	if cfg.load("res://game_data.cfg") == OK:
		return String(cfg.get_value("game_data", "data_dir", ""))
	return ""
