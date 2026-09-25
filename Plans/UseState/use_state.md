# Use-state UI and exterior COC

Follow-on to `Plans/Completed Plans/Transitions/actor_transitions.md`.

## Current state

- Activating a terminal, container, furniture, or a locked door without its
  key calls `ScriptServer.begin_use(activator, target)`. The actor's
  `ActorReference.using` / `using_marker` and the target's `used_by` (or
  `FurnitureReference.occupants`) are set; `ActorReference.using_changed`
  fires. `ScriptServer.end_use(actor)` clears both sides.
- Nothing reacts to it. The player's `using` is set and never cleared except
  by the next `begin_use`.
- `TerminalSession` (`project/terminal_session.gd`) still exists and is
  exported on `Game`, but nothing opens it. `open_session(terminal, esm,
  player)` takes an `EsmTerminalNode` and reads the menu from its
  reference's base.
- `ContainerReference.contents` is the container's live `Inventory`; there is
  no container UI.
- There is no lockpick UI.
- `coc` rejects exterior CELLs ("CenterOnWorld is not implemented yet").

## Scope

1. **`PlayerController` presents its possessed actor's `using` target.** On
   `possessed.using_changed`, open the UI for the target's type; closing that
   UI calls `ScriptServer.end_use(possessed)`. The UI never ends use on its
   own terms otherwise.
   - Terminal: `TerminalSession`, taking the `TerminalReference` rather than
     a node, so a terminal can be used without its node loaded.
   - Container: a container UI over `ContainerReference.contents` and the
     player's inventory.
   - Locked door: a lockpick UI. Success calls `ScriptServer.unlock(door)`;
     either outcome ends use.
   - Furniture: no UI; sitting is presentation on the actor.
2. **Non-player actors do not pick locks.** An NPC controller or package that
   finds its actor using a locked door ends the use immediately.
3. **Exterior `coc`.** `coc <exterior CELL EditorID>` moves the player's
   reference into the CELL's worldspace at its grid centre, at the terrain
   height there.

## Open

- Where the NPC-side reaction to `using` lives: NPC packages in
  `NpcSimulationServer`, or a physical NPC controller that does not exist yet.
- Lockpick fidelity: the original minigame (skill-gated lock levels, bobby
  pins, force lock), or a stand-in that only enforces the skill gate.
- Exterior `coc` height: sample LAND heights through `TerrainStreamer`, or
  place high and let the body settle once terrain collision is ready.
