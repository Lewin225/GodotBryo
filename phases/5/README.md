# Phase 5 — Scripting VM

Parent: [ROADMAP.md](../../ROADMAP.md)

Goal (per ROADMAP.md): the base game's scripted behavior (quest state machines, triggers,
scripted objects) executes correctly — the largest single undertaking after world streaming.

**Started 2026-08-23, in parallel with the remaining Phase 3 work** (player controller
integration), not sequentially after it — nothing in this phase depends on Phase 3/4 landing
first, and the design work below was already done (`enginedocs/nv_script_interpreter_design.md`,
`enginedocs/nv_class_hierarchy.md`) before this phase's first task file existed.

**ROADMAP.md's own assumption for this phase — reverse-engineering Bethesda's compiled `SCPT`
bytecode format — is wrong, and disproven with real data.** Every one of the 11,483 real `SCPT`
records in `FalloutNV.esm` carries `SCTX`, the complete original GECK source text, alongside the
compiled bytecode (`SCDA`). This project parses and tree-walks `SCTX` directly and never decodes
`SCDA` — see `enginedocs/nv_script_interpreter_design.md`'s "load-bearing finding" for the full
real-data case.

## Sub-tasks

| # | Task | File |
|---|------|------|
| 5.0 | Script interpreter foundation — native SCPT extraction, lexer/parser/tree-walking interpreter, a small real-system-backed function registry, proven end-to-end against real ESM scripts | [00-script-interpreter-foundation.md](00-script-interpreter-foundation.md) |
