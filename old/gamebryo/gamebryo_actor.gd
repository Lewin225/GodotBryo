class_name GamebryoActor
extends GamebryoObject

const ActorAnimationComponentScript := preload("res://gamebryo/actor_animation_component.gd")

const POSSESSED_SHADOW_SETTING_META := "gamebryo_possessed_original_cast_shadow"

## When true, this actor remains present for lighting/shadows but is omitted
## from ordinary camera rendering. The setting is shared by NPCActor and
## CreatureActor; first-person weapon rendering is a separate future layer.
@export var possessed_first_person: bool = false:
	set(value):
		possessed_first_person = value
		_apply_possessed_first_person_render_mode()

func _enter_tree() -> void:
	if get_node_or_null(^"ActorAnimationComponent") == null:
		var component := ActorAnimationComponentScript.new()
		component.name = "ActorAnimationComponent"
		add_child(component)

func _apply_possessed_first_person_render_mode() -> void:
	for child in find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		if not mesh.has_meta(POSSESSED_SHADOW_SETTING_META):
			mesh.set_meta(POSSESSED_SHADOW_SETTING_META, mesh.cast_shadow)
		if possessed_first_person:
			mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		else:
			mesh.cast_shadow = int(mesh.get_meta(POSSESSED_SHADOW_SETTING_META))
			mesh.remove_meta(POSSESSED_SHADOW_SETTING_META)

## Issue #52 chunk 3: base class for the Actor branch (NPC_/CREA), sibling
## of GamebryoVisual under GamebryoObject rather than underneath it — see
## enginedocs/nv_class_hierarchy.md's "Actors" section. Actors don't have
## GamebryoVisual's "MeshInstance3D children built straight from NIF
## submeshes" shape; they need a skeleton/animation controller instead
## (issue #52 chunk 4, real data — see the "ESM humanoid assembly
## structure" finding from chunk 2: skeleton comes from NPC_.MODL, body/head
## parts from RACE's gender-selected INDX blocks).
##
## Deliberately NO composed CharacterBody3D/collider (unlike GamebryoVisual's
## StaticBody3D composition trick, which this class started out mirroring —
## see git history for the removed GamebryoCharacterBody). Physical
## movement/collision for actors is real future work, not this class's
## concern yet: the player's own existing controller already owns a
## CharacterBody3D, and the plan is for one of these actor nodes to
## eventually live INSIDE that controller (not just for third-person model/
## shadows, but because that's also where character stats/SPECIAL/inventory
## belong) rather than each actor composing a second, independent physics
## body of its own. Adding a throwaway placeholder capsule here now would
## just be something to reconcile with (or discard from) that later design.
##
## Identity fields only for now (form_id/base_form_id/editor_id/record_type,
## inherited from GamebryoReference/GamebryoObject).
##
## Real construction now lives in a hand-authored template scene per leaf
## (npc_actor.tscn/creature_actor.tscn) plus this populate() method, NOT
## purely on-the-fly code the way every other GamebryoObject branch is
## built — a deliberate exception, since actors are meaningfully more
## complex (skeleton/animation/armor/items) than anything else placed in
## the world, and a real scene lets that setup be authored/previewed in
## the editor instead of only inspectable by running a script.
## GamebryoObjectRegistry._build_npc()/_build_creature() instantiate the
## template and call populate() on it; each leaf's own .gd script (also
## @tool) can additionally be opened standalone as a preview/config tool,
## the same "same code path in-editor and at runtime" discipline
## nif_viewer.gd already follows for NIFs.
##
## Base no-op: CreatureActor doesn't override this yet (issue #52's own
## documented gap — see creature_actor.gd). NPCActor does.
func populate(_placement: Dictionary, _esm: EsmReader, _mesh_resolver: GamebryoMeshResolver) -> void:
	pass
