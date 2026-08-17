# 1.2 — Collision Extraction (NIF `bhk*` → Godot Shapes)

Parent: [Phase 1](README.md)

## Goal

Derive real Godot collision shapes from a NIF's Havok (`bhk*`) collision data, closing
the gap flagged since [0.3](../0/03-nif-parser.md) and restated in
[Phase 0's results](../0/results.md). Can be developed and tested independently of
1.0/1.1's object-type breadth — it only needs *a* NIF with collision data to work
against, which 1.0 already provides. Benchmark: walkable collision, not physically
exact Havok material fidelity.

## Format notes

`nifly` (vendored, `native/nifly/`) already models the full Havok class hierarchy in
`bhk.hpp` — confirmed by reading the header directly — but provides no convenience
getter the way it does `GetVertsForShape()` for render geometry. This is new code to
write, not a missing library. The concrete block-walk path, from `Objects.hpp`/
`bhk.hpp`:

```
NiAVObject::collisionRef → bhkCollisionObject → bhkRigidBody
  (has translation/rotation/friction/restitution + a shape reference)
  → bhkPackedNiTriStripsShape (most common for static world geometry)
    → dataRef → hkPackedNiTriStripsData
      (triData: triangle indices; compressedVertData: Vector3 verts, if compressed)
```

Exact field names for the rigid-body → shape reference weren't pinned down from
memory with full confidence during Phase 1 planning — verify directly against the
vendored `native/nifly/include/bhk.hpp`/`Objects.hpp` at implementation time (cheap,
it's local source, not a web lookup) rather than trusting this doc's recollection.

Simpler shapes exist for non-mesh collision and map onto Godot's built-ins fairly
directly:

| bhk shape | Godot equivalent |
|---|---|
| `bhkPackedNiTriStripsShape` | `ConcavePolygonShape3D` (static triangle mesh) |
| `bhkBoxShape` | `BoxShape3D` |
| `bhkSphereShape` | `SphereShape3D` |
| `bhkCapsuleShape` | `CapsuleShape3D` |
| `bhkConvexVerticesShape` | `ConvexPolygonShape3D` |

`bhkMoppBvTreeShape` wraps a shape in a Havok-proprietary compiled BVH (MOPP) for
runtime query acceleration — the MOPP data itself is opaque/not meant to be decoded;
what matters is the underlying shape it wraps, which is reachable the same way.

## Steps

1. Write `native/src/nif/nif_collision.{h,cpp}`: given a loaded NIF, walk each
   `NiAVObject`'s `collisionRef` chain and extract a plain (Godot-independent)
   collision representation — shape kind + geometry (verts/tris for mesh shapes,
   dimensions for primitives) + the collision body's local transform.
2. Add a fallback path for objects with no `bhk` data: bounding-box (from the NIF's
   own computed bounds) or convex-hull-from-render-mesh, per the original
   [ROADMAP.md](../../ROADMAP.md) Phase 1 scoping.
3. Extend the Godot-facing wrapper (`NifReader` or a sibling) to expose collision
   data the same way it exposes render geometry.
4. Wire into 1.0/1.1's node construction: replace the collision placeholder with a
   real `CollisionShape3D` built from this module's output.
5. Test against a variety of real objects from the target cell(s) — furniture,
   walls/floor pieces, and at least one object confirmed to have no `bhk` data (to
   exercise the fallback path deliberately, not by accident).

## Deliverables

- `native/src/nif/nif_collision.{h,cpp}` — pure C++, no Godot dependency, same
  pattern as `nif_loader.{h,cpp}`.
- Godot wrapper exposing collision shape data.
- Test scene demonstrating a physics body (e.g. a simple falling test object, or a
  free-fly collision check) resting correctly on real extracted collision geometry.

## Acceptance criteria

- [x] A `bhkPackedNiTriStripsShape`-based static produces correct walkable
      `ConcavePolygonShape3D` collision — confirmed against real data from
      `GSDocMitchellHouse`: 334/403 built objects have collision (142 triangle-mesh
      shapes among them), verified with an actual physics drop test (see below).
- [x] Primitive shapes confirmed against real data, all 5 shape kinds present:
      `box`×113, `convex_hull`×104, `sphere`×2, `capsule`×1, alongside the 142
      `triangle_mesh`. Box tested with a real physics drop.
- [x] Objects with no `bhk` data (69/403 in the same cell) get a bounding-box fallback
      collider from the render mesh's own AABB — tested with a real physics drop.
- [x] Demonstrated with actual physics, not just "the data parsed": a headless test
      (`project/test_collision.gd`) drops a small `RigidBody3D` sphere from above three
      specific real objects — one found to have triangle-mesh collision, one box
      collision, one using the fallback — and confirms each one actually stops the
      ball near floor height rather than letting it fall through. All three pass.

### Bug found during physics testing, not by inspection

The triangle-mesh case initially failed outright — the test ball fell in what turned
out to be **pure, unimpeded freefall** the entire simulation (confirmed by comparing
the fall distance against expected freefall physics: ~29m over a 1.5s window matched
freefall-from-already-falling velocity almost exactly, meaning it never touched
anything). Two real, separate bugs, found and fixed in sequence:

1. **Wrong drop target position.** The test was dropping onto the *object's own pivot
   origin* (`REFR` placement anchor), not the collision geometry's actual world
   footprint — those aren't the same point for meshes whose pivot isn't centered on
   their geometry (e.g. a wall-mounted piece pivoting at its attach point). Fixed by
   computing the collision shape's own world-space AABB center and dropping onto
   that instead.
2. **`ConcavePolygonShape3D` is one-sided by default** (`backface_collision = false`
   in Godot). Havok's own triangle winding is a separate data source from the render
   mesh's (which needed its own winding fix in 0.3/1.0) and was never independently
   verified. Rather than risk guessing a second unverified winding convention, set
   `backface_collision = true` unconditionally on triangle-mesh collision — makes it
   solid from both sides, matching this task's "walkable, not exact fidelity"
   benchmark.

Fixing only #2 didn't change anything (results were byte-identical) — #1 was
independently blocking the test the whole time, which is why the two bugs are
recorded as a sequence, not "found bug, fixed, done." Worth remembering: when a fix
doesn't change a test's output at all, check whether the test is even exercising the
code path being fixed before concluding the fix was wrong.

### Third bug: Havok unit scale was backwards, caught by eye after the fact

The physics drop test above (all three cases passing) shipped first and looked
complete — but it has a real blind spot: it targets each collision shape's own
centroid, so a *uniform scale error* is invisible to it (a shrunk collision mesh's
centroid is still roughly its centroid; the ball lands on it regardless of how big
it actually is). This is exactly what happened: `units::kHavokToMeters` was defined
as `kGamebryoUnitsToMeters / 7.0` (sourced from a single, not independently
re-verified, description of nifskope's Havok operations), when it should have been
`kGamebryoUnitsToMeters * 7.0` — the division direction was backwards, making every
triangle-mesh/box/capsule/convex-hull collision shape **~49x too small** (a factor of
7 in each of two compounding wrong directions). Not caught by the acceptance testing
above; caught by the user visually inspecting collision shapes in the Godot editor
(`cell_viewer_editor.tscn`) and noticing mesh colliders were tiny next to their own
render mesh.

Fixed by verifying numerically rather than guessing a replacement constant: wrote a
standalone probe comparing each real triangle-mesh collision shape's own extracted
AABB size against its sibling render mesh's AABB size (already known-correct) across
several real objects, trying a few candidate conversions. `havok_raw * 7.0 / 70.0`
matched the render mesh size almost exactly every time (e.g. one object: render size
`(0.343, 2.743, 0.229)` m vs. collision size `(0.343, 2.743, 0.229)` m — identical to
3 decimal places), conclusively fixing both the constant's value and its direction at
once.

Added a permanent regression check for exactly this failure mode
(`check_collision_scale_sanity()` in `test_collision.gd`): compares every built
object's collision-shape AABB diagonal against its own render-mesh AABB diagonal,
across the whole cell (359 objects checked), asserting the ratio stays within a
generous 0.2×–4× band. All but one land within 0.8×–1.0× (a real, physically
plausible ~4x-simplified collision proxy on a single small bucket prop is the sole
outlier, comfortably inside the band). This check — not the physics drop test — is
what would have caught this bug immediately if it had existed first; both are now
kept, since they validate different things (physically functional vs. correctly
sized).

## Explicit non-goals for this task

- Havok material properties beyond what's needed for basic collision (friction/
  restitution extraction is a nice-to-have, not required for "walkable").
- Ragdoll/constraint data (`bhkRagdollSystem`, hinge/prismatic constraints) — not
  needed until actors exist (later phase).
- MOPP tree decoding itself — only the shape it wraps matters.

## Known follow-up (not blocking, flagged so it doesn't get lost)

`backface_collision = true` on triangle-mesh collision (see the winding-order note
above) is a real workaround, not a real fix — it papers over not knowing Havok's
actual triangle winding convention rather than determining it. Works fine for
Phase 1's "walkable, not exact fidelity" benchmark, but worth properly resolving
later (e.g. testing a one-sided drop from below a known floor to infer the true
winding, or finding an authoritative source) rather than leaving double-sided
collision as a permanent, silent simplification. Explicit user pushback on this
being an acceptable-for-now-not-forever fix, not something I judged unimportant.

## Implementation notes

- **Field names verified against the vendored source, not memory**, as this doc's
  own Format notes flagged as necessary: `NiAVObject::collisionRef` →
  `bhkNiCollisionObject::bodyRef` (`bhkCollisionObject` inherits it) →
  `bhkWorldObject::shapeRef` (inherited by `bhkEntity`/`bhkRigidBody`) — all
  confirmed by reading `native/nifly/include/{bhk,Objects}.hpp` directly before
  writing any extraction code, not assumed from the plan.
- **A third, separate unit-scale conversion, found and sourced during this task —
  and initially applied backwards.** Havok collision shape data is stored in neither
  meters nor raw Gamebryo units, but its own scale. A single secondary source
  (nifskope's documented Havok-operations page) was read as `nif_units = havok_raw /
  7.0`, composed to `meters = havok_raw / 490.0` — this made every collision shape
  ~7x too small (on top of the already-applied /70, effectively /490 instead of the
  correct /10). Caught by eye in the editor, then **fixed by numeric
  cross-verification, not by re-reading the source more carefully**: compared real
  collision-shape AABB sizes against their own sibling render-mesh AABB sizes (see
  the "Third bug" section above for the full account) and confirmed the correct
  formula is `meters = havok_raw * 7.0 / 70.0` — multiply, not divide. Kept as a
  visibly separate constant (`units::kHavokToMeters`) from
  `units::kGamebryoUnitsToMeters` in `native/src/common/units.h` rather than folding
  them together, since conflating "the render-mesh/placement unit scale" and "the
  Havok unit scale" would have been an easy, hard-to-notice mistake given how similar
  the two numbers' provenance looks — and this bug is exactly why that separation
  paid off: only the Havok-sourced values were wrong, not the render/placement ones.
- `native/src/nif/nif_loader.cpp` extracts collision in the *same* NIF parse pass as
  render geometry (not a second file open/parse) — walks every `NiAVObject` block
  (not just render `NiShape`s; collision is commonly attached to a parent `NiNode`
  rather than the visible mesh itself) for a non-empty `collisionRef`, follows the
  chain above, unwraps a `bhkMoppBvTreeShape` wrapper if present (the MOPP data
  itself is opaque and skipped, matching the non-goal), and dispatches on the
  resolved shape's concrete type via `dynamic_cast`.
- Verified against real data before touching any Godot code: a standalone probe
  (same no-Godot-dependency pattern as `native/tools/dump_object`) ran collision
  extraction against every resolvable object in `GSDocMitchellHouse` and confirmed
  all 5 shape kinds appear in real content, and a healthy 334/403 objects have some
  form of collision — this caught nothing broken, but meant the Godot-side wiring
  and the physics test were built with confidence the C++ layer already worked,
  rather than debugging both layers at once.
- `GamebryoMeshResolver.populate_collision_children()` (`project/gamebryo/mesh_resolver.gd`)
  builds one `CollisionShape3D` per extracted shape (`ConcavePolygonShape3D`/
  `BoxShape3D`/`SphereShape3D`/`CapsuleShape3D`/`ConvexPolygonShape3D`), or one
  bounding-box fallback (from the render mesh's own AABB, matching the original
  ROADMAP.md Phase 1 scoping) if the NIF has no collision data at all. Godot's
  `CapsuleShape3D` is aligned along local Y by convention but Havok capsules are
  defined by two arbitrary endpoints — handled by building a basis whose Y axis
  points from `point_a` to `point_b` and positioning at the midpoint.
- Wired into both `_instantiate_visual()` (every ordinary Tier 1 type) and
  `_build_light()`'s optional fixture-mesh case in `object_registry.gd` — anywhere
  `populate_mesh_children()` is called, `populate_collision_children()` follows
  immediately after.
- Test harness: `project/test_collision.gd` / `test_collision.tscn`. Unlike every
  other visual-check task, this one runs fully **headless**
  (`tools/Godot_v4.7.1-stable_linux.x86_64 --headless --path project
  test_collision.tscn`) — `PhysicsServer3D` doesn't need a GPU or rendering context,
  only the rendering-based screenshot tests do. Uses `SceneTree` timers (real-time
  based) to let physics settle rather than manually counting `physics_frame` ticks.
