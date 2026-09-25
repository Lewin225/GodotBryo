# NifServer

Implements [`Plans/Completed Plans/NifServer/nif_server_v2.md`](../../../Plans/Completed%20Plans/NifServer/nif_server_v2.md).
One NIF path in, one honest Godot tree out — the result reflects the file's contents, never the
caller's intent. Nothing outside this folder is modified; no autoload is registered yet.

## Files

| file | role |
|---|---|
| `nif_server.gd` | the singleton: public API, admission, build budget, cache, stats |
| `nif_resolver.gd` | worker-side `_resolve()` — raw data only |
| `nif_builder.gd` | main-thread `_build()` — every RS/PS3D-backed object |
| `nif_resolve_result.gd` | the plain-data result passed between them |
| `nif_names.gd` | reversible NIF-name ↔ Godot-node-name mapping (§6) |
| `nif_archive_source.gd` | BSA index + extraction — stand-in for ArchiveServer |
| `nif_server_demo.gd` | headless contract demo |
| `nif_server_viewer.gd` / `.tscn` | visual demo (F toggles `flatten_static`) |

```
tools/Godot_v4.7.1-stable_linux.x86_64 --headless --path project \
    --script res://GodotBryo/Servers/NifServer/nif_server_demo.gd

tools/Godot_v4.7.1-stable_linux.x86_64 --path project \
    res://GodotBryo/Servers/NifServer/nif_server_viewer.tscn
```

> New `class_name` scripts need one editor import pass before `--script` can resolve them:
> `... --headless --path project --editor --quit-after 40`.

## Implemented

| v2 § | behaviour |
|---|---|
| §3 | `request(path, owner, on_complete, flatten_static)`; callback once, on the main thread, owner-validity checked, unparented results freed |
| §3.3 | canonical paths — `\`→`/`, lowercase, leading `meshes/` stripped; one cache identity |
| §3.4 | missing/malformed → `null`; diagnostics as warnings; failures cached |
| §4 | `_resolve()` on `WorkerThreadPool`, `_build()` main-thread only, `builds_per_frame_budget`, admission cap, duplicate-request coalescing |
| §5 | node tree from `childRefs`, `MeshInstance3D` per submesh, collision built not withheld |
| §6 | reversible name escape + authored name on every node as `nif_name` metadata |
| §7 | `request_kf()` → `AnimationLibrary` keyed by sequence name |
| §9 | skinned meshes get a `Skin` of **named binds** with `skeleton` left unset |
| §10 | `flatten_static` — one wrapper, one mesh instance per mesh, hierarchy discarded, collision kept |
| §11 | LOD assets load as ordinary static NIFs; no LOD code path exists |

The root carries the settled −90° X conversion, so results are Y-up and Godot-forward with no
caller-side correction.

## Deliberately not done

Particles, lights, cameras and billboard mode are not constructed yet (the map in v2 §3 covers
them; the demo stops short). Morphs, `BSSegmentedTriShape` segments and property-block identity
for the §7.3 fan-out are not carried.

**TextureServer is not implemented.** What stands in for it is roughly twenty lines: `_resolve()`
gathers texture *bytes* on the worker, the server holds a `path -> bytes | ImageTexture` dict, and
`_build()` decodes and uploads lazily on first use. That deliberately bends v2 §4, which says
`_build()` assigns an **already-uploaded** `ImageTexture` and never calls `create_from_image()`
itself, precisely so decode and upload are paced by TextureServer's own budget. Here they land
inside the build budget instead. Harmless for a six-file demo; the first thing that would blow the
frame budget under streaming load. Also absent: `warm()`/`is_finished()`/`request()`, upload
pacing, in-flight deduplication, and `alpha_safe` variants.

## Data source: built on the legacy reader, not on nifly

**This is the demo's main shortfall.** v2 is designed against nifly's object model — that is where
the §3 node map, the palette audit, the property-sharing histogram and the ragdoll discriminator
were all measured. This implementation instead consumes `NifReader` / `nif_loader.cpp`, a legacy
pre-digested `nif::Mesh` summary, which was an implementation shortcut and not a spec decision.

What that costs, all of it recoverable by repointing at nifly:

| v2 § | needs | in `nif_loader.cpp` | in nifly |
|---|---|---|---|
| §3 node map | node block type — `SceneNode` carries only name/parent/transform | no | `GetBlockTypeStringById()` |
| §5.3 ragdoll split | `bhkCollisionObject` vs `bhkBlendCollisionObject` | no | `GetBlock<bhkBlendCollisionObject>` |
| §6 resolution order | `NiDefaultAVObjectPalette` aliases | no | `NiDefaultAVObjectPalette::objects` |
| §7.3 fan-out | source property-block identity | no | `NiAVObject::propertyRefs` |
| §7.4 palette KFs | `NiStringPalette` + offsets | no | `ControllerLink::stringPaletteRef` |
| §8 all six slots | texture slots 3-5 | slots 0-2 only (`nif_loader.cpp:759-773`) | `BSShaderTextureSet::textures` |
| §5.3 metadata | extra data blocks | no | `NiObjectNET::extraDataRefs` |

Consequently every node here is a `Node3D`: lights, cameras, particle systems and billboard nodes
are not "not built yet", they are unidentifiable through this data source. The GDScript contract
layer above -- threading, budget, cache, delivery, named binds, name mapping, `flatten_static` --
is independent of that choice and stands as written.

Archive reads are mutex-guarded because the `pread()`/`ReadFile()+OVERLAPPED` patch named in v2 §4
is not done; resolves serialise on IO while parsing stays parallel. ArchiveServer replaces this
class and removes the mutex.
