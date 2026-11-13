@tool
class_name WeaponReference
extends EsmReference

## XHLP: the weapon's condition, a fraction (on 460 of FalloutNV.esm's 691
## WEAP REFRs, 0.01 to 0.98); -1 when absent. Not read yet; saved; not used yet
## (condition and jam chance, Plans/Weapons/weapons.md, Later).
@export var condition: float = -1.0:
	set(value):
		condition = value
		mark_dirty()
## Runtime state with no ESM source: how many weapons this reference stands
## for. No WEAP REFR in FalloutNV.esm carries XCNT. Set; saved; not used yet.
@export var count: int = 1:
	set(value):
		count = value
		mark_dirty()
## The AMMO base loaded in the weapon, 0 when empty. Possibly XAMT (on 3 WEAP
## REFRs; meaning inferred from the name, not decoded); not read. Set by
## EsmWeaponNode's reload; saved; used by EsmWeaponNode.loaded_ammo(), the ammo
## a shot fires.
@export var loaded_ammo_form_id: int = 0:
	set(value):
		loaded_ammo_form_id = value
		mark_dirty()
## Rounds loaded in the weapon. Possibly XAMC (on 3 WEAP REFRs; meaning
## inferred from the name, not decoded); not read. Set; saved; used by
## EsmWeaponNode: a shot spends one, a reload fills it from the holder.
@export var loaded_ammo_count: int = 0:
	set(value):
		loaded_ammo_count = value
		mark_dirty()
## Runtime state with no ESM source: whether the weapon is jammed. Set; saved;
## not used yet (the weapon node clears it with a jam clip).
@export var is_jammed: bool = false:
	set(value):
		is_jammed = value
		mark_dirty()
