extends Node

const GameDataConfigScript := preload("res://game_data_config.gd")
const AlchemyRecordScript := preload("res://gamebryo/alchemy_record.gd")
const LeveledItemRecordScript := preload("res://gamebryo/leveled_item_record.gd")

var failures := 0

func _ready() -> void:
	var config: Dictionary = GameDataConfigScript.resolve()
	var reader := EsmReader.new()
	var data_dir := String(config.get("data_dir", ""))
	if not reader.open(data_dir + GameDataConfigScript.ESM_FILE):
		_fail("FalloutNV.esm opens")
		_finish()
		return
	_ok("FalloutNV.esm opens")

	var factory := EsmResourceFactory.new(reader)
	var npc := factory.load_npc(0x00104C0C)
	if npc == null:
		_fail("Doc Mitchell creates an NpcRecord")
		_finish()
		return
	_ok("Doc Mitchell creates an NpcRecord")
	_check(npc.form_id == 0x00104C0C, "NPC resource owns its FormID")
	_check(npc.record_type == "NPC_", "NPC resource preserves record type")
	_check(npc.race != null and npc.race.form_id == 0x000042C3, "NPC resolves typed RaceRecord")
	_check(npc.hair == null or npc.hair.form_id != 0, "Hair reference is typed or safely unresolved")
	_check(npc.eyes == null or npc.eyes.form_id != 0, "Eyes reference is typed or safely unresolved")
	_check(npc.face_gen != null and npc.face_gen.fggs.size() == 200, "FGGS remains raw and lossless")
	_check(npc.face_gen != null and npc.face_gen.fgga.size() == 120, "FGGA remains raw and lossless")
	_check(npc.face_gen != null and npc.face_gen.fgts.size() == 200, "FGTS remains raw and lossless")
	_check(npc.face_gen != null and npc.face_gen.fggs_decoded and npc.face_gen.fggs_values.size() == 50, "FGGS exposes validated float values")
	_check(npc.face_gen != null and npc.face_gen.fgga_decoded and npc.face_gen.fgga_values.size() == 30, "FGGA exposes validated float values")
	_check(npc.face_gen != null and npc.face_gen.fgts_decoded and npc.face_gen.fgts_values.size() == 50, "FGTS exposes validated float values")
	_check(npc.face_gen != null and npc.face_gen.diagnostics.is_empty(), "FaceGen fixture has no decode diagnostics")
	_check(npc.race != null and not npc.race.body_parts(npc.is_female).is_empty(), "Race resolves gendered body parts")
	_check(npc.race != null and npc.race.head_parts(npc.is_female).size() >= 8, "Race resolves the complete generic head descriptor")
	_check(npc.race != null and npc.race.head_parts(npc.is_female)[1].model_path.is_empty() and not npc.race.head_parts(npc.is_female)[1].icon_path.is_empty(), "Icon-only ears remain represented without fabricated geometry")
	if npc.race != null and npc.race.head_parts(npc.is_female).size() >= 8:
		var head_parts := npc.race.head_parts(npc.is_female)
		_check(head_parts[2].part_type == "mouth" and head_parts[3].part_type == "teeth_lower" and head_parts[4].part_type == "teeth_upper", "Race preserves distinct mouth and upper/lower teeth roles")
		_check(head_parts[5].part_type == "tongue" and head_parts[6].part_type == "eye_left" and head_parts[7].part_type == "eye_right", "Race preserves tongue and left/right eye roles")
	_check(factory.load_npc(0x00104C0C) == npc, "Factory returns the session-cached resource")
	var raul := factory.load_npc(0x000E60EF)
	_check(raul != null, "Raul Tejada resolves as an NPC resource")
	_check(raul != null and raul.race != null and raul.race.body_parts(raul.is_female)[0].model_path != "" and raul.race.body_parts(raul.is_female)[0].icon_path != "", "Ghoul body model and skin override stay paired")
	var veronica := factory.load_npc(0x000E32AA)
	_check(veronica != null, "Veronica Santangelo resolves as an NPC resource")
	var prospector := factory.load_npc(0x0017B586) # NVProspectorFemaleT
	_check(prospector != null and prospector.hair != null, "hair-bearing female NPC resolves a typed HairRecord")
	_check(prospector != null and prospector.hair != null and prospector.hair.form_id == 0x0005DC6B, "hair-bearing fixture preserves the real HAIR FormID")
	_check(prospector != null and prospector.hair != null and not prospector.hair.model_path.is_empty(), "hair-bearing fixture resolves a real hair model path")
	_check(prospector != null and prospector.eyes != null and prospector.eyes.form_id != 0, "hair-bearing fixture resolves a typed EyesRecord")
	for entry in npc.inventory:
		if entry.item_form_id == 0x00015169:
			_check(entry.item_record != null and entry.item_record.get_script() == AlchemyRecordScript, "Stimpak inventory entry resolves AlchemyRecord")
		if entry.item_form_id == 0x0003A2B2:
			_check(entry.item_record != null and entry.item_record.get_script() == LeveledItemRecordScript, "leveled inventory entry resolves LeveledItemRecord")
	_finish()

func _check(condition: bool, label: String) -> void:
	if condition:
		_ok(label)
	else:
		_fail(label)

func _ok(label: String) -> void:
	print("  OK   ", label)

func _fail(label: String) -> void:
	failures += 1
	print("  FAIL ", label)

func _finish() -> void:
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(0 if failures == 0 else 1)
