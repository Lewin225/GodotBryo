# Spawn menu

A Debug Tools tab for browsing placeable Base records and spawning them where the player is
looking, or into the player's inventory. Layout after Garry's Mod's spawn menu:

- category tabs along the top;
- a tree down the left;
- a large grid of thumbnails filling the rest;
- a search box over the grid.

## Status

Steps 1–3 done, step 5 for ICON records, step 6 for model renders (2026-11-09); `tests/test_spawn_menu.tscn` and `tests/test_debug_tabs.tscn` pass. The census below was run on
2026-11-09 against FalloutNV.esm only, the one plugin the game loads.

- **Step 1.** `spawn_menu/spawn_catalog.gd`. Row counts, models, models in BSA and icons match the
  census for all 27 types. First builds measured: NPC_ ~215 ms, STAT ~180 ms, LVLI ~110 ms, the
  rest under 75 ms. The three over 100 ms still need the worker build (step 3). `humanize()` was
  rewritten on char codes (135 → 53 ms for STAT). It is identical to the browser's for all 70872
  EditorIDs.
- **Step 2.** `spawn_menu/spawn_placer.gd`, a `SpawnPlacer` node in `game.tscn`. It is
  `place_at_me_handler`; `debug_place_at_me()` is gone. PlaceAtMe places at the *calling
  reference* (its documented meaning, which quest scripts rely on), with optional Distance/Direction
  (GECK-wiki directions, not checked against the engine); the crosshair is the tab's. Leveled lists
  are resolved at placement (LVLN/LVLC have no reference type). Items start
  `ActorReference.DROP_HEIGHT` above the target (and `DROP_DISTANCE` ahead of an actor PlaceAtMe'd
  at), as `drop_entry()` does: placed at the player's feet they started inside the floor and fell
  out of the world when a pick-up woke them (found in play, 2026-11-09; checked by the test).
- **Step 3.** `spawn_menu/spawn_menu_tab.tscn` (`SpawnMenuTab`), the Spawn tab of Debug Tools.
  `SpawnCatalog.request_type()`/`poll()` build each type on one worker task at a time with the
  worker's own `EsmReader` (STAT ~187 ms there); the tab shows "Indexing <type>…" meanwhile.
  Main-thread cost, measured 2026-11-09 (was: a 6785-STAT grid fill ~64 ms, a search ~25 ms): no
  frame over ~9 ms. Searches wait for a 120 ms typing pause (Enter applies at once) and use one
  joined search string per type, built on the worker, so each match is one native `find()`
  ("crate": ~1 ms). The grid fills within 4 ms a frame, overwriting items in place and trimming
  the rest later. The tree builds a node's children when it is expanded, the unfiltered tree is
  cached, and a search's tree is rebuilt the frame after the grid. Types that finish together
  make one refresh. The catalog is made the first time the tab shows (~0 ms). A type's own tree node is its "All" node (no separate child). Not done yet:
  Favourites (step 8) and "Inspect in Script Engine" (the Script Engine tab lists script
  instances, and a Base has none until placed). `ConsoleOverlay.open_with_line()` added for
  Open in console. A spawned LVLN actor ran 30 physics frames without a crash.
- **Step 5, icons only.** A record with an ICON shows it as-is: the DDS through
  `TextureServer.request()`, scaled by the grid (mipmapped filter). No ThumbnailCache, disk cache
  or resize: all 2317 icons in the archives are 256×256 DXT3/DXT5 and decode cheaply, and
  TextureServer already caches them (resident for the session; ~2317 × 64 KB at most). Only the
  visible rows and one screen ahead load, 16 at a time, newest first; scrolling or a new
  selection drops the ones not started. The disk cache belongs with model renders (step 6).
- **Hover preview (in place of step 6's cached model renders, for now).** `spawn_menu/model_preview.tscn`
  (`ModelPreview`): hovering a record with a model shows it live over its icon, 1.2× the icon about
  the same centre, slowly turning, in a SubViewport with its own World3D. It loads after 80 ms on
  one row (a sweep loads only where it stops), removes collision bodies (a NifRigidBody is top
  level and, while awake -- a frozen one never sleeps -- moves its owner, the meshes, back to its
  own transform each frame, which pinned most weapons and armor in place), hides NIF editor
  markers and frames from the meshes' merged AABB. The pointer within the hovered cell turns the
  model ±45° of yaw and pitch, eased. Its viewport renders at full scale with bilinear scaling:
  SubViewports inherit `rendering/scaling_3d` (FSR, MetalFX on macOS), whose output has no alpha.
  NPC_ and CREA show none yet (step 9). Grid thumbnails for model-only records are renders on
  this rig (step 6). Shift steers it with the pointer; otherwise it spins. `ItemList.get_item_rect()` ignores scrolling, and
  `get_item_at_position()` in the panel margin answers row 0 at any scroll; both are allowed for.
- **Step 8, Spawnlists (2026-11-09).** A first category tab, shown by default, whose tree is
  Favourites, Common and Recent (`spawn_menu/spawn_lists.gd`, `SpawnLists`). Favourites come from
  the context menu's Add to / Remove from Favourites; Recent is what was spawned, given or equipped,
  newest first, at most 50. Both are saved to `user://spawn_menu.cfg` on every change. Common is
  data, not code: `spawn_menu/common_spawnlist.tres` (a `SpawnList` of EditorIDs, checked against
  FalloutNV.esm with `_diag/diag_common_spawnlist.tscn`); EditorIDs the data lacks are skipped. List
  rows of any type come from `SpawnCatalog.row_for()`, one at a time, so a list does not build every
  type; each shows its own type's glyph. The status line clips, so a long message cannot widen the
  grid's column and move items under the hover preview.
- **Thumbnails split out for any UI (2026-11-09).** The renders, icons and the record lookup moved
  out of the tab into the `ThumbnailServer` autoload (`GodotBryo/Servers/ThumbnailServer/`:
  `thumbnail_server.gd`, `record_visuals.gd`, `stage.tscn`). `request(form_id)` gives a record's
  picture; `ui/record_icon.gd` (`RecordIcon`) shows one in any UI (a look-at overlay, console
  suggestions); `ui/model_preview.tscn` (`ModelPreview`) is the live view, with `show_record()`.
  The notes below describe the parts before the move: `ThumbnailRenderer` is now the server's
  render half, and `ModelPreview`'s statics are the server's `request_model()`, `prepare_model()`,
  `frame_model()`.
- **Step 6, model renders.** `spawn_menu/thumbnail_renderer.tscn` (`ThumbnailRenderer`, a node of
  the tab). A record with no ICON whose model the preview shows renders that model once: the key
  is the model path, so every record on one mesh shares one render and one Texture2D. It renders
  on the hover preview's own stage (`preview_stage.tscn`: camera, pivot, lights, World3D), in the
  preview's start pose (yaw −35°, level) and framing (`ModelPreview.frame_model()`), so the hover
  carries on from its thumbnail without a jump. 128 px, one `UPDATE_ONCE` frame per model, read
  back after `RenderingServer.frame_post_draw`, then kept mipmapped and DXT5-compressed
  (`ThumbnailRenderer.compact()`): 21,872 bytes each against 256 KB raw at 256 px. Compression is
  an editor-build feature; without it the image stays uncompressed (64 KB + mips). Saved as PNG under `user://thumbnails/`, named by
  the md5 of the path plus every setting that changes the image (`CACHE_VERSION`, size, pose,
  fill, pitch); a later session loads the PNG on a worker thread. Six requests at once (trees load
  in parallel, render one at a time), visible rows and one screen ahead, like the icons. A model
  that renders nothing gives null (glyph), remembered for the session, not saved.
  - Texture readiness (Open): answered. NifServer awaits `NifTreeBuilder.resolve_textures()`
    before it builds a tree, so a delivered tree is already textured.
  - Two framing bugs found by `_diag/diag_thumbnail_framing.tscn` (every saved render: tiny or
    touching an edge), both also in the hover preview's stage:
    1. **Physics interpolation.** The project turns it on; the camera and model are moved in
       `_process`, so a render drew them part way between two physics ticks, at a different size
       every run (the baseball at 66–94 px for a computed 131). The stage now has
       `physics_interpolation_mode` off. 32 of 230 renders were cropped before, 0 after.
    2. **Rigid bodies.** The renderer first parked delivered trees in its viewport before
       `ModelPreview._prepare()`; a NifRigidBody goes top level on entering the tree and carried
       the meshes off with the simulation while the tree waited. Trees are prepared before they
       are parented, as the preview does.
  - The six renders still under 40% of the image are dust-storm effects, a shock-baton FX mesh and
    two Lucky 38 ceiling pieces, whose bounds are mostly invisible geometry.
  - The check needs a window: `--headless` draws nothing, so `test_spawn_menu` skips it there.
  - Not done: actors (step 9); textures are resident for the session (~21 KB each), with no
    eviction.
- Open questions answered by step 2: runtime STATs get a node through `CellStreamerV2` (the V2
  physicaliser does not batch); `set_location(0, …)` does emit the cell change and the streamer
  frees the node (`world_items.md` is stale on this).

## Goal

- Open Debug Tools (Home), pick the Spawn tab, browse or search, and click a thumbnail:
  - an object or actor is placed at the crosshair, facing the player;
  - an item goes into the player's inventory.
- Undo spawns one at a time, newest first, or clear all of this session's spawns.
- Thumbnails come from the item's own inventory icon where one exists. Otherwise they are a render
  of the item's world model, cached to disk so each is made once.
- Building the placement path also makes the console's `PlaceAtMe` work. It has been a stub since
  the registry was detached from CellStreamerV2.

Out of scope: a tool gun, a physics gun, dupes, saved layouts, editing a placed reference's
transform with gizmos. Each of these is a separate piece of work once spawning exists.

## Starting state

What already exists and is reused, verified in the code on 2026-11-09:

- **Record index.** `EsmServer.get_record_index()` returns one row per record with `form_id`,
  `record_type`, `editor_id` and `full_name`: 465017 rows, 70872 with an EditorID.
  `ConsoleCompleter` already builds an EditorID index over it in about 276 ms.
- **Spawning a reference.** `EsmServer.create_runtime_reference(base_form_id)` makes a
  `runtime:` reference that is unplaced, held in the runtime table and written to saves.
  `EsmReference.set_location(space, position)` places it and emits `reference_cell_changed`. On
  that signal, `CellStreamerV2._on_reference_cell_changed` → `_on_reference_arrived` physicalises
  it in the current cell, and `WorldStreamerV2` follows the same signal.
  `ActorReference.drop_entry()` already uses exactly this path to drop stacks in front of an
  actor, so this is proven for items.
- **Coordinates.** Reference positions are metres on Gamebryo's Z-up axes; the native parser
  converts units. `EsmReferencePhysicaliser.authored_position(godot_position)` and
  `authored_heading(godot_yaw)` convert back from Godot space. Use these; do not add another
  conversion (see AGENTS.md on #56's doubled conversion).
- **PlaceAtMe.** The registry's `PlaceAtMe` calls `place_at_me_handler`, which is
  `game.gd`'s `debug_place_at_me()`. That function only warns and returns 0.
- **Leveled lists.** `LeveledItemResolver` and `LeveledActorResolver`
  (`GodotBryo/Pipeline/`) already exist. The editor browser previews LVLI results with the first.
- **Editor browser.** `addons/godotbryo_browser/` is an editor-only dock with:
  - a TabBar of 30 record types;
  - a card grid built in 4 ms batches per frame;
  - display names (FULL, else humanised EditorID, else FormID);
  - drag-to-scene through `create_reference_for_base` + the physicaliser.

  It has no thumbnails and is `@tool`-only. It is the closest existing thing to this tab, and its
  display-name rules are worth sharing (see Decisions).
- **Textures.** `TextureServer.request(tex_path)` is an awaitable, cached DDS decode and upload.
  Inventory icons are DDS files under `textures/`.
- **Debug Tools.** A `Control` with a `TabContainer`. Opening it enters
  `ScriptServer.MENU_CONSOLE`, which frees the mouse and leaves the player camera where it was.
  Every tab is scene-authored and its script only does `@onready` lookups (AGENTS.md).
- **OBND.** Only `actor_base.gd` reads OBND. No placeable Base exposes bounds, so placement
  measures the built node instead (step 6).

## Census

`project/_diag/diag_spawn_menu_census.gd` is a headless census, run with
`godot --headless --path . -s _diag/diag_spawn_menu_census.gd`. For every record of each type it
reads the raw subrecords and counts:

- whether it has a FULL name;
- its world model (MODL; MOD2 for ARMO) and whether that model is in the archives;
- its ICON and whether that icon is in the archives;
- a non-zero OBND;
- the first folder under `meshes/` of each model.

| Type | Records | FULL | Model (in BSA) | ICON (in BSA) | OBND ≠ 0 | Top model folders |
|---|---|---|---|---|---|---|
| STAT | 6785 | 0 | 6780 (6775) | 0 | 6117 | dungeons 2581, architecture 1502, clutter 1198, landscape 388, weapons 259 (27 folders) |
| NPC_ | 3816 | 3399 | 3808 (3808) | 0 | 1819 | characters 3170, (root) 638 |
| LVLI | 2738 | 0 | 0 | 0 | 0 | — |
| CONT | 2478 | 2430 | 2478 (2478) | 0 | 2086 | clutter 1969, furniture 247, dungeons 177 |
| CREA | 1578 | 1159 | 1093 (1093) | 0 | 701 | creatures 1048, (root) 33 |
| ACTI | 1143 | 722 | 429 (429) | 0 | 1124 | clutter 163, architecture 125, dungeons 46 |
| NOTE | 894 | 733 | 282 (282) | 348 (348) | 98 | clutter 282 |
| MISC | 507 | 502 | 461 (461) | 489 (489) | 337 | clutter 399, weapons 29 |
| LIGH | 501 | 0 | 29 (29) | 0 | 448 | clutter 15 |
| FLST | 464 | 0 | 0 | 0 | 0 | — |
| ARMO | 389 | 384 | 345 (345) | 372 (368) | 214 | armor 331 |
| LVLN | 365 | 0 | 0 | 0 | 0 | — |
| TERM | 344 | 322 | 312 (312) | 0 | 274 | terminals 291 |
| LVLC | 343 | 0 | 0 | 0 | 0 | — |
| DOOR | 320 | 312 | 320 (318) | 0 | 297 | dungeons 185, architecture 88 |
| KEYM | 283 | 283 | 264 (264) | 283 (283) | 160 | clutter 261 |
| CCRD | 270 | 270 | 270 (270) | 270 (270) | 0 | clutter 270 |
| WEAP | 261 | 251 | 207 (207) | 200 (200) | 100 | weapons 190 |
| MSTT | 241 | 16 | 241 (240) | 0 | 227 | clutter 106, effects 71, vehicles 35 |
| FURN | 234 | 190 | 234 (233) | 0 | 223 | furniture 202 |
| IDLM | 211 | 0 | 0 | 0 | 200 | — |
| ALCH | 189 | 189 | 189 (189) | 189 (189) | 140 | clutter 176 |
| SCOL | 98 | 0 | 98 (88) | 0 | 98 | scol 98 |
| AMMO | 92 | 92 | 91 (91) | 92 (92) | 40 | ammo 45, weapons 31 |
| TACT | 87 | 75 | 85 (85) | 0 | 83 | clutter 33, terminals 25 |
| IMOD | 50 | 50 | 50 (50) | 50 (50) | 13 | weapons 50 |
| BOOK | 27 | 20 | 26 (26) | 17 (17) | 26 | clutter 26 |
| GRAS | 24 | 0 | 24 (24) | 0 | 9 | landscape 24 |
| CMNY | 6 | 6 | 6 (6) | 6 (6) | 0 | clutter 6 |
| CHIP | 5 | 5 | 5 (5) | 5 (5) | 1 | clutter 5 |
| TREE | 3 | 0 | 3 (0) | 3 (0) | 3 | (none) |

What this settles:

- **Inventory icons cover inventory items and nothing else.**
  - Full coverage: ALCH, AMMO, KEYM, CCRD, CMNY, CHIP and IMOD have an ICON on every record, all
    present in the archives.
  - Gaps: ARMO 368/389, MISC 489/507 and WEAP 200/261. The WEAP gap is mostly unarmed or
    no-model weapons.
  - No world-object or actor type has an ICON at all.

  So icons are the first thumbnail source for items, and renders are needed for everything else.
  Renders are also the fallback for items without an icon.
- **OBND cannot frame thumbnails or place spawns.**
  - It is zero on 161 of 261 WEAP, all 270 CCRD and 175 of 389 ARMO.
  - The 9mm pistol (0x000E3778) is one of the zeros.

  Framing and placement use the built node's AABB.
- **NPC_ MODL is not a picture of the NPC.**
  - 3170 point into `characters/`, which means the shared skeletons; 638 sit at the root.
  - A model render would show a skeleton or nothing.
  - An NPC thumbnail needs the full assembled actor: race body parts, head, FaceGen. That is the
    expensive case and is deferred to step 9.
- **Model folders make a usable tree for every type with models.**
  - STAT spreads over 27 top folders.
  - Weapons sit under `weapons/<kind>/`, armor under `armor/<set>/`, creatures under
    `creatures/<kind>/`.
  - NPC_ is the exception: its models are only skeletons, so it is grouped by race instead.
- **Not spawnable from this tab.**
  - Left out: IDLM, GRAS, FLST, and TREE, whose 3 models are missing from the archives.
  - Spawnable with a warning on missing models: SCOL (10 of 98 models missing) and the handful of
    DOOR/FURN/MSTT/STAT records with missing models.
  - LVLI/LVLN/LVLC have no model of their own; they are resolved first (Decisions).

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

- **Top tabs are category groups. The record type is the tree's first level.**
  - One tab per record type would be about 25 tabs; the editor browser has 30 and they overflow.
  - Groups keep the tab bar short, the way GMod's categories do. The tree still shows the record
    type, so nothing is hidden.
  - The groups are one data table (`SpawnCatalog.CATEGORIES`), so switching to one tab per type
    is a table edit.

  The groups:

  | Tab | Types | Default click |
  |---|---|---|
  | Items | WEAP, ARMO, AMMO, ALCH, MISC, KEYM, BOOK, NOTE, CCRD, CMNY, CHIP, IMOD | add to inventory |
  | Actors | NPC_, CREA | place |
  | Objects | STAT, MSTT, SCOL | place |
  | Interactive | ACTI, TACT, CONT, DOOR, FURN, TERM, LIGH | place |
  | Leveled | LVLI, LVLN, LVLC | resolve, then add (LVLI) or place (LVLN/LVLC) |
  | Favourites | anything starred, plus a Recent node | per record |

- **The tree under each type** comes from a pluggable grouping function per type:
  - **Model folder (default):** the model path minus `meshes/` and the file name, split on `/`.
    For example, `dungeons/vault/roomkit`.
  - **NPC_:** by race (`NpcBase.race`), then by the first faction where it has one.
  - **Leveled lists:** by EditorID prefix, because they have no model.
  - **Records with no model:** an `(no model)` node, so nothing disappears.

  Each node shows a count, and selecting a node shows everything below it. An `All` node sits at
  the top of each type.
- **The grid is an `ItemList` in icon mode.** Settings: `ICON_MODE_TOP`, `max_columns = 0`,
  `fixed_icon_size` from the size slider (64 / 96 / 128), `same_column_width`.
  - It draws only visible rows and copes with the 6785 STAT records without one Control per card.
    The editor browser's PanelContainer cards are why it builds in 4 ms batches.
  - Visible indices come from the vertical scrollbar value, the icon size and the column count.
    That range drives which thumbnails are requested.
  - Placeholder icon until the thumbnail lands: a per-type glyph.
- **The search** matches display name, EditorID and FormID (hex, with or without `0x`, as the
  console does) across the current tab. With text in it, the tree is filtered to matching nodes.
- **The info bar** shows the hovered or selected record: name, EditorID, type, FormID and model
  path. For items it adds value and weight from the Base.
- **The tab is its own scene,** `spawn_menu/spawn_menu_tab.tscn`, instanced into `game.tscn`'s
  TabContainer like the console is.
  - Its nodes are still authored in the scene, not built from code (AGENTS.md's tab rule).
  - This keeps `game.tscn` from growing by several hundred lines.

### Clicks

- **Left click** does the tab's default: add to inventory for items, place for everything else.
- **Shift + left click** does the other one where it makes sense: place an item in the world, or
  give a container. A container is placeable only.
- **Right click** opens a menu with:
  - Place at crosshair;
  - Add to inventory (items);
  - Favourite / Unfavourite;
  - Copy EditorID;
  - Copy console command (`player.PlaceAtMe WeapNV9mmPistol 1` / `player.AddItem ...`);
  - Inspect in Script Engine (when the base has a script);
  - Open in the console, which fills the line without running it, like the console's +Caps button.
- **The count spinbox** in the footer applies to AddItem and to placement. Placing more than one
  uses `drop_entry`'s spread (`DROP_SPACING`) across the facing direction.

### Placement

`SpawnPlacer` (`spawn_menu/spawn_placer.gd`) is the one owner. Both the tab and `PlaceAtMe` use
it, so `game.gd`'s `debug_place_at_me()` becomes a call into it. This also fits
`Plans/GameGd/game_gd_decomposition.md` better than more code in `game.gd`.

- **Ray:** from the active camera's centre (`get_viewport().get_camera_3d()`) along its forward
  axis.
  - It ignores the cursor. Debug Tools frees the mouse, but the player camera stays where it was
    aimed when the panel opened, which is GMod's behaviour.
  - Range is 20 m (tunable). The player's own body is excluded.
  - On a miss, the spawn goes 2 m ahead at the player's feet height.
- **Position:** `EsmReferencePhysicaliser.authored_position(hit_point)`, with no other conversion.
- **Heading:** facing the player. That is `authored_heading(camera_yaw + PI)`.
- **Space:** the possessed reference's `current_space_form_id`. `set_location()` derives the cell,
  and the streamers physicalise it.
- **Resting on the surface:** once the node exists (`EsmNode.node_for(reference)`), measure the
  merged AABB of its visual instances in reference space and raise the reference so the AABB
  bottom sits on the hit point.
  - The first frame can show it half-sunk; the correction runs once.
  - OBND would avoid this, but no placeable Base reads it and the census shows it is zero too
    often to rely on.
- **Leveled lists:**
  - LVLN and LVLC go through `LeveledActorResolver` at the player's level, and the chosen base is
    placed.
  - LVLI goes through `LeveledItemResolver`, and each resulting item is added.
  - The info bar says what was chosen.
- **What is placed is a `runtime:` reference,** so saves include it. That is wanted: spawned
  things persist like dropped items do.

### Undo

- `SpawnPlacer` keeps this session's spawned runtime references in order.
- **Undo (button, or Ctrl+Z while the tab has focus)** removes the newest one.
  `set_location(0, Vector3.ZERO)` takes it out of the world, and then
  `release_runtime_reference()` drops it from the runtime table so saves leave it out.
- **Clear spawned** does every one.
- An item added to the inventory is undone with the inventory's remove, for the same count.
- **A spawn that left the world is skipped and forgotten:** the player picked it up, or it moved to
  a container.

### Thumbnails

`ThumbnailCache` (`spawn_menu/thumbnail_cache.gd`) answers `request(form_id, size) -> Texture2D`,
awaitable. It works through three sources in order:

1. **Memory:** an `ImageTexture` by `(form_id, size)`, with an LRU cap of about 2000 entries.
2. **Disk:** `user://thumbnails/<generator version>/<FormID hex>_<size>.png`.
   - The cache key also hashes the source path (ICON or model). A record whose model or icon
     changes misses the cache instead of showing a stale picture.
   - The files are derived from the user's own game data and live in `user://`, never in the repo.
3. **Generate:**
   - **Inventory icon:** `TextureServer.request("textures/" + icon)`, then scale it to the cell
     size. These are already 2D, so they cost no rendering. Covers almost every Items tab entry.
   - **Model render:** `ThumbnailRenderer` (`spawn_menu/thumbnail_renderer.tscn`) is set up as
     follows.
     - A `SubViewport` with `own_world_3d = true`, `transparent_bg = true`, size 128 or 256,
       `UPDATE_DISABLED` between jobs.
     - A `Camera3D`, a key and fill `DirectionalLight3D`, and a neutral `WorldEnvironment`.

     It renders one model per job:
     1. `NifServer.request(model_path, …)` builds the model.
     2. Add it under a pivot turned to a three-quarter view (yaw −35°, pitch −20°).
     3. Frame it from the merged AABB, with distance = radius / sin(fov/2).
     4. Wait until its textures are resident. NifServer finishing does not mean TextureServer has
        finished; see Open.
     5. Set `UPDATE_ONCE` and await `RenderingServer.frame_post_draw`.
     6. Read the texture with `get_texture().get_image()`, then free the model.
   - **Actor render (step 9):** a synthetic reference from `create_reference_for_base`, physicalised
     into the renderer's own world, the way the editor browser's Open As Scene does.

- **Scheduling.**
  - Only records in the grid's visible range, plus one screen ahead, are requested.
  - Requests are LIFO, so scrolling fast does not leave a queue of off-screen work ahead of what is
    on screen.
  - A scroll or tab change drops queued, unstarted jobs.
  - Renders are capped at one job in flight and one readback per frame, because
    `get_texture().get_image()` stalls on the GPU. Icon decodes use TextureServer's own worker cap.
- **Records with no model and no icon** keep the type glyph. These are leveled lists, LIGH without
  a model, and the 0-model ACTI.
  - A leveled list could later show its first resolved entry's thumbnail.

### Shared catalogue

`SpawnCatalog` (`spawn_menu/spawn_catalog.gd`) is plain data with no nodes, testable headless.

- It builds per-type rows from the record index: display name, EditorID, FormID, model path, icon
  path.
- It also builds the tree, the category table and filtering.
- Display names use the editor browser's rule: FULL unless it just repeats the type, else the
  humanised EditorID, else the FormID. That rule moves into `SpawnCatalog` as a static function.
  The browser can call it later, but changing the browser is not part of this work.
- **Model and icon paths need the raw record**; the index row has only names. A type's rows are
  built the first time its tab opens.
  - Measure that first build. If a type is slower than about 100 ms, build it on a WorkerThreadPool
    task with its own `EsmReader`, following the resolver pool's per-thread reader rule (EsmReader
    is not thread-safe).
  - The tab shows "Indexing STAT…" meanwhile.
  - A native `get_record_paths(type)` is the step after that, only if the worker build is still too
    slow.

### Favourites and settings

`user://spawn_menu.cfg` holds:

- favourite FormIDs, stored as `<file>:<local id>` like save identities, so a load-order change
  does not mix them up;
- the last 30 spawned records (Recent);
- icon size;
- the last tab and tree node.

## Build order

Each step ends with its checks in `tests/test_spawn_menu.tscn`, run headless against the real
ESM, unless the step says otherwise.

1. **SpawnCatalog.**
   - Rows per type from the record index plus raw MODL/MOD2/ICON.
   - The category table, model-folder tree, NPC_ race tree, `(no model)` node, display names and
     filtering.
   - Checks: row counts match the census table; the 9mm pistol is under
     `WEAP/weapons/1handpistol` with its ICON; search `000e3778`, `0xE3778` and `9mm` all find it;
     IDLM/GRAS/FLST/TREE are absent.
   - Time the first build per type.
2. **SpawnPlacer and PlaceAtMe.**
   - The ray, placement, heading, count spread and session spawn list with Undo and Clear.
   - `debug_place_at_me()` delegates to it.
   - Checks in Doc Mitchell's house: `player.PlaceAtMe` of a MISC and a STAT makes a `runtime:`
     reference in the player's cell; its node appears through CellStreamerV2; Undo frees the node
     and drops it from `EsmServer`'s runtime table.
   - Also verify the space-0 removal path. `world_items.md`'s starting state said `_refresh_cell()`
     returned early for space 0; `set_holder()`'s comment now says the streamers free the node.
   - Add `PlaceAtMe` to the console's `SIGNATURES` if its arguments changed.
3. **The tab, without thumbnails.**
   - The scene, the top tabs, the tree, the ItemList grid with type glyphs, the search, the info
     bar, left / Shift / right click, the count spinbox, Undo and Clear.
   - Instance it into `game.tscn`.
   - Checks: switching tabs and tree nodes fills the grid with the catalogue's records; a simulated
     click on an Items record adds it to the player's inventory and one on a STAT places it.
   - Extend `test_debug_tabs` for the new scene layout.
4. **Surface resting.** The AABB correction after the node is built. Check that a placed crate's
   AABB bottom is within 1 cm of the hit point.
5. **ThumbnailCache with icon thumbnails.**
   - Memory, disk and TextureServer icons, plus visible-range scheduling.
   - Checks: requesting the 9mm pistol yields a texture of the requested size; a second run loads
     from `user://thumbnails`; scrolling drops queued jobs.
6. **ThumbnailRenderer for models.**
   - Checks: in a windowed run (the headless renderer draws nothing), a STAT, a CONT and a WEAP
     without an icon each give a non-empty, non-uniform image.
   - Headless tests cover only the queue and cache with the renderer stubbed.
   - Check by hand for dark or untextured renders; see Open on texture readiness.
7. **Leveled lists.** LVLN/LVLC place a resolved actor, and LVLI adds its resolved items, both at
   the player's level. The info bar names the result.
8. **Favourites and Recent,** in `spawn_menu.cfg`. Check that they survive a restart of the scene.
9. **Actor thumbnails.**
   - Physicalise synthetic NPC_ and CREA references in the renderer's world.
   - First, verify that entering a tree there does not register them with NpcSimulationServer or
     ScriptServer (see Open).
   - Until then, NPC_ uses the type glyph, and CREA uses a model render, which works because CREA
     models are the creatures' own (`creatures/`).
10. **AGENTS.md.** Add the tab to the Debug Tools list, and add `SpawnPlacer` as PlaceAtMe's owner.

## Open

- **Texture readiness for renders.** Does a NIF built by NifServer have its textures resident when
  `request()` completes, or are they still in flight in TextureServer? If they are in flight, the
  renderer needs a "wait until this tree's textures are finished" step, or it will cache grey
  models. Check before step 6.
- **Side effects of physicalising an actor offscreen.** An actor node entering a tree may hand
  itself to NpcSimulationServer, run head tracking, or register with ScriptServer. The thumbnail
  world must not do that. Verify before step 9; it may need a "preview" flag on the physicaliser.
- **Statics placed at runtime.** Most placed STATs become `DirectGeometryBatch` geometry, not
  nodes. Step 2 must confirm that `_on_reference_arrived` physicalises a runtime STAT as a node,
  that its collision exists, and that Undo frees it. Do the same for SCOL, whose parts take
  `physicalise_scol_part`.
- **Exterior spawns.** The checks in step 2 run in an interior. In an exterior, confirm that
  WorldStreamerV2 picks up the spawned reference in the tile the player stands in, and keeps it
  when the tile is unloaded and loaded again.
- **Item physics.** Items placed in the world are static props on master. Whether they fall and
  settle depends on the world-items branch (`Plans/WorldItems/world_items.md`), not on this tab.
- **Spawned actors are inert,** like every actor in the current phase. Placing an NPC_ gives a
  standing figure with whatever packages NpcSimulationServer would give a runtime reference;
  confirm it does not crash for an actor with no editor-placed package context.
- **Opening the tab from a key.** GMod's menu is hold-to-open on Q. The console's hold-to-run
  shows that pattern works here. A later step could host this tab's scene in its own overlay on a
  hold key, in addition to Debug Tools.
