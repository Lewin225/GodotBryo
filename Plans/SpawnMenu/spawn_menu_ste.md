# Spawn menu (Simplified Technical English version)

This file has the same content as `spawn_menu.md`. It follows the word rules of ASD-STE100.
Each sentence has one idea. Instructions have 20 words or fewer. Descriptions have 25 words or fewer.
Code names stay as they are in the code.

The spawn menu is a Debug Tools tab. It lets the user find a Base record and spawn it.
The layout follows the spawn menu of Garry's Mod:

- Category tabs are along the top.
- A tree is on the left.
- A large grid of thumbnails fills the rest.
- A search box is above the grid.

## Status

Steps 1, 2 and 3 are done. Step 5 is done for records with an ICON. Step 6 is done for models; actors are step 9 (2026-11-09). `tests/test_spawn_menu.tscn` and `tests/test_debug_tabs.tscn` pass.
The census below was run on 2026-11-09. It used FalloutNV.esm only. This is the one plugin that the game loads.
See `spawn_menu.md` for the details of steps 1, 2 and 3.

## Goal

1. The user opens Debug Tools with the Home key and selects the Spawn tab.
2. The user browses or searches.
3. The user clicks a thumbnail.

The result of the click depends on the record type:

- An object or an actor appears at the crosshair. It faces the player.
- An item goes into the player inventory.

The tab also has these functions:

- Undo removes the newest spawn of this session. Clear removes all of them.
- A thumbnail is the inventory icon of the item when the item has one. Otherwise it is a render of the world model.
- The program saves each render to disk. Each render is made one time only.
- The placement code also makes the console command `PlaceAtMe` work. This command is a stub now.

The tab does not include these items:

- a tool gun
- a physics gun
- dupes
- saved layouts
- gizmos for the transform of a placed reference

Each of these is a separate task. It can start after spawning works.

## Starting state

These parts exist now. They were checked in the code on 2026-11-09.

**Record index.**
- `EsmServer.get_record_index()` gives one row for each record.
- A row has `form_id`, `record_type`, `editor_id` and `full_name`.
- There are 465017 rows. 70872 rows have an EditorID.
- `ConsoleCompleter` builds an EditorID index from these rows in about 276 ms.

**Spawn of a reference.**
- `EsmServer.create_runtime_reference(base_form_id)` makes a `runtime:` reference.
- The new reference has no place. The runtime table holds it. Saves include it.
- `EsmReference.set_location(space, position)` puts the reference in the world. It sends the signal `reference_cell_changed`.
- `CellStreamerV2` and `WorldStreamerV2` receive this signal. `CellStreamerV2` then builds the node in the current cell.
- `ActorReference.drop_entry()` already uses this path to drop items. The path is proven for items.

**Coordinates.**
- A reference position is in meters on the Z-up axes of Gamebryo. The native parser converts the units.
- `EsmReferencePhysicaliser.authored_position(godot_position)` converts a Godot position.
- `EsmReferencePhysicaliser.authored_heading(godot_yaw)` converts a Godot yaw.
- Use these two functions. Do not add a second conversion. Issue #56 shows why: a second conversion gave a wrong distance.

**PlaceAtMe.**
- The registry calls `place_at_me_handler`. This is `debug_place_at_me()` in `game.gd`.
- This function only prints a warning and returns 0.

**Leveled lists.**
- `LeveledItemResolver` and `LeveledActorResolver` are in `GodotBryo/Pipeline/`.
- The editor browser uses the first one to preview LVLI results.

**Editor browser.**
- `addons/godotbryo_browser/` is a dock for the editor only.
- It has a TabBar of 30 record types and a grid of cards. The grid adds cards in batches of 4 ms for each frame.
- It makes display names. It uses the FULL name, then the humanized EditorID, then the FormID.
- It can drag a record into a scene. It uses `create_reference_for_base` and the physicaliser.
- It has no thumbnails.
- It is the closest part to this tab.

**Textures.**
- `TextureServer.request(tex_path)` is a coroutine. It decodes a DDS file and uploads it. It caches the result.
- Inventory icons are DDS files in `textures/`.

**Debug Tools.**
- Debug Tools is a `Control` that has a `TabContainer`.
- When it opens, it calls `ScriptServer.enter_menu(MENU_CONSOLE)`. This frees the mouse. The player camera stays in its position.
- Each tab is authored in the scene. Its script does only `@onready` lookups. This rule is in AGENTS.md.

**OBND.**
- Only `actor_base.gd` reads OBND.
- No placeable Base has bounds. Placement therefore measures the built node. This is step 4.

## Census

The script `project/_diag/diag_spawn_menu_census.gd` ran the census. It runs without a window:

`godot --headless --path . -s _diag/diag_spawn_menu_census.gd`

For each record, the script reads the raw subrecords. It counts these items:

- records with a FULL name
- records with a world model (MODL, or MOD2 for ARMO), and models that are in the archives
- records with an ICON, and icons that are in the archives
- records with an OBND that is not zero
- the first folder under `meshes/` for each model

The numbers in brackets are the items that are in the archives.

| Type | Records | FULL | Model (in BSA) | ICON (in BSA) | OBND not 0 | Top model folders |
|---|---|---|---|---|---|---|
| STAT | 6785 | 0 | 6780 (6775) | 0 | 6117 | dungeons 2581, architecture 1502, clutter 1198, landscape 388, weapons 259 (27 folders) |
| NPC_ | 3816 | 3399 | 3808 (3808) | 0 | 1819 | characters 3170, (root) 638 |
| LVLI | 2738 | 0 | 0 | 0 | 0 | none |
| CONT | 2478 | 2430 | 2478 (2478) | 0 | 2086 | clutter 1969, furniture 247, dungeons 177 |
| CREA | 1578 | 1159 | 1093 (1093) | 0 | 701 | creatures 1048, (root) 33 |
| ACTI | 1143 | 722 | 429 (429) | 0 | 1124 | clutter 163, architecture 125, dungeons 46 |
| NOTE | 894 | 733 | 282 (282) | 348 (348) | 98 | clutter 282 |
| MISC | 507 | 502 | 461 (461) | 489 (489) | 337 | clutter 399, weapons 29 |
| LIGH | 501 | 0 | 29 (29) | 0 | 448 | clutter 15 |
| FLST | 464 | 0 | 0 | 0 | 0 | none |
| ARMO | 389 | 384 | 345 (345) | 372 (368) | 214 | armor 331 |
| LVLN | 365 | 0 | 0 | 0 | 0 | none |
| TERM | 344 | 322 | 312 (312) | 0 | 274 | terminals 291 |
| LVLC | 343 | 0 | 0 | 0 | 0 | none |
| DOOR | 320 | 312 | 320 (318) | 0 | 297 | dungeons 185, architecture 88 |
| KEYM | 283 | 283 | 264 (264) | 283 (283) | 160 | clutter 261 |
| CCRD | 270 | 270 | 270 (270) | 270 (270) | 0 | clutter 270 |
| WEAP | 261 | 251 | 207 (207) | 200 (200) | 100 | weapons 190 |
| MSTT | 241 | 16 | 241 (240) | 0 | 227 | clutter 106, effects 71, vehicles 35 |
| FURN | 234 | 190 | 234 (233) | 0 | 223 | furniture 202 |
| IDLM | 211 | 0 | 0 | 0 | 200 | none |
| ALCH | 189 | 189 | 189 (189) | 189 (189) | 140 | clutter 176 |
| SCOL | 98 | 0 | 98 (88) | 0 | 98 | scol 98 |
| AMMO | 92 | 92 | 91 (91) | 92 (92) | 40 | ammo 45, weapons 31 |
| TACT | 87 | 75 | 85 (85) | 0 | 83 | clutter 33, terminals 25 |
| IMOD | 50 | 50 | 50 (50) | 50 (50) | 13 | weapons 50 |
| BOOK | 27 | 20 | 26 (26) | 17 (17) | 26 | clutter 26 |
| GRAS | 24 | 0 | 24 (24) | 0 | 9 | landscape 24 |
| CMNY | 6 | 6 | 6 (6) | 6 (6) | 0 | clutter 6 |
| CHIP | 5 | 5 | 5 (5) | 5 (5) | 1 | clutter 5 |
| TREE | 3 | 0 | 3 (0) | 3 (0) | 3 | none |

The census shows these facts.

**Only inventory items have icons.**
- ALCH, AMMO, KEYM, CCRD, CMNY, CHIP and IMOD have an ICON on every record. All icons are in the archives.
- ARMO has 368 icons for 389 records. MISC has 489 for 507. WEAP has 200 for 261. Most WEAP records without an icon have no model.
- No world object and no actor has an ICON.
- The icon is therefore the first source of thumbnails for items.
- A model render is the source for all other records. It is also the fallback for an item without an icon.

**OBND cannot frame a thumbnail or place a spawn.**
- OBND is zero on 161 of 261 WEAP records, on all 270 CCRD records and on 175 of 389 ARMO records.
- The 9mm pistol (0x000E3778) is one of the records with a zero OBND.
- Framing and placement use the AABB of the built node.

**The MODL of an NPC_ is not a picture of the NPC.**
- 3170 models are in `characters/`. These are shared skeletons. 638 models are at the root.
- A render of this model shows a skeleton or nothing.
- A thumbnail of an NPC needs the complete actor: race body parts, head and FaceGen. This is expensive, so it is step 9.

**Model folders give a good tree.**
- STAT models are in 27 top folders.
- Weapons are in `weapons/<kind>/`. Armor is in `armor/<set>/`. Creatures are in `creatures/<kind>/`.
- NPC_ is the exception. The tree groups NPC_ records by race.

**Some types are not spawnable from this tab.**
- The tab does not show IDLM, GRAS and FLST. It does not show TREE, because the 3 TREE models are not in the archives.
- SCOL is spawnable. 10 of its 98 models are missing. The tab shows a warning for a missing model.
- A few DOOR, FURN, MSTT and STAT records also have a missing model. The tab shows a warning for these.
- LVLI, LVLN and LVLC have no model. The program resolves them first (see Decisions).

## Decisions

### Layout

```
┌ Spawn ─────────────────────────────────────────────────────────────────┐
│ [Items] [Actors] [Objects] [Interactive] [Leveled] [★ Favourites]      │
├──────────────┬─────────────────────────────────────────────────────────┤
│ ▾ WEAP (261) │ [search name, EditorID, FormID...]   size ▭▭▭  [Undo]   │
│   ▸ 1handpis │ ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐        │
│   ▸ 2handrif │ │ 🖼 │ │ 🖼 │ │ 🖼 │ │ 🖼 │ │ 🖼 │ │ 🖼 │ │ 🖼 │        │
│ ▸ ARMO (389) │ └────┘ └────┘ └────┘ └────┘ └────┘ └────┘ └────┘        │
│ ▸ AMMO (92)  │ 9mm Pist  .357 Rev  Varmint   ...                       │
│ ▸ ALCH (189) │                                                         │
│ ...          │                                                         │
├──────────────┴─────────────────────────────────────────────────────────┤
│ 9mm Pistol · WeapNV9mmPistol · WEAP 0x000E3778 · weapons/1handpistol/… │
│ Left click: add to inventory   Shift+click: place   Count [1]          │
└────────────────────────────────────────────────────────────────────────┘
```

**Top tabs.**
- The top tabs are groups of categories. The record type is the first level of the tree.
- One tab for each type gives about 25 tabs. The editor browser has 30 tabs, and they overflow.
- Groups keep the tab bar short. The tree still shows the record type, so nothing is hidden.
- The groups are one table, `SpawnCatalog.CATEGORIES`. To use one tab for each type, change this table.

| Tab | Types | Default click |
|---|---|---|
| Items | WEAP, ARMO, AMMO, ALCH, MISC, KEYM, BOOK, NOTE, CCRD, CMNY, CHIP, IMOD | add to inventory |
| Actors | NPC_, CREA | place |
| Objects | STAT, MSTT, SCOL | place |
| Interactive | ACTI, TACT, CONT, DOOR, FURN, TERM, LIGH | place |
| Leveled | LVLI, LVLN, LVLC | resolve, then add (LVLI) or place (LVLN, LVLC) |
| Favourites | all starred records and a Recent node | as for the record |

**Tree.**
- Each type has a function that groups its records. These are the groupings:
  - **Default:** the model path without `meshes/` and without the file name, split on `/`. An example is `dungeons/vault/roomkit`.
  - **NPC_:** by race (`NpcBase.race`). Then by the first faction, when the record has one.
  - **Leveled lists:** by the prefix of the EditorID. They have no model.
  - **Records without a model:** in a node named `(no model)`. No record disappears.
- Each node shows a count. A node shows all records below it.
- An `All` node is at the top of each type.

**Grid.**
- The grid is an `ItemList` in icon mode. The settings are:
  - `ICON_MODE_TOP`
  - `max_columns = 0`
  - `fixed_icon_size` from the size slider (64, 96 or 128)
  - `same_column_width`
- `ItemList` draws only the visible rows. It handles 6785 STAT records without one Control for each card.
- The editor browser uses a PanelContainer for each card. This is why it builds the grid in batches.
- The visible range comes from the scrollbar value, the icon size and the number of columns. This range selects the thumbnails to request.
- Until a thumbnail arrives, the grid shows a glyph for the type.

**Search.**
- The search matches the display name, the EditorID and the FormID. The FormID can be hex, with or without `0x`. The console uses the same rule.
- The search covers the current tab.
- When the search box has text, the tree shows only the matching nodes.

**Info bar.**
- The info bar shows the record under the mouse or the selected record.
- It shows the name, the EditorID, the type, the FormID and the model path.
- For an item, it also shows the value and the weight from the Base.

**Scene.**
- The tab is a separate scene: `spawn_menu/spawn_menu_tab.tscn`. `game.tscn` has an instance of it in the TabContainer, as for the console.
- The nodes are authored in the scene. They are not built from code. This follows AGENTS.md.
- This keeps `game.tscn` small.

### Clicks

- **Left click** does the default action of the tab. Items go into the inventory. All other records are placed.
- **Shift and left click** does the other action when it is possible. It places an item in the world. A container can only be placed.
- **Right click** opens a menu with these entries:
  - Place at crosshair
  - Add to inventory (items only)
  - Favourite or Unfavourite
  - Copy EditorID
  - Copy console command, for example `player.PlaceAtMe WeapNV9mmPistol 1` or `player.AddItem ...`
  - Inspect in Script Engine, when the Base has a script
  - Open in console. This fills the console line but does not run it, like the +Caps button.
- **The count spinbox** in the footer applies to AddItem and to placement.
- For more than one placed object, the spread follows `drop_entry`. It uses `DROP_SPACING` across the facing direction.

### Placement

`SpawnPlacer` (`spawn_menu/spawn_placer.gd`) is the one owner of placement.
The tab and `PlaceAtMe` both use it. `debug_place_at_me()` in `game.gd` calls it.
This also agrees with `Plans/GameGd/game_gd_decomposition.md`, because `game.gd` gets less code.

**Ray.**
- The ray starts at the center of the active camera (`get_viewport().get_camera_3d()`). It goes along the forward axis of the camera.
- The ray does not use the cursor. Debug Tools frees the mouse, but the player camera stays in its position. GMod works in the same way.
- The range is 20 m. This value can change. The ray ignores the body of the player.
- If the ray hits nothing, the spawn is 2 m ahead of the player, at the height of the feet.

**Position.**
- Use `EsmReferencePhysicaliser.authored_position(hit_point)`. Do not add other conversions.

**Heading.**
- The spawn faces the player. The heading is `authored_heading(camera_yaw + PI)`.

**Space.**
- Use `current_space_form_id` of the possessed reference.
- `set_location()` finds the cell. The streamers then build the node.

**Rest on the surface.**
1. Wait until the node exists. Use `EsmNode.node_for(reference)`.
2. Measure the merged AABB of its visual instances in reference space.
3. Raise the reference until the bottom of the AABB is at the hit point.

The first frame can show the object partly below the surface. The correction runs one time.
OBND would remove this step. No placeable Base reads OBND, and the census shows that it is often zero.

**Leveled lists.**
- For LVLN and LVLC, `LeveledActorResolver` selects a Base at the player level. The program places that Base.
- For LVLI, `LeveledItemResolver` selects items. The program adds each item.
- The info bar shows what the resolver selected.

**Saves.**
- The program places a `runtime:` reference. Saves include it.
- This is intended. Spawned objects persist like dropped items.

### Undo

- `SpawnPlacer` keeps the runtime references of this session in order.
- **Undo** (the button, or Ctrl+Z when the tab has focus) removes the newest one.
  1. `set_location(0, Vector3.ZERO)` removes it from the world.
  2. `release_runtime_reference()` removes it from the runtime table. Saves then do not include it.
- **Clear spawned** removes all of them.
- To undo an item that went into the inventory, remove the same count from the inventory.
- If a spawn has left the world, Undo skips it and forgets it. This happens when the player picks it up or when it moves into a container.

### Thumbnails

`ThumbnailCache` (`spawn_menu/thumbnail_cache.gd`) answers `request(form_id, size) -> Texture2D`. The call can be awaited.
It uses three sources in this order.

1. **Memory.** An `ImageTexture` for each `(form_id, size)`. An LRU limit of about 2000 entries applies.
2. **Disk.** The path is `user://thumbnails/<generator version>/<FormID hex>_<size>.png`.
   - The cache key includes a hash of the source path (ICON or model). If the model or icon of a record changes, the cache misses. The tab does not show an old picture.
   - The files come from the game data of the user. They are in `user://`. They are never in the repository.
3. **Generate.**
   - **Inventory icon.** `TextureServer.request("textures/" + icon)` gives the texture. The program scales it to the size of the cell. This needs no render. It covers almost all entries of the Items tab.
   - **Model render.** `ThumbnailRenderer` (`spawn_menu/thumbnail_renderer.tscn`) has these parts:
     - a `SubViewport` with `own_world_3d = true`, `transparent_bg = true`, a size of 128 or 256, and `UPDATE_DISABLED` between jobs
     - a `Camera3D`
     - a key light and a fill light (`DirectionalLight3D`)
     - a neutral `WorldEnvironment`

     It renders one model for each job:
     1. `NifServer.request(model_path, …)` builds the model.
     2. Put the model under a pivot. Turn the pivot to a three-quarter view (yaw −35°, pitch −20°).
     3. Frame the model from the merged AABB. The distance is radius / sin(fov/2).
     4. Wait until the textures of the model are resident. See Open.
     5. Set `UPDATE_ONCE`. Await `RenderingServer.frame_post_draw`.
     6. Read the image with `get_texture().get_image()`. Then free the model.
   - **Actor render (step 9).** Make a synthetic reference with `create_reference_for_base`. Physicalise it in the own world of the renderer. The editor browser does the same for Open As Scene.

**Scheduling.**
- The program requests only the records in the visible range and one screen ahead.
- Requests are LIFO. When the user scrolls fast, old off-screen work does not block the work on screen.
- A scroll or a tab change drops the queued jobs that have not started.
- Only one render job runs at a time. Only one readback runs in each frame. `get_texture().get_image()` stalls the GPU.
- Icon decodes use the worker limit of TextureServer.

**Records with no model and no icon.**
- These records keep the glyph of the type. They are the leveled lists, LIGH without a model, and ACTI without a model.
- Later, a leveled list can show the thumbnail of its first resolved entry.

### Shared catalogue

`SpawnCatalog` (`spawn_menu/spawn_catalog.gd`) holds plain data. It has no nodes, so a test can run it without a window.

- It builds the rows of each type from the record index. A row has the display name, EditorID, FormID, model path and icon path.
- It also builds the tree and the category table, and it filters rows.
- Display names follow the rule of the editor browser: the FULL name, unless it repeats the type. Then the humanized EditorID. Then the FormID.
- This rule moves into `SpawnCatalog` as a static function. The browser can call it later. A change to the browser is not part of this work.
- The index row has names only. The model and icon paths need the raw record.
- The program builds the rows of a type when the user opens its tab for the first time.
- Measure this first build. If a type takes more than about 100 ms, build it in a WorkerThreadPool task. The task uses its own `EsmReader`. `EsmReader` is not thread-safe, so each thread needs its own.
- While the build runs, the tab shows "Indexing STAT…".
- If the worker build is still too slow, add a native function `get_record_paths(type)`.

### Favourites and settings

The file `user://spawn_menu.cfg` holds:

- the favourite FormIDs. They are stored as `<file>:<local id>`, as in save identities. A change of the load order does not mix them.
- the last 30 spawned records (Recent)
- the icon size
- the last tab and the last tree node

## Build order

Each step ends with checks in `tests/test_spawn_menu.tscn`. The checks run without a window against the real ESM.
A step that needs a window says so.

1. **SpawnCatalog.**
   - Build the rows of each type from the record index and the raw MODL, MOD2 and ICON.
   - Add the category table, the model-folder tree, the NPC_ race tree, the `(no model)` node, the display names and the filter.
   - Checks:
     - The row counts match the census table.
     - The 9mm pistol is under `WEAP/weapons/1handpistol` and has its ICON.
     - The searches `000e3778`, `0xE3778` and `9mm` all find it.
     - IDLM, GRAS, FLST and TREE are absent.
   - Time the first build of each type.
2. **SpawnPlacer and PlaceAtMe.**
   - Add the ray, the placement, the heading, the count spread, the list of spawns of the session, Undo and Clear.
   - `debug_place_at_me()` calls `SpawnPlacer`.
   - Checks in the house of Doc Mitchell:
     - `player.PlaceAtMe` for a MISC and for a STAT makes a `runtime:` reference in the cell of the player.
     - The node appears through `CellStreamerV2`.
     - Undo frees the node and removes the reference from the runtime table of `EsmServer`.
   - Also check the removal with space 0. `world_items.md` says `_refresh_cell()` returns early for space 0. The comment of `set_holder()` says the streamers free the node. One of these is wrong.
   - If the arguments of `PlaceAtMe` change, update `SIGNATURES` in the console.
3. **The tab, without thumbnails.**
   - Add the scene, the top tabs, the tree, the `ItemList` grid with glyphs, the search, the info bar, the three click types, the count spinbox, Undo and Clear.
   - Add an instance to `game.tscn`.
   - Checks:
     - A change of the tab or of the tree node fills the grid with the records of the catalogue.
     - A simulated click on an Items record adds it to the inventory of the player.
     - A simulated click on a STAT places it.
   - Extend `test_debug_tabs` for the new layout.
4. **Rest on the surface.** Add the AABB correction. Check that the bottom of the AABB of a placed crate is within 1 cm of the hit point.
5. **ThumbnailCache with icon thumbnails.**
   - Add the memory cache, the disk cache, the icons from TextureServer, and the scheduling of the visible range.
   - Checks:
     - A request for the 9mm pistol gives a texture of the requested size.
     - A second run loads from `user://thumbnails`.
     - A scroll drops the queued jobs.
6. **ThumbnailRenderer for models.**
   - Checks in a run with a window. The headless renderer draws nothing. A STAT, a CONT and a WEAP without an icon must each give an image that is not empty and not one color.
   - Headless tests cover only the queue and the cache. They use a stub for the renderer.
   - Look at the images by hand for dark or untextured renders. See Open.
7. **Leveled lists.** LVLN and LVLC place a resolved actor. LVLI adds its resolved items. Both use the player level. The info bar names the result.
8. **Favourites and Recent.** Save them in `spawn_menu.cfg`. Check that they remain after a restart of the scene.
9. **Actor thumbnails.**
   - Physicalise synthetic NPC_ and CREA references in the world of the renderer.
   - First check that a node in this world does not register with NpcSimulationServer or ScriptServer. See Open.
   - Until then, NPC_ uses the glyph of the type. CREA uses a model render. This works because a CREA model is the model of the creature (`creatures/`).
10. **AGENTS.md.** Add the tab to the list of Debug Tools. Name `SpawnPlacer` as the owner of PlaceAtMe.

## Open

These questions have no answer yet. Each one is checked at the step shown.

- **Texture readiness for renders (before step 6).**
  - Does the NIF from NifServer have all its textures when `request()` completes? Or are some textures still in TextureServer?
  - If textures are still loading, the renderer must wait for them. If it does not wait, the cache keeps grey models.
  - Answered at step 6: yes. NifServer awaits `resolve_textures()` before it builds the tree.
- **Side effects of an actor in the thumbnail world (before step 9).**
  - An actor node can give itself to NpcSimulationServer. It can start head tracking or register with ScriptServer.
  - The thumbnail world must not do any of these. A "preview" flag on the physicaliser can be necessary.
- **Statics placed at runtime (step 2).**
  - Most placed STAT references become `DirectGeometryBatch` geometry and not nodes.
  - Check that `_on_reference_arrived` makes a node for a runtime STAT. Check that the collision exists and that Undo frees it.
  - Do the same check for SCOL. SCOL parts use `physicalise_scol_part`.
- **Exterior spawns (after step 2).**
  - The step 2 checks run in an interior.
  - In an exterior, check that `WorldStreamerV2` finds the new reference in the tile of the player.
  - Also check that the reference remains after the tile is unloaded and loaded again.
- **Item physics.**
  - Items in the world are static props on master. Whether they fall and rest depends on the world-items branch (`Plans/WorldItems/world_items.md`). This tab does not decide it.
- **Spawned actors do nothing.**
  - Every actor is inert in the current phase. A placed NPC_ stands still.
  - Check that a runtime NPC_ with no placed package context does not cause a crash in NpcSimulationServer.
- **A key to open the tab.**
  - The spawn menu of GMod opens while the user holds the Q key. The hold-to-run console shows that this pattern works here.
  - A later step can put the scene of this tab in its own overlay with a hold key, in addition to Debug Tools.
