# NpcSimulationServer

`nav_npc_simulation_server.gd`, autoloaded as `NpcSimulationServer`, indexes every
authored placed actor and every XTEL door, grounds each actor against real NAVM
triangles, and routes between them.

- **Lifecycle** — nothing loads until `seed()` is called; `game.gd` calls it at
  boot. `seed_finished` fires when the navmesh, actors and portals are ready.
  Tests may instantiate the script directly and seed their own instance.
- **Local navigation** — `local_navigation` (`local_navigation.gd`, the
  `LocalNavigation` child node) holds Godot NavigationServer3D maps for the cells the streamers have loaded, for
  physicalised actors' local pathing; see "Local navigation" below.
- **Index** — `actors_by_space_form_id` / `actors_by_cell_form_id` and grounding
  follow `EsmServer.reference_cell_changed`, so an actor that moves or walks into
  another CELL is re-indexed and re-grounded.

- **Positions** — authored REFR/ACHR vectors plus a navmesh snap
- **Routing** — A* over triangles, funnelled, async, cross-space, component-aware
- **Dependencies** — `EsmServer` + `NavmeshReader` (native)
- **Disabled actors** — nothing here moves actors yet. A disabled actor
  (`EsmReference.is_disabled()`) is frozen: no AI packages, combat or schedules,
  and no travel while virtual. Script moves (`MoveTo`) still move it.

An earlier prototype (`npc_simulation_server.gd`) indexed actors by raw authored
position with no ground truth and no routing. It was deleted once this superseded
it; `npc_portal.gd` is the only piece that outlived it, and is still used here.

The navmesh layer exists because an authored position is not enough to decide
**where an actor would actually stand**. A raw point carries no guarantee of
being standable, so physicalizing an actor from one can put them inside a
mountain or on the wrong bank of a river.

## What the navmesh layer is built on

Backed by `NavmeshReader` (`native/src/nav/`), which loads every `NAVM` record in
every shipped master once, then serves read-only queries.

Measured on real data (base game + all five DLC masters):

- **6,139 records, 621,256 vertices, 826,632 triangles, 31.2 MB resident** by
  the database's own count (`resident_bytes`); **42.6 MB** of heap is still
  allocated after `load()` returns (`native/tools/navmesh_memory.cpp`, glibc
  `mallinfo2`), the difference being container overhead. Loading briefly takes
  far more: `EsmFile`'s whole-plugin record index, freed afterwards.
- **~0.36 s to load**, against a 5 s boot budget. Dominated by opening the
  plugin files (~0.16 s) and the derived cross-record stitch (~0.11 s); the
  actual NAVM parse is ~0.03 s.
- 481 distinct spaces; the exterior Mojave is one space holding 4,041 records.

Loading the whole game's navmesh up front is therefore cheap enough that
downsampling or an LRU cache would buy nothing. That was the original reason the
idea got shelved and the measurement does not support it.

## Confidence levels — read before extending this

The ESM's navmesh format is only partly documented. xEdit's FNV schema names the
subrecords but routes the two fields that matter through callbacks
(`wbNVTREdgeToStr`, `wbNavmeshEdgeLinkEnum`) whose bodies are not in the copy
vendored under `enginedocs/xEdit/`. Everything below was settled by exhaustive
census over the whole shipped population, not a sample. The tools are committed
under `native/tools/` so any claim here can be re-run.

**Authored and confirmed:**

- *Within-record triangle adjacency.* `NVTR` edge fields are `-1` for "no
  neighbour in this record", otherwise an in-record triangle index. No other
  encoding exists: of 2,479,896 edge slots, 13.260% are `-1`, 86.737% are in
  `[0, triangle_count)`, and **zero** are any other negative value.
  (`navm_edge_encoding_census.cpp`)
- *Record-level connectivity.* `NVEX` target FormIDs always resolve to a real
  NAVM record (0 unresolved), and connectivity is 99.07% reciprocal (15,794 of
  15,942 directed pairs have a matching reverse count).
  (`navm_nvex_semantics_census.cpp`)
- *`NVEX` "Triangle" indexes the **target** record*, not the local one: in range
  for the target in 99.882% of links, but for the owning record in only 78.932%.
- *`NVGD` bounds exist on 6,139/6,139 records* — an exhaustive result, so the
  coarse broad-phase has no fallback path.
- *Coordinate space.* Exterior NAVM vertices are worldspace-absolute
  (4,258/4,260 consistent), in raw Gamebryo units. `navmesh_database.cpp`
  converts them to meters at the point of reading, per `common/units.h` — do not
  add a second conversion downstream. This was an actual bug during the build:
  without it, actors in Hoover Dam Power Plant sat 12 m from a navmesh whose raw
  z-range was 10368..11652 (= 148..166 m).

**Derived, not authored — this is the one approximation:**

- *Where two records connect.* `NVEX` says *which* records connect but never
  names the local triangle a link leaves from. Geometric seam matching was tried
  as an alternative and **ruled out**: only 2.10% of boundary edges in
  NVEX-linked records share vertex positions with a linked record
  (`navm_stitch_census.cpp`), so seams do not have coincident vertices.
  `NavmeshDatabase::build_cross_record_links()` therefore pairs each authored
  target triangle with whichever triangle of the linking record is geometrically
  nearest. Routes are exact within a record and approximate at record seams.

**Not established — do not build on these without new evidence:**

- What `NVEX` "Type" means. Values are 95.50% `0`, 2.24% `1`, 2.24% `2`, 0.02%
  `3`. The near-identical counts for 1 and 2 suggest a directional pair, but
  that is a guess and nothing reads the field.
- Whether the named target triangle is a precise seam pairing. It is probably
  not — only 10.631% of named target triangles even have a boundary edge, so
  they are generally interior triangles.

**Known bad data, handled:** 82 of 2,479,896 `NVTR` edge slots hold exactly
`triangle_count` — out of range by one. They are clamped to `-1` at load. This
is not cosmetic: indexing on them reads past the triangle array. The test asserts
the count is exactly 82 so a parser change that silently swallows more is caught.

## Path quality

A* returns a corridor of triangles. Emitting one waypoint per triangle centroid
produces two visible artifacts: a zigzag ("vibration") where triangles are small
and dense, and needlessly long straights where they are large. Two passes fix it:

1. **Funnel** (`build_waypoints`) — Simple Stupid Funnel Algorithm, the shortest
   line inside the corridor. Run **per record**, because it needs consecutive
   triangles to share an edge; that holds inside a record via authored NVTR
   adjacency but not across one, since seam vertices are not coincident.
2. **Line-of-sight simplification** (`simplify_by_line_of_sight`) — drops a
   waypoint only when the shortcut past it is *sampled and verified* to stay on
   real navmesh. This straightens across record seams, which the per-record
   funnel cannot do alone, without ever inventing a line over a gap.

Measured on one real 224-triangle Mojave route:

| | waypoints | mean turn | reversals (>90°) | length |
|---|---|---|---|---|
| centroids only | 224 | — | — | 1737 m |
| + funnel | 97 | 43.7° | 8 / 95 | 1649 m |
| + line-of-sight | 48 | 30.5° | 0 / 46 | 1611 m |
| + height projection | 537 | **5.2°** | 2 / 533 | 1602 m |

(straight-line distance is 1464 m.) Waypoint count rises again at the last step
because that pass *inserts* terrain-following points; the count is not the
metric, smoothness and surface adherence are.

3. **Height projection** (`project_onto_navmesh`) — re-seats the path's height on
   the real surface. Smoothing interpolates height linearly between waypoints,
   which floats the path off uneven ground. That is not cosmetic: **navmesh
   overlaps vertically** (multi-storey interiors, catwalks, the Dam), so a path
   floating off its own floor can snap an actor onto the wrong one.

   This pass is **insert-only** — it never moves or drops a funnel waypoint. That
   restriction was learned the hard way: two earlier versions also resampled and
   re-simplified, and each pushed waypoints *off* the mesh (6.7%, then 11.9%),
   because moving or dropping a point can cut a corner out of the corridor the
   funnel guaranteed. The funnel's own output measures 0.00% off-mesh; anything
   that reshapes it has to earn that back.

   Inserted points keep the segment's XY (still inside the corridor) and take
   their height from the surface beneath, queried from the height already being
   walked so overlapping floors stay distinguished. Two guards matter: a sample
   whose nearest surface is more than 0.5 m away *horizontally* is rejected
   (`snap` returns the closest point on a triangle, so a probe over a hole still
   "finds" mesh at the hole's rim), and a sample with no surface near the walked
   height is simply not inserted rather than fabricated.

Surface adherence, sampled every 0.5 m along real routes:

| | >2 m off surface | within 1 m | waypoints off-mesh |
|---|---|---|---|
| before projection | 11.8% | 76.1% | 8.5% |
| after | **4.7%** | **91.7%** | **0.00%** |

In spaces with genuinely stacked navmesh — the case that motivates this — it is
**0.19% beyond 2 m, worst 2.05 m**, which is less than a storey, so wrong-floor
spawns are effectively eliminated.

**Remaining limitation:** every *waypoint* is on the navmesh, but the
interpolated stretches between them can still float where the straight segment
spans ground the projection could not sample (4.7% of sampled points). Consumers
that need an exact position mid-segment should snap; consumers that spawn an
actor already do.

## Routing is keyed on walkable REGIONS, not spaces

**A space is not one connected walkable area.** Measured: the exterior worldspace
alone splits into **181 disconnected components** holding 2.42% of its triangles
(14,246), and 81 spaces are non-contiguous. Across all masters there are 926
components.

This was a real bug, found by watching the viewer. NCR Correctional Facility sits
in the exterior worldspace but inside a fence, and its yard connects to the rest
of the Mojave only through a building. Space-keyed routing saw "same space" and
concluded no doors were needed, found no walkable path, and fell back to a
straight line **clipping through the fence**. Every trip in or out of NCRCF drew
as an unwalkable red leg.

`NavmeshDatabase::build_components()` runs a union-find over every triangle at
load, joined by authored in-record adjacency and the derived cross-record links.
`SnapResult.component` then tells any caller which walkable region a point is in,
and portals are indexed by the components on each side of the door -- a door
being the only thing that joins two components.

`find_component_paths()` is the search that matters. Unlike the space-level
version it can return a *non-empty* path when both ends are in the same space,
which is exactly the NCRCF case: out through a building and back into the open.
It tests the goal before its cycle check, so a path that leaves a region and
returns to its neighbour stays reachable.

Verified on real data: of the exterior's enclosed actor-bearing regions, **14 are
reachable via doors and all 14 now produce a fully walkable route** (1-4 doors,
2-5 legs, 1.1-2.1 km). A further 14 have no door route at all -- rooftops, ledges
and similar with no authored way in or out; those correctly report no path rather
than inventing one.

`find_portal_paths()` (space-level) is kept as a fallback for when either end is
off navmesh, and offers several candidate door sequences shortest-first;
`route_across_spaces` keeps the first that routes end to end. That matters: the
fewest-doors sequence is often *not* walkable, because two doors can sit in
disconnected parts of one space. Picking the first candidate blindly produced
routes with an unwalkable middle leg.

**All XTEL transitions are treated as zero cost.** The search minimises door
count, not distance. There is no authored traversal cost on an XTEL to weigh
against metres walked, so any distance-based comparison across a door would be
inventing one.

A leg that cannot be routed is still returned, flagged `has_navmesh: false` with
a straight from/to pair, and the whole route reports `walkable: false`. That is
deliberate — it shows exactly where the path stops being real instead of handing
back a confident route with a fabricated middle.

## NAVM centers are an optimiser, never connectivity

`use_coarse_index` toggles the authored-`NVGD`-bounds broad-phase. It changes
query cost and never the answer — measured at **66 µs vs 8,483 µs** for the same
snap, returning the identical triangle, and the test asserts both paths agree
across sampled records.

The rule that must not be broken: **proximity is not connectivity.** Two records
whose bounds are adjacent are not connected unless `NVEX` says so. If anything
ever falls back to "no graph edge found, connect to the nearest center anyway",
routes start crossing rivers. Centers are only ever a broad-phase filter and an
A* distance heuristic. A record's center is not even guaranteed walkable — a
record can be concave or hollow, putting its midpoint off-mesh.

## Local navigation

`LocalNavigation` copies the NAVM of the **local** cells into Godot's
NavigationServer3D: one map per space, a `NavigationRegion3D` per NAVM record
(`NAVM_<form id>`) and the seam links below, grouped under a `Space_<form id>`
node per space. Being nodes, they
show in the remote scene tree and under Debug > Visible Navigation. Physicalised actors path and avoid each
other on these maps; NSS keeps routing every actor over the whole game's NAVM,
including through doors.

- **Which cells are local** is the streamers' decision, given as a whole set per
  space with `set_local_cells(space, cells)`. `CellStreamerV2` makes the current
  interior local; `WorldStreamerV2` its resident full-detail tiles, none while
  paused, synced at the end of a frame in which a tile's scripts load or unload.
- **Builds** — a cell's NavigationMeshes are built on a `WorkerThreadPool` task
  and its nodes added on the main thread; `cell_ready` follows. A cell made non-local
  before its build lands is never applied.
- **Seams** — Godot's edge connections at a 0.5 m margin join the record seams
  within it (82% of NVEX-joined pairs, and 616 pairs NVEX does not record, 427
  of them coincident); a `NavigationLink3D` named `Seam_...` joins each
  NVEX-joined pair 0.5-4 m apart (76), between the two closest
  points on their open edges (`NavmeshReader.get_record_seam_links`). See
  `native/tools/navm_seam_gap_census.cpp` and `_diag/diag_local_seams`. Edge
  connections stall only on a whole worldspace (on WastelandNV the free-edge
  search had not finished after a minute), which local maps never hold.
- **Cell size 0.1 m** — at Godot's 0.25 m default, distinct vertices in
  GSDocMitchellHouse share a cell and the map reports an edge error.
- **Why not the whole worldspace in Godot** — measured on WastelandNV
  (`_diag/diag_navserver_bench`): about 767 MB for Godot's map against NSS's
  42.6 MB for every space; routes of about 2 km reach 91/100 in 84 ms mean
  (NSS: 90/100, 91 ms), with Godot's `path_search_max_polygons` lifted from its
  4,096 default, which otherwise ends every such route short.

## Packages and low-level travel (first slice)

Two more child nodes run every physics frame on the main thread, for the actors
given a package through `PackageRunner.set_package()` (the script functions
`AddScriptPackage` / `RemoveScriptPackage`); package selection from a base's
`packages` is not implemented yet.

- **`PackageRunner`** (`package_runner.gd`) runs each such actor's
  `active_package` and decides where it goes (`ActorReference.move_target`).
  FOLLOW only: within PTDT Count / Distance (Gamebryo units) of Target 1 (a
  specific reference, 0x14 the player, or the actor's XLKR linked reference)
  it clears the target, else sends the actor to the target, again once the
  target has moved 1 m. When the target is in another space it walks to the
  first load door of `route_across_spaces` and activates it through
  `ScriptServer.activate`, which moves it to the door's destination; the
  streamers physicalise it there if that space is loaded. Locked doors are not
  handled.
- **`LowLevelTravel`** (`low_level_travel.gd`) moves those actors while
  `LOW_LEVEL`: a route from `request_route` to `move_target`, walked at the
  NpcController's walk speed times SpeedMult, writing `position` and the
  heading, then `reach_move_target()`. Routes are derived and never saved.
- **The lease follows physical presence.** An `NpcController` holds its
  actor's lease while it is in the tree and the actor's space has local
  navigation; a streamer paused for an interior visit clears its local cells,
  so its controllers hand their actors to `LowLevelTravel`, and take them back
  (placed where the reference has got to) when it resumes.

This is the start of the tick planned below, on the main thread for the few
actors that run a package; the worker-thread travel and round-robin sweep are
still to come.

## Planned: the simulation tick

None of this section is implemented. It is the agreed design for when NSS starts
ticking actors, recorded so the ownership rules are settled before package
evaluation and ScriptServer dispatch land.

### What an NPC is

An NPC is a Resource, not a node. Data lives in three places:

- **`ActorReference`** — per-instance, one per authored ACHR, cached by
  `instance_id`. Authored placement (`position`, `rotation`, `current_cell_form_id`),
  plus `spawn_cell_form_id`, `current_space_form_id`, `simulation_mode`,
  `active_package`, `health`, `alive`, `contents`, and the ACHR extras.
- **`NpcBase`** — shared between every actor using that base record. Race, hair,
  eyes, class, body-part data, `packages: Array[PackageBase]`, flags.
- **NSS-side tables keyed by `instance_id`** — the three indices plus
  `grounding_by_instance_id` (`position`, `distance`, `navmesh_form_id`,
  `global_triangle`, `component`).

### Persistent vs derived

The split is by lifetime, not by storage location:

- **Persistent → on `ActorReference`**, must survive save/load: position, health,
  alive, inventory, active package, package progress.
- **Derived → never on the Resource**, recomputable: current path waypoints,
  waypoint index, in-flight route request id, snap caches. A ~500-waypoint array
  per actor across 3,386 actors is pure save-file liability when a repath
  regenerates it in ~10 ms.

### Who owns which field

The lease (`simulation_mode`) is **field-scoped, not actor-scoped**. NSS never
stops processing a leased actor — it processes it more often. What it stops is
integrating travel.

| | NSS writes | leased actor writes |
|---|---|---|
| `active_package`, current target | always | never |
| `position` | only while unleased | while leased |

A leased actor *executes* the package it is given — walks to the supplied
target, fights, eats. It never selects one. Package and target selection is
always NSS's job.

The lease follows physical presence: an `NpcController` sets its reference
`PHYSICAL_LEASED` while it is in the tree and the reference's space has local
navigation, and on leaving the tree, or when its streamer pauses, writes its
final position and heading and sets it back to `LOW_LEVEL`. There is no
`checkout()` / `checkin()`: the field alone hands the actor over.

The player is an actor like any other, holding a normal `ActorReference` that is
permanently leased; its position is written per frame by its physical controller.

### Tick rates

- **Unleased** — round-robin sweep, budgeted. One actor per frame is enough:
  3,386 actors at 60 Hz is a 56 s sweep.
- **Leased** — at least 1 Hz. Bounded by physicalization radius (tens of actors),
  so the cost is nil.

Parametrise as a **sweep period**, not a fixed count per frame:
`per_frame = ceil(actors.size() / (sweep_seconds * fps))`. A fixed count silently
turns into a longer sweep as population grows, and once the sweep exceeds the
schedule tolerance it starts dropping package changes outright.

Sweep period is governed by schedule tolerance, not by position staleness.
`ActorReference.position` is the canonical *last-tick* position, deliberately not
live: the tick fetches the current travel position from the simulation and writes
it. That is fine because proximity is **pushed** — NSS computes distance directly
in the threaded simulation, where positions are live, and emits warnings to the
streamers. Nothing polls the Resource for spatial queries. Distance events need
hysteresis (enter at R, exit at R+margin) or they flap when an actor loiters on
the boundary; `WorldStreamer` already does this and is the pattern to copy.

### Schedule re-evaluation

Packages are time-gated, so a clock-driven path is required — it cannot be purely
event-driven off actor state.

Censused over all 4,163 PACK records in `FalloutNV.esm` (100% carry PSDT, zero
malformed):

- Every non-"any" start time is a **whole hour, 0–23**. 25 distinct values, no
  sub-hour granularity exists in the format.
- Durations are whole hours too; 2,521 of 4,163 are `0`.
- Only **32.4%** (1,350) are time-gated at all — the rest are `time == -1`.
- **Zero** month-constrained; **53** day-of-week constrained.

Timescale is 30, so one game hour is **two real minutes**. A round-robin sweep
well under that is all the precision the data can express.

An hour-bucketed wake queue was considered and **rejected**: it is a pure cost
optimisation with no correctness benefit, and it introduces invalidation bugs
that do not otherwise exist (an actor leased across an hour boundary never fires
its bucket, so re-bucketing on the lease's release silently skips a package
change). The
round-robin sweep has none of that and costs nothing.

### Threading boundary

- Route computation and travel integration: worker thread. Safe because
  `NavmeshReader` is immutable after load and every query is const.
- The tick itself: **main thread**. It writes Resources and will call into
  ScriptServer. "Package evaluation is slow, let's thread it" is a tempting and
  quietly unsafe future optimisation — Godot Resources are not thread-safe.
- NSS reads actor refs **deferred**, so there is no cross-thread liveness
  requirement and no tearing window to close.

Writer sets are disjoint and reads are deferred, so no locking is needed
anywhere. That property is worth asserting in tests rather than only documenting:
leased ⇒ NSS never writes `position`; unleased ⇒ the controller never writes it.

The lease flip needs no handshake. The tick, on the main thread, is the only
writer of travel results, and so is the controller and the physicaliser that
flips the field. The tick checks `simulation_mode` before writing `position` and
drops a worker result whose actor is leased, or whose `position` no longer equals
the position the job started from (a `MoveTo`, a door or the controller moved it
meanwhile); travel then restarts from the new position to the same target. An
actor coming back `LOW_LEVEL` is re-grounded from its reference.

### Still unbuilt

`active_package` is declared and every `PackageBase` field is parsed, including
the `POBA`/`POEA`/`POCA` begin/end/change blocks that ScriptServer will dispatch.
Nothing reads any of it. An NPC currently knows where it is and where it could
stand, and nothing about what it is doing.

## Threading as built

(For the rules the future tick must respect, see "Threading boundary" above.)

`NavmeshReader` holds no file handle once loaded and all its queries are
read-only, so **one instance serves any number of threads**. This is deliberately
unlike `EsmReader`/`BsaReader`, which each own a `FILE*` and need one instance
per worker.

`request_route()` runs on `WorkerThreadPool` and returns a request id; the result
arrives on the `route_ready` signal. Low-level simulation is never blocked on a
route — it is computed once and the actor keeps moving on its previous one.

Measured with the viewer's `P` stress test, 100 simultaneous same-space routes in
the exterior: **100 completed in ~1.8–2.0 s wall, worst main-thread frame 7.78 ms
against a 7.17 ms idle baseline.** No perceptible hitch; the work is genuinely
off-thread. Per-route cost is p50 2.3 ms (short) to 21.8 ms (long), with a ~280 ms
tail on routes that explore a large share of the graph before failing.

No queue, priority or cancellation exists, and none is planned: an offscreen actor
can afford to think for a long time, so route latency is not a cost. The one thing
to stay aware of is that nav shares `WorkerThreadPool` with `GamebryoResolverPool`
(NIF/texture resolve), so a large nav burst queues behind or ahead of asset
streaming for the same crowd.

## Grounding results

Across all 3,386 placed actors: 3,289 ground onto real navmesh (2,938 within
0.25 m, 329 within 2 m, 22 further), 97 do not. Those 97 are a real outcome, not
a bug — not every cell is navmeshed, and some authored placements genuinely sit
off-mesh. "Grounded" here means on navmesh: the tick cannot route or move them
while unleased. Physicalised, one stands on whatever collision is under it (the
controller's ground ray); it still cannot be routed anywhere without navmesh.

## Tests

```bash
cd project
../tools/Godot_v4.7.1-stable_linux.x86_64 --headless --path . tests/test_nav_npc_simulation_server.tscn
../tools/Godot_v4.7.1-stable_linux.x86_64 --headless --path . tests/test_local_navigation.tscn
```

Requires a current `project/bin/*.so`. A stale one does not fail loudly — the
`NavmeshReader` class is simply absent and the navmesh silently never loads, so
the test checks `ClassDB.class_exists("NavmeshReader")` first and says so.
