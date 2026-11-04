# SaveServer

Saves and loads the game. The plan is `Plans/Saving/save_load.md`.

## Contract

```gdscript
SaveServer.save(save_id, parent := "") -> Error     # ERR_BUSY when refused; why in report
SaveServer.read_save(save_id) -> Dictionary         # checked save state, {} when it cannot load
SaveServer.apply_state(state)                       # clears EsmServer's game state, then loads each section
SaveServer.build_state(parent := "") -> Dictionary  # the save state, without storing it
SaveServer.check_header(header) -> String           # why it cannot load, or ""
SaveServer.get_save_refusal() -> String             # why a save cannot be made now, or ""
SaveServer.register_backend(name, backend)
SaveServer.backend_name                             # "json_folder" or "git"; from user://save_settings.cfg
SaveServer.playthrough_id                           # set by start_playthrough() or a loaded header
SaveServer.start_playthrough()                      # a new game's playthrough
SaveServer.has_save(save_id) -> bool
SaveServer.extra_sections                           # section name -> owner (time, weather)
SaveServer.save_refusals                            # Array[Callable] returning a reason or ""
SaveServer.report                                   # warnings and dropped entries of the last call
SaveFields.write(resource, skipped := []) -> Dictionary
SaveFields.read(resource, data, skipped := [])
```

## Layers

- **Owners** (EsmServer, QuestServer, ScriptServer, DialogueServer, and the sections the game
  adds) turn their state into plain values with `save_state()` and back with
  `load_state(state, report)`. They know nothing of files.
- **SaveServer** builds the save state, checks a loaded one's header, and applies it in order.
- **Backends** (`SaveBackend`) store and fetch whole save states and never touch game objects.
  `JsonFolderBackend` is the default; a backend is registered by name. `GitBackend` is
  registered when the git command runs (see Git storage).
- **SaveFields** turns a resource's saved fields into plain values and back.

## Schema (format version 1)

A save state is a Dictionary of plain values (no Object), one key per section.

**Ids.** A record is `<file>:<local id>` (`FalloutNV.esm:00104C0C`): the master its FormID comes
from and the lower three bytes. A reference is its instance_id: the same form for a placed one,
`player`, or `runtime:<file>:<local id>:<n>`. An unset record is `null`.

**Values** (`SaveFields`). A resource's saved fields are its script properties with
`PROPERTY_USAGE_STORAGE`. An int named `*_form_id` is a record id; an `EsmBase` a record id; an
`EsmReference` an instance_id; another Resource a Dictionary of its own saved fields; a `Vector3`
`[x, y, z]`; a Dictionary has string keys, read back as its typed key type (`ActorValues` keyed by
actor value name). A number in an untyped slot (a script local) is a float. Floats may differ in
their last digit after a save and a load, since JSON does not read printed digits back exactly.

| Section | Holds |
|---|---|
| `header` | `version`; `masters` (`file`, `size`, `modified`) in load order; `player_space` (record id), `player_position`, `player_cell` (editor ID); `space_names` (space id -> editor ID); `saved_at` (UTC); `parent` (save_id or null); `playthrough` (the playthrough's id) |
| `esm_server` | `references`: instance_id -> saved fields, plus `editor_id` (the base's); `runtime`: `next_number` and `references` (each also has `base_form_id`); `bases`: record id -> the fields `changed_fields` lists, plus `editor_id` |
| `quest_server` | `states`: QUST id -> QuestState fields plus `editor_id`; `clock`; `next_run`: QUST id -> clock time; `quest_objects`: item id -> bool; `active_quest` |
| `script_server` | `globals`: GLOB editor ID -> value; `clock`; `disabled_player_controls` |
| `dialogue_server` | `said`: speaker instance_id -> INFO id -> game day (Say Once and Say Once a Day lines only); `talked_to_player`; `added_topics`; `saying`: each line being said (`speaker`, `topic`, `info`, `listener`, `begun`), said again from the start on load |

Keys named `editor_id` are for reading the files and are ignored on load. A reference entry
leaves out its inventory when the inventory has not changed since EsmServer built it.

A change to the schema bumps `FORMAT_VERSION` and adds a migration from the old version.

## Loading

`read_save()` refuses a save from a newer format version or one that needs a master that is
not loaded. A master whose size or modified time differs, or a different load order, only adds
a warning to `report`. Entries whose record is no longer in the load order are dropped by their
owner and listed in `report`.

## Saving

`save()` is refused during a conversation, while `ScriptServer` has a move queued, and when a
check in `save_refusals` gives a reason (the game adds one for a transition in progress).

## JsonFolderBackend

One folder per save under `user://saves`: `header.json` and `<section>.json`, with `esm_server/`
split into `bases.json`, `runtime.json` and `references/<space editor ID>.json`. Files are
indented and key-sorted, so two saves diff cleanly. A save is written to `<save_id>.writing` and
renamed into place; the save it replaces is moved aside first and removed after.

## Git storage

`GitBackend` keeps one bare repository per playthrough, `user://saves_git/<playthrough>/repo.git`.
A save is written as JsonFolderBackend's folder into `tree/` and committed whole with git's
plumbing (`add -A`, `write-tree`, `commit-tree`, `update-ref`); its save_id is the ref
`refs/saves/<save_id>`, URI-encoded. The commit's parent is the save last written or read in that
playthrough, so saving after loading an earlier save starts a branch; a quick save moves its ref
and the earlier quick saves stay in the history. A save is read by checking its commit out into
`read/` and reading that folder with JsonFolderBackend. `list()` names each save
`<playthrough>/<save_id>`; a bare save_id is in the current playthrough. `delete()` removes the
ref, and `git gc --auto` after a save reclaims what nothing reaches.

Chosen with `user://save_settings.cfg`:

```ini
[saves]
storage="git"
```

Without git installed only `json_folder` is registered, and the setting is ignored.
