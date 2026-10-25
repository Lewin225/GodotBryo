# Stage D: NpcController

A controller for physicalised NPCs and creatures, cheaper than `PlayerController`, built as a
template scene to open and tweak like the actor template. Gate: an NPC walks a route across
GSDocMitchellHouse, and the player and the NPC animate from their controllers.

## Build order

1. **Local navigation.** Done: the current interior (`CellStreamerV2`) and `WorldStreamerV2`'s
   resident full-detail tiles (none while paused) are local (`LocalNavigation`,
   `test_local_navigation`, `test_world_streamer_v2`).
2. **`ActorMotion`.** Done: `PlayerController` publishes it, `ActorAnimator` chooses the
   unarmed clip (`test_actor_node`).
3. **`npc_controller.tscn`.** Done: follows NpcSimulationServer's route to the reference's
   `move_target` (fields added here rather than in step 4), turns on the spot before walking,
   writes position and heading while leased (`test_npc_controller` walks Doc 27.4 m across his
   house).
4. **Spawning and hand-off.** Done: the physicaliser builds an `NpcController` for every
   `ActorReference`; the controller extends `EsmNode` and is the node registered for the
   reference (streamers free, reparent and place it), tells its `EsmActorNode` to load and
   unload, and holds the lease while in the tree. `checkout()` / `checkin()` removed; the
   README's hand-off section rewritten.
5. **Gate in play.** Done: with `NpcController.debug_follow_player` (since replaced by the
   Follow package), Doc follows the player
   across GSDocMitchellHouse and the Goodsprings saloon's NPCs follow in theirs, turning, walking
   and idling from their controllers. The player's own body is not visible (no third person
   yet); its `ActorMotion` is covered by `test_actor_node`.
6. **Follow package.** Done: `NpcSimulationServer` runs FOLLOW for actors given it by
   `AddScriptPackage` (`PackageRunner`), moves unleased ones itself (`LowLevelTravel`), and
   goes through load doors to reach a target in another space; an `NpcController` holds its
   lease only while its space is physically loaded. `test_package_follow` has Doc follow the
   player across his house, out into WastelandNV and back. Replaces the controller's
   `debug_follow_player` stub. Gate: Doc follows the player across the wasteland into other
   interiors in play.
7. **Moved:** the door and obstacle cut, to `Plans/Navigation/door_obstacle_cut.md`.

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
  Specified in full in `Plans/Navigation/door_obstacle_cut.md`.
- **Doors along a route.** The controller opens the door a waypoint names on reaching it and
  waits for it to open. A door whose state changes under a route (locked, unlocked) makes
  NpcSimulationServer route again.
- **Local navmesh from NAVM.** The NAVM records of the lod0 tiles (or the current interior) are
  `NavigationRegion3D` / `NavigationLink3D` nodes under `NpcSimulationServer/LocalNavigation`,
  unblocked: no door regions or navigation layers.
- **Movement is kinematic.** The controller moves at walk or run speed along the agent's next path
  position toward the current waypoint (with the agent's avoidance velocity), turns toward it at
  `turn_speed_degrees`, and keeps to the ground with `GroundRay`. No `move_and_slide`: the
  navmesh says where an actor can walk.
- **State stays on the reference.** The controller moves the actor every physics frame and writes
  its position and heading to the `ActorReference` every `placement_write_seconds` (0.1 s), on
  arrival and when it hands the lease back; the possessed actor's `PlayerController` writes every
  frame.
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
- **Spawning.** The physicaliser instances `npc_controller.tscn` for an `ActorReference`, except
  for the possessed actor, which the player's body stands in for. `NpcController` extends
  `EsmNode` and is the node registered for the reference (`EsmNode.node_for`), so streamers
  free, reparent and place the whole actor through it, and enable state hides it and turns off
  its collision, the Body capsule included. It loads no model itself: it hands the reference to
  its `EsmActorNode` child (`placed_by_parent`, so the child does not register) and tells it to
  load or unload; activation is forwarded to the child.
- **Lease hand-off by field.** The lease rules are in the NpcSimulationServer README ("Who owns
  which field"): leased, the controller writes `position` and NSS never does; unleased, the
  reverse; NSS always owns the package and `move_target`, and keeps ticking a leased actor. The
  lease follows physical presence: the controller holds it (`PHYSICAL_LEASED`) while it is in
  the tree and its space has local navigation, placing itself where the reference has got to on
  taking it; leaving the tree, or its streamer pausing, writes its final position and heading,
  then sets `LOW_LEVEL`.
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
- **Seams.** NAVM records join where their open edges (NVTR neighbour -1) meet; they rarely
  share vertices. Measured over FalloutNV.esm (`native/tools/navm_seam_gap_census.cpp`): of 6,252
  NVEX-joined record pairs, 5,009 have open edges within 0.25 m, 177 (exterior) at 0.25-4 m, the
  4 interior ones (0x10D629) at 1.12-3.84 m, and 1,062 farther than 4 m. 538 pairs NVEX does
  not join have open edges within 0.25 m, 427 of them coincident; no pair within 0.25 m looks
  like a cliff top over the ground below. NVEX's target triangle is no measure of where the
  records meet: it is over 4 m from the source record's open edges for most entries.
  `LocalNavigation` therefore uses Godot's edge connections at a 0.5 m margin (616 pairs NVEX
  does not join fall within it, all well short of the 1 m+ where a ledge would join the ground
  below), plus a `NavigationLink3D` for each NVEX-joined pair 0.5-4 m apart (76), between the two closest points
  on their open edges (`NavmeshReader.get_record_seam_links`), so it crosses at the seam.
  On 49 cells around Goodsprings, edge connections alone reach the same 94 of 100 cross-cell
  routes as links between triangle centres, without the detour through each centre
  (`_diag/diag_local_seams`). The controller crosses a link deliberately: on
  `NavigationAgent3D.link_reached` it walks straight to the exit, its height going from the
  entry's to the exit's, and resumes the agent's path there.
- **Stuck recovery.** A controller with route left that moves less than `stuck_distance`
  (0.25 m) in `stuck_seconds` (3 s), whatever blocks it, is moved to its current waypoint and
  stood on the ground there.

## Door and obstacle cut

Moved to `Plans/Navigation/door_obstacle_cut.md`.

## Open

- **Templated and leveled appearance.** Moved to `Plans/Actors/templated_npcs.md`.

- **Router seams (NavmeshReader / NpcSimulationServer).** Its A* crosses between records only by
  the derived NVEX pairs (`build_cross_record_links`), so it likely cannot route across the 538
  record seams NVEX does not record, which Godot joins; and it bridges the 1,062 NVEX pairs
  whose open edges are over 4 m apart, whatever lies between. Neither is checked against the
  game. Its nearest-triangle pairing also makes routes cross the same seam back and forth
  (interior 0x10D629: a 53 m route goes up onto a record and down again).

- **Same-space follow with no direct route.** FOLLOW plans doors only when the target is in
  another space. Within one space it asks for a direct route; when that route is not found the
  actor retries every `route_retry_seconds` (5 s) and never tries doors. With every actor
  following the player in WastelandNV, at Primm 3,218 off-screen and 1,444 on-screen routes
  failed in one 5 s interval and those followers did not move until the player walked north.
  Whether the cause is walkable regions joined only by doors or a target off the navmesh is not
  checked. Proposed: when a same-space route is not found, plan a door sequence by walkable
  region (`find_door_sequence` already searches by region).

- **The first-copy-in-a-frame cost (NifServer).** The first template copy in a frame pays a cost
  that later copies in the same frame do not, up to about 10 ms with ~1,300 physicalised actors
  (NifServer README "The copy is synchronous"). A bare `Node3D`, `StaticBody3D` or
  `MeshInstance3D` created first in a frame does not pay it; what does is not identified.
  `DebugCopyBench 5` copies the teeth, head, skeleton and upper body, and a `MeshInstance3D` given
  a skinned mesh, one a frame in turn.

- **Distance tiers for crowded scenes (not needed for normal play).** Normal play has at most about
  25 physicalised actors; at the measured rates that is about 6 ms of process and under 1 ms of
  physics. `DebugActorCost` with 1,342 physicalised actors and 546 visuals (median ms saved,
  process / physics / frame, against 141.5 / 35.9 / 201.6): visuals hidden 74 / 2 / 77,
  controllers 16 / 24 / 58, look-at modifiers 20 / 0 / 19, skeleton process off 20 / 0 / 21,
  animation players 14 / 0 / 17, avoidance 6 / 3 / 12, animator clip choice 5 / 2 / 9. If a scene
  ever needs it: lease only within ~25 m and let LowLevelTravel move the rest on a faster sweep
  with the node following the reference; advance distant animation every few frames by the
  accumulated time (switching 150 `AnimationPlayer`s back on raised process time to ~35 ms for a
  stretch, headless); no look-at beyond ~10 m.
