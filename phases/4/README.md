# Phase 4 — Actor Runtime & Gameplay Composition

Parent: [ROADMAP.md](../../ROADMAP.md)

Goal: turn the Phase 3 visual actor foundation into a composable runtime actor model.

Design doc: [base-reference-architecture.md](base-reference-architecture.md) — the
Base/Reference split for ESM records (formalizes and supersedes this README's own
"Typed ESM resource references" and "Equipment visual handoff" sections below).

This phase establishes shared actor state and component boundaries so inventory, equipment,
stats, AI packages, dialogue, effects, scripting, and persistence can attach to actors without
turning every concern into another inheritance branch.

## Composition decision

Actors use composition rather than inheriting from `ContainerNode` or from any other gameplay
system:

```text
GamebryoActor
├── ActorData / ActorValues       (shared actor state)
├── Inventory                     (also used by ContainerNode)
├── Equipment                     (actor-owned equipped item state)
├── ActorAnimationComponent       (Skeleton3D / animation runtime)
└── Dialogue / Effects interfaces (references to shared data and services)
```

The inheritance tree remains structural and deliberately small:

```text
GamebryoObject
├── GamebryoVisual
│   └── ContainerNode
└── GamebryoActor
    ├── NPCActor       (NPC_ record source)
    └── CreatureActor  (CREA record source)
```

`TESPackage`, factions, quests, dialogue records, and effects are data resources or referenced
graphs; an external `NPCController` interprets packages and drives the actor at runtime. `Inventory` is the shared
capability, not the superclass: an actor and a `CONT` both own inventory while remaining separate
object types. Components should be introduced when backed by a real shared behavior or state
boundary, rather than as empty wrappers for every ESM subrecord.

Controllers are parent/owner nodes, not actor children. An `NPCController` or `PlayerController`
owns or possesses a `GamebryoActor`; the actor supplies embodiment and runtime components, while
the controller supplies thinking or input. This allows a `CREA` Super Mutant to be a companion,
talker, or questgiver without changing its record-source class. Humanoid versus creature is an
appearance/skeleton assembly contract: a `CreatureActor` may compose `HumanoidAssembly` when its
real assets support that contract.

### Typed ESM resource references

ESM records will be represented as typed Godot `Resource` objects and passed into actor nodes,
rather than flattened into ad-hoc node variables. A referenced record resolves to its own resource:
`NpcRecord.hair` is a `HairRecord`, whose own `form_id`, editor ID, model, texture, and flags are
authoritative. The original FormID relationship remains available for unresolved-reference
diagnostics, but normal consumers should use the typed resource rather than duplicate fields such
as `hair_form_id`. The same rule applies to race, eyes, class, packages, inventory records, and
other ESM references; the first implementation target is the Phase 3 NPC appearance path.

### Phase 3 appearance handoff

The NPC appearance foundation now consumes typed ESM resources and real race assets. Human and
ghoul heads use their matching EGM/`FGGS` static geometry basis, and their `.tri` files are parsed
into named Godot `ArrayMesh` blend shapes while preserving skinning, materials, and NPC-specific
static face geometry. The head `.tri` delta morphs are therefore ready for facial animation
drivers; the TRI statistical morphs and EGT/`FGTS` texture synthesis remain unimplemented until
their runtime relationship is verified. This is an appearance/data boundary, not actor AI,
dialogue, quest, or gameplay behavior.

The current NPC visual layer also exposes the real TRI phoneme/expression names through a separate
`FacialAnimationController` and reserved `FacialAnimationPlayer`. The verified humanoid head KF
samples contain bone transform tracks but no morph-weight tracks, so direct morph scheduling is
bounded and diagnostic until an authored facial-weight source is found. Both shipped human and
ghoul TRI files lack an eyelid/blink target; blink generation is intentionally deferred.

### Equipment visual handoff

The first equipment slice is resource-driven and inspector-selectable. `ArmorRecord` owns its
verified `BMDT` slot mask and gender-specific biped models; its `BipedModelListResource` resolves
linked `ArmorAddonRecord` resources, and `WeaponRecord` provides the third-person model. An
`EquipmentState` is supplied explicitly to `NPCActor`; `NPC_.CNTO` remains inventory
data and is not treated as worn equipment. Armor models bind to the NPC's shared `Skeleton3D`,
while an unskinned third-person weapon follows the authored right-hand bone through a
`BoneAttachment3D`.

Armor entries are ordered low-to-high priority. Overlapping `BMDT` masks keep the later record and
emit a diagnostic; NIF BSDismember partition IDs remain independent metadata and are not confused
with slot masks. The current body coverage pass hides only confirmed coarse nude-body roles
(upperbody/left hand/right hand/head); gore meshes remain controlled independently. Per-partition
clothing replacement and automatic equipment-state derivation are future work.

## Control and possession decision

The player is a control role assigned to an actor, not a separate actor class. A controlled actor
uses a player-input driver and owns the active camera and first-person view; an AI-controlled actor
uses an AI driver instead:

```text
NPCController / PlayerController
└── GamebryoActor
    ├── ActorData / Inventory / Equipment
    ├── ActorAnimationComponent
    └── HumanoidAssembly or CreatureAssembly
```

The controller drives movement, interaction, equipment, combat, and gameplay through the same actor
interface. Possession changes which controller and view are active; it does not change the actor's
fundamental type. This keeps the architecture compatible with eventual co-op: multiple local or
network player controllers can possess separate actors, while NPCs continue using the same actor
model with NPC controllers. Co-op networking is not Phase 4 scope, but avoiding a hard-coded
singleton `Player` actor here preserves that future option.

The current `Character` instance in `game.tscn` is a development harness for tuning first-person
input, collision, movement, jumping, and general controller feel. It is not the canonical player
actor or a competing actor type; its controller and view work should be transferable to whichever
`GamebryoActor` is currently possessed.

## Quest-state decision

Quest progression belongs to a global session/save-state service, not to an actor-owned component:

```text
GameSession / SaveState
├── QuestStateStore       (stages, objectives, variables, completion/failure)
├── WorldState
└── Players               (per-player inventory, skills, perks, choices)
```

Actors may carry transient participation context—quest aliases, relevant dialogue conditions, or
quest-driven package state—but they do not own quest progression. In co-op, the authoritative host
or server owns the shared `QuestStateStore`; clients replicate its changes, while genuinely
player-specific state remains under each player. This prevents multiple actors from independently
advancing or disagreeing about one global quest.

## Scope

- Shared actor data/resources for identity, actor values, factions, effects, and templates.
- Shared inventory composition for actors and `CONT` containers.
- Equipment/body-part swapping against real biped slots and animation state.
- AI package data loading and a package-scheduling interface; full navigation and behavior remain
  Phase 6 work.
- Runtime actor state and interfaces for dialogue, scripting, and persistence.
- Global quest-state/session boundaries, with actor participation represented as transient context.
- Basic movement integration where the runtime model requires it.

Phase 4 implementation follows completion of the remaining Phase 3 world/actor foundation work;
these boundaries are being recorded now so the next systems do not grow around the wrong ownership
model.

## Exit criterion

An NPC has real composed inventory, stats, and animation state, can select a real package through
the actor runtime interface, and is ready for Phase 5 scripting and Phase 6 AI execution.
