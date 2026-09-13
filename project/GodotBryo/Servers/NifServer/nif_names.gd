@tool
extends RefCounted
class_name NifNames

## Reversible NIF-name <-> Godot-node-name mapping.
##
## Research §6: 41.6% of all NiAVObject name references contain a character
## Godot forbids in a node name, overwhelmingly the exporter's ":0"/":1"
## multi-material split suffix. Animation binding, attach-point lookup and the
## object palette all resolve by name, so the mapping must round-trip -- a
## one-way replace(":", "_") (what mesh_resolver.gd does today) silently
## breaks KF retargeting for the 1,317 distinct target names that carry one.
##
## Godot forbids  . : @ / % "  in node names, so the escape marker itself has
## to be a legal character: "_" is used. "_" is escaped first as "_5F", after
## which every remaining "_" in the output is unambiguously a marker
## introducing two hex digits.

const _ILLEGAL := [".", ":", "@", "/", "%", "\""]

## Nodes carry their authored name verbatim under this key. Godot auto-renames
## duplicate siblings and 245 shipped NIFs contain a duplicate NiAVObject name
## (2,326 surplus), so callers must resolve against this rather than node name.
const META_NIF_NAME := "nif_name"


static func escape(nif_name: String) -> String:
	if nif_name.is_empty():
		return ""
	var out := nif_name.replace("_", "_5F")
	for c in _ILLEGAL:
		out = out.replace(c, "_%02X" % c.unicode_at(0))
	return out


static func unescape(node_name: String) -> String:
	var out := ""
	var i := 0
	while i < node_name.length():
		if node_name[i] == "_" and i + 2 < node_name.length():
			var hex := node_name.substr(i + 1, 2)
			if hex.is_valid_hex_number():
				out += String.chr(hex.hex_to_int())
				i += 3
				continue
		out += node_name[i]
		i += 1
	return out
