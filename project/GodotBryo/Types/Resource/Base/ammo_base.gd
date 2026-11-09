@tool
class_name AmmoBase
extends EsmBase

## AMMO (Ammunition). Named by WEAP NAM0, alone or in an FLST. EsmBase holds
## EDID and FULL. Census: 92 AMMO in FalloutNV.esm;
## Plans/Weapons/projectiles.md.
##
## Not read yet (xEdit labels): OBND Object Bounds; SCRI is EsmBase's; DEST;
## YNAM and ZNAM pick up and drop sounds; ONAM Short Name; QNAM Abbrev.

## DATA offset 4 flags, xEdit's names.
const FLAG_NAMES := "Ignores Normal Weapon Resistance:1,Non-Playable:2"
const FLAG_IGNORES_NORMAL_WEAPON_RESISTANCE := 0x01
const FLAG_NON_PLAYABLE := 0x02

## MODL: the item's model. Read; used by the item's node.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_path: String = ""
## DATA offset 8: Value. Read (EsmReader item data); used by the inventory.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var value: int = 0
## DAT2 offset 8: Weight. Read (EsmReader item data); used by the inventory.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var weight: float = 0.0
## ICON. Read; used by the inventory.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var inventory_icon: String = ""
## MICO. Read; used by the inventory.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var message_icon: String = ""
## DATA offset 0: Speed (1 on 71, 10 on 19, 0 on 2). Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var speed: float = 0.0
## DATA offset 4: Flags (FLAG_NAMES); Non-Playable on 16. Read; Ignores
## Normal Weapon Resistance used by ProjectileServer's hit.
@export_custom(PROPERTY_HINT_FLAGS, FLAG_NAMES, PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var flags: int = 0
## DATA offset 12: Clip Rounds. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var clip_rounds: int = 0
## DAT2 offset 0: Proj. per Shot (0 on 82, 1 on 4, 8 on Ammo12GaCoinShot; no
## DAT2 on 5). Read; used by ProjectileServer: non-zero replaces the WEAP's
## Projectile Count. `# ASSUMPTION` 0 keeps it.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var projectiles_per_shot: int = 0
## DAT2 offset 4: Projectile (PROJ), the ammo's override of the WEAP's (on 8:
## slugs, bean bag, coin shot, HE/HV missiles, HE 25mm, incendiary 40mm).
## Read; resolved into `projectile`.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var projectile_form_id: int = 0
## The PROJ of projectile_form_id; null when none. Set; used by
## EsmWeaponNode to resolve the projectile it fires.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "ProjectileBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var projectile: ProjectileBase = null
## DAT2 offset 12: Consumed Ammo (AMMO or MISC, the casing left; MISC on 52).
## Absent on the 11 AMMO whose DAT2 is 12 bytes. Read; not used yet (shells
## dropped by the weapon node).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var consumed_ammo_form_id: int = 0
## DAT2 offset 16: Consumed Percentage. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var consumed_percentage: float = 0.0
## RCIL: the ammo effects (AMEF), 1 to 4 on 58 of 92. Read; used by
## ProjectileServer to modify a hit's damage.
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "AmmoEffectBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var effects: Array[AmmoEffectBase] = []


func ignores_normal_weapon_resistance() -> bool:
	return flags & FLAG_IGNORES_NORMAL_WEAPON_RESISTANCE != 0
