Each server is a autoloaded singleton in global scope, in the same vein as godot's render/physics servers

They should offer a defined contract, thread and coroutine as much of their work as possible.

They should not call into *non* server scripts, so checking GodotBryoSettings for the esm path is okay.

# NOTE - GodotBryoSettings will be moved into this folder soon as GodotBryoSettingsServer

# NOTE - MeshServer exists only as concept notes. NifServer is the only mesh consumer so it's not needed

# ThumbnailServer

A record's picture for any UI: `request(form_id)` gives its inventory icon, else a render of its
model, as a Texture2D. `RecordVisuals` decides which, from subrecords alone (fallback model
subrecords, a creature's NIFZ body parts, a leveled list's entries), never from particular
records. Renders are keyed by model, drawn once on its own stage, kept DXT5-compressed and saved
under `user://thumbnails`. UI widgets on top of it live in `project/ui/`: `RecordIcon` (a
TextureRect for one record) and `ModelPreview` (a live, turning 3D view that starts in the
thumbnail's pose).

# Pausing

The game pauses with `get_tree().paused`: a save loading now, a pause menu later. The game
scene's nodes stop with the tree (the player, NPC controllers and everything streamed in, game
time, weather, the sky). Every server is `PROCESS_MODE_ALWAYS` and decides in its own
`_process` what pausing means for it:

| Server | While the game is paused |
|---|---|
| ArchiveServer, TextureServer, NifServer, FaceGenServer, EsmServer, SaveServer, ThumbnailServer | Carry on: they hold no game state, so a load warms them |
| ScriptServer | Runs no GameMode or MenuMode block; its clock stands; queued moves wait |
| QuestServer | Runs no quest script; its clock stands |
| DialogueServer | Lines and their voices pause, as in menu mode |
| NpcSimulationServer | Runs no package and moves no actor (PackageRunner); seeding carries on |

The streamers (CellStreamerV2, WorldStreamerV2, TerrainStreamer) and TransitionCoordinator
are game-scene nodes that act like servers: they are `PROCESS_MODE_ALWAYS` and keep loading and
drawing the loading overlay while paused. The roots they fill (a cell, a tile, the persistent
root) are `PROCESS_MODE_PAUSABLE`, so what they load stays paused.

This is not `WorldStreamerV2.set_streaming_paused()`, `TerrainStreamer.set_streaming_paused()`
or `WeatherManager.set_weather_paused()`, which hold one worldspace's streaming or the weather
during an interior visit while the game runs.
