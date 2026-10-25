# GodotBryo

An attempt at a from-scratch*, drop-in replacement for Gamebryo, in Godot 4.7. Targeting Fallout: New Vegas for now (Fallout 3 and Skyrim maybe later).

* OpenMW's source was read to help answer a few questions that the geck didn't document
<img width="3416" height="1348" alt="105" src="https://github.com/user-attachments/assets/456494c3-2c8d-46e3-b9ad-1dada39486e9" />

It reads the original ESM/BSA/NIF/DDS files directly, so you need your own copy of the game. Nothing from the game is in this repo.

Why Godot? Lightweight, existing renderer, free, easy to extend through GDExtension, source available, multi-platform.

<img width="2256" height="1355" alt="88" src="https://github.com/user-attachments/assets/bc7202d2-9d05-446c-9f88-6a4358b242ba" />

Why at all. I don't like the character controller in vew vegas, and I never found a mod that fixed it. I'd also like to add boneworks style vr weapon controls, coop and those nice half life alyx npc animations where they place feet properly.

Plus it's just an open platform to do stuff with new vegas in an easier way than injecting the original. planning on a feature to replace a given REFR with a godot scene, to allow easy modding and allow a vr mod to replace weapons

Moviemaker works too, and you can drag and drop from the inspector to build scenes for it

<img width="2192" height="1291" alt="72" src="https://github.com/user-attachments/assets/ff158bfd-b6be-4fa7-811d-7b2eb880ff70" />


## Where it's at

You can explore the whole map, but other than that. Very early. You can start a new game in Doc Mitchell's house and play through the opening quest (Doc's intro, the Rorschach test on the couch, Doc seeing you out). Most of the rest of the intro is softlocked behind not being able to shoot Sunny’s bottles (no weapons). Some other quests work. YMMV

What works, roughly:

* Interior cells with their lighting/fog, and streaming the open world with terrain built from LAND (including the 7+1 layer texture blending)
* Distant LOD, day/night, weather
* Doors and load doors, `coc`
* Script engine (lots of functions still missing), quests, conditions (+dialog conditions)
* Dialogue with voice, terminals, message boxes
* NPCs: race/head/hair/equipment, FaceGen head shapes, walking, idles, sitting on furniture, head tracking
* AI packages (Travel, Dialogue, Follow), running both on screen and off screen
* Proper REFR managment, including actors. (Any refr can be moved in or out of it's cell.. eg. DocMitchellREF.moveto player )
* Containers, activators, lights, physics items you can pick up
* Editor plugin for browsing and previewing ESM records

Not done yet: creatures, combat, Pip-Boy/inventory, loading the original UI XML, saving, VATS, face textures, lip sync, NPCs that get their look from leveled lists (they're invisible right now), only the follow and travel AI packages exist right now. See `Plans/` for what's being worked on and `ROADMAP.md` for the bigger picture.

<img width="1909" height="1074" alt="104" src="https://github.com/user-attachments/assets/e3362b02-85f5-4c58-aa0f-638cd69a0dc9" />


## Script engine

The script interpreter runs the original script source (object, quest, dialogue result and package scripts) and the condition functions. Unimplemented functions log a warning and return 0, so scripts keep running. (This does make some scripts behave weird, like weapon condition warnings)

approximate coverage

* ~126 of ~660 vanilla functions implemented
* scripts in FalloutNV.esm use 325 different functions, 106 of them implemented
* about 70% of the function calls in those scripts hit an implemented function

Biggest gaps by number of calls: `GetDead`, `RewardXP`, `StartCombat`, `RemoveFromFaction` / `AddToFaction`, `PlayGroup`, reputation (`AddReputation`, `GetReputation`, ...), `ResetAI`, `SetEnemy`, `GetLinkedRef`, `RemoveAllTypedItems`, `SetDestroyed`, `MoveToMarkerWithFade`, `StopCombat`, `SetRestrained`, perks, `PlaySound`.

### Extra console commands

Godotbryo specific bits, not in the original. Type them in the script console (debug tools, Scripting tab).

| Command | What it does |
|---|---|
| `DebugNpcReport [radius]` | Prints the NPC simulation's state for actors within `radius` metres of the player, or the player's whole space |
| `DebugNpcLog seconds` | Logs the player and the actors around them every `seconds`; 0 stops it |
| `DebugAddScriptPackageAll package` | Gives every placed actor `package` (e.g. a follow package to make everyone follow you) |
| `DebugRemoveScriptPackageAll` | Clears those packages again |
| `DebugSetLowLevelSpeed multiplier` | Speeds up or slows down actors moving off screen |
| `DebugNpcControllers 0\|1` | Turns every on-screen NPC controller's per-frame work off or on |
| `DebugActorThreads 0\|1` | Runs each actor on its own thread group, or back on the main thread |
| `DebugActorCost` | Turns off each part of every loaded actor in turn and prints what it costs |
| `DebugCopyBench [mode]` | Times creating nodes and copying actor meshes, for profiling NifServer |

<img width="1906" height="1071" alt="122" src="https://github.com/user-attachments/assets/1a8e102c-8a65-42bb-9734-b05dcac2a818" />

## Building

Linux only so far. You need a C++17 compiler, scons, and the official Godot 4.7.1 binary (not the Flatpak, it can't load the GDExtension, see `native/README.md`). It has previously ran on windows and macos, and they'll be supported when it' more complete

```bash
git clone --recursive https://github.com/Lewin225/GodotBryo.git
cd GodotBryo

# put Godot_v4.7.1-stable_linux.x86_64 in tools/

cd native
scons platform=linux target=template_debug api_version=4.7 use_static_cpp=no disable_exceptions=no -j$(nproc)

cd terrain_streamer
scons platform=linux target=template_debug api_version=4.7 use_static_cpp=no disable_exceptions=no -j$(nproc)

# Terrain3D builds into its own demo project, copy the lib across
cd ../terrain3d
scons platform=linux target=template_debug -j$(nproc)
mkdir -p ../../project/addons/terrain_3d/bin
cp project/addons/terrain_3d/bin/libterrain.linux.debug.x86_64.so ../../project/addons/terrain_3d/bin/
cd ../..

tools/Godot_v4.7.1-stable_linux.x86_64 --headless --editor --path project --quit
```

The build patches the nifly submodule, so it'll show as modified in `git status`. That's expected.

## Running

```bash
tools/Godot_v4.7.1-stable_linux.x86_64 --path project
```

Pick `FalloutNV.esm` from your game's Data folder (it restarts once to load it), then New game. You can also set `GODOTBRYO_DATA_DIR` to the Data folder instead.

Esc opens the debug tools, F3 shows what you're looking at.

## Tests

The tests run against the real game data, so pick the ESM first (or set `GODOTBRYO_DATA_DIR`).

```bash
./run_tests.sh
```

More in `project/tests/README.md`. `AGENTS.md` has a longer tour of the codebase.

## Legal

No Bethesda/Obsidian assets, code or data are included, you supply your own copy of the game. Not affiliated with or endorsed by Bethesda, Obsidian or ZeniMax. Fallout is a trademark of Bethesda Softworks LLC.

## License

GPL-3.0, see `LICENSE`. Submodules keep their own licenses: godot-cpp (MIT), nifly (GPL-3.0), Terrain3D (MIT, using [a patched fork](https://github.com/Lewin225/Terrain3D/tree/godotbryo)), SunshineClouds2 (MIT).
