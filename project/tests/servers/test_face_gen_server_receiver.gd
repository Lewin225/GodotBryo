extends Node

## A request owner for test_face_gen_server that is freed before delivery.

var received := false


func receive(_mesh: ArrayMesh) -> void:
	received = true
