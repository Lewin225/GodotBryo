@tool
class_name ProjectileBase
extends EsmBase

## PROJ (Projectile). Named by WEAP DNAM offset 36 and AMMO DAT2 offset 4. What
## a shot is: a hitscan ray or a moving projectile, its model, muzzle flash,
## explosion and sounds. EsmBase holds EDID and FULL. Used by ProjectileServer.
## Census: 95 PROJ in FalloutNV.esm; Plans/Weapons/projectiles.md.
##
## Not read yet (xEdit labels): OBND Object Bounds; MODT; NAM2 muzzle flash
## model info; DEST destruction data (on 25, all thrown or placed).

## DATA offset 0 flags, xEdit's names.
const FLAG_NAMES := "Hitscan:1,Explosion:2,Alt. Trigger:4,Muzzle Flash:8,Can Be Disabled:32,Can Be Picked Up:64,Supersonic:128,Pins Limbs:256,Pass Through Small Transparent:512,Detonates:1024,Rotation:2048"
const FLAG_HITSCAN := 0x001
const FLAG_EXPLOSION := 0x002
const FLAG_ALT_TRIGGER := 0x004
const FLAG_MUZZLE_FLASH := 0x008
const FLAG_CAN_BE_DISABLED := 0x020
const FLAG_CAN_BE_PICKED_UP := 0x040
const FLAG_SUPERSONIC := 0x080
const FLAG_PINS_LIMBS := 0x100
const FLAG_PASS_THROUGH_SMALL_TRANSPARENT := 0x200
const FLAG_DETONATES := 0x400
const FLAG_ROTATION := 0x800

## DATA offset 2 types, xEdit's names.
const TYPE_MISSILE := 1
const TYPE_LOBBER := 2
const TYPE_BEAM := 4
const TYPE_FLAME := 8
const TYPE_CONTINUOUS_BEAM := 16

## MODL: the projectile's model, shown in flight (on all 95). Read; used by
## EsmProjectileNode.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_path: String = ""
## NAM1: the muzzle flash model (on 66 of 95; 24 distinct). Read; used by
## ProjectileServer at the muzzle when Muzzle Flash is set.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var muzzle_flash_model_path: String = ""
## DATA offset 0: Flags (FLAG_NAMES). Hitscan on 29, Explosion on 44. Read;
## used by ProjectileServer.
@export_custom(PROPERTY_HINT_FLAGS, FLAG_NAMES, PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var flags: int = 0
## DATA offset 2: Type (TYPE_*): Missile 56, Lobber 23, Beam 14, Flame 2.
## Read; used by ProjectileServer.
@export_custom(PROPERTY_HINT_ENUM, "None:0,Missile:1,Lobber:2,Beam:4,Flame:8,Continuous Beam:16", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var projectile_type: int = 0
## DATA offset 4: Gravity, a multiplier of world gravity (0 to 20; 0 on 41,
## 1 on 26). Read; used by ProjectileServer for a moving projectile's arc.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var gravity: float = 0.0
## DATA offset 8: Speed, game units per second (0 to 60000). Read; used by
## ProjectileServer for a moving projectile and the kill-cam projectile.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var speed: float = 0.0
## DATA offset 12: Range, game units (640 to 60000; 10000 on 73). Read; used
## by ProjectileServer as the ray's length and a projectile's flight limit.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var projectile_range: float = 0.0
## DATA offset 16: Light (LIGH); NULL on all 95. Read; not used.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var light_form_id: int = 0
## DATA offset 20: Muzzle Flash Light (LIGH), on 52. Read; used by
## ProjectileServer with the muzzle flash.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var muzzle_flash_light_form_id: int = 0
## DATA offset 24: Tracer Chance, 0 to 1 (0.5 and 0.3 on the two tracer
## rounds, 0 on the rest). Read; used by ProjectileServer.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var tracer_chance: float = 0.0
## DATA offset 28: Explosion - Alt. Trigger - Proximity, game units (100 on
## the mines and placed charges). Read; used by ProjectileServer.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var alt_trigger_proximity: float = 0.0
## DATA offset 32: Explosion - Alt. Trigger - Timer, seconds (2.5 on the
## grenades). Read; used by ProjectileServer as the fuse.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var alt_trigger_timer: float = 0.0
## DATA offset 36: Explosion (EXPL), on 51. Read; resolved into `explosion`.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var explosion_form_id: int = 0
## The EXPL of explosion_form_id; null when none. Set; used by
## ProjectileServer when the Explosion flag is set.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "ExplosionBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var explosion: ExplosionBase = null
## DATA offset 40: Sound (SOUN), played in flight; on 37. Read; used by
## ProjectileServer.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "SoundBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var sound: SoundBase = null
## DATA offset 44: Muzzle Flash - Duration, seconds (0 to 0.6). Read; used by
## ProjectileServer.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var muzzle_flash_duration: float = 0.0
## DATA offset 48: Fade Duration, seconds (0.5 on 81). Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var fade_duration: float = 0.0
## DATA offset 52: Impact Force (0 to 50). Read; not used yet (pushing what
## a hit strikes).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var impact_force: float = 0.0
## DATA offset 56: Sound - Countdown (SOUN), on 11. Read; used by
## ProjectileServer while a fuse runs.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "SoundBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var countdown_sound: SoundBase = null
## DATA offset 60: Sound - Disable (SOUN), on 9. Read; used by
## ProjectileServer when a projectile is disarmed.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "SoundBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var disable_sound: SoundBase = null
## DATA offset 64: Default Weapon Source (WEAP), on 15. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var default_weapon_source_form_id: int = 0
## DATA offset 68: Rotation, a vec3 (non-zero on 26; the Rotation flag on 5).
## Absent on the 17 PROJ whose DATA is 68 bytes. Read; used by
## ProjectileServer as a spin, degrees per second about each axis, when the
## Rotation flag is set. `# ASSUMPTION` the unit.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var rotation: Vector3 = Vector3.ZERO
## DATA offset 80: Bouncy Mult (xEdit's label; 1 on 29, 0 on 33, values that
## are not multipliers on 8). Absent on the 68-byte DATA. Read; used by
## ProjectileServer for a bounce, clamped to 0..1. `# ASSUMPTION` the field.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var bouncy_mult: float = 0.0
## VNAM: Sound Level (1 on 90 of 95). Read; not used yet (detection).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var sound_level: int = 0


func is_hitscan() -> bool:
	return flags & FLAG_HITSCAN != 0


## Whether it explodes on impact: the Explosion flag decides, not the
## Explosion field (7 PROJ name an EXPL with the flag clear: the hatchet and
## spear, the spits, the Tesla cannon, the plasma caster, ARCHIMEDES II).
## `# ASSUMPTION`
func explodes() -> bool:
	return flags & FLAG_EXPLOSION != 0 and explosion != null
