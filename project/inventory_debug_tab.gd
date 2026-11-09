extends Control

## The possessed actor's inventory (ActorReference.contents): one row per
## entry, a stack or one held item reference, with its count, name, base
## FormID, the reference's instance_id when it is one, and weight and value
## from the base.
##
## Category tabs split the list as the Pip-Boy's Items screen does (CATEGORIES:
## Weapons, Apparel, Aid, Misc, Ammo), with All first and Equipped last (worn
## armor and the weapons in the holster slots); each title counts its
## entries. Rows show the item's picture (ThumbnailServer: its inventory icon,
## else a render of its model) beside its name. The Details sidebar shows the
## selected entry: its picture (RecordIcon), name, type and fields, and
## buttons that act on it: Equip or Unequip (as the menu's), Drop (the whole
## entry in front of the actor, ActorReference.drop_entry(): a held reference
## as itself, a stack as one new runtime reference per unit), Increase (one
## more: a stack counts up, anything else gets a new stack of its base) and
## Decrease (one fewer; a held reference removed stays held by nothing and in
## no space). Decrease is off for a holster weapon, which is not in the
## inventory.
##
## Right click on a row opens a menu: Equip or Unequip (WEAP and ARMO, through
## Inventory.equip_item() as the EquipItem script function; a weapon then
## moves into a holster slot and leaves the list), Drop, Add to or Remove from
## the spawn menu's Favourites (the same SpawnLists as `spawn_tab`), Copy
## EditorID and Open in console (SpawnMenuTab.console_command(), as the spawn
## menu's).
##
## The list rebuilds when the inventory says it changed, and at most every
## REFRESH_SECONDS otherwise (an equip or a condition change says nothing).
##
## Nodes are authored in game.tscn; this script only looks them up.

## The tabs, in order: a name and the record types it holds. Misc also takes
## any type no tab names. BOOK is under Aid, where skill books are read from
## (not checked against the game); NOTE is under Misc, though the Pip-Boy
## lists notes under Data, which this tab does not have.
const CATEGORIES := [
	{"name": "All", "types": []},
	{"name": "Weapons", "types": ["WEAP"]},
	{"name": "Apparel", "types": ["ARMO", "ARMA"]},
	{"name": "Aid", "types": ["ALCH", "BOOK"]},
	{"name": "Misc", "types": ["MISC", "KEYM", "NOTE", "CCRD", "CMNY", "CHIP", "IMOD"]},
	{"name": "Ammo", "types": ["AMMO"]},
	{"name": "Equipped", "types": []},
]
const ALL := 0
const MISC := 4
## Not a Pip-Boy tab: worn entries (armor), and the weapons in the actor's
## holster slots, which leave the inventory when equipped
## (ActorReference.equip_weapon()). Last, so the Pip-Boy tabs keep their
## places.
const EQUIPPED := 6
## The holster slots, in the order the Equipped tab lists them, and their
## names.
const SLOTS := [ActorReference.WeaponSlot.RIGHT_HIP, ActorReference.WeaponSlot.LEFT_HIP, ActorReference.WeaponSlot.BACK]
const SLOT_NAMES := {ActorReference.WeaponSlot.RIGHT_HIP: "right hip", ActorReference.WeaponSlot.LEFT_HIP: "left hip", ActorReference.WeaponSlot.BACK: "back"}
## Seconds between rebuilds when the inventory has not said it changed.
const REFRESH_SECONDS := 0.5
## Width of a row's picture beside its name, in pixels.
const ROW_ICON_SIZE := 24

const MENU_EQUIP := 0
const MENU_DROP := 1
const MENU_FAVOURITE := 2
const MENU_COPY_EDITOR_ID := 3
const MENU_OPEN_IN_CONSOLE := 4
## Record types the menu can equip.
const EQUIPPABLE_TYPES := ["WEAP", "ARMO"]

## The spawn menu tab: its Favourites file is the one Add to Favourites
## changes.
@export var spawn_tab: SpawnMenuTab

@onready var _categories: TabBar = $Margin/VBox/Categories
@onready var _filter_edit: LineEdit = $Margin/VBox/FilterEdit
@onready var _tree: Tree = $Margin/VBox/Split/ItemTree
@onready var _details_icon: RecordIcon = $Margin/VBox/Split/Details/Margin/VBox/Icon
@onready var _details_name: Label = $Margin/VBox/Split/Details/Margin/VBox/Name
@onready var _details_fields: RichTextLabel = $Margin/VBox/Split/Details/Margin/VBox/Fields
@onready var _status: RichTextLabel = $Margin/VBox/Status
@onready var _equip: Button = $Margin/VBox/Split/Details/Margin/VBox/Buttons/Equip
@onready var _drop: Button = $Margin/VBox/Split/Details/Margin/VBox/Buttons/Drop
@onready var _increase: Button = $Margin/VBox/Split/Details/Margin/VBox/Buttons/Increase
@onready var _decrease: Button = $Margin/VBox/Split/Details/Margin/VBox/Buttons/Decrease
@onready var _menu: PopupMenu = $ContextMenu

var _game: Node3D
## The inventory the list shows, watched for inventory_changed.
var _watched: Inventory
var _dirty := true
var _since_refresh := 0.0
## What the list last showed (_signature()); a rebuild with the same is
## skipped.
var _shown_signature := ""
## The entry the context menu acts on.
var _menu_entry: InventoryItem
## The Equipped tab's holster weapons (_slot_entries()): entry -> slot, and
## weapon -> entry.
var _slot_of := {}
var _slot_entry_by_weapon := {}


func _ready() -> void:
	# The game scene owns this tab (it is authored in game.tscn), wherever that
	# scene sits in the tree.
	_game = owner as Node3D if owner is Node3D else get_tree().root.get_node_or_null("Game")
	_setup_tree()
	_filter_edit.text_changed.connect(func(_t: String) -> void: _refresh())
	_categories.tab_changed.connect(func(_index: int) -> void: _refresh())
	_tree.item_selected.connect(func() -> void: _show_details(_selected_entry()))
	_equip.pressed.connect(_act_on_selected.bind(toggle_equipped))
	_drop.pressed.connect(_act_on_selected.bind(drop))
	_increase.pressed.connect(_act_on_selected.bind(increase))
	_decrease.pressed.connect(_act_on_selected.bind(decrease))
	_tree.item_mouse_selected.connect(_on_tree_mouse_selected)
	_menu.id_pressed.connect(_on_menu_id)
	_show_details(null)
	_refresh()


func _setup_tree() -> void:
	_tree.columns = 7
	_tree.column_titles_visible = true
	_tree.hide_root = true
	_tree.select_mode = Tree.SELECT_ROW
	_add_column(0, "Qty", 50)
	_add_column(1, "Item Name", 0)
	_add_column(2, "FormID", 100)
	_add_column(3, "Reference", 190)
	_add_column(4, "Weight", 75)
	_add_column(5, "Value", 65)
	_add_column(6, "Total Wt", 80)


## A column; 0 width expands to fill.
func _add_column(column: int, title: String, width: int) -> void:
	_tree.set_column_title(column, title)
	_tree.set_column_expand(column, width == 0)
	if width > 0:
		_tree.set_column_custom_minimum_width(column, width)


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_since_refresh += delta
	if _dirty or _since_refresh >= REFRESH_SECONDS:
		_refresh()


## The possessed actor, or null.
func _actor() -> ActorReference:
	if _game == null or _game.player == null:
		return null
	return _game.player.possessed


## Rebuilds on the next frame the tab shows.
func _mark_dirty() -> void:
	_dirty = true


## Watches `inventory` for changes in place of the one watched before.
func _watch(inventory: Inventory) -> void:
	if inventory == _watched:
		return
	if _watched != null and _watched.inventory_changed.is_connected(_mark_dirty):
		_watched.inventory_changed.disconnect(_mark_dirty)
	_watched = inventory
	if _watched != null:
		_watched.inventory_changed.connect(_mark_dirty)


## The CATEGORIES index of a record type: its tab, else Misc.
static func category_of(record_type: String) -> int:
	for index in range(1, CATEGORIES.size()):
		if (CATEGORIES[index]["types"] as Array).has(record_type):
			return index
	return MISC


## The CATEGORIES index of an entry.
static func entry_category(entry: InventoryItem) -> int:
	return category_of(entry.base.record_type if entry.base != null else "")


## Whether the inventory entry `entry` belongs on tab `category`.
static func in_category(entry: InventoryItem, category: int) -> bool:
	if category == EQUIPPED:
		return entry.is_equipped
	return category == ALL or entry_category(entry) == category


## The weapons in `actor`'s holster slots, as entries the list can show: one
## per weapon, made once and kept (so a selection survives a rebuild), each
## marked equipped, its slot in _slot_of. They are not in the inventory.
func _slot_entries(actor: ActorReference) -> Array[InventoryItem]:
	var result: Array[InventoryItem] = []
	var kept := {}
	for slot: ActorReference.WeaponSlot in SLOTS:
		var weapon := actor.get_weapon(slot)
		if weapon == null:
			continue
		var entry: InventoryItem = _slot_entry_by_weapon.get(weapon)
		if entry == null:
			entry = InventoryItem.make_reference(weapon)
			entry.is_equipped = true
		kept[weapon] = entry
		_slot_of[entry] = slot
		result.append(entry)
	_slot_entry_by_weapon = kept
	for entry: InventoryItem in _slot_of.keys():
		if not result.has(entry):
			_slot_of.erase(entry)
	return result


## The holster slot of a weapon entry from _slot_entries(); NONE for an
## inventory entry.
func slot_of(entry: InventoryItem) -> ActorReference.WeaponSlot:
	return _slot_of.get(entry, ActorReference.WeaponSlot.NONE)


func _refresh() -> void:
	_dirty = false
	_since_refresh = 0.0
	var actor := _actor()
	_watch(actor.contents if actor != null else null)
	if actor == null or actor.contents == null:
		_tree.clear()
		_shown_signature = ""
		_status.text = "No possessed actor with an inventory"
		_show_details(null)
		return
	var selected := _selected_entry()
	var entries := actor.contents.get_items()
	var slot_entries := _slot_entries(actor)
	# Nothing the list shows changed: keep the tree, its scroll and selection.
	var shown := _signature(entries + slot_entries)
	if shown == _shown_signature:
		return
	_shown_signature = shown
	_tree.clear()
	var root := _tree.create_item()
	var filter_text := _filter_edit.text.to_lower().strip_edges()
	var category := _categories.current_tab
	var counts := []
	counts.resize(CATEGORIES.size())
	counts.fill(0)
	var total_count := 0
	var total_weight := 0.0
	var total_value := 0
	var still_selected := false
	for entry in entries:
		var weight := _base_number(entry.base, "weight")
		var value := int(_base_number(entry.base, "value"))
		total_count += entry.count
		total_weight += weight * entry.count
		total_value += value * entry.count
		counts[ALL] += 1
		counts[entry_category(entry)] += 1
		if entry.is_equipped:
			counts[EQUIPPED] += 1
		if not in_category(entry, category) or not _matches(entry, filter_text):
			continue
		if _add_entry_row(root, entry, weight, value, selected):
			still_selected = true
	counts[EQUIPPED] += slot_entries.size()
	if category == EQUIPPED:
		for entry in slot_entries:
			if _matches(entry, filter_text) and _add_entry_row(root, entry, _base_number(entry.base, "weight"),
					int(_base_number(entry.base, "value")), selected):
				still_selected = true
	for index in CATEGORIES.size():
		_categories.set_tab_title(index, "%s (%d)" % [CATEGORIES[index]["name"], counts[index]])
	_show_details(selected if still_selected else null)
	_status.text = "[b]%d[/b] entries   •   [b]%d[/b] total items   •   Total Weight: [color=#e5c07b][b]%.2f[/b] lbs[/color]   •   Total Value: [color=#98c379][b]%d[/b] caps[/color]" % [
		entries.size(), total_count, total_weight, total_value
	]


## Everything the list and the Details sidebar show, as one string: the tab,
## the filter, and each entry's identity, count, equip state, condition and
## whether its row picture is ready.
func _signature(entries: Array) -> String:
	var parts := PackedStringArray([str(_categories.current_tab), _filter_edit.text])
	for entry: InventoryItem in entries:
		parts.append("%d:%d:%d:%s:%s:%s" % [entry.get_instance_id(), entry.base_form_id, entry.count, entry.is_equipped,
				entry.health_percent, ThumbnailServer.cached(entry.base_form_id) != null])
	return "|".join(parts)


## Adds `entry`'s row, selected when it is `selected`; true when it is.
func _add_entry_row(root: TreeItem, entry: InventoryItem, weight: float, value: int, selected: InventoryItem) -> bool:
	var row := _add_row(root, entry, weight, value)
	if entry != selected:
		return false
	row.select(0)
	_tree.scroll_to_item(row)
	return true


func _add_row(root: TreeItem, entry: InventoryItem, weight: float, value: int) -> TreeItem:
	var row := _tree.create_item(root)
	row.set_metadata(0, entry)
	row.set_text(0, str(entry.count))
	row.set_text_alignment(0, HORIZONTAL_ALIGNMENT_CENTER)
	row.set_text(1, _item_name(entry))
	row.set_custom_color(1, Color("#e5c07b"))
	row.set_icon_max_width(1, ROW_ICON_SIZE)
	_set_row_icon(row, entry)
	row.set_text(2, "0x%08X" % entry.base_form_id)
	row.set_text_alignment(2, HORIZONTAL_ALIGNMENT_CENTER)
	row.set_custom_color(2, Color("#61afef"))
	var reference_text := String(entry.item_reference.instance_id) if entry.item_reference != null else "stack"
	if slot_of(entry) != ActorReference.WeaponSlot.NONE:
		reference_text += " (%s)" % SLOT_NAMES[slot_of(entry)]
	row.set_text(3, reference_text)
	row.set_custom_color(3, Color("#c678dd") if entry.item_reference != null else Color("#5c6370"))
	row.set_text(4, "%.2f" % weight)
	row.set_text_alignment(4, HORIZONTAL_ALIGNMENT_RIGHT)
	row.set_text(5, "%d" % value)
	row.set_text_alignment(5, HORIZONTAL_ALIGNMENT_RIGHT)
	row.set_custom_color(5, Color("#98c379"))
	row.set_text(6, "%.2f" % (weight * entry.count))
	row.set_text_alignment(6, HORIZONTAL_ALIGNMENT_RIGHT)
	row.set_custom_color(6, Color("#d19a66"))
	return row


## The entry's picture beside its name: at once when ThumbnailServer has it,
## else asked for, and the list rebuilt when it arrives.
func _set_row_icon(row: TreeItem, entry: InventoryItem) -> void:
	var picture := ThumbnailServer.cached(entry.base_form_id)
	if picture != null:
		row.set_icon(1, picture)
	elif ThumbnailServer.has_picture(entry.base_form_id):
		_load_row_icon(entry.base_form_id)


func _load_row_icon(form_id: int) -> void:
	var picture := await ThumbnailServer.request(form_id)
	if picture != null and is_inside_tree():
		_mark_dirty()


## Shows `entry` in the Details sidebar; null for none.
func _show_details(entry: InventoryItem) -> void:
	_update_buttons(entry)
	if entry == null:
		_details_icon.form_id = 0
		_details_name.text = ""
		_details_fields.text = "[color=#5c6370]Select an item.[/color]"
		return
	if _details_icon.form_id != entry.base_form_id:
		_details_icon.form_id = entry.base_form_id
	_details_name.text = _item_name(entry)
	_details_fields.text = details_text(entry)


## The Details sidebar's fields for `entry`, as BBCode.
func details_text(entry: InventoryItem) -> String:
	var weight := _base_number(entry.base, "weight")
	var value := int(_base_number(entry.base, "value"))
	var record_type := entry.base.record_type if entry.base != null else ""
	var lines := PackedStringArray()
	lines.append(_field("Type", "%s [%s]" % [SpawnCatalog.TYPE_NAMES.get(record_type, record_type), record_type] if not record_type.is_empty() else "unknown"))
	lines.append(_field("Category", CATEGORIES[entry_category(entry)]["name"]))
	lines.append(_field("EditorID", entry.base.editor_id if entry.base != null and not entry.base.editor_id.is_empty() else "—"))
	lines.append(_field("FormID", "0x%08X" % entry.base_form_id))
	lines.append(_field("Count", str(entry.count)))
	var slot := slot_of(entry)
	lines.append(_field("Equipped", ("in the %s holster" % SLOT_NAMES[slot]) if slot != ActorReference.WeaponSlot.NONE else "yes" if entry.is_equipped else "no"))
	lines.append(_field("Reference", String(entry.item_reference.instance_id) if entry.item_reference != null else "stack"))
	if entry.health_percent >= 0.0:
		lines.append(_field("Condition", "%s (COED)" % entry.health_percent))
	if entry.owner_form_id != 0:
		lines.append(_field("Owner", "0x%08X" % entry.owner_form_id))
	lines.append(_field("Weight", "%.2f each, %.2f in all" % [weight, weight * entry.count]))
	lines.append(_field("Value", "%d each, %d in all" % [value, value * entry.count]))
	var visual := ThumbnailServer.record_visual(entry.base_form_id)
	if not String(visual.get("icon", "")).is_empty():
		lines.append(_field("Icon", "textures/" + String(visual["icon"])))
	if not String(visual.get("model", "")).is_empty():
		lines.append(_field("Model", String(visual["model"]).trim_prefix(RecordVisuals.ACTOR_PREFIX)))
	return "\n".join(lines)


static func _field(label: String, value: String) -> String:
	return "[color=#8b929e]%s[/color]  %s" % [label, value.replace("[", "[lb]")]


## Whether the entry's name, FormID or reference contains `filter_text`.
func _matches(entry: InventoryItem, filter_text: String) -> bool:
	if filter_text.is_empty():
		return true
	var reference_text := String(entry.item_reference.instance_id) if entry.item_reference != null else ""
	var haystack := "%s 0x%08x %s" % [_item_name(entry), entry.base_form_id, reference_text]
	return haystack.to_lower().contains(filter_text)


## The base's name, else its editor ID, else its FormID.
func _item_name(entry: InventoryItem) -> String:
	if entry.base == null:
		return "Item 0x%X" % entry.base_form_id
	var full := String(entry.base.full_name).strip_edges()
	if not full.is_empty():
		return full
	return String(entry.base.editor_id)


## A numeric field of the base (weight, value), or 0 when it has none.
func _base_number(base: EsmBase, field: String) -> float:
	if base == null or not field in base:
		return 0.0
	return float(base.get(field))


func _selected_entry() -> InventoryItem:
	var row := _tree.get_selected()
	if row == null:
		return null
	return row.get_metadata(0) as InventoryItem


# --- Context menu ------------------------------------------------------------

func _on_tree_mouse_selected(at_position: Vector2, mouse_button_index: int) -> void:
	if mouse_button_index == MOUSE_BUTTON_RIGHT:
		open_menu(_selected_entry(), _tree.get_screen_position() + at_position)


## Opens the context menu for `entry` at `screen_position`.
func open_menu(entry: InventoryItem, screen_position: Vector2) -> void:
	if entry == null:
		return
	_menu_entry = entry
	var record_type := entry.base.record_type if entry.base != null else ""
	var equip_index := _menu.get_item_index(MENU_EQUIP)
	_menu.set_item_text(equip_index, "Unequip" if entry.is_equipped else "Equip")
	_menu.set_item_disabled(equip_index, not record_type in EQUIPPABLE_TYPES)
	var lists := _lists()
	var favourite_index := _menu.get_item_index(MENU_FAVOURITE)
	_menu.set_item_text(favourite_index, "Remove from Favourites" if lists != null and lists.is_favourite(entry.base_form_id) else "Add to Favourites")
	_menu.set_item_disabled(favourite_index, lists == null)
	_menu.set_item_disabled(_menu.get_item_index(MENU_COPY_EDITOR_ID), _editor_id(entry).is_empty())
	_menu.position = Vector2i(screen_position)
	_menu.reset_size()
	_menu.popup()


func _on_menu_id(id: int) -> void:
	var entry := _menu_entry
	var actor := _actor()
	if entry == null or actor == null or actor.contents == null:
		return
	if not actor.contents.get_items().has(entry) and slot_of(entry) == ActorReference.WeaponSlot.NONE:
		return
	match id:
		MENU_EQUIP:
			toggle_equipped(entry)
		MENU_DROP:
			drop(entry)
		MENU_FAVOURITE:
			var lists := _lists()
			if lists != null:
				lists.toggle_favourite(entry.base_form_id)
		MENU_COPY_EDITOR_ID:
			DisplayServer.clipboard_set(_editor_id(entry))
		MENU_OPEN_IN_CONSOLE:
			var console := get_tree().get_first_node_in_group(&"console") as ConsoleOverlay
			if console != null:
				console.open_with_line(console_command(entry))
	_mark_dirty()


## Equips `entry` (a WEAP or ARMO of the possessed actor's inventory), or
## unequips it when it is equipped; a holster weapon goes back to the
## inventory. True when it changed.
func toggle_equipped(entry: InventoryItem) -> bool:
	var actor := _actor()
	if actor == null or actor.contents == null or entry.base == null or not entry.base.record_type in EQUIPPABLE_TYPES:
		return false
	if slot_of(entry) != ActorReference.WeaponSlot.NONE:
		return actor.unequip_weapon(slot_of(entry))
	if entry.is_equipped:
		return actor.contents.unequip_item(entry)
	return actor.contents.equip_item(entry)


## Drops `entry` in front of the actor; a holster weapon is unequipped first.
func drop(entry: InventoryItem) -> void:
	var actor := _actor()
	if actor == null or actor.contents == null:
		return
	var slot := slot_of(entry)
	if slot != ActorReference.WeaponSlot.NONE:
		var weapon := entry.item_reference
		if not actor.unequip_weapon(slot):
			return
		entry = null
		for item in actor.contents.get_items():
			if item.item_reference == weapon:
				entry = item
		if entry == null:
			return
	actor.drop_entry(entry)


## The console line that gives one of `entry`'s item, as the spawn menu's.
static func console_command(entry: InventoryItem) -> String:
	var row := {"record_type": entry.base.record_type if entry.base != null else "",
			"editor_id": entry.base.editor_id if entry.base != null else "", "form_id": entry.base_form_id}
	return SpawnMenuTab.console_command(row, 1)


static func _editor_id(entry: InventoryItem) -> String:
	return entry.base.editor_id if entry.base != null else ""


## The spawn menu's Favourites and Recent (SpawnLists.shared() of its file).
func _lists() -> SpawnLists:
	return SpawnLists.shared(spawn_tab.lists_path if spawn_tab != null else SpawnLists.DEFAULT_PATH)


# --- Details buttons ---------------------------------------------------------

## Enables the Details buttons for `entry` (null for none) and names Equip.
func _update_buttons(entry: InventoryItem) -> void:
	var record_type := entry.base.record_type if entry != null and entry.base != null else ""
	_equip.text = "Unequip" if entry != null and entry.is_equipped else "Equip"
	_equip.disabled = not record_type in EQUIPPABLE_TYPES
	_drop.disabled = entry == null
	_increase.disabled = entry == null
	_decrease.disabled = entry == null or slot_of(entry) != ActorReference.WeaponSlot.NONE


## Runs `action` on the selected entry, then shows the change.
func _act_on_selected(action: Callable) -> void:
	var entry := _selected_entry()
	if entry == null:
		return
	action.call(entry)
	_mark_dirty()
	_refresh()


## Adds one of `entry`'s item to the possessed actor's inventory: one more in
## a stack, else a new stack of its base (a held reference or a holster
## weapon is one item of its own). True when it changed.
func increase(entry: InventoryItem) -> bool:
	var actor := _actor()
	if actor == null or actor.contents == null or entry.base_form_id == 0:
		return false
	if entry.item_reference == null and actor.contents.get_items().has(entry):
		entry.count += 1
		actor.contents.inventory_changed.emit()
		return true
	return actor.contents.add_item(entry.base_form_id)


## Removes one of `entry` from the possessed actor's inventory; a held
## reference removed stays held by nothing and in no space. A holster weapon
## is not in the inventory and is left alone. True when it changed.
func decrease(entry: InventoryItem) -> bool:
	var actor := _actor()
	if actor == null or actor.contents == null or not actor.contents.get_items().has(entry):
		return false
	if not actor.contents.remove_inventory_item(entry):
		return false
	if entry.item_reference != null:
		entry.item_reference.holder_instance_id = &""
	return true
