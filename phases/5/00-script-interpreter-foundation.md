# 5.0 — Script Interpreter Foundation

Parent: [Phase 5](README.md)

## Goal

Prove the full script pipeline end-to-end against real `SCTX` from `FalloutNV.esm` — native
extraction, lex, parse, tree-walk, frame/event dispatch — with only the small set of functions
that map onto systems this codebase already has. Not a broad function-library push (see
"Explicit non-goals" below); the point of this milestone is a working, tested, extensible
foundation, matching this project's own Phase 0 precedent ("prove the toolchain before committing
to engine work").

## Design source

`enginedocs/nv_script_interpreter_design.md` (written the day before this task started) is the
actual architecture spec — this doc records what was built against it, not a re-derivation.
Its central, real-data-verified finding: every `SCPT` record carries `SCTX`, the complete original
GECK source text, alongside `SCDA` (compiled bytecode Bethesda's own engine executes) — this
project parses/interprets `SCTX` directly and never decodes `SCDA`. `enginedocs/nv_class_hierarchy.md`
covers the one prerequisite refactor (`GamebryoReference` off `StaticBody3D` onto `Node3D`) —
confirmed already done in code before this task started (`project/gamebryo/gamebryo_reference.gd`
extends `Node3D`).

## Native: SCPT extraction

- `native/src/esm/esm_types.h`: `ScriptLocalVar`/`ScriptData` structs. `ScriptData.script_type`
  reads `SCHR`'s real `Type` field (confirmed via fopdoc + a real record's own bytes:
  `VMS18CompanionFreezerExitSCRIPT`'s `SCHR.CompiledSize` field reads 0x9c/156, matching that same
  record's own `SCDA` subrecord size exactly — confirms the field layout, not just fopdoc's word).
  `0` = Object, confirmed against real data; Quest/Effect's real values aren't confirmed yet
  (out of scope — this milestone only exercises Object scripts).
- `EsmFile::get_script_data()` (`esm_file.h`/`.cpp`): walks `EDID`/`SCHR`/`SCTX`/`SLSD`+`SCVR`
  pairs (locals)/`SCRO` (referenced FormIDs). `SCRV` (which local slot an `SCRO` entry resolves
  for) is a real, deliberate gap — real data shows its own count doesn't always match `SCRO` 1:1
  (one sampled real script carried a single `SCRV` against eight `SCRO` entries), so the exact
  pairing rule isn't confirmed and isn't guessed. The interpreter resolves identifiers via its
  local variable table instead, falling back to "unimplemented" for anything else — a real,
  acceptable approximation for this milestone (see Explicit non-goals).
- `ReferencePlacement.script_form_id` (new field): a REFR's base record's own `SCRI` subrecord.
  Confirmed real and common via a full-file census: 992/1143 real `ACTI`, 136/320 `DOOR`, 124/2478
  `CONT` records carry one.
- `EsmReader.get_script_data()`/`get_cell_references()`'s Dictionary output: same bindings,
  Dictionary-shaped, mirroring every other `EsmReader` method.

Verified end-to-end against real data (not just unit-level): `test_script_esm.gd` asserts
`get_script_data()` against `VLCSafetyTrigger01SCRIPT` (form_id `0x17b787`) matches source text,
local variable name, and all 12 referenced FormIDs hand-verified via a native scratch tool this
session, and confirms at least one real `ACTI` REFR in `GSDocMitchellHouse` resolves a non-zero
`script_form_id`.

## GDScript: `project/script_vm/`

- `script_lexer.gd` — tokenizer. Confirmed real: `;` starts a comment to end-of-line (design doc's
  own grammar), so a statement-trailing `;` seen in real scripts needs no special handling at all
  — it's just an empty trailing comment.
- `script_parser.gd` — recursive-descent parser → a plain-Dictionary AST (this project's
  established shape for parsed data, same as `mesh_resolver.gd`'s raw geometry entries). Real,
  explicit scope limit: GECK's own call syntax (`FuncName arg1 arg2`, no parens/commas required)
  has no arity table in the data, so this parser only knows the arity of the handful of functions
  it actually implements (`KNOWN_ARITIES`); an unimplemented function used as a call-statement's
  own head greedily consumes the rest of its line as arguments (right for the common one-call-
  per-line shape), and — a real, documented consequence — a bare reference/editor-ID literal used
  as an ARGUMENT to another call can itself get misparsed as a zero-arg unimplemented call
  (confirmed against real data: `VLCSafetyTrigger01SCRIPT`'s own `MoveTo
  VHDLegateCampGateDestinationMarker` logs the marker name as "unimplemented function"). Harmless
  this pass (still evaluates to 0, never crashes) — disambiguating call-head vs. argument position
  is real follow-up work, not fixed here.
- `script_function_registry.gd` — `String -> Callable`, same shape as
  `GamebryoObjectRegistry._factories`. Seeded with exactly the functions that map onto systems
  already built: `Enable`/`Disable`/`GetDisabled` (visibility + `CellStreamBuilder.
  set_collision_disabled()`), `Activate` (the existing `activate()` contract every interactable
  already implements), `IsActionRef`/`GetActionRef` (against the dispatching event's own action
  ref), `GetRandomPercent`. `GetSecondsPassed`/`GameDaysPassed`/`Unlock` are registered but return
  a real, honest `0` — no frame-delta or game-clock system exists yet to source the first two from,
  and no lock/key state exists on any Dynamic type yet for the third. Any other function call logs
  once (not per-call, so a hot `GameMode` loop doesn't spam) and evaluates to `0`/`false`.
- `script_interpreter.gd` — tree-walking interpreter, one instance per parsed script (cached by
  `SCPT` form_id, shared across every calling reference — same resource-caching discipline
  `GamebryoMeshResolver` already applies to parsed NIFs). Per-instance state lives on the
  caller-owned `ScriptExecutionContext` instead.
- `script_execution_context.gd` — one per (script, calling reference): local variable table, the
  calling `GamebryoReference` Node, and whichever reference triggered the current event dispatch
  (`GetActionRef`/`IsActionRef`'s own answer).
- `script_engine.gd` — a real scene `Node` (like `CellLoader`/`WorldStreamer`), owns every live
  script instance, runs `GameMode`/`MenuMode` blocks every frame via its own `_process()`, exposes
  `dispatch_event(node, block_type, action_ref)` for event-gated blocks.

## Whole-corpus real-data survey

`test_script_corpus_survey.gd` lexes and parses every real `SCPT.SCTX` in `FalloutNV.esm` (2,576
scripts — the base game only, not the DLC `.esm`s the design doc's "11,483" figure counted across)
and reports a real function-call-name histogram plus any structural anomaly. This surfaced two
real bugs the four hand-picked-sample tests above didn't catch:

1. **Real editor IDs can start with a digit** (`1EWatchControlScript`, confirmed real data) — the
   lexer's original digit-vs-letter dispatch committed to a NUMBER token before checking whether a
   letter immediately followed with no gap, splitting the identifier into a stray number token plus
   a separate trailing identifier. Fixed: `_read_number_or_ident()` now scans the whole
   `[0-9 . letter _]` run first and decides NUMBER vs. IDENT from what it actually contains.
2. **`String(token["value"])` crashes whenever a token's value is a non-string type** (an `int`/
   `float` from a NUMBER token) — GDScript's `String()` type constructor is stricter than the
   global `str()` function about which Variant types it accepts. Every such call site in
   `script_parser.gd` now uses `str()` instead.

Both were real crashes (`SCRIPT ERROR: Invalid call. Nonexistent 'String' constructor.`) that
would have taken down the whole interpreter on real, unremarkable game data — exactly the kind of
gap a small hand-picked sample can't surface. Post-fix: 2,576/2,576 real scripts parse without
error (two harmless "unrecognized character" lexer warnings for a stray backtick in one script's
comment, correctly skipped rather than crashing). The real function-call histogram (`GetDead`,
`ShowMessage`, `SetStage`, `AddScriptPackage`, `SetObjectiveDisplayed`, ... all in the hundreds of
real call sites) is the actual next-priority list once inventory/quest/faction/AI systems exist to
back them — closely matching, and now measured rather than grep-estimated against, the design
doc's own "Tier 1" ranking.

## Tests (`project/tests/`)

`test_script_esm.gd`, `test_script_lexer.gd`, `test_script_parser.gd` (including the full real
`VLCSafetyTrigger01SCRIPT` source, hand-verified), `test_script_interpreter.gd` (arithmetic
precedence, if/elseif/else branching, `Enable`/`Disable` on a real Node, unimplemented-function
non-crashing behavior, and a full `ScriptEngine` round trip against the real ESM script). All
headless, self-checking, `ALL CHECKS PASSED`.

## Live-game wiring (second milestone, same task file)

`GamebryoObjectRegistry` gained an optional `script_engine: ScriptEngine` field (null by default --
every `@tool` viewer and most `test_*.tscn` scenes construct a registry with none, and that stays a
real, valid, non-error configuration). `_finalize()` — the one real choke point every construction
path (`build()`'s marker/door/light/scol/visual/fallback branches, and `construct_from_resolved()`'s
threaded-path equivalents) funnels through before returning a node — now calls
`script_engine.register_scripted_node(node, script_form_id)` whenever both are set and the
placement's own `script_form_id` is non-zero. `game.gd` owns the one real `ScriptEngine` for the
whole game (a new `game.tscn` sibling node next to `CellLoader`/`WorldStreamer`), wired into both
`cell_loader.registry` and `world_streamer.registry` after `_ready()`, sharing `cell_loader.esm`
rather than opening a second `EsmReader`.

`register_scripted_node()` also now dispatches a real `OnLoad` block immediately, if the script
defines one — real language semantics (`OnLoad` ranks #5 by real usage in the block-type census
above), and construction time genuinely *is* "this reference just loaded into the world" for this
project's own Dynamic-object model. **Deliberately not** wiring `OnActivate` into `game.gd`'s
interact raycast this pass — investigating candidate real scripts to test surfaced a genuine
semantic gap worth understanding before touching that flow: `GSDocMitchellDoorScript` (a real
script on a real door in `GSDocMitchellHouse`) is just `begin OnActivate / set
DocMitchellREF.PlayerLeft to 1 / activate / end` — that bare `activate` call is exactly how a
scripted door opts back INTO the engine's default open/close behavior. Real implication: `game.gd`
currently calls a Dynamic type's own `activate()` unconditionally, which is only coincidentally
correct for doors whose whole script is "just call activate" — a script with real conditional logic
before deciding whether to call `activate` would be silently skipped today. Wiring this correctly
needs `dispatch_event()` to propagate a script-triggered `activate()` call's own outcome (the
Dictionary door-destination result) back out to the caller, which doesn't exist yet — a real,
separate follow-up, not squeezed in here.

**Real bug found and fixed via this integration, not caught by any earlier hand-picked-sample
test**: `GSBrokenSMGScript` (a real prop in `GSDocMitchellHouse`) has one `if` but two `endif`s in
its own real, shipped `GameMode` block — a real authoring mismatch (`SCDA` is deliberately never
decoded, so there's no way to confirm what the original compiler did with the extra one, only that
it evidently still shipped). The parser previously had no defense against a reserved block-structure
keyword (`endif`/`elseif`/`else`/`end`) appearing where no open block expects it, so the stray
`endif` parsed as a zero-arg call to a function literally named `endif` — misleading (logged as
"unimplemented function 'endif'", implying a missing function, not a stray token). Fixed: these four
keywords are now reserved in `_parse_statement()`, never fall through to
`_parse_call_statement()`, and a stray one becomes a real `{"kind": "noop"}` AST node (logged once,
not silently dropped). This is exactly why `test_script_engine_integration.gd` — the first test to
actually tree-walk/execute real `GameMode` blocks against a diverse set of real scripts, not just
parse them structurally like the corpus survey — earns its place: static parsing alone couldn't
have surfaced this, since the bug only manifested as an actual bare-call AST node once real
execution walked into it.

New test: `test_script_engine_integration.gd` loads the real `GSDocMitchellHouse` cell through the
real `CellLoader` (the actual production construction path, not a synthetic stand-in), confirms a
real, known-scripted prop (`GSBrokenSMG`) gets registered with a real `ScriptEngine`, and runs
several real `GameMode` frame ticks against whatever got registered without crashing. Also verified:
the full existing regression suite (including `test_cell_loader`/`test_object_registry`/
`test_world_streamer`) still passes, and a real headless boot of `game.tscn` itself loads
`GSDocMitchellHouse` successfully with `GSBrokenSMGScript` visibly registering, warning about its
real unimplemented functions (`GetButtonPressed`/`SetHardcore`/`MarkForDelete`), and ticking
`GameMode` every frame — through the actual production `build()` → `stream_refs()` → `_finalize()`
call chain, not a test harness.

## Explicit non-goals for this milestone

Matches `enginedocs/nv_script_interpreter_design.md`'s own "Explicit non-goals for a first pass"
list, narrowed further to what's actually runnable today:

- **Every "Tier 1" function from the design doc's own ranked list.** Most (`AddItem`, `SetStage`,
  `AddToFaction`, `StartCombat`, ...) depend on inventory/quest/faction/AI systems that don't exist
  in this codebase yet. Building those now would balloon this milestone into all of Phases 5–7 at
  once — grow the registry the same incremental way `object_registry.gd` already grows its own
  factory table, function by function, as the backing systems land.
- **`OnActivate` dispatch.** Done for registration/`OnLoad`/`GameMode` (see "Live-game wiring"
  below), deliberately not for `OnActivate` — real investigation while picking a test candidate
  surfaced a genuine outcome-propagation gap worth solving properly, not squeezed in. See that
  section for the real script that exposed it.
- **Piggybacking `WorldStreamer`'s own frame cadence.** The design doc's stated goal; not done
  this pass — `ScriptEngine` runs its own `_process()` instead (still one real per-frame tick, just
  not literally the same call site). Touching `world_streamer.gd` itself is deferred to the
  integration step above.
- **Cross-reference (`OtherRef.Var`) reads/writes, `SCRV`-based symbol resolution, Quest/Effect
  script types, block params (e.g. `OnTrigger Play` vs. plain `OnTrigger`), NVSE syntax
  (`Let`/arrays/strings/`ForEach`).** All real, all logged as gaps at the exact point they'd
  matter (see the class/function doc comments), none guessed at.

## First real function backed by a system: `ShowMessage`

`GSBrokenSMGScript`'s own real `ShowMessage GSBrokenSMGMsg` call is the actual starting point.
Building it required a real, general parser fix first, not just a new registry entry:

**The argument problem.** `ShowMessage`'s real argument is a bare `MESG` editor-ID name
(`GSBrokenSMGMsg`), not a `FormID`. The parser's existing "undeclared bare identifier == phantom
zero-arg call" heuristic (from the earlier corpus-survey pass) meant that argument evaluated to `0`
(logged as "unimplemented function 'GSBrokenSMGMsg'") instead of the literal name `ShowMessage`
actually needs. Real Gamebryo/GECK never has this ambiguity — every value is `int`/`float`/`ref`,
and a bare identifier argument always compiles to a `ref`; the compiler would reject anything else.
Fixed by making `_parse_ident_primary()` return a real `{"kind": "name", ...}` node for an
undeclared, unprefixed identifier in *expression/argument* position (an if/set operand, or an
argument to another call) — evaluates to its own literal text. Statement-HEAD position
(`_parse_call_statement()`) is untouched and still correctly treats a bare line as a real call.

**The comparison problem this exposed.** Once unresolved names could carry into a real `==`/`!=`
comparison against a number (a real script pattern, e.g. `if (Button == 1)` elsewhere), GDScript's
own `==` operator turned out to *throw* for genuinely incompatible Variant type pairs like
`String`/`int` (`"Invalid operands 'String' and 'int' in operator '=='"`) rather than just
returning `false` the way a C-like fallback would. Real Gamebryo never has this comparison in a
valid script either (a `ref`-vs-number type mismatch wouldn't compile), so there's no "correct"
answer to defer to — the fix (`ScriptInterpreter._safe_equal()`) makes `==`/`!=` degrade to "not
equal" for incompatible dynamic types instead of crashing, matching how a runtime encountering this
impossible-in-valid-code situation should behave.

**The function itself.** Native `EsmFile::get_message_by_editor_id()` (mirroring
`find_stat_by_editor_id()`'s existing linear-scan-by-EditorID pattern) reads `MESG.FULL`
(title)/`MESG.DESC` (body) — verified against `GSBrokenSMGMsg`'s real bytes
(`form_id 0x105233`, title "Broken 9mm Submachine Gun", body starting "This 9mm submachine gun is
broken..."). `ShowMessage` (`script_function_registry.gd`) resolves the message and calls
`OS.alert(text, title)` — a real, user-directed choice: no in-game message-box UI exists yet, so
the OS's own native alert dialog stands in. Two honest limitations recorded where they live:
`OS.alert()` is blocking/modal (confirmed directly this session — freezes the whole game loop,
`GameMode` ticking included, until dismissed, when a real display is available; safely fails open
with no display, e.g. this session's own headless test runs), and it returns `void` — no button
index, so `GetButtonPressed` stays genuinely unimplementable through this mechanism, not a partial
gap this closes.

**Deliberately not exercised in the automated test suite**: calling `ShowMessage` for real (which
was in an earlier draft of `test_script_interpreter.gd`). Confirmed directly this session that
`OS.alert()`'s blocking behavior is environment-dependent — the same call completed instantly in
one headless run and genuinely hung a later one once a real display was available (an active
editor/Play session), which makes an automated test non-deterministic and hang-prone through no
fault of the code under test. `get_message_by_editor_id()`'s own real-data resolution (the actual
risk surface) is covered headlessly in `test_script_esm.gd` instead; `OS.alert()` itself is a
one-line stdlib call with nothing of ours left to verify.

## `OnActivate` dispatch for non-door Dynamic types, and the real `player` keyword

Reported directly against real play: pressing E on `GSBrokenSMG` (a real `ACTI` in
`GSDocMitchellHouse`) did nothing — because `game.gd`'s `_try_interact()` only ever calls
`target.activate()` directly, and `DoorNode` is the only real type with one. `OnActivate` never ran
for anything else, script or no script.

Fixed scoped narrowly, sidestepping the door outcome-propagation gap entirely: `_try_interact()`
now dispatches `OnActivate` via `ScriptEngine` for any scripted target that does **not** have its
own `activate()` — mutually exclusive with the door branch, so door behavior is completely
untouched (still calls `activate()` directly, unconditionally, same real gap as before). This is
real and sufficient for every non-door Dynamic type (`CONT`/`ACTI`/`FURN`/`TACT`/`TERM`/`MSTT`),
which never had any interact path at all before this, script or otherwise.

**Two more real bugs found chasing this end-to-end, both from the same root cause**: once
`ShowMessage`'s argument fix let unresolved names carry real values into comparisons, `IsActionRef
player` (real code in `GSBrokenSMGScript`'s own `OnActivate`) hit the exact same GDScript
`String`-vs-`Object` `==` crash the earlier `String`-vs-`int` fix didn't cover — confirmed directly
(`"Invalid operands 'String' and 'Object'"`), and worse, the crash left the test process hung
rather than exiting, since nothing downstream of the crash point ran. Fixed by promoting
`_safe_equal()` from `ScriptInterpreter` to a shared `ScriptExecutionContext.safe_equal()` static
(the natural home — already hosts `is_truthy()`, the same kind of script-value-semantics helper),
used by both the interpreter's own `==`/`!=` and `IsActionRef`'s registered function.

Second: even with that fixed, `IsActionRef player` would still always resolve false, because
`"player"` just stayed an unresolved name string — this interpreter has no way to know it's
supposed to mean anything special. Real Gamebryo/GECK treats `player` as a genuine global keyword,
always resolving to the actual player reference — distinct from `ScriptExecutionContext.action_ref`
(whichever reference triggered the *current* event, which isn't always the player — an NPC's own
`OnTriggerEnter` might not be). Fixed: `ScriptEngine.player_node` (set once by `game.gd` from its
own `_find_character_body()`) propagates onto every dispatched context's new `player_node` field;
`ScriptInterpreter`'s `"name"` case special-cases the literal keyword `player` (case-insensitive) to
resolve it instead of returning the raw string. This is the one and only GECK keyword this
interpreter special-cases — every other bare reference still stays an unresolved name, a real,
documented, unchanged gap.

**Deliberately not exercised via the real interact path in the automated test suite** — same
`OS.alert()` hang-risk reasoning as `ShowMessage` itself: driving a real raycast interact against
`GSBrokenSMG` would genuinely trigger `ShowMessage` (now that `IsActionRef player` can actually
resolve true), which is exactly the non-deterministic blocking behavior already ruled out of
automated tests. `test_script_interpreter.gd` covers `player_node`/`action_ref` resolution directly
against a synthetic script instead — real coverage of the resolution logic without touching
`OS.alert()`.

## A third `String()`-family crash, and a full sweep

Reported directly against real play (world loading, and the "SPECIAL machine"): `is_truthy: Invalid
call. Nonexistent 'bool' constructor.` Same root cause as the two crashes above, a third strict
GDScript type constructor: `bool(value)` throws for a String (a `"name"` node's own unresolved-ref
literal reaching a bare `if (SomeUnresolvedRef)` truthiness check) instead of converting it, exactly
the way `String()` and `==` already turned out to. Fixed: `ScriptExecutionContext.is_truthy()` now
checks types explicitly (String/int/float/bool/Node) instead of trusting `bool()`'s conversion to be
lenient — real language rule (0/empty/null is false, anything else is true) implemented directly
rather than delegated to a constructor that doesn't actually behave that way.

Given three real crashes from the same "strict constructor on an arbitrary runtime Variant" pattern,
swept the rest of `project/script_vm/` and `addons/script_viewer/` for the same shape rather than
waiting for a fourth real-play report. Every other `String()` call turned out safe on inspection —
they all operate on AST **metadata** fields (`blocktype`/`kind`/`name`/`op`/`reference`), which the
parser already guarantees are real Strings via `str()` (the earlier fix), or on native `EsmReader`
binding results, which are always genuine `String` from the C++ side. The one genuine remaining risk
found this way: `ShowMessage`'s own `String(a[0])` — `a[0]` is a runtime-**evaluated** argument
value (any type, depending on what expression produced it), not metadata, so it had the exact same
exposure as the two fixed bugs even though nobody had hit it yet. Fixed to `str(a[0])` preemptively.
**The general lesson, worth keeping in mind for every future registered function**: GDScript's
`String()`/`bool()` type constructors are not the lenient, "convert anything" operations they look
like — `str()` is; reach for `str()`, never `String()`/`bool()`, when converting an arbitrary
runtime-evaluated script value (as opposed to a parser-guaranteed-String AST field).

## Editor tooling: `addons/script_viewer/` (a real `EditorPlugin`, not just an open scene)

A read-only script inspector: search/browse every real script by editor ID, see its actual `SCTX`
source with every function call color-coded by whether `script_function_registry.gd` implements
it, Ctrl+Click an implemented call to jump straight to its registration
(`EditorInterface.edit_script()`). Reuses the exact same lex/parse/registry pipeline
`script_engine.gd` runs at real game time — never a parallel bespoke text scan that could silently
drift from what the interpreter actually does, and never writes anything (no save path exists at
all here, not even disabled).

**Real correction mid-build, worth recording**: this started as a plain `@tool` scene
(`nif_viewer.gd`/`interior_viewer.gd`'s own "just open the scene, no Play needed" convention) —
wrong for this specific case. That convention works for those two because interacting with their
3D viewport (selecting built nodes, reading Transform in the Inspector) is native editor
node-selection behavior. A scene merely *open* in the 2D viewport is in node-editing mode: clicks
there select/move nodes and never reach a Control's own input handling (the search `LineEdit`,
`ItemList` selection, `RichTextLabel`'s `meta_clicked`) — real interactivity needs either Play mode
or a genuine editor panel. Play mode was also ruled out: `EditorInterface` (the jump-to-code
feature's whole mechanism) only exists for code running *inside* the editor process, and a
Play-mode scene is a separate process entirely — no combination of scene-open-only or Play-mode
gets both real clicks and `EditorInterface` access at once. Fixed by making it a proper
`EditorPlugin` (`addons/script_viewer/plugin.cfg`/`plugin.gd`) with `_has_main_screen() = true`,
docked as a real top-tab-row screen (alongside 2D/3D/Script/AssetLib) via
`EditorInterface.get_editor_main_screen().add_child(...)`, enabled through
`project.godot`'s `[editor_plugins]`. `script_viewer.gd`/`.tscn` itself moved into
`addons/script_viewer/` (self-contained, matching `addons/fpc/`/`addons/terrain_3d/`'s own
convention) but needed no logic changes — the plugin is a thin wrapper around the exact same
Control that already existed.

**Second correction, same tool**: `SourceDisplay` started as a `RichTextLabel` with hand-built
BBCode spans (needing exact source character offsets threaded through the lexer/parser just to
wrap the right substring in `[color]`/`[url]` tags) and a `meta_clicked` handler manually checking
`Input.is_key_pressed(KEY_CTRL)`. Switched to `CodeEdit` instead — it ships the exact UX this tool
needs natively: `symbol_lookup_on_click` handles Ctrl-gating, word-boundary detection, and
hover-underline feedback all on its own (`symbol_validate`/`symbol_lookup` signals), and a
`CodeHighlighter` colors by keyword text, not by position, so the source offset plumbing turned out
to be unnecessary and was reverted out of the lexer/parser (kept `start`/`end` on lexer tokens
themselves — cheap, general, real potential future use for e.g. a debugger mapping a breakpoint
line to source — but dropped the parser's now-dead `name_start`/`name_end`, which existed only for
this). `_source_display.editable = false` keeps it genuinely read-only. Verified against the full
2,576-script corpus (still 0 crashes) plus `test_script_viewer.gd` exercising call-name collection
(including same-script, different-casing call sites — real, since the language is
case-insensitive) and registration-line lookup headlessly (the tool's own UI/`EditorInterface`/
`CodeEdit` symbol-lookup pieces only make sense inside a running editor, so the test calls the
underlying pure functions directly, bypassing the `Engine.is_editor_hint()`-gated `_ready()`).

## Acceptance criteria

- [x] `get_script_data()` matches real, hand-verified ESM bytes for a real script.
- [x] `script_form_id` resolves for real, placed `ACTI`/`CONT`/etc. REFRs.
- [x] Lexer/parser/interpreter round-trip a real script's own source text correctly (locals,
      blocks, statements, the exact call/arg shape).
- [x] Arithmetic/comparison/logical operator precedence matches conventional (C-like) precedence
      — real GECK operator precedence isn't independently confirmed against a documented source,
      flagged as an assumption in `script_parser.gd`, not a confirmed fact.
- [x] An unimplemented function call never crashes the interpreter.
- [x] `Enable`/`Disable`/`Activate` correctly call into this project's own existing systems.
- [x] Full existing regression suite has no new failures.
- [x] Lexer/parser proven against the ENTIRE base-game script corpus (2,576 real scripts), not
      just a hand-picked sample — found and fixed two real crashes a small sample missed.
- [x] Real scripts register, resolve locals, and dispatch `OnLoad`/`GameMode` through the actual
      live construction path (`object_registry.gd`'s `_finalize()`), verified via a real
      `game.tscn` headless boot loading `GSDocMitchellHouse` and `test_script_engine_integration.gd`.
- [x] A real function backed by a real system, not a stub: `ShowMessage` resolves a real `MESG`
      record and shows its actual text (`OS.alert()`) — found and fixed two real bugs
      (`_parse_ident_primary()`'s call-vs-name ambiguity, `==`'s Variant type-mismatch crash) along
      the way, neither caught by any earlier test.
- [x] `OnActivate` dispatch for every non-door Dynamic type (`CONT`/`ACTI`/`FURN`/`TACT`/`TERM`/
      `MSTT`) — reported directly against real play (pressing E on `GSBrokenSMG` did nothing),
      fixed scoped narrowly to sidestep the door outcome-propagation gap entirely (still open,
      door-specific, see "Explicit non-goals").
- [x] The real `player` GECK keyword resolves to the actual player character, not an unresolved
      name — the one and only such keyword this interpreter special-cases.
- [ ] A real script observed running correctly in interactive play, not just a headless boot (needs
      a human to actually walk into the cell, press E on `GSBrokenSMG`, and confirm the real
      `ShowMessage` dialog actually appears — everything upstream of that is now verified, but the
      final "does it actually work when you play it" step is real and still open).
