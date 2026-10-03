# Actors

**Status: proposed.**

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
- **Bases.** `NpcBase` and `CreatureBase` stay separate: their fields differ and their ACBS flags
  differ. A shared parent only if stage A finds enough shared fields.
- **One actor node** renders NPCs and creatures: skeleton (`MODL`), skinned parts bound to it,
  animation. Parts come from RACE for an NPC_ and from `NIFZ` (relative to `MODL`'s folder,
  through `TPLT` when templated) for a CREA. A humanoid layer adds head, hair, eyes and worn
  equipment; creatures do not wear clothing (unverified).
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

## Facts

- CREA `NIFZ` (xEdit "Model List"): 1,059 of 1,578 CREA in FalloutNV.esm; 468 of the rest are
  templated; about 51 are audio templates or spawn markers.
- PACK: 4,163 in FalloutNV.esm, each with `PKDT` and `PSDT`; 2,992 CTDAs; types by count in
  `Plans/Navigation/navmesh_esm_census.md`. `NPC_.PKID` lists an NPC's packages in order.
- The couch trigger, SCPT 001055B4: when `player.IsCurrentFurnitureRef DocMitchellCouchREF`, with
  objective 40 displayed and not completed, it completes objective 40 and sets `VCG01.bGiveTest`.
  Doc's script (SCPT 00105BCB) checks `bDocInChair`.
- Stage 110 runs `DocMitchellREF.evp` to walk Doc to the exit; `GSDocMitchellExitTriggerScript`
  sets 115 when the player enters the exit trigger at 110; PACK 00105BD1 is Doc's force-greet.

## Stages

Each stage has a gate; a later stage does not start on an unmet gate.

| Stage | Work | Gate |
|---|---|---|
| A. Census | VCG01's and Goodsprings' NPCs: their PKID packages, types and data; the IDLE records VCG01 plays; FURN records and the furniture marker data in their NIFs; the ACHR/ACRE and NPC_/CREA subrecords shared and not. | Field lists for B and the package types for H, from counts over the whole population. |
| B. References | Abstract `ActorReference`, `NpcReference`, `CreatureReference`; shared fields moved to the base; every caller of today's `ActorReference` checked for NPC versus any actor. | The field list agreed first. Inventory, actor values and every resolved link still show in the inspector; the full test suite passes. |
| C. Actor node | Split `EsmHumanoidActor` into the shared actor node (skeleton, parts, animation) and its humanoid layer; the parts source per type; the physicaliser routes actors to it. | Doc Mitchell renders and animates as today. |
| D. NpcController | Movement, ground contact and following a navmesh route, cheaper than `PlayerController`; tells the actor node how it is moving. `PlayerController` does the same for the possessed actor. | An NPC walks a route across GSDocMitchellHouse; the player and the NPC animate from their controllers. |
| E. Ownership | An actor is virtual (`NpcSimulationServer`) or local (`NpcController`); check-out and check-in hand position and package state over; a disabled actor is frozen in both; script moves win over both; the server seeds in the running game. | An NPC leaving the loaded area continues virtually and returns where the server put it. |
| F. Animation | Locomotion from the controller's movement; furniture enter, sit and exit; `PlayIdle` from IDLE records; `Look` / `StopLook`. | Doc plays VCG01's idles and looks at the player. |
| G. Furniture | FURN markers; entering and leaving a seat for the player and for NPCs; `IsCurrentFurnitureRef`, `GetSitting`. | The player sitting on the couch completes objective 40. |
| H. Packages | Typed `PackageBase`; the package stack (PKID, quest-added); selection by order, schedule and conditions; `evp`; the types A names, expected to include Travel, Use Item At or Sandbox, and Dialogue. Generic over actors, in both `NpcController` and `NpcSimulationServer`. | The done-condition. |
| I. Positional voice | Speech plays at the speaker's actor node. | Doc's lines come from Doc. |
| J. Creatures | CREA parts from `NIFZ`/`TPLT` through the actor node; creatures through D-H unchanged. | A Goodsprings creature renders, animates and runs its packages. |

## Unverified

- That creatures cannot wear clothing.
- Which package type puts Doc in his chair.

## Out of scope

- Wielding weapons, for NPCs and creatures alike: one WEAP resource serves both, added later on
  the generic actor.
- Combat, detection and AI combat styles.
- FaceGen, lip sync and the dialogue camera.
- Inventory and container UI.
