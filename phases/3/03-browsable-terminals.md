# Phase 3.3 — Browsable Terminals

GitHub: [#2 — Make real terminals browsable](https://github.com/Lewin225/GodotBryo/issues/2)

## Goal

Make a placed Fallout: New Vegas terminal usable as a data-driven interface:
activate it, read its welcome text, navigate its authored menu tree, view result
pages and linked Notes, enter/leave submenu terminals, then close without leaving
player input or UI state stuck.

This is deliberately a terminal presentation/data slice. It does **not** establish
general persistent reference state, lock/password behavior, hacking, lockpicking,
or container UI.

## First gate: verify the real TERM format

Before adding a parser or UI, create a native diagnostic and inspect several actual
`TERM` records plus their placed `REFR`s. Establish from bytes, not the GECK UI's
field labels alone:

- welcome text and terminal flags;
- menu-item order, title, and result text;
- linked Note and submenu-terminal FormIDs;
- condition data and per-item script metadata;
- the relationship between a placed terminal's base `TERM` and its authored menu.

Select one small, accessible terminal only after this survey. Record its FormID,
EditorID, and exact expected menu tree in the tests; it becomes this task's fixture.

### Initial real-data survey

`native/tools/terminal_survey.cpp` is the reusable first-pass survey tool. Its
FalloutNV.esm output establishes, before a parser exists:

- Terminal menu entries are interleaved record subrecords: `ITXT` is an item
  label, followed by `RNAM` (normally result text), `ANAM`, and optional linked
  data/script/condition subrecords before the next `ITXT`.
- `INAM` is a linked Note FormID and `TNAM` is a linked submenu TERM FormID.
  `P04CompanionFireTerminal` (`0x17B7A0`) has `TNAM 0x17B79F`; its submenu has
  real result text and item scripts. This proves submenu links are FormIDs,
  not label-derived relationships.
- `RNAM` is not blindly a printable string: a 4-byte all-zero `RNAM` appears
  for a real "No." item. The parser must decode the field by verified size/
  meaning, treating the zero form as an authored empty result rather than
  displaying binary bytes.
- Initial placed fixture: `VHDStealthSuitTerminal` (`TERM 0x166B56`) is
  `REFR 0x1515A1` in `HooverDamIntPowerPlant01b`; it has three Note-linked
  choices. It is suitable for opening/menu/Note browsing. A second placed
  submenu fixture is still required before declaring navigation complete.

## Implementation sequence

1. Add native `TerminalData` / `TerminalMenuItem` extraction and
   `EsmReader.get_terminal_data(form_id)`. Preserve source FormIDs/identifiers
   beside display text: submenu/Note resolution must never guess by text.
2. Give `TerminalNode` parsed terminal data and a real activation capability.
   Route terminal interaction from `game.gd` to a single game-owned session
   controller, rather than treating an unscripted terminal as a scripted no-op.
3. Add one session model for opened terminal, navigation stack, selected item, and
   player-input restoration. Individual `TerminalNode`s must not own UI/session
   state.
4. Scene-author the player-facing UI: welcome text, selectable menu items,
   result-text pages, Back/Exit, submenu navigation, and linked Note display.
5. Implement only the condition/script subset demonstrated by the chosen fixture.
   Unsupported choices stay visible but disabled with an explanatory debug reason;
   supported actions route through the existing `ScriptEngine` once their data
   attachment is verified.

## Acceptance criteria

- Real-data tests assert the fixture's TERM record layout and authored menu tree.
- A placed, unscripted terminal opens through normal interaction.
- The user can navigate a real submenu, display real result text and a linked Note,
  then Back/Exit cleanly.
- Runtime links use FormIDs, never display-text heuristics.
- Unsupported condition/script/hacking paths fail visibly and safely.

## Explicit follow-up work

Password/lock gating, hacking, persistent reference state, door/container locking,
and broad condition/function coverage are separate future tasks. Do not pull them
into this one merely because the original game presents them near terminals.
