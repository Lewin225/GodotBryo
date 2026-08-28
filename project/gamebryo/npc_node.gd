class_name NPCNode
extends GamebryoActor

## Issue #52 chunk 5: thin leaf for a placed NPC_ (enginedocs/
## nv_class_hierarchy.md's "Actors" section — "a rich shared GamebryoActor
## base... with genuinely thin NPCNode/CreatureNode leaves"). No fields of
## its own yet: armor slots, dialogue, pickpocket-able state are all real
## future work, not invented ahead of a real need. Construction (skeleton +
## body-part wiring against the real RACE-driven humanoid assembly
## confirmed in issue #52 chunk 2/4) lives in
## GamebryoObjectRegistry._build_npc(), same "Node classes are shape-only"
## split every other branch in this codebase already follows.
