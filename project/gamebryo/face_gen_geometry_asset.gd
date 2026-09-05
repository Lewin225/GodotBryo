class_name FaceGenGeometryAsset
extends Resource

## Parsed EGM basis shared by a race/gender head. Mode entries are flat xyz
## delta arrays in FaceGen vertex order.
@export var source_path: String = ""
@export var vertex_count: int = 0
@export var symmetric_mode_count: int = 0
@export var asymmetric_mode_count: int = 0
@export var symmetric_basis: Array = []
@export var asymmetric_basis: Array = []
