# Reference persistence

Changed references and bases are saved and restored on load, so the world keeps its runtime
state across sessions. Follow-on to
[`Completed Plans/Navigation/npc_server.md`](../Completed%20Plans/Navigation/npc_server.md).

## Current state

- `EsmResource.dirty` is set by `mark_dirty()` when a resource changes at runtime; a clean one is
  rehydrated from the ESM, a dirty one is not (`esm_resource.gd`).
- Nothing writes dirty resources out or reads them back; `EsmServer` notes that save loading
  must inject or replace its restored resources.

## Open

- The save format, and what it holds beyond dirty references (quest state, globals, the
  simulation server's actor state).
- Cell reset: placed actors choose from their leveled list again, and encounter zones without
  Never Resets fix their level again (`EncounterZoneBase.resolved_level`,
  `ActorReference.leveled_template`; [`templated_npcs.md`](../Completed%20Plans/Actors/templated_npcs.md)).
  Both are runtime fields that a save keeps.
- Saving bases whose resolved links form a cycle: `ResourceSaver` reports cyclic resource
  inclusion (`Completed Plans/Actors/actors.md`, Unverified).
