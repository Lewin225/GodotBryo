@tool
class_name PackageLocationValue
extends Resource

## The decoded union payload of PACK.PLDT/PLD2. It is deliberately lazy:
## packages are shared base data, so eagerly constructing every referenced
## REFR while loading all PACK records would populate unrelated world state.
enum ValueKind {
	REFERENCE = 0,
	CELL = 1,
	CURRENT_LOCATION = 2,
	EDITOR_LOCATION = 3,
	OBJECT_BASE = 4,
	OBJECT_TYPE = 5,
	LINKED_REFERENCE = 6,
	PACKAGE_LOCATION = 7,
}

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var value_kind: ValueKind = ValueKind.REFERENCE
## A canonical authored-reference identity, not a second exposed copy of the
## FormID bytes. Only meaningful for REFERENCE.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var reference_instance_id: String = ""
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var cell_form_id: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var object_base_form_id: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var object_type: PackageLocation.ObjectType = PackageLocation.ObjectType.NONE
## Preserved for diagnostics/round-tripping, but deliberately not inspector
## data: consumers should use the decoded field appropriate to `value_kind`.
var raw_value: int = 0

func resolve_reference(esm_server: Node) -> EsmReference:
	if value_kind != ValueKind.REFERENCE or esm_server == null or not esm_server.has_method("get_reference"):
		return null
	return esm_server.get_reference(reference_instance_id) as EsmReference

func resolve_cell(esm_server: Node) -> EsmBase:
	if value_kind != ValueKind.CELL or esm_server == null or not esm_server.has_method("get_base"):
		return null
	return esm_server.get_base(cell_form_id) as EsmBase

func resolve_object_base(esm_server: Node) -> EsmBase:
	if value_kind != ValueKind.OBJECT_BASE or esm_server == null or not esm_server.has_method("get_base"):
		return null
	return esm_server.get_base(object_base_form_id) as EsmBase
