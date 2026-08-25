class_name GamebryoResolveContext
extends RefCounted

## phases/2/10-threaded-streaming-workers.md, step 3: the per-task-private
## state a threaded tile resolve needs. Bundles a GamebryoMeshResolver
## (BSA/NIF/mesh/texture/collision resolution, per step 2) with its own
## private EsmReader -- caught directly while building resolve_placement()
## below: DOOR/SCOL/LIGH resolution also reads the ESM directly
## (get_door_destination()/get_scol_parts()/get_light_data()), and EsmFile
## is documented at its own source as "Not thread-safe (single FILE* with
## seek+read)" -- the exact same reason GamebryoMeshResolver's BSA readers
## needed to be per-instance, not shared, in step 2. GamebryoResolverPool
## pools these (not bare GamebryoMeshResolvers) so a checked-out context has
## everything a resolve task needs without ever touching
## GamebryoObjectRegistry's own shared `esm`/`resolver` fields.

var resolver: GamebryoMeshResolver
var esm: EsmReader

func _init() -> void:
	resolver = GamebryoMeshResolver.new()
	esm = EsmReader.new()
	if not esm.open(GamebryoMeshResolver.get_data_dir() + "FalloutNV.esm"):
		push_error("GamebryoResolveContext: could not open FalloutNV.esm")
