# ProjectileServer

The firing half of weapons: step 7 of [weapons.md](weapons.md). The request shape, muzzle and aim
point are in weapons.md, Firing. This file holds the data chain from a WEAP to what leaves the
muzzle, the census behind it, the server's shape, the fields to read, and the delivery order.

Census: FalloutNV.esm unless marked. DLC counts are from a pass over all ten masters that does not
remap master indices, so DLC cross-record links are unreliable; record counts and EditorIDs in it
are.

## The chain

```
WEAP ─ DNAM+36 Projectile ──────────────► PROJ ─ DATA+36 Explosion ─► EXPL ─ DATA+28 ─► IPDS ─► IPCT
  │    DNAM+42 Projectile Count             │                          │ EITM ─► ENCH
  │    DATA+12 Base Damage                  │ MODL  projectile model   │ MODL, MNAM (IMAD), INAM
  │    INAM ─► IPDS (bullet impacts)        │ NAM1  muzzle flash model
  └─ NAM0 ─► AMMO, or FLST of AMMO          │ DATA+20 muzzle flash LIGH
               DAT2+4 Projectile (override)─┘
               DAT2+0 Proj. per Shot (override)
               RCIL ─► AMEF (damage, DR, DT, spread, condition, fatigue mods)
```

- The projectile is the WEAP's: DNAM+36 names a PROJ on 173 of 261 WEAP. The ammo does not name
  it: AMMO DAT2+4 is NULL on 79 of 92 AMMO, absent (no DAT2) on 5.
- The ammo overrides it: 8 AMMO name a PROJ (slugs, bean bag, coin shot, HE/HV missiles, HE
  25mm, incendiary 40mm); 29 across the DLC masters. Of 341 weapon-ammo pairs in FalloutNV.esm,
  27 have an ammo PROJ and it always differs from the WEAP's; 314 have none.
- Proj. per Shot (AMMO DAT2+0) is 0 on 82 AMMO, 1 on 4, 8 on Ammo12GaCoinShot. Across the DLC it
  is also 4 on four buckshot AMMO with a NULL PROJ, and 5, 7 and 9 on others. `# ASSUMPTION` 0
  keeps the WEAP's Projectile Count, non-zero replaces it.
- NAM0: AMMO on 75 WEAP, an FLST of AMMO on 75 (1 to 5 entries, all AMMO), none on 111 (melee,
  hand to hand, grenades, mines, thrown).
- A WEAP with no NAM0 and a PROJ spends itself: 12 grenade throw, 4 land mine, 4 mine drop,
  3 thrown, plus WeapNVBallisticFist and EDEStunBaton.
- A WEAP with NAM0 and no PROJ: WeapNVEuclidsCFinder, NVCamera.
- Projectile Count (DNAM+42): 1 on 245; 7 on the shotguns, 14 on the sawed-offs, 3 on
  WeapNVMultiPlasRifle and WeapNVTriBeamLaserRifle, 5 on WeapPlasmaRifleAlwaysCrit, 0 on the two
  detonators and the binoculars.
- Damage: the WEAP's DATA+12 Base Damage, per projectile. Explosive PROJ add their EXPL's
  DATA+4 Damage. Ammo effects (RCIL ─► AMEF DATA: Type, Operation, Value) modify it: 58 of 92
  AMMO carry 1 to 4. Resistances, criticals and the damage formula are not in this server.

## PROJ (95; 145 with DLC)

DATA is 84 bytes on 78, 68 on 17 (no Rotation, no Bouncy Mult). Every PROJ has MODL, VNAM and
DATA; 66 have NAM1 (24 distinct muzzle flash models); 17 MODT; 25 DEST.

| Off | Field | Census |
|---|---|---|
| 0 | Flags u16 | Hitscan 29, Explosion 44, Alt. Trigger 59, Muzzle Flash 63, Can Be Disabled 7, Can Be Picked Up 11, Supersonic 34, Pins Limbs 2, Pass Through Small Transparent 19, Detonates 2, Rotation 5; bit 4 and bits 12–15 never set |
| 2 | Type u16 | Missile 56, Lobber 23, Beam 14, Flame 2; Continuous Beam 0 |
| 4 | Gravity | 0 to 20; 0 on 41, 1 on 26 |
| 8 | Speed | 0 to 60000. Hitscan bullets 7000–60000; Beam 5000 or 10000; Lobber 0–1800 |
| 12 | Range | 640 to 60000; 10000 on 73 |
| 16 | Light | NULL on all 95 |
| 20 | Muzzle Flash Light | set on 52 |
| 24 | Tracer Chance | 0.5 AutoTracerProjectile, 0.3 MinigunTracerProjectile, 0 on the rest |
| 28 | Alt. Trigger Proximity | 100 on the 7 mines and placed charges, 0.5 NellisMunitions |
| 32 | Alt. Trigger Timer | 2.5 grenades, 3.0 mines, 5.0 long fuse, 15 time bomb, 10 ARCHIMEDES II |
| 36 | Explosion | EXPL on 51 |
| 40 | Sound | set on 37 |
| 44 | Muzzle Flash Duration | 0 to 0.6 |
| 48 | Fade Duration | 0.5 on 81 |
| 52 | Impact Force | 0 to 50 |
| 56 | Sound Countdown | set on 11 |
| 60 | Sound Disable | set on 9 |
| 64 | Default Weapon Source | set on 15 (mines, C4, Tesla chain, Lakelurk, ARCHIMEDES II) |
| 68 | Rotation vec3 | non-zero on 26; Rotation flag on 5 |
| 80 | Bouncy Mult | 1 on 29, 0 on 33; on 8 (bullets, plasma, incinerator, Lakelurk) a value that is not a multiplier (-3100, 6100, 4.6e24). The field is not confirmed past +68 |

Type by flags:

| Type | Hitscan | Explosion | PROJ | Examples |
|---|---|---|---|---|
| Missile | yes | no | 26 | every bullet, buckshot, slug, BB, CameraFilm |
| Missile | yes | yes | 1 | GaussProjectile (GaussImpactExplosion, damage 0) |
| Flame | yes | no | 2 | FlameProjectile, FlameProjectileANT (range 640) |
| Missile | no | no | 13 | plasma, alien blaster, throwing knife, dart, sonic, Mesmetron |
| Missile | no | yes | 16 | missiles, 25/40mm grenades, Fat Man, incinerator, artillery |
| Lobber | no | yes | 22 | grenades, mines, C4 (Detonates), time bomb, dynamite |
| Lobber | no | no | 1 | TrapBaseballProjectile |
| Beam | no | no | 9 | every laser, pulse gun, Tesla chain |
| Beam | no | yes | 5 | ARCHIMEDES I, Tesla cannon and chain explosions |

- Hitscan is set on the bullets, flamers and the gauss rifle only. No Beam PROJ is hitscan: the
  lasers are Beam, speed 10000, range 10000.
- The Explosion flag and the Explosion field disagree on 7 PROJ: an Explosion set with the
  flag clear (NVHatchetProjectile and NVSpearProjectile → NVDynamiteExplosion; AntSpit and
  CentaurSpit → LargeExplosion; Tesla cannon; plasma caster; ARCHIMEDES II). `# ASSUMPTION` the
  flag decides whether the projectile explodes on impact.
- Alt. Trigger is set on 34 PROJ with timer and proximity 0 (every bullet and laser). Its meaning
  there is not known.

VNAM Sound Level: 1 on 90, 2 on 4, 0 on 1.

## EXPL (154; 213 with DLC)

DATA is 52 bytes on all. 41 are named by a PROJ; the rest by DEST stages and other records.

| Off | Field | Census (the 41 PROJ explosions) |
|---|---|---|
| 0 | Force | 0 to 10000 |
| 4 | Damage | 0 (gauss, Tesla cannon, plasma caster, gas) to 2000 (SatcomNuke); grenade frag 125, missile 200, Fat Man 600 |
| 8 | Radius | 40 to 1700 |
| 12 | Light | set on 98 of 154 |
| 16 | Sound 1 | set on 119 |
| 20 | Flags u32 | Radius in BS Units on all 154; Always Uses World Orientation 67; Knock Down Always 14, By Formula 48; Ignore LOS 20; Push Source Ref Only 2; Ignore Image Space Swap 130 |
| 24 | IS Radius | 0 to 100000 |
| 28 | Impact DataSet | set on 81 |
| 32 | Sound 2 | set on 94 |
| 36 | Radiation Level, Dissipation Time, Radius | level non-zero on 24 (Fat Man 10, SatcomNuke 100) |
| 48 | Sound Level | |

EITM (ENCH) on 22: incendiary, pulse, stun, Tesla chain, incinerator bursts. MNAM (IMAD) on 97.
INAM Placed Impact Object on none.

## Impacts

- WEAP INAM names an IPDS on 237 of 261 WEAP: the bullet's impact by surface material.
- EXPL DATA+28 names one on 81 EXPL.
- IPDS DATA: 12 IPCT, one per material (Stone, Dirt, Grass, Glass, Metal, Wood, Organic, Cloth,
  Water, Hollow Metal, Organic Bug, Organic Glow).
- IPCT: MODL effect model, DATA (duration, orientation, angle threshold, placement radius, sound
  level, No Decal flag), DODT decal, DNAM TXST, SNAM and NAM1 sounds.
- The hit surface's material comes from its collision (havok material). Not censused here.

## Kill event

- A hitscan shot resolves at once. The server knows the hit, its target and the damage before
  anything shows, and emits `lethal_hit(shot, target)` when that damage would kill the target.
  The kill cam (later) listens to it.
- `# ASSUMPTION` lethal = the shot's damage (Base Damage × projectiles that hit, ammo effects)
  is at least the target's Health. The real formula (DT, DR, criticals, limb multipliers) comes
  with damage and is not this server's.
- During the kill cam the same shot spawns its PROJ MODL as a moving projectile from the muzzle
  to the resolved hit point. Outside the kill cam a hitscan shot spawns no projectile, only its
  muzzle flash, tracer (Tracer Chance) and impact.

## Particles

Census of the 98 models PROJ name (MODL, NAM1 muzzle flash, their EXPL's MODL). Particles reach a
projectile two ways.

1. **In the model**: NiParticleSystem (BSStripParticleSystem on the flamer) blocks with their
   NiPSys emitters, modifiers and controllers.
   - PROJ MODL: 13 of 95. Plasma (plasmaprojectile01/02), the incinerators, the spits, the pulse
     gun, both dynamite (lit fuse), the flamer flame.
   - NAM1 muzzle flashes: 2 of the 66 PROJ with one, both Beam; the rest
     are textured meshes with texture transform controllers.
   - EXPL MODL: 48 of 51 PROJ explosions.
2. **Add-on nodes**: a `BSValueNode` named `AddOnNode<n>` in the model names an ADDN record by
   its DATA Node Index. The ADDN's MODL is an `MPS\` NIF holding a BSMasterParticleSystem with
   BSPSysMultiTargetEmitterCtlr: one shared particle system that many models emit into.
   - 37 ADDN in FalloutNV.esm, indices 0–36, every model a particle system; 5 have SNAM sounds.
     DNAM Master Particle System Cap is 0 on all.
   - The missile's smoke trail is one: `mlprojectile.nif` has no particles of its own and an
     AddOnNode24 → `MPSMissleSmokeTrail` (also on the orbital nuke). Others: plasma 15
     (MPSPlasmaProjectile), spits 18/32, Mesmetron and sonic 33 (ring trail), flamer 36.
   - Muzzle flashes carry them too: the gun flashes AddOnNode5 (metal burn smoke) and 22 (gun
     sparks), the alien blaster 21.
   - `# ASSUMPTION` the number in the node's name is its Node Index; the BSValueNode's own value
     is not read yet.

Not handled yet: NifServer builds an NiParticleSystem as an empty, non-emitting GPUParticles3D;
BSValueNode and ADDN are not read. Particles are their own work (NifServer, a census of the NiPSys
blocks), not this server's. Missiles, grenades and bullets fly and hit without them.

## Networking shape

Not networked now; built so it can be.
- Each `fire` is a shot with an id. The server announces its creation (`shot_created`: id, weapon,
  shooter, from, projectile, ammo, seed) for a client's ProjectileServer, which replays it with the
  same seed: the same projectiles, visuals and sounds, no hits.
- Hits, damage, explosions and `lethal_hit` run on the host only and are announced by shot id.
- Moving projectiles (phase 2) are announced on creation, on each new segment (bounce, stick)
  and on their end (impact, explosion, disarm, pick-up). Between those a client computes the
  arc from the last segment's origin, velocity and time: nothing is sent in flight.

## Placed projectiles

Armed mines and charges exist in the world from startup as PGRE records (placed grenade): 174 in
FalloutNV.esm, every one naming a PROJ. No PMIS, PBEA, PFLA or PCBE records exist.

| PROJ | PGRE |
|---|---|
| MineFragProjectile | 131 |
| MineNVPowderChargeProjectile | 33 |
| VHDLegionOliverRangerC4Projectile | 7 |
| MineBottleCapProjectile | 3 |

- PGRE subrecords: NAME and DATA (position, rotation) on all 174; XOWN on 108, XESP (enable
  parent) on 22, XPWR on 4, EDID on 1.
- Not the mine items: REFRs of the mine and grenade WEAP (59 frag grenades, 43 dynamite, 16 C4,
  7 frag mines and others) are pick-ups, not armed.
- Not projectiles either: 20 REFRs of `trapMineBuried01` (ACTI with a script) and 26 of
  `VHDOliverRangerMineLayingTrigger` (ACTI with a script); their scripts are not read here.
- All four PROJ are proximity-triggered (Alt. Trigger Proximity 100, timer 3.0). No fused
  grenade (timer only) is placed in FalloutNV.esm.
- xEdit defines PGRE (Placed Grenade), PMIS (Placed Missile), PBEA (Placed Beam), PFLA and
  PCBE, named after the PROJ Types Lobber, Missile, Beam, Flame and Continuous Beam; all 4
  placed PROJ are Lobber (Type 2). Only PGRE occur.
- Script reference parameters and XLKR accept PGRE, PMIS and PBEA, so a placed projectile can be
  a script's target.
- Not this work: a PGRE is a world-placed item and only a consumer of the server. When
  triggered or activated it calls the server to spawn its PROJ, as any caller does. Loading
  PGRE (the native reader lists only REFR, ACHR and ACRE in a cell; its class is chosen by
  record type, its base being a PROJ) belongs to world placement.

## Saving

- Every non-hitscan projectile the server creates is a ProjectileReference and saves with its
  state: its segment (origin, velocity, time into it), fuse time left, armed, stuck to (a spear
  in a wall or limb). A quicksave keeps airborne missiles, grenades and spears and resumes them on load. Hitscan shots
  resolve in their frame and are not saved.

Found in SaveServer (`Servers/SaveServer/README.md`) and EsmServer:
- Runtime references already save and rehydrate. `EsmServer.create_runtime_reference(base)`
  makes a `runtime:<file>:<base local id>:<n>` reference whose class is
  `TYPE_TO_REFERENCE[base.record_type]`; `save_state()` writes each one's saved fields plus
  `base_form_id` under `esm_server.runtime`; `load_state()` rebuilds it from that base's type
  and reads its fields back. `release_runtime_reference()` drops one (exploded, picked up).
  Inventory items and equipped weapons use this path today.
- So a ProjectileReference is a runtime reference: `"PROJ": "ProjectileBase"` in
  `TYPE_TO_BASE`, `"PROJ": "ProjectileReference"` in `TYPE_TO_REFERENCE`. Its saved fields are
  storage properties, which SaveFields writes: the shooter (EsmReference) as an instance_id,
  the weapon and ammo bases (EsmBase) as record ids, the segment's origin and velocity
  (Vector3), times and flags. EsmServer's save needs no change.
- A runtime reference placed in the world (`set_location()`) emits `reference_cell_changed`
  and is listed by `get_references_in_cell()` through the relocation table, so the streamers
  physicalise it like any reference. `# ASSUMPTION` a loaded one is relisted in its cell the
  same way (its fields set its location again); the step 7 test checks it.
- The ProjectileServer keeps the projectiles it steps in a list built from those references:
  on load it collects the ProjectileReferences EsmServer rebuilt and resumes their segments.
  Its own state (the shot id counter) is a SaveServer `extra_sections` entry, as time and
  weather are.

## Shooting projectiles

Ours: not taken from the original's behaviour.
- A non-hitscan projectile with the Explosion flag can be shot. A hitscan hit detonates it at
  once, its explosion where it was hit. `# ASSUMPTION`
- By the flag, that is the missiles, 25/40mm grenades, Fat Man, grenades, mines, C4, dynamite
  and time bombs. Not the throwing knife (no explosion), the hatchet and spear (an Explosion
  set, the flag clear), plasma or lasers.
- Only hitscan shots hit projectiles; a moving projectile does not hit another.
- A shootable projectile needs a collision shape the hitscan ray reaches: its MODL's collision,
  or one the server gives it.
- DEST (destruction data) is on 25 PROJ, all thrown or placed, the knife, hatchet and spear among
  them. It does not decide what can be shot; it is read with the rest of PROJ.

## Shape

- `ProjectileServer`: an autoload under `GodotBryo/Servers/ProjectileServer/`, with its README.
  `fire()` is its only way in (weapons.md, Firing).
- It runs on the physics tick (`_physics_process`), on the game pause like the other servers.
  - A hitscan shot resolves in the tick `fire()` is called in: one ray per projectile through
    the physics space's direct state, to the PROJ's Range.
  - A moving projectile's flight is computed in code, not simulated: its position at time t
    since launch is `origin + velocity × t + ½ × gravity × t²` (gravity = PROJ Gravity × world
    gravity, `# ASSUMPTION`), and its spin from the PROJ's Rotation. Closed form, so the same
    launch gives the same arc at any tick rate and on any machine. They are not RigidBody3D.
  - Each tick the host casts a ray (or shape) along the segment from last tick's point to this
    tick's, so a fast projectile does not pass through thin collision. The cast is the only
    physics query.
  - A bounce or a stick starts a new segment: new origin, velocity and launch time.
  - Fuses (Alt. Trigger Timer) and proximity checks count physics time.
- `ProjectileReference` (extends EsmReference): a projectile the server spawned: PROJ base,
  shooter, weapon and ammo bases, its segment, fuse time left, armed, stuck to. One for each
  non-hitscan projectile spawned.
- `EsmProjectileNode`: the physicaliser's node for a ProjectileReference, showing the PROJ's MODL
  (and NAM1 at the muzzle on fire). It holds the collision a hitscan ray hits for shootable
  projectiles. The server moves it; it writes its transform back to its reference.
- By space, not cell. A projectile flies in its space (a worldspace or an interior) and is
  stepped while that space is the loaded one: outside, one can cross the whole worldspace.
  Leaving the cells loaded at full detail does not pause it, as it pauses an NPC; its casts
  hit whatever collision is loaded along the way, and nothing where none is.
- A projectile in a space that is not loaded (the player went into an interior) is removed:
  ended with no hit and its reference released, since that space's physics may be cleaned up
  in the transition. If that shows as a problem (a grenade thrown from a door before going
  through it), the fix is to step it to the end of its arc before the space unloads, resolve
  what it hits, then remove it.
- The shooter's own collision is excluded from its shot's casts.
- A projectile that reaches its PROJ's Range ends: a hitscan ray misses; a moving projectile is
  released, an explosive one without exploding (`# ASSUMPTION`).
- Signals (host): `shot_created`, `hit`, `lethal_hit`, `exploded`, `projectile_ended`.

## Editor

For checking a projectile's fields and visuals, not for simulating it.
- PROJ in the GodotBryo browser dock's `BASE_TYPES`. Dropping one places an `EsmProjectileNode`
  shown as it is in flight: its MODL, oriented along -Z, still. Its ProjectileReference and
  ProjectileBase show in the inspector.
- No launching, detonating or firing in the editor; the server does not run there.

## Fields to read

The weapon side reads the accuracy cone and resolves the effective PROJ; the server reads the
projectile count (AMMO Proj. per Shot, else WEAP Projectile Count) and the post-shot spread.
Already read on WeaponBase: NAM0 (`ammo`), DNAM Projectile (`projectile_form_id`), Projectile
Count, Min and Max Range, Spread, Min Spread, DATA Base Damage, CRDT.

| Record | Fields | Phase |
|---|---|---|
| WEAP | INAM (IPDS); DNAM On Hit (+52); DNAM Limb Dmg Mult, Resist Type, Kill Impulse, Impulse Dist (past +136; 217 of 261 DNAM are 204 bytes) | 1 |
| AMMO | DATA flags, Clip Rounds; DAT2 Proj. per Shot, Projectile, Weight, Consumed Ammo, Consumed % (12-byte DAT2 on 11 stops after Weight); RCIL | 1 |
| AMEF | DATA Type, Operation, Value | 1 |
| PROJ | DATA to +68; MODL; NAM1; VNAM | 1 |
| PROJ | DATA +68 Rotation, +80 Bouncy Mult; DEST | 2 |
| EXPL | DATA; MODL | 2 |
| EXPL | EITM, MNAM, radiation, INAM | 3 |
| IPDS, IPCT | all | 1 (bullets), 2 (explosions) |
| ADDN | DATA Node Index, MODL, SNAM, DNAM (with particles, not this server) | later |

New resources: ProjectileBase (PROJ), AmmoEffectBase (AMEF), ImpactBase (IPCT). AmmoBase,
ExplosionBase and ImpactDataSetBase exist with their DATA unread.

## Order

Each step with its test in `tests/`, against real records.

Phase 1, guns:
1. Records: ProjectileBase (PROJ to +68, MODL, NAM1, VNAM), AmmoBase DATA and DAT2, AMEF
   (AmmoEffectBase), WEAP INAM. Field docs per AGENTS.md.
2. `ProjectileServer` with `fire()`: the projectile count, post-shot spread from the seed, one
   ray per projectile on the physics tick, `shot_created` and `hit`. The weapon side: the
   effective PROJ and the accuracy cone in EsmWeaponNode; ammo spent from the holder.
3. Damage per hit (Base Damage, ammo effects) and `lethal_hit`; the damage log line with the
   shooter's name.
4. Visuals: NAM1 muzzle flash with its light and duration, tracers by Tracer Chance, WEAP INAM
   impacts (IPDS, IPCT; ImpactBase).
5. Script `FireWeapon`. The editor: PROJ in the dock, placed as in flight. The lasers on this path (`# ASSUMPTION` above).
6. The kill-cam projectile: the PROJ MODL from the muzzle to the resolved hit.

Built (phase 1):
- ProjectileBase (all of DATA, MODL, NAM1, VNAM), AmmoBase DATA, DAT2 and RCIL, AmmoEffectBase,
  ExplosionBase DATA and MODL (PROJ links to it), ImpactDatasetBase DATA, ImpactBase (MODL,
  DATA, SNAM; decals not yet), WEAP INAM; WeaponBase.default_ammo(), effective_projectile(),
  effective_projectile_count().
- `ProjectileServer` (README in its folder): `fire()`, post-shot spread from the WEAP's Min
  Spread, rays on the physics tick, shooter exclusion, `hit`, `lethal_hit`, `shot_resolved`,
  `damage_log`; muzzle flash with its light, tracers, Stone/Organic impacts; Beam PROJ as rays;
  `spawn_shot_projectile()` for the kill cam.
- EsmWeaponNode: muzzle along the NIF's +Y (checked against the barrel), the aim point from the
  holder's input (the player's camera ray), the accuracy cone from the WEAP's Spread, the loaded
  ammo, a reload taking rounds from the holder's inventory; `fired(shot_id)`.
- Script `FireWeapon` (console signature added). PROJ in the browser dock: a ProjectileReference
  (no flight state yet) shown by an EsmProjectileNode, its bodies held.
- Tests: test_projectile_records, test_projectile_server, test_projectile_effects.
- `# ASSUMPTION`s added: Min Spread is the post-shot spread and Spread the accuracy cone (every
  shotgun has Spread 0); the muzzle's forward is its NIF +Y; impacts use Stone, or Organic on an
  actor; the aim ray reaches 10000 units.

Phase 2, launchers and thrown (every non-hitscan Missile and Lobber, 52):
7. ProjectileReference (runtime reference, ProjectileBase in `TYPE_TO_BASE`) and
   EsmProjectileNode; saving and loading in flight, relisted in its cell.
8. Flight: Speed, Gravity, Range, Rotation, bounce; impact or explosion by the Explosion flag;
   the PROJ's Sound while in flight; removed when its space unloads.
   Plasma, the alien blaster, the throwing knife and spear are here: they are moving Missiles.
9. ExplosionBase DATA and MODL: damage, radius, force, knock down, LOS; the gauss rifle's
   explosion.
10. Alt triggers (timer, proximity) with countdown and disable sounds; Can Be Picked Up, Can Be
    Disabled, Detonates (C4 and the 0-projectile detonators); WEAP with no NAM0 spend
    themselves (grenades, mines, thrown).
11. Shooting projectiles.

Built (phase 2):
- ProjectileReference flight state (segment, age, travelled, at rest, fuse, armed, disarmed) as a
  runtime reference; `EsmServer.get_runtime_references()`; ProjectileServer as a SaveServer
  extra section; a load steps the rebuilt projectiles again.
- Closed-form flight with gravity, spin by the Rotation flag, range; strikes (explode, stick and
  wait, bounce and rest, hit and lie or end); fuses, arming and proximity; explosions (falloff,
  LOS, force); detonate, detonate_placed (the detonator), disarm, pick_up, activation.
- EsmProjectileNode follows its reference, plays the flight and countdown sounds, carries the
  shootable area; hitscan rays set off shootable projectiles.
- EsmWeaponNode: a weapon with no ammo fires without spending (stand-in); a detonator sets off its
  holder's charges.
- Test: test_projectile_flight.
- `# ASSUMPTION`s added: the PROJ's Gravity multiplies the world's; Rotation is degrees per
  second; bounce restitution 0.4 × Bouncy Mult and friction 0.6; linear explosion falloff and the
  force's unit; a 0.5 s shooter grace; the strike rules; a mine's timer is its arming delay;
  a detonator sets off its holder's Detonates charges; explosion models show for 2 s.
- Not yet: the interact ray does not find projectiles (activation works through
  ScriptServer.activate()); the thrown weapon's release follows no attack clip key.

Phase 3, specials: parked as unfinished work. Each waits on the system named.
12. - Beams: done as they are. A beam hits at once and its model is drawn from the gun to
      the hit, a very fast tracer.
    - Tesla cannon chain (DLC03TeslaChainProjectile, 4 PROJ naming the cannon as Default
      Weapon Source): jumping between targets. Not started.
    - ARCHIMEDES strikes (Beam PROJ with explosions, ARCHIMEDES II on a 10 s timer). Not started.
    - Flame (the flamer, hitscan, range 640): a stream drawn along the ray. Waits on particles.
    - Pins Limbs (throwing knife, spear): waits on ragdolls and death.
    - Explosion enchantments (EITM on 22 EXPL: incendiary, pulse, stun): waits on actor effects.
    - Image space modifiers (MNAM on 97 EXPL): waits on IMAD.
    - Radiation (24 EXPL): waits on the radiation actor value.
    - Default Weapon Source (15 PROJ): the weapon a projectile counts as when nothing fired it.
    - Continuous Beam: no PROJ uses it in FalloutNV.esm.

Not in this plan: placed projectiles (PGRE), particles (NifServer, see Particles), the damage
formula, VATS, the kill cam
itself, networking.

## Not known

- Muzzle flashes and tracers point up in game. Their NIFs hold NiBillboardNodes
  (HandGunMuzzleFlash01 and RifleMuzzleFlash01 2 each, 762mmProjectile 1); NifServer's
  NifBillboardNode `rotate_about_up` spins about the world up axis, which would stand a
  forward-pointing flash upright. Not confirmed: the billboard modes in these NIFs are not
  censused. A NifServer change (census, test in `tests/servers/`); if it is the cause,
  ProjectileServer's MUZZLE_FLASH_TURN comes out with it. Projectile models need no turn: the
  missile and Fat Man point along their NIF +Y.
- The viewmodel casts no shadow, so it does not shadow its own muzzle flash light. To have it
  shadow only from that light: viewmodel meshes cast shadows on their own render layer; every
  other light leaves that layer out of its `shadow_caster_mask`; the flash light includes it in
  its `shadow_caster_mask` and `light_cull_mask`. Needs shadow bias tuning (the light sits a few
  centimetres from the gun) and assumes the viewmodel renders with the main camera.

- Alt. Trigger on PROJ with no timer and no proximity.
- PROJ DATA past +68: Bouncy Mult values that are not multipliers.
- Fallout 3's AMMO and PROJ: no FO3 data here, so the FO3 fixed-round chain is not censused.
- Which WEAP fields drive the accuracy cone and which the post-shot spread (DNAM Min Spread,
  Spread, AMEF Spread Mod).
