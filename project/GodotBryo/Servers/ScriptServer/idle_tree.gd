class_name IdleTree
extends RefCounted

## The IDLE records as a tree (ANAM parent and previous sibling) and the pick
## the GECK's "Idle Animations" page describes: from a top-level item, the first
## child whose conditions the actor meets, then its first qualifying child,
## until none qualifies; that item is the pick. An item whose MODL is only a
## folder is skipped when it must return a file (IdleBase.must_return_file), as
## if it had not qualified. Conditions run with the actor as subject.
##
## Which top-level item serves which purpose: furniture use starts at
## FurnitureIdles, package and general idles at GeneralIdles (census A5). The
## top-level items for human skeletons have MODL `Characters\_Male\IdleAnims`;
## matching other skeletons' items is not done yet.

## The top-level item furniture use picks from.
const FURNITURE_ROOT := "FurnitureIdles"

## IdleBase -> its children, in sibling order.
var _children: Dictionary = {}
var _built := false

## The idle `actor` plays from under `root`, or null when no item qualifies.
func pick(actor: EsmReference, root: IdleBase) -> IdleBase:
	if root == null:
		return null
	_build()
	return _pick_under(actor, root)

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
	for child: IdleBase in _children.get(item, []):
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
	for row: Dictionary in EsmServer.get_record_index():
		if String(row.get("record_type", "")) != "IDLE":
			continue
		var idle := EsmServer.get_base(int(row["form_id"])) as IdleBase
		if idle == null or idle.parent == null:
			continue
		if not siblings_by_parent.has(idle.parent):
			siblings_by_parent[idle.parent] = []
		siblings_by_parent[idle.parent].append(idle)
	for parent: IdleBase in siblings_by_parent:
		_children[parent] = _in_sibling_order(siblings_by_parent[parent])

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
