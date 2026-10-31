# FaceGenServer

Shapes a head-part mesh to one NPC's face, and gives the NPC's skin its FaceGen colour.
`request_morph()` takes a mesh NifServer delivered, finds the shape's EGM, adds the NPC's FaceGen
offsets to its vertices on a worker, and calls back with that NPC's own copy of the mesh.
`request_skin()` calls back with the NPC's face map and body offset. Both are done once, when the
actor loads; nothing is recomputed per frame.

Research and plan: [`Plans/Completed Plans/Actors/faces.md`](../../../../Plans/Completed%20Plans/Actors/faces.md).

---

## Contract

```gdscript
FaceGenServer.request_morph(mesh: ArrayMesh, model_path: String, shape_name: String, npc: NpcBase,
		requesting_node: Node, on_complete: Callable) -> void   # on_complete(mesh: ArrayMesh)
FaceGenServer.egm_path_for(model_path, shape_name) -> String          # static
FaceGenServer.geometry_coordinates(npc) -> Array[PackedFloat32Array]  # static: [FGGS, FGGA]
FaceGenServer.request_skin(npc: NpcBase, requesting_node: Node, on_complete: Callable) -> void
		# on_complete(skin: Dictionary): {"face_map": Texture2D or null, "body_offset": Color}
FaceGenServer.texture_coordinates(npc) -> PackedFloat32Array        # static: FGTS
FaceGenServer.facemod_path_for(npc) · head_egt_path_for(npc) · body_egt_path_for(npc)  # static
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

**Expressions.** When the shape is its TRI's (vertex count V), the delivered mesh carries the
TRI's expressions as blend shapes named as in the TRI (normalized: the morphed positions plus the
offsets, with the source mesh's normals and tangents). A difference morph's offsets are its
deltas. A statistical morph (blinks, squints, eye looks) moves each listed vertex to the next of
the TRI's extra vertices, both with the NPC's FaceGen applied, so it follows this face. A name
met twice keeps its first. Hair and other shapes without a TRI get none. Nothing here sets a
weight; that is the actor's.

**Results are shared and immutable.** A result is cached by (source mesh, EGM, coefficients), held
weakly, so actors with the same face (templated NPCs, NPCs with zero FaceGen) share one mesh for as
long as one of them holds it. Each delivered mesh carries `face_gen_egm_path` metadata. Callers
must not modify it.

**Work split.** The EGM and its TRI are read and parsed once per path on a worker (native
`EgmReader`, `TriReader`); each morph runs on a worker; only the `ArrayMesh` is built on the main
thread. `deliveries_per_frame` caps the callbacks made in one frame.

**The skin.** FGTS is the race's for the NPC's gender plus the NPC's own, from the template when the
NPC takes its traits from one. The face map is the NPC's shipped facemod
(`textures\characters\facemods\falloutnv.esm\<form id>_0.dds`, through TextureServer), else one
built on a worker from the race head's EGT (`<head NIF stem>.egt`): each texel 128 + offset / 2,
the facemods' encoding (they fit 126.3 + 0.46 x offset). Built maps are cached by (EGT,
coefficients), held weakly, like morphed meshes. The body offset is the race's upper-body EGT
(RACE body INDX 3) at the NPC's FGTS, averaged over its texels: every shipped upper-body EGT moves
all its texels alike, so one colour holds it. Offsets are in 8-bit levels; the body offset is
divided by 255 and signed. How the actor combines them with the skin texture is
`EsmActorNode._apply_skin` and `actor_skin.gdshader`.

## Not done here

- Expression weights (the actor's facial player).
- Headgear: `ActorEquipment` attaches it without asking for a morph yet.
- The `M<race>_<npc>_0.dds` / `F<race>_<npc>_0.dds` facemods (an NPC's face on another race; 60
  files, for templated and leveled NPCs).

## Tests

`tests/servers/test_face_gen_server.tscn`: path and coefficient rules, Doc Mitchell's head, the
callback contract, and a census of every shape of every HAIR, HDPT and RACE head-part NIF in
FalloutNV.esm (171 shapes in 110 NIFs, all with an EGM that fits). `tests/test_actor_node.tscn`
checks that each of Doc's head-part, eye and hair meshes is morphed. The server test also
checks Doc's head carries its TRI's 46 expressions and that `BlinkLeft` moves only its 20
vertices; 46 of the 171 census shapes carry expressions. Skin: every upper-body EGT is one value
per mode (within 2%), Doc's face map is his facemod, an NPC without one gets a built 256 x 256
map shared between requests, and an AfricanAmerican NPC's body offset is dark.
