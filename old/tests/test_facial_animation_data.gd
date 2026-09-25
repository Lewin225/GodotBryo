extends Node

const DATA_DIR := "../fresh_nv_copy/Data/"
const CLIPS := [
	"characters\\_male\\idleanims\\talk_headnodsingle_neutral.kf",
	"characters\\_male\\idleanims\\talk_headshake_sad.kf",
	"characters\\_male\\idleanims\\surgeryheadmildpain.kf",
]

func _ready() -> void:
	var resolver := GamebryoMeshResolver.new(DATA_DIR)
	for head in ["characters\\head\\headhuman.nif", "characters\\head\\headghoul.nif"]:
		var tri := resolver.load_tri(head)
		print("=== ", head, " TRI names ===")
		if tri != null:
			for i in tri.get_delta_morph_count():
				print(tri.get_delta_morph_name(i))
	for clip in CLIPS:
		var nif := resolver.load_nif(clip)
		print("=== ", clip, " ===")
		if nif == null:
			print("LOAD FAILED")
			continue
		for seq in nif.get_animation_sequences():
			print("sequence=", seq.name, " tracks=", seq.tracks.size(), " float_tracks=", seq.float_tracks.size())
			for track in seq.float_tracks:
				print("float target=", track.target_node_name, " property=", track.property_type, " controller=", track.controller_type, " keys=", track.keys.size())
	get_tree().quit()
