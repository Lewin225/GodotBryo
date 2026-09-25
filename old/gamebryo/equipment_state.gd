@tool
class_name EquipmentState
extends Resource

## Armor is ordered from lowest to highest priority. Overlapping slot masks
## are resolved by keeping the later (higher-priority) record. Entries within
## one ARMO are retained together because its ARMA list is authored as a
## single outfit composition.
@export var armor_records: Array[ArmorRecord] = []
@export var weapon: WeaponRecord
@export var diagnostics: PackedStringArray = []
