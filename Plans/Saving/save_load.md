# Save and load

The game's runtime state is written to a save file and restored from it, so a session can stop
and resume. Replaces the earlier reference persistence plan. ROADMAP Phase 9.

## Facts

Runtime state as of `08cc182`, by owner. Caches, nodes and anything rebuilt from the ESM are left
out.

- **References** (`EsmServer._authored_reference_cache`, plus the player from
  `create_reference_for_base`). ESM-read fields are `@export_custom(..., READ_ONLY)`; runtime
  fields are plain `@export`.
  - `EsmReference`: `current_space_form_id`, `position`, `rotation`, `disabled`,
    `marked_for_delete`, `script_instance` (SCPT FormID and locals). Plain `var`, so not saved by
    a property walk: `texture_swaps`, `used_by`.
  - `ActorReference`: `controller`, `move_target`, `has_move_target`, `active_package`,
    `script_package`, `package_completed`, sitting state, `special_idle`, `last_idle`,
    `is_moving`, `is_running`, `is_sneaking`, `look_target`, `alive`, `contents` (Inventory),
    `actor_values` (`base_overrides`, `permanent`, `damage`), `leveled_template`,
    `leveled_template_level`. Plain `var`: `using`, the furniture marker index.
  - `DoorReference`: `is_open`, `is_locked`, `lock_level`. `ContainerReference`: `is_open`,
    `contents`. `TerminalReference`: `is_locked`, `lock_level`. `ActivatorReference`: `is_open`.
    `FurnitureReference.occupants` is plain `var`, rebuilt from actors' `using`.
  - Every one of the 6,385 seeded actors changes position under the simulation, so every actor
    is saved; `dirty` is set only by `disabled` and the player's NPC_ edits.
- **Bases.** `dirty` is set only on the player's NPC_ (FULL from the name menu, ACBS Female from
  the race menu and `SexChange`). `EncounterZoneBase.resolved_level` is runtime state on a base.
- **QuestServer.** `_states` (QUST FormID -> `QuestState`: stage, `stages_done`, running,
  `script_delay`, completed, failed, objectives displayed and completed, `script_instance`),
  `_clock`, `_next_run`, `active_quest`.
- **ScriptServer.** `globals.values`, `clock`, `_instances` (references whose script has run;
  their locals are on the reference), `disabled_player_controls`, `_pending_moves`.
- **DialogueServer.** `_said` (speaker instance_id -> INFO FormID -> game day),
  `_talked_to_player`, `_added_topics`. The conversation in progress is not saved.
- **NpcSimulationServer.** Indices by instance_id, space and cell are rebuilt from the
  references. `PackageRunner` and `LowLevelTravel` hold routes, door plans and timers that are
  recomputed.
- **Time and weather.** `GameTimeManager`: `game_hour`, `game_day`, `game_month`, `game_year`,
  `game_days_passed`, `timescale`. `WeatherManager`: the current and next weather and
  `blend_alpha`.
- **Runtime-created references.** None: `PlaceAtMe` is disabled (`game.gd`).
  `create_reference_for_base` names every reference of one base `base:%08X`, which cannot tell
  two created references apart. `get_reference()` resolves `authored:`, `base:` and the player;
  `tests/test_esm_server.gd` checks that `runtime:` returns null.
- **Inventories** (`gamebryo/inventory.gd`). `add_item()` builds a reference for every entry,
  stackable or not. Item ids are `inventory:%08X:%d` from a counter per inventory
  (`_next_instance_id`), so two inventories give the same id. `serialize_state()` and
  `restore_state()` already turn an inventory into a plain Dictionary and back.
- **Inventory readers.** Every reader of `InventoryItem.item_reference` outside `Inventory` uses
  only its `base`, `base_form_id` or class (`ActorEquipment`, `EsmActorEquipmentState`,
  `ScriptFunctionRegistry` GetItemCount/RemoveItem/RemoveAllItems, the browser dock, `game.gd`).
  Only `serialize_state()`/`restore_state()` read reference state: `WeaponReference.condition`,
  `loaded_ammo_form_id`, `loaded_ammo_count` and `ArmorReference.condition`. The COED owner and
  condition are already on `InventoryItem` (`owner_form_id`, `health_percent`), not the reference.
  Item references are named `inventory-ref:%08X:%d` (`EsmServer._create_inventory_item_reference`)
  and items `inventory:%08X:%d`, both numbered per inventory.
- **Writes to runtime fields.** Of the plain `@export` reference fields, only `disabled` (through
  `set_disabled`) marks dirty. Position and rotation are written by `PlayerController`,
  `NpcController`, `LowLevelTravel`, `ScriptServer` and `FurnitureSeating`; packages by
  `PackageRunner`; idles and sitting by `ActorIdles` and `FurnitureSeating`; `look_target` by
  `ScriptFunctionRegistry`; locks and `is_open` by `ScriptServer`, `ScriptFunctionRegistry` and
  `EsmDoorNode`; script locals through `ScriptInstance`; inventories and actor values through
  their own methods. Plain `@export` also holds ESM-read fields that EsmServer fills when it builds
  a reference (`activation_flags`, `lock_flags`, `lock_key_form_id`, `is_leveled_lock`,
  `is_open_by_default`, `emittance_form_id`, `health`, `idle_form_id`, `topic_form_id`,
  `spawn_cell_form_id`), so plain `@export` is not yet only runtime state.
- **Leveled picks.** `ActorReference.get_leveled_template()` seeds its random pick from the
  instance_id (or the space, XLCM and list), at the player's level, or the encounter zone's
  `resolved_level`. EsmServer makes the pick while it builds an actor, before its inventory and
  actor values. A clean actor makes the same pick again only if the player's level and the zones'
  levels are restored before it is built.
- **Disabled actors.** `PackageRunner` and `LowLevelTravel` skip an actor whose `is_disabled()` is
  true, so an initially disabled actor does not move until it is enabled. An actor under an
  enable parent takes its state from the parent.
- **Authored inventory entries** (FalloutNV.esm): CNTO is a base or LVLI FormID and a count;
  6,595 on CONT, 16,166 on NPC_, 1,568 on CREA, 2,586 with a count above 1. LVLO adds 13,319.
  None names a placed reference. COED (owner, global or rank, condition) follows 1,455 CNTO and
  1,926 LVLO: 2,110 on ARMO, 1,261 on WEAP, 8 on LVLI, 1 MISC, 1 NOTE; conditions 0.12 to 0.85;
  2 CONT entries set an owner.
- `ResourceSaver` reports cyclic inclusion on bases whose resolved links form a cycle
  (`Completed Plans/Actors/actors.md`).

## Design

### Format

- A save is a folder of readable text files, one per server (a server with much state splits
  its own into a subfolder), so a quest stage or an NPC is found and edited in its server's file:

  ```
  user://saves/<save name>/
    header.json            format version; masters with size and modified time; player space,
                           position and cell; game days passed; real time saved; parent save
    esm_server/
      bases.json           dirty bases; encounter zone resolved_level
      runtime.json         the runtime counter; runtime references
      references/<space editor ID>.json
                           authored and player references, by the space they are in
    quest_server.json      QuestState per QUST; the clock, next runs, active quest
    script_server.json     global values, clock, disabled player controls
    dialogue_server.json   said, talked to the player, added topics
    game_time.json         GameTimeManager
    weather.json           WeatherManager
  ```
- Files are sorted and indented, one entry per line, the same order every time, so two saves
  diff cleanly. Entries keyed by FormID or instance_id also carry the editor ID (of the record,
  the base, the cell), which the loader ignores.
- A save is written to a new folder and renamed into place, so a failed save leaves the old one.
- Not Godot resources: loading a `.tres`/`.res` can load and run scripts, builds an object per
  field and runs every setter. Files are plain JSON (`JSON.stringify`, `JSON.parse_string`, which
  builds only plain values). `JSON.from_native` was rejected: it prefixes every key and value
  with its type and flattens dictionaries, which defeats editing by hand. Types come back from
  each property's declared type (`SaveFields`), never from the file.
- Two ways to store saves, chosen by the player:
  - **Full** (the default): every save is a complete folder.
  - **Git**, offered only when git is installed: the saves folder is a git repository and each
    save is a commit, so saves share unchanged files and a save loaded and saved again from an
    earlier one starts a branch. The save browser can later show the branches, and a remote gives
    save sync between machines.
- Reading a save reads its files whole; nothing seeks. Step 4 measures size, save time and read
  time.

### Layers

- **State.** Each owner's `save_state()`/`load_state()` turns its state into a save state of
  plain values and back. Owners know nothing of files.
- **SaveServer** (new autoload) builds the whole save state from the owners and applies one to
  them in the load order below. It owns the save state's schema and format version, migrations
  from older versions, the master check, the save and load refusals, and which backend stores
  saves.
- **Backends** store and fetch whole save states, already in the current version:

  ```gdscript
  class_name SaveBackend
  extends RefCounted

  ## Stores `state` (header and sections of plain values) under `save_id`.
  func write(save_id: String, state: Dictionary) -> Error
  ## The save state stored under `save_id`, or {} with the error in `last_error`.
  func read(save_id: String) -> Dictionary
  ## Headers of every stored save, for the save browser.
  func list() -> Array[Dictionary]
  func delete(save_id: String) -> Error
  ## What the backend supports: "parents" (branches), "sync", "partial_read".
  func capabilities() -> PackedStringArray
  ```

  Backends are registered with SaveServer by name and chosen by a setting. The interface carries
  only plain values, so a backend never touches game objects. The folder of JSON files (Format)
  and Git are the first two; another (a `.fos` writer) is one more class against the schema.
- **Schema.** The save state's sections, fields, id formats and version are documented beside
  SaveServer (`project/GodotBryo/Servers/SaveServer/README.md`); it is the contract between the
  layers, and changes to it bump the version with a migration.

### Fields and values

- A resource's saved fields are its script's properties with `PROPERTY_USAGE_STORAGE`
  (`get_script().get_script_property_list()`), the rule `ResourceSaver` uses. Engine properties
  (`resource_name`, `script`) are not script properties and are left out. `instance_id` and
  `base_form_id` are the entry's key and are not repeated in it.
- A value is written by its type:
  - an `EsmBase` as its FormID, an `EsmReference` as its instance_id, null as null;
  - any other Resource (`Inventory`, `InventoryItem`, `ActorValues`, `ScriptInstance`,
    `QuestState`) as a Dictionary of its own storage fields, by the same rule;
  - an int named `*_form_id` as `<file>:<local id>`, a `Vector3` as `[x, y, z]`;
  - a Dictionary with string keys, read back as its typed key and value types (`ActorValues`
    keyed by actor value name; a number in an untyped slot, a script local, as a float, as the
    interpreter uses it);
  - anything else as itself.
- On load the property's declared class decides how a value is read back: a FormID resolves
  through `EsmServer.get_base()`, an instance_id through `get_reference()`, a Dictionary into a
  new instance of the declared Resource class.
- `current_cell_form_id` is derived from space and position and loses `STORAGE`.
- Ids name the file a record comes from, not its load-order position, so saves survive a change
  of load order (DLC now, mods after the base game is complete). A record's file is the master
  its FormID's top byte names in that file's own master list; its local id is the lower three
  bytes. An override in a later file keeps the file that defined the record.
  - A base is already `esm://<file>/<type>/<local id>` (`EsmBase.source_uri`, its
    `resource_path`).
  - A reference's instance_id becomes `<file>:<local id>` for an authored placement
    (`FalloutNV.esm:00104C0C`, replacing `authored:%08X`), and `runtime:<file>:<local id>:<n>`
    for a runtime one. The save writes FormIDs the same way.
  - `instance_id` is a `StringName`: interned, so comparing two is a pointer comparison and a
    Dictionary keyed by them does not rehash the text.
  - The load-order FormID stays in memory as the fast key (the filing index, `EsmReader`,
    `base_form_id`), resolved from the id when a reference is built; it is never saved.
- File-relative ids keep a save's records resolving under another load order, not its game:
  where two files override one record, the later one wins, so reordering them changes the
  bases a save's references use. A load order that differs from the header's loads with a
  warning, as a changed master does; changing it mid-playthrough is unsupported.

### Links

- Ids resolve through `get_base()` and `get_reference()`, so every link to one object resolves
  to the one cached instance.
- A reference enters the cache before its saved fields are applied, so references that link to
  each other resolve without building twice.
- `Inventory`, `ActorValues`, `ScriptInstance` and `QuestState` have one owner and are written
  inline. A type that becomes shared gets an id and its own section.

### Runtime references

- A reference with no ESM record is `runtime:<base file>:<base local id>:<number>`, numbered
  from one counter in EsmServer and kept for the playthrough. EsmServer's table holds every
  runtime reference; `get_reference()` resolves `runtime:` only from it and returns null otherwise. A runtime
  reference leaves the table when it is used up (an item consumed or removed from the last
  inventory holding it) or deleted (`MarkForDelete`), and is not saved after that. The counter
  never goes back, so a released number is never reused and a stale id resolves to null, as a
  script local holding a removed reference does.

### Inventories

- An entry is a stack (base FormID and count) or one reference. Authored CNTO and LVLO entries
  are stacks; when an entry becomes a reference is open.

### Dirty

- Dirty is marked where a value changes, not by callers: the saved fields' setters, and
  `Inventory`, `ActorValues` and `ScriptInstance` on change. EsmServer clears it when it finishes
  building a reference.
- Saved references: every dirty reference in the cache, every runtime reference, and every
  entry of the loaded save that this session has not built. A clean reference is rebuilt from
  the ESM on load.
- Every list a server saves is bounded by the records it is about (quests, INFOs, actors), never
  by how long the game has run. `DialogueServer._said` is checked against this at step 4: it
  keeps only what a condition can read.

### Controller state

- A saved actor loads as the simulation holds it: `simulation_mode` LOW_LEVEL, with no controller.
  The fields its controller sets every frame (`simulation_mode`, `is_moving`, `is_running`,
  `is_sneaking`) lose `STORAGE`; the controller sets them again when the actor is leased.
- Furniture: `using` and `using_marker` are plain `var`, so a seated actor would load with a
  `sit_state` of 3 and no furniture. `using` is saved as the furniture's instance_id and
  `using_marker` with it, and loading seats the actor again through `FurnitureSeating`; the
  furniture's `occupants` is rebuilt from them. Census at step 3: every other plain `var` on a
  reference that a saved field depends on.
- `base:<FormID>` references (`create_reference_for_base`) are throwaway builds for previews and
  hydration, not world state, and are never saved; the player is `player`. Step 2 checks no saved
  field links to one.

### Loading from an open game

- No process restart: it would throw away the caches that make a second load fast. Each part
  is one of four kinds:
  - **Cache servers keep everything.** ArchiveServer, TextureServer, NifServer (and its KF disk
    cache), MeshServer, MaterialServer, FaceGenServer, and the terrain's texture pool and region
    data hold only what is derived from game files, never game state. Their warm caches are why
    a second load is fast.
  - **EsmServer keeps what it read from the ESM** (the reader, the record and placement indices,
    clean bases) and discards its game state: the reference caches, `_relocated`, the runtime
    table and counter, the player's reference. A dirty base is read from the ESM again before the
    save's version is applied.
  - **State servers that come back up quickly are torn down and started again** rather than
    given reset code: QuestServer, ScriptServer, DialogueServer, NpcSimulationServer (its navmesh
    stays with LocalNavigation if that is the slow part; measured at step 7), time and weather.
  - **The game scene stays.** Its streamers unload the world they hold and stream the saved
    location in, as a `coc` does; TerrainStreamer and Terrain3D keep their caches.
- Then the load order above runs as from the launcher.

### Progress

- SaveServer emits `progress(stage: String, detail: String, done: int, total: int)` through a save
  and a load, with what it is working on by name, not a bare fraction:
  - reading: each file (`esm_server/references/GoodspringsWorld.json`);
  - applying: each owner and its count (`QuestServer: 412 quests`), each moved reference built
    (`Moved items: 14 of 37, WeapNV9mmPistol`);
  - seeding: `NpcSimulationServer.seed_progress`, forwarded with the actor's editor ID;
  - placing and streaming: the destination cell, `CellStreamerV2.load_progress`, and
    TerrainStreamer's ready status, forwarded until the transition releases the player.
  - saving: each owner, then each file written.
- Loading and saving run in steps across frames (a batch of references per frame), so the
  loading screen redraws between them; nothing is applied in one blocking call.
- The transition screen (`TransitionCoordinator`'s overlay) shows the stage, the detail and a bar
  while a load runs; a save shows its progress only when it outlasts a short delay.
- Every load writes a load report beside the saves (`user://saves/last_load.txt`): each stage's
  time, counts, warnings, and the entries dropped by the master check. It is what a bug report
  attaches.

### Saving

- Each owner has `save_state() -> Dictionary`. Saving runs on the main thread between frames,
  while nothing streams. It is refused during a conversation, a transition (the possessed
  actor's space loading) and while a move waits in `ScriptServer._pending_moves`.

### Loading

- A save loads into a session where the ESM has loaded and no game has started: from the
  launcher, or after a restart from an open game (Open).
- `game.gd` starts a game in one of two ways. A new game runs `QuestServer.begin_game()`,
  `NpcSimulationServer.seed()` and the startup script (PR #88; before it, the VCG01 setup in
  `game.gd`). A loaded game runs the steps below and neither `begin_game()` nor the startup
  script.
- Order:
  1. Read the header. Refuse the save if its format version is newer or a master it names is
     missing. A master whose size or time differs only warns; entries whose record or reference
     no longer resolves are dropped and listed in the load report.
  2. EsmServer: dirty bases (the player's NPC_, whose ACBS level is the player's level), encounter
     zone levels, the runtime counter and table. The `references` section is held as an overlay.
  3. The player's reference is built, taking its overlay entry.
  4. QuestServer, ScriptServer, DialogueServer, time and weather load their sections.
  5. `NpcSimulationServer.seed()` builds the actors, each taking its overlay entry. A clean actor
     makes its leveled pick again with the player's and the zones' levels already restored.
  6. The player is placed at the header's space and position through `ScriptServer.move_reference`.
- Any reference built later (a cell loading, a script looking one up) takes its overlay entry
  when EsmServer builds it.
- An authored reference's instance_id is its REFR/ACHR/ACRE FormID and does not change when it
  moves; EsmServer records its current cell (`_relocated`) and lists it there. That record holds
  only built references, so loading builds every saved reference whose saved cell is not its
  filing cell, before streaming starts; otherwise its new cell would not list it until its filing
  cell loaded. Actors are built at seeding anyway; this covers moved items and objects (dropped,
  `MoveTo`). The `references/<space>.json` split is for editing; the loader does not depend on
  it.

## Build order

1. **Runtime ids, inventories and dirty.** Done (`4f0581a`). The runtime table and
   counter; `InventoryItem` as a stack or a reference, readers on the item's base; ESM-read
   reference fields without `STORAGE`; dirty marked at the setters and cleared after building.
   Checked by `tests/test_esm_server` (`_check_inventory_contract`, `_check_dirty_marking`).
2. **File-relative ids.** Done. Only EsmServer builds or parses an
   instance_id (`instance_id_for_form_id`, `form_id_for_instance_id`, `file_for_form_id`,
   `get_reference_by_form_id`, `load_order`); the code and tests that built `authored:%08X`
   ask it by FormID. `base:` and `runtime:` ids take the same form; `player` is unchanged.
   Diag scripts still build `authored:` ids and are left to break. Every test passes except
   `test_head_tracking` (2 failures, the same on `master`) and `test_script_corpus_survey`
   (no result within 300 s).
3. **Field writer and reader.** Done. `SaveFields`
   (`GodotBryo/Servers/SaveServer/save_fields.gd`); `_after_fields_read()` on `Inventory` and
   `InventoryItem`; `level_modifier`, `current_cell_form_id`, `simulation_mode`, `is_moving`,
   `is_running` and `is_sneaking` lose `STORAGE`, `using` and `using_marker` gain it;
   `ActorValues`' dictionaries, `QuestState.stages_done` and `ScriptInstance.locals` are typed.
   Plain `var` left on references: `texture_swaps` (loading a save reverts SwapTexture),
   `used_by` and `FurnitureReference.occupants` (rebuilt from actors' `using`). Checked by
   `tests/test_save_fields`. `Inventory.serialize_state()`/`restore_state()` are no longer
   the save's path; removed at step 4 once nothing calls them. Gate (met): Doc Mitchell, a
   container, a door, a runtime weapon and a QuestState, changed, written, sent through JSON
   text, read into a fresh instance and written again, match; the output holds no Object. Nothing
   in play makes a runtime reference yet; the test creates its weapon directly.
4. **Sections.** Done. EsmServer (`save_state`, `load_state`,
   `clear_game_state`, entries applied as each reference is built), QuestServer (states, clock,
   next runs, `_quest_objects`, active quest), ScriptServer (globals, clock, disabled controls)
   and DialogueServer (flagged lines said, talked to the player, added topics; `mark_said` now
   records only Say Once and Say Once a Day lines). A dirty base saves the fields
   `EsmBase.mark_changed()` recorded (`changed_fields`): the name menu, `set_female`, and an
   encounter zone's `resolved_level`. `Inventory.serialize_state`/`restore_state` removed.
   `JSON.parse_string` does not read a float's printed digits back exactly (writing with
   `full_precision` makes every float differ), so a float can change in its last digit across
   a save and a load; the tests compare saves value by value, floats within a relative 1e-9
   (`tests/save_compare.gd`). Measured (`tests/test_save_sections`, a new game, 10 s and 40 s
   of simulation at speed 50): 3,393 to 3,520 references, 312 quest states; 5.7 to 6.1 MB of
   indented JSON, 234 to 248 KB zstd; `save_state` 593 to 640 ms; parse and load 1.6 to 1.8 s
   (building every saved reference from the ESM). Actor inventories were 64% of the
   references' size, nearly all unchanged since built; `Inventory.changed_since_built`
   (cleared by EsmServer after filling, set on every change) leaves those out, and loading
   builds them again from the ESM. With it, after 10 s: 7 of 3,393 references carry an
   inventory; 3.3 MB, 196 KB zstd; `save_state` 593 ms; parse and load 1.1 s.
   `save_state()`/`load_state()` on EsmServer (with the overlay), QuestServer,
   ScriptServer and DialogueServer. EsmServer is not instanced again (that reloads the ESM): its
   test clears its reference caches and runtime table, loads the overlay, and builds the saved
   references again. Gate: a test runs the simulation and VCG01's first stages, saves, loads into
   new instances of the other servers and the cleared EsmServer, saves again, and both saves are
   equal. Measure
   size, save time and read time, after one Goodsprings save and after a long session (hours of
   simulated travel at high speed scale), against a target set from the first measurement.
5. **SaveServer and files.** Done. `GodotBryo/Servers/SaveServer/`:
   `save_server.gd` (save, read_save with the header check, apply_state, refusals: a
   conversation, a queued move, and `save_refusals` the game adds), `save_backend.gd`,
   `json_folder_backend.gd`, and `README.md` (the schema). Owners' `load_state()` take a
   `report` Array and list what they drop there. Autoloaded as `SaveServer`
   (`project.godot`). Checked by `tests/test_save_server` (folder layout, read back equal,
   applied and built again equal, a changed master warns, a missing master refuses, two saves
   around a quest stage differ only in `quest_server.json` and `header.json`, refused while a
   move is queued). SaveServer, the `SaveBackend` interface, the schema README, and the
   JSON folder backend: write a save folder, rename it into place, read it back; the header and
   its master check. Gate: a save naming a missing master is refused; one from a changed master loads with a
   warning and a report of dropped entries; two saves a minute apart in one cell differ only in
   the files that changed.
6. **Load in game.** The launcher's Load, the load order above, time and weather; progress
   across frames, the transition screen's stage and detail, the load report. A save can be
   anywhere, so the game must boot into an exterior, which no start has done: every start so
   far is Doc Mitchell's house, and exteriors are reached only from an interior. First, a boot
   straight into a worldspace (the startup script moving the player to Goodsprings, PR #88):
   WorldStreamerV2 activating with no earlier space, TerrainStreamer's first ready wait, and
   `game.gd`'s exterior environment, weather and sky; a test for it beside `test_transitions`.
   Gate: save inside Doc Mitchell's house and outside in Goodsprings, quit, load each from the launcher; the
   player, Doc Mitchell's quest stage, Sunny's position and package, an opened container's
   contents, the time and the weather are as saved, and the exterior load has its terrain,
   distant objects and sky.
7. **Quick save and quick load keys**, and the launcher's list of saves. Quick load is loading
   from an open game (above). Census first: each server's state, what it caches, and how long it
   takes to start; measure NpcSimulationServer's navmesh load separately. Gate: quick load twice
   in Goodsprings; the second load reuses NifServer's trees and textures (its stats show no new
   parses) and the world matches the save.
8. **Git storage.** A second backend, offered where git is installed: commit per save, branch on
   saving from an earlier save. The save browser's branch view and remotes come after.

## Open

- When an inventory entry becomes a reference, by item type or by use: COED entries, and whether
  one with a count above 1 is that many references; damage, mods, dropping. Ammo belongs here
  too (a fired round leaves a casing). Not a save and load question; an inventory plan of its
  own. Until then authored entries stay stacks and only references the player moves in are
  references.
- Cell reset and cleanup of dropped items and bodies are gameplay, not save and load, and come
  later: when a cell's changes are discarded, when runtime references left in it are released,
  when placed actors choose from their leveled list again, and when encounter zones without Never
  Resets fix their level again (`templated_npcs.md`). They are what bounds save growth from
  play; the save only stops storing what they discard.
- `ScriptServer._pending_moves`: none can be waiting when a save is made (Saving), so none is
  saved; whether that refusal is ever noticeable in play.
- A `.fos` backend: writing one is partial (perks, stats, map markers, Havok state and the
  change-form flag bits are not modelled or not documented; `enginedocs/nv_save_architecture.html`
  rates the layouts low confidence) and needs a fixed load order; reading a real New Vegas save
  is a project of its own. Neither changes the interface.
- Possible optimisation, in case moved non-actor references reach the tens of thousands and the
  eager build at load costs too much time or memory: key `_relocated`/`_relocated_by_cell` by
  instance_id instead of EsmReference, fill them from the save without building, and let
  `get_references_in_cell()` build each one through `get_reference()` when its cell loads.
