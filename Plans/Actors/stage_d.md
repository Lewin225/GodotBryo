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
- Trigger volumes (`EsmPrimitiveVolume`, an `Area3D`) fire OnTrigger for physics bodies inside
  them. VCG01's chair trigger fires `OnTrigger DocMitchellREF`, so Doc has to be something the
  volume detects.

## Proposed shape

`npc_controller.tscn`, root `NpcController` (`Node3D`):

```
NpcController (Node3D, npc_controller.gd)     exports: walk_speed, run_speed, turn_speed_degrees,
├── EsmActorNode (instance of esm_actor_node.tscn)      arrive_radius, ground_snap_distance
├── Body (see question 1)                    ← what triggers and the player collide with
└── GroundRay (RayCast3D)                    ← snaps height while walking
```

- **Movement is kinematic.** The controller follows the route's waypoints at walk or run speed,
  turns toward the next one at `turn_speed_degrees`, and keeps to the ground with `GroundRay`.
  No `move_and_slide`: the navmesh already says where an actor can walk.
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
