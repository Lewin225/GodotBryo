extends Node3D

# Heavier repro: many CONCURRENT worker tasks all building ArrayMesh/
# ImageTexture/StandardMaterial3D/Shape3D at once (closer to WorldStreamer's
# real load -- ~15 pool contexts, hundreds of placements each) while the
# main thread ALSO does real RenderingServer-touching Node work every
# frame, same as it would during real streaming. A single isolated task
# succeeding doesn't rule out a race that only shows up under real
# contention.

var _errors := 0
var _ok := 0

func _worker(i: int) -> void:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	var verts := PackedVector3Array()
	for v in range(30):
		verts.append(Vector3(v, i, -v))
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)

	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color(randf(), randf(), randf()))
	var tex := ImageTexture.create_from_image(img)

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex

	var box := BoxShape3D.new()
	box.size = Vector3(1, 1, 1)

	if mesh.get_aabb().size.length() > 0.0 and tex.get_size().x == 8 and mat.albedo_texture == tex and box.get_rid().is_valid():
		_ok += 1
	else:
		_errors += 1

func _ready() -> void:
	var ids: Array = []
	for i in range(400):
		ids.append(WorkerThreadPool.add_task(_worker.bind(i)))

	# Real main-thread RS-touching work happening AT THE SAME TIME as the
	# worker tasks above -- same contention shape as real streaming (main
	# thread building/rendering while resolve tasks run).
	for i in range(200):
		var mi := MeshInstance3D.new()
		mi.mesh = BoxMesh.new()
		add_child(mi)
		mi.queue_free()

	for id in ids:
		WorkerThreadPool.wait_for_task_completion(id)

	print("ok=", _ok, " errors=", _errors)
	get_tree().quit(0)
