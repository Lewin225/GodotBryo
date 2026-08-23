# New Vegas Script Interpreter — Design Notes

The last piece of the data model, and the one that actually runs the game: every `SCPT` record,
every object/quest/effect script, every `OnActivate`/`OnDeath`/`GameMode` block. Sourced from
`enginedocs/GeckWiki/scripting/` (17 saved pages) plus direct inspection of the real
`FalloutNV.esm` binary — the central architectural claim below is verified against real record
bytes, not assumed from the wiki text alone.

## The load-bearing finding: don't decode Bethesda's bytecode

A compiled `SCPT` record carries several subrecords. Read byte-for-byte from a real record in this
project's own `FalloutNV.esm` (`VLCSafetyTrigger01SCRIPT`, chosen at random):

```
EDID  25   "VLCSafetyTrigger01SCRIPT"
SCHR  20   refCount, compiledSize, lastIndex, scriptType, scriptFlags
SCDA  400  <compiled bytecode — Bethesda's own proprietary VM format>
SCTX  1268 "scn VLCSafetyTrigger01SCRIPT\r\n\r\nRef ActivatorREF;\r\n\r\nBEGIN OnTriggerEnter\r\n..."
SLSD  24   local variable slot 1 (index, type flags)
SCVR  13   "ActivatorREF" — that slot's name
SCRV  4    which SLSD slot this SCRO entry resolves for
SCRO  4×8  FormIDs referenced by name in the script text
```

`SCTX` is the **original, human-readable source text** — not a debug-only extra, present and
complete on every one of the 11,483 scripts sampled directly across the whole ESM (a full scan of
every `SCTX` subrecord in the file, not a handful of spot checks). `SCDA`, the actual compiled
bytecode Bethesda's own runtime executes, is also present — but there is no reason to ever decode
it. **The interpreter this project builds should tokenize and parse `SCTX` directly, the same way
the GECK's own compiler did, and never touch `SCDA` at all.** Reverse-engineering a proprietary
bytecode VM buys nothing when the actual source is sitting right next to it in every record, already
in a syntax fully documented by the GECK Wiki.

`SLSD`/`SCVR` and `SCRO`/`SCRV` are worth keeping too, even though they're derivable by parsing
`SCTX` yourself: they're Bethesda's own **pre-resolved symbol table** for that script. `SCVR` names
each local variable slot; `SCRO` lists the concrete FormIDs any named reference/quest/global the
script text mentions actually resolves to, cross-indexed via `SCRV`. A hand-rolled parser has to
resolve `ActivatorREF` or a quest editor ID against the whole ESM's namespace at parse time — the
compiler already did that resolution once and left the answer in the record. Using it sidesteps a
whole class of "which of several same-named editor IDs did the original author mean" ambiguity for
free.

## What a script actually is: three flavors, one grammar

Every script (except a bare **Result script** fragment, which has no `ScriptName` or blocks at
all — just a snippet of code run once, e.g. a dialogue `INFO`'s result script) declares its type at
compile time, and the type gates which block types and calling conventions are legal:

| Flavor | Attached to | Reference script? | Notable rule |
|---|---|---|---|
| **Object** | NPCs, Creatures, Activators, any form that can have a reference | Yes | Runs even for disabled references; `GameMode`/`MenuMode` fire every frame, no configurable delay |
| **Quest** | `QUST` records only | No | Not tied to any single reference — can't use implicit-reference or reference-specific block types; has its own configurable **script processing delay** (default 5s, can go as low as effectively-every-frame) |
| **Effect** | Base Effect (`MGEF`) via Actor/Object Effect or an Ingestible | Yes, but on the *target*, not the scripted form | Limited to exactly three block types: `ScriptEffectStart`/`ScriptEffectUpdate`/`ScriptEffectFinish`; variables can't be accessed remotely, since the "owner" is really the effect, not a placed reference |

"Reference script" vs. "non-reference script" is the single most consequential distinction in the
whole language, because it decides whether a function call needs an explicit target:

```
GetFactionRelation player          ; implicit — only legal in a reference script; means "thisReference.GetFactionRelation player"
LucasSimmsRef.GetFactionRelation player   ; explicit — legal anywhere, always names the reference
```

A **Quest** script can never use the implicit form (it isn't attached to any reference at all), so
every reference-function call in a quest script must be spelled out explicitly — either via a
persistent reference's own EditorRefID, or via a local `ref` variable holding one.

Mapped onto this project's own class hierarchy (`nv_class_hierarchy.md`): an Object script's
"calling reference" *is* the `GamebryoReference`/`GamebryoObject`/`GamebryoActor` node the script is
attached to — implicit calls resolve to `self`, exactly the way `game.gd`'s interact raycast already
resolves `collider` to the node it calls `activate()` on. A Quest script's execution context has no
such `self` at all; it's the `Resource`-based, never-a-Node case already called out in that document
— its calling references always come from a local `ref` variable or an explicit EditorRefID lookup,
never an implicit target.

## Variables: three primitive types, four storage tiers

```
int   varName    ; alias: short, long — all three are identical, 32-bit signed
float varName    ; single precision
ref   varName    ; a FormID — either a Reference or a Base Form (see below)
```

(NVSE adds `string_var`/`array_var` on top of this — real, but a stretch goal, not part of the
vanilla-compatible core; see Scope, below.)

Declaration must precede first use, at the top of the script, before any block — same restriction as
GDScript's own top-of-class `var` convention, so this maps cleanly onto however the interpreter ends
up representing a script's local variable table. No two variables in one script may share a name,
and a variable can't shadow any form's own EditorID.

Storage has four distinct tiers, each with a different resolution rule and a different natural home
in this project's own data model:

| Tier | Syntax | Lifetime / access rule | Maps to |
|---|---|---|---|
| **Local** | `myVar` | Script-instance-private; a different value per Reference running the same Object script | A field on the interpreter's per-instance execution context |
| **Cross-reference** | `MyRef.MyVar` | Only reachable if `MyRef` is a **persistent** reference | Looked up via the owning node's own local-variable table, same persistence requirement this project already enforces elsewhere (furniture references, per `Furniture - GECK.txt`) |
| **Quest-scoped** | `MyQuest.MyVar` | Survives the quest being stopped — "stopped" only halts script *processing*, the variable values are untouched | Lives on the `Quest` `Resource` from `nv_class_hierarchy.md`, not on any Node |
| **Global** | Global Variable form (`GLOB`) | Visible to every script/condition with no owner at all; **stored as float internally even when declared Short/Long**, so high-magnitude int comparisons (`if globalVar == 2000000001`) can silently fail after any arithmetic | A `Resource`-backed lookup table keyed by editor ID, per the "what never becomes a Node" rule |

`ref` deserves its own callout: a `ref` variable can hold **either** a live Reference or a bare Base
Form (e.g. `set MyWeapon to Weap10mmPistol`), and the two are not interchangeable — calling a
reference function through a `ref` holding only a Base Form is a real, documented crash risk, not a
theoretical one. The idiomatic vanilla guard is:

```
if IsFormValid rRef
    if IsReference rRef
        ; safe to use rRef as a calling reference
    endif
endif
```

The interpreter should make this a first-class runtime check on every implicit/explicit reference
call, not an opt-in the script author has to remember — a `ref` that dereferences to a Base Form
should fail the call cleanly (matching the language's real behavior: a script that calls a reference
function on something that isn't a reference **silently stops running**, not crash-loudly) instead
of the engine crash 1st-party GECK content occasionally risks.

## Grammar sketch

```
statement      := assignment | conditional | block | bare-call | comment
assignment     := ("set" IDENT "to" expr) | ("let" lvalue ":=" expr)   ; Let is NVSE, preferred when available
conditional    := "if" expr NEWLINE stmt* ("elseif" expr NEWLINE stmt*)* ("else" NEWLINE stmt*)? "endif"
block          := "begin" blocktype param* NEWLINE stmt* "end"
call           := [reference "."] funcname arg*      ; args separated by whitespace and/or comma
comment        := ";" .* NEWLINE                     ; block comments /* */ are xNVSE 6.2.1+, not vanilla
```

Operators, exactly as documented (no more, no fewer — **there is no switch/case** in this language,
by design, confirmed directly in the beginner tutorial):

```
Arithmetic:  +  -  *  /  %
Comparison:  ==  !=  >  <  >=  <=      ; always yield exactly 1 or 0
Logical:     &&  ||                     ; no native NOT or XOR — "A == 0" and "(A||B)-(A&&B)" are the idioms
```

Boolean coercion is the whole game's truthiness rule and it's simple: `0` (including an unassigned
`ref`) is false, anything else is true. A function documented as returning bool returns literal `1`
or `0`, storable in a plain `int`.

## Execution model

`Begin`/`End` blocks are **not** function definitions — they're the language's entire event
dispatch mechanism. Every frame, every loaded script's blocks are checked top-to-bottom in
declaration order; if a block's own condition (its blocktype + parameters) is currently true, its
body runs *that frame*, otherwise it's skipped, with no state carried between frames except whatever
the script itself stored in a variable. `GameMode`/`MenuMode` are the two "runs every frame,
unconditionally" blocktypes; everything else (`OnActivate`, `OnDeath`, `OnHit`, `OnTriggerEnter`,
...) is a real event gate.

Ranking every blocktype actually used across all 11,483 real scripts in `FalloutNV.esm` (not
guessed — counted):

```
GameMode          766      OnTrigger           138
OnTriggerEnter     750      SayToDone           136
OnActivate         545      OnStartCombat       116
OnDeath            453      OnTriggerLeave       87
OnLoad             340      MenuMode             60
OnAdd              212      ScriptEffectFinish   28
OnHit              199      OnCombatEnd          26
ScriptEffectStart  142      ScriptEffectUpdate   22
                            OnHitWith            19
```

`GameMode` alone dominates, which matters for the interpreter's own frame-loop integration: it needs
to hook the same per-frame cadence `WorldStreamer._process()` already runs on for streaming checks,
not a separate polling timer, or every resident scripted actor pays its own redundant per-frame
overhead. Quest scripts are the one exception — they run on their own configurable delay (`Quest
Data Tab`'s Script Processing Delay, default 5s, changeable live via `SetQuestDelay`), decoupled
from the object-script per-frame cadence entirely.

## The function library: a registry, not a rewrite of 488 signatures

The GECK Wiki catalogs 488 built-in functions in the base `Category:Functions (GECK)` page alone,
before NVSE/JIP/xNVSE extensions. Documenting all 488 here would be both incomplete (their pages
weren't part of this pass's saved set) and the wrong shape for an interpreter design doc — what
matters architecturally is that **this project already has the right pattern for this**:
`GamebryoObjectRegistry`'s `_factories` is a runtime-populated `String -> Callable` dictionary,
extended by calling `register()`, with zero compiled-in switch statement to grow. A script function
table is the exact same shape: `String -> Callable(args, context) -> Variant`, seeded with a small
core and extended incrementally, function by function, verified against real scripts the way every
other piece of this project has been.

**Real usage frequency**, not a guess, should drive which functions get built first — counted
directly across every script in the ESM, filtered to exclude keywords/blocktypes/obvious
project-specific reference names:

```
Tier 1 — build these first (each appears 400+ times across real scripts):
  SetObjectiveDisplayed   SetObjectiveCompleted   SetStage         GetStage
  Enable   Disable                                AddItem         RemoveItem
  AddScriptPackage        ShowMessage             MoveTo          GetDead
  GetObjectiveCompleted   GetObjectiveDisplayed   RewardXP        StartCombat
  SayTo                   Activate                RemoveFromFaction
  AddReputation           GameDaysPassed          ResetAI         GetItemCount
  SetActorValue (SetAV)   GetSecondsPassed        AddToFaction    GetDisabled
  SetEnemy                IsActionRef             GetRandomPercent
  MarkForDelete           Unlock                  GetLinkedRef
```

That's ~30 functions covering the large majority of real call sites in the actual game data — a
genuinely tractable first milestone, versus the 488-signature wall the raw function-list category
page presents. `GetContainer`/`GetIsReference`/`IsFormValid`/`IsReference` belong alongside them
even though they didn't rank in raw frequency, since the beginner tutorial and the reference-scripts
page both treat them as load-bearing safety idioms every other script leans on implicitly.

## Proposed pipeline

```
SCTX (plaintext, already in the ESM)
  → Lexer                  tokens: keywords, identifiers, numbers, operators, comments stripped
  → Parser                 AST: one ScriptDef per SCPT, blocks as a flat ordered list of (blocktype, params, stmts)
  → Symbol resolution       cross-check identifiers against SCRO/SCRV first, fall back to a live
                             editor-ID lookup only for names the compiler's own table didn't cover
  → Interpreter             tree-walking, not bytecode -- a per-instance ExecutionContext holds the
                             local variable table + a reference to the calling GamebryoReference/
                             GamebryoActor (or null, for a Quest script's non-reference context)
  → Frame integration        GameMode/MenuMode block bodies run once per already-existing frame tick
                             (piggybacking WorldStreamer's own cadence, not a second timer); Quest
                             scripts get their own SetQuestDelay-driven timer instead
```

Tree-walking over the parsed AST, not re-implementing a bytecode VM, matches both what the source
data actually gives us (real, readable `SCTX`, not opaque `SCDA`) and this project's own established
preference for working from verified source data over reverse-engineered binary formats everywhere
else in the codebase (the ESM/NIF/BSA readers are all real-format parsers, never black-box
reimplementations).

## How close to GDScript should this actually be?

Close in three specific ways, deliberately far in two others — not an all-or-nothing question.

**Close: implementation language.** Build the interpreter in GDScript, not C++. This project already
states its own split explicitly — heavy GDExtension for performance-critical work, GDScript for
game-logic glue (`direct_geometry_batch.h`'s own doc comment) — and FNV scripts are exactly the
glue-logic case: event-driven, mostly idle between frames, nothing like the tight per-vertex loops
that justified C++ for terrain/mesh work. A tree-walking GDScript interpreter is plenty fast here,
and far easier to debug and hot-iterate on than a hand-written C++ VM would be.

**Close: function dispatch.** Every built-in script function should be a real GDScript function,
registered by name in a `String -> Callable` table — the same pattern `GamebryoObjectRegistry`
already uses for `_factories`. `AddItem` calls into whatever inventory system exists; `Enable`/
`Disable` toggle the node the same way `CellStreamBuilder.set_collision_disabled()` already does;
`Activate` calls the same `activate()` contract `game.gd`'s interact raycast already uses. The
interpreter shouldn't reimplement game logic — it should look up and call the GDScript function that
already does.

**Close: data representation.** `int`/`float` map straight onto GDScript's own primitives; `ref` maps
onto either a Node reference or a plain form-ID `int` — no separate boxed-value wrapper type needed.

**Far: don't transpile to GDScript source and hot-compile it.** Tempting — parse FNV script, emit
`.gd` text, load it at runtime — and worth resisting. Godot's script compiler isn't a sandboxed
target, generated-code bugs are miserable to debug, and it gives up exactly the control this
interpreter needs: capping a runaway `While`/`ForEach` loop, enforcing the "silently stop, don't
crash" rule when a `ref` turns out to hold a Base Form instead of a Reference (see Variables, above),
single-stepping a block for a debug overlay. A real tree-walking interpreter over the project's own
parsed AST keeps all of that in reach.

**Far: don't hand-roll the expression grammar where a real Godot API already does the job.** Godot
ships an `Expression` class built for exactly this — runtime-evaluated arithmetic/comparison/logical
expressions with named variable bindings, confirmed present in this project's own Godot version
(`native/godot-cpp/gen/include/godot_cpp/classes/expression.hpp`):

```
Error   Expression.parse(String expression, PackedStringArray input_names = [])
Variant Expression.execute(Array inputs = [], Object base_instance = null, ...)
```

Use it for the *leaf* expressions inside `if`/`set` — not the whole script. It has no concept of
`Begin`/`End` blocks, and FNV's own space-separated, no-parens call syntax (`AddItem Caps001 10`)
isn't valid `Expression` syntax either, so the project's own parser still owns control flow and
statement-level function calls. `Expression` just removes the need to hand-write an
operator-precedence parser for the arithmetic/comparison sub-expressions that appear inside them.

## Explicit non-goals for a first pass

- **NVSE arrays/strings/lambdas/`Let`/`ForEach`/User Defined Functions.** Real, and eventually
  worth having (much of the modding-era ecosystem assumes them), but they're an extension layer on
  top of the vanilla grammar above, not required to run Bethesda's own base-game scripts — the
  11,483 scripts sampled are all vanilla-syntax `SCTX`.
- **Console-only functions** (`Category:Designer Debug Tools`' 38 commands, plus the broader
  console-function set) — these never appear in `SCTX` bodies at all; they're a separate REPL-style
  surface, not part of the script interpreter proper.
- **All 488 catalogued functions up front.** Build the real-usage Tier 1 list above, verify each one
  against actual `SCTX` call sites the way `Category:Functions (GECK)`'s own text specifies them,
  and grow the registry the same incremental way `object_registry.gd` already grows its factory
  table — not a single 488-function push.
- **Decoding `SCDA`.** Called out once above, worth repeating as an explicit non-goal rather than
  just an omission: there is no reason to ever touch it.
