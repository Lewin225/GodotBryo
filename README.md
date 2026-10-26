# GodotBryo

An attempt at a from-scratch [1][2][3] replacement for Gamebryo, in Godot 4.7. Targeting New Vegas for now (fo3 3 and Skyrim one day).

Rather the (currently very popular) decomp route, this aims to load everything from the game's *data* in at runtime, into real godot objects, scene prefabs and resources, it's not just using the godot renderer, gamebryo is g o n e

```
[1]*OpenMW's source was read to help answer a few questions that the geck
didn't document, nothing from openmw was used directly*

[2]*Huge thanks to the GECK team and their discord for putting up with
my inane implementation questions*

[3]*No decomp or binary peeking was done here, all behaviour was manually
documented from gameplay and cross referenced against the geck/openmw
```


<img width="1909" height="1074" alt="104" src="https://github.com/user-attachments/assets/5f1b4621-cb33-46c8-90e5-e07ece21271b" />


It reads the original ESM/BSA/NIF/DDS files directly, so you need your own copy of the game. Nothing from the game is in this repo.

Why Godot? Lightweight, existing renderer, free, easy to extend through GDExtension, source available, multi-platform.


<img width="3416" height="1348" alt="105" src="https://github.com/user-attachments/assets/4e8344cf-1ab2-4580-ab38-6e4dd9008f11" />


Why at all. I don't like the character controller in new vegas, and I never found a mod that fixed it the way I wanted. + this runs on Linux

I'd also like to add boneworks style vr weapon controls, coop and those [nice half life alyx npc animations where they place feet properly](https://www.youtube.com/watch?v=UOYSg08eu5Q). Generally just touch up and modernise the handling like fallout 4 did


<img width="2418" height="1359" alt="68" src="https://github.com/user-attachments/assets/b631fb6d-5ad1-441e-a7e8-c92c1b33a303" />


The goal is an open platform to do stuff with new vegas / fo3 in an easier way than modding or injecting the original. planning on a feature to replace a given REFR with a godot scene, to allow easy modding and allow a vr mod to replace weapons


<img width="2651" height="1139" alt="11" src="https://github.com/user-attachments/assets/be4eba31-4d48-4c37-9535-cb46f268e933" />


Moviemaker kinda works too, and you can drag and drop from the inspector to build scenes for it


<img width="2192" height="1291" alt="72" src="https://github.com/user-attachments/assets/bedee1e3-13ab-4b24-a149-dfa3e33eb0b3" />



## Where it's at

You can explore the whole map, but other than that. Very early. You can start a new game in Doc Mitchell's house and play through the opening quest (Doc's intro, the Rorschach test on the couch, Doc seeing you out). Most of the rest of the intro is softlocked behind not being able to shoot Sunny’s bottles (no weapons). Some other quests work. YMMV

What works, roughly, on linux:

* Interior cells with their lighting/fog, and streaming the open world with terrain built from LAND (including the 7+1 layer texture blending)
* Distant LOD, day/night, weather
* Doors and load doors, `coc`
* Script engine (lots of functions still missing), quests, conditions (+dialog conditions)
* Dialogue with voice, terminals, message boxes, doors and animated static (lockpick / hacking has a placeholder swipe to unlock prefab)
* NPCs: race/head/hair/equipment, FaceGen head shapes, walking, idles, sitting on furniture, head tracking
* AI packages (Travel, Dialogue, Follow), running both on screen and off screen
* Proper REFR managment, including actors. (Any refr can be moved in or out of it's cell.. eg. DocMitchellREF.moveto player )
* Containers, activators, lights, physics items you can pick up
* Editor plugin for browsing and previewing ESM records

Not done yet: creatures, combat, Pip-Boy/inventory, loading the original UI XML, saving, VATS, face textures, lip sync, NPCs that get their look from leveled lists (they're invisible right now), multi ESM / load order / plugins, only the follow and travel AI packages exist right now. See `Plans/` for what's being worked on and `ROADMAP.md` for the bigger picture.

## Some deliberate behaviour differences
Most of these felt like improvements that were limited by hardware at the time, refr to resource gives us editor inspect-ability at the cost of a bit more ram  
* Npc's move off screen using the full detail navmesh combined with a proxy for fast search, not a linear path like the original. no more black mountain stuck re-spawns at 0,0. It could also support genuine encounters with npc's that you pass during fast travel
* A REFR keeps its id for good. New Vegas gives picked-up and dropped items new ref ids, which makes them a pain to track - here a reference is one resource with one esm id, whatever moves it (inventory, dropping, scripts). If your mod spawns a pistol, that ref handle is good forever, wherever it ends up. (Pickup and drop aren't built yet; the reference model is.)
* The player is a controller that possesses any actor, defaulting to the player NPC_ (0x07), not a special player object. Any actor could be possessed, which is wip groundwork for co-op
* All REFR's are godot resources, compiled on demand - dirtying the resource in any way flags it as save data (saving isn't built yet), then it will no longer be fetched from the master ESM. This is so generic it serves everything from npc health to being able to base build


<img width="1910" height="1067" alt="99" src="https://github.com/user-attachments/assets/053c8893-3462-4d28-bc4d-99fed1db1ab2" />


## Script engine

The script interpreter runs the original script source (object, quest, dialogue result and package scripts) and the condition functions. Unimplemented functions log a warning and return 0, so scripts keep running. (This does make some scripts behave weird, like weapon condition warnings)

approximate coverage

* ~126 of ~660 vanilla functions implemented
* scripts in FalloutNV.esm use 325 different functions, 106 of them implemented
* about 70% of the function calls in those scripts hit an implemented function

Biggest gaps by number of calls: `GetDead`, `RewardXP`, `StartCombat`, `RemoveFromFaction` / `AddToFaction`, `PlayGroup`, reputation (`AddReputation`, `GetReputation`, ...), `ResetAI`, `SetEnemy`, `GetLinkedRef`, `RemoveAllTypedItems`, `SetDestroyed`, `MoveToMarkerWithFade`, `StopCombat`, `SetRestrained`, perks, `PlaySound`.

Script Functions - https://github.com/Lewin225/GodotBryo/blob/master/project/GodotBryo/Servers/ScriptServer/script_function_registry.gd#L64


<img width="1910" height="1067" alt="99" src="https://github.com/user-attachments/assets/2c418f95-695e-40ec-bf92-775240c30ebc" />


### Performance
I've only been implementing the sort of "runtime" perf, things like minimising hitching, making use of as many threads as possible, limiting per frame node tree additions, gpu upload timing ect... mostly through the Servers - which offer a promises style file delivery and handle gpu upload when there's time to do it

However... Memory usage is high (~7GB) - The servers keep a converted godot version of every unique object they're asked for, they use this for cache so any further calls are fast, but this cache never clears (it will in future)

The Terrain is loaded to your gpu vram and never removed. interior/exterior transitions are usually near instant because of this, but vram usage is much higher than it needs to be

Video settings are tuned for me, and there's no way to change them (3080ti, 16gb ram)

All of the ESM lights are rendered as called for, which on a deferred pipeline like gamebryo was near free. Godot uses forward rendering, with a clustering optimisation. this seems to work well enough that i've enabled shadows for every light in the game. but probably worth reviewing at some point

GI - GI is currently the most expensive bit of the render pass ~2ms, this needs work


<img width="1916" height="1076" alt="22" src="https://github.com/user-attachments/assets/e405f85f-08c4-42ae-a305-d03cd2e7cc83" />


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


<img width="1911" height="1074" alt="120" src="https://github.com/user-attachments/assets/9a0e1a79-c321-474e-8627-b362ab0e95dc" />


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
