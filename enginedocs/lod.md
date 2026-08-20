# Gamebryo/Creation-era engine notes — Distant LOD

Pure findings about how Fallout: New Vegas's own engine and data represent distant
object LOD, established directly against real game files (`FalloutNV.esm`, the shipped
BSAs, `Fallout_default.ini`/quality-preset `.ini`s) rather than assumed from modding-
community documentation. No solution/implementation notes here — see the relevant
`phases/2/*.md` task doc for how (or whether) this project acts on any of it.

## There is no separate "terrain LOD" mesh format

Checked every shipped BSA (main game + all DLC) and the loose `Data/` tree for anything
matching a terrain-LOD naming/folder convention (`meshes/terrain/...`,
`textures/terrain/.../lod/...` or similar). **Zero matches.** Whatever this engine does
for distant terrain rendering, it does not ship as separate pre-baked terrain-LOD mesh
assets the way some other Bethesda titles do.

## Object LOD is a paired-mesh convention, not a separate system

What *does* exist, extensively: **1,647 files** across the shipped BSAs with a
`_lod.nif` suffix, sitting in the same folder as (and clearly a simplified companion
to) a full-detail mesh of the same base name — confirmed directly, not inferred: both
`meshes/architecture/barracks/barracks01.nif` and
`meshes/architecture/barracks/barracks01_lod.nif` exist side by side in
`Fallout - Meshes.bsa`.

Breakdown by top-level folder (`meshes/<folder>/...`):

| Folder | Count | What it covers |
|---|---|---|
| `architecture` | 522 | Buildings |
| DLC-specific (`nvdlc02`/`03`/`04`, `dlcpitt`, `dlc03`/`04`/`05`, `dlcanch`) | ~530 | DLC structures, terrain-adjacent geology |
| `landscape` | 100 | Rocks, cliffs, crystals, craters, trees |
| `dungeons` | 51 | Exterior-facing dungeon walls |
| `scol` | 42 | Static Collection LOD variants |
| `clutter`, `vehicles`, `trees` | ~52 | Smaller props |

## Per-category LOD distance tuning is real (from `Fallout_default.ini`'s `[LOD]` section)

```ini
[LOD]
fLodDistance=500.0000
fLODBoundRadiusMult=10
fLODFadeOutMultItems=3
fLODFadeOutMultObjects=5
fLODFadeOutMultActors=6
fLODMultLandscape=1.0000
fLODMultTrees=0.5000
fObjectLODMax=15.0    fObjectLODMin=1.0    fObjectLODDefault=5
fItemLODMax=15.0      fItemLODMin=1.0      fItemLODDefault=2
fActorLODMax=15.0     fActorLODMin=2.0     fActorLODDefault=5
```

These are genuinely different per category (Objects/Items/Actors/Trees/Landscape each
get their own multiplier), and scale with the quality preset — `VeryHigh.ini` raises
`fLODFadeOutMultObjects`/`Actors`/`Items` from the default's 5/6/3 to 15/15/15 across the
board; `high.ini` uses 7.5/6.0/4.5. The `fLODBoundRadiusMult`/`fLODFadeOutMult*`/
`fLodDistance` combination strongly implies (from the ini's own structure — the naming
and presence of a "bound radius mult" specifically) that real fade-out distance is
**size-proportional**, not a single flat number: something in the shape of
`fade_distance ≈ object_bounding_radius × category_multiplier × fLODBoundRadiusMult`.
This exact formula is inferred from the data's own shape, not confirmed against engine
source or byte-level verified — flagged as inferred, not established, unlike the other
findings in this doc.

## "Visible When Distant" (VWD) is a real per-`REFR` flag, and it's the actual gate

Bit `0x00008000` in a `REFR` record's own 32-bit header flags field. Confirmed directly
against real `WastelandNV` data (bypassing this project's own `ReferencePlacement`
GDScript binding, which doesn't currently expose record flags at all — checked via
`EsmFile::find_record_by_form_id()` directly) — and it produced a real, non-obvious
result:

| Object | Has a `_lod.nif` companion? | VWD flag actually set? |
|---|---|---|
| `Barracks01`/`Barracks02` (3 placements checked) | yes | **yes**, all 3 |
| `NVNellisQuonsetHut01`/`02` (4 placements checked) | yes | **no**, all 4 |
| `CraneStatic01` (2 placements checked) | yes | **no**, both |

So **having a `_lod.nif` file available for a model does not mean every placement of it
renders at distance** — VWD is set (or not) per individual `REFR` placement, independent
of whether the base model has LOD geometry available at all. Two placements of the exact
same base object could in principle disagree (not observed in this sample, but nothing
in the data model prevents it — VWD is stored per-`REFR`, not per base record).

## Bethesda's own artist-only visualization submeshes ("EditorMarker")

Not LOD-specific, but found while investigating LOD-adjacent effect meshes, and belongs
in the same "undocumented engine convention, confirmed by direct inspection" category:
many NIFs — confirmed across `FXDustMeshSky01`, `FXAmbDust02`, `FXFireSmall01`,
`FXRadiationDust1x1`, `FXDustWhirlWind01`, `fxvulturesNV`, and others, all sharing the
same convention — carry a submesh literally named `EditorMarker` (sometimes suffixed
`:0` in NifSkope/3ds Max style), with real triangle geometry, alpha-blended and unlit,
but no assigned texture. Some of these effect NIFs have **no other geometry at all** —
`EditorMarker` is the *only* submesh, meaning their real visible effect is presumably a
particle system this project's NIF parser doesn't currently extract as a submesh at all.
This is a CK-wide authoring convention (an artist-visible gizmo for placing/orienting an
effect in the editor), not specific to one file, and the real engine does not render it
in actual gameplay.

## Exterior cell spatial index (Block/Sub-Block GRUPs)

Documented in depth in `phases/2/11-exterior-cell-lookup-index.md` (that doc is the
canonical source — this is a pointer, not a duplicate): `WRLD` records' exterior cells
are organized into `GRUP` type 4 ("Exterior Cell Block", 32×32 cells) containing `GRUP`
type 5 ("Exterior Cell Sub-Block", 8×8 cells), each holding the actual `CELL` records.
Both levels' `GRUP` label field packs a signed `int16` pair — low 16 bits = the block/
sub-block's own `Y` coordinate, high 16 bits = `X` (confirmed by direct crosscheck
against real cell data across multiple blocks, including negative coordinates — not
simply trusted from a paraphrased "note the reverse order" description). A worldspace's
own persistent cell sits structurally first under the `WRLD`'s "World Children" `GRUP`,
before any Block/Sub-Block `GRUP`, and can carry its own placeholder `XCLC` grid
coordinate (`(0,0)` observed in `WastelandNV`) that collides with a genuine grid tile
also at that coordinate — a real ambiguity in the data itself, not a parsing bug.
