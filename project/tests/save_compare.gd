class_name SaveCompare
extends RefCounted

## Compares two saves as parsed JSON values. JSON.parse_string() does not read
## a float's printed digits back exactly, so a float may differ in its last
## digit after a save and a load; floats match within a relative 1e-9.

const RELATIVE_TOLERANCE := 1e-9


## The path of the first difference between `a` and `b`, or "" when they match.
static func first_difference(a: Variant, b: Variant, path: String = "") -> String:
	if (a is float or a is int) and (b is float or b is int):
		var scale := maxf(1.0, maxf(absf(float(a)), absf(float(b))))
		if absf(float(a) - float(b)) <= RELATIVE_TOLERANCE * scale:
			return ""
		return "%s: %s != %s" % [path, a, b]
	if typeof(a) != typeof(b):
		return "%s: %s != %s" % [path, a, b]
	if a is Dictionary:
		for key: Variant in a:
			if not b.has(key):
				return "%s/%s: missing after the load" % [path, key]
			var difference := first_difference(a[key], b[key], "%s/%s" % [path, key])
			if not difference.is_empty():
				return difference
		for key: Variant in b:
			if not a.has(key):
				return "%s/%s: only after the load" % [path, key]
		return ""
	if a is Array:
		if a.size() != b.size():
			return "%s: %d entries != %d" % [path, a.size(), b.size()]
		for i in a.size():
			var difference := first_difference(a[i], b[i], "%s[%d]" % [path, i])
			if not difference.is_empty():
				return difference
		return ""
	return "" if a == b else "%s: %s != %s" % [path, a, b]
