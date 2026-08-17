class_name GamebryoObject
extends GamebryoReference

## Layer for base records with an OBND (confirmed present on every
## placeable "has a physical form" type checked so far — see
## phases/1/architecture.md's evidence table): editor_id and a type tag.
##
## OBND itself (the bounding-box struct) is NOT parsed/threaded through
## yet — get_cell_references() doesn't read it. No bounds field is added
## here to avoid a field that would silently always read zero; add it when
## something actually needs it (culling, inventory icon framing, ...).

var editor_id: String = ""
var record_type: String = "" # 4-char tag of the base record, e.g. "DOOR"
