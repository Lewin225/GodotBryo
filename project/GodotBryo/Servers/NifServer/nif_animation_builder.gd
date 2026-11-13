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
	var resolver := _kf_target
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
## to later. Every target counts as a shape: the flag only lets material
## links (alpha, texture transform, emissive, emittance, refraction) build
## tracks, and a material controller's target is a shape of the rig the KF
## plays on, never one in the KF, which holds none. A link naming a node that
## is no shape writes a property that node does not have, which does nothing.
static func _kf_target(target: String) -> Dictionary:
	return {"path": NifNamesScript.escape(target), "shape": true, "bone": false}
