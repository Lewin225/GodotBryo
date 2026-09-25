extends Node

func _ready() -> void:
	var shader := load("res://gamebryo/terrain_grass_particles.gdshader") as Shader
	if shader == null:
		push_error("FAIL grass particle shader did not load")
		get_tree().quit(1)
		return
	var material := ShaderMaterial.new()
	material.shader = shader
	print("  OK   Terrain N=7 grass particle shader loaded")
	print("=======================")
	print("ALL CHECKS PASSED")
	get_tree().quit()
