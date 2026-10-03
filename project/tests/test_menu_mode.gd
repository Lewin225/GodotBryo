extends Node

## Menu mode (ScriptServer.enter_menu / exit_menu): MenuMode blocks and the
## MenuMode function, quest scripts and dialogue pausing; the name and race
## menus writing the player's NPC_ and marking it dirty; SexChange; a dirty
## base not rehydrated from the ESM.

const NAME_MENU := preload("res://name_menu.tscn")
const RACE_MENU := preload("res://race_menu.tscn")
const SPECIAL_MENU := preload("res://special_menu.tscn")
const TAG_SKILLS_MENU := preload("res://tag_skills_menu.tscn")
const TRAIT_MENU := preload("res://trait_menu.tscn")

var failures := 0

func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1

func _ready() -> void:
	var esm_server = get_node("/root/EsmServer")
	if not esm_server.is_ready():
		await esm_server.esm_ready
	var quests = get_node("/root/QuestServer")
	var dialogue = get_node("/root/DialogueServer")
	var script_server = get_node("/root/ScriptServer")
	var player: ActorReference = esm_server.get_player_reference()
	script_server.player_reference = player
	var player_base: NpcBase = player.base
	var registry: ScriptFunctionRegistry = script_server.function_registry
	var none := ScriptExecutionContext.new(null)

	# Entering and leaving; the MenuMode function and its groups.
	check(not script_server.is_menu_mode() and registry.call_function("MenuMode", [], none) == 0, "the game starts outside menu mode")
	script_server.enter_menu(script_server.MENU_COMPUTERS)
	check(script_server.is_menu_mode() and registry.call_function("MenuMode", [], none) == 1 and registry.call_function("MenuMode", [1057], none) == 1
			and registry.call_function("MenuMode", [1001], none) == 0 and registry.call_function("MenuMode", [2], none) == 1
			and registry.call_function("MenuMode", [1], none) == 0, "with Computers open: MenuMode, MenuMode 1057 and 2 are 1; 1001 and 1 are 0")
	script_server.enter_menu(script_server.MENU_MESSAGE)
	script_server.exit_menu(script_server.MENU_COMPUTERS)
	check(script_server.is_menu_mode() and script_server.get_menu() == 1001, "closing one of two menus stays in menu mode")
	script_server.exit_menu(script_server.MENU_MESSAGE)
	check(not script_server.is_menu_mode(), "closing the last leaves it")

	# Quest scripts run MenuMode for the open menu: VCG01's MenuMode 1036 block
	# sets stage 40 from 36.
	var vcg01: QuestBase = esm_server.find_quest_by_editor_id("VCG01")
	quests.reset_quest(vcg01)
	quests.start_quest(vcg01)
	quests.get_quest_state(vcg01).stage = 36
	script_server.enter_menu(script_server.MENU_RACE)
	quests._process(quests.get_script_delay(vcg01) + 0.1)
	script_server.exit_menu(script_server.MENU_RACE)
	check(quests.get_stage(vcg01) == 40, "with the race menu open, VCG01's MenuMode 1036 block moves stage 36 to 40 (%d)" % quests.get_stage(vcg01))

	# Dialogue pauses in menu mode.
	var doc: EsmReference = esm_server.find_reference_by_editor_id("DocMitchellREF")
	var intro: DialogueTopicBase = esm_server.find_base_by_editor_id("VCG01Intro")
	dialogue.reset()
	quests.reset_quest(vcg01)
	quests.start_quest(vcg01)
	var line: DialogueLine = dialogue.say(doc, intro, player)
	dialogue.wait_for_loads()
	script_server.enter_menu(script_server.MENU_MESSAGE)
	dialogue._process(60.0)
	var paused: bool = dialogue.get_line(doc) == line and line.elapsed == 0.0
	script_server.exit_menu(script_server.MENU_MESSAGE)
	dialogue._process(60.0)
	check(paused and dialogue.get_line(doc) != line, "a line does not advance in menu mode and finishes after")
	dialogue.reset()
	quests.stop_quest(vcg01)
	quests.reset_quest(vcg01)

	# The name menu sets the player NPC_'s FULL (empty in FalloutNV.esm).
	var authored_name := player_base.full_name
	var authored_flags := player_base.acbs_flags
	var name_menu: NameMenu = NAME_MENU.instantiate()
	add_child(name_menu)
	name_menu.open(player)
	check(script_server.get_menu() == script_server.MENU_TEXT_EDIT, "the name menu is menu 1051 (TextEdit)")
	name_menu.get_node("Root/Panel/Margin/VBox/Name").text = "Courier Six"
	name_menu.accept()
	check(player_base.full_name == "Courier Six" and player_base.dirty and not script_server.is_menu_mode(),
			"accepting sets the player NPC_'s FULL, marks it dirty and leaves menu mode")

	# The race menu sets its Female flag.
	var race_menu: RaceMenu = RACE_MENU.instantiate()
	add_child(race_menu)
	race_menu.open(player)
	check(script_server.get_menu() == script_server.MENU_RACE, "the race menu is menu 1036")
	race_menu.get_node("Root/Panel/Margin/VBox/Sex/Female").button_pressed = true
	race_menu.accept()
	check(player_base.is_female() and registry.call_function("GetIsSex", ["Female"], ScriptExecutionContext.new(player)) == 1,
			"choosing Female sets the player NPC_'s ACBS Female flag; GetIsSex Female is 1")

	# The vigor tester's SPECIAL menu: 40 points over the player's 5s leaves 5.
	var values := player.get_actor_values()
	var authored_luck := values.get_base(ActorValue.LUCK)
	var special_menu: SpecialMenu = SPECIAL_MENU.instantiate()
	add_child(special_menu)
	special_menu.open(player, {"points": 40})
	check(script_server.get_menu() == script_server.MENU_LOVE_TESTER and special_menu.remaining() == 5,
			"the SPECIAL menu is 1074 with 5 of 40 points left (%d)" % special_menu.remaining())
	special_menu.accept()
	check(special_menu.visible, "it does not close with points left")
	special_menu.set_attribute(6, 10)
	special_menu.accept()
	check(not special_menu.visible and values.get_base(ActorValue.LUCK) == 10.0 and not script_server.is_menu_mode(),
			"spending them on Luck sets the player's base Luck to 10 and closes it")
	values.set_base(ActorValue.LUCK, authored_luck)
	special_menu.queue_free()
	script_server.run_debug_line("ShowLoveTesterMenuParams 40")
	check(not script_server.is_menu_mode(), "with no UI, ShowLoveTesterMenuParams opens and closes menu 1074 at once")

	# The tag skills menu closes once exactly the asked-for count is chosen.
	var tag_menu: TagSkillsMenu = TAG_SKILLS_MENU.instantiate()
	add_child(tag_menu)
	tag_menu.open(player, {"count": 3})
	tag_menu.set_chosen(0, true)
	tag_menu.set_chosen(3, true)
	tag_menu.accept()
	var open_with_two: bool = tag_menu.visible and script_server.get_menu() == script_server.MENU_CHARGEN
	tag_menu.set_chosen(12, true)
	check(open_with_two and tag_menu.chosen() == [ActorValue.BARTER, ActorValue.GUNS, ActorValue.UNARMED],
			"the tag skills menu is 1048 and stays open with 2 of 3 chosen")
	tag_menu.accept()
	check(not tag_menu.visible and not script_server.is_menu_mode(), "with 3 it closes")
	tag_menu.queue_free()
	var trait_menu: TraitMenu = TRAIT_MENU.instantiate()
	add_child(trait_menu)
	trait_menu.open(player)
	var trait_menu_id: int = script_server.get_menu()
	trait_menu.accept()
	check(trait_menu_id == script_server.MENU_TRAITS and not script_server.is_menu_mode() and trait_menu.max_traits() == 2,
			"the trait menu is 1084, allows iTraitMenuMaxNumTraits (2) and Done closes it (%d)" % trait_menu.max_traits())
	trait_menu.queue_free()

	# SexChange changes the NPC_ too.
	script_server.run_debug_line("player.SexChange Male 1")
	check(not player_base.is_female(), "player.SexChange Male clears it")

	# A dirty base is not rehydrated from the ESM.
	player_base.full_name = "Changed"
	player_base._auto_rehydrate()
	check(player_base.full_name == "Changed", "rehydrating a dirty base leaves its fields")
	player_base.dirty = false
	esm_server.rehydrate(player_base)
	check(player_base.full_name == authored_name and player_base.acbs_flags == authored_flags, "a clean one is refilled from the ESM")

	name_menu.queue_free()
	race_menu.queue_free()
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
