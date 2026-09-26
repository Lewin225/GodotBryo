# Use-state UI and exterior COC

Follow-on to `Plans/Completed Plans/Transitions/actor_transitions.md`.

## Current state

- Activating a terminal, container, furniture, or a locked door without its
  key calls `ScriptServer.begin_use(activator, target)`. The actor's
  `ActorReference.using` / `using_marker` and the target's `used_by` (or
  `FurnitureReference.occupants`) are set; `ActorReference.using_changed`
  fires. `ScriptServer.end_use(actor)` clears both sides.
- Terminals are done: `PlayerController` opens its `TerminalSession`
  (`player/player.tscn`) when the possessed actor starts using a
  `TerminalReference`, suspends its own input while it is open, and closing
  the session calls `end_use`. `ShowMessage` presents on the player's
  `MessageBox`, registered with `ScriptServer` on possession.
- Locks are done as placeholders: `TerminalReference` has a lock state from
  its base; a locked door or terminal without its key or password note opens
  `UnlockSession`, a slide-to-unlock screen (`player/player.tscn`). Success
  unlocks (a hacked terminal then opens), cancel ends the use.
- Terminal menu items run their result scripts
  (`ScriptServer.run_result_script`). Items with conditions stay listed but
  unavailable: conditions are only counted, not decoded.
- Nothing reacts to using a container or furniture; the player's `using`
  stays set until the next `begin_use`.
- `ContainerReference.contents` is the container's live `Inventory`; there is
  no container UI.
- `coc` rejects exterior CELLs ("CenterOnWorld is not implemented yet").

## Scope

1. **`PlayerController` presents its possessed actor's `using` target.** On
   `possessed.using_changed`, open the UI for the target's type; closing that
   UI calls `ScriptServer.end_use(possessed)`. The UI never ends use on its
   own terms otherwise.
   - Container: a container UI over `ContainerReference.contents` and the
     player's inventory.
   - Locked door / terminal: replace the `UnlockSession` placeholder with
     the lockpick and hacking minigames.
   - Terminal item conditions: decode the menu items' CTDA and hide items
     whose conditions fail.
   - Furniture: no UI; sitting is presentation on the actor.
2. **Non-player actors do not pick locks.** An NPC controller or package that
   finds its actor using a locked door ends the use immediately.
3. **Exterior `coc`.** `coc <exterior CELL EditorID>` moves the player's
   reference into the CELL's worldspace at its grid centre, at the terrain
   height there.

## Open

- Where the NPC-side reaction to `using` lives: NPC packages in
  `NpcSimulationServer`, or a physical NPC controller that does not exist yet.
- Minigame fidelity: the original lockpick (bobby pins, force lock) and
  word-guess hacking, gated by skill, or skill gates alone. Either needs the
  player's skills exposed.
- Exterior `coc` height: sample LAND heights through `TerrainStreamer`, or
  place high and let the body settle once terrain collision is ready.
