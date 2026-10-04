# Engine

Mechanics the original game's executable hard-codes: knowledge with no ESM record behind it,
taken from the GECK's documentation and checked against the game's behaviour. A record type
belongs in `Types/Resource/`; what the engine does with records belongs here.

- `actor_value.gd` (`ActorValue`): the 77 actor value codes and their script names, and the
  formulas that derive an actor's base values from its record (Health from base health,
  Endurance and level; Carry Weight from Strength; ...). The formula coefficients are GMSTs
  (`EsmServer.get_game_setting()`), with the engine's defaults where FalloutNV.esm omits them
  (`ActorValue.DEFAULT_SETTINGS`). The ESM's AVIF records hold only each value's display name,
  description, icon and short name, linked to their codes by hard-coded FormID; they are not read
  yet. One actor's runtime values are `Types/Resource/actor_values.gd` (`ActorValues`).
