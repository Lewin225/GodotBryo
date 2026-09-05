# Phase 3.2 — Item Branch: Inventory Foundation + MISC

Parent: [Phase 3](README.md) · Extends [phases/3/01-dynamic-object-types.md](01-dynamic-object-types.md)'s
Item branch · Builds on [enginedocs/nv_class_hierarchy.md](../../enginedocs/nv_class_hierarchy.md)'s
"Items — a sibling branch" section

## Scope

Inventory composition is now established as a generic component contract:
`InventoryComponent` is a child Node usable by NPCs and CONT objects, while
equipment remains a separate consumer of inventory-owned entries.

Two things, in this order, because the second can't be tested without the first:

1. **A real inventory system** — the player can hold items. Doesn't exist at all yet
   (the "Inventory" tab in the in-game Debug Tools window is an empty placeholder —
   see `AGENTS.md`'s Debug Tools section — and `ContainerNode` is explicitly
   "mesh-only, inventory contents out of scope" per `phases/1/object-types.md`). This
   is real Phase 7/8 scope (`ROADMAP.md`) being deliberately pulled forward because
   `MISC` needs *somewhere* to go when picked up — this task is not a request to build
   full Phase 7/8 (no equip UI, no weight-limit enforcement, no container looting yet).
2. **`MISC` as the first real Item-branch type** — per `phases/3/01`'s own table, `MISC`
   is the largest real gap in that branch (178/507 real base records carry a script).
   World-placed `MISC` REFRs must become **real physics props** — confirmed directly
   from the GECK Wiki's own MiscItem page (`enginedocs/GeckWiki/txt/MiscItem - GECK.txt`):
   "They react to Havok physics, have a value and a weight" — not just correctly-placed
   static meshes the way Phase 1 left them. Concretely: a world `MISC` item must be a
   real `RigidBody3D`-backed prop the player can **shove/drag around**, and separately,
   **pick up into their inventory**.

**Explicitly out of scope** (don't build these here — flag for a later task instead):
- The other six Item-branch types (`ARMO`/`WEAP`/`AMMO`/`KEYM`/`CCRD`/`ALCH`) — get the
  same `ItemNode`/pickup treatment later, once this proves the pattern on `MISC`. Don't
  build them speculatively now; `phases/3/01`'s table tracks them separately.
- Container contents/looting (`CNTO` subrecord parsing) — a container's own inventory
  is a different, larger task (needs `LVLI` leveled-list resolution too, which
  `phases/1/object-types.md` explicitly deferred). This task is about the *player's*
  inventory gaining items, not containers having them.
- Equipping, hotkeys, weight-limit enforcement, any inventory UI beyond wiring the
  already-existing empty Debug Tools "Inventory" tab if convenient.
- Tuned, Havok-accurate mass/friction/restitution (real `bhkRigidBody` values from the
  NIF) — that's `ROADMAP.md` Phase 14's own explicit scope ("Dynamic/loose physics
  objects (bottles, debris) driven by `bhkRigidBody` mass/friction/restitution
  values"). This task needs a real, shovable/draggable `RigidBody3D`, not perfectly
  tuned physics — a reasonable placeholder mass (e.g. derived loosely from the real
  `Weight` field, or a flat constant) is fine for now, don't block on NIF collision
  mass extraction.
- Script execution on pickup/equip (`OnEquip`, etc.) — blocked on Phase 5's
  interpreter regardless, same as every other Dynamic type.

## Docs to read first

1. `phases/3/01-dynamic-object-types.md` — the Item branch section this extends, and
   its "Confirmed NOT Dynamic" section (some sibling types like `BOOK`/`NOTE`/`IMOD`/
   `CMNY` have zero real script usage and are correctly left alone for now — don't
   scope-creep into them).
2. `enginedocs/nv_class_hierarchy.md` — "Items — a sibling branch, not a merge into
   set-dressing" section: the core design guidance. An Item's Reference **stops
   existing** the moment it's picked up (GECK's own "Objects → References" page
   documents this) — model it as a `GamebryoVisual`-based node for in-world state
   PLUS a plain-Dictionary shape for in-inventory state, with an explicit conversion
   between them (mirroring how `resolve_raw_geometry()` → `build_geometry_entries()`
   already separates raw data from constructed Node elsewhere in this codebase). A
   shared `ItemData` field set (`weight`, `value`, `equip_type`, `inventory_image`,
   `message_icon`) belongs on the Dictionary shape, not baked into a Node subclass.
3. `project/gamebryo/gamebryo_visual.gd` and `gamebryo_collision_body.gd` — the
   existing composition pattern (a `GamebryoVisual`'s collision is a composed
   `StaticBody3D` CHILD, `GamebryoCollisionBody`, not something the node inherits).
   `MISC` needs the same composition idea with a `RigidBody3D` instead — see "New
   composition body" below.
4. `project/game.gd`'s `_try_interact()` — already anticipates this exact task in its
   own doc comment: *"hover prompts and physics-prop dragging are follow-on work
   sharing this same raycast, not separate systems."* Read the whole function; it's
   the entry point this task hooks into, not a new raycast.
5. `AGENTS.md`'s "Native standalone C++ tools" section if you need to verify any real
   ESM field layout yourself before trusting it (see next section for what's already
   confirmed).

## Real data already confirmed (don't re-derive, but do verify anything not listed here)

Checked directly against `FalloutNV.esm` (native scan, no Godot) before writing this
doc — a real `MISC` record's subrecord layout:

```
EDID, OBND, FULL, MODL, ICON, SCRI (optional, ~35% of real records), DATA (8 bytes)
```

- **`DATA`** (8 bytes): `int32 Value` + `float32 Weight`, in that order — confirmed by
  decoding real records and getting sane values (weights 0.01–5.0, values 2–400,
  matching real FNV junk-item pricing; NOT the reverse order, which would have
  produced nonsense). No existing parser for this — `native/src/esm/esm_types.h`/
  `esm_file.{h,cpp}` currently have no `ItemData`/`get_item_data()` equivalent at all.
- **`ICON`**: inventory image path (relative to `Data/Textures/`, same convention as
  every other texture path in this codebase — no "textures\" prefix stored, add it at
  lookup time same as `mesh_resolver.gd`'s existing texture paths).
- **`MICO`** (message icon, shown in the HUD pickup toast): present on some but not
  all real records — didn't appear in the first samples checked, treat as optional,
  same "real, valid case" convention as every other optional subrecord in this codebase
  (e.g. `SCRI`, `has_xtel`).
- **`FULL`**: display name — needed for the pickup message/inventory list, not
  currently threaded through `ReferencePlacement`/`get_cell_references()` at all
  (only `base_editor_id`, the internal EDID, is — `FULL` is the real in-game display
  name and is a different subrecord).

## Native work

Add to `native/src/esm/esm_types.h`/`esm_file.{h,cpp}` (mirroring the existing
`LightData`/`DoorDestination` pattern — a plain struct + a `get_*_data(form_id)`
method, not a generic subrecord dump):

```cpp
struct ItemData {
    std::string full_name;       // FULL, display name
    int32_t value = 0;           // DATA
    float weight = 0.0f;         // DATA
    std::string inventory_icon;  // ICON, empty if absent
    std::string message_icon;    // MICO, empty if absent (a real, common case)
};
std::optional<ItemData> EsmFile::get_item_data(uint32_t form_id) const;
```

Generic over base_type (don't hardcode `MISC` — the other six Item types share this
same `DATA`/`ICON`/`MICO`/`FULL` shape per the GECK Wiki's own "Data fields common to
most Items" list, `enginedocs/GeckWiki/txt/Category_Items - GECK.txt` — verify each
type's own `DATA` subrecord size/field order before trusting it's identical, some
Item types add extra fields to their own `DATA` beyond Value/Weight, don't assume).
Bind it to GDScript the same way `get_light_data()`/`get_door_data()` already are in
`esm_reader_gd.{h,cpp}`.

## GDScript work

**Inventory** (new — no existing file to extend): a plain, non-Node class (`RefCounted`
or a `Resource` if you want it save-file-serializable later, matching this codebase's
own "Resource for cheap, non-scene-tree data" convention from
`enginedocs/nv_class_hierarchy.md`'s "What never becomes a Node" section) holding
`{ base_form_id: int -> count: int }` plus enough per-entry cached display data
(`full_name`, `inventory_icon`, `weight`, `value`) to render a list without re-querying
the ESM every frame. `add_item(base_form_id, count)`/`remove_item(...)`/`get_entries()`.
Where it lives (a `Game`-owned singleton-ish node, an autoload, a field on `Character`)
is your call — there's no existing precedent to match in this codebase, pick whatever
composes cleanly with `game.gd`'s existing structure. Wiring it into the existing empty
"Inventory" Debug Tools tab (`game.tscn`'s `Debug Tools/TabContainer/Inventory`, and see
`world_streaming_debug_tab.gd`/`environment_debug_tab.gd` for the established
scene-authored-controls-only pattern for these tabs) is optional but likely the fastest
way to verify this visually without building real UI.

**New composition body** (`project/gamebryo/gamebryo_rigid_body.gd` or similar):
mirror `GamebryoCollisionBody` (`StaticBody3D` + `owner_ref` field) but extending
`RigidBody3D` instead, for real physics-reactive collision. `mesh_resolver.gd`'s
`populate_collision_children()` currently always builds a `GamebryoCollisionBody`
(hardcoded `StaticBody3D`) — decide whether to parameterize that function with a body
class, or give `ItemNode` its own composition step that doesn't call
`populate_collision_children()` at all and builds its own `RigidBody3D` child instead.
Either is defensible; whichever you pick, don't silently change collision body type
for every OTHER `GamebryoVisual` subclass — `Door`/`Container`/`Activator`/etc. must
stay `StaticBody3D`.

**`ItemNode`** (`project/gamebryo/item_node.gd`, `class_name ItemNode`, `extends
GamebryoVisual`) — per the class-hierarchy doc, this one class covers all seven
Item-branch types eventually (don't make `MiscItemNode`, `WeaponNode`, etc. — a
per-type subclass buys nothing here since the interesting data lives in `ItemData`,
not the class). Needs:
- The `RigidBody3D` composition above instead of `GamebryoCollisionBody`.
- A cached `ItemData` (from the new native `get_item_data()`) so pickup doesn't need
  a fresh ESM query.
- A `pickup() -> Dictionary` method (or whatever name reads best alongside
  `DoorNode.activate()`/`resolve_destination()` — this codebase already uses duck-typed
  capability methods checked via `has_method(...)` rather than base-class contracts,
  see `enginedocs/nv_class_hierarchy.md`'s "Cross-cutting fields → composition" section
  for the precedent) returning the item's `base_form_id`/count/`ItemData`, or `{}` if
  not eligible for some reason. `game.gd`'s interact raycast needs a
  `has_method("pickup")` check alongside its existing `has_method("activate")` one —
  read `_try_interact()` closely, it already resolves a `GamebryoCollisionBody`
  collider up to `owner_ref` before checking capabilities, and the new `RigidBody3D`
  body needs the exact same `owner_ref` pattern or that resolution breaks for items.

**Registration** — same two-place pattern as every other Dynamic type (see
`phases/3/01`'s own description of this, or just copy what `d49e510` did for
`TACT`/`TERM`/`MSTT`): `GamebryoObjectRegistry._register_defaults()` for
CellLoader/indoor, and `resolve_placement()`'s fixed match statement for
WorldStreamer/outdoor. Register `"MISC"` only for now — not the other six Item types.

**Drag interaction** — genuinely new interaction mode, not a copy of the existing
tap-to-activate pattern. `_try_interact()` currently fires once on
`Input.is_action_just_pressed("interact")`; dragging needs press/hold/release state
tracked across frames while the button stays down, then releases the prop (probably
disabling gravity/damping while held, re-enabling on release — a `PhysicsServer3D`
joint holding it at a fixed offset from the camera is the usual, robust approach for
this over directly setting `RigidBody3D.global_position` in `_process()`, which fights
the physics step and produces jittery collision against other bodies).

## Open design questions — use judgment, but make a call and document it in the code

These weren't resolved during scoping and are yours to decide (this codebase's own
convention: real, deliberate decisions with a comment explaining the "why," not silent
defaults):
- **Same key for drag vs. pickup, or different keys?** E.g. tap `interact` to pick up,
  hold `interact` to drag; or a separate dedicated key. Whatever you pick, a player
  needs a way to do EITHER — dragging something you can never then pick up (or vice
  versa) would be a real, noticeable gap.
- **Where the `Inventory` class lives** (see above) — no existing precedent to match.
- **Placeholder mass value** — pick something reasonable and say so in a comment;
  don't spend time on real Havok mass extraction, that's Phase 14.

## Acceptance criteria

- A real, unmodified `MISC` REFR from `FalloutNV.esm` (pick one from a cell you can
  actually reach in play, or via `interior_viewer.tscn`/`exterior_viewer.tscn`) renders
  as a real `RigidBody3D`-backed prop: it responds to the player bumping into it (moves,
  doesn't just block like static collision), can be dragged around while held, and
  settles back under gravity/collision when released.
- Picking it up removes it from the world (the `Node` this session — real, in-memory
  removal; nothing here touches save/persistence, out of scope per `ROADMAP.md` Phase
  9) and adds a real entry to the player's inventory with correct `value`/`weight`/
  `full_name` read from the actual ESM record, not placeholder data.
- `GamebryoObjectRegistry`'s two dispatch points both resolve `MISC` to `ItemNode` —
  verify indoors (`CellLoader`) AND outdoors (`WorldStreamer`) actually differ before
  this change and don't after, the same real gap Codex's Phase 3.1 audit caught for
  `MSTT` (a type registered in only one of the two paths silently works indoors and
  stays RID-batched outdoors — check `project/tests/test_object_registry.gd` and
  `test_threaded_resolve.gd`, which needed real fixes last time for exactly this
  reason, and expect the same here).
- Existing tests that assert `MISC` is unregistered/falls through to the structural
  fallback (same class of stale assertion Codex found and fixed for `MSTT`/`TACT`/
  `TERM` in `d49e510`) are updated, not left failing.

## When done

Update `phases/3/01-dynamic-object-types.md`'s `MISC` row status, and add a note that
the Item branch now has a proven `ItemNode` pattern the remaining six types
(`ARMO`/`WEAP`/`AMMO`/`KEYM`/`CCRD`/`ALCH`) can follow without re-deriving the
design — but don't implement those six here; leave them for the next handoff.
