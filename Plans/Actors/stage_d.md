# Stage D: NpcController (draft for review)

A controller for physicalised NPCs and creatures, cheaper than `PlayerController`, built as a
template scene to open and tweak like the actor template. Gate: an NPC walks a route across
GSDocMitchellHouse, and the player and the NPC animate from their controllers.

## Facts

- `PlayerController` is a `CharacterBody3D` (capsule, `move_and_slide`, step and hover logic,
  camera) with an `EsmActorNode` child (`player.tscn`). It already computes a `MotionData`
  (actor-local velocity, grounded, crouched, sprinting) every physics frame and hands it to an
  `ActorAnimationComponent` child of the actor. That component is legacy (`gamebryo/`); the new
  actor node has none, so today the player's motion drives no animation.
- `NpcSimulationServer.request_route(space, from, to)` returns a request id; the result arrives on
  `route_ready` with `found` and `waypoints` (a `PackedVector3Array` on the navmesh).
  `route_across_spaces` adds legs through doors.
- `ActorAnimator` loads Doc's 121 locomotion clips from `meshes/characters/_male/locomotion/`.
  Idle and the unarmed turns sit at its top (`mtidle`, `mtturnleft`, `mtturnright`); the unarmed
  movement clips are per body type in `male/`, `female/` and `child/` (`mtforward`,
  `mtbackward`, `mtleft`, `mtright`, and `mtfast*` for running); crippled-leg clips are in
  `hurt/` (`*_hurt`); the weapon-stance sets (`1gt`, `1hm`, `1hp`, `2ha`, `2hh`, `2hl`, `2hm`,
  `2hr`, `h2h`) are at the top. `ActorAnimator.locomotion_clip()` chooses among the unarmed
  clips from `ActorMotion`; child bodies, crippled legs and weapon stances are not chosen yet.
- `NpcSimulationServer` is built for off-screen simulation: it routes over the authored NAVM and
  knows nothing of what is physically in the loaded world (other actors, the player, objects in the
  way, things to flee from).
- `NavmeshReader` exposes each NAVM record's triangles (`get_record_triangle_points`) and a
  space's geometry, in metres. A NAVM record is already a triangle mesh, so it can become a Godot
  `NavigationMesh` directly, without baking.
- NAVM records do not share vertices at their seams: only 2.10% of boundary edges in NVEX-linked
  records coincide (`navm_stitch_census.cpp`), which is why the server pairs seam triangles by
  nearest geometry. Interior cells such as GSDocMitchellHouse are usually one record.
- Trigger volumes (`EsmPrimitiveVolume`, an `Area3D`) fire OnTrigger for physics bodies inside
  them. VCG01's chair trigger fires `OnTrigger DocMitchellREF`, so Doc has to be something the
  volume detects.

## Proposed shape

`npc_controller.tscn`, root `NpcController` (`Node3D`):

```
NpcController (Node3D, npc_controller.gd)     exports: walk_speed, run_speed, turn_speed_degrees,
├── EsmActorNode (instance of esm_actor_node.tscn)      arrive_radius, ground_snap_distance
├── NavigationAgent3D                        ← local path and avoidance (radius, max speed, ...)
├── Body (see question 1)                    ← what triggers and the player collide with
└── GroundRay (RayCast3D)                    ← snaps height while walking
```

- **Our router decides the path; Godot follows it.** `NpcSimulationServer` computes every route,
  as it already must for packages, flee, follow and combat targets. For a physicalised actor it
  hands the controller the route's waypoints, each annotated with the door it crosses, if any.
  The controller paths with its `NavigationAgent3D` only to the next waypoint: funnelled
  waypoints see each other along the corridor, so each hop is short and near-straight and the
  local path cannot stray through another door. Godot adds avoidance between agents (NPCs and the
  player) and keeps the agent on walkable ground when pushed. Off screen, the server alone moves
  the actor, as now. The waypoints are derived data (README: never on the Resource) and go from
  the server to the controller directly.
- **Doors and obstacles are blocked in our router.** The original engine cuts the navmesh at
  runtime around doors and objects flagged as obstacles (GECK navmesh tutorial: "Doors, like
  objects with the 'obstacle' tag, automatically cut the navmesh in game"); NAVM itself marks
  only load doors (NVDP, measured: every resolved NVDP door has XTEL). `NavmeshDatabase`
  CSG-splits the NAVM under each internal door and obstacle reference's footprint (the base's
  OBND placed by the reference; record-header bit 25 `0x02000000` "Obstacle" on ACTI, CONT,
  SCOL, MSTT, LIGH and STAT; every DOOR) and tags the pieces inside it with the reference.
  `find_route` skips the pieces of references blocked for the query: obstacles for everyone, a
  door for an actor that cannot pass it (locked without the key, or above its lockpicking).
  Deferred until after stage D's gate; specified in full under "Deferred: the door and obstacle
  cut".
- **Doors along a route.** The controller opens the door a waypoint names on reaching it and
  waits for it to open. A door whose state changes under a route (locked, unlocked) makes
  NpcSimulationServer route again.
- **Local navmesh from NAVM.** The NAVM records of the lod0 tiles (or the current interior) are
  `NavigationRegion3D` / `NavigationLink3D` nodes under `NpcSimulationServer/LocalNavigation`,
  unblocked: no door regions or navigation layers. Done for interiors (`CellStreamerV2`).
- **Movement is kinematic.** The controller moves at walk or run speed along the agent's next path
  position toward the current waypoint (with the agent's avoidance velocity), turns toward it at
  `turn_speed_degrees`, and keeps to the ground with `GroundRay`. No `move_and_slide`: the
  navmesh says where an actor can walk.
- **State stays on the reference.** Every physics frame the controller writes position and heading
  to its `ActorReference`, as `PlayerController` does for the possessed actor.
- **Movement target on the reference.** `NpcSimulationServer` runs packages for every actor and
  sets where it is heading; the controller only moves. `ActorReference` gains runtime state with no
  ESM source: `move_target: Vector3` (in the actor's current space), `has_move_target: bool`, and
  signal `move_target_reached` (emitted on arrival, when the target is cleared). The server sets
  the target to the next stop on the global route: the package target, or the next door.
  Off screen (`LOW_LEVEL`) the server walks the actor there itself and emits the signal;
  physicalised (`PHYSICAL_LEASED`) the `NpcController` follows the server's waypoints there and
  reports arrival.
  Either way the server then advances the package step. A save mid-walk keeps the target, and a
  hand-off between the two modes carries on to the same point. Stage D sets targets from a test,
  not from packages.
- **Motion to animation, shared with the player.** A `MotionData`-like state (actor-local velocity,
  grounded, running) goes to the actor node's `ActorAnimator.set_motion()`, which picks the
  `mt*` clip for direction and speed (and turns in place). `PlayerController` calls the same
  method in place of the legacy `ActorAnimationComponent`.
- **Spawning.** The physicaliser instances `npc_controller.tscn` for an `ActorReference` (the
  controller owns its `EsmActorNode`), except for the possessed actor, which the player's body
  stands in for.
- **Lease hand-off by field.** The lease rules are in the NpcSimulationServer README ("Who owns
  which field"): leased, the controller writes `position` and NSS never does; unleased, the
  reverse; NSS always owns the package and `move_target`, and keeps ticking a leased actor. The
  physicaliser sets `simulation_mode` directly: `PHYSICAL_LEASED` when it builds the controller,
  `LOW_LEVEL` when it removes it, after the controller has written its final position and heading.
  The NSS tick (main thread) checks the field before writing `position`; worker threads only
  compute routes and never write Resources, so nothing races the flip. The tick keeps the mode it
  last saw per actor (derived, not saved); an actor that comes back `LOW_LEVEL` is re-grounded
  from `reference.position` and routed again to the same `move_target`.
  Stale worker results: the tick keeps the position each worker job started from and applies
  the result only if the actor is still `LOW_LEVEL` and `reference.position` still equals that
  start point. Anything else that moved the actor meanwhile (`MoveTo`, `SetPos`, a door, the
  controller's final write) wins: the result is dropped and travel restarts from the new
  position, so an in-flight result never rolls back a teleport. `checkout()` /
  `checkin()` and their grounded check are removed, and the README's "acknowledged handoff"
  paragraph is rewritten to match. An ungrounded unleased actor is one the tick cannot move yet; a
  physicalised one is always built. The possessed actor is `PHYSICAL_LEASED` while possessed.

## Decisions

- **Packages stay in the server.** `NpcSimulationServer` runs package execution for physicalised
  and off-screen actors alike; it and the controller communicate only through the reference's
  movement target (see above).

- **Split navigation.** `NpcSimulationServer` keeps the whole game's navmesh and plans every
  actor's global route, including through doors, so door state (locked, unlocked) stays its
  concern; Godot's navigation has no notion of doors. Godot's NavigationServer3D holds only the
  lod0 tiles or the current interior, for local pathing and avoidance of physicalised actors.
  Measured (`_diag/diag_navserver_bench`, `native/tools/navmesh_memory.cpp`):

  | | Heap | Routes (100, about 2 km) | 
  |---|---|---|
  | `NavmeshReader`, all six plugins (6,139 records, 826,632 triangles) | 42.6 MB | 90 found, 91 ms mean |
  | NavigationServer3D, WastelandNV only (4,037 regions, 589,723 polygons, 92,646 links) | about 767 MB | 91 reached, 84 ms mean, 3% longer |

  100 avoidance agents cost 0.09 ms per physics frame. The Godot map needs
  `map_set_use_edge_connections(false)` (its free-edge search over the unstitched seams never
  finished on WastelandNV) and is joined by the NVEX links below; a path search stops after
  `path_search_max_polygons` (default 4,096), enough for local paths.

- **Body:** an `AnimatableBody3D` capsule, moved kinematically: trigger volumes detect it and the
  player is blocked by NPCs, without per-frame sliding.
- **Speed:** from the actor's record (ACBS Speed Multiplier, `ActorBase.speed_multiplier`, through
  the SpeedMult actor value), scaled by an exported factor on the controller to tweak by eye.
- **Animation input: `ActorMotion`.** Controllers publish their motion; the actor chooses its own
  clips and controllers never name one. `ActorMotion` (`GodotBryo/Types/Node/actor_motion.gd`, a
  RefCounted, never saved) is created once by each controller and handed to its `EsmActorNode`
  once (`actor.motion`); the controller updates its fields in place every physics frame and the
  node's `ActorAnimator` reads them. Fields, all actor-local: `move_input` (Vector2, 0-1: the
  intended direction), `velocity` (Vector3, m/s), `turn_rate` (rad/s about up), `grounded`,
  `running`, `sneaking`. Not in it: weapon stance (equipment), crippled-leg `*_hurt` clips and
  health (actor values), which the animator reads from the actor. Replaces the legacy
  `MotionData` / `ActorAnimationComponent` path in `PlayerController`.
- **Seams.** Godot connects regions by touching edges; NAVM records do not touch. They are
   stitched by the ESM's connection data instead. Within a record, NVTR adjacency is exact and one
   record is one region. Across records, each NVEX link names its target record and triangle
   (resolving 100%); the source triangle is not authored, and
   `NavmeshDatabase::build_cross_record_links()` pairs it with the nearest triangle, as the
   server's A* already uses. Each pair becomes a bidirectional link
   (`NavigationServer3D.link_create`, no nodes) between the two triangles' centres, so local and
   global pathing join records in the same places. `NavmeshReader.get_space_cross_links` returns the
   pairs. Caveat: target triangles are generally interior (10.6% have a boundary edge), so a link
   can cross a little way into the next record.

## Deferred: the door and obstacle cut

Not needed for stage D's gate (Doc's walk crosses no door); done after steps 2-4. Until then
routes ignore internal doors and obstacles: a controller walks into a closed internal door.

### Facts (FalloutNV.esm unless stated; `native/tools/door_obstacle_census.cpp`,
`project/_diag/diag_nvdp_census.gd`, `project/_diag/diag_doc_house_doors.gd`)

- The original engine cuts the navmesh at runtime: "Doors, like objects with the 'obstacle' tag,
  automatically cut the navmesh in game for us so we don't need to do anything special for them"
  (GECK navmesh tutorial). Authors run the navmesh through doorways "as if the door isn't even
  there".
- **No authored link between an internal door and NAVM.** NVDP (door links) names only load
  doors: across the six masters, 1,365 links to 1,360 references; the 1,099 that EsmServer
  resolves all have XTEL (64 locked), the other 261 are DLC references (load-order byte 01) not
  in EsmServer. NVDP triangles carry NVTR flag `0x0400` (100% of them; 0.16% of all triangles).
  Triangles under internal door footprints carry no distinguishing flag: every bit is at or below
  its overall rate, `0x0040` and `0x0400` at about 0.3% (some 8 triangles each).
- **Doors.** 320 DOOR bases, none with the obstacle bit; 296 have a non-zero OBND (24 have an
  all-zero OBND). 2,758 placed: 1,108 XTEL, 1,650 internal (1,478 in interiors, 177 locked, in
  83 spaces, at most 11 in one); 106 rotated off the vertical.
- **What lies under the 1,650 internal door footprints** (OBND x/y, scaled, rotated about Z, at
  the REFR; triangles within the OBND z range plus 1 m): 153 doors are in spaces with no NAVM; 98
  have no usable OBND; 545 have no triangle under them because the navmesh does not pass the door
  (114 `BathroomStallDoor01`, 20 `UtlDoor01`, 19 `VStallDoor01`, ...: the mesh stops short, as at
  stall door `000E7285`); about 850 have triangles under them, 701 of those exactly 2; 4 have 20
  or more. Under doors with 1-4 triangles, most triangles are 0-40% inside the footprint: a door
  slab is thin (Doc's bathroom door `001062AC`, `NVCraftsmanHomeDoor`: 0.23 x 1.83 m), and the
  triangles under it reach into the rooms (one 3.4 m past the door).
- The navmesh tends to have an edge along a doorway (Doc's: x 23.43, y 10.99-12.74, 0.24 m from
  the slab at x 23.67-23.90), but it can lie outside the door's bounds or be several edges, so
  it is not used as the cut.
- **Obstacles.** Record-header bit 25 (`0x02000000`, xEdit "Obstacle") on 361 bases: ACTI 11,
  CONT 19, MSTT 20, SCOL 7, STAT 304 (LIGH allows it; none set). Placed: STAT 59,473 (37,500
  rotated off the vertical, 46,605 scaled), MSTT 292 (176 off vertical), SCOL 108 (35), ACTI 36
  (8), CONT 16 (0). 13 STAT and 3 CONT obstacle bases have no usable OBND. Mostly exterior
  scenery (rocks); off-vertical placements make the footprint the ground projection of a rotated
  box (up to 8 corners: a convex hull), not a rectangle.

### What to build

1. **Footprints (native).** For each placed internal door (DOOR without XTEL) and each placed
   obstacle-flagged reference with a usable OBND: the OBND box scaled by XSCL, rotated by the
   REFR rotation (the basis EsmReferencePhysicaliser uses), projected to the ground as a convex
   polygon (rectangle for a vertical door; convex hull otherwise), with the box's z range. Read
   from the ESM at seed; doors and statics do not move (a scripted `MoveTo` on a door is not
   handled).
2. **CSG split in `NavmeshDatabase`, once at load.** For each footprint, every triangle of its
   space within its z range and overlapping it is replaced by convex pieces: the inside piece
   (Sutherland-Hodgman against the footprint) and the outside remainder split along each
   footprint edge line in turn; every piece is triangulated (fan). Heights come from the
   original triangle's plane. Where a footprint edge crosses a shared triangle edge, both
   triangles are cut, so the cut point must be computed from that edge's endpoints in a fixed
   order (lower vertex index first) to give both sides bit-identical vertices. NVTR adjacency
   for the affected triangles is rebuilt among the pieces and their uncut neighbours; global
   triangle numbering, components, cross-record links and NVDP triangle indices are remapped.
   Inside pieces are tagged with the reference's FormID.
3. **Door passability: `NpcSimulationServer.can_pass_door(actor: ActorReference, door:
   DoorReference) -> bool`.** The one place that decides whether an actor may route through a
   door; everything that builds a route's blocked set calls it. True when any holds:
   - the door is not locked (`DoorReference.is_locked`);
   - the actor's inventory (`ActorReference.contents`) holds the door's key
     (`lock_key_form_id` / `lock_key`, read from XLOC);
   - the actor owns the door, or is in its owning faction at or above the required rank
     (REFR XOWN / XRNK: **not read on any reference yet**; DoorReference needs both fields, per
     the field-description rule);
   - the actor's Lockpick skill meets the lock level (XLOC level, read as `lock_level`).
     **Unverified:** whether NPCs pick locks in the original game at all, and how a lock level
     maps to a required skill (GECK lock levels Very Easy to Very Hard, plus "requires key" in
     `lock_flags`); check both before enabling this clause.
   Obstacles have no passability: always blocked.
4. **Blocking in `find_route`.** A per-query set of blocked reference FormIDs: every obstacle,
   and each door in the route's spaces for which `can_pass_door` is false. A* skips triangles tagged
   with a blocked FormID. `route_across_spaces` passes the same set. Route results annotate the
   waypoint where a route crosses an unblocked door's pieces with that door, for the controller
   to open it.
5. **Door state changes.** A door locked or unlocked while routes cross it, or an actor gaining
   or losing a key, makes NpcSimulationServer route the affected actors again.
6. **Godot's copy stays uncut.** `LocalNavigation` keeps building from the original triangles;
   blocking is never Godot's.

### Tests

- `can_pass_door`: unlocked door true; locked door false for an actor without the key and true
  once the key is in its inventory; owner and faction clauses once XOWN / XRNK are read.
- With Doc's bathroom door `001062AC` blocked, no route crosses from one side of it to the
  other; unblocked, the route crosses and names the door at the crossing waypoint.
- Every cut shared edge has identical vertices on both sides (no T-junctions): the rebuilt
  adjacency is symmetric across all cut triangles.
- Triangle area is conserved: the pieces of each cut triangle sum to its area.
- Census numbers above re-run unchanged.

### Open

- Whether a slab always spans the navmesh doorway. Doc's does (slab y 10.97-12.80, doorway
  10.99-12.74); if one falls short a route slips around its end. Widening footprints along the
  door's width is the fallback, tuned against the blocked-door test over every door with
  triangles under it.
- Obstacle footprints: OBND is a box; a rock's real footprint is smaller. Whether that cuts
  walkable ground the game keeps needs a comparison in play.
- DLC: the 261 unresolved NVDP references and DLC obstacles wait on EsmServer loading the DLC
  masters; `NavmeshReader` keeps each DLC's file-local `01xxxxxx` FormIDs, which can collide
  between DLCs.

## Open

- Nothing yet beyond the deferred cut's own open questions.
