# Godot / New Vegas Engine Replacement — Project Roadmap

**Scope:** Load and play the base game (Fallout: New Vegas + official DLC) using original,
user-owned assets. No NVSE compatibility, no third-party mod support, no Construction Set
replacement. Those are explicitly out of scope until the base title is fully playable.

**Model:** Clean-room reimplementation, in the spirit of OpenMW — read Bethesda's file
formats and reproduce observed runtime behavior; never redistribute or embed original
assets or code.

**Target:** Godot **4.7.1**, pinned for all implementation work. Use the native
standalone Linux binary (`tools/Godot_v4.7.1-stable_linux.x86_64`), not the
system-installed flathub flatpak — the flatpak's bundled runtime has an older glibc
than this host's compiler targets, which breaks loading host-built GDExtension
libraries. See [native/README.md](native/README.md) for details. Heavy use of
GDExtension (C++) for format parsing and performance-critical systems, GDScript/C#
reserved for game-logic glue.

**Reference game copy:** a full legally-owned install lives in this project directory
at `fresh_nv_copy/` (`fresh_nv_copy/Data/` contains `FalloutNV.esm`, all base-game
BSAs, and all DLC/bonus-pack `.esm`+`.bsa` pairs — Dead Money, Honest Hearts, Old
World Blues, Lonesome Road, Gun Runners' Arsenal, Caravan Pack, Classic Pack, Mercenary
Pack, Tribal Pack). All Phase 0+ tooling should point at this copy directly rather than
a placeholder path.


## Current status (October 2026)

| Phase | State |
|---|---|
| 0 Groundwork | Done |
| 1 Static world rendering | Done |
| 2 World streaming and scale | Done: interior and continuous exterior streaming, terrain, distant LOD |
| 3 Actors, skeletons, animation | Done for NPCs: skinned assembly, equipment, hair colour, FaceGen geometry, locomotion and idles. Creatures: `Plans/Actors/creatures.md` |
| 4 Actor runtime | Done: actor references and bases, inventory, actor values, packages, furniture use |
| 5 Scripting VM | In use: result and object scripts, conditions, quest stages; many functions still unimplemented |
| 6 AI and combat | AI packages (Travel, Dialogue, Follow) on and off screen through `NpcSimulationServer`; no combat |
| 7 Dialogue, quests, UI | Dialogue with voice, quests and objectives, terminals, message boxes; no Pip-Boy or inventory UI |
| 8 VATS | Not started |
| 9 Save/load | Not started (`Plans/Saving/reference_persistence.md`) |
| 10 Content pass | Not started; the opening quest VCG01 plays start to finish |
| 14 Physics | Physics items that can be picked up, and the player controller |

Work in progress is planned in `Plans/`; finished plans are in `Plans/Completed Plans/`.

---

## Phase 0 — Groundwork (foundational, no gameplay) — done

Goal: prove the toolchain and pipeline before committing to engine work.

- Stand up GDExtension build scaffolding (SCons/CMake) for native modules.
- Vendor or reimplement a BSA reader (archive listing + decompression).
- Vendor or reimplement an ESM/ESP parser sufficient to read `FalloutNV.esm` records
  (start with GRUP/record/subrecord framing — the format is well documented via xEdit).
- Integrate a NIF parser (evaluate `nifly` first — clean-room, C++, active — before
  writing one from scratch) and get static mesh geometry + UVs out of a single `.nif`.
- DDS → Godot texture import path (Godot already reads DDS; confirm BC1-7/compressed
  variants used by FNV work with Godot's importer, patch if not).
- **Exit criterion:** a standalone tool that unpacks a BSA, finds a known mesh, and
  dumps it to glTF or a Godot-native mesh resource for manual inspection.

## Phase 1 — Static World Rendering — done

Goal: walk a single exterior cell with correct geometry, textures, and collision. No
NPCs, no AI, no scripting, no combat. Interior cells were sequenced before
exterior/terrain.

- Extend the ESM parser to read `CELL`, `WRLD`, `LAND` (landscape/heightmap + texture
  splatting), and `REFR` (object placement/reference) records.
- Build a Godot-side loader that, given a cell ID, instances static meshes at their
  `REFR` transforms using the Phase 0 NIF pipeline.
- Implement landscape terrain generation from `LAND` records (heightmap + quadrant
  texture blending) — Godot has no built-in equivalent, this is custom.
- Collision: derive Godot collision shapes from NIF collision data (`bhkCollisionObject`
  / `bhkRigidBody` nodes) or convex-hull fallback from render meshes.
- Basic free-fly/no-clip camera controller — not the real player controller yet.
- **Exit criterion:** load into a real FNV exterior cell (e.g. Goodsprings) and an
  interior cell (e.g. Doc Mitchell's house) with correct static geometry, textures,
  and walkable collision, using only original game assets at runtime.

## Phase 2 — World Streaming & Scale — done

Goal: move continuously through the game's actual worldspace, not one cell at a time.

- Implement adjacent-cell loading/unloading for exterior worldspace grid cells based
  on player position (Bethesda's cell grid is fixed-size and enumerable from `WRLD`
  data — no discovery heuristics needed).
- Interior↔exterior transitions via door `REFR`/`DOOR` teleport links. Exterior grid
  cells also load their owning worldspace's "persistent" cell (the CS's always-loaded
  bucket, holding e.g. every exterior-facing entrance door in the base game). Not
  loading that cell at all was a known gap, since fixed.
- Distant terrain / object LOD (FNV ships pre-baked LOD meshes and distant land data —
  reuse them rather than generating LOD at runtime, at least initially).
- Memory budget and streaming radius tuning against the real Mojave worldspace size.
- **Exit criterion:** walk from Goodsprings to Primm without load screens beyond the
  intended interior transitions, at a stable frame rate.

## Phase 3 — Actors, Skeletons, Animation

Goal: NPCs and the player exist in the world and animate, but are inert (no AI, no
combat, no dialogue yet).

- Skeleton/skinning support: map Gamebryo bone hierarchies (`NiSkinInstance`) to Godot
  `Skeleton3D`, including the biped rig used by player/NPC models.
- KF/animation data parsing (New Vegas anim data is embedded/associated NIF-adjacent
  animation — confirm exact container format) and playback via `AnimationPlayer`.
  Confirmed directly (not assumed) that this phase should start with the simpler,
  non-skeletal case: physical (non-teleporting) doors use a dedicated "Animated" model
  variant (e.g. `NVCraftsmanRmDoorAnimated.NIF`, vs. plain `NVCraftsmanRmDoor.NIF` for a
  teleporting door at the same base type) carrying real `NiControllerManager`/
  `NiControllerSequence`/`NiTransformInterpolator`/`NiTransformData` keyframe blocks —
  rigid single-node transform animation, no `NiSkinInstance`/bone hierarchy, so it
  doesn't need skeleton/skinning support to land first. **Done** —
  `DoorNode.activate()` now plays real animation, sounds, and flags for
  non-teleporting doors, with a mid-swing reactivation debounce.
- Equipment/armor mesh swapping on the skeleton (the "nif per body part + biped slot"
  model FNV uses).
- NPC appearance foundation: typed `NPC_`/`RACE`/`HAIR`/`EYES` resources, real race-selected
  head/body assembly, per-NPC EGM/`FGGS` static geometry, and real `.tri` facial morph targets
  converted to Godot `ArrayMesh` blend shapes. Facial animation drivers and EGT/`FGTS` texture
  synthesis remain follow-up work. A dedicated NPC facial controller now exposes the authored
  TRI phoneme/expression names and bounded runtime morph animation; the real humanoid head-KF
  census found bone-only tracks and no morph-weight tracks, while neither shipped human nor ghoul
  TRI contains an eyelid/blink target. Authored facial clip mapping and blink source remain open
  data-verification work.
- Basic third-person player controller: movement, jump, camera collision — using
  Jolt-backed `CharacterBody3D`.
- Spawn NPC actors from `NPC_`/`ACHR` records at their placed positions, idle-animated,
  no behavior.
- **Exit criterion:** player character walks/runs/jumps with correct animation, and a
  handful of NPCs stand in Goodsprings correctly skinned and animated.

## Phase 4 — Actor Runtime & Gameplay Composition

Goal: turn the Phase 3 visual actor foundation into a composable runtime actor model.

- Shared actor data/resources for identity, actor values, factions, effects, and templates.
- Shared inventory composition for actors and `CONT` containers, including item ownership and
  equipment state.
- Equipment/body-part swapping against the real biped slots and actor animation state.
- AI package data loading and a first package-scheduling interface; full navigation and behavior
  execution remains Phase 6.
- Runtime actor state and interfaces for dialogue, scripting, and persistence without coupling
  those systems into the scene inheritance tree.
- Global quest/session state separate from actor ownership; actors carry only transient quest
  participation context, preserving a shared authoritative state model for co-op.
- Player control, camera, first-person presentation, and gameplay actions as a detachable
  possession layer over any actor, preserving an eventual co-op path.
- Treat the current `Character` in `game.tscn` as the movement/control feel harness, not as the
  permanent player-character class.
- Basic actor movement integration where required by the runtime model; inert visual actors remain
  a valid milestone while movement is being built.
- **Exit criterion:** an NPC has real composed inventory/stats/animation state, can select a real
  package through the actor runtime interface, and remains ready for Phase 5 scripting and Phase 6
  AI execution.

Phase 4 implementation begins after the remaining Phase 3 world/actor foundation work is complete;
its ownership boundaries are documented now to guide that work safely.

## Phase 14 — Physics & Havok-Equivalent Behavior

Goal: dynamic physics objects behave like they do in the original.

- Ragdoll on actor death using Jolt constraints mapped from `bhkRagdollConstraint`
  data in NIFs.
- Dynamic/loose physics objects (bottles, debris) driven by `bhkRigidBody` mass/
  friction/restitution values.
- Projectile physics for ballistic weapons (arcing rounds, explosives) — needed before
  combat in Phase 6.
- **Exit criterion:** shootable/kickable physics props in a test cell match observed
  original-game behavior (mass, bounce, settle) closely enough to be unremarkable.

## Phase 5 — Scripting VM

Goal: the base game's scripted behavior (quest state machines, triggers, scripted
objects) executes correctly. This is the largest single undertaking after world
streaming.

- Reverse/document the GECK script bytecode format as compiled into `.esm` (script
  records `SCPT`), independent of NVSE extensions.
- Implement an interpreter covering the base-game function set only (no NVSE opcodes).
- Implement the core event/callback model scripts rely on (OnLoad, OnActivate,
  OnHit, GetStage, SetStage, quest stage triggers, etc.).
- Wire script execution into world objects, quests, and dialogue (Phase 7 depends on
  this being functional first).
- **Exit criterion:** a self-contained base-game quest with no DLC/mod dependencies
  (e.g. an early Goodsprings quest) advances through its stages correctly from
  triggers alone.

## Phase 6 — AI & Combat

Goal: NPCs behave, fight, and path correctly.

- Navmesh: FNV ships precomputed navmeshes per cell (`NAVM` records) — parse and
  convert to Godot's `NavigationMesh` rather than autogenerating.
- Package/AI scheduling system (Radiant AI subset): travel, sandbox, sleep, combat
  packages tied to NPC schedules.
- Faction and reputation-driven aggression/disposition checks.
- Hitscan and ballistic combat, damage resolution, death behavior (hooking into
  Phase 14 ragdolls).
- **Exit criterion:** an NPC follows its default schedule, notices and engages a
  hostile target using faction rules, and dies correctly.

## Phase 7 — Dialogue, Quests, UI

Goal: the game is actually playable as an RPG, not just walkable.

- Dialogue tree parsing (`DIAL`/`INFO` records) and a dialogue UI, including
  conditionalized responses (script condition evaluation, dependent on Phase 5).
- Voice file playback synced to dialogue selection (lip-sync is a stretch goal, not
  a blocker — subtitles-first is acceptable).
- Quest log / journal UI reflecting `QUST` stage data.
- Core HUD: health, AP (for VATS groundwork), compass, inventory screen.
- **Exit criterion:** play the opening sequence through the first quest hand-off in
  Goodsprings start-to-finish using dialogue, without developer shortcuts.

## Phase 8 — VATS & FNV-Specific Systems

Goal: close the gap on the systems that make FNV distinct from a generic shooter-RPG.

- VATS targeting: hit-chance calculation, body-part targeting, time-dilation/camera
  sequence, AP cost and consumption.
- Companion wheel and companion command system.
- Hardcoe mode systems (needs, ammo weight, stimpak healing-over-time) — optional/
  toggleable, but should be modeled since it affects base-game balance data.
- Weapon mod attachment system (base-game weapon mods only).
- **Exit criterion:** VATS is usable in combat with correct hit-chance math and visual
  sequencing.

## Phase 9 — Save/Load & Persistence

Goal: sessions persist correctly — this can start earlier in parallel but must be
solid before calling the base game "complete."

- Runtime object/actor/quest-state serialization (does not need to read original
  `.fos` save format — a native save format is acceptable since mod compatibility
  is out of scope).
- World state deltas (moved/destroyed objects, opened containers, dead NPCs) persisted
  per cell.
- **Exit criterion:** save mid-quest, reload, and all world/quest/inventory state is
  identical to pre-save.

## Phase 10 — Full Base-Game Content Pass

Goal: everything from Phases 1–9 holds up across the entire Mojave, not just test
cells.

- Full worldspace + all interiors load and stream correctly.
- All base-game quests completable start to finish.
- All four DLCs (Dead Money, Honest Hearts, Old World Blues, Lonesome Road) load and
  are completable, since they ship as additional `.esm` masters using the same
  formats already supported.
- Performance pass: target frame rate parity or better vs. original on comparable
  hardware.
- **Exit criterion:** a full unassisted playthrough, main quest + all DLC, with no
  known blocking bugs.

---

## Explicit non-goals (revisit only after Phase 10)

- NVSE / xNVSE opcode compatibility.
- Loading third-party `.esp` mod plugins.
- GECK/Construction Kit replacement or editing tools.
- Load-order or plugin-conflict resolution.
- Multiplayer.

## Cross-cutting risks worth tracking from day one

- **NIF/animation coverage gaps:** New Vegas uses a specific Gamebryo NIF version;
  confirm early which node/controller types actually appear in FNV's data (vs. the
  wider NIF spec other games use) so parser scope stays bounded.
- **Script bytecode reverse-engineering is the critical path.** Everything in Phases
  6–8 depends on Phase 5 landing solidly — prioritize spending real time here before
  committing to combat/AI work.
- **Terrain/LOD data formats are under-documented** compared to NIF/ESM — budget
  extra research time in Phase 2.
- **Team size vs. scope:** OpenMW took a sustained multi-contributor team roughly a
  decade to reach "generally playable" for a simpler game. Re-scope phase timelines
  once real contributor bandwidth is known rather than assuming a fixed calendar.
