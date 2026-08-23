# Phase 3 — Actors, Skeletons, Animation

Parent: [ROADMAP.md](../../ROADMAP.md)

Goal (per ROADMAP.md): NPCs and the player exist in the world and animate, but are
inert — no AI, no combat, no dialogue yet. Full scope: skeleton/skinning
(`NiSkinInstance` → `Skeleton3D`), KF/animation playback, equipment mesh swapping,
a real third-person player controller, and spawning `NPC_`/`ACHR` actors idle-animated
at their placed positions.

**Sequencing note (from ROADMAP.md, confirmed against real data, not assumed):** this
phase starts with the simpler, non-skeletal case rather than skeleton/skinning first.
Physical (non-teleporting) doors use a dedicated "Animated" model variant (confirmed
real and distinct in `FalloutNV.esm` — e.g. `NVCraftsmanRmDoorAnimated.NIF` vs plain
`NVCraftsmanRmDoor.NIF`) carrying rigid single-node `NiControllerManager`/
`NiControllerSequence`/`NiTransformInterpolator`/`NiTransformData` keyframe data — no
bone hierarchy, so it doesn't need `Skeleton3D` support to land. **Done** — see
[00-door-completion.md](00-door-completion.md): `DoorNode.activate()` now plays real
animation, Open/Close/Loop sounds, and DOOR flags for non-teleporting doors, with a
mid-swing reactivation debounce.
