@tool
class_name ExplosionBase
extends EsmBase

## EXPL (Explosion). Named by PROJ DATA offset 36, DEST stage data (DSTD) and
## other records. EsmBase holds EDID and FULL. Census: 154 EXPL in
## FalloutNV.esm, 41 named by a PROJ; Plans/Weapons/projectiles.md.
##
## Not read yet (xEdit labels): OBND Object Bounds; EITM Object Effect (ENCH,
## on 22); MNAM Image Space Modifier (IMAD, on 97); DATA offset 24 IS Radius,
## 36 radiation level, dissipation time and radius, 48 Sound Level; INAM
## Placed Impact Object (on none).

## DATA offset 20 flags, xEdit's names.
const FLAG_NAMES := "Radius in BS Units:1,Always Uses World Orientation:2,Knock Down - Always:4,Knock Down - By Formula:8,Ignore LOS Check:16,Push Explosion Source Ref Only:32,Ignore Image Space Swap:64"
const FLAG_ALWAYS_USES_WORLD_ORIENTATION := 0x02
const FLAG_KNOCK_DOWN_ALWAYS := 0x04
const FLAG_KNOCK_DOWN_BY_FORMULA := 0x08
const FLAG_IGNORE_LOS_CHECK := 0x10

## MODL: the explosion's model (most of the PROJ explosions' models hold
## particle systems). Read; used by ProjectileServer where it explodes.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_path: String = ""
## DATA offset 0: Force (0 to 200000). Read; used by ProjectileServer to push
## rigid bodies in the radius.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var force: float = 0.0
## DATA offset 4: Damage at the centre (0 to 20000; frag grenade 125, missile
## 200). Read; used by ProjectileServer.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var damage: float = 0.0
## DATA offset 8: Radius, game units (Radius in BS Units set on all 154).
## Read; used by ProjectileServer.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var radius: float = 0.0
## DATA offset 12: Light (LIGH), on 98. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var light_form_id: int = 0
## DATA offset 16: Sound 1 (SOUN), on 119. Read; used by ProjectileServer.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "SoundBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var sound: SoundBase = null
## DATA offset 20: Flags (FLAG_NAMES). Read; Ignore LOS Check used by
## ProjectileServer; the knock downs not used yet.
@export_custom(PROPERTY_HINT_FLAGS, FLAG_NAMES, PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var flags: int = 0
## DATA offset 28: Impact DataSet (IPDS), on 81. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var impact_dataset_form_id: int = 0
## DATA offset 32: Sound 2 (SOUN), on 94. Read; not used yet.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "SoundBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var second_sound: SoundBase = null
