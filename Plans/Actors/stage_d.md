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
- **Local navmesh from NAVM.** Each NAVM record of a loaded cell becomes a `NavigationRegion3D`
  (vertices and triangles from `NavmeshReader`), added and removed with the cell by the streamers.
- **Movement is kinematic.** The controller moves at walk or run speed along the agent's next path
  position (with the agent's avoidance velocity), turns toward it at `turn_speed_degrees`, and
  keeps to the ground with `GroundRay`. No `move_and_slide`: the navmesh says where an actor can
  walk.
- **State stays on the reference.** Every physics frame the controller writes position and heading
  to its `ActorReference`, as `PlayerController` does for the possessed actor.
- **API for packages (stage H):** `move_to(space, position)` requests the route and walks it;
  `stop()`; signal `arrived`. Stage D drives it from a test or diagnostic, not from packages.
- **Motion to animation, shared with the player.** A `MotionData`-like state (actor-local velocity,
  grounded, running) goes to the actor node's `ActorAnimator.set_motion()`, which picks the
  `mt*` clip for direction and speed (and turns in place). `PlayerController` calls the same
  method in place of the legacy `ActorAnimationComponent`.
- **Spawning.** The physicaliser instances `npc_controller.tscn` for an `ActorReference` (the
  controller owns its `EsmActorNode`), except for the possessed actor, which the player's body
  stands in for.

## Questions

0. **Seams.** Godot connects regions by touching edges; NAVM records do not touch. Proposed:
   stitch by the ESM's connection data instead. Within a record, NVTR adjacency is exact and one
   record is one region. Across records, each NVEX link names its target record and triangle
   (resolving 100%); the source triangle is not authored, and
   `NavmeshDatabase::build_cross_record_links()` pairs it with the nearest triangle, as the
   server's A* already uses. Each pair becomes a bidirectional link
   (`NavigationServer3D.link_create`, no nodes) between the two triangles' centres, so local and
   global pathing join records in the same places. Needs `NavmeshReader` to expose the derived
   pairs. Caveat: target triangles are generally interior (10.6% have a boundary edge), so a link
   can cross a little way into the next record.
1. **The body.** What triggers detect, and what the player bumps into:
   - an `Area3D` capsule: cheapest; triggers see it (with the volumes monitoring areas too); the
     player walks through NPCs;
   - an `AnimatableBody3D` capsule moved kinematically: triggers see it and the player is blocked
     by NPCs, still without per-frame sliding.
2. **Speeds.** Fallout derives walk and run speed from GMSTs (`fMoveCharWalkMin`/`Max`,
   `fMoveCharRunMin`/`Max`, scaled by the actor's SpeedMult and the clip's own speed). Read those,
   with a scene multiplier to tweak, or start from plain exported speeds?
3. **Clip selection.** Code in `ActorAnimator` switching clips by direction and speed with a short
   crossfade, or an `AnimationTree` (a BlendSpace2D of the `mt*` clips) authored in the actor
   template scene, tweakable in the editor? The tree is the "human touch" option; an earlier
   locomotion AnimationTree in the legacy path had bugs (wrong player path, a missing Z-up fix,
   root-motion drift from uneven track sets), which the rebuilt node would have to avoid.
