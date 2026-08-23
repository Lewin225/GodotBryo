extends Node

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func _ready() -> void:
	print("--- ScriptLexer ---")

	var tokens := ScriptLexer.new("Set ActivatorREF to GetActionRef;\nActivatorREF.MoveTo Marker;\n").tokenize()
	var kinds := []
	var values := []
	for t in tokens:
		kinds.append(t["kind"])
		values.append(t["value"])

	check(kinds[0] == ScriptLexer.Kind.IDENT and values[0] == "Set", "first token is IDENT 'Set'")
	check(values.has("to"), "'to' lexed as an ident")
	check(values.has("."), "'.' lexed as its own OP token")
	check(kinds[kinds.size() - 1] == ScriptLexer.Kind.EOF_, "stream ends with EOF_")

	# ';' starts a comment to end-of-line (design doc's grammar sketch) --
	# nothing after it on the same line should be tokenized.
	var comment_tokens := ScriptLexer.new("Set x to 1 ; this is a comment\nSet y to 2\n").tokenize()
	var comment_values := []
	for t in comment_tokens:
		if t["kind"] != ScriptLexer.Kind.NEWLINE and t["kind"] != ScriptLexer.Kind.EOF_:
			comment_values.append(t["value"])
	check(not comment_values.has("this"), "text after ';' is not tokenized (real comment)")
	check(comment_values.has("y"), "the next real line after a comment still lexes")

	var num_tokens := ScriptLexer.new("Set x to 3.5\nSet y to -2\n").tokenize()
	var found_float := false
	for t in num_tokens:
		if t["kind"] == ScriptLexer.Kind.NUMBER and typeof(t["value"]) == TYPE_FLOAT and is_equal_approx(t["value"], 3.5):
			found_float = true
	check(found_float, "3.5 lexes as a float NUMBER token")

	var op_tokens := ScriptLexer.new("if (a == b && c != d)\n").tokenize()
	var op_values := []
	for t in op_tokens:
		if t["kind"] == ScriptLexer.Kind.OP:
			op_values.append(t["value"])
	check(op_values.has("=="), "'==' lexed as one two-char OP token")
	check(op_values.has("&&"), "'&&' lexed as one two-char OP token")
	check(op_values.has("!="), "'!=' lexed as one two-char OP token")

	_finish()

func _finish() -> void:
	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
