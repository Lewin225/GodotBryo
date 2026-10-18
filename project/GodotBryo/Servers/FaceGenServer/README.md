# FaceGenServer

Shapes a head-part mesh to one NPC's face. `request_morph()` takes a mesh NifServer delivered,
finds the shape's EGM, adds the NPC's FaceGen offsets to its vertices on a worker, and calls back
with that NPC's own copy of the mesh. The morph is done once, when the actor loads; nothing is
recomputed per frame.

Research and plan: [`Plans/Actors/faces.md`](../../../../Plans/Actors/faces.md).

---

## Contract

```gdscript
FaceGenServer.request_morph(mesh: ArrayMesh, model_path: String, shape_name: String, npc: NpcBase,
		requesting_node: Node, on_complete: Callable) -> void   # on_complete(mesh: ArrayMesh)
FaceGenServer.egm_path_for(model_path, shape_name) -> String          # static
FaceGenServer.geometry_coordinates(npc) -> Array[PackedFloat32Array]  # static: [FGGS, FGGA]
FaceGenServer.get_stats() -> Dictionary  ·  reset_stats()  ·  purge_all()
```

**Delivery is a callback, as NifServer's.** `on_complete` must be a method on `requesting_node`
(a bound method is fine); anything else is refused. It is called exactly once, on the main thread,
from `_process` — never from inside `request_morph()` — with the morphed mesh, or with null when
the shape has no EGM that fits. Nothing is delivered once the owner is freed.

**Which EGM.** `<stem>.egm` beside the NIF, or `<stem>hat.egm` / `<stem>nohat.egm` for a shape
named `Hat` / `NoHat` (hair NIFs). An EGM fits a shape whose vertex count is the EGM's, or the
same-stem TRI's V when the EGM holds the TRI's V + K vertices (heads and eyes); the first V EGM
vertices are the NIF's, in NIF order.

**Which coefficients.** The race's FGGS / FGGA for the NPC's gender plus the NPC's own, from the
template when the NPC takes its traits from one. An NPC's FaceGen is an offset from its race's:
the shipped facemods fit race + NPC FGTS, and NPC FGGS centres on zero in every race.

**The offsets.** The sum over modes of coefficient x mode scale x the EGM's s16 value, divided by
70 for metres, added in the shape's own (Gamebryo) axes — the same space as the positions NifServer
delivers. Normals, UVs, skin weights and materials are the source mesh's.

**Results are shared and immutable.** A result is cached by (source mesh, EGM, coefficients), held
weakly, so actors with the same face (templated NPCs, NPCs with zero FaceGen) share one mesh for as
long as one of them holds it. Each delivered mesh carries `face_gen_egm_path` metadata. Callers
must not modify it.

**Work split.** The EGM and its TRI are read and parsed once per path on a worker (native
`EgmReader`, `TriReader`); each morph runs on a worker; only the `ArrayMesh` is built on the main
thread. `deliveries_per_frame` caps the callbacks made in one frame.

## Not done here

- TRI expression morphs (blinks, phonemes) and FGTS textures.
- Headgear: `ActorEquipment` attaches it without asking for a morph yet.

## Tests

`tests/servers/test_face_gen_server.tscn`: path and coefficient rules, Doc Mitchell's head, the
callback contract, and a census of every shape of every HAIR, HDPT and RACE head-part NIF in
FalloutNV.esm (171 shapes in 110 NIFs, all with an EGM that fits). `tests/test_actor_node.tscn`
checks that each of Doc's head-part, eye and hair meshes is morphed.
