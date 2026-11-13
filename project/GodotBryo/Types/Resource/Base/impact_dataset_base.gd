@tool
class_name ImpactDatasetBase
extends EsmBase

## IPDS (Impact DataSet). Named by WEAP INAM (on 237 of 261 WEAP), EXPL DATA
## offset 28 and CREA CNAM. EsmBase holds EDID. Census: 60 IPDS in
## FalloutNV.esm; DATA is 48 bytes on 55, 40 on 3, 36 on 2 (the last
## materials absent).

## DATA's materials in order, xEdit's names.
const MATERIAL_NAMES := ["Stone", "Dirt", "Grass", "Glass", "Metal", "Wood", "Organic", "Cloth", "Water", "Hollow Metal", "Organic Bug", "Organic Glow"]
const MATERIAL_STONE := 0
const MATERIAL_ORGANIC := 6

## DATA: one IPCT per material (MATERIAL_NAMES), NULL where it has none. Read;
## resolved by ProjectileServer through impact_for().
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var impact_form_ids: PackedInt32Array = PackedInt32Array()


## The IPCT for `material` (MATERIAL_*); null when the set has none.
func impact_for(material: int) -> ImpactBase:
	if material < 0 or material >= impact_form_ids.size() or impact_form_ids[material] == 0:
		return null
	var server := EsmReference.get_esm_server()
	return server.get_base(impact_form_ids[material]) as ImpactBase if server != null else null
