# NpcSimulationServer (NSS) design

**Status: complete.** The server seeds in the running game (`game.gd`), simulates checked-in
actors' packages over the door graph, and hands actors to and from `NpcController` by check-out
and check-in. Left as follow-ons: saving and restoring dirty references
(`Plans/Saving/reference_persistence.md`), DOOR FNAM Minimal Use in portal choice, exterior
blockers for off-screen travel, and interior NAVM sampling for in-space routes (all under "Not
now" below).


## Short intro
`NpcSimulationServer (NSS)` owns the persistent background simulation of placed NPCs. It is
independent of renderable NIF trees, interior streaming, exterior streaming,
and Godot physics bodies. It is entirely data driven. Streamers can query it to
determine if and where npc's should be placed in the cell they're loading.

When a npc is physicalised by either of the streamers, it must be "checked out" from the NpcSimulationServer

When the streamers remove the physical actor, the ActorReference is then marked as "checked in", 

NpcSimulationServer simulates checked in npc packages using a simple point in space system, plus a set of navigation links. this is a low tick background simulation that does not take place in the world 


## Purpose
An NPC has one shared `ActorReference` godot resource instance. 

Its controller and visual actor are temporary local embodiments of that reference.


`NpcController` and the player's `PlayerController` are separate,
independent implementations that do not share a base class or movement code.
Both do the same thing, move an actor in physical space and handle rendering it using `EsmHumanoidActor`

The `ActorReference` is held by `EsmHumanoidActor`, not currently copied into the pilot.
this may change, but it's simply a shared pointer either way, it can have many holders

`EsmHumanoidActor` is a
rendering/assembly component even though it also holds a reference: it does not
choose packages, routes, targets, equipment, or hostility. Those decisions
stay with `NpcSimulationServer`/`NpcController`; `EsmHumanoidActor` only
reflects them visually.


## Reference identity and persistence

At game start, `NpcSimulationServer` obtains every placed NPC `ActorReference`
from `EsmServer` and indexes those same resource instances by stable reference
identity. `EsmServer` can return a handle to the same instance to any caller;
`NpcSimulationServer` does not own the reference or make a parallel virtual
actor record.

For scale: the base game plus all official DLC place 3,957 `ACHR` references
game-wide (per `Plans/Completed Plans/Navigation/navmesh_esm_census.md`) — every one of them
a permanent, always-indexed point-cloud entry from game start, since indexing
costs nothing here (no node, no collision, no `_process()`). 

Only the ones inside a streamer-resident region are ever checked out; the "Perception
sampling" budget above already assumes an order of ~20 physically leased at
once, not 3,957. `ACRE`/`CREA` creature placements (3,804 game-wide) are out
of scope for this document: `ActorReference` today maps only from `NPC_`
placements (`esm_server.gd`), and creatures have no equivalent typed
reference yet.

`ActorReference` is mutable runtime state. Position, current cell, inventory,
equipment, active package execution, and travel progress are written to that
resource this marking it dirty. `EsmServer` persists dirty references. 
On restart it rehydrates the authored ACHR reference plus its saved overlay, and
`NpcSimulationServer` seeds from those rehydrated references. 
(Savegames are not implemented but will be transparent to this system)

Authored spawn provenance and mutable location are separate fields:

```text
spawn_cell_form_id    authored ACHR owner; immutable
current_cell_form_id  runtime location; mutable - must be updated by NSS if simming in a multi cell worldspace
current_space_form_id to cover workspaces, this is the space query filter
```
The current space allows the NSS to treat the simulated NPC's as different spaces/layers. 
NPC's in NSS can only perceive other NPC's in the same space as them.
They can however navigate to References in different spaces, using travel (and other) packages

No simulation rule depends on classifying a space as interior or exterior.

The player is registered as one bespoke `ActorReference`, physically leased
to `PlayerController` from creation. It never enters `LOW_LEVEL` mode, so it
never checks in and consequently never checks out either — there is no
virtual-to-physical transition to perform, only a permanent physical lease.

`NpcSimulationServer` never simulates the player's actor. The player controller
remains movement/input authority; `NpcSimulationServer` indexes the player's actor just like any other
for package targets, spatial queries, awareness, and hostility.

## Simulation space

Every reference in the virtual layer is nothing but a point (ActorReference.position)
and a `current_space_form_id`, all held in the same server. There is no
per-space loading or unloading here — the whole authored world is always
"in" the server, the same way it's always in `EsmServer`. What the server
controls is not what exists, but who can see or interact with whom: two
references are only comparable, and only visible to each other, when their
`current_space_form_id` matches.

The server is a data-only point cloud, indexed by authored space:

```text
instance ID → ActorReference
current_space_form_id → NPC instance IDs   (perception/interaction masking)
current_cell_form_id → NPC instance IDs    (streamer check-out queries)
next game-time event → NPC instance ID
```

There are no virtual NPC scene nodes, collision objects, visual actors,
navigation agents, or per-NPC `_process()` callbacks.

An active streamer registers its active simulation space with
`NpcSimulationServer`. When a virtual NPC enters one of those spaces, or
changes `current_cell_form_id` within a registered space,
`NpcSimulationServer` notifies the relevant streamer of its updated spatial
membership. The notification never spawns a node or changes simulation mode;
it tells the streamer that its local checkout policy may now apply. A streamer
can also query the shared index for NPCs in an active space by range. 

Any default `nearby NPCs` query is centred on the players `ActorReference`; callers
may supply another centre and range when their own residency policy requires
it.

Low-level processing advances on game-time events: package schedule boundaries,
package completion, route/portal arrival, relevant observations, or a coarse
due tick. Travel advances along a space-qualified vector/portal itinerary
using elapsed game time. A change within a space updates
`current_cell_form_id` only; crossing a portal updates both
`current_cell_form_id` and `current_space_form_id` and moves the reference
between the `current_space_form_id` index buckets above.

V2 feature: An unleased NPC with the `No Low Level Processing` NPC flag is skipped for processing in NSS
It will only be able to run it's packages when checked out and physicalised

`ActorReference` will carry an attached simulation-state component. It contains the
current package execution, intent, route state, active target, and transient
perception/threat data. Should be based on ESM data as much as possible

Persistent simulation fields dirty the reference; rebuildable perception cache does not need save persistence.

```text
ActorReference
  └─ simulation_state
       mode: LOW_LEVEL or PHYSICAL_LEASED
       active package and execution phase
       current intent and target
       space / vector-leg / portal progress
       perception and threat entries
```

`LOW_LEVEL` and `PHYSICAL_LEASED` describe who is currently executing the
simulation, not resource ownership or write permission. 

Every participant can hold the same `ActorReference` handle. 
The lifecycle rule is simply mutually exclusive mutation: 
  while checked in, `NpcSimulationServer` advances the reference and no physical controller exists; 
  while checked out,`NpcController` advances it and `NpcSimulationServer` leaves it untouched.


`EsmHumanoidActor` observes that same reference and refreshes visual state as needed.


Perception entries are actor-relative rather than a single visibility boolean:
awareness state, last known position, last observation time, and hostility
state. Virtual observations and physical observations update the same state.

## Perception sampling

A perception target is any `ActorReference`, not only the player. While
physically leased, its controller writes `ActorReference.position` every
frame as it moves, so the position the NSS sees is always current, not
just captured at check-in/check-out boundaries. A virtual target's position
is only as current as its last low-level tick, since nothing is writing to
it between ticks.

Virtual-space perception is distance only; no physics will exist or is intended 
Virtual perception is simply by space and distance: an unleased reference
becomes eligible for physical check-out once a target comes within
check-out range.

A physically leased `NpcController` gates its raycast behind cheaper checks
first: distance to the candidate target against a perception radius smaller
than the streaming/check-out radius, then an FOV cone test, and only then a
raycast. For v1, raycast scheduling is a simple load spread, not a priority
system: one physically leased controller thinks per frame, round-robin,
with no distinction between aware and unaware controllers. At a target of
~20 concurrent physically leased NPCs and a 165 fps target, that is a full
cycle roughly every 120ms, which is fast enough that prioritizing aware
controllers isn't worth the complexity yet. A successful raycast updates the
perception entry (`last observation time`, awareness state) and reports it
to `NpcSimulationServer` which may or may not set a target depending on that actor's logic or packages.




## Packages and intents

`NpcBase.packages` is the authored package stack. `NpcSimulationServer` owns
the package runner that selects and advances the active package. The package
runner updates intent stored in the ActorReference; it does not move a physics
body directly.

```text
Package runner → Intent → virtual executor or physical executor
```

An intent includes the current in-space target vector, target
reference/location, locomotion policy, interaction request, equipment
request, and completion condition. 

A global route consists of same-space vector legs joined by portal transitions. 
`NpcSimulationServer` does not construct navigation paths; 
a checked-out physical npc may use the local Godot navigation map to execute a local intent.
These real world navigation meshes are loaded by cell/worldstreamer and are unrelated to the NSS


Package selection and package execution are separate. Early executor fixtures
force an explicit Follow package as the first-pass test package.

`NpcSimulationServer` owns decisions: package selection, high-level route and
portal choice, response to awareness/damage, desired equipment/item use, and
persistence. `NpcController` owns local execution: collision, movement,
`NavigationAgent3D`, physical observations, and applying authorised visual or
interaction commands. It reports facts such as waypoint reached, line of
sight, damage, blocked movement, and interaction result back to
`NpcSimulationServer`.

## Physical check-out

`WorldStreamerV2` and `CellStreamerV2` own physical checkout. They register
their active spaces with `NpcSimulationServer`, query the shared spatial
index when an area becomes resident, and react when NSS reports an NPC
entering an active space. NSS supplies shared `ActorReference` handles; it
does not spawn nodes or choose the streamer's residency/range policy.

`CellStreamerV2` treats its loaded interior as one active simulation space. As
soon as that cell and its navigation map are resident, it checks out the NPCs
in that interior and checks out later arrivals reported for the same space.
`WorldStreamerV2` treats its active WRLD as one space but applies its own
player-centred near-cell/range residency policy. It checks out matching NPCs
when exterior cells enter that policy, and when an NSS spatial-membership
notification puts an NPC inside already-resident coverage. Distant/VWD
residency is not NPC physical residency.

Checking out tells `NpcSimulationServer` that a reference is going to be a
physical entity until it is checked back in; the streamer then hands each
checked-out reference to `EsmReferencePhysicaliser`.

```text
streamer:            register active space; local area and NAVMs become resident
streamer → NpcSimulationServer: query nearby references, or receive an entry notification
NpcSimulationServer → streamer: matching ActorReferences
streamer → NpcSimulationServer: check these out (now physical)
streamer → EsmReferencePhysicaliser: spawn a controller for each
```

The NSS handoff API is deliberately narrow:

```gdscript
func checkout(reference: ActorReference) -> bool
func checkin(reference: ActorReference) -> bool
```

`checkout()` changes a tracked reference from `LOW_LEVEL` to
`PHYSICAL_LEASED` and removes it from NSS advancement. `checkin()` changes it
back, and schedules its next permitted low-level update. 

`false` means the reference is not NSS-tracked or is already in the requested state.

Neither method receives a controller, parent, cell, range, or navigation map.
Those are streamer responsibilities: the streamer chooses candidates from its
own residency policy, calls `checkout()`, then creates the `NpcController` in
its physical host. During teardown it calls `checkin()` before destroying that
controller.

Check-out occurs after the streamer has registered its physical navigation
map. NSS neither selects a navigation region nor creates a physical
navigation connection; it only hands the controller the reference's
current position vector and local intent. 
**How the controller resolves that
raw vector onto the loaded navmesh — nearest-point clipping, a route-aware
landing search, or something else — is unresolved.** 

Worldspace travel is simple linear point-to-point movement, 
so exterior checkout is low-risk. What
actually happened for interior AI travel/landing on the original 360-era
engine is not well documented and not confidently known here; don't take
this document as having settled it. The reference's simulation mode becomes
`PHYSICAL_LEASED`; low-level movement for that reference stops so both
executors never advance it.

For an `ActorReference`, `EsmReferencePhysicaliser` spawns an `NpcController`
(new physical node type; owns the capsule collider, movement,
`NavigationAgent3D`) with a child `EsmHumanoidActor` for visual rendering.
`EsmHumanoidActor` itself already exists and is unchanged by this plan. As an
interim step before `NpcController` exists, `EsmReferencePhysicaliser` spawns
the bare `EsmHumanoidActor` directly, with no controller, purely to exercise
load performance; this interim path is not the target design.

The controller's child `EsmHumanoidActor` holds the same `ActorReference`
instance indexed by `NpcSimulationServer`. Inventory and equipment changes are
made through the shared reference/inventory resources and notify
`EsmHumanoidActor` to refresh visually. Neither the controller nor
`EsmHumanoidActor` maintains a copied physical inventory.

## Physical check-in

Before a physical host's navigation regions or semantic cell root are removed,
the streamer checks in and destroys every NPC it checked out for that area.

Check-in and check-out are execution handoffs, not data handoffs. All actor
state lives on `ActorReference` and only there; `NpcController` reads and
writes that same instance directly while it is checked out, so there is
nothing to copy out when the lease ends. The streamer destroys the controller
after check-in; the package runner resumes advancing the still-shared reference
when allowed.

```text
streamer              → request check-in for each physical NPC in the area
NpcSimulationServer   → clear physical lease; re-index current spatial state;
                         resume low-level simulation when allowed
streamer              → destroy NpcController, collision, NavigationAgent3D,
                         and visual actor
```

The check-in order is intentional:

```text
check in NPCs → free semantic cell host
```

## Space traversal and physical navigation

NSS retains a global traversal graph of spaces and space-qualified vectors.
It has no NAVM triangles, navmesh polygons, `NavigationServer3D` maps, links,
or physical navigation paths. Those remain entirely in the checked-out
controller/streamer tier.

**Rejected alternative:** OpenMW keeps any actor running an AiTravel package
permanently active (full AI/physics/pathing, no distance falloff) rather than
approximating distant travelers, specifically to avoid landing/consistency
problems (`actors processing range` setting, `docs/.../game.rst`). That does
not fit here: WastelandNV's exterior NAVMs alone are 608,609 triangles across
4,260 records (`navmesh_esm_census.md`), and we assume `NavigationServer3D`
was never meant to carry that much always-resident geometry for actors
nobody is near. New Vegas itself also clearly doesn't need an always-active
carve-out for its own Travel packages to work at range, which is further
evidence the original engine has a genuine lower-fidelity background tier,
not just active/frozen. So the point-cloud/vector-leg design stays, even
though it's more machinery than OpenMW needed for its own constraints.

Each directed `XTEL` produces one portal relationship:

```text
(source space, source REFR.DATA Vec3) ── 0 distance ──>
(destination space, XTEL destination Vec3)
```

The destination REFR FormID identifies the destination space; the XTEL
destination vector is already parsed as `dest_position`. The two vectors are
only meaningful in their respective relative coordinate spaces. NSS
therefore calculates distance only between vectors in the same space:

```text
actor Vec3 in A → portal source Vec3 in A          = Euclidean distance
portal source Vec3 in A → destination Vec3 in B    = 0
portal destination Vec3 in B → next Vec3 in B      = Euclidean distance
```

A route's cost is the sum of those same-space vector legs. Portal transitions
exist only to join spaces; they are not Godot navigation links, physical
waypoints, traversable segments, door interactions, loading transitions, or
elapsed time. `NAVI`/`NAVM` data is not an NSS input or responsibility.

The player is not a party to check-in/check-out at a door. Interacting with a
door loads the target cell through the existing streamer/`CellLoader` path,
independent of `NpcSimulationServer`. Check-in and check-out are purely about
whether an NPC is in the low-level simulation or in the game: checked out
means physically present with a controller, checked in means simulated only.

An NPC's check-out is gated solely on target-host residency, not on crossing
order: an NPC that walks through the door before the player is checked in to the new space
until the player's own interaction puts them in the space and makes the target host resident, at which point it checks out into the now-loaded cell. 
An NPC arriving after the player is already checked out immediately, since the host is already resident. Either way, the source host is not checked in and freed until
nothing still needs it, per the streamer's ordinary residency lifecycle.

## Initial implementation boundary

The first implementation remains GDScript and runs on the main thread. The
simulation uses event-driven or low-frequency game-time updates rather than
per-frame nodes. A later native implementation may preserve the same public
server API and state transitions if profiling warrants it. threading is 
preferred but may cause issues updating the shared ActorReference resources 



## Dependencies and deferred work

- Typed `PackageBase` fields: `PKDT`, locations, schedule, targets,
  conditions, package-specific data, and scripts.
- Effective NPC package-stack resolution through `TPLT` and ACBS template
  flags.
- Script/quest evaluation for `CTDA` and package scripts. Until this lands,
  normal package-stack selection must not ignore unavailable conditions or
  package scripts and select a later package as though the earlier package
  were false.
- The global portal graph itself: build it from door `REFR` `XTEL` links
  (already parsed by `EsmFile`) at startup rather than new ESM parsing. 
  
  
- Typed NAVM/NAVI data and navigation-region parsing only for the physical tier.

- Cache of generated portal graph in usr directory if needed. keyed by master esm
  
- `NpcController`, the physical-actor node type hosting collision, movement,
  `NavigationAgent3D`, and a child `EsmHumanoidActor`; replaces the interim
  bare-`EsmHumanoidActor` spawn path in `EsmReferencePhysicaliser`. Local
  interaction/combat systems and inventory mutation notifications land here
  too.
  
- `WorldStreamerV2`/`CellStreamerV2` API for region residency queries and
  reference check-out/check-in, replacing today's direct
  enumerate-and-physicalise pipeline.
  
- `EsmServer` dirty marking, dirty-reference-overlay persistence and rehydration on restart.
- Not now: sampling interior NAVM triangles for more accurate in-space
  routing/landing than a straight-line vector. Interiors are cheap enough
  (95,896 triangles total across 651 records, vs. 730,736 exterior) that
  this is plausible later, but it's not needed to get v1's Follow package
  working.
- Not now: coarse navigation blockers for the exterior point-cloud tier
  (e.g. mountains, impassable terrain), so the straight-line distance
  approximation for virtual worldspace travel stops cutting through terrain
  it can't actually cross. Accepted as a known approximation for v1.
- Not now: DOOR `FNAM` "Minimal Use" (14 DOOR bases in `FalloutNV.esm`) is an
  NPC routing preference for portal selection. Sliding (51) and Hidden (3) do
  not affect routing.
- Not now: seeding in the running game. `NpcSimulationServer` is an autoload
  but seeds only when `seed()` is called; `game.gd` does not call it, so the
  running game has no simulated actors, routes or portals.
