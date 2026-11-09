@tool
class_name AmmoEffectBase
extends EsmBase

## AMEF (Ammo Effect). Named by AMMO RCIL. EsmBase holds EDID and FULL.
## Census: 54 AMEF in FalloutNV.esm.

## DATA offset 0 types, xEdit's names.
const TYPE_DAMAGE := 0
const TYPE_DR := 1
const TYPE_DT := 2
const TYPE_SPREAD := 3
const TYPE_WEAPON_CONDITION := 4
const TYPE_FATIGUE := 5
## DATA offset 4 operations, xEdit's names.
const OPERATION_ADD := 0
const OPERATION_MULTIPLY := 1
const OPERATION_SUBTRACT := 2

## DATA offset 0: Type (Damage Mod 19, DT Mod 18, Weapon Condition Mod 11,
## Spread Mod 5, Fatigue Mod 1). Read; Damage Mod used by ProjectileServer.
@export_custom(PROPERTY_HINT_ENUM, "Damage Mod,DR Mod,DT Mod,Spread Mod,Weapon Condition Mod,Fatigue Mod", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var effect_type: int = 0
## DATA offset 4: Operation. Read; used with effect_type.
@export_custom(PROPERTY_HINT_ENUM, "Add,Multiply,Subtract", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var operation: int = 0
## DATA offset 8: Value. Read; used with effect_type.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var value: float = 0.0


## `amount` with this effect applied.
func apply(amount: float) -> float:
	match operation:
		OPERATION_ADD:
			return amount + value
		OPERATION_MULTIPLY:
			return amount * value
		OPERATION_SUBTRACT:
			return amount - value
	return amount
