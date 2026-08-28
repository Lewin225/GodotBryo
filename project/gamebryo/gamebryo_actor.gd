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
## inherited from GamebryoReference/GamebryoObject) — construction of the
## real skeleton/mesh lives in GamebryoObjectRegistry._build_npc()/
## _build_creature(), same "Node classes are shape-only" split every other
## branch in this codebase already follows.
