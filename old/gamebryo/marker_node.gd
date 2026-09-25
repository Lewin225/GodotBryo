class_name MarkerNode
extends GamebryoObject

## Bethesda's own "Marker" model-name convention (MarkerCOCHeading.nif,
## Marker_Audio.NIF, MarkerXHeading.nif, ...) -- Construction-Kit-only helper
## objects, never meant to be visible or physically solid in actual gameplay
## (phases/2/07-runtime-cell-loader.md). Confirmed directly against the NIF
## data (not assumed): no NiStringExtraData/"EditorMarker" tag exists on
## these in this game (unlike some later Bethesda titles), and the shapes'
## own internal names are just the model filename repeated -- the model
## filename is the only identifying signal Bethesda actually left. Kept as a
## real node (GamebryoObject: identity + transform, no mesh, no collision --
## GamebryoReference is Node3D, so no physics body at all unless a
## composed GamebryoCollisionBody child is added, and MarkerNode never adds
## one) rather than discarded, so future work can key off marker_kind to
## build real typed behavior (e.g. an
## Audio marker becoming an AudioStreamPlayer3D-driven node) without needing
## to touch placement/registry plumbing again.

var marker_kind: String = "" # model's basename without extension, e.g. "MarkerCOCHeading"

static func is_marker_model(model_path: String) -> bool:
	return "marker" in String(model_path).get_file().to_lower()

static func kind_from_model(model_path: String) -> String:
	return String(model_path).get_file().get_basename()
