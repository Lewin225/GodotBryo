# Nifly Registered NIF Block Types

This is the list of concrete block classes registered by nifly's `NiFactoryRegister` in
`native/nifly/src/Factory.cpp`. These are types nifly can instantiate when their block names appear in a
NIF. Registration is not the same as saying that Fallout: New Vegas uses every type, or that this project
currently interprets every field or behavior.

Unregistered base/helper classes such as `NiObject`, `NiAVObject`, `NiShape`, `NiNode`, `bhkShape`, and
`NiProperty` are represented by their registered concrete subclasses below.

## Scene nodes and geometry

`NiNode`, `RootCollisionNode`, `AvoidNode`, `NiBSAnimationNode`, `NiBSParticleNode`, `BSFadeNode`,
`BSValueNode`, `BSLeafAnimNode`, `BSTreeNode`, `BSOrderedNode`, `BSMultiBoundNode`,
`BSDistantObjectInstancedNode`, `BSDebrisNode`, `BSBlastNode`, `BSDamageStage`, `BSWeakReferenceNode`,
`BSFaceGenNiNode`, `NiBone`, `NiSortAdjustNode`, `NiRangeLODData`, `NiScreenLODData`, `NiLODNode`,
`NiBillboardNode`, `NiSwitchNode`, `NiTriShape`, `NiTriShapeData`, `NiTriStrips`, `NiTriStripsData`,
`NiLines`, `NiLinesData`, `NiScreenElements`, `NiScreenElementsData`, `BSLODTriShape`,
`BSSegmentedTriShape`, `BSTriShape`, `BSSubIndexTriShape`, `BSMeshLODTriShape`, `BSDynamicTriShape`,
`BSGeometry`, `NiAdditionalGeometryData`, `BSPackedAdditionalGeometryData`.

## Textures, lights, and shader/material blocks

`NiSequenceStreamHelper`, `NiPalette`, `NiPersistentSrcTextureRendererData`, `NiPixelData`,
`NiSourceTexture`, `NiSourceCubeMap`, `NiTextureEffect`, `NiAmbientLight`, `NiDirectionalLight`,
`NiPointLight`, `NiSpotLight`, `NiShadeProperty`, `NiSpecularProperty`, `NiTexturingProperty`,
`NiVertexColorProperty`, `NiDitherProperty`, `NiFogProperty`, `NiWireframeProperty`, `NiZBufferProperty`,
`WaterShaderProperty`, `HairShaderProperty`, `DistantLODShaderProperty`, `BSDistantTreeShaderProperty`,
`TallGrassShaderProperty`, `VolumetricFogShaderProperty`, `SkyShaderProperty`, `TileShaderProperty`,
`BSShaderNoLightingProperty`, `BSShaderPPLightingProperty`, `Lighting30ShaderProperty`,
`BSLightingShaderProperty`, `BSEffectShaderProperty`, `BSWaterShaderProperty`, `BSSkyShaderProperty`,
`NiAlphaProperty`, `NiMaterialProperty`, `NiStencilProperty`, `BSShaderTextureSet`.

## Particle systems and particle controllers

`BSMasterParticleSystem`, `NiParticleSystem`, `NiMeshParticleSystem`, `BSStripParticleSystem`,
`NiParticles`, `NiAutoNormalParticles`, `NiParticleMeshes`, `NiRotatingParticles`, `NiParticlesData`,
`NiAutoNormalParticlesData`, `NiRotatingParticlesData`, `NiParticleMeshesData`,
`NiParticleSystemController`, `NiBSPArrayController`, `NiEmitterModifier`, `NiGravity`,
`NiParticleGrowFade`, `NiParticleColorModifier`, `NiParticleRotation`, `NiParticleBomb`,
`NiParticleMeshModifier`, `NiPlanarCollider`, `NiSphericalCollider`, `NiPSysData`, `NiMeshPSysData`,
`BSStripPSysData`, `NiPSysEmitterCtlrData`, `NiColorData`, `NiPSysColorModifier`,
`NiPSysGrowFadeModifier`, `NiPSysMeshUpdateModifier`, `NiPSysVortexFieldModifier`,
`NiPSysGravityFieldModifier`, `NiPSysDragFieldModifier`, `NiPSysTurbulenceFieldModifier`,
`NiPSysAirFieldModifier`, `NiPSysRadialFieldModifier`, `BSWindModifier`, `BSPSysRecycleBoundModifier`,
`BSPSysHavokUpdateModifier`, `BSParentVelocityModifier`, `NiPSysSphericalCollider`,
`NiPSysPlanarCollider`, `NiPSysColliderManager`, `NiPSysSphereEmitter`, `NiPSysCylinderEmitter`,
`NiPSysBoxEmitter`, `BSPSysArrayEmitter`, `NiPSysMeshEmitter`, `BSPSysStripUpdateModifier`,
`NiPSysAgeDeathModifier`, `BSPSysLODModifier`, `NiPSysSpawnModifier`, `BSPSysSimpleColorModifier`,
`NiPSysRotationModifier`, `BSPSysScaleModifier`, `NiPSysGravityModifier`, `NiPSysPositionModifier`,
`NiPSysBoundUpdateModifier`, `NiPSysDragModifier`, `BSPSysInheritVelocityModifier`, `NiPSysBombModifier`,
`NiPSysResetOnLoopCtlr`, `NiPSysModifierActiveCtlr`, `NiPSysEmitterLifeSpanCtlr`,
`NiPSysEmitterSpeedCtlr`, `NiPSysEmitterInitialRadiusCtlr`, `NiPSysEmitterDeclinationCtlr`,
`NiPSysGravityStrengthCtlr`, `NiPSysEmitterDeclinationVarCtlr`, `NiPSysFieldMagnitudeCtlr`,
`NiPSysFieldAttenuationCtlr`, `NiPSysFieldMaxDistanceCtlr`, `NiPSysAirFieldAirFrictionCtlr`,
`NiPSysAirFieldInheritVelocityCtlr`, `NiPSysAirFieldSpreadCtlr`, `NiPSysInitialRotSpeedCtlr`,
`NiPSysInitialRotSpeedVarCtlr`, `NiPSysInitialRotAngleCtlr`, `NiPSysInitialRotAngleVarCtlr`,
`NiPSysEmitterPlanarAngleCtlr`, `NiPSysEmitterPlanarAngleVarCtlr`, `NiPSysRotDampeningCtlr`,
`NiPSysEmitterCtlr`, `BSPSysMultiTargetEmitterCtlr`, `NiPSysUpdateCtlr`.

## Skinning

`NiSkinInstance`, `BSDismemberSkinInstance`, `NiSkinData`, `NiSkinPartition`, `BSSkinInstance`,
`BSSkinBoneData`, `SkinAttach`, `BoneTranslations`.

## Animation, controllers, and interpolators

`BSLightingShaderPropertyColorController`, `BSLightingShaderPropertyFloatController`,
`BSLightingShaderPropertyUShortController`, `BSEffectShaderPropertyColorController`,
`BSEffectShaderPropertyFloatController`, `NiLookAtController`, `NiPathController`, `NiUVController`,
`BSRefractionFirePeriodController`, `BSFrustumFOVController`, `BSLagBoneController`,
`BSProceduralLightningController`, `NiBoneLODController`, `NiBSBoneLODController`, `NiMorphData`,
`NiGeomMorpherController`, `NiRollController`, `NiMaterialColorController`, `NiLightColorController`,
`NiFloatExtraDataController`, `NiVisData`, `NiVisController`, `NiFlipController`,
`NiTextureTransformController`, `NiLightDimmerController`, `NiLightRadiusController`,
`NiAlphaController`, `BSNiAlphaPropertyTestRefController`, `NiKeyframeController`,
`NiTransformController`, `BSMaterialEmittanceMultController`, `BSRefractionStrengthController`,
`NiMultiTargetTransformController`, `NiControllerManager`, `NiSequence`, `BSAnimNote`, `BSAnimNotes`,
`NiStringPalette`, `NiControllerSequence`, `NiDefaultAVObjectPalette`, `NiBSplineData`,
`NiBSplineBasisData`, `NiBSplineCompFloatInterpolator`, `NiBSplineCompPoint3Interpolator`,
`NiBSplineTransformInterpolator`, `NiBSplineCompTransformInterpolator`, `NiBlendBoolInterpolator`,
`NiBlendFloatInterpolator`, `NiBlendPoint3Interpolator`, `NiBlendTransformInterpolator`,
`NiBoolInterpolator`, `NiBoolTimelineInterpolator`, `NiFloatInterpolator`, `NiTransformInterpolator`,
`BSRotAccumTransfInterpolator`, `NiPoint3Interpolator`, `NiPathInterpolator`, `NiLookAtInterpolator`,
`BSTreadTransfInterpolator`, `NiKeyframeData`, `NiTransformData`, `NiPosData`, `NiBoolData`,
`NiFloatData`.

## Extra data and bounds

`NiExtraData`, `NiBinaryExtraData`, `NiFloatExtraData`, `NiFloatsExtraData`, `NiStringExtraData`,
`NiStringsExtraData`, `NiBooleanExtraData`, `NiIntegerExtraData`, `NiIntegersExtraData`,
`NiVectorExtraData`, `NiColorExtraData`, `BSXFlags`, `BSWArray`, `BSPositionData`,
`BSEyeCenterExtraData`, `BSPackedCombinedSharedGeomDataExtra`, `BSInvMarker`, `BSFurnitureMarker`,
`BSFurnitureMarkerNode`, `BSDecalPlacementVectorExtraData`, `BSBehaviorGraphExtraData`, `BSBound`,
`BSBoneLODExtraData`, `NiVertWeightsExtraData`, `NiTextKeyExtraData`,
`BSDistantObjectLargeRefExtraData`, `BSDistantObjectExtraData`, `BSClothExtraData`,
`BSCollisionQueryProxyExtraData`, `BSConnectPointParents`, `BSConnectPointChildren`, `BSMultiBound`,
`BSMultiBoundOBB`, `BSMultiBoundAABB`, `BSMultiBoundSphere`.

## Collision and Havok

`NiCollisionObject`, `NiCollisionData`, `bhkCollisionObject`, `bhkNPCollisionObject`,
`bhkPCollisionObject`, `bhkSPCollisionObject`, `bhkBlendCollisionObject`, `bhkPhysicsSystem`,
`bhkRagdollSystem`, `bhkBlendController`, `bhkPlaneShape`, `bhkMultiSphereShape`,
`bhkConvexListShape`, `bhkConvexVerticesShape`, `bhkBoxShape`, `bhkSphereShape`, `bhkCylinderShape`,
`bhkTransformShape`, `bhkConvexTransformShape`, `bhkCapsuleShape`, `bhkNiTriStripsShape`,
`bhkListShape`, `hkPackedNiTriStripsData`, `bhkPackedNiTriStripsShape`, `bhkLiquidAction`,
`bhkOrientHingedBodyAction`, `bhkSimpleShapePhantom`, `bhkAabbPhantom`, `bhkHingeConstraint`,
`bhkLimitedHingeConstraint`, `bhkRagdollConstraint`, `bhkBreakableConstraint`,
`bhkStiffSpringConstraint`, `bhkPrismaticConstraint`, `bhkMalleableConstraint`,
`bhkBallAndSocketConstraint`, `bhkBallSocketConstraintChain`, `bhkRigidBody`, `bhkRigidBodyT`,
`bhkCompressedMeshShape`, `bhkCompressedMeshShapeData`, `bhkMoppBvTreeShape`, `bhkPoseArray`,
`bhkRagdollTemplate`, `bhkRagdollTemplateData`.

## What this file does not claim

- A registered class is not necessarily present in the Fallout: New Vegas corpus.
- A registered class is not necessarily supported by the current `NifReader` extraction API.
- A parsed block is not necessarily a scene node. Many registered types are properties, data blocks,
  controllers, interpolators, collision internals, or extra data consumed by another object.
- NifServer still needs a separate policy for which parsed blocks become Godot nodes, which become data on
  a parent, and which are preserved only for diagnostics or future support.

## Authority

The authoritative list for this snapshot is the sequence of `RegisterFactory<T>()` calls in
`native/nifly/src/Factory.cpp`. The class declarations and inheritance relationships are in
`native/nifly/include/Nodes.hpp`, `Geometry.hpp`, `Objects.hpp`, `Shaders.hpp`, `Particles.hpp`,
`Animation.hpp`, `Skin.hpp`, `ExtraData.hpp`, and `bhk.hpp`.
