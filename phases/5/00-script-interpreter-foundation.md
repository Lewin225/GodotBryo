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

## Explicit non-goals for this milestone

Matches `enginedocs/nv_script_interpreter_design.md`'s own "Explicit non-goals for a first pass"
list, narrowed further to what's actually runnable today:

- **Every "Tier 1" function from the design doc's own ranked list.** Most (`AddItem`, `SetStage`,
  `AddToFaction`, `StartCombat`, ...) depend on inventory/quest/faction/AI systems that don't exist
  in this codebase yet. Building those now would balloon this milestone into all of Phases 5–7 at
  once — grow the registry the same incremental way `object_registry.gd` already grows its own
  factory table, function by function, as the backing systems land.
- **Wiring `ScriptEngine`/`script_form_id` into `object_registry.gd`'s actual construction paths.**
  `script_form_id` is extracted and tested, and `ScriptEngine` is a real, tested, standalone class
  — but no `DoorNode`/`ContainerNode`/etc. factory calls `register_scripted_node()` yet. Real,
  deliberate: this class needed to be provably correct on its own first (see Tests above) before
  wiring it into the live construction path where a bug would be much harder to isolate.
- **Piggybacking `WorldStreamer`'s own frame cadence.** The design doc's stated goal; not done
  this pass — `ScriptEngine` runs its own `_process()` instead (still one real per-frame tick, just
  not literally the same call site). Touching `world_streamer.gd` itself is deferred to the
  integration step above.
- **Cross-reference (`OtherRef.Var`) reads/writes, `SCRV`-based symbol resolution, Quest/Effect
  script types, block params (e.g. `OnTrigger Play` vs. plain `OnTrigger`), NVSE syntax
  (`Let`/arrays/strings/`ForEach`).** All real, all logged as gaps at the exact point they'd
  matter (see the class/function doc comments), none guessed at.

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
- [ ] A real script actually observed running correctly in play (needs the object_registry.gd
      integration step from Explicit non-goals first — out of scope for this milestone).
