class_name ScriptFunctionRegistry
extends RefCounted

## Script function table: name -> Callable(args: Array, ctx:
## ScriptExecutionContext) -> Variant, grown at runtime through register().
## Calling an unregistered name logs once and returns 0.

var _functions := {} # lowercased name -> Callable
var _canonical_names: Array[String] = [] # Original registered names for autocomplete/reflection
var _warned_missing := {} # "name|SCPT" -> true: one warning per function per script, not every frame

## ESM reader for record lookups such as ShowMessage's MESG. Null until set.
var esm: EsmReader = null
## Script coordinates are Gamebryo units; references use metres
## (native/src/common/units.h is the authority for 70 units per metre).
const GAMEBRYO_UNITS_TO_METERS := 1.0 / 70.0
## The player's physics body, for commands that act on the body itself
## (ToggleCollision). Null when there is no player.
var player_node: Node = null
## Source of game time. Time functions return 0 while it is null.
var game_time_manager: GameTimeManager = null
## World-facing commands delegate to handlers registered by the scene that
## owns the loaders. PlaceAtMe receives (args, calling_reference).
var place_at_me_handler: Callable
## The ScriptServer that performs activation, locking and unlocking for the
## Activate, Lock and Unlock commands. Null in a bare registry.
var script_server: Object = null
var center_on_cell_handler: Callable
var show_message_handler: Callable
var get_button_pressed_handler: Callable

func _init() -> void:
	_register_defaults()

## Registers `fn` under a name, or an Array of names: the full name and its
## short aliases (`["GetActorValue", "GetAV"]`). Names are case-insensitive.
func register(names: Variant, fn: Callable) -> void:
	for name: String in (names if names is Array else [names]):
		_functions[name.to_lower()] = fn
		if not _canonical_names.has(name):
			_canonical_names.append(name)

func is_registered(name: String) -> bool:
	return _functions.has(name.to_lower())

func get_registered_function_names() -> Array[String]:
	return _canonical_names.duplicate()

func call_function(name: String, args: Array, ctx: ScriptExecutionContext) -> Variant:
	var lower := name.to_lower()
	if _functions.has(lower):
		return _functions[lower].call(args, ctx)
	# Once per function per script, so every script calling it is listed.
	var warn_key := "%s|%d" % [lower, ctx.instance.script_form_id if ctx != null and ctx.instance != null else 0]
	if not _warned_missing.has(warn_key):
		_warned_missing[warn_key] = true
		push_warning("ScriptFunctionRegistry: unimplemented script function '%s' in %s -- evaluates to 0/false"
				% [name, ctx.describe() if ctx != null else "an unknown script"])
	return 0

func _register_defaults() -> void:
	# `Abs x`, `Sqrt x`: the math functions shipped scripts call (Abs per the
	# GECK wiki's Abs page; Sqrt from its use in shipped scripts). Sqrt of a
	# negative number gives 0 here; the original's result is not known.
	register("Abs", func(a: Array, _c): return absf(_number(a, 0)))
	register("Sqrt", func(a: Array, _c): return sqrt(maxf(_number(a, 0), 0.0)))
	# Real seconds since the calling script last ran.
	register("GetSecondsPassed", func(_a, ctx: ScriptExecutionContext):
		return ctx.seconds_passed)
	register("GameDaysPassed", func(_a, _c):
		if game_time_manager != null:
			return game_time_manager.game_days_passed
		return 0.0)
	register("GetCurrentTime", func(_a, _c):
		if game_time_manager != null:
			return game_time_manager.game_hour
		return 0.0)
	register("GetRandomPercent", func(_a, _c): return randi_range(0, 99))

	register("Enable", func(_a, ctx: ScriptExecutionContext):
		var node := EsmNode.node_for(ctx.calling_reference)
		if node == null:
			return 0
		node.visible = true
		EsmNode.set_collision_disabled(node, false)
		return 1)

	register("Disable", func(_a, ctx: ScriptExecutionContext):
		var node := EsmNode.node_for(ctx.calling_reference)
		if node == null:
			return 0
		node.visible = false
		EsmNode.set_collision_disabled(node, true)
		return 1)

	register("GetDisabled", func(_a, ctx: ScriptExecutionContext):
		var node := EsmNode.node_for(ctx.calling_reference)
		if node == null:
			return 0
		return 0 if node.visible else 1)

	# `[Ref.]Activate [ActionRef] [RunOnActivateBlockFlag]`. The activator is
	# ActionRef when given, else this dispatch's action reference. With the
	# flag 1 the target's OnActivate block runs as for any activation;
	# otherwise the built-in activation runs directly, so `Activate` inside a
	# target's own OnActivate block does not re-enter it.
	register("Activate", func(a: Array, ctx: ScriptExecutionContext):
		var target := ctx.calling_reference
		if target == null or script_server == null:
			return 0
		var activator: EsmReference = a[0] if a.size() > 0 and a[0] is EsmReference else ctx.action_ref
		var run_block := a.size() > 1 and ScriptExecutionContext.is_truthy(a[1])
		if run_block:
			script_server.activate(target, activator)
		else:
			script_server.default_activate(target, activator)
		return 1)

	# `[Ref.]MoveTo Target [x y z]`: moves the calling reference to Target's
	# space and position plus the offset (Gamebryo units), taking Target's
	# rotation.
	register("MoveTo", func(a: Array, ctx: ScriptExecutionContext):
		var target: Variant = a[0] if a.size() > 0 else null
		if ctx.calling_reference == null or not target is EsmReference or script_server == null:
			return 0
		var offset := Vector3(_number(a, 1), _number(a, 2), _number(a, 3)) * GAMEBRYO_UNITS_TO_METERS
		var marker := target as EsmReference
		script_server.move_reference(ctx.calling_reference, marker.current_space_form_id, marker.position + offset, marker.rotation)
		return 1)

	# `[Ref.]PositionCell x y z zRot CellID`: Gamebryo units, degrees; the
	# CELL by editor ID. Keeps the reference's x/y rotation.
	register("PositionCell", func(a: Array, ctx: ScriptExecutionContext):
		var esm_server := EsmReference.get_esm_server()
		if ctx.calling_reference == null or a.size() < 5 or script_server == null or esm_server == null:
			return 0
		var cell: int = esm_server.find_form_id_by_editor_id(str(a[4]))
		if cell == 0:
			return 0
		_position(ctx.calling_reference, esm_server.get_space_form_id_for_cell(cell), a)
		return 1)

	# `[Ref.]PositionWorld x y z zRot WorldspaceID`: as PositionCell, in a
	# worldspace named by editor ID.
	register("PositionWorld", func(a: Array, ctx: ScriptExecutionContext):
		var esm_server := EsmReference.get_esm_server()
		if ctx.calling_reference == null or a.size() < 5 or script_server == null or esm_server == null:
			return 0
		var worldspace: int = esm_server.find_form_id_by_editor_id(str(a[4]))
		if worldspace == 0:
			return 0
		_position(ctx.calling_reference, worldspace, a)
		return 1)

	# `[Ref.]Lock [Level]` / `[Ref.]Unlock` on the calling reference.
	register("Lock", func(a: Array, ctx: ScriptExecutionContext):
		if ctx.calling_reference == null or script_server == null:
			return 0
		script_server.lock(ctx.calling_reference, int(a[0]) if a.size() > 0 and (a[0] is int or a[0] is float) else -1)
		return 1)

	register("IsActionRef", func(a: Array, ctx: ScriptExecutionContext):
		if a.is_empty() or ctx.action_ref == null:
			return 0
		# a[0] is a reference, or the text of a name that did not resolve.
		return 1 if ScriptExecutionContext.safe_equal(a[0], ctx.action_ref) else 0)

	register("GetActionRef", func(_a, ctx: ScriptExecutionContext):
		return ctx.action_ref)

	register("GetSelf", func(_a, ctx: ScriptExecutionContext):
		return ctx.calling_reference)

	# Quests, named by editor ID: `GetStage Quest`, `GetStageDone Quest Stage`,
	# `SetStage Quest Stage`, `StartQuest Quest`, `StopQuest Quest`,
	# `GetQuestRunning Quest`, `GetQuestCompleted Quest`,
	# `SetQuestDelay Quest Seconds`.
	register("GetStage", func(a: Array, _c):
		var quests := _quest_server()
		return quests.get_stage(_quest(a, 0)) if quests != null else 0)
	register("GetStageDone", func(a: Array, _c):
		var quests := _quest_server()
		return 1 if quests != null and quests.is_stage_done(_quest(a, 0), int(_number(a, 1))) else 0)
	register("SetStage", func(a: Array, _c):
		var quests := _quest_server()
		var quest := _quest(a, 0)
		if quests == null or quest == null:
			return 0
		quests.set_stage(quest, int(_number(a, 1)))
		return 1)
	register("StartQuest", func(a: Array, _c):
		var quests := _quest_server()
		if quests == null or _quest(a, 0) == null:
			return 0
		quests.start_quest(_quest(a, 0))
		return 1)
	register("StopQuest", func(a: Array, _c):
		var quests := _quest_server()
		if quests == null or _quest(a, 0) == null:
			return 0
		quests.stop_quest(_quest(a, 0))
		return 1)
	register("GetQuestRunning", func(a: Array, _c):
		var quests := _quest_server()
		return 1 if quests != null and quests.is_running(_quest(a, 0)) else 0)
	# The platform: this engine runs as the PC version.
	register("IsWin32", func(_a: Array, _c): return 1)
	register("IsXBox", func(_a: Array, _c): return 0)
	register("IsPS3", func(_a: Array, _c): return 0)
	# `GetGlobalValue Global`: a global's current value, the GLOB as a condition
	# passes it or by editor ID; 0 when it is not a global.
	register("GetGlobalValue", func(a: Array, _c):
		var global := _base_arg(a, 0)
		if global == null or script_server == null:
			return 0
		var value: Variant = script_server.globals.get_global(global.editor_id)
		return value if value != null else 0)
	# `GetQuestVariable Quest Variable`: a quest script variable, named as an
	# SLSD index (conditions) or by name; 0 when the quest or variable is
	# unknown.
	register("GetQuestVariable", func(a: Array, _c):
		var quest := _quest(a, 0)
		if quest == null or script_server == null or a.size() < 2:
			return 0
		return _variable_value(script_server.get_quest_instance(quest), quest.script_form_id, a[1]))
	# `GetScriptVariable Reference Variable`: as GetQuestVariable, on a
	# reference's object script.
	register("GetScriptVariable", func(a: Array, _c):
		var ref: EsmReference = a[0] as EsmReference if not a.is_empty() and a[0] is EsmReference else null
		if ref == null or script_server == null or a.size() < 2:
			return 0
		return _variable_value(script_server.get_script_instance(ref), script_server.get_script_form_id(ref), a[1]))
	register("GetQuestCompleted", func(a: Array, _c):
		var quests := _quest_server()
		return 1 if quests != null and quests.is_completed(_quest(a, 0)) else 0)
	register("SetQuestDelay", func(a: Array, _c):
		var quests := _quest_server()
		if quests == null or _quest(a, 0) == null:
			return 0
		quests.set_script_delay(_quest(a, 0), _number(a, 1))
		return 1)

	# Quest state: `CompleteQuest Quest`, `FailQuest Quest`, `ResetQuest Quest`,
	# `CompleteAllObjectives Quest`, `SetActiveQuest Quest`.
	register("CompleteQuest", func(a: Array, _c):
		return _apply_to_quest(a, "complete_quest"))
	register("FailQuest", func(a: Array, _c):
		return _apply_to_quest(a, "fail_quest"))
	register("ResetQuest", func(a: Array, _c):
		return _apply_to_quest(a, "reset_quest"))
	register("CompleteAllObjectives", func(a: Array, _c):
		return _apply_to_quest(a, "complete_all_objectives"))
	register("SetActiveQuest", func(a: Array, _c):
		var quests := _quest_server()
		var quest := _quest(a, 0)
		if quests == null or quest == null:
			return 0
		quests.active_quest = quest
		return 1)
	# `SetQuestObject Item Flag`: 1 makes the item a quest item, 0 does not.
	register("SetQuestObject", func(a: Array, _c):
		var quests := _quest_server()
		var esm_server := EsmReference.get_esm_server()
		var item: EsmBase = esm_server.find_base_by_editor_id(str(a[0])) if not a.is_empty() and esm_server != null and esm_server.is_ready() else null
		if quests == null or item == null or not _is_number(a, 1):
			return 0
		quests.set_quest_object(item, _number(a, 1) != 0.0)
		return 1)

	# Quest objectives, by QOBJ index: `SetObjectiveDisplayed Quest Index Flag`,
	# `SetObjectiveCompleted Quest Index Flag` (Flag 1 sets, 0 clears),
	# `GetObjectiveDisplayed Quest Index`, `GetObjectiveCompleted Quest Index`.
	register("GetObjectiveDisplayed", func(a: Array, _c):
		return _read_objective(a, "is_objective_displayed"))
	register("GetObjectiveCompleted", func(a: Array, _c):
		return _read_objective(a, "is_objective_completed"))
	register("SetObjectiveDisplayed", func(a: Array, _c):
		return _change_objective(a, "set_objective_displayed", "SetObjectiveDisplayed"))
	register("SetObjectiveCompleted", func(a: Array, _c):
		return _change_objective(a, "set_objective_completed", "SetObjectiveCompleted"))

	# Inventory of the calling reference (actor, creature or container). Items
	# are named by base editor ID; a leveled list resolves when added.
	register("GetItemCount", func(a: Array, ctx: ScriptExecutionContext):
		var inventory := _inventory_of(ctx.calling_reference)
		var item := _base_arg(a, 0)
		return inventory.get_item_count(item.form_id) if inventory != null and item != null else 0)
	# `AddItem Item Count [HideMessage]`.
	register("AddItem", func(a: Array, ctx: ScriptExecutionContext):
		var esm_server := EsmReference.get_esm_server()
		var item := _base_arg(a, 0)
		if esm_server == null or item == null:
			return 0
		return 1 if esm_server.add_inventory_items(ctx.calling_reference, item, maxi(int(_number(a, 1)), 1)) > 0 else 0)
	# `RemoveItem Item Count [HideMessage]`: removes up to Count, across stacks.
	register("RemoveItem", func(a: Array, ctx: ScriptExecutionContext):
		var inventory := _inventory_of(ctx.calling_reference)
		var item := _base_arg(a, 0)
		if inventory == null or item == null:
			return 0
		return 1 if _remove_items(inventory, item.form_id, maxi(int(_number(a, 1)), 1)) > 0 else 0)
	# `RemoveAllItems [TargetContainer] [RetainOwnership]`: moves every item to
	# the target's inventory, or removes them when there is no target.
	register("RemoveAllItems", func(a: Array, ctx: ScriptExecutionContext):
		var inventory := _inventory_of(ctx.calling_reference)
		if inventory == null:
			return 0
		var target := _inventory_of(a[0] as EsmReference) if not a.is_empty() and a[0] is EsmReference else null
		var moving := inventory.get_items()
		inventory.clear()
		if target != null:
			for item in moving:
				item.is_equipped = false
				target.add_inventory_item(item)
		return 1)
	# `EquipItem Item [NoUnequip] [HideMessage]`: equips the item, adding one
	# when the actor has none.
	register("EquipItem", func(a: Array, ctx: ScriptExecutionContext):
		var inventory := _inventory_of(ctx.calling_reference)
		var item := _base_arg(a, 0)
		var esm_server := EsmReference.get_esm_server()
		if inventory == null or item == null:
			return 0
		var owned := _first_item(inventory, item.form_id)
		if owned == null and esm_server != null and esm_server.add_inventory_items(ctx.calling_reference, item, 1) > 0:
			owned = _first_item(inventory, item.form_id)
		return 1 if owned != null and inventory.equip_item(owned) else 0)
	# `UnequipItem Item [NoEquip] [HideMessage]`.
	register("UnequipItem", func(a: Array, ctx: ScriptExecutionContext):
		var inventory := _inventory_of(ctx.calling_reference)
		var item := _base_arg(a, 0)
		if inventory == null or item == null:
			return 0
		for owned in inventory.get_equipped_items():
			if owned.item_reference != null and owned.item_reference.base_form_id == item.form_id:
				inventory.unequip_item(owned)
		return 1)
	register("GetEquipped", func(a: Array, ctx: ScriptExecutionContext):
		var inventory := _inventory_of(ctx.calling_reference)
		var item := _base_arg(a, 0)
		if inventory == null or item == null:
			return 0
		for owned in inventory.get_equipped_items():
			if owned.item_reference != null and owned.item_reference.base_form_id == item.form_id:
				return 1
		return 0)

	# Identity and location of the calling reference.
	register("GetIsID", func(a: Array, ctx: ScriptExecutionContext):
		var base := _base_arg(a, 0)
		return 1 if ctx.calling_reference != null and base != null and ctx.calling_reference.base_form_id == base.form_id else 0)
	register("GetIsReference", func(a: Array, ctx: ScriptExecutionContext):
		return 1 if ctx.calling_reference != null and not a.is_empty() and a[0] is EsmReference and a[0] == ctx.calling_reference else 0)
	# `GetIsSex Male|Female` (conditions pass 0 or 1): the NPC_'s ACBS Female
	# flag, from its template when that supplies traits; 0 for anything else.
	register("GetIsSex", func(a: Array, ctx: ScriptExecutionContext):
		var source := _actor_part(ctx.calling_reference, ActorStats.TEMPLATE_USE_TRAITS) as NpcBase
		var wants_female := _sex_arg(a, 0)
		if source == null or wants_female < 0:
			return 0
		return 1 if source.is_female() == (wants_female == 1) else 0)
	# `GetIsVoiceType VoiceType`: the actor's VTCK (from its template when that
	# supplies traits) is the VTYP, or is in the FLST of them.
	register("GetIsVoiceType", func(a: Array, ctx: ScriptExecutionContext):
		var source := _actor_part(ctx.calling_reference, ActorStats.TEMPLATE_USE_TRAITS)
		var voice := _base_arg(a, 0)
		if source == null or voice == null:
			return 0
		var voice_type: int = source.get("voice_type_form_id")
		if voice.record_type == "FLST":
			for entry in voice.all_subrecord_data("LNAM"):
				if entry.size() >= 4 and entry.decode_u32(0) == voice_type:
					return 1
			return 0
		return 1 if voice.form_id == voice_type else 0)
	# `GetInFaction Faction`: the actor's SNAM (from its template when that
	# supplies factions) names the FACT with a rank of 0 or more.
	register("GetInFaction", func(a: Array, ctx: ScriptExecutionContext):
		return 1 if _faction_rank(ctx.calling_reference, _base_arg(a, 0)) >= 0 else 0)
	# `GetFactionRank Faction`: the actor's rank in the FACT, or -1.
	register("GetFactionRank", func(a: Array, ctx: ScriptExecutionContext):
		return _faction_rank(ctx.calling_reference, _base_arg(a, 0)))
	# `GetTalkedToPC`: whether the actor has talked to the player.
	register("GetTalkedToPC", func(_a: Array, ctx: ScriptExecutionContext):
		var dialogue := _dialogue_server()
		return 1 if dialogue != null and dialogue.has_talked_to_player(ctx.calling_reference) else 0)
	# `[Actor.]SayTo Target Topic [ForceSubtitle] [NoTargetLook]`: the calling
	# actor says the topic's chosen INFO to Target. Returns 0, as the GECK
	# documents; subtitles always show and Target does not turn to look.
	register("SayTo", func(a: Array, ctx: ScriptExecutionContext):
		var dialogue := _dialogue_server()
		var topic := _base_arg(a, 1) as DialogueTopicBase
		if dialogue != null and ctx.calling_reference != null and topic != null and a[0] is EsmReference:
			dialogue.say(ctx.calling_reference, topic, a[0])
		return 0)
	# `[Actor.]Say Topic [ForceSubtitle] ...`: the calling actor says the
	# topic's chosen INFO to no one in particular.
	register("Say", func(a: Array, ctx: ScriptExecutionContext):
		var dialogue := _dialogue_server()
		var topic := _base_arg(a, 0) as DialogueTopicBase
		if dialogue != null and ctx.calling_reference != null and topic != null:
			dialogue.say(ctx.calling_reference, topic, null)
		return 0)
	# `[Speaker.]StartConversation Target [Topic]`: with the player as Target,
	# the speaker starts a conversation with the topic, GREETING when none is
	# given. The speaker does not walk to the player first. Conversations
	# between NPCs are not implemented.
	register("StartConversation", func(a: Array, ctx: ScriptExecutionContext):
		var dialogue := _dialogue_server()
		var target: Variant = a[0] if not a.is_empty() else null
		if dialogue == null or ctx.calling_reference == null or not target is EsmReference or target != script_server.player_reference:
			return 0
		var topic := _base_arg(a, 1) as DialogueTopicBase if a.size() > 1 else null
		return 1 if dialogue.start_conversation(ctx.calling_reference, target, topic) else 0)
	# `AddTopic Topic`: adds the topic to the player's topic list.
	register("AddTopic", func(a: Array, _c):
		var dialogue := _dialogue_server()
		var topic := _base_arg(a, 0) as DialogueTopicBase
		if dialogue == null or topic == null:
			return 0
		dialogue.add_topic(topic)
		return 1)
	# `DisablePlayerControls [Movement Pipboy Fighting POV Looking RolloverText
	# Sneaking]` (each 0 or 1): disables the controls flagged 1; with no
	# arguments, `1 1 1 1 0 0 0`, as the GECK wiki gives it.
	register("DisablePlayerControls", func(a: Array, _c):
		if script_server == null:
			return 0
		script_server.disable_player_controls(_control_flags(a, 0x0F))
		return 1)
	# `EnablePlayerControls [...]`: enables the controls flagged 1, the same
	# flags; with no arguments every control (not verified).
	register("EnablePlayerControls", func(a: Array, _c):
		if script_server == null:
			return 0
		script_server.enable_player_controls(_control_flags(a, 0x7F))
		return 1)
	# `GetPlayerControlsDisabled`: whether any player control is disabled.
	register("GetPlayerControlsDisabled", func(_a: Array, _c):
		return 1 if script_server != null and script_server.disabled_player_controls != 0 else 0)
	# `GetPlayerName` / `ShowNameMenu` opens the name entry menu (1051, TextEdit);
	# it returns nothing useful, as the GECK wiki notes.
	register(["GetPlayerName", "ShowNameMenu"], func(_a: Array, _c):
		if script_server != null:
			script_server.open_menu(script_server.MENU_TEXT_EDIT)
		return 0)
	# `ShowRaceMenu` opens the race menu (1036).
	register("ShowRaceMenu", func(_a: Array, _c):
		if script_server != null:
			script_server.open_menu(script_server.MENU_RACE)
		return 0)
	# `MenuMode [MenuType]`: whether a menu is open, or that menu or group
	# (ScriptServer.is_menu_open).
	register("MenuMode", func(a: Array, _c):
		return 1 if script_server != null and script_server.is_menu_open(int(_number(a, 0)) if not a.is_empty() else 0) else 0)
	# `[Actor.]SexChange Male|Female [1]`: sets the ACBS Female flag of the
	# actor's NPC_, which marks it dirty.
	register("SexChange", func(a: Array, ctx: ScriptExecutionContext):
		var npc := ctx.calling_reference.base as NpcBase if ctx.calling_reference != null else null
		var female := _sex_arg(a, 0)
		if npc == null or female < 0:
			return 0
		npc.set_female(female == 1)
		return 1)
	# `GetInCell Cell`: the CELL itself, by editor ID.
	register("GetInCell", func(a: Array, ctx: ScriptExecutionContext):
		var esm_server := EsmReference.get_esm_server()
		if ctx.calling_reference == null or a.is_empty() or esm_server == null:
			return 0
		var cell: int = a[0] if a[0] is int else esm_server.find_form_id_by_editor_id(str(a[0]))
		return 1 if cell != 0 and ctx.calling_reference.current_cell_form_id == cell else 0)
	# `GetInWorldspace Worldspace`: true in that worldspace's exterior.
	register("GetInWorldspace", func(a: Array, ctx: ScriptExecutionContext):
		var esm_server := EsmReference.get_esm_server()
		if ctx.calling_reference == null or a.is_empty() or esm_server == null:
			return 0
		var worldspace: int = a[0] if a[0] is int else esm_server.find_form_id_by_editor_id(str(a[0]))
		return 1 if worldspace != 0 and ctx.calling_reference.current_space_form_id == worldspace else 0)
	register("GetInSameCell", func(a: Array, ctx: ScriptExecutionContext):
		var other: EsmReference = a[0] as EsmReference if not a.is_empty() and a[0] is EsmReference else null
		if ctx.calling_reference == null or other == null or ctx.calling_reference.current_cell_form_id == 0:
			return 0
		return 1 if ctx.calling_reference.current_cell_form_id == other.current_cell_form_id else 0)
	# `GetDistance Ref`, in Gamebryo units; DISTANCE_OTHER_SPACE across spaces.
	register("GetDistance", func(a: Array, ctx: ScriptExecutionContext):
		var other: EsmReference = a[0] as EsmReference if not a.is_empty() and a[0] is EsmReference else null
		if ctx.calling_reference == null or other == null:
			return DISTANCE_OTHER_SPACE
		if ctx.calling_reference.current_space_form_id != other.current_space_form_id or ctx.calling_reference.current_space_form_id == 0:
			return DISTANCE_OTHER_SPACE
		return ctx.calling_reference.position.distance_to(other.position) / GAMEBRYO_UNITS_TO_METERS)

	# Locks and open state of the calling reference (doors, containers, terminals).
	register("GetLocked", func(_a, ctx: ScriptExecutionContext):
		return 1 if ctx.calling_reference != null and "is_locked" in ctx.calling_reference and ctx.calling_reference.get("is_locked") else 0)
	# 1 open, 3 closed; 0 for a reference with no open state. Opening (2) and
	# closing (4) are not tracked: the change is immediate.
	register("GetOpenState", func(_a, ctx: ScriptExecutionContext):
		if ctx.calling_reference == null or not "is_open" in ctx.calling_reference:
			return 0
		return 1 if ctx.calling_reference.get("is_open") else 3)
	# `SetOpenState Flag`: 1 opens, 0 closes; a loaded door plays the change.
	register("SetOpenState", func(a: Array, ctx: ScriptExecutionContext):
		if ctx.calling_reference == null or not "is_open" in ctx.calling_reference:
			return 0
		ctx.calling_reference.set("is_open", _number(a, 0) != 0.0)
		var node := EsmNode.node_for(ctx.calling_reference)
		if node != null:
			node.on_activated(null)
		return 1)
	# The reference is not spawned again once its CELL next loads.
	register("MarkForDelete", func(_a, ctx: ScriptExecutionContext):
		if ctx.calling_reference == null:
			return 0
		ctx.calling_reference.marked_for_delete = true
		return 1)

	# Actor values of the calling actor, named by script name (`GetAV Health`).
	register(["GetActorValue", "GetAV"], func(a: Array, ctx: ScriptExecutionContext):
		return _read_actor_value(a, ctx, "get_current"))
	register(["GetBaseActorValue", "GetBaseAV"], func(a: Array, ctx: ScriptExecutionContext):
		return _read_actor_value(a, ctx, "get_base"))
	register(["GetPermanentActorValue", "GetPermAV"], func(a: Array, ctx: ScriptExecutionContext):
		return _read_actor_value(a, ctx, "get_permanent"))
	register(["SetActorValue", "SetAV"], func(a: Array, ctx: ScriptExecutionContext):
		return _change_actor_value(a, ctx, "set_base"))
	register(["ModActorValue", "ModAV"], func(a: Array, ctx: ScriptExecutionContext):
		return _change_actor_value(a, ctx, "modify"))
	register(["ForceActorValue", "ForceAV"], func(a: Array, ctx: ScriptExecutionContext):
		return _change_actor_value(a, ctx, "force"))
	register(["DamageActorValue", "DamageAV"], func(a: Array, ctx: ScriptExecutionContext):
		return _change_actor_value(a, ctx, "damage_value"))
	register(["RestoreActorValue", "RestoreAV"], func(a: Array, ctx: ScriptExecutionContext):
		return _change_actor_value(a, ctx, "restore_value"))
	register("GetHealthPercentage", func(_a, ctx: ScriptExecutionContext):
		var values := _actor_values(ctx)
		return values.health_percentage() if values != null else 0.0)
	register("GetLevel", func(_a, ctx: ScriptExecutionContext):
		var values := _actor_values(ctx)
		return values.get_level() if values != null else 0)
		

	register("Unlock", func(_a, ctx: ScriptExecutionContext):
		if ctx.calling_reference == null or script_server == null:
			return 0
		script_server.unlock(ctx.calling_reference)
		return 1)

	register("PlaceAtMe", func(a: Array, ctx: ScriptExecutionContext):
		if a.is_empty() or not place_at_me_handler.is_valid():
			push_warning("ScriptFunctionRegistry: PlaceAtMe unavailable -- no world placement handler")
			return 0
		return place_at_me_handler.call(a, ctx.calling_reference))

	var center_on_cell := func(a: Array, _ctx: ScriptExecutionContext):
		if a.is_empty() or not center_on_cell_handler.is_valid():
			push_warning("ScriptFunctionRegistry: CenterOnCell unavailable -- no cell-transition handler")
			return 0
		return center_on_cell_handler.call(a)
	register(["CenterOnCell", "COC"], center_on_cell)

	# Toggles noclip on the calling reference's node, or on the player's body
	# when there is no calling reference.
	var toggle_collision := func(_a: Array, ctx: ScriptExecutionContext):
		var target: Object = EsmNode.node_for(ctx.calling_reference) if ctx.calling_reference != null else player_node
		if target != null and "noclip" in target:
			target.noclip = !target.noclip
			return 1 if target.noclip else 0
		return 0
	register(["ToggleCollision", "TCL"], toggle_collision)

	register("ShowMessage", func(a: Array, ctx: ScriptExecutionContext):
		# Real argument shape: either an EditorID string (e.g. GSBrokenSMGMsg)
		# or a FormID -- resolved via get_message_by_editor_id() or get_message_by_form_id().
		if a.is_empty() or esm == null:
			return 0
		var identifier := str(a[0])
		var msg: Dictionary = {}
		if a[0] is int or a[0] is float:
			msg = esm.get_message_by_form_id(int(a[0]))
		elif identifier.is_valid_int():
			msg = esm.get_message_by_form_id(int(identifier))
		if msg.is_empty():
			msg = esm.get_message_by_editor_id(identifier)
		if msg.is_empty():
			push_warning("ScriptFunctionRegistry: ShowMessage -- no MESG found for '%s'" % identifier)
			return 0
		if show_message_handler.is_valid():
			return show_message_handler.call(msg, ctx)
		return 1)

	register("GetButtonPressed", func(_a: Array, ctx: ScriptExecutionContext):
		# Returns the 0-based button index pressed by the player, or -1 if no button
		# was pressed yet. Reading this value consumes it back to -1 per Gamebryo semantics.
		if get_button_pressed_handler.is_valid():
			return get_button_pressed_handler.call(ctx)
		return -1)

## Numeric argument `index`, or 0 when absent or not a number.
static func _number(args: Array, index: int) -> float:
	if index < args.size() and (args[index] is int or args[index] is float):
		return float(args[index])
	return 0.0

## Queues PositionCell/PositionWorld's move: x y z in Gamebryo units, zRot in
## degrees.
func _position(ref: EsmReference, space_form_id: int, args: Array) -> void:
	var position := Vector3(_number(args, 0), _number(args, 1), _number(args, 2)) * GAMEBRYO_UNITS_TO_METERS
	var rotation := Vector3(ref.rotation.x, ref.rotation.y, deg_to_rad(_number(args, 3)))
	script_server.move_reference(ref, space_form_id, position, rotation)

## A script variable's value from `instance`: `variable` is an SLSD index into
## script `script_form_id`, or a name. 0 when there is no such variable.
func _variable_value(instance: ScriptInstance, script_form_id: int, variable: Variant) -> Variant:
	if instance == null:
		return 0
	var name: String = script_server.script_variable_name(script_form_id, variable) if variable is int else str(variable)
	var value: Variant = instance.get_local(name) if not name.is_empty() else null
	return value if value != null else 0

## GetDistance's result for references in different spaces (or unplaced).
const DISTANCE_OTHER_SPACE := 1.0e10

## A reference's live inventory (actor, creature, container), or null.
static func _inventory_of(ref: EsmReference) -> Inventory:
	return ref.get("contents") as Inventory if ref != null and "contents" in ref else null

## The base record at argument `index`: an EsmBase as a condition passes it,
## or an editor ID as a script names it. Null when neither.
static func _base_arg(args: Array, index: int) -> EsmBase:
	if index >= args.size():
		return null
	if args[index] is EsmBase:
		return args[index]
	var esm_server := EsmReference.get_esm_server()
	return esm_server.find_base_by_editor_id(str(args[index])) if esm_server != null and esm_server.is_ready() else null

## The NPC_ or CREA record supplying `actor`'s part named by a template
## flag, or null when it is not an actor.
static func _actor_part(actor: EsmReference, template_flag: int) -> EsmBase:
	if actor == null or actor.base == null or actor.base.get("actor_stats") == null:
		return null
	return ActorStats.template_source(actor.base, template_flag)

## `actor`'s authored rank in `faction` (ActorFaction.rank), or -1 when it
## is not a member. A negative authored rank also reads as not a member.
static func _faction_rank(actor: EsmReference, faction: EsmBase) -> int:
	var source := _actor_part(actor, ActorStats.TEMPLATE_USE_FACTIONS)
	if source == null or faction == null:
		return -1
	for entry: ActorFaction in source.get("factions"):
		if entry.faction_form_id == faction.form_id:
			return entry.rank if entry.rank >= 0 else -1
	return -1

static func _dialogue_server() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null("DialogueServer") if tree != null else null

## The first inventory item of a base, or null.
static func _first_item(inventory: Inventory, base_form_id: int) -> InventoryItem:
	for item in inventory.get_items():
		if item.item_reference != null and item.item_reference.base_form_id == base_form_id:
			return item
	return null

## Removes up to `count` items of a base, across stacks. Returns how many.
static func _remove_items(inventory: Inventory, base_form_id: int, count: int) -> int:
	var removed := 0
	for item in inventory.get_items():
		if removed >= count:
			break
		if item.item_reference == null or item.item_reference.base_form_id != base_form_id:
			continue
		var take := mini(item.count, count - removed)
		if inventory.remove_inventory_item(item, take):
			removed += take
	return removed

## The calling reference's actor values, or null when it is not an actor.
static func _actor_values(ctx: ScriptExecutionContext) -> ActorValues:
	return ctx.calling_reference.get_actor_values() if ctx.calling_reference != null else null

## `method` (get_current, get_base, get_permanent) of the actor value named by
## the first argument, on the calling actor; 0 for a non-actor.
static func _read_actor_value(args: Array, ctx: ScriptExecutionContext, method: String) -> float:
	var values := _actor_values(ctx)
	var code := _actor_value_code(args, 0)
	return values.call(method, code) if values != null and code >= 0 else 0.0

## Applies `method` (set_base, modify, force, damage_value, restore_value)
## with the second argument to the actor value named by the first. 1 when
## applied, 0 for a non-actor or an unknown actor value.
static func _change_actor_value(args: Array, ctx: ScriptExecutionContext, method: String) -> int:
	var values := _actor_values(ctx)
	var code := _actor_value_code(args, 0)
	if values == null or code < 0:
		return 0
	values.call(method, code, _number(args, 1))
	return 1

## The actor value code an argument gives: an int code as a condition passes
## it, or a script name. -1 when neither.
## DisablePlayerControls' / EnablePlayerControls' 0/1 arguments as
## ScriptServer CONTROL_* flags (the Nth argument is bit N); `default` with no
## arguments.
static func _control_flags(args: Array, default: int) -> int:
	if args.is_empty():
		return default
	var flags := 0
	for i in mini(args.size(), 7):
		if _number(args, i) != 0.0:
			flags |= 1 << i
	return flags

## The sex at argument `index`: 1 female, 0 male, -1 when it is neither. A
## condition passes ptSex as 0 or 1; a script names it, `Male` or `Female`.
static func _sex_arg(args: Array, index: int) -> int:
	if index >= args.size():
		return -1
	var value: Variant = args[index]
	if value is int or value is float:
		return int(value) if int(value) == 0 or int(value) == 1 else -1
	match str(value).to_lower():
		"male": return 0
		"female": return 1
	push_warning("ScriptFunctionRegistry: unknown sex '%s'" % str(value))
	return -1

static func _actor_value_code(args: Array, index: int) -> int:
	if index >= args.size():
		return -1
	if args[index] is int:
		return args[index] if args[index] >= 0 and args[index] < ActorValue.COUNT else -1
	var code := ActorValue.from_name(str(args[index]))
	if code < 0:
		push_warning("ScriptFunctionRegistry: unknown actor value '%s'" % str(args[index]))
	return code

## The QUST at argument `index`: a QuestBase as a condition passes it, or an
## editor ID as a script names it. Null when neither.
static func _quest(args: Array, index: int) -> EsmBase:
	if index < args.size() and args[index] is QuestBase:
		return args[index]
	var esm_server := EsmReference.get_esm_server()
	if index >= args.size() or esm_server == null or not esm_server.is_ready():
		return null
	return esm_server.find_quest_by_editor_id(str(args[index]))

## Calls QuestServer's `method` on the quest named by the first argument. 1
## when the quest exists, else 0.
static func _apply_to_quest(args: Array, method: String) -> int:
	var quests := _quest_server()
	var quest := _quest(args, 0)
	if quests == null or quest == null:
		return 0
	quests.call(method, quest)
	return 1

## 1 when QuestServer's `method` (is_objective_displayed,
## is_objective_completed) is true for the quest and objective index named by
## the first two arguments, else 0.
static func _read_objective(args: Array, method: String) -> int:
	var quests := _quest_server()
	var quest := _quest(args, 0)
	if quests == null or quest == null or not _is_number(args, 1):
		return 0
	return 1 if quests.call(method, quest, int(_number(args, 1))) else 0

## Applies QuestServer's `method` (set_objective_displayed,
## set_objective_completed) to the quest and objective index named by the
## first two arguments: the third argument sets when nonzero, clears when 0.
## Without a third argument nothing changes. 1 when applied, else 0.
static func _change_objective(args: Array, method: String, name: String) -> int:
	var quests := _quest_server()
	var quest := _quest(args, 0)
	if quests == null or quest == null or not _is_number(args, 1):
		return 0
	if not _is_number(args, 2):
		push_warning("ScriptFunctionRegistry: %s %s %s without a flag changes nothing"
				% [name, quest.editor_id, str(args[1])])
		return 0
	return 1 if quests.call(method, quest, int(_number(args, 1)), _number(args, 2) != 0.0) else 0

## Whether argument `index` exists and is a number.
static func _is_number(args: Array, index: int) -> bool:
	return index < args.size() and (args[index] is int or args[index] is float)

## The QuestServer autoload, or null where it does not exist.
static func _quest_server() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null("QuestServer") if tree != null else null
