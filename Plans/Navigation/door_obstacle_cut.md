# Door and obstacle cut

Internal doors and obstacle-flagged objects are cut out of `NpcSimulationServer`'s navmesh, so
routes stop at closed doors and go around obstacles. Follow-on to
[`Completed Plans/Actors/stage_d.md`](../Completed%20Plans/Actors/stage_d.md).

## Current state

- Routes ignore internal doors and obstacles: a controller walks into a closed internal door.
- `NpcSimulationServer.can_pass_door(actor, door)` exists: true when the door is not locked or
  the actor carries its key. `blocked_doors_for(actor)` applies it to load doors only, which
  `find_door_sequence` leaves out of a door sequence. Ownership (XOWN / XRNK) and lockpicking are
  not considered.
- No footprints and no CSG split exist; `find_route` takes no blocked set.

## Facts (FalloutNV.esm unless stated; `native/tools/door_obstacle_census.cpp`,
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

## What to build

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
   door; everything that builds a route's blocked set calls it. The first two clauses exist
   (Current state). True when any holds:
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

## Tests

- `can_pass_door`: unlocked door true; locked door false for an actor without the key and true
  once the key is in its inventory; owner and faction clauses once XOWN / XRNK are read.
- With Doc's bathroom door `001062AC` blocked, no route crosses from one side of it to the
  other; unblocked, the route crosses and names the door at the crossing waypoint.
- Every cut shared edge has identical vertices on both sides (no T-junctions): the rebuilt
  adjacency is symmetric across all cut triangles.
- Triangle area is conserved: the pieces of each cut triangle sum to its area.
- Census numbers above re-run unchanged.

## Open

- Whether a slab always spans the navmesh doorway. Doc's does (slab y 10.97-12.80, doorway
  10.99-12.74); if one falls short a route slips around its end. Widening footprints along the
  door's width is the fallback, tuned against the blocked-door test over every door with
  triangles under it.
- Obstacle footprints: OBND is a box; a rock's real footprint is smaller. Whether that cuts
  walkable ground the game keeps needs a comparison in play.
- DLC: the 261 unresolved NVDP references and DLC obstacles wait on EsmServer loading the DLC
  masters; `NavmeshReader` keeps each DLC's file-local `01xxxxxx` FormIDs, which can collide
  between DLCs.
