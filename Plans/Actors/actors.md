# Actors

**Status: stages A, B, C and D done (E's ownership built during D, creatures aside); stage H next, see `stage_h.md`.**

Actor references, one actor node, an NPC controller, ownership between the simulation server and
the controller, animation, furniture and AI packages. Done when a new game plays VCG01 from stage
80 to stage 200 with no console: Doc walks to his chair and sits, the player sits on the couch and
its trigger starts the Rorschach test, and Doc walks to the exit and force-greets the player at
the door.

## Decisions

- **References.** `ActorReference` is the abstract actor reference (Gamebryo's Actor), holding
  the state every actor has: inventory, actor values, use state, package state, health, alive.
  `NpcReference` (ACHR) and `CreatureReference` (ACRE) extend it. Today's `ActorReference` is the
  NPC one and becomes `NpcReference`.
- **Bases.** An abstract `ActorBase` holds the 20 subrecords NPC_ and CREA share with the same
  meaning (census A1). `NpcBase` and `CreatureBase` extend it, each reading its own DATA, RNAM,
  PNAM, CNAM, NAM5 and LNAM (same signatures, different meanings) and its own-type subrecords,
  and naming the ACBS flags its own way.
- **Hierarchy.** Each reference type pairs with its base type; generic code works on
  `ActorReference` and `ActorBase` only.

  ```
  EsmReference
  └── ActorReference         abstract: ACHR/ACRE shared fields, inventory, actor values, use and package state
      ├── NpcReference       ACHR; base is an NpcBase
      └── CreatureReference  ACRE; base is a CreatureBase; adds XOWN ownership

  EsmBase
  └── ActorBase              abstract: the 20 subrecords NPC_ and CREA share
      ├── NpcBase            DATA, RNAM race, PNAM head parts, CNAM class, DNAM, hair, eyes, FaceGen
      └── CreatureBase       DATA, RNAM attack reach, PNAM body part data, CNAM impact dataset, NIFZ, sounds
  ```
- **One actor node** renders NPCs and creatures: skeleton (`MODL`), skinned parts bound to it,
  animation. Parts come from RACE for an NPC_ and from `NIFZ` (relative to `MODL`'s folder,
  through `TPLT` when templated) for a CREA; for an NPC_ they include head, hair, eyes and worn
  equipment. The node asks the base for its parts list and runs the same pipeline for both; there
  is no second node or subclass. Creatures do not wear clothing (unverified).
- **Controllers.** `PlayerController` keeps its collision and motion, which are too expensive per
  NPC. `NpcController` is a cheaper controller for physicalised NPCs and creatures. Both have the
  actor node as a child and tell it how the actor is moving, for animation.
- **Generic actors.** Package processing (`NpcController` locally, `NpcSimulationServer` at low
  level), furniture, dialogue, inventory, weapons and look work on the abstract actor reference
  and never branch on NPC versus creature. Creatures can do nearly everything an NPC can:
  inventory, wielding weapons, dialogue, look.
- **Creatures come late.** NPCs first; creatures render through the node in the last stage, with
  everything before it already generic.
- **State on resources.** Actor state lives on the reference resources, never on nodes; nodes
  exist only for physicalised actors.

## Stage C design

The actor node keeps the lifecycle, the editor buttons and the order of the steps: ask the base
for its parts list, request the NIFs, assemble, commit. Everything else is a child node in the
actor template scene, so every script shows in the scene graph:

| Child node | Owns |
|---|---|
| `ActorSkinning` | binding skinned parts to the skeleton, compacting external skin parts |
| `ActorAnimator` | the AnimationPlayer / AnimationTree and KF loading; later the controller's movement (D) and `PlayIdle` (F) |
| `ActorEquipment` | equipment attachments and body coverage, reading the reference's `EsmActorEquipmentState` |

The parts list comes from the base: NpcBase lists its RACE body parts, head, hair and eyes;
CreatureBase its NIFZ (stage J). Construction and animation profiling are removed, to be rebuilt
later if needed. Actor state stays on resources; these nodes are presentation only.

## Facts

- CREA `NIFZ` (xEdit "Model List"): 1,059 of 1,578 CREA in FalloutNV.esm; 468 of the rest are
  templated; about 51 are audio templates or spawn markers.
- PACK: 4,163 in FalloutNV.esm, each with `PKDT` and `PSDT`; 2,992 CTDAs; types by count in
  `Plans/Navigation/navmesh_esm_census.md`. `NPC_.PKID` lists an NPC's packages in order.
- The couch trigger, SCPT 001055B4: when `player.IsCurrentFurnitureRef DocMitchellCouchREF`, with
  objective 40 displayed and not completed, it completes objective 40 and sets `VCG01.bGiveTest`.
  Doc's script (SCPT 00105BCB) checks `bDocInChair`.
- Stage 110 runs `DocMitchellREF.evp` to walk Doc to the exit; `GSDocMitchellExitTriggerScript`
  sets 115 when the player enters the exit trigger at 110. PACK 00105BD1 (Travel) walks Doc to the exit; PACK 00105BD2 (Dialogue, stage >= 115) is his force-greet.

## Stages

Each stage has a gate; a later stage does not start on an unmet gate.

| Stage | Work | Gate |
|---|---|---|
| A. Census (done) | VCG01's and Goodsprings' NPCs: their PKID packages, types and data; the IDLE records VCG01 plays; FURN records and the furniture marker data in their NIFs; the ACHR/ACRE and NPC_/CREA subrecords shared and not. | Field lists for B and the package types for H, from counts over the whole population. |
| B. References (done) | Abstract `ActorReference`, `NpcReference`, `CreatureReference`; shared fields moved to the base; every caller of today's `ActorReference` checked for NPC versus any actor. | The field list agreed first. Inventory, actor values and every resolved link still show in the inspector; the full test suite passes. |
| C. Actor node (done) | `EsmHumanoidActor` becomes the one actor node: its skeleton, skinning and animation code separated from the NPC_-specific parts selection (RACE parts, hair, eyes, equipment), which the base supplies as its parts list; the physicaliser routes every ActorReference to it. | Doc Mitchell renders and animates as today. |
| D. NpcController | Movement, ground contact and following a navmesh route, cheaper than `PlayerController`; tells the actor node how it is moving. `PlayerController` does the same for the possessed actor. | An NPC walks a route across GSDocMitchellHouse; the player and the NPC animate from their controllers. |
| E. Ownership | `EsmServer.get_all_placed_actor_references()` (the server's seed list) widened from ACHR to ACRE; an actor is virtual (`NpcSimulationServer`) or local (`NpcController`); check-out and check-in hand position and package state over; a disabled actor is frozen in both; script moves win over both; the server seeds in the running game. | An NPC leaving the loaded area continues virtually and returns where the server put it. |
| F. Animation | Locomotion from the controller's movement; furniture enter, sit and exit; `PlayIdle` and package idles from IDLE records (VCG01's are loose special idles played by name; the idle tree is not needed); `Look` / `StopLook`. | Doc plays VCG01DocGiveMirror and NPCSmokingIdle, the player plays the VCG01 wake-up idles, and Doc looks at the player. |
| G. Furniture | Plan: `stage_g.md`. FURN markers; entering and leaving a seat for any actor, NPC, creature or the player: sitting is the actor's state (`ScriptServer.begin_use`, `ActorReference.using`), not a controller's; controllers only stop moving while it is set, and the actor node plays the furniture animations; `IsCurrentFurnitureRef`, `GetSitting`. | The player sitting on the couch completes objective 40. |
| H. Packages | Plan: `stage_h.md`. First slice done early (stage D): FOLLOW through `PackageRunner` and `LowLevelTravel`, `AddScriptPackage` / `RemoveScriptPackage`; see `stage_d.md`. Typed `PackageBase`; the package stack (PKID, quest-added); selection by order, schedule and conditions; `evp`; Travel (using furniture at a radius-0 FURN destination, as Use Item At does) and Dialogue (force-greet), per census A3; `AddScriptPackage` / `RemoveScriptPackage`; packages on the player too (VCG00/VCG01 add them). Generic over actors, in both `NpcController` and `NpcSimulationServer`. | The done-condition. |
| I. Positional voice | Speech plays at the speaker's actor node. | Doc's lines come from Doc. |
| J. Creatures | CREA parts from `NIFZ`/`TPLT` through the actor node; creatures through D-H unchanged. | A Goodsprings creature renders, animates and runs its packages. |

## Unverified

- Saving a dirty base whose resolved links form a cycle (a CREA inheriting sounds from a creature
  that inherits back, a template chain, a form list containing itself). Building is safe:
  `get_base` caches a resource before resolving its links, so a cycle reuses one instance. Such
  cycles are never freed (reference counting), which is harmless while EsmServer's cache holds
  every base, but `ResourceSaver` on a cyclic graph reports cyclic resource inclusion. Check when
  dirty bases are saved. Placed references avoid cycles altogether by resolving on demand.

- That creatures cannot wear clothing.

## Out of scope

- Wielding weapons, for NPCs and creatures alike: one WEAP resource serves both, added later on
  the generic actor.
- Combat, detection and AI combat styles.
- FaceGen, lip sync and the dialogue camera.
- Inventory and container UI.
