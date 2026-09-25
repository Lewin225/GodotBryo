@tool
class_name PackageLocation
extends Resource

## One PACK.PLDT or PACK.PLD2 location. `location_value` is a typed union
## decoded from the raw payload according to `location_type`.
enum LocationType {
	NEAR_REFERENCE = 0,
	IN_CELL = 1,
	NEAR_CURRENT_LOCATION = 2,
	NEAR_EDITOR_LOCATION = 3,
	OBJECT_ID = 4,
	OBJECT_TYPE = 5,
	NEAR_LINKED_REFERENCE = 6,
	AT_PACKAGE_LOCATION = 7,
}

## xEdit's FNV Object Type enum. It is meaningful only for OBJECT_TYPE.
enum ObjectType {
	NONE = 0,
	ACTIVATORS = 1,
	ARMOR = 2,
	BOOKS = 3,
	CLOTHING = 4,
	CONTAINERS = 5,
	DOORS = 6,
	INGREDIENTS = 7,
	LIGHTS = 8,
	MISCELLANEOUS = 9,
	FLORA = 10,
	FURNITURE = 11,
	WEAPONS_ANY = 12,
	AMMO = 13,
	NPCS = 14,
	CREATURES = 15,
	KEYS = 16,
	ALCHEMY = 17,
	FOOD = 18,
	ALL_COMBAT_WEARABLE = 19,
	ALL_WEARABLE = 20,
	WEAPONS_RANGED = 21,
	WEAPONS_MELEE = 22,
	WEAPONS_NONE = 23,
	ACTOR_EFFECTS_ANY = 24,
	ACTOR_EFFECTS_RANGE_TARGET = 25,
	ACTOR_EFFECTS_RANGE_TOUCH = 26,
	ACTOR_EFFECTS_RANGE_SELF = 27,
	UNKNOWN_28 = 28,
	ACTORS_ANY = 29,
}

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var location_type: LocationType = LocationType.NEAR_REFERENCE
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "PackageLocationValue", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var location_value: PackageLocationValue
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var radius: int = 0
