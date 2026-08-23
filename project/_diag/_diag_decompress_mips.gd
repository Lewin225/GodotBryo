extends SceneTree

## Implementation check for the DXT1-alpha fix: does Image.decompress()
## carry the mipmap chain through, or do we need generate_mipmaps() after?

func _init() -> void:
	var resolver := GamebryoMeshResolver.new()
	var found := resolver.resolve_bytes("textures\\landscape\\roads\\roadwastelandstrip01.dds")
	var img := Image.new()
	img.load_dds_from_buffer(found["data"])
	print("before: format=", img.get_format(), " mipmaps=", img.has_mipmaps(), " size=", img.get_size())
	var t0 := Time.get_ticks_usec()
	var err := img.decompress()
	var t1 := Time.get_ticks_usec()
	print("decompress err=", err, " took ", (t1 - t0) / 1000.0, " ms")
	print("after:  format=", img.get_format(), " mipmaps=", img.has_mipmaps())
	if not img.has_mipmaps():
		var t2 := Time.get_ticks_usec()
		var gerr := img.generate_mipmaps()
		var t3 := Time.get_ticks_usec()
		print("generate_mipmaps err=", gerr, " took ", (t3 - t2) / 1000.0, " ms -> mipmaps=", img.has_mipmaps())
	quit()
