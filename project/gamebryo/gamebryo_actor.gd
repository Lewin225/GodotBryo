class_name GamebryoActor
extends GamebryoObject

## Issue #52 chunk 3: base class for the Actor branch (NPC_/CREA), sibling
## of GamebryoVisual under GamebryoObject rather than underneath it — see
## enginedocs/nv_class_hierarchy.md's "Actors" section. Actors don't have
## GamebryoVisual's "MeshInstance3D children built straight from NIF
## submeshes" shape; they need a skeleton/animation controller instead
## (issue #52 chunk 4, real data — see the "ESM humanoid assembly
## structure" finding from chunk 2: skeleton comes from NPC_.MODL, body/head
## parts from RACE's gender-selected INDX blocks). This chunk is scaffolding
## only: the composed CharacterBody3D child, no real skeleton/mesh data yet.
##
## Same composition trick GamebryoVisual uses for its internal StaticBody3D
## (mesh_resolver.gd's populate_collision_children()): the physics body is a
## composed child, not inherited, so GamebryoReference can stay Node3D for
## every other branch.

## Human-scale placeholder capsule (same dimensions as project/player/
## player.tscn's own CollisionShape3D) — real per-actor dimensions belong to
## a later chunk once OBND/race data actually drives them; using the
## player's own numbers here rather than inventing new ones keeps player
## and NPC collision consistent in the meantime.
const DEFAULT_CAPSULE_RADIUS := 0.4
const DEFAULT_CAPSULE_HEIGHT := 1.8

## Builds and attaches this actor's internal CharacterBody3D child (named
## "CharacterBody", following GamebryoCollisionBody's "CollisionBody"/
## GamebryoRigidBody's "RigidBody3D" naming precedent) with a placeholder
## capsule shape. Idempotent no-op if already populated — safe to call more
## than once without stacking duplicate children.
func populate_character_body() -> GamebryoCharacterBody:
	var existing := get_node_or_null(^"CharacterBody")
	if existing is GamebryoCharacterBody:
		return existing

	var body := GamebryoCharacterBody.new()
	body.name = "CharacterBody"
	body.owner_ref = self
	add_child(body)

	var shape := CapsuleShape3D.new()
	shape.radius = DEFAULT_CAPSULE_RADIUS
	shape.height = DEFAULT_CAPSULE_HEIGHT

	var col := CollisionShape3D.new()
	col.name = "CollisionShape3D"
	col.shape = shape
	# CapsuleShape3D is centered on its own origin; lift it so the actor's
	# own Node3D origin sits at the feet (matching REFR placement transforms
	# — DATA's position is the ground-contact point, not the model's center).
	col.position = Vector3(0.0, DEFAULT_CAPSULE_HEIGHT * 0.5, 0.0)
	body.add_child(col)

	return body

func get_character_body() -> GamebryoCharacterBody:
	return get_node_or_null(^"CharacterBody") as GamebryoCharacterBody
