class_name SaveBackend
extends RefCounted

## Stores and fetches whole save states for SaveServer. A save state is a
## Dictionary of plain values: `header` and one section per owner
## (README.md, Schema). A backend never touches game objects and only sees
## save states already in the current format version; SaveServer migrates
## and checks them. Subclasses override every method.

## Why the last call failed; empty after a success.
var last_error := ""
## The playthrough being played, set by SaveServer. A backend that keeps
## playthroughs apart files a save without one in its header here, and reads
## a save_id that names none from here.
var playthrough_id := ""


## Stores `state` under `save_id`, replacing any save already there only once
## the new one is complete.
func write(_save_id: String, _state: Dictionary) -> Error:
	return ERR_UNAVAILABLE


## The save state stored under `save_id`, or {} with the reason in last_error.
func read(_save_id: String) -> Dictionary:
	return {}


## The header of every stored save, each with its `save_id`, for the save
## browser.
func list() -> Array[Dictionary]:
	return []


## Whether a save is stored under `save_id`.
func has_save(save_id: String) -> bool:
	return list().any(func(header: Dictionary) -> bool: return header["save_id"] == save_id)


func delete(_save_id: String) -> Error:
	return ERR_UNAVAILABLE


## What the backend supports beyond the above: "parents" (saves form a tree of
## branches), "sync" (saves shared between machines), "partial_read" (a
## section read on its own).
func capabilities() -> PackedStringArray:
	return PackedStringArray()
