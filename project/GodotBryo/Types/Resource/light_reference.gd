@tool
class_name LightReference
extends EsmReference

## LIGH references have no LIGH-specific placement payload beyond the common
## REFR identity and transform. The authored light definition is reached via
## `base`, which is a LightBase after EsmServer rehydration.
