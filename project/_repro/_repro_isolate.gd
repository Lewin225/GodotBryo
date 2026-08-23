extends Node3D

# Isolate exactly which of {mesh, texture, material, shape} construction is
# actually unsafe under real concurrent contention (many worker tasks +
# simultaneous main-thread RS work), rather than assuming all four are
# equally guilty just because they crashed together.

const N := 400

func _main_thread_contention() -> void:
	for i in range(200):
		var mi := MeshInstance3D.new()
		mi.mesh = BoxMesh.new()
		add_child(mi)
		mi.queue_free()

func _run(label: String, worker: Callable) -> void:
	var ids: Array = []
	for i in range(N):
		ids.append(WorkerThreadPool.add_task(worker.bind(i)))
	_main_thread_contention()
	var had_error := false
	for id in ids:
		WorkerThreadPool.wait_for_task_completion(id)
	print(label, ": done (check stderr above for ERROR lines during this block)")

func _ready() -> void:
	print("=== MESH ONLY ===")
	_run("mesh", func(i):
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		var verts := PackedVector3Array()
		for v in range(30):
			verts.append(Vector3(v, i, -v))
		arrays[Mesh.ARRAY_VERTEX] = verts
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	)

	print("=== TEXTURE ONLY ===")
	_run("texture", func(i):
		var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
		img.fill(Color(randf(), randf(), randf()))
		var tex := ImageTexture.create_from_image(img)
	)

	print("=== MATERIAL ONLY (no texture) ===")
	_run("material", func(i):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(randf(), randf(), randf())
	)

	print("=== SHAPE ONLY ===")
	_run("shape", func(i):
		var box := BoxShape3D.new()
		box.size = Vector3(1, 1, 1)
	)

	print("ALL DONE")
	get_tree().quit(0)
