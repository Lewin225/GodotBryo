@tool
class_name DestructionStageCollection
extends Resource

## One destruction stage: DSTD, DMDL, DMDT, ended by DSTF.

## DSTD offset 0: Health %. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var health_percent: int = 0
## DSTD offset 1: Index. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var index: int = 0
## DSTD offset 2: Damage Stage. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var damage_stage: int = 0
## DSTD offset 3: Flags. Read; not used yet.
@export_custom(PROPERTY_HINT_FLAGS, "Cap Damage,Disable,Destroy", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var flags: int = 0
## DSTD offset 4: Self Damage per Second (s32). Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var self_damage_per_second: int = 0
## DSTD offset 8: Explosion. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var explosion_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "ExplosionBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var explosion: ExplosionBase
## DSTD offset 12: Debris. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var debris_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "DebrisBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var debris: DebrisBase
## DSTD offset 16: Debris Count (s32). Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var debris_count: int = 0
## DMDL: the stage's model file name. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_path: String = ""
## DMDT: the model's texture-file hashes, raw. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_info: PackedByteArray = PackedByteArray()
