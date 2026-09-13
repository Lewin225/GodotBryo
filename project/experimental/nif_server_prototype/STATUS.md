# NifServer prototype (superseded)

Moved here 2026-09-12. **Not live code** — nothing references it, it is not an autoload, and it does
not run. Kept only as reference material for Stage E of
[`Plans/server_stack_build_order.md`](../../../Plans/server_stack_build_order.md).

## Why it was moved

It was built against `NifReader` / `nif_loader.cpp`, a legacy pre-digested summary, rather than
nifly's object model — which is what every measurement in
[`nif_server_v2.md`](../../../Plans/NifServer/nif_server_v2.md) was taken from. That data source
cannot express the §3 node map (no block type per node), §5.3 ragdoll split, §6 palette resolution,
§7.3 property identity, §7.4 palette KFs, or §8 texture slots 3-5. Stage D builds the nifly-backed
source; Stage E rebuilds the server on it.

Two of its files were also superseded by servers that have since shipped:

| file | superseded by |
|---|---|
| `nif_archive_source.gd` | `ArchiveServer` (Stage B) — catalog, BSA priority, positional reads |
| texture decode inside `nif_builder.gd` | `TextureServer` (Stage C) — decode/upload/cache with budget |

## What is worth reusing at Stage E

| file | status |
|---|---|
| `nif_names.gd` | **finished and data-source independent** — reversible escaping, round-trip verified |
| `nif_server.gd` | contract layer: threading split, admission cap, build budget, request coalescing, cache identity, owner-aware delivery. Reusable shape; see §E7 for the ownership-safety-net bug that must be fixed |
| `nif_builder.gd` | named-bind `Skin` construction and the -90° X root transform are correct; the rest is shaped around the legacy result |
| `nif_resolve_result.gd` | reasonable starting schema, will change once Stage D defines the real source |
| `nif_server_demo.gd`, `nif_server_viewer.*` | demos of the superseded pipeline |

`README.md` is the original prototype write-up, including its own account of what it got wrong.
