class_name FaceGenData
extends Resource

## FaceGen payloads. Raw bytes remain authoritative. The *_values arrays are
## only validated little-endian float views; entry semantics are still opaque.
@export var fggs: PackedByteArray = PackedByteArray()
@export var fgga: PackedByteArray = PackedByteArray()
@export var fgts: PackedByteArray = PackedByteArray()
@export var fggs_values: PackedFloat32Array = PackedFloat32Array()
@export var fgga_values: PackedFloat32Array = PackedFloat32Array()
@export var fgts_values: PackedFloat32Array = PackedFloat32Array()
@export var fggs_decoded: bool = false
@export var fgga_decoded: bool = false
@export var fgts_decoded: bool = false
@export var diagnostics: PackedStringArray = PackedStringArray()
@export var geometry_asset_path: String = ""
@export var geometry_applied: bool = false
@export var geometry_applied_vertex_count: int = 0
@export var geometry_applied_mode_count: int = 0
