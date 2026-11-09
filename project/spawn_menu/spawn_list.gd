class_name SpawnList
extends Resource

## A list of records for the spawn menu's Spawnlists tab, named by EditorID, so
## it is data rather than code: another game's data can ship its own. The
## Common list is common_spawnlist.tres. EditorIDs the loaded data does not
## have are skipped.

## The records, in the order shown.
@export var editor_ids := PackedStringArray()
