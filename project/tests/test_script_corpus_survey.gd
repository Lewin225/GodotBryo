extends Node

## Whole-corpus real-data survey (not a pass/fail unit test): lexes and
## parses every real SCPT.SCTX in FalloutNV.esm and reports what actually
## happens -- same spirit as native/tools/alpha_survey.cpp's own real-data
## census pattern, just targeting the script parser instead of NIF shader
## data. Two things this is FOR:
##   1. Coverage: does the parser choke (structurally, not just semantically)
##      on any real script in the base game, not just the one hand-picked
##      sample the other test_script_*.gd files use.
##   2. Real usage data: an actual function-call-name histogram across every
##      real script, cross-checked against
##      enginedocs/nv_script_interpreter_design.md's own "Tier 1" ranking
##      (which was a raw grep-based frequency count, not a real parse) --
##      tells us whether that ranking holds up once real block/statement
##      structure is accounted for, and what to implement next.
##
## Deliberately not wired into the pass/fail test runner
## (project/tests/README.md's "run every headless test" loop) -- this is a
## report, not a gate; a survey finding "3 real scripts have an unusual
## shape" isn't a regression, it's information.

## Base game only (FalloutNV.esm, matching every other test_*.gd's own
## ESM_PATH) -- nv_script_interpreter_design.md's "11,483 real scripts"
## figure was counted across every DLC .esm too; this survey doesn't open
## those, a real, deliberate scope match to what this whole milestone
## covers so far, not a discrepancy.
const ESM_PATH := "../fresh_nv_copy/Data/FalloutNV.esm"

func _ready() -> void:
	var esm := EsmReader.new()
	if not esm.open(ESM_PATH):
		print("FAIL: could not open ESM: ", esm.get_last_error())
		get_tree().quit(1)
		return

	var form_ids: PackedInt64Array = esm.get_all_script_form_ids()
	print("--- script corpus survey: %d real SCPT records ---" % form_ids.size())

	var total_blocks := 0
	var total_stmts := 0
	var empty_source_count := 0
	var zero_block_despite_begin := [] # editor_ids worth investigating by hand
	var block_type_counts := {} # lowercased blocktype -> count
	var known_function_counts := {} # lowercased name -> count
	var unknown_function_counts := {} # lowercased name -> count

	var registry := ScriptFunctionRegistry.new()
	var start_ms := Time.get_ticks_msec()

	for i in range(form_ids.size()):
		var form_id := int(form_ids[i])
		var data: Dictionary = esm.get_script_data(form_id)
		if data.is_empty():
			continue
		var source := String(data["source_text"])
		if source.strip_edges() == "":
			empty_source_count += 1
			continue

		var tokens := ScriptLexer.new(source).tokenize()
		var program := ScriptParser.new(tokens).parse()

		var blocks: Array = program["blocks"]
		total_blocks += blocks.size()
		# Naive substring check -- doesn't account for comments, so a script
		# whose ENTIRE body is commented out (real, confirmed case:
		# L38SecretDoorSCRIPT's whole BEGIN OnActivate block is `;`-prefixed
		# line by line in the actual game data) is a false positive here,
		# not a parser bug. Left naive deliberately -- this list is a
		# by-hand spot-check starting point, not a pass/fail signal.
		if blocks.is_empty() and source.to_lower().find("begin") != -1:
			zero_block_despite_begin.append(String(data.get("editor_id", "0x%X" % form_id)))

		for block in blocks:
			var bt := String(block["blocktype"]).to_lower()
			block_type_counts[bt] = block_type_counts.get(bt, 0) + 1
			total_stmts += block["stmts"].size()
			_count_functions(block["stmts"], registry, known_function_counts, unknown_function_counts)

		if i % 2000 == 0 and i > 0:
			print("  ... %d / %d (%.1fs)" % [i, form_ids.size(), (Time.get_ticks_msec() - start_ms) / 1000.0])

	var elapsed_s := (Time.get_ticks_msec() - start_ms) / 1000.0
	print("\n--- summary ---")
	print("scripts parsed: %d   elapsed: %.1fs (%.2fms/script)" % [form_ids.size(), elapsed_s, elapsed_s * 1000.0 / max(1, form_ids.size())])
	print("empty source_text: %d" % empty_source_count)
	print("total blocks: %d   total statements: %d" % [total_blocks, total_stmts])
	print("scripts with 0 parsed blocks despite containing 'begin': %d" % zero_block_despite_begin.size())
	if zero_block_despite_begin.size() > 0:
		print("  sample: ", zero_block_despite_begin.slice(0, 10))

	print("\n--- block type histogram (top 20) ---")
	_print_top(block_type_counts, 20)

	print("\n--- known (implemented) function calls (top 20) ---")
	_print_top(known_function_counts, 20)

	print("\n--- unknown (unimplemented) function calls (top 30 -- real prioritization data) ---")
	_print_top(unknown_function_counts, 30)

	get_tree().quit(0)

func _count_functions(stmts: Array, registry: ScriptFunctionRegistry, known: Dictionary, unknown: Dictionary) -> void:
	for stmt in stmts:
		match String(stmt["kind"]):
			"set":
				_count_functions_in_expr(stmt["expr"], registry, known, unknown)
			"if":
				for branch in stmt["branches"]:
					_count_functions_in_expr(branch["cond"], registry, known, unknown)
					_count_functions(branch["stmts"], registry, known, unknown)
				_count_functions(stmt.get("else_stmts", []), registry, known, unknown)
			"call":
				_count_call(stmt, registry, known, unknown)

func _count_functions_in_expr(expr: Dictionary, registry: ScriptFunctionRegistry, known: Dictionary, unknown: Dictionary) -> void:
	match String(expr["kind"]):
		"binop":
			_count_functions_in_expr(expr["left"], registry, known, unknown)
			_count_functions_in_expr(expr["right"], registry, known, unknown)
		"unary":
			_count_functions_in_expr(expr["operand"], registry, known, unknown)
		"call":
			_count_call(expr, registry, known, unknown)
			for a in expr["args"]:
				_count_functions_in_expr(a, registry, known, unknown)

func _count_call(call_expr: Dictionary, registry: ScriptFunctionRegistry, known: Dictionary, unknown: Dictionary) -> void:
	var name := String(call_expr["name"]).to_lower()
	if registry.is_registered(name):
		known[name] = known.get(name, 0) + 1
	else:
		unknown[name] = unknown.get(name, 0) + 1

func _print_top(counts: Dictionary, n: int) -> void:
	var keys := counts.keys()
	keys.sort_custom(func(a, b): return counts[a] > counts[b])
	for i in range(min(n, keys.size())):
		print("  %-30s %d" % [keys[i], counts[keys[i]]])
