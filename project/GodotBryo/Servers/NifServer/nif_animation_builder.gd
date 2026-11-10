@tool
extends RefCounted
class_name NifAnimationBuilder

## Builds standalone KF data into an unbound AnimationLibrary. A KF is a NIF
## whose sequences address an authored, composed runtime rig rather than a
## tree owned by the file itself, so its targets are bare, escaped authored
## names and this builder never guesses a skeleton, weapon, or animobject
## target. The block -> track rules are NifAnimationConverter's.

const NifNamesScript := preload("res://GodotBryo/Servers/NifServer/nif_names.gd")
const NifAnimationConverterScript := preload("res://GodotBryo/Servers/NifServer/nif_animation_converter.gd")


## One library per file: 4,981 shipped KFs have one sequence, but 33 contain
## 2-5 and cannot be represented honestly by one Animation resource.
##
## Track paths are bare, escaped authored target names. A later composed-rig
## binder owns translating them to Skeleton3D bones or attached scene nodes.
static func build_library(src: NifSource) -> AnimationLibrary:
	if src == null:
		return null
	var sequences: Array = src.get_sequences()
	if sequences.is_empty():
		return null
	var shapes := {}
	for nd in src.get_nodes():
		if nd.has("positions"):
			shapes[String(nd["name"])] = true
	var resolver := _kf_target.bind(shapes)
	var library := AnimationLibrary.new()
	for sequence in sequences:
		var sequence_dict := sequence as Dictionary
		var animation := NifAnimationConverterScript.build_animation(sequence_dict, resolver)
		var name := NifNamesScript.escape(String(sequence_dict.get("name", "")))
		if name.is_empty():
			name = "Sequence%d" % int(sequence_dict.get("block_index", 0))
		var unique_name := name
		var collision := 0
		while library.has_animation(unique_name):
			collision += 1
			unique_name = "%s__%d" % [name, collision]
		library.add_animation(unique_name, animation)
	return library


## A KF target: its bare escaped name, addressed against the rig it is bound
## to later; a shape when the KF itself holds a shape of that name.
static func _kf_target(target: String, shapes: Dictionary) -> Dictionary:
	return {"path": NifNamesScript.escape(target), "shape": shapes.has(target), "bone": false}
