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
- `ActorAnimator` loads 125 male locomotion KFs: `mt*` (unarmed: idle, forward, backward, left,
  right, fast*, turnleft / turnright, *_hurt) and the weapon-stance sets (`1gt`, `1hm`, `1hp`,
  `2ha`, `2hh`, `2hl`, `2hm`, `2hr`, `h2h`). It plays `mtidle` and nothing else.
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

- **Two-tier pathing.** `NpcSimulationServer` stays the global planner: for a physicalised actor it
  gives the next destination on the global route (the target, or the next door). The controller
  paths to that destination locally with a `NavigationAgent3D` on Godot's NavigationServer, which
  brings avoidance between agents (NPCs and the player) and dynamic obstacles
  (`NavigationObstacle3D`) the authored navmesh does not know about. Off screen, the server alone
  moves the actor, as now.
- **Local navmesh from NAVM.** The NAVM records of the lod0 tiles (or the current interior) become
  NavigationServer3D regions in a map for that space, built from `NavmeshReader`'s triangles and
  added and removed as tiles load and unload.
- **Movement is kinematic.** The controller moves at walk or run speed along the agent's next path
  position (with the agent's avoidance velocity), turns toward it at `turn_speed_degrees`, and
  keeps to the ground with `GroundRay`. No `move_and_slide`: the navmesh says where an actor can
  walk.
- **State stays on the reference.** Every physics frame the controller writes position and heading
  to its `ActorReference`, as `PlayerController` does for the possessed actor.
- **Movement target on the reference.** `NpcSimulationServer` runs packages for every actor and
  sets where it is heading; the controller only moves. `ActorReference` gains runtime state with no
  ESM source: `move_target: Vector3` (in the actor's current space), `has_move_target: bool`, and
  signal `move_target_reached` (emitted on arrival, when the target is cleared). The server sets
  the target to the next stop on the global route: the package target, or the next door.
  Off screen (`LOW_LEVEL`) the server walks the actor there itself and emits the signal;
  physicalised (`PHYSICAL_LEASED`) the `NpcController` paths there locally and reports arrival.
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
- **Animation input:** controllers publish their motion; the actor chooses its own clips. Both
  `PlayerController` and `NpcController` keep an `ActorMotion` resource up to date every physics
  frame (move input, current velocity, grounded, running, crouching, turning) and hand it to their
  `EsmActorNode`. The node's `ActorAnimator` reads it and picks clips or blends as suits the
  actor: humanoid locomotion sets for NPCs, its own for creatures. Controllers never name a clip.
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

## Open

- Nothing yet.
