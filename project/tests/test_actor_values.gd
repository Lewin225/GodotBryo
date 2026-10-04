extends Node

## ActorValues against shipped NPC_ and CREA records: authored stats, derived
## values, templates, the modifier layers and the script functions.

var failures := 0

func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1

func _ready() -> void:
	var esm_server = get_node("/root/EsmServer")
	if not esm_server.is_ready():
		await esm_server.esm_ready
	var script_server = get_node("/root/ScriptServer")
	await get_tree().process_frame

	# Game settings: FalloutNV.esm's GMSTs, else the engine default.
	check(is_equal_approx(float(esm_server.get_game_setting("fAVDHealthEnduranceMult")), 20.0), "GMST fAVDHealthEnduranceMult is 20")
	check(esm_server.get_game_setting("fAVDNPCHealthEnduranceOffset") == null and ActorValue.setting("fAVDNPCHealthEnduranceOffset") == -1.0,
			"a setting absent from the ESM uses the engine default")
	check(ActorValue.from_name("health") == ActorValue.HEALTH and ActorValue.from_name("SmallGuns") == ActorValue.GUNS
			and ActorValue.from_name("NoSuchValue") == -1, "actor value names resolve case-insensitively")

	# Doc Mitchell (NPC_ 0x104C0C): DATA base health 50, SPECIAL 4 6 4 6 7 5 4,
	# level 1, DNAM Medicine 33.
	var doc: ActorReference = esm_server.create_reference_for_base(0x104C0C)
	check(doc.actor_values != null and doc.actor_values.owner == doc, "a created actor reference has its ActorValues")
	var doc_values := doc.get_actor_values()
	check(doc_values.current_values["Health"] == 65.0 and doc_values.current_values.size() == ActorValue.COUNT,
			"current_values lists every actor value by name")
	check(doc_values.get_base(ActorValue.ENDURANCE) == 4 and doc_values.get_base(ActorValue.INTELLIGENCE) == 7, "SPECIAL from NPC_ DATA")
	check(doc_values.get_base(ActorValue.MEDICINE) == 33, "skills from NPC_ DNAM")
	check(doc_values.get_level() == 1, "level from ACBS")
	check(doc_values.get_base(ActorValue.HEALTH) == 65.0, "NPC health: 50 + (4 - 1) x 5 (%.1f)" % doc_values.get_base(ActorValue.HEALTH))
	check(doc_values.get_base(ActorValue.PERCEPTION_CONDITION) == 100.0, "limb conditions start at 100")

	# The player (NPC_ 0x7): base health 100, all SPECIAL 5.
	var player: ActorReference = esm_server.get_player_reference()
	var player_values := player.get_actor_values()
	check(player_values.get_base(ActorValue.HEALTH) == 200.0, "player health: 100 + 5 x 20 (%.1f)" % player_values.get_base(ActorValue.HEALTH))
	check(player_values.get_base(ActorValue.ACTION_POINTS) == 80.0 and player_values.get_base(ActorValue.CARRY_WEIGHT) == 200.0,
			"action points 65 + 5 x 3, carry weight 150 + 5 x 10")

	# The player formula at Endurance 10 and level 30: 100 + 10 x 20 + 29 x 5.
	var max_player := NpcBase.new()
	max_player.base_health = 100
	max_player.attributes[ActorValue.ENDURANCE - ActorValue.STRENGTH] = 10
	check(ActorValue.derive_base(ActorValue.HEALTH, max_player, 30, true) == 445.0, "player health at Endurance 10, level 30 is 445")

	# Rex (CREA 0x118E71): DATA health 22, level multiplier 0.75 of the player's.
	var rex: CreatureReference = esm_server.create_reference_for_base(0x118E71)
	var rex_values := rex.get_actor_values()
	check(rex_values.get_base(ActorValue.HEALTH) == 22.0 and rex_values.get_base(ActorValue.PERCEPTION) == 8, "creature health and SPECIAL from CREA DATA")
	check(rex_values.get_level() >= 1, "a PC-level-mult creature has a level (%d)" % rex_values.get_level())

	# An NPC_ whose stats come from an NPC_ template derives from the template's.
	var templated: NpcBase = null
	var template: NpcBase = null
	for row: Dictionary in esm_server.get_record_index():
		if String(row.get("record_type", "")) != "NPC_":
			continue
		var npc := esm_server.get_base(int(row["form_id"])) as NpcBase
		if (npc.template_flags & ActorBase.TEMPLATE_USE_STATS) != 0 and npc.template is NpcBase:
			var candidate: NpcBase = npc.template
			if (candidate.template_flags & ActorBase.TEMPLATE_USE_STATS) == 0 and candidate.base_health != npc.base_health:
				templated = npc
				template = candidate
				break
	check(templated != null, "found an NPC_ taking stats from an NPC_ template with different DATA")
	if templated != null:
		var templated_reference: EsmReference = esm_server.create_reference_for_base(templated.form_id)
		var from_template: ActorValues = templated_reference.get_actor_values()
		check(from_template.get_stats() == template, "templated stats come from the template (%s -> %s)" % [templated.editor_id, template.editor_id])

	# Modifier layers.
	doc_values.set_base(ActorValue.STRENGTH, 6)
	check(doc_values.get_base(ActorValue.STRENGTH) == 6.0, "SetAV replaces the base")
	doc_values.modify(ActorValue.STRENGTH, 2)
	check(doc_values.get_permanent(ActorValue.STRENGTH) == 8.0 and doc_values.get_current(ActorValue.STRENGTH) == 8.0, "ModAV changes the permanent value")
	doc_values.damage_value(ActorValue.STRENGTH, 3)
	check(doc_values.get_current(ActorValue.STRENGTH) == 5.0 and doc_values.get_permanent(ActorValue.STRENGTH) == 8.0, "DamageAV lowers only the current value")
	doc_values.force(ActorValue.STRENGTH, 10)
	check(doc_values.get_current(ActorValue.STRENGTH) == 10.0 and doc_values.get_permanent(ActorValue.STRENGTH) == 13.0, "ForceAV = ModAV by (value - current)")
	doc_values.restore_value(ActorValue.STRENGTH, 100)
	check(doc_values.get_current(ActorValue.STRENGTH) == 13.0, "RestoreAV stops at no damage")

	# Script functions on the calling actor.
	check(script_server.run_debug_line("GetAV Health", doc).get("result") == 65.0, "GetAV Health")
	script_server.run_debug_line("DamageAV Health 50", player)
	check(is_equal_approx(float(script_server.run_debug_line("GetHealthPercentage", player).get("result")), 0.75), "GetHealthPercentage after damage (150 / 200)")
	script_server.run_debug_line("RestoreActorValue Health 50", player)
	script_server.player_reference = player
	check(is_equal_approx(float(script_server.run_debug_line("player.GetHealthPercentage").get("result")), 1.0), "player.GetHealthPercentage after restore")
	script_server.player_reference = null
	check(script_server.run_debug_line("GetBaseAV Medicine", doc).get("result") == 33.0 and script_server.run_debug_line("GetLevel", doc).get("result") == 1,
			"GetBaseAV and GetLevel")
	script_server.run_debug_line("SetAV Variable01 3", doc)
	check(script_server.run_debug_line("GetActorValue Variable01", doc).get("result") == 3.0, "SetAV / GetActorValue Variable01")
	check(script_server.run_debug_line("GetAV Health", esm_server.create_reference_for_base(0x000E3778)).get("result") == 0,
			"a non-actor has no actor values")

	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
