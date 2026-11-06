@tool
class_name LightReference
extends EsmReference

## XEMI: the LIGH or REGN whose colour tints this placement's shapes flagged
## External_Emittance; 0 when absent. Read; used by EsmNode to tint those
## shapes' materials per placement.
## Distinct from the placed light's own LIGH base.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var emittance_form_id: int = 0
