extends SceneTree

## Throwaway diagnostic for the black-background decal investigation:
## does Godot's Image.load_dds_from_buffer() actually surface DXT3 (BC2)
## alpha data? Samples alpha stats for known-decal DXT3 textures vs a
## known-working DXT5 comparison.

func _init() -> void:
	var resolver := GamebryoMeshResolver.new()
	var targets := [
		"textures\\landscape\\roads\\roadwastelandstrip01.dds", # center-line strip, DXT1
	]
	for t in targets:
		var found := resolver.resolve_bytes(t)
		if found.is_empty():
			print(t, " -> NOT FOUND")
			continue
		var img := Image.new()
		var err := img.load_dds_from_buffer(found["data"])
		if err != OK:
			print(t, " -> load error ", err)
			continue
		print(t)
		print("  format=", img.get_format(), " size=", img.get_size(), " mipmaps=", img.has_mipmaps())
		# Decompress so get_pixel works, then sample alpha distribution.
		var work := Image.new()
		work.copy_from(img)
		if work.is_compressed():
			var derr := work.decompress()
			print("  decompress err=", derr, " -> format=", work.get_format())
		var w := work.get_width()
		var h := work.get_height()
		var buckets := { "a0": 0, "a_low": 0, "a_mid": 0, "a_high": 0, "a1": 0 }
		var n := 0
		for y in range(0, h, maxi(1, h / 64)):
			for x in range(0, w, maxi(1, w / 64)):
				var a := work.get_pixel(x, y).a
				n += 1
				if a <= 0.001: buckets["a0"] += 1
				elif a < 0.25: buckets["a_low"] += 1
				elif a < 0.75: buckets["a_mid"] += 1
				elif a < 0.999: buckets["a_high"] += 1
				else: buckets["a1"] += 1
		print("  alpha sample n=", n, " -> ", buckets)
	quit()
