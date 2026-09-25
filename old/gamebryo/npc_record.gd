@tool
class_name NpcRecord
extends EsmRecordResource

@export var full_name: String = ""
@export var model_path: String = ""
@export var race: RaceRecord
@export var hair: HairRecord
@export var eyes: EyesRecord
@export var actor_class: ClassRecord
@export var is_female: bool = false
## Selects the authored child locomotion family. This is intentionally an
## explicit resource field until the Fallout NV child flag's exact source
## bit is verified; false preserves the adult male/female behavior.
@export var is_child: bool = false
@export var acbs_flags: int = 0
@export var inventory: Array[InventoryEntryResource] = []
@export var packages: Array[PackageRecord] = []
@export var face_gen: FaceGenData
