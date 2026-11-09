extends Node

## ThumbnailServer -- a record's picture, for any UI: the spawn menu's grid,
## an overlay naming what the player looks at, the console's suggestions.
##
## A record's picture is its inventory icon, else a render of its model
## (RecordVisuals decides which: fallback model subrecords, a creature's body
## parts, a leveled list's entries). request(form_id) gives it as a Texture2D;
## RecordIcon (ui/record_icon.gd) is a TextureRect that shows one. For the
## live 3D view, ModelPreview (ui/model_preview.tscn) loads a model through
## request_model() and frames it like the render (frame_model()), so a live
## view starts where its thumbnail was.
##
## Icons come from TextureServer, as they are. Renders are keyed by model, not
## record, so records sharing a mesh share one render and one Texture2D. A
## render is drawn once on the stage (stage.tscn: camera, lights, World3D of
## its own) and kept for the session, mipmapped and DXT5-compressed
## (compact(), about 21 KB at 128 px), and saved as a PNG under CACHE_DIR,
## named from the model key and the render settings (cache_key()). A later
## session loads the PNG on a worker thread rather than rendering again.
##
## A render asks NifServer for the trees; NifServer resolves a tree's textures
## before it builds it, so a delivered tree is already textured. Trees are
## prepared (prepare_model()) on delivery, then wait hidden in the stage's
## viewport, never the game world. The stage draws one frame (UPDATE_ONCE),
## the image is read back after RenderingServer.frame_post_draw, and the tree
## is freed. Trees load in parallel and render one at a time.
##
## A model that fails to load or draws nothing gives null, remembered for the
## session and not saved. --headless draws nothing, so every render is null.
## Callers pace their own requests (the spawn menu asks only for what is on
## screen); every request runs once per key however many ask.
##
## The stage has physics interpolation off: the project turns it on, and the
## camera and model are moved in _process, so an interpolated frame would draw
## them part way between their last two physics ticks, at the wrong size.

const CACHE_DIR := "user://thumbnails"
## Bump when the stage (lights, environment) changes, to drop old renders.
const CACHE_VERSION := 3
## Rendered width and height, in pixels; a UI scales it. The live preview
## (ModelPreview) is there for a closer look.
const THUMBNAIL_SIZE := 128
## The pose renders are drawn in, and live previews start in: the model's yaw
## (level, no pitch), and the camera's pitch, in degrees; and how much of the
## view the model's bounding sphere fills.
const START_YAW_DEGREES := -35.0
const CAMERA_PITCH_DEGREES := -20.0
const FILL := 0.9
const ACTOR_PREFIX := RecordVisuals.ACTOR_PREFIX

const StageScene := preload("res://GodotBryo/Servers/ThumbnailServer/stage.tscn")

## Emitted when a render or an icon request ends, with its texture or null.
signal finished(key: String, texture: Texture2D)

var _stage: SubViewport
var _camera: Camera3D
var _pivot: Node3D
## Form id -> its visual (RecordVisuals.visual()).
var _visuals := {}
var _visual_finder: RecordVisuals
## Icon path (under textures/) -> Texture2D, or null when it did not load.
var _icons := {}
## Model key -> Texture2D, or null when it gave none.
var _renders := {}
## Icon paths and model keys being loaded or rendered.
var _pending := {}
var _stage_busy := false
## WorkerThreadPool tasks running (PNG loads and saves, compression).
var _tasks: Array[int] = []
## Renders drawn and PNGs loaded this session, for tests and debug panels.
var renders_done := 0
var disk_loads := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_stage = StageScene.instantiate()
	_stage.size = Vector2i(THUMBNAIL_SIZE, THUMBNAIL_SIZE)
	_stage.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_stage)
	_camera = _stage.get_node("Camera3D")
	_pivot = _stage.get_node("Pivot")
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)

func _exit_tree() -> void:
	for task in _tasks:
		WorkerThreadPool.wait_for_task_completion(task)
	_tasks.clear()

# --- Records -----------------------------------------------------------------

## The visual of record `form_id` (RecordVisuals.visual(): icon, model key,
## leveled, parts); empty until EsmServer is ready.
func record_visual(form_id: int) -> Dictionary:
	if _visuals.has(form_id):
		return _visuals[form_id]
	if not EsmServer.is_ready():
		return {}
	if _visual_finder == null:
		_visual_finder = RecordVisuals.new(EsmServer.reader, ArchiveServer)
	var found := _visual_finder.visual_of(form_id)
	_visuals[form_id] = found
	return found

## Record `form_id`'s picture: its icon, else a render of its model; null when
## it has neither. A coroutine.
func request(form_id: int) -> Texture2D:
	var found := record_visual(form_id)
	var texture: Texture2D
	if not String(found.get("icon", "")).is_empty():
		texture = await request_icon(found["icon"])
	if texture == null and not String(found.get("model", "")).is_empty():
		texture = await request_render(found["model"])
	return texture

## Record `form_id`'s picture if it is ready now, else null; starts nothing.
func cached(form_id: int) -> Texture2D:
	var found := record_visual(form_id)
	var texture: Texture2D = _icons.get(String(found.get("icon", "")))
	return texture if texture != null else _renders.get(String(found.get("model", "")))

## Whether record `form_id` has a picture to give (an icon or a model).
func has_picture(form_id: int) -> bool:
	var found := record_visual(form_id)
	return not (String(found.get("icon", "")).is_empty() and String(found.get("model", "")).is_empty())

# --- Icons -------------------------------------------------------------------

## The icon at `icon` (under textures/), as TextureServer gives it. A coroutine.
func request_icon(icon: String) -> Texture2D:
	if _icons.has(icon):
		return _icons[icon]
	var key := "textures/" + icon
	if _pending.has(key):
		return await _wait_for(key)
	_pending[key] = true
	var texture: Texture2D = await TextureServer.request(key)
	_pending.erase(key)
	_icons[icon] = texture
	finished.emit(key, texture)
	return texture

func has_icon(icon: String) -> bool:
	return _icons.has(icon)

func cached_icon(icon: String) -> Texture2D:
	return _icons.get(icon)

# --- Renders -----------------------------------------------------------------

## The render of the model `key` (request_model()): from memory, else the disk
## cache, else drawn. A coroutine.
func request_render(key: String) -> Texture2D:
	if _renders.has(key):
		return _renders[key]
	if _pending.has(key):
		return await _wait_for(key)
	_pending[key] = true
	var texture := await _load_from_disk(key)
	if texture == null:
		texture = await _render(key)
	_pending.erase(key)
	_renders[key] = texture
	finished.emit(key, texture)
	return texture

## Whether the render of `key` has finished, with a texture or with none.
func has_render(key: String) -> bool:
	return _renders.has(key)

func cached_render(key: String) -> Texture2D:
	return _renders.get(key)

## Whether an icon path (prefixed "textures/") or a model key is loading now.
func is_pending(key: String) -> bool:
	return _pending.has(key)

## Forgets the renders held in memory (not on disk), so the next request loads
## the saved PNG: a new session's start, for tests.
func drop_cached_renders() -> void:
	_renders.clear()

func _wait_for(key: String) -> Texture2D:
	while true:
		var result: Array = await finished
		if result[0] == key:
			return result[1]
	return null

## The PNG for the model `key` under CACHE_DIR.
func cache_path(key: String) -> String:
	return "%s/%s.png" % [CACHE_DIR, cache_key(key).md5_text()]

## The model key and every setting that changes the image.
func cache_key(key: String) -> String:
	return "%s|v%d|%d|%.3f|%.3f|%.3f|%.1f" % [key.to_lower(), CACHE_VERSION, THUMBNAIL_SIZE,
			start_pose().x, start_pose().y, FILL, CAMERA_PITCH_DEGREES]

func _load_from_disk(key: String) -> Texture2D:
	var file := cache_path(key)
	if not FileAccess.file_exists(file):
		return null
	var loaded: Array = [null]
	await _on_worker(func() -> void:
		var image := Image.load_from_file(file)
		if image != null and not image.is_empty():
			loaded[0] = compact(image))
	var image: Image = loaded[0]
	if image == null:
		return null
	disk_loads += 1
	return ImageTexture.create_from_image(image)

func _render(key: String) -> Texture2D:
	var delivery: Array = [null, false]
	request_model(key, _on_render_tree.bind(delivery))
	while not delivery[1]:
		await get_tree().process_frame
	var tree: Node3D = delivery[0]
	if tree == null:
		return null
	while _stage_busy:
		await get_tree().process_frame
	_stage_busy = true
	var pose := start_pose()
	_pivot.basis = Basis(Vector3.RIGHT, pose.y) * Basis(Vector3.UP, pose.x)
	tree.reparent(_pivot, false)
	tree.visible = true
	frame_model(tree, _pivot, _camera)
	_stage.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	var image := _stage.get_texture().get_image()
	_pivot.remove_child(tree)
	tree.queue_free()
	_stage_busy = false
	if image == null or image.is_empty() or image.get_used_rect().size == Vector2i.ZERO:
		return null
	renders_done += 1
	var file := cache_path(key)
	await _on_worker(func() -> void:
		image.save_png(file)
		compact(image))
	return ImageTexture.create_from_image(image)

## A tree for a render arriving: parented at once, hidden, in the stage's
## viewport until the stage is free to draw it.
func _on_render_tree(tree: Node3D, delivery: Array) -> void:
	if tree != null:
		tree.visible = false
		_stage.add_child(tree)
	delivery[0] = tree
	delivery[1] = true

## `image` as it is kept: mipmapped (UIs draw it smaller than it is) and
## compressed to DXT5 (S3TC with alpha). The same image, uncompressed, when
## this build has no S3TC encoder (Image compression is an editor-build
## feature). Safe on a worker thread.
static func compact(image: Image) -> Image:
	image.generate_mipmaps()
	image.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_GENERIC)
	return image

## Runs `work` on WorkerThreadPool and waits, a frame at a time, until it is
## done. Waited for in _exit_tree() too.
func _on_worker(work: Callable) -> void:
	var task := WorkerThreadPool.add_task(work)
	_tasks.append(task)
	while not WorkerThreadPool.is_task_completed(task) and is_inside_tree():
		await get_tree().process_frame
	if _tasks.has(task):
		_tasks.erase(task)
		WorkerThreadPool.wait_for_task_completion(task)

# --- Models ------------------------------------------------------------------

## The model's [yaw, pitch] before anything turns it, in radians: renders are
## drawn in it, and live previews start in it.
static func start_pose() -> Vector2:
	return Vector2(deg_to_rad(START_YAW_DEGREES), 0.0)

## Loads the model `key` and calls `on_complete(tree)` once with it: its NIFs,
## each from NifServer, under one new Node3D, prepared (prepare_model()); or
## null when none loads. A key is one path under meshes/
## ("meshes/clutter/fridge.nif"), or several joined by "|" for a model built of
## parts (a creature's body parts, shown with no skeleton, so skinned parts
## stay in their bind pose). A key starting with ACTOR_PREFIX is an actor's:
## its model is turned 180°, as an actor's front faces away from the camera
## here. The tree is the caller's: parent or free it. When `on_complete` is no
## longer valid (its object freed), the tree is freed instead.
func request_model(key: String, on_complete: Callable) -> void:
	var actor := key.begins_with(ACTOR_PREFIX)
	var paths := key.trim_prefix(ACTOR_PREFIX).split("|", false)
	var root := Node3D.new()
	root.name = "Model"
	if actor:
		root.rotation.y = PI
	var state := {"root": root, "left": paths.size(), "on_complete": on_complete}
	if paths.is_empty():
		_finish_model(state)
		return
	for path in paths:
		NifServer.request(path, self, _on_part_delivered.bind(state))

## One NIF of a request_model() arriving: prepared and parented at once
## (NifServer frees a tree nobody adopts) and, with the last, the model handed
## over.
func _on_part_delivered(tree: Node3D, state: Dictionary) -> void:
	if tree != null:
		prepare_model(tree)
		(state["root"] as Node3D).add_child(tree)
	state["left"] = int(state["left"]) - 1
	if int(state["left"]) <= 0:
		_finish_model(state)

func _finish_model(state: Dictionary) -> void:
	var root: Node3D = state["root"]
	var on_complete: Callable = state["on_complete"]
	if root.get_child_count() == 0 or not on_complete.is_valid():
		root.free()
		root = null
		if not on_complete.is_valid():
			return
	on_complete.call(root)

## Removes collision bodies and hides NIF editor markers: a picture needs no
## physics, and a NifRigidBody would undo its turning (it is top level and,
## while awake -- a frozen body never sleeps -- moves its owning node, the
## meshes, back to its own transform every frame). A body with meshes under it
## is kept, frozen. Run before the tree enters the scene tree: a NifRigidBody
## that enters goes top level and, awake, carries the meshes off with the
## simulation.
static func prepare_model(tree: Node) -> void:
	for node in tree.find_children("*", "CollisionObject3D", true, false):
		if not is_instance_valid(node):
			continue
		if node.find_children("*", "VisualInstance3D", true, false).is_empty():
			node.get_parent().remove_child(node)
			node.free()
		elif node is RigidBody3D:
			(node as RigidBody3D).freeze = true
	for node in tree.find_children("*", "Node3D", true, false):
		if node.is_in_group(&"nif_editor_objects"):
			(node as Node3D).visible = false

## Centres `tree` (a child of `pivot`) on the pivot and backs `camera` off,
## CAMERA_PITCH_DEGREES above level, until the model's bounding sphere fills
## FILL of the view. Bounds are taken in the pivot's space, so a rotated NIF
## root frames the same and the framing does not change as the pivot turns.
static func frame_model(tree: Node3D, pivot: Node3D, camera: Camera3D) -> void:
	var bounds := model_bounds(tree, pivot)
	if bounds.size == Vector3.ZERO:
		bounds = AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
	tree.position -= bounds.get_center()
	var radius := maxf(bounds.size.length() * 0.5, 0.01)
	var distance := radius / sin(deg_to_rad(camera.fov) * 0.5) / FILL
	var pitch := deg_to_rad(CAMERA_PITCH_DEGREES)
	camera.position = Vector3(0.0, -sin(pitch), cos(pitch)) * distance
	camera.look_at(Vector3.ZERO)
	camera.near = maxf(distance - radius * 2.0, 0.01)
	camera.far = distance + radius * 2.0

## The merged AABB of `root`'s visible meshes, in `space`'s coordinates. Both
## must be in the scene tree.
static func model_bounds(root: Node3D, space: Node3D) -> AABB:
	var result := AABB()
	var first := true
	var to_space := space.global_transform.affine_inverse()
	for node in root.find_children("*", "VisualInstance3D", true, false):
		var visual := node as VisualInstance3D
		if not visual.is_visible_in_tree():
			continue
		var box := to_space * visual.global_transform * visual.get_aabb()
		if first:
			result = box
			first = false
		else:
			result = result.merge(box)
	return result
