@tool
class_name RaceRecord
extends EsmRecordResource

@export var male_head_parts: Array[RacePartResource] = []
@export var female_head_parts: Array[RacePartResource] = []
@export var male_body_parts: Array[RacePartResource] = []
@export var female_body_parts: Array[RacePartResource] = []

func head_parts(female: bool) -> Array[RacePartResource]:
	return female_head_parts if female else male_head_parts

func body_parts(female: bool) -> Array[RacePartResource]:
	return female_body_parts if female else male_body_parts
