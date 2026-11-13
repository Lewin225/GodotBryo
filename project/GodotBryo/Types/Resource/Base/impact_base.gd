@tool
class_name ImpactBase
extends EsmBase

## IPCT (Impact): what a hit leaves on one surface material. Named by IPDS
## DATA. EsmBase holds EDID. Census: 125 IPCT in FalloutNV.esm.
##
## Not read yet (xEdit labels): MODT; DODT Decal Data (on 119); DNAM Texture
## Set (TXST, on 91), the decal's textures; NAM1 Sound 2 (on 1). Decals come
## with them.

## DATA offset 4 orientations, xEdit's names.
const ORIENTATION_SURFACE_NORMAL := 0
const ORIENTATION_PROJECTILE_VECTOR := 1
const ORIENTATION_PROJECTILE_REFLECTION := 2

## MODL: the effect model shown where it hits (on 96). Read; used by
## ProjectileServer.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_path: String = ""
## DATA offset 0: Effect - Duration, seconds (0.25 on 44, 0.06 on 41). Read;
## used by ProjectileServer as the effect model's lifetime.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var duration: float = 0.0
## DATA offset 4: Effect - Orientation (Projectile Reflection 71, Surface
## Normal 40, Projectile Vector 14). Read; used by ProjectileServer.
@export_custom(PROPERTY_HINT_ENUM, "Surface Normal,Projectile Vector,Projectile Reflection", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var orientation: int = 0
## DATA offset 8: Angle Threshold. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var angle_threshold: float = 0.0
## DATA offset 12: Placement Radius. Read; not used yet (decals).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var placement_radius: float = 0.0
## SNAM: Sound 1 (SOUN), played where it hits (on 109). Read; used by
## ProjectileServer.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "SoundBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var sound: SoundBase = null
