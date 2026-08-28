class_name GamebryoActor
extends GamebryoObject

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
## (npc_node.tscn/creature_node.tscn) plus this populate() method, NOT
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
## Base no-op: CreatureNode doesn't override this yet (issue #52's own
## documented gap — see creature_node.gd). NPCNode does.
func populate(_placement: Dictionary, _esm: EsmReader, _mesh_resolver: GamebryoMeshResolver) -> void:
	pass
