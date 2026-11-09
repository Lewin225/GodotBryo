class_name ConsoleCompleter
extends RefCounted

## Autocomplete and EditorID resolution for the console (ConsoleSession).
##
## Names come from FalloutNV.esm's own record index (EsmServer.get_record_index:
## every record's type, FormID, EDID and FULL), so any record with an EditorID
## completes and resolves, with its type, FormID and name shown beside it.
## What a function's arguments are comes from SIGNATURES, which narrows
## completion to the records an argument takes: `AddItem` completes items,
## `SetStage` quests, `coc` interior cells.

## Bits of an index in _id_keys' low end; a FormID is above them.
const ID_BITS := 20
const ID_MASK := (1 << ID_BITS) - 1

## Most suggestions complete() returns by default.
const MAX_ITEMS := 12

## Record types each EditorID-valued argument kind accepts.
const KIND_RECORD_TYPES := {
	"ref": ["REFR", "ACHR", "ACRE"],
	"actor": ["ACHR", "ACRE"],
	"item": ["WEAP", "ARMO", "AMMO", "ALCH", "MISC", "KEYM", "BOOK", "NOTE", "CCRD", "CMNY", "IMOD", "CHIP", "LVLI"],
	"object": ["WEAP", "ARMO", "AMMO", "ALCH", "MISC", "KEYM", "BOOK", "NOTE", "CCRD", "CMNY", "IMOD", "CHIP", "LVLI",
			"NPC_", "CREA", "LVLN", "LVLC", "STAT", "SCOL", "MSTT", "ACTI", "TACT", "CONT", "DOOR", "FURN", "LIGH", "TERM", "EXPL"],
	"furniture": ["FURN"],
	"cell": ["CELL"],
	"interior_cell": ["CELL"],
	"worldspace": ["WRLD"],
	"quest": ["QUST"],
	"global": ["GLOB"],
	"message": ["MESG"],
	"package": ["PACK"],
	"faction": ["FACT"],
	"idle": ["IDLE"],
	"race": ["RACE"],
	"class": ["CLAS"],
	"voice": ["VTYP", "FLST"],
	"topic": ["DIAL"],
}

## Arguments of the registered script functions (ScriptFunctionRegistry), as
## the registry's own usage comments give them: `Name:kind`, in brackets when
## optional. Several names separated by `|` share a signature (aliases, or
## functions taking the same arguments). Kinds are KIND_RECORD_TYPES' keys or
## number, int, flag (0 or 1), string, sex, actorvalue, quest_variable and
## script_variable. A registered function missing here completes any name.
const SIGNATURES := {
	"Abs|Sqrt": "X:number",
	"GetSecondsPassed|GameDaysPassed|GetCurrentTime|GetRandomPercent": "",
	"SwapTexture": "Ref:ref Block:string Path:string",
	"Enable|Disable": "[Fade:flag]",
	"GetDisabled|GetActionRef|GetSelf|IsWin32|IsXBox|IsPS3": "",
	"Activate": "[ActionRef:ref] [RunOnActivateBlock:flag]",
	"MoveTo": "Target:ref [X:number] [Y:number] [Z:number]",
	"PositionCell": "X:number Y:number Z:number ZRot:number Cell:cell",
	"PositionWorld": "X:number Y:number Z:number ZRot:number Worldspace:worldspace",
	"Lock": "[Level:int]",
	"Unlock": "",
	"IsActionRef|GetIsReference|GetInSameCell|Look|IsCurrentFurnitureRef|GetDistance": "Ref:ref",
	"GetStage|StartQuest|StopQuest|GetQuestRunning|GetQuestCompleted|CompleteQuest|FailQuest|ResetQuest|CompleteAllObjectives|SetActiveQuest": "Quest:quest",
	"GetStageDone|SetStage": "Quest:quest Stage:int",
	"SetQuestDelay": "Quest:quest Seconds:number",
	"GetGlobalValue": "Global:global",
	"GetQuestVariable": "Quest:quest Variable:quest_variable",
	"GetScriptVariable": "Ref:ref Variable:script_variable",
	"SetQuestObject": "Item:item Flag:flag",
	"GetObjectiveDisplayed|GetObjectiveCompleted": "Quest:quest Index:int",
	"SetObjectiveDisplayed|SetObjectiveCompleted": "Quest:quest Index:int Flag:flag",
	"GetItemCount|GetEquipped": "Item:item",
	"AddItem|RemoveItem": "Item:item Count:int [HideMessage:flag]",
	"RemoveAllItems": "[TargetContainer:ref] [RetainOwnership:flag]",
	"EquipItem": "Item:item [NoUnequip:flag] [HideMessage:flag]",
	"UnequipItem": "Item:item [NoEquip:flag] [HideMessage:flag]",
	"GetIsID": "Object:object",
	"GetIsSex": "Sex:sex",
	"GetIsVoiceType": "VoiceType:voice",
	"GetInFaction|GetFactionRank": "Faction:faction",
	"GetTalkedToPC": "",
	"SayTo": "Target:ref Topic:topic [ForceSubtitle:flag] [NoTargetLook:flag]",
	"Say": "Topic:topic [ForceSubtitle:flag]",
	"StartConversation": "Target:ref [Topic:topic]",
	"AddTopic": "Topic:topic",
	"DisablePlayerControls|EnablePlayerControls": "[Movement:flag] [Pipboy:flag] [Fighting:flag] [POV:flag] [Looking:flag] [RolloverText:flag] [Sneaking:flag]",
	"GetPlayerControlsDisabled|GetPlayerName|ShowNameMenu|ShowTraitMenu|ShowRaceMenu": "",
	"ShowLoveTesterMenuParams": "Points:int",
	"SetTagSkills": "Total:int [ShowInitialTaggedSkills:flag]",
	"MenuMode": "[MenuType:int]",
	"SexChange": "[Sex:sex]",
	"GetInCell": "Cell:cell",
	"GetInWorldspace": "Worldspace:worldspace",
	"PlayIdle|IsLastIdlePlayed": "Idle:idle",
	"PickIdle|StopLook|GetSitting|IsMoving|IsRunning|IsSneaking": "",
	"IsCurrentFurnitureObj": "Furniture:furniture",
	"GetHitLocation|GetKnockedState|IsInCombat|IsWeaponOut|GetSleeping|IsGreetingPlayer|GetPlantedExplosive|GetUsedItemActivate|GetVATSMode|GetVATSValue": "",
	"GetCurrentAIProcedure|GetCurrentAIPackage|IsTalking|GetDialogueEmotion|IsChild|GetFurnitureMarkerID": "",
	"GetIsRace": "Race:race",
	"GetIsClass": "Class:class",
	"GetLocked|GetOpenState": "",
	"SetOpenState": "Open:flag",
	"AddScriptPackage|DebugAddScriptPackageAll": "Package:package",
	"RemoveScriptPackage|EvaluatePackage|evp|DebugRemoveScriptPackageAll|DebugActorCost|MarkForDelete": "",
	"DebugNpcReport": "[Radius:number]",
	"DebugNpcLog": "Seconds:number",
	"DebugCopyBench": "[Mode:int]",
	"DebugActorThreads|DebugNpcControllers": "On:flag",
	"DebugSetLowLevelSpeed": "Multiplier:number",
	"GetActorValue|GetAV|GetBaseActorValue|GetBaseAV|GetPermanentActorValue|GetPermAV": "ActorValue:actorvalue",
	"SetActorValue|SetAV|ModActorValue|ModAV|ForceActorValue|ForceAV|DamageActorValue|DamageAV|RestoreActorValue|RestoreAV": "ActorValue:actorvalue Value:number",
	"GetHealthPercentage|GetLevel|GetButtonPressed|ToggleCollision|TCL|TGM|TDM|Kill|Resurrect": "",
	"PlaceAtMe": "Object:object [Count:int]",
	"FireWeapon": "Weapon:item",
	"CenterOnCell|COC": "Cell:interior_cell",
	"ShowMessage": "Message:message",
}

## Console commands that are not script functions (ConsoleSession runs them):
## name -> [argument signature, description].
const META_COMMANDS := {
	"help": ["[Function:function]", "lists commands, or a function's arguments and aliases"],
	"find": ["Text:string [RecordType:string]", "searches EditorIDs and names, optionally of one record type"],
	"info": ["[Name:any]", "describes a reference or record (the target when no name is given)"],
	"prid": ["[Ref:ref]", "sets the target reference that unprefixed commands act on; `prid none` clears it"],
	"bat": ["File:string", "runs each line of a text file (user:// or an absolute path) as a command"],
	"history": ["[Count:int]", "lists recent commands"],
	"status": ["", "shows the loaded plugins, record counts, script functions and where the player is"],
	"clear|cls": ["", "clears the output"],
}

## Words that start a statement without being a function.
const STATEMENT_KEYWORDS := ["set"]

var _function_names: Array[String] = []
var _signatures := {} # lowercased function name -> Array of params
var _canonical := {} # lowercased function name -> registered spelling

var _index_ready := false
var _names := PackedStringArray() # EditorIDs, sorted by lowercased name
var _lower := PackedStringArray() # the same, lowercased
var _types := PackedStringArray()
var _form_ids := PackedInt64Array()
var _full_names := PackedStringArray()
var _by_lower := {} # lowercased EditorID -> index
var _by_form_id := {} # FormID -> index
var _by_type := {} # record type -> PackedInt32Array of indices, in name order
var _interior_cells := PackedInt32Array()
var _interior_set := {} # index -> true, for _interior_cells
var _id_keys := PackedInt64Array() # (FormID << ID_BITS) | index, sorted: records in FormID order
var _pools := {} # kind -> PackedInt32Array, built on first use
var _type_counts := {} # record type -> records of it, with or without an EditorID
var _record_total := 0
## Most suggestions the complete() call in progress collects.
var _limit := MAX_ITEMS

## `registry` supplies the function names; null uses a default registry.
func _init(registry: ScriptFunctionRegistry = null) -> void:
	var reg := registry if registry != null else ScriptFunctionRegistry.new()
	_function_names = reg.get_registered_function_names()
	for name in _function_names:
		_canonical[name.to_lower()] = name
	for names: String in SIGNATURES:
		var params := parse_params(String(SIGNATURES[names]))
		for name in names.split("|"):
			_signatures[name.to_lower()] = params

## `"Item:item [Count:int]"` as [{name, kind, optional}, ...].
static func parse_params(text: String) -> Array:
	var params: Array = []
	for token in text.split(" ", false):
		var optional := token.begins_with("[")
		var bare := token.trim_prefix("[").trim_suffix("]")
		var colon := bare.find(":")
		params.append({
			"name": bare.left(colon) if colon >= 0 else bare,
			"kind": bare.substr(colon + 1) if colon >= 0 else "any",
			"optional": optional,
		})
	return params

## Builds the EditorID index from EsmServer's record index, once it is ready.
## Returns whether the index is available.
func ensure_index() -> bool:
	if _index_ready:
		return true
	var esm_server := EsmReference.get_esm_server()
	if esm_server == null or not esm_server.is_ready():
		return false
	build_index(esm_server.get_record_index())
	return true

## Builds the index from record index rows ({record_type, form_id, editor_id,
## full_name}); rows without an EditorID are left out.
func build_index(rows: Array) -> void:
	var keys := PackedStringArray()
	_type_counts.clear()
	_record_total = rows.size()
	for i in rows.size():
		var record_type := String(rows[i].get("record_type", ""))
		_type_counts[record_type] = int(_type_counts.get(record_type, 0)) + 1
		var editor_id := String(rows[i].get("editor_id", ""))
		if not editor_id.is_empty():
			keys.append(editor_id.to_lower() + "\t" + str(i))
	keys.sort()
	_names.resize(keys.size())
	_lower.resize(keys.size())
	_types.resize(keys.size())
	_form_ids.resize(keys.size())
	_full_names.resize(keys.size())
	_by_lower.clear()
	_by_form_id.clear()
	var by_type := {}
	for i in keys.size():
		var tab := keys[i].rfind("\t")
		var row: Dictionary = rows[int(keys[i].substr(tab + 1))]
		_lower[i] = keys[i].left(tab)
		_names[i] = String(row["editor_id"])
		_types[i] = String(row.get("record_type", ""))
		_form_ids[i] = int(row.get("form_id", 0))
		_full_names[i] = String(row.get("full_name", ""))
		if not _by_lower.has(_lower[i]):
			_by_lower[_lower[i]] = i
		_by_form_id[_form_ids[i]] = i
		if not by_type.has(_types[i]):
			by_type[_types[i]] = PackedInt32Array()
		by_type[_types[i]].append(i)
	_by_type = by_type
	_pools.clear()
	_id_keys.resize(keys.size())
	for i in keys.size():
		_id_keys[i] = (_form_ids[i] << ID_BITS) | i
	_id_keys.sort()
	_interior_set.clear()
	_interior_cells = PackedInt32Array()
	var esm_server := EsmReference.get_esm_server()
	for i: int in by_type.get("CELL", PackedInt32Array()):
		if esm_server == null or not esm_server.has_method("get_space_form_id_for_cell") \
				or esm_server.get_space_form_id_for_cell(_form_ids[i]) == _form_ids[i]:
			_interior_cells.append(i)
			_interior_set[i] = true
	_index_ready = true

## How many records of `record_type` the ESM has, with or without an EditorID.
func record_count(record_type: String) -> int:
	return int(_type_counts.get(record_type, 0))

func total_record_count() -> int:
	return _record_total

func is_index_ready() -> bool:
	return _index_ready

func index_size() -> int:
	return _names.size()

# --- Resolution ---------------------------------------------------------------

## The record with this EditorID (case-insensitive) as {editor_id,
## record_type, form_id, full_name}, or {} when none has it.
func resolve(editor_id: String) -> Dictionary:
	var i := int(_by_lower.get(editor_id.to_lower(), -1))
	return _record(i) if i >= 0 else {}

## The record with this FormID, as resolve() gives it, or {} when it has no
## EditorID or no record has the FormID.
func record_for_form_id(form_id: int) -> Dictionary:
	var i := int(_by_form_id.get(form_id, -1))
	return _record(i) if i >= 0 else {}

func _record(i: int) -> Dictionary:
	return {"editor_id": _names[i], "record_type": _types[i], "form_id": _form_ids[i], "full_name": _full_names[i]}

## A token's FormID when it is written as one, else -1: `0x15169` (1 to 8 hex
## digits after 0x) or the 8 digits the GECK shows, `00015169`. Fewer bare
## digits are numbers (a count, a stage), not FormIDs. A name that is also
## an EditorID is the caller's to resolve first.
static func parse_form_id(token: String) -> int:
	var lower := token.to_lower()
	var prefixed := lower.begins_with("0x")
	var digits := lower.substr(2) if prefixed else lower
	if digits.is_empty() or digits.length() > 8 or (not prefixed and digits.length() != 8):
		return -1
	if digits.begins_with("-") or digits.begins_with("+") or not digits.is_valid_hex_number():
		return -1
	return digits.hex_to_int()

## Whether `record_type` is one an argument of `kind` accepts. Kinds that take
## no record (numbers, flags) accept nothing; `any` accepts everything.
static func kind_accepts(kind: String, record_type: String) -> bool:
	if kind == "any":
		return true
	return KIND_RECORD_TYPES.has(kind) and (KIND_RECORD_TYPES[kind] as Array).has(record_type)

## Whether arguments of `kind` name records.
static func is_record_kind(kind: String) -> bool:
	return KIND_RECORD_TYPES.has(kind)

## The records `kind` takes whose EditorID or name is closest to `text`, for
## "did you mean" hints.
func closest(text: String, kind: String, count := 3) -> PackedStringArray:
	var pool := _pool(kind)
	var lower := text.to_lower()
	var scored: Array = []
	for i: int in pool:
		var score := lower.similarity(_lower[i])
		if score > 0.5:
			scored.append([score, i])
	scored.sort_custom(func(a, b): return a[0] > b[0])
	var out := PackedStringArray()
	for entry in scored.slice(0, count):
		out.append(_names[entry[1]])
	return out

# --- Functions ----------------------------------------------------------------

func function_names() -> Array[String]:
	return _function_names

func is_function(name: String) -> bool:
	return _canonical.has(name.to_lower())

## A function's registered spelling, or "" when it is not registered.
func canonical_name(name: String) -> String:
	return String(_canonical.get(name.to_lower(), ""))

## A function's parameters, or null when SIGNATURES does not record them.
func signature(name: String) -> Variant:
	return _signatures.get(name.to_lower())

## The other registered names sharing `name`'s SIGNATURES entry.
func aliases(name: String) -> PackedStringArray:
	var out := PackedStringArray()
	for names: String in SIGNATURES:
		var group := names.split("|")
		var lower_group := Array(group).map(func(n): return n.to_lower())
		if lower_group.has(name.to_lower()) and names.contains("|"):
			for n in group:
				if n.to_lower() != name.to_lower():
					out.append(n)
	return out

## `AddItem Item Count [HideMessage]`, plain text.
func usage(name: String) -> String:
	var params: Variant = signature(name)
	var meta: Variant = meta_command(name)
	if meta != null:
		params = parse_params(String(meta[0]))
	if params == null:
		return "%s ..." % name
	var parts := PackedStringArray([name])
	for p: Dictionary in params:
		parts.append(("[%s]" if p["optional"] else "%s") % p["name"])
	return " ".join(parts)

## A meta command's [signature, description], or null.
static func meta_command(name: String) -> Variant:
	var lower := name.to_lower()
	for names: String in META_COMMANDS:
		if Array(names.split("|")).has(lower):
			return META_COMMANDS[names]
	return null

static func meta_command_names() -> PackedStringArray:
	var out := PackedStringArray()
	for names: String in META_COMMANDS:
		out.append_array(names.split("|"))
	return out

# --- Completion ---------------------------------------------------------------

## Suggestions for the word `caret` is in or touches, matched whole (text
## after the caret counts):
## {start: int, end: int (the word's span in line), items: [{text, detail,
## append_space}], signature: String (BBCode; the current function's
## arguments, the current one underlined), more: bool (whether more than
## `limit` match)}. At most `limit` items. `context` may hold `target` (the console's EsmReference) and
## `script_server` (for quest and reference script variables).
func complete(line: String, caret: int, context: Dictionary = {}, limit := MAX_ITEMS) -> Dictionary:
	_limit = limit
	var result := {"start": caret, "end": caret, "items": [], "signature": "", "more": false}
	var left := line.substr(0, caret)
	var statement_start := _statement_start(left)
	var statement := left.substr(statement_start)
	if _in_quotes(statement):
		return result
	var tokens := _tokens(statement)
	var word := ""
	var word_start := caret
	if not tokens.is_empty() and int(tokens.back()["end"]) == statement.length():
		var last: Dictionary = tokens.pop_back()
		word = String(last["text"])
		word_start = statement_start + int(last["start"])
	result["start"] = word_start
	var word_end := caret
	while word_end < line.length() and not " \t,|".contains(line[word_end]):
		word_end += 1
	result["end"] = word_end
	# The whole word the caret is in, not only what is before it: editing
	# inside `0x0015` updates the suggestions for all of it.
	word = line.substr(word_start, word_end - word_start)
	var items: Array = []
	if tokens.is_empty():
		items = _head_items(word)
	else:
		var head := String(tokens[0]["text"])
		var arg_index := tokens.size() - 1
		var kind := _argument_kind(head, arg_index, word, result)
		items = _argument_items(kind, word, tokens, context)
	result["more"] = items.size() > limit
	result["items"] = items.slice(0, limit)
	return result

## Where the statement containing the end of `left` starts: after the last `|`
## that splits statements (ConsoleSession.split_statements).
static func _statement_start(left: String) -> int:
	var in_quotes := false
	var start := 0
	var i := 0
	while i < left.length():
		var c := left[i]
		if c == "\"":
			in_quotes = not in_quotes
		elif c == "|" and not in_quotes:
			if i + 1 < left.length() and left[i + 1] == "|":
				i += 2
				continue
			start = i + 1
		i += 1
	return start

static func _in_quotes(text: String) -> bool:
	return text.count("\"") % 2 == 1

## Whitespace- and comma-separated words of `text` with their spans; a quoted
## string is one word.
static func _tokens(text: String) -> Array:
	var tokens: Array = []
	var i := 0
	while i < text.length():
		if " \t,".contains(text[i]):
			i += 1
			continue
		var start := i
		if text[i] == "\"":
			i += 1
			while i < text.length() and text[i] != "\"":
				i += 1
			i = mini(i + 1, text.length())
		else:
			while i < text.length() and not " \t,".contains(text[i]):
				i += 1
		tokens.append({"text": text.substr(start, i - start), "start": start, "end": i})
	return tokens

## Suggestions for a statement's first word: meta commands, `set`, functions
## (after a `Ref.` prefix, functions only), then references to prefix with.
func _head_items(word: String) -> Array:
	var dot := word.rfind(".")
	if dot >= 0:
		var prefix := word.left(dot + 1)
		var items: Array = []
		for item in _function_items(word.substr(dot + 1)):
			item["text"] = prefix + String(item["text"])
			items.append(item)
		return items
	var items: Array = []
	var lower := word.to_lower()
	var exact: Array = []
	for name in meta_command_names():
		if name.begins_with(lower):
			var meta: Array = meta_command(name)
			(exact if name == lower else items).append({"text": name, "detail": "console: " + String(meta[1]), "append_space": true})
	for keyword: String in STATEMENT_KEYWORDS:
		if keyword.begins_with(lower):
			items.append({"text": keyword, "detail": "set Variable to Value", "append_space": true})
	items = exact + items + _function_items(word)
	if items.size() <= _limit and not word.is_empty():
		for item in _record_items("ref", word, _limit):
			item["text"] = String(item["text"]) + "."
			item["append_space"] = false
			items.append(item)
	return items

func _function_items(word: String) -> Array:
	var lower := word.to_lower()
	var prefixed: Array = []
	var contained: Array = []
	for name in _function_names:
		var name_lower := name.to_lower()
		var item := {"text": name, "detail": usage(name), "append_space": true}
		if lower.is_empty() or name_lower.begins_with(lower):
			if name_lower == lower:
				prefixed.push_front(item)
			else:
				prefixed.append(item)
		elif lower.length() >= 2 and name_lower.contains(lower):
			contained.append(item)
	return prefixed + contained

## The kind of argument `arg_index` (0-based) of the statement starting with
## `head`, and the signature line in `result`.
func _argument_kind(head: String, arg_index: int, word: String, result: Dictionary) -> String:
	var lower := head.to_lower()
	var meta: Variant = meta_command(lower)
	if meta != null:
		var meta_params := parse_params(String(meta[0]))
		result["signature"] = _signature_line(lower, meta_params, arg_index, word)
		if lower == "find" and arg_index == 1:
			return "record_type"
		return String(meta_params[arg_index]["kind"]) if arg_index < meta_params.size() else "none"
	if lower == "set":
		result["signature"] = "[b]set[/b] %s %s %s" % [
			"[u]Variable[/u]" if arg_index == 0 else "Variable", "[u]to[/u]" if arg_index == 1 else "to",
			"[u]Value[/u]" if arg_index >= 2 else "Value"]
		match arg_index:
			0: return "variable"
			1: return "keyword_to"
		return "any"
	var function_name := head.substr(head.rfind(".") + 1)
	var params: Variant = signature(function_name)
	if params == null:
		if is_function(function_name):
			result["signature"] = "[b]%s[/b] [color=#7f848e](arguments not recorded)[/color]" % canonical_name(function_name)
		return "any"
	result["signature"] = _signature_line(canonical_name(function_name), params, arg_index, word)
	if arg_index >= (params as Array).size():
		return "none"
	return String(params[arg_index]["kind"])

## A function's arguments with argument `active` underlined. Past the last
## argument it warns only once something is typed there: a trailing space is
## dropped when the line runs.
static func _signature_line(name: String, params: Array, active: int, word: String) -> String:
	var parts := PackedStringArray(["[b]%s[/b]" % name])
	if params.is_empty():
		parts.append("[color=#7f848e](no arguments)[/color]")
	for i in params.size():
		var p: Dictionary = params[i]
		var text := "%s[color=#7f848e]:%s[/color]" % [p["name"], p["kind"]]
		if p["optional"]:
			text = "[" + text + "]"
		parts.append(("[u][color=#e5c07b]%s[/color][/u]" if i == active else "%s") % text)
	if active >= params.size() and not word.is_empty():
		parts.append("[color=#e06c75](too many arguments)[/color]")
	return " ".join(parts)

func _argument_items(kind: String, word: String, tokens: Array, context: Dictionary) -> Array:
	match kind:
		"none", "number", "int", "string":
			return []
		"keyword_to":
			return [{"text": "to", "detail": "", "append_space": true}] if "to".begins_with(word.to_lower()) else []
		"flag":
			return _list_items(["0", "1"], word, "flag")
		"sex":
			return _list_items(["Male", "Female"], word, "sex")
		"actorvalue":
			return _list_items(ActorValue.NAMES, word, "actor value")
		"function":
			return _function_items(word)
		"record_type":
			return _list_items(_by_type.keys(), word, "record type")
		"quest_variable":
			var quest_name := String(tokens[1]["text"]) if tokens.size() > 1 else ""
			return _list_items(_quest_variables(quest_name, context), word, "quest variable")
		"script_variable":
			var ref_name := String(tokens[1]["text"]) if tokens.size() > 1 else ""
			return _list_items(_reference_variables(_reference_named(ref_name, context), context), word, "script variable")
		"variable":
			return _variable_items(word, context)
		"ref", "actor":
			var items := _list_items(["player"], word, "the player's reference")
			return items + _record_items(kind, word)
		"any":
			return _function_items(word).slice(0, 4) + _record_items("any", word)
	return _record_items(kind, word)

## `set` targets: the target's script variables, `Quest.` and `Ref.`
## prefixes, `Quest.variable` / `Ref.variable` after one, and globals.
func _variable_items(word: String, context: Dictionary) -> Array:
	var dot := word.find(".")
	if dot >= 0:
		var owner := word.left(dot)
		var names := _quest_variables(owner, context)
		if names.is_empty():
			names = _reference_variables(_reference_named(owner, context), context)
		var items: Array = []
		for item in _list_items(names, word.substr(dot + 1), "variable"):
			item["text"] = owner + "." + String(item["text"])
			items.append(item)
		return items
	var target: EsmReference = context.get("target")
	var items := _list_items(_reference_variables(target, context), word, "target's variable")
	items.append_array(_record_items("global", word, _limit))
	for item in _record_items("quest", word, _limit):
		item["text"] = String(item["text"]) + "."
		item["append_space"] = false
		items.append(item)
	return items

func _quest_variables(quest_name: String, context: Dictionary) -> Array:
	var esm_server := EsmReference.get_esm_server()
	var server: Node = context.get("script_server")
	if quest_name.is_empty() or esm_server == null or not esm_server.is_ready() or server == null:
		return []
	var quest: EsmBase = esm_server.find_quest_by_editor_id(quest_name)
	if quest == null or quest.script_form_id == 0:
		return []
	var instance: ScriptInstance = server.get_quest_instance(quest)
	return instance.locals.keys() if instance != null else []

## Variables of a reference's script that has run (its ScriptInstance); a
## script that has not run has none yet.
static func _reference_variables(reference: EsmReference, _context: Dictionary) -> Array:
	if reference == null or reference.script_instance == null:
		return []
	return reference.script_instance.locals.keys()

static func _reference_named(name: String, context: Dictionary) -> EsmReference:
	if name.to_lower() == "player":
		var server: Node = context.get("script_server")
		return server.player_reference if server != null else null
	var esm_server := EsmReference.get_esm_server()
	if name.is_empty() or esm_server == null or not esm_server.is_ready():
		return null
	return esm_server.find_reference_by_editor_id(name)

static func _list_items(values: Array, word: String, detail: String) -> Array:
	var lower := word.to_lower()
	var prefixed: Array = []
	var contained: Array = []
	for value in values:
		var text := str(value)
		var text_lower := text.to_lower()
		if lower.is_empty() or text_lower.begins_with(lower):
			prefixed.append({"text": text, "detail": detail, "append_space": true})
		elif text_lower.contains(lower):
			contained.append({"text": text, "detail": detail, "append_space": true})
	return prefixed + contained

## Records `kind` takes whose EditorID starts with, then contains, `word`.
## Collects at most `limit` + 1, so callers can tell when there are more.
func _record_items(kind: String, word: String, limit := -1) -> Array:
	if limit < 0:
		limit = _limit
	if not ensure_index():
		return []
	var lower := word.to_lower()
	var typed_digits := lower.substr(2)
	if lower.begins_with("0x") and typed_digits.length() <= 8 and (typed_digits.is_empty() \
			or (typed_digits.is_valid_hex_number() and not typed_digits.begins_with("-") and not typed_digits.begins_with("+"))):
		return _form_id_items(kind, typed_digits, limit)
	var picked := PackedInt32Array()
	if kind == "any":
		var i := _lower.bsearch(lower)
		while i < _lower.size() and picked.size() <= limit and _lower[i].begins_with(lower):
			picked.append(i)
			i += 1
		if picked.size() <= limit and lower.length() >= 2:
			for j in _lower.size():
				if _lower[j].contains(lower) and not _lower[j].begins_with(lower):
					picked.append(j)
					if picked.size() > limit:
						break
	else:
		var pool := _pool(kind)
		for i: int in pool:
			if _lower[i].begins_with(lower):
				picked.append(i)
				if picked.size() > limit:
					break
		if picked.size() <= limit and not lower.is_empty():
			for i: int in pool:
				if _lower[i].contains(lower) and not _lower[i].begins_with(lower):
					picked.append(i)
					if picked.size() > limit:
						break
	var items: Array = []
	for i in picked:
		items.append({"text": _names[i], "detail": describe_index(i), "append_space": true})
	return items

## Records `kind` takes whose FormID starts with `digits` (hex after the 0x,
## as the FormID's 8 digits are written, leading zeros included), in FormID
## order; the suggestion inserts the EditorID. At most `limit` + 1.
func _form_id_items(kind: String, digits: String, limit: int) -> Array:
	var shift := 4 * (8 - digits.length())
	var low := (digits.hex_to_int() if not digits.is_empty() else 0) << shift
	var high := low + (1 << shift) - 1
	var position := _id_keys.bsearch(low << ID_BITS)
	var items: Array = []
	while position < _id_keys.size() and items.size() <= limit:
		var key := _id_keys[position]
		position += 1
		if (key >> ID_BITS) > high:
			break
		var i := int(key & ID_MASK)
		if _accepts(kind, i):
			items.append({"text": _names[i], "detail": describe_index(i), "append_space": true})
	return items

func _accepts(kind: String, i: int) -> bool:
	if kind == "any":
		return true
	if kind == "interior_cell":
		return _interior_set.has(i)
	return (KIND_RECORD_TYPES.get(kind, []) as Array).has(_types[i])

## Indices of the records `kind` takes, in name order.
func _pool(kind: String) -> PackedInt32Array:
	if kind == "interior_cell":
		return _interior_cells
	if _pools.has(kind):
		return _pools[kind]
	var pool := PackedInt32Array()
	if kind == "any":
		pool.resize(_names.size())
		for i in _names.size():
			pool[i] = i
	else:
		var record_types: Array = KIND_RECORD_TYPES.get(kind, [])
		for record_type: String in record_types:
			pool.append_array(_by_type.get(record_type, PackedInt32Array()))
		if record_types.size() > 1:
			# Indices follow name order, so sorting them sorts by name.
			pool.sort()
	_pools[kind] = pool
	return pool

## `ALCH 00015169 "Stimpak"`: a record's type, FormID and name.
func describe_index(i: int) -> String:
	var text := "%s %08X" % [_types[i], _form_ids[i]]
	if not _full_names[i].is_empty():
		text += " \"%s\"" % _full_names[i]
	return text

## find: records whose EditorID or name contains `text`, of `record_type`
## when given, as records (resolve()'s shape). At most `limit`.
func find(text: String, record_type := "", limit := 50) -> Array:
	if not ensure_index():
		return []
	var lower := text.to_lower()
	var type_upper := record_type.to_upper()
	var pool: PackedInt32Array = _by_type.get(type_upper, PackedInt32Array()) if not type_upper.is_empty() else _pool("any")
	var out: Array = []
	for i: int in pool:
		if _lower[i].contains(lower) or _full_names[i].to_lower().contains(lower):
			out.append(_record(i))
			if out.size() >= limit:
				break
	return out
