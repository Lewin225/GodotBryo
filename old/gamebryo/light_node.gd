class_name LightNode
extends GamebryoVisual

## LIGH. Unlike the rest of Tier 1, this genuinely needs more than the
## shared GamebryoVisual shape — a real Light3D child, not just mesh
## children (which may not even exist: checked GSDocMitchellHouse directly,
## all 25 of its LIGH refs have an empty MODL, pure ambient/fill/key rig
## lights with no fixture). See phases/1/03-light-sources.md and
## phases/1/architecture.md's Tier 2.
