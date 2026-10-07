class_name IdleTree
extends RefCounted

## The IDLE records as a tree (ANAM parent and previous sibling) and the pick
## the GECK's "Idle Animations" page describes: from a top-level item, the first
## child whose conditions the actor meets, then its first qualifying child,
## until none qualifies; that item is the pick. An item whose MODL is only a
## folder is skipped when it must return a file (IdleBase.must_return_file), as
## if it had not qualified. Conditions run with the actor as subject.
##
## The tree's top level is one item per skeleton (GECK): the IDLEs with no
## parent whose MODL lies under that skeleton's folder (`Characters\_Male\` for
## humans), in sibling order; loose idles (SECTION_FLAG_LOOSE), played by name,
## are not among them. pick_for picks from an actor's skeleton's items, as the
## Idle Manager does (PickIdle, ambient idles); pick from one named item
## (FurnitureIdles for furniture use).

## The top-level item furniture use picks from.
const FURNITURE_ROOT := "FurnitureIdles"

## IdleBase -> its children, in sibling order.
var _children: Dictionary = {}
## Skeleton folder (lowercase, `characters\_male\`) -> its top-level items, in
## sibling order.
var _roots_by_folder: Dictionary = {}
var _built := false

## The idle `actor` plays from under `root`, or null when no item qualifies.
func pick(actor: EsmReference, root: IdleBase) -> IdleBase:
	if root == null:
		return null
	_build()
	return _pick_under(actor, root)

## The idle `actor` plays from its skeleton's top-level items, or null when
## none qualifies or its skeleton has none.
func pick_for(actor: EsmReference) -> IdleBase:
	_build()
	return _pick_among(actor, _roots_by_folder.get(skeleton_folder(actor), []))

## The folder of `actor`'s skeleton MODL (its base's, or its Model/Animation
## template's), lowercase with a trailing backslash; "" without one.
static func skeleton_folder(actor: EsmReference) -> String:
	var base := ActorBase.template_source(actor.base if actor != null else null, ActorBase.TEMPLATE_USE_MODEL_ANIMATION)
	if base == null or base.model_path.is_empty():
		return ""
	var path := base.model_path.to_lower().replace("/", "\\")
	return path.left(path.rfind("\\") + 1)

## The skeleton folder a top-level IDLE belongs to: its MODL up to IdleAnims
## (`Characters\_Male\IdleAnims[\X.kf]` -> `characters\_male\`).
static func _folder_of(idle: IdleBase) -> String:
	var path := idle.model_path.to_lower().replace("/", "\\")
	var at := path.find("idleanims")
	return path.left(at) if at >= 0 else ""

## The top-level item named `editor_id`, or null.
func get_root(editor_id: String) -> IdleBase:
	var idle := EsmServer.find_base_by_editor_id(editor_id) as IdleBase
	if idle == null or idle.parent != null:
		return null
	return idle

## `item`'s children in sibling order.
func get_children(item: IdleBase) -> Array:
	_build()
	return _children.get(item, [])

func _pick_under(actor: EsmReference, item: IdleBase) -> IdleBase:
	return _pick_among(actor, _children.get(item, []))

## The first of `items` (siblings, in order) the actor qualifies for, then its
## deepest qualifying descendant; an item without a KF that must return a file
## is skipped as if it had not qualified.
func _pick_among(actor: EsmReference, items: Array) -> IdleBase:
	for child: IdleBase in items:
		if not ScriptServer.evaluate_conditions(child.conditions, ConditionContext.new(actor)):
			continue
		var deeper := _pick_under(actor, child)
		if deeper != null:
			return deeper
		if child.has_kf() or not child.must_return_file():
			return child
	return null

## Groups every IDLE under its parent, ordered by following each sibling's
## `previous` from the one without a previous sibling among them.
func _build() -> void:
	if _built:
		return
	_built = true
	var siblings_by_parent := {}
	var roots_by_folder := {}
	for row: Dictionary in EsmServer.get_record_index():
		if String(row.get("record_type", "")) != "IDLE":
			continue
		var idle := EsmServer.get_base(int(row["form_id"])) as IdleBase
		if idle == null:
			continue
		if idle.parent == null:
			_add_root(roots_by_folder, idle)
			continue
		if not siblings_by_parent.has(idle.parent):
			siblings_by_parent[idle.parent] = []
		siblings_by_parent[idle.parent].append(idle)
	for parent: IdleBase in siblings_by_parent:
		_children[parent] = _in_sibling_order(siblings_by_parent[parent])
	for folder: String in roots_by_folder:
		_roots_by_folder[folder] = _in_sibling_order(roots_by_folder[folder])

## Files a parentless IDLE among its skeleton's top-level items, unless it is
## a loose idle.
static func _add_root(roots_by_folder: Dictionary, idle: IdleBase) -> void:
	if (idle.animation_group_section & IdleBase.SECTION_FLAG_LOOSE) != 0:
		return
	var folder := _folder_of(idle)
	if folder.is_empty():
		return
	if not roots_by_folder.has(folder):
		roots_by_folder[folder] = []
	roots_by_folder[folder].append(idle)

static func _in_sibling_order(siblings: Array) -> Array:
	var members := {}
	for idle: IdleBase in siblings:
		members[idle] = true
	var next_of := {}
	var first: Array = []
	for idle: IdleBase in siblings:
		if idle.previous == null or not members.has(idle.previous):
			first.append(idle)
		else:
			next_of[idle.previous] = idle
	var ordered: Array = []
	for start: IdleBase in first:
		var idle: IdleBase = start
		while idle != null and not ordered.has(idle):
			ordered.append(idle)
			idle = next_of.get(idle)
	for idle: IdleBase in siblings:
		if not ordered.has(idle):
			ordered.append(idle)
	return ordered
