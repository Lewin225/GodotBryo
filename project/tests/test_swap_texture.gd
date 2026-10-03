extends Node3D

## SwapTexture on the Rorschach card (TempRorschachTest01REF, block
## "PipBoyCard01:0"): every texture VCG01's INFO scripts swap in exists; a swap
## made before the card loads and one made while it is loaded both reach the
## block's mesh as its albedo, on a copy of its material.

const BLOCK := "PipBoyCard01:0"
const CARDS := ["pipboycard01", "pipboycard02", "pipboycard03", "pipboycard04", "pipboycard05", "InkBlot01", "InkBlot02", "InkBlot03"]

var failures := 0

func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1

func _ready() -> void:
	var esm_server = get_node("/root/EsmServer")
	if not esm_server.is_ready():
		await esm_server.esm_ready
	var script_server = get_node("/root/ScriptServer")

	var missing: Array[String] = []
	for card in CARDS:
		if await TextureServer.request("textures\\clutter\\rorchachtest\\%s.dds" % card) == null:
			missing.append(card)
	check(missing.is_empty(), "all %d card textures exist (missing %s)" % [CARDS.size(), missing])

	var card: EsmReference = esm_server.find_reference_by_editor_id("TempRorschachTest01REF")
	script_server.run_debug_line("SwapTexture TempRorschachTest01REF \"PipBoyCard01:0\" \"clutter\\rorchachtest\\pipboycard03\"")
	check(card.texture_swaps.get(BLOCK) == "clutter\\rorchachtest\\pipboycard03", "SwapTexture records the swap on the reference, unloaded")

	card.set_disabled(false)
	var node: EsmNode = EsmReferencePhysicaliser.new().physicalise(card, self)
	var mesh := await _card_mesh(node)
	check(mesh != null, "the card's visual has a mesh for block %s" % BLOCK)
	if mesh == null:
		_finish(card)
		return
	var authored: Texture2D = (mesh.mesh.surface_get_material(0) as BaseMaterial3D).albedo_texture
	var expected: Texture2D = await TextureServer.request("textures\\clutter\\rorchachtest\\pipboycard03.dds")
	await _settle()
	check(_albedo(mesh) == expected and mesh.get_surface_override_material(0) != null,
			"loading applies the earlier swap through an override material")

	script_server.run_debug_line("SwapTexture TempRorschachTest01REF \"pipboycard01:0\" \"clutter\\rorchachtest\\InkBlot02\"")
	var inkblot: Texture2D = await TextureServer.request("textures\\clutter\\rorchachtest\\InkBlot02.dds")
	await _settle()
	check(_albedo(mesh) == inkblot and (mesh.mesh.surface_get_material(0) as BaseMaterial3D).albedo_texture == authored,
			"a swap while loaded (block name in another case) changes it; the shared material keeps its texture")
	node.queue_free()
	_finish(card)

func _finish(card: EsmReference) -> void:
	card.texture_swaps.clear()
	card.set_disabled(true)
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)

func _card_mesh(node: EsmNode) -> MeshInstance3D:
	for i in 600:
		await get_tree().process_frame
		var visual := node.get_node_or_null("NifVisual")
		if visual == null:
			continue
		for m: MeshInstance3D in visual.find_children("*", "MeshInstance3D", true, false):
			if m.get_meta(NifNames.META_NIF_NAME, "") == BLOCK:
				return m
	return null

func _settle() -> void:
	for i in 5:
		await get_tree().process_frame

func _albedo(mesh: MeshInstance3D) -> Texture2D:
	var material := mesh.get_active_material(0) as BaseMaterial3D
	return material.albedo_texture if material != null else null
