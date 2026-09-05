# Phase 14 — Physics & Havok-Equivalent Behavior

Parent: [ROADMAP.md](../../ROADMAP.md)

Goal: reproduce dynamic physics behavior after the actor, scripting, AI, and combat systems are
otherwise useful.

## Scope

- Ragdolls using Jolt constraints mapped from real `bhkRagdollConstraint` data.
- Dynamic loose objects using real `bhkRigidBody` mass, friction, and restitution values.
- Projectile physics for ballistic weapons and explosives.

## Exit criterion

Shootable and kickable physics props in a test cell match the original game's mass, bounce, and
settling behavior closely enough to be unremarkable.
