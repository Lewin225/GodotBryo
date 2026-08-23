class_name DoorNode
extends GamebryoVisual

## DOOR. phases/2/07-runtime-cell-loader.md: teleport destination (if any) is
## resolved once and cached here at build time, not looked up lazily on
## interaction — the ESM-side lookup (EsmReader.get_door_destination()) is
## cheap (a byte-range-pruned walk, not a file scan), but resolving once here
## means a door with a missing/broken destination fails visibly when the
## cell loads, not silently the first time a player tries to use it, and
## avoids repeating an identical lookup on every use.

## True if this door teleports (has an XTEL) rather than just swinging open.
## Most doors do; some (e.g. a plain room door) don't — that's a normal,
## valid case, not a missing-data error.
var has_destination: bool = false
var dest_cell_form_id: int = 0
var dest_position: Vector3 = Vector3.ZERO
var dest_rotation: Vector3 = Vector3.ZERO

## Called by GamebryoObjectRegistry._build_door() right after this node's
## own form_id (GamebryoReference.form_id, this door's own REFR) is set —
## see object_registry.gd.
func resolve_destination(esm: EsmReader) -> void:
	apply_destination(esm.get_door_destination(form_id))

## The same effect as resolve_destination(), but from an already-resolved
## destination Dictionary instead of an EsmReader -- phases/2/10-threaded-
## streaming-workers.md's threaded resolve path looks the destination up
## itself (on a WorkerThreadPool task, via its own private EsmReader) and
## hands the result to the main-thread construct step, which calls this
## instead of resolve_destination() so DoorNode never touches an EsmReader
## directly regardless of which path built it.
func apply_destination(dest: Dictionary) -> void:
	has_destination = not dest.is_empty()
	if has_destination:
		dest_cell_form_id = int(dest["dest_cell_form_id"])
		dest_position = dest["dest_position"]
		dest_rotation = dest["dest_rotation"]

## phases/3/00-door-completion.md step 8: whether this non-teleporting door
## is currently open. In-memory only -- no persistence, that's save/load's
## job, out of scope here. Defaults closed -- confirmed against the real
## DLC04 shack door: its "Open" track starts at identity rotation and its
## "Close" track ends within ~0.5 degrees of identity (a small physical
## settle/overshoot in the authored animation, not an exact match, but
## close enough to confirm "identity/unanimated == closed" for this door).
var is_open: bool = false

## phases/3/00-door-completion.md Part B: DOOR.FNAM flags (esm::DoorData in
## esm_types.h) — real, confirmed values (fopdoc), stored regardless of
## whether the system each one needs actually exists yet. "Quest Item" and
## "Random Anim Start" (shown on the GECK Wiki's own DOOR dialog) are
## deliberately NOT here: neither is in FNAM at all — almost certainly
## generic record-header flags shared across many record types, not
## DOOR-specific, and their real bit position was never confirmed (not
## guessed).
##   - is_automatic_door: real and implementable (auto-teleport within
##     fAutoDoorActivateDistance), but NOT wired up here — needs a proximity
##     check somewhere in the interact/streaming loop, unscoped work.
##   - is_hidden: no local-map UI exists yet to hide this door from.
##   - is_minimal_use: needs AI/pathing (NPC shortcut suppression) to exist
##     first.
##   - is_sliding_door: no navmesh system exists yet, so "skip navmesh
##     obstacle generation" is a no-op today.
var is_automatic_door: bool = false
var is_hidden: bool = false
var is_minimal_use: bool = false
var is_sliding_door: bool = false

## Called by GamebryoObjectRegistry's door factories with
## EsmReader.get_door_data(base_form_id)'s own Dictionary (or {} if the
## FormID somehow didn't resolve to a real DOOR record — shouldn't happen
## for a placement that got this far, but a missing/malformed record isn't
## treated as fatal here any more than a missing destination is). Builds
## real AudioStreamPlayer3D children for whichever of Open/Close/Loop this
## door's own record actually sets — most doors don't set all three, and
## an ANIMATED door commonly sets none at all (see esm::DoorData's own doc
## comment: that convention bakes sound into the NIF via
## NiTextKeyExtraData instead, not read here — a real, deliberate gap, not
## a bug, when an animated door plays no sound through this path).
func apply_door_data(mesh_resolver: GamebryoMeshResolver, door_data: Dictionary) -> void:
	is_automatic_door = bool(door_data.get("is_automatic_door", false))
	is_hidden = bool(door_data.get("is_hidden", false))
	is_minimal_use = bool(door_data.get("is_minimal_use", false))
	is_sliding_door = bool(door_data.get("is_sliding_door", false))
	_add_sound_player("OpenSound", mesh_resolver, String(door_data.get("open_sound_path", "")))
	_add_sound_player("CloseSound", mesh_resolver, String(door_data.get("close_sound_path", "")))
	_add_sound_player("LoopSound", mesh_resolver, String(door_data.get("loop_sound_path", "")), true)

func _add_sound_player(node_name: String, mesh_resolver: GamebryoMeshResolver, sound_path: String, loop: bool = false) -> void:
	if sound_path == "":
		return
	var stream := mesh_resolver.load_sound(sound_path)
	if stream == null:
		return
	# A fresh AudioStreamWAV per player (not sharing mesh_resolver's own
	# cached Resource's loop_mode directly) -- the SAME cached stream may
	# be used as a one-shot Open/Close sound elsewhere and shouldn't
	# silently start looping there too. .duplicate() is cheap (this is
	# metadata + a shared PackedByteArray, not a second audio decode).
	var player_stream: AudioStreamWAV = stream.duplicate()
	player_stream.loop_mode = AudioStreamWAV.LOOP_FORWARD if loop else AudioStreamWAV.LOOP_DISABLED
	var player := AudioStreamPlayer3D.new()
	player.name = node_name
	player.stream = player_stream
	add_child(player)

func _play_sound(node_name: String) -> void:
	var player := get_node_or_null(node_name) as AudioStreamPlayer3D
	if player != null:
		player.play()

func _stop_sound(node_name: String) -> void:
	var player := get_node_or_null(node_name) as AudioStreamPlayer3D
	if player != null:
		player.stop()

## Step 4 of phases/2/07-runtime-cell-loader.md: the interaction entry
## point. DoorNode's real collision shapes live on an internal
## GamebryoCollisionBody CHILD (populate_collision_children(), called
## during _build_door() -- see enginedocs/nv_class_hierarchy.md:
## GamebryoReference is Node3D, not StaticBody3D, so collision is composed,
## not inherited). A normal Godot 3D raycast (e.g.
## PhysicsDirectSpaceState3D.intersect_ray()) against this door returns
## that CollisionBody as `collider`, not this node -- callers resolve
## `collider.owner_ref` to reach the real DoorNode (see game.gd's interact
## raycast) before calling activate() on it.
##
## Returns { "dest_cell_form_id": int, "dest_position": Vector3,
## "dest_rotation": Vector3 } or {} if this door doesn't teleport (a plain
## swinging door -- a real, valid case, not an error the caller needs to
## handle specially beyond "nothing happens"). A non-teleporting door with
## real animation data (phases/3/00-door-completion.md step 6) still plays
## its swing as a SIDE EFFECT of this call before returning {} -- callers
## (game.gd's own `outcome.is_empty() -> return`) don't need to change at
## all, "nothing happens" was always about destination data, not visuals.
##
## Deliberately a plain function returning data, not a signal, and does NOT
## call CellLoader.load_cell() itself -- DoorNode has no idea a CellLoader
## or a player exists (same reasoning as resolve_destination() being called
## by the registry rather than DoorNode reaching for EsmReader itself). The
## caller decides what to do with the result: typically
## CellLoader.load_cell(result.dest_cell_form_id), then reposition the
## player to dest_position/dest_rotation once load_completed fires.
func activate() -> Dictionary:
	if has_destination:
		return {
			"dest_cell_form_id": dest_cell_form_id,
			"dest_position": dest_position,
			"dest_rotation": dest_rotation,
		}
	_toggle_swing()
	return {}

## Toggles open<->closed and plays the matching real animation
## (populate_animation_player(), step 6) -- confirmed against the real
## `AutoClosingDoor` example script
## (enginedocs/GeckWiki/scripting/txt/Useful Scripts - GECK.txt):
## `OnActivate` calls the engine's own default `Activate`, and
## `GetOpenState`'s own documented values (1 = Open, 3 = Closed, 4 =
## Closing) confirm a door genuinely tracks real open/closed state across
## activations, not "play once and stop" -- toggling each call is the
## real behavior, not a guess.
##
## Does NOT attempt a clean mid-swing reversal (seeking the other
## animation to a mirrored playback position) -- a real, deliberate
## simplification: re-activating while still animating just switches to
## the other animation via Godot's own default blend.
##
## `is_open` itself ALWAYS toggles, regardless of whether this door has an
## animation or sound to show it -- open/closed is a real game-logic state
## (e.g. a future "is this door passable" check), not merely a label for
## "whichever clip most recently played". A door with neither (a real,
## common case -- see ROADMAP.md's own originally-flagged gap this whole
## phase exists to close, and Part B's own sound-baked-into-the-NIF gap for
## animated doors) still toggles silently/invisibly, which is correct, not
## a bug: nothing to render is a rendering gap, not a state gap. Animation
## playback is additionally skipped if this door's sequences aren't named
## "Open"/"Close" (confirmed the real, standard naming on every door
## checked so far, but not exhaustively censused across every DOOR NIF in
## the game).
func _toggle_swing() -> void:
	var opening := not is_open
	var anim_name := "Open" if opening else "Close"
	var player := get_node_or_null("AnimationPlayer") as AnimationPlayer
	if player != null and player.has_animation(anim_name):
		player.play(anim_name)
	_play_sound("OpenSound" if opening else "CloseSound")
	if opening:
		_play_sound("LoopSound")
	else:
		_stop_sound("LoopSound")
	is_open = opening
