@tool
class_name EsmResource
extends Resource

## A resource mirroring an ESM record (EsmBase) or placement (EsmReference).
## A clean one is rehydrated from the ESM; once changed at runtime it is dirty,
## and is rehydrated from save data instead, never again from the ESM.

## Not an ESM field: whether this resource changed at runtime since it was
## read from the ESM. Set by mark_dirty(); EsmBase does not rehydrate a dirty
## base from the ESM. Saved with the resource.
@export var dirty: bool = false

## Records that this resource changed at runtime.
func mark_dirty() -> void:
	dirty = true
