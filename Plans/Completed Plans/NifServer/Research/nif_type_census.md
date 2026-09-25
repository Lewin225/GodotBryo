# NIF Block Type Census — Fallout: New Vegas Game Data

Every `.nif` and `.kf` file in `fresh_nv_copy/Data/*.bsa` (base game + all DLC/pack archives +
`Update.bsa`), header-parsed for its block type table. 25,760 of 25,760 files parsed; 0 failures.
No loose `.nif`/`.kf` files exist outside the archives.

`files` = number of files whose header declares the type. `blocks` = total block instances across
all files. A type declared in a header always has at least one instance.

## Corpus

| | count |
|---|---|
| `.nif` files | 20746 |
| `.kf` files | 5014 |
| distinct block types present | 160 |
| types registered by nifly but absent from the data | 160 |
| types present in the data but not registered by nifly | 0 |

NIF versions present: 20.2.0.7 user 11 bs34 (25090 files), 20.2.0.7 user 11 bs33 (310 files), 20.2.0.7 user 11 bs32 (125 files), 20.2.0.7 user 11 bs27 (81 files), 20.2.0.7 user 11 bs31 (37 files), 20.2.0.7 user 11 bs25 (31 files), 20.2.0.7 user 11 bs21 (31 files), 20.2.0.7 user 11 bs30 (17 files), 20.2.0.7 user 11 bs26 (13 files), 20.2.0.7 user 11 bs14 (9 files), 20.2.0.7 user 11 bs24 (8 files), 20.0.0.4 user 11 bs11 (3 files), 20.0.0.4 user 10 bs11 (3 files), 20.2.0.7 user 11 bs28 (2 files)

## Types present in the data (160)

Sorted by file count.

| block type | files | blocks | .nif | .kf |
|---|---:|---:|---:|---:|
| `BSShaderPPLightingProperty` | 19578 | 58706 | 19578 | 0 |
| `BSShaderTextureSet` | 19578 | 56789 | 19578 | 0 |
| `NiMaterialProperty` | 16376 | 30414 | 16376 | 0 |
| `NiTriStrips` | 15278 | 57796 | 15278 | 0 |
| `NiTriStripsData` | 15278 | 57794 | 15278 | 0 |
| `BSFadeNode` | 15121 | 15121 | 15121 | 0 |
| `NiStringExtraData` | 12692 | 32161 | 12692 | 0 |
| `BSXFlags` | 12578 | 12578 | 12578 | 0 |
| `bhkCollisionObject` | 11134 | 15645 | 11134 | 0 |
| `NiAlphaProperty` | 10422 | 15253 | 10422 | 0 |
| `hkPackedNiTriStripsData` | 8465 | 9759 | 8465 | 0 |
| `bhkPackedNiTriStripsShape` | 8465 | 9914 | 8465 | 0 |
| `bhkMoppBvTreeShape` | 8465 | 9947 | 8465 | 0 |
| `bhkRigidBody` | 7926 | 12109 | 7926 | 0 |
| `NiTransformInterpolator` | 6850 | 169595 | 1856 | 4994 |
| `NiTransformData` | 6507 | 110780 | 1744 | 4763 |
| `NiTextKeyExtraData` | 6393 | 7748 | 1379 | 5014 |
| `NiControllerSequence` | 6178 | 7483 | 1164 | 5014 |
| `NiNode` | 5690 | 51831 | 5690 | 0 |
| `NiTriShapeData` | 5194 | 10178 | 5194 | 0 |
| `NiTriShape` | 4633 | 9189 | 4633 | 0 |
| `BSMultiBoundNode` | 4137 | 4137 | 4137 | 0 |
| `BSMultiBound` | 4137 | 4137 | 4137 | 0 |
| `BSMultiBoundAABB` | 4136 | 4136 | 4136 | 0 |
| `NiBSplineData` | 4102 | 4124 | 0 | 4102 |
| `NiBSplineCompTransformInterpolator` | 4065 | 105312 | 0 | 4065 |
| `NiBSplineBasisData` | 4049 | 4119 | 0 | 4049 |
| `BSShaderNoLightingProperty` | 3663 | 9582 | 3663 | 0 |
| `NiAdditionalGeometryData` | 3567 | 3567 | 3567 | 0 |
| `bhkRigidBodyT` | 3531 | 4701 | 3531 | 0 |
| `NiFloatInterpolator` | 2852 | 13427 | 1252 | 1600 |
| `NiFloatData` | 2652 | 10379 | 1103 | 1549 |
| `bhkConvexVerticesShape` | 1980 | 2793 | 1980 | 0 |
| `NiTexturingProperty` | 1616 | 3018 | 1616 | 0 |
| `NiSourceTexture` | 1616 | 2854 | 1616 | 0 |
| `NiBoolInterpolator` | 1516 | 8696 | 680 | 836 |
| `NiTransformController` | 1299 | 7321 | 1299 | 0 |
| `NiControllerManager` | 1164 | 1164 | 1164 | 0 |
| `NiMultiTargetTransformController` | 1164 | 1164 | 1164 | 0 |
| `NiDefaultAVObjectPalette` | 1164 | 1164 | 1164 | 0 |
| `NiSkinData` | 1038 | 5396 | 1038 | 0 |
| `NiSkinPartition` | 1038 | 5396 | 1038 | 0 |
| `NiBoolData` | 1028 | 6508 | 666 | 362 |
| `bhkBoxShape` | 908 | 1498 | 908 | 0 |
| `BSDismemberSkinInstance` | 860 | 5157 | 860 | 0 |
| `NiPosData` | 852 | 2266 | 570 | 282 |
| `BSSegmentedTriShape` | 849 | 989 | 849 | 0 |
| `NiPoint3Interpolator` | 835 | 2252 | 552 | 283 |
| `NiStencilProperty` | 823 | 839 | 823 | 0 |
| `NiTextureTransformController` | 687 | 2077 | 687 | 0 |
| `NiBlendFloatInterpolator` | 568 | 3708 | 568 | 0 |
| `NiMaterialColorController` | 535 | 994 | 535 | 0 |
| `NiPSysUpdateCtlr` | 392 | 1599 | 392 | 0 |
| `NiPSysAgeDeathModifier` | 392 | 1599 | 392 | 0 |
| `NiPSysSpawnModifier` | 392 | 1599 | 392 | 0 |
| `NiPSysPositionModifier` | 392 | 1599 | 392 | 0 |
| `NiPSysBoundUpdateModifier` | 392 | 1599 | 392 | 0 |
| `NiParticleSystem` | 388 | 1587 | 388 | 0 |
| `NiPSysData` | 388 | 1587 | 388 | 0 |
| `NiVisController` | 370 | 2820 | 370 | 0 |
| `NiPSysEmitterCtlr` | 353 | 1528 | 353 | 0 |
| `BSPSysSimpleColorModifier` | 352 | 1270 | 352 | 0 |
| `NiPSysRotationModifier` | 343 | 1387 | 343 | 0 |
| `NiBlendPoint3Interpolator` | 342 | 677 | 342 | 0 |
| `NiAlphaController` | 333 | 843 | 333 | 0 |
| `NiPSysGrowFadeModifier` | 299 | 1165 | 299 | 0 |
| `NiBillboardNode` | 280 | 689 | 280 | 0 |
| `NiPSysBoxEmitter` | 266 | 1088 | 266 | 0 |
| `NiPSysGravityModifier` | 263 | 889 | 263 | 0 |
| `NiBlendBoolInterpolator` | 259 | 4075 | 259 | 0 |
| `BSMaterialEmittanceMultController` | 252 | 471 | 252 | 0 |
| `NiBSplineCompPoint3Interpolator` | 221 | 447 | 0 | 221 |
| `bhkLimitedHingeConstraint` | 190 | 596 | 190 | 0 |
| `NiSkinInstance` | 178 | 239 | 178 | 0 |
| `NiCamera` | 162 | 162 | 162 | 0 |
| `NiBSplineCompFloatInterpolator` | 154 | 237 | 0 | 154 |
| `BSFurnitureMarker` | 142 | 142 | 142 | 0 |
| `bhkListShape` | 141 | 162 | 141 | 0 |
| `BSValueNode` | 139 | 482 | 139 | 0 |
| `BSAnimNotes` | 134 | 136 | 0 | 134 |
| `NiBoolTimelineInterpolator` | 122 | 1691 | 120 | 2 |
| `NiPSysModifierActiveCtlr` | 120 | 1150 | 120 | 0 |
| `bhkCapsuleShape` | 116 | 1363 | 116 | 0 |
| `NiPSysDragModifier` | 103 | 917 | 103 | 0 |
| `BSDecalPlacementVectorExtraData` | 95 | 95 | 95 | 0 |
| `NiPSysCylinderEmitter` | 92 | 224 | 92 | 0 |
| `NiFloatExtraData` | 81 | 94 | 81 | 0 |
| `BSOrderedNode` | 81 | 81 | 81 | 0 |
| `bhkRagdollConstraint` | 78 | 708 | 78 | 0 |
| `NiPSysMeshEmitter` | 74 | 175 | 74 | 0 |
| `BSBound` | 66 | 66 | 66 | 0 |
| `BSRefractionStrengthController` | 66 | 87 | 66 | 0 |
| `BSBlastNode` | 63 | 81 | 63 | 0 |
| `NiPSysColliderManager` | 61 | 126 | 61 | 0 |
| `NiPSysPlanarCollider` | 60 | 490 | 60 | 0 |
| `NiIntegerExtraData` | 60 | 60 | 60 | 0 |
| `bhkBlendController` | 60 | 1165 | 60 | 0 |
| `bhkBlendCollisionObject` | 60 | 1165 | 60 | 0 |
| `NiPointLight` | 58 | 119 | 58 | 0 |
| `BSFrustumFOVController` | 56 | 56 | 56 | 0 |
| `NiGeomMorpherController` | 55 | 83 | 55 | 0 |
| `NiMorphData` | 55 | 83 | 55 | 0 |
| `NiPSysSphereEmitter` | 53 | 112 | 53 | 0 |
| `BSDamageStage` | 51 | 69 | 51 | 0 |
| `NiPSysEmitterSpeedCtlr` | 49 | 75 | 49 | 0 |
| `bhkTransformShape` | 47 | 57 | 47 | 0 |
| `NiFloatExtraDataController` | 42 | 54 | 42 | 0 |
| `BSPSysMultiTargetEmitterCtlr` | 42 | 71 | 42 | 0 |
| `NiBSBoneLODController` | 41 | 41 | 41 | 0 |
| `bhkSimpleShapePhantom` | 40 | 40 | 40 | 0 |
| `bhkSPCollisionObject` | 40 | 40 | 40 | 0 |
| `BSMasterParticleSystem` | 38 | 38 | 38 | 0 |
| `NiPSysBombModifier` | 35 | 231 | 35 | 0 |
| `bhkConvexTransformShape` | 34 | 109 | 34 | 0 |
| `NiPSysGravityStrengthCtlr` | 27 | 107 | 27 | 0 |
| `NiPSysEmitterLifeSpanCtlr` | 25 | 40 | 25 | 0 |
| `NiPSysEmitterInitialRadiusCtlr` | 23 | 47 | 23 | 0 |
| `bhkSphereShape` | 23 | 38 | 23 | 0 |
| `BSRotAccumTransfInterpolator` | 21 | 38 | 0 | 21 |
| `NiPathInterpolator` | 19 | 56 | 19 | 0 |
| `TallGrassShaderProperty` | 18 | 18 | 18 | 0 |
| `BSRefractionFirePeriodController` | 17 | 30 | 17 | 0 |
| `NiPSysColorModifier` | 13 | 94 | 13 | 0 |
| `NiColorData` | 13 | 94 | 13 | 0 |
| `NiLightColorController` | 13 | 13 | 13 | 0 |
| `NiAmbientLight` | 12 | 12 | 12 | 0 |
| `BSStripParticleSystem` | 11 | 12 | 11 | 0 |
| `BSStripPSysData` | 11 | 12 | 11 | 0 |
| `BSPSysStripUpdateModifier` | 11 | 12 | 11 | 0 |
| `bhkMalleableConstraint` | 10 | 143 | 10 | 0 |
| `NiPSysSphericalCollider` | 10 | 243 | 10 | 0 |
| `NiBinaryExtraData` | 8 | 8 | 8 | 0 |
| `WaterShaderProperty` | 8 | 8 | 8 | 0 |
| `NiLookAtInterpolator` | 7 | 21 | 7 | 0 |
| `SkyShaderProperty` | 6 | 9 | 6 | 0 |
| `BSDebrisNode` | 6 | 6 | 6 | 0 |
| `BSWindModifier` | 6 | 10 | 6 | 0 |
| `TileShaderProperty` | 5 | 49 | 5 | 0 |
| `BSTreadTransfInterpolator` | 5 | 5 | 0 | 5 |
| `NiStringPalette` | 5 | 5 | 0 | 5 |
| `NiBSplineTransformInterpolator` | 4 | 148 | 0 | 4 |
| `bhkHingeConstraint` | 4 | 4 | 4 | 0 |
| `NiLightDimmerController` | 4 | 4 | 4 | 0 |
| `bhkLiquidAction` | 3 | 25 | 3 | 0 |
| `NiPSysEmitterPlanarAngleVarCtlr` | 2 | 3 | 2 | 0 |
| `NiPSysEmitterDeclinationVarCtlr` | 2 | 3 | 2 | 0 |
| `bhkPrismaticConstraint` | 2 | 3 | 2 | 0 |
| `BSParentVelocityModifier` | 2 | 2 | 2 | 0 |
| `bhkOrientHingedBodyAction` | 2 | 2 | 2 | 0 |
| `NiPSysInitialRotAngleCtlr` | 1 | 2 | 1 | 0 |
| `NiPSysInitialRotSpeedVarCtlr` | 1 | 2 | 1 | 0 |
| `NiPSysInitialRotSpeedCtlr` | 1 | 2 | 1 | 0 |
| `NiPSysEmitterPlanarAngleCtlr` | 1 | 2 | 1 | 0 |
| `NiPSysEmitterDeclinationCtlr` | 1 | 2 | 1 | 0 |
| `BSMultiBoundSphere` | 1 | 1 | 1 | 0 |
| `bhkBreakableConstraint` | 1 | 1 | 1 | 0 |
| `BSWArray` | 1 | 1 | 1 | 0 |
| `bhkStiffSpringConstraint` | 1 | 1 | 1 | 0 |
| `NiPSysResetOnLoopCtlr` | 1 | 1 | 1 | 0 |
| `bhkNiTriStripsShape` | 1 | 1 | 1 | 0 |

### Present in fewer than 25 files

Types below this line appear in under 0.1% of the corpus. Each is listed with an example file so
the actual usage can be inspected before deciding whether it needs real support or a skip/stub.

**Rarity does not imply optional.** `NiStringPalette` appears in 5 files, and those 5 files are
unreadable without it: their animation links address targets by byte offset into the palette rather
than by inline name (see `Plans/nifserver_design_findings.md` §6.4). Judge each rare type by what
breaks without it, not by its count.

| block type | files | blocks | example |
|---|---:|---:|---|
| `NiPSysEmitterInitialRadiusCtlr` | 23 | 47 | `meshes\dlcanch\effects\dlcanchgastankexplosion01.nif` |
| `bhkSphereShape` | 23 | 38 | `meshes\clutter\toys\ball01.nif` |
| `BSRotAccumTransfInterpolator` | 21 | 38 | `meshes\dlcanch\creatures\chimera\locomotion\mtforward.kf` |
| `NiPathInterpolator` | 19 | 56 | `meshes\dlcanch\effects\dlcanchfxbomberloop01.nif` |
| `TallGrassShaderProperty` | 18 | 18 | `meshes\landscape\grass\grasswasteland01.nif` |
| `BSRefractionFirePeriodController` | 17 | 30 | `meshes\nvdlc01\clutter\lights\nvdlc01_sconceanim.nif` |
| `NiPSysColorModifier` | 13 | 94 | `meshes\nvdlc01\clutter\smsign\nvdlc01smsign.nif` |
| `NiColorData` | 13 | 94 | `meshes\nvdlc01\clutter\smsign\nvdlc01smsign.nif` |
| `NiLightColorController` | 13 | 13 | `meshes\dungeons\caves\lamplight\lamplightwarm.nif` |
| `NiAmbientLight` | 12 | 12 | `meshes\dungeons\caves\lamplight\lamplightchandelier.nif` |
| `BSStripParticleSystem` | 11 | 12 | `meshes\effects\tests\flamestriptest.nif` |
| `BSStripPSysData` | 11 | 12 | `meshes\effects\tests\flamestriptest.nif` |
| `BSPSysStripUpdateModifier` | 11 | 12 | `meshes\effects\tests\flamestriptest.nif` |
| `bhkMalleableConstraint` | 10 | 143 | `meshes\nvdlc01\creatures\ghosts\skeleton.nif` |
| `NiPSysSphericalCollider` | 10 | 243 | `meshes\dlc04\dungeons\lab\rooms\dlc04braincontroldevice01.nif` |
| `NiBinaryExtraData` | 8 | 8 | `meshes\interface\testloadanim01c.nif` |
| `WaterShaderProperty` | 8 | 8 | `meshes\water_placeable\water_bathtub.nif` |
| `NiLookAtInterpolator` | 7 | 21 | `meshes\nvdlc01\terminals\nvdlc01_roulette\nvdlc01_roulette-table.nif` |
| `SkyShaderProperty` | 6 | 9 | `meshes\sky\stars.nif` |
| `BSDebrisNode` | 6 | 6 | `meshes\vehicles\vertibirdmq11animations.nif` |
| `BSWindModifier` | 6 | 10 | `meshes\effects\explosiongrenadefrag.nif` |
| `TileShaderProperty` | 5 | 49 | `meshes\interface\circular loading\loading01.nif` |
| `BSTreadTransfInterpolator` | 5 | 5 | `meshes\creatures\libertyprime\1gtequip.kf` |
| `NiStringPalette` | 5 | 5 | `meshes\characters\_male\idleanims\talk_handsatside_moving2.kf` |
| `NiBSplineTransformInterpolator` | 4 | 148 | `meshes\dlc05\creatures\alien\locomotion\forwardwalk.kf` |
| `bhkHingeConstraint` | 4 | 4 | `meshes\creatures\zaxeye\skeleton.nif` |
| `NiLightDimmerController` | 4 | 4 | `meshes\clutter\questitems\monumentlight01.nif` |
| `bhkLiquidAction` | 3 | 25 | `meshes\dlc03\effects\dlc03flamerexplosion.nif` |
| `NiPSysEmitterPlanarAngleVarCtlr` | 2 | 3 | `meshes\animobjects\nvvomit.nif` |
| `NiPSysEmitterDeclinationVarCtlr` | 2 | 3 | `meshes\animobjects\nvvomit.nif` |
| `bhkPrismaticConstraint` | 2 | 3 | `meshes\creatures\protectron\skeleton.nif` |
| `BSParentVelocityModifier` | 2 | 2 | `meshes\gore\bloodspraylimb01.nif` |
| `bhkOrientHingedBodyAction` | 2 | 2 | `meshes\creatures\sentryturret\skeleton.nif` |
| `NiPSysInitialRotAngleCtlr` | 1 | 2 | `meshes\animobjects\nvvomit.nif` |
| `NiPSysInitialRotSpeedVarCtlr` | 1 | 2 | `meshes\animobjects\nvvomit.nif` |
| `NiPSysInitialRotSpeedCtlr` | 1 | 2 | `meshes\animobjects\nvvomit.nif` |
| `NiPSysEmitterPlanarAngleCtlr` | 1 | 2 | `meshes\animobjects\nvvomit.nif` |
| `NiPSysEmitterDeclinationCtlr` | 1 | 2 | `meshes\animobjects\nvvomit.nif` |
| `BSMultiBoundSphere` | 1 | 1 | `meshes\effects\tests\testmultiboundyes.nif` |
| `bhkBreakableConstraint` | 1 | 1 | `meshes\creatures\protectron\skeleton.nif` |
| `BSWArray` | 1 | 1 | `meshes\projectiles\libertyprimeprojectile.nif` |
| `bhkStiffSpringConstraint` | 1 | 1 | `meshes\dlc04\effects\dlc04slimebubble03.nif` |
| `NiPSysResetOnLoopCtlr` | 1 | 1 | `meshes\dungeons\nvlucky38\nvlucky38reactor.nif` |
| `bhkNiTriStripsShape` | 1 | 1 | `meshes\traps\terminaldesktrap01.nif` |

## Registered by nifly, absent from the data (160)

Zero occurrences across all 25,760 files. Nothing in the shipped game data can require these.

`AvoidNode`, `BSAnimNote`, `BSBehaviorGraphExtraData`, `BSBoneLODExtraData`, `BSClothExtraData`,
`BSCollisionQueryProxyExtraData`, `BSConnectPointChildren`, `BSConnectPointParents`,
`BSDistantObjectExtraData`, `BSDistantObjectInstancedNode`, `BSDistantObjectLargeRefExtraData`,
`BSDistantTreeShaderProperty`, `BSDynamicTriShape`, `BSEffectShaderProperty`,
`BSEffectShaderPropertyColorController`, `BSEffectShaderPropertyFloatController`,
`BSEyeCenterExtraData`, `BSFaceGenNiNode`, `BSFurnitureMarkerNode`, `BSGeometry`, `BSInvMarker`,
`BSLODTriShape`, `BSLagBoneController`, `BSLeafAnimNode`, `BSLightingShaderProperty`,
`BSLightingShaderPropertyColorController`, `BSLightingShaderPropertyFloatController`,
`BSLightingShaderPropertyUShortController`, `BSMeshLODTriShape`, `BSMultiBoundOBB`,
`BSNiAlphaPropertyTestRefController`, `BSPSysArrayEmitter`, `BSPSysHavokUpdateModifier`,
`BSPSysInheritVelocityModifier`, `BSPSysLODModifier`, `BSPSysRecycleBoundModifier`,
`BSPSysScaleModifier`, `BSPSysSubTexModifier`, `BSPackedAdditionalGeometryData`,
`BSPackedCombinedSharedGeomDataExtra`, `BSPositionData`, `BSProceduralLightningController`,
`BSSkinBoneData`, `BSSkinInstance`, `BSSkyShaderProperty`, `BSSubIndexTriShape`, `BSTreeNode`,
`BSTriShape`, `BSWaterShaderProperty`, `BSWeakReferenceNode`, `BoneTranslations`,
`DistantLODShaderProperty`, `HairShaderProperty`, `Lighting30ShaderProperty`,
`NiAutoNormalParticles`, `NiAutoNormalParticlesData`, `NiBSAnimationNode`, `NiBSPArrayController`,
`NiBSParticleNode`, `NiBlendTransformInterpolator`, `NiBone`, `NiBoneLODController`,
`NiBooleanExtraData`, `NiCollisionData`, `NiCollisionObject`, `NiColorExtraData`,
`NiDirectionalLight`, `NiDitherProperty`, `NiEmitterModifier`, `NiExtraData`, `NiFlipController`,
`NiFloatsExtraData`, `NiFogProperty`, `NiGravity`, `NiIntegersExtraData`, `NiKeyframeController`,
`NiKeyframeData`, `NiLODNode`, `NiLightRadiusController`, `NiLines`, `NiLinesData`,
`NiLookAtController`, `NiMeshPSysData`, `NiMeshParticleSystem`, `NiPSysAirFieldAirFrictionCtlr`,
`NiPSysAirFieldInheritVelocityCtlr`, `NiPSysAirFieldModifier`, `NiPSysAirFieldSpreadCtlr`,
`NiPSysDragFieldModifier`, `NiPSysEmitterCtlrData`, `NiPSysFieldAttenuationCtlr`,
`NiPSysFieldMagnitudeCtlr`, `NiPSysFieldMaxDistanceCtlr`, `NiPSysGravityFieldModifier`,
`NiPSysInitialRotAngleVarCtlr`, `NiPSysMeshUpdateModifier`, `NiPSysRadialFieldModifier`,
`NiPSysRotDampeningCtlr`, `NiPSysTurbulenceFieldModifier`, `NiPSysVortexFieldModifier`, `NiPalette`,
`NiParticleBomb`, `NiParticleColorModifier`, `NiParticleGrowFade`, `NiParticleMeshModifier`,
`NiParticleMeshes`, `NiParticleMeshesData`, `NiParticleRotation`, `NiParticleSystemController`,
`NiParticles`, `NiParticlesData`, `NiPathController`, `NiPersistentSrcTextureRendererData`,
`NiPixelData`, `NiPlanarCollider`, `NiRangeLODData`, `NiRollController`, `NiRotatingParticles`,
`NiRotatingParticlesData`, `NiScreenElements`, `NiScreenElementsData`, `NiScreenLODData`,
`NiSequence`, `NiSequenceStreamHelper`, `NiShadeProperty`, `NiSortAdjustNode`, `NiSourceCubeMap`,
`NiSpecularProperty`, `NiSphericalCollider`, `NiSpotLight`, `NiStringsExtraData`, `NiSwitchNode`,
`NiTextureEffect`, `NiUVController`, `NiUVData`, `NiVectorExtraData`, `NiVertWeightsExtraData`,
`NiVertexColorProperty`, `NiVisData`, `NiWireframeProperty`, `NiZBufferProperty`,
`RootCollisionNode`, `SkinAttach`, `VolumetricFogShaderProperty`, `bhkAabbPhantom`,
`bhkBallAndSocketConstraint`, `bhkBallSocketConstraintChain`, `bhkCompressedMeshShape`,
`bhkCompressedMeshShapeData`, `bhkConvexListShape`, `bhkCylinderShape`, `bhkMultiSphereShape`,
`bhkNPCollisionObject`, `bhkPCollisionObject`, `bhkPhysicsSystem`, `bhkPlaneShape`, `bhkPoseArray`,
`bhkRagdollSystem`, `bhkRagdollTemplate`, `bhkRagdollTemplateData`
