@tool
class_name AlternateTextureCollection
extends Resource

## One entry of a model's Alternate Textures (MODS, MO2S, MO3S or MO4S): a
## TXST that replaces the texture set of one shape in the model's NIF. Each
## entry is a length-prefixed name, a TXST FormID and an s32 index; every one
## of the 1,838 entries in FalloutNV.esm names a TXST.

## 3D Name: the shape, written `<shape name>:<n>`, for example
## `BeardGoatee:0`. Read; not used yet (NifServer would swap the texture set).
## The `:<n>` suffix matches `shape_index` on 291 of the 1,414 suffixed
## entries, so it is not that index.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var shape_name: String = ""
## New Texture: the TXST FormID. Read; resolved into `texture_set`.
var texture_set_form_id: int = 0
## New Texture's TXST. Read; not used yet.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "TextureSetBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var texture_set: TextureSetBase
## 3D Index (s32). Read; not used yet. 0 to 36 in FalloutNV.esm, and -1 on 7
## HDPT entries, each beside an entry for the same shape with index 0. What it
## indexes in the NIF is not confirmed.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var shape_index: int = 0
