@tool
class_name InitialItemCollection
extends Resource

## One entry of an actor's (or container's) xEdit "Items": a CNTO subrecord and
## the COED Extra Data that may follow it (fopdoc's "Item Subrecord
## Collection"). The authored starting item, shared by every placement of its
## base; not InventoryItem, the live per-placement item.

## CNTO offset 0: the item, an item's Base or a LeveledItemBase. Read; used to
## build the reference's inventory.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var item_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EsmBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var item: EsmBase
## CNTO offset 4: Count (s32). Read; used to build the reference's inventory.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var count: int = 1
## COED offset 0: Owner, an NpcBase or FactionBase; 0 without COED. Read (set
## on 2 CONT entries in FalloutNV.esm); carried to the InventoryItem.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var owner_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EsmBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var owner: EsmBase
## COED offset 4 when the owner is an NPC_: Global Variable (xEdit
## `wbCOEDOwnerDecider`). Set by no COED in FalloutNV.esm; read, always 0.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var global_variable_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "GlobalBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var global_variable: GlobalBase
## COED offset 4 when the owner is a FACT: Required Rank. Set by no COED in
## FalloutNV.esm; read, always 0.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var required_rank: int = 0
## COED offset 8: Item Condition, 0-1; -1 without COED. Read; carried to the
## InventoryItem's health_percent.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var condition: float = -1.0
