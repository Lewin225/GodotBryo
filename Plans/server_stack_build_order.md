# Server Stack Build Order

Sequenced plan for `pread` → ArchiveServer → TextureServer → NifServer. One stage at a time, each
gated behind a real test that runs against the shipped game data.

Supersedes the sequencing in [`NifServer/nif_server_v1_build_order.md`](NifServer/nif_server_v1_build_order.md).
Per-server contracts stay where they are: [ArchiveServer](archive_server.md),
[TextureServer](texture_server.md), [NifServer v2](NifServer/nif_server_v2.md).

---

## Index

| # | Stage | Gate |
|---|---|---|
| [0](#0-working-agreement) | Working agreement | — |
| [1](#1-starting-state-verified) | Starting state, verified | — |
| [2](#stage-a-pread-in-bsa_archive) | Stage A — `pread` in `bsa_archive` | `servers/test_bsa_concurrent` |
| [3](#stage-b-archiveserver) | Stage B — ArchiveServer | `servers/test_archive_server` |
| [4](#stage-c-textureserver) | Stage C — TextureServer | `servers/test_texture_server` |
| [5](#stage-d-nifserver-native-nifly-binding) | Stage D — NifServer native (nifly binding) | `servers/test_nif_source` |
| [6](#stage-e-nifserver-gdscript) | Stage E — NifServer GDScript | `servers/test_nif_server` |
| [7](#7-test-conventions) | Test conventions | — |

---

## 0. Working agreement

Six rules, each derived from a specific fault in the first NifServer attempt. They exist to be
checkable, not aspirational.

| # | Rule | Fault it prevents |
|---|---|---|
| 1 | **Allowlist.** Each stage below names the modules it may use. Using anything else requires stopping and saying so **before** writing the code, not in the summary afterwards. | The first build silently consumed `nif_loader.cpp`/`NifReader`, which appears nowhere in v2, and inherited its limits. |
| 2 | **Premise check.** Each stage begins by running its stated verification command and reporting the actual output. A prerequisite is never assumed done. | `pread`, ArchiveServer and TextureServer were all assumed complete. None existed. |
| 3 | **Run early.** The first executable slice of a stage runs before the rest is written — a stub that loads one real file and prints one real number. | Four bugs (entry-path lookup, illegal escape character, wrong dict key, float-vs-Vector3) surfaced only after everything was written. |
| 4 | **Gate.** A stage does not start until the previous stage's test prints `ALL CHECKS PASSED` and exits `0`. No exceptions for "it obviously works". | v2 §15's gates went unrun until prompted. |
| 5 | **Deviations are written down first.** Any departure from the spec is recorded in that server's doc *before* the code merges, with the reason. | `_build()` decoding textures inline contradicts v2 §4 and went unmentioned until asked. |
| 6 | **Attribute limits correctly.** When reporting a limitation, state whether it is a property of the data, of nifly, or of a choice I made. | Consequences of my own implementation choice were reported as facts about the codebase. |

**Escape hatch, used out loud:** if a stage turns out to need something outside its allowlist, that
is a finding worth surfacing — say so, propose the change, and get agreement before proceeding.

---

## 1. Starting state, verified

Checked at time of writing, not assumed:

| claim | reality | evidence |
|---|---|---|
| `pread` patch done | **no** | `bsa_archive.cpp` uses `fseek`+`fread` in `read_at()` (lines 176/180); file untouched since the initial commit |
| ArchiveServer exists | **no** | nothing under `project/GodotBryo/Servers/` but the prototype below |
| TextureServer exists | **no** | same |
| nifly reads everything needed | **yes** | 25,760/25,760 files, 0 failures, 0 uninstantiable blocks (`tools/nif_xcheck/`) |
| `nif_loader.cpp` suffices for v2 | **no** | exposes 3 of 6 texture slots and no node block type; see NifServer v2 §3 |

**The earlier prototype** was moved to `project/experimental/nif_server_prototype/` (2026-09-12,
after Stage C) and is not live code: nothing references it and it is not an autoload. It was built
against `NifReader`/`nif_loader.cpp`, which cannot express §3, §5.3, §6, §7.3, §7.4 or §8 of
nif_server_v2. Its `nif_archive_source.gd` and inline texture decode are superseded outright by
ArchiveServer and TextureServer. Stage E reuses its contract layer (threading, budget, cache,
delivery, name mapping, named binds, `flatten_static`) from there; see that folder's `STATUS.md`.

---

## Stage A: `pread` in `bsa_archive`

**Goal:** concurrent `read_at()` on one open archive is safe by construction, so no mutex is needed
anywhere above it.

**May use:** `native/src/bsa/*`, `native/src/common/byte_reader.h`, zlib, platform headers.
**Must not touch:** anything else.

| # | Work |
|---|---|
| A1 | Replace the shared-cursor `fseek`+`fread` in `BsaArchive::read_at()` with `pread()` (POSIX) / `ReadFile` + `OVERLAPPED` (Windows), behind a small platform shim. |
| A2 | Keep the open/index path as-is — it runs once, single-threaded, before any concurrency. |
| A3 | Platform-specific error reporting: short reads, EINTR retry, offset past EOF. |

**Prerequisite check:** `grep -n "fseek\|pread\|ReadFile" native/src/bsa/bsa_archive.cpp`

**Build:** `cd native && scons platform=linux target=template_debug api_version=4.7 use_static_cpp=no disable_exceptions=no -j$(nproc)`

**Gate — `project/tests/servers/test_bsa_concurrent.tscn` must prove:**

- serial extraction of N representative entries returns byte-identical data to before the patch
- **concurrent** extraction of the same N entries from one `BsaReader`, across `WorkerThreadPool`
  tasks, is byte-identical to the serial result
- coverage includes a compressed entry, an uncompressed entry, an embedded-name archive, a
  zero-length entry, and a past-EOF offset
- a missing path and a malformed archive produce distinguishable errors

---

## Stage B: ArchiveServer

**Goal:** one owner of archive discovery, priority and byte reads. Spec: [archive_server.md](archive_server.md).

**May use:** Stage A's `BsaArchive`, new native catalog code, a thin GDScript autoload.
**Must not use:** `mesh_resolver.gd`, `resolve_bytes()`, `nif_loader.cpp`, `NifReader`.

| # | Work |
|---|---|
| B1 | Native immutable catalog: opens every archive once, owns BSA priority and the normalized `path → (archive, entry)` index, with prefix enumeration using the same winner rule. |
| B2 | Path canonicalisation in one place: `\`→`/`, lowercase, single `meshes/` handling. |
| B3 | Thin GDScript autoload owning configuration and lifecycle only; register in `project.godot`. |
| B4 | Open and index before accepting requests; catalog immutable thereafter. |

**Prerequisite check:** Stage A gate green.

**Gate — `project/tests/servers/test_archive_server.tscn` must prove:**

- every BSA in the real `Data/` opens, or reports a specific initialisation failure
- the priority winner matches the current resolver's for a **full entry census**, not a sample
- concurrent and serial reads agree byte-for-byte for NIF, DDS and WAV paths
- both `meshes\Foo.NIF` and `Foo.nif` resolve to one identity
- missing path, malformed archive, decompression failure and zero-length data are distinguishable
- no lazy opening and no catalog mutation from a worker

---

## Stage C: TextureServer

**Goal:** the project's one DDS decode/upload/cache primitive. Spec: [texture_server.md](texture_server.md).

**May use:** ArchiveServer, Godot `Image`/`ImageTexture`.
**Must not use:** `mesh_resolver.gd`'s texture cache, `nif_loader.cpp`, `NifReader`.

| # | Work |
|---|---|
| C1 | `warm(path, alpha_safe)` — thread-safe, marshals its own enqueue, returns immediately. |
| C2 | `is_finished(path, alpha_safe)` — finished covers success **and** failure; not "ready". |
| C3 | `request(path, alpha_safe)` — returns the cached usable texture or `null` for terminal failure. |
| C4 | Worker decode, main-thread upload on its own budgeted queue; in-flight deduplication. |
| C5 | Cache key carried over unchanged from the existing resolver; stats surface. |
| C6 | Decide and record `alpha_safe` ownership (texture_server.md "Not decided yet"). |

**Prerequisite check:** Stage B gate green.

**Gate — `project/tests/servers/test_texture_server.tscn` must prove:**

- a real DDS decodes and uploads, and the second `request()` for it returns the cached texture without re-decoding
- a failed texture is *terminally finished*, never a permanent blocker
- N concurrent `warm()` calls for the same path produce exactly one decode
- uploads stay within the configured per-frame budget under a backlog
- `warm()` from a `WorkerThreadPool` task does not mutate queue state on that thread
- decoded output matches the current resolver's for a representative set (byte or hash comparison)

---

## Stage D: NifServer native (nifly binding)

**This stage is the correction of the first attempt's central fault and is not skippable.**

**Goal:** a native reader exposing nifly's object model — the model every v2 measurement was taken
from — rather than `nif_loader.cpp`'s pre-digested summary.

**May use:** nifly, ArchiveServer, `native/src/common/*`.
**Must not use:** `nif_loader.cpp`, `NifReader`, `mesh_resolver.gd`. This is a **new** native module;
the legacy loader is left untouched and still serves its existing callers.

| # | Must expose | v2 § it unblocks |
|---|---|---|
| D1 | per-node **block type** plus name, parent, local transform | §3 node map — without this every node is a `Node3D` |
| D2 | collision object subclass (`bhkCollisionObject` / `bhkBlendCollisionObject` / `bhkSPCollisionObject`) | §5.3 ragdoll split |
| D3 | all **6** `BSShaderTextureSet` slots | §8 |
| D4 | `NiDefaultAVObjectPalette` entries | §6 resolution order |
| D5 | per-shape property refs with **block identity** (for sharing) | §7.3 fan-out |
| D6 | `ControllerLink` including `stringPaletteRef` + offsets, resolved | §7.4 |
| D7 | `NiObjectNET` extra-data blocks | §5.3 metadata bucket |
| D8 | geometry, skin (names + binds), morph, collision shapes and bodies | §5, §9 |

**Prerequisite check:** Stage C gate green; `grep -rn "GetBlockTypeStringById" native/nifly/include/BasicTypes.hpp`.

**Gate — `project/tests/servers/test_nif_source.tscn` must prove, against real files:**

- block type is reported for every scene node — `skeleton.nif` yields `NiCamera`, `NiTriShape` and `NiNode` distinctly
- `skeleton.nif` reports `bhkBlendCollisionObject`; `barracks01.nif` reports `bhkCollisionObject`
- a known env-mapped mesh reports non-empty slots 4 and 5
- `nvdlc04uskydome.nif` reports its 2 palette entries including the aliasing one
- `eatidle.kf` yields **non-empty** target names for all 33 controlled blocks
- a shared `NiMaterialProperty` reports the same block identity from each referencing shape
- vertex counts and transforms match `tools/nif_xcheck/` output for a fixed sample

---

## Stage E: NifServer GDScript

**Goal:** [NifServer v2](NifServer/nif_server_v2.md), on the Stage D source.

**May use:** Stage D native reader, ArchiveServer, TextureServer, and the existing prototype's
contract layer.
**Must not use:** `NifReader`, `nif_loader.cpp`, `mesh_resolver.gd`.

| # | Work |
|---|---|
| E1 | Bring the contract layer back from `project/experimental/nif_server_prototype/`, sourcing from Stage D. Its archive and texture code stays behind: ArchiveServer and TextureServer replace both. |
| E2 | Replace the inline texture decode with `warm()`/`is_finished()`/`request()`; `_build()` never calls `create_from_image()`. |
| E3 | Implement the §3 node map now that block type exists — `MeshInstance3D`, `GPUParticles3D`, `Camera3D`, `OmniLight3D`, `Node3D`. |
| E4 | Implement §5.3: ragdoll as `PhysicalBone3D` under an inert `PhysicalBoneSimulator3D`; extra data as node metadata; billboard mode onto descendant materials. |
| E5 | Implement §6 resolution order including palette aliases. |
| E6 | Stamp source property-block identity per node for the §7.3 fan-out. |
| E7 | Fix the ownership safety net: the unparented check must be deferred, not synchronous — the current version frees the node under a caller that parents a line later. |
| E8 | Keep as-is: threading split, admission, budget, cache identity, canonical paths, name mapping, named skin binds, `flatten_static`. |

**Prerequisite check:** Stage D gate green.

**Gate — `project/tests/servers/test_nif_server.tscn` must prove:**

- **parity** against `mesh_resolver` for a fixed corpus sample: vertex counts, indices, world transforms, material texture paths, collision descriptors, skin bind names
- hierarchy and `flatten_static` place every mesh identically (already passing: 0.000000 m across 10 meshes)
- a light NIF yields `OmniLight3D`, a camera NIF `Camera3D`, a particle NIF `GPUParticles3D`
- `skeleton.nif` yields `PhysicalBone3D` under a simulator that is **not** simulating
- name escape round-trips for every authored name in the sample, including duplicates
- `_build()` calls stay within `builds_per_frame_budget` under a backlog of 100 requests
- concurrent resolves show no shared-cursor, cross-thread RID or deferred-callback failure
- a callback that parents on the next frame is not freed underneath

---

## 7. Test conventions

Follow `project/tests/README.md` exactly: a `test_*.gd` / `test_*.tscn` pair, `check(cond, msg)`
printing `  OK  ` / `  FAIL `, ending in `ALL CHECKS PASSED` or `FAILURES: N`, exiting `0` / `1`,
running against real shipped data — no mocks, no synthetic fixtures.

```
cd project
../tools/Godot_v4.7.1-stable_linux.x86_64 --headless --path . tests/servers/test_<name>.tscn
```

A stage is complete when its own test passes **and** the full headless suite still passes:

```
cd project
GODOT="../tools/Godot_v4.7.1-stable_linux.x86_64"
for t in $(find tests -name 'test_*.tscn' | sort); do
  [ "$t" = "tests/test_exterior_cell.tscn" ] && continue
  echo "### $t ###"
  timeout 150 "$GODOT" --headless --path . "$t" 2>&1 | grep -E "FAIL|ALL CHECKS|FAILURES"
done
```

New `class_name` scripts need one editor import pass before `--script` can resolve them:
`--headless --path project --editor --quit-after 40`.
