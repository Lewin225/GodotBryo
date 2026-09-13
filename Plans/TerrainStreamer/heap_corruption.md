# terrain_streamer: heap corruption on shutdown

A standalone brief. Everything needed to start is here; nothing depends on the session that found it.

**Status:** open, unassigned. Not yet investigated — this is the report, not a diagnosis.

---

## Symptom

Six test scenes abort with exit status `134` (`SIGABRT`). They have been failing for some time and
were previously assumed to be a generic "Godot moans on exit" nuisance. They are not: glibc is
aborting because **the heap is corrupt**.

```
#3  __libc_message_impl.cold
#4  malloc_printerr
#5  _int_free_merge_chunk
#6  _int_free_chunk
#7  libterrain_streamer.linux.template_debug.x86_64.so + 0x21d01
#8  libterrain_streamer.linux.template_debug.x86_64.so + 0x1341c
#9  libterrain_streamer.linux.template_debug.x86_64.so + 0x126c7
#10 Godot_v4.7.1-stable_linux.x86_64 + 0x44ba7b8
```

`malloc_printerr` from `_int_free_chunk` is glibc's "this chunk's metadata is wrong" path. The write
that corrupted it happened **earlier and elsewhere**; the free is only where it is detected. The
faulting frames are inside our own first-party library.

The three `.so` offsets are byte-identical across every occurrence, so it is one deterministic code
path, not a race with varying shape.

## Affected scenes

All under `project/tests/`, run via `./run_tests.sh`:

- `test_terrain_streamer_phase1.tscn`
- `test_terrain_streamer_phase2_stress.tscn`
- `test_terrain_streamer_phase3_completion.tscn`
- `test_terrain_streamer_phase3_object_budget.tscn`
- `test_terrain_streamer_phase4_retention.tscn`
- `test_terrain_region_stager.tscn`

Each prints its checks and then aborts, so the assertions pass and the crash is at teardown. The
runner correctly reports them as failures.

## Reproduce

```bash
cd project
../tools/Godot_v4.7.1-stable_linux.x86_64 --path . tests/test_terrain_streamer_phase3_completion.tscn
echo $?          # 134
coredumpctl info -1 --no-pager | sed -n '/Stack trace/,$p' | head -20
```

`coredumpctl` is available and cores are being retained on this machine.

## Code under suspicion

`native/terrain_streamer/` — small, 356 lines total:

| | |
|---|---|
| `src/terrain_region_stager.cpp` | 254 lines |
| `src/terrain_region_stager.h` | 75 lines |
| `src/register_types.cpp` | 27 lines |

Built separately from `nv_engine`:

```bash
cd native/terrain_streamer
scons platform=linux target=template_debug api_version=4.7 use_static_cpp=no disable_exceptions=no -j$(nproc)
```

Output goes to `project/addons/terrain_streamer/bin/`. The shipped `.so` is newer than the sources,
so it is not stale.

## Leads, in the order worth trying

### 1. A process-lifetime static cache of `shared_ptr`

`terrain_region_stager.h`:

```cpp
static std::mutex shared_catalogue_mutex_;
// Process-lifetime cache for the current finite-master scope. If DLC/mod
// worldspaces expand this set, add an explicit eviction/ownership policy;
// TerrainStreamer.deactivate() cannot currently reclaim these shared values.
static std::map<std::pair<std::string, uint32_t>, std::shared_ptr<WorldCatalogue>> shared_catalogues_;
```

This is destroyed during **static destruction at process exit** — after Godot's own shutdown. Its
`WorldCatalogue` values hold `std::map<std::pair<int,int>, CellPayload>`, and each `CellPayload`
holds an `esm::LandData` with `std::vector<float>` and more. So a large allocation graph is torn
down at the latest possible moment, which matches a crash at exit. The comment already admits the
ownership policy is unresolved.

Worth asking: does anything in that graph hold a Godot-allocated type, and is Godot's allocator
still alive at static-destruction time?

### 2. The mutex guards one site only

`shared_catalogue_mutex_` is locked in exactly one place, `terrain_region_stager.cpp:143`, around
the lookup/insert. The `shared_ptr` handed out is then used unguarded. The control block is atomic;
the `WorldCatalogue` it points at is not. The class comment says instances are worker-owned, and
`project/world_streamer.gd` drives it, so concurrent access to one catalogue is plausible.

### 3. Two copies of the same translation units in one process

`native/terrain_streamer/SConstruct`:

```python
sources = Glob("src/*.cpp") + Glob("../src/common/*.cpp") + Glob("../src/esm/esm_file.cpp")
```

`native/SConstruct` compiles those same files into `libnv_engine`. Both libraries are loaded
together, so the process holds two independent copies of `esm_file.cpp` and `common/`, including
their statics. If an object allocated by one copy is freed by the other, or the two disagree about
a shared structure, that is exactly the class of bug being seen. Both build with
`use_static_cpp=no`, so they should share one libstdc++ — worth confirming rather than assuming.

## What is NOT established

Be careful with the following; it is unverified and was produced by nearest-symbol lookup on a
library with **no DWARF line info** (`addr2line` returns `??:?`):

```
0x21d01 -> std::__adjust_heap<...std::pair<int,int>...>
0x1341c -> std::_Sp_counted_base<...>::_M_release_last_use_cold()
0x126c7 -> std::_Sp_counted_base<...>::_M_destroy()
```

The `shared_ptr` frames are consistent with lead 1 and the source does use `shared_ptr` and
`std::pair<int,int>` heavily, so they are plausible — but they are **guesses at nearest preceding
symbol**, not resolved frames. Do not build a theory on them. Rebuild with `-g` and symbolise
properly before trusting any of it.

Also unestablished: whether the corrupting write is in `terrain_streamer` at all. The stack shows
where the damage is *detected*, not where it was *done*.

## Recommended first move

Build with AddressSanitizer and run one affected scene. ASan reports the offending write at the
moment it happens, with a real stack, which turns this from archaeology into a line number.

```bash
cd native/terrain_streamer
scons platform=linux target=template_debug api_version=4.7 use_static_cpp=no disable_exceptions=no \
      CCFLAGS="-fsanitize=address -fno-omit-frame-pointer -g" LINKFLAGS="-fsanitize=address" -j$(nproc)
cd ../../project
LD_PRELOAD=$(gcc -print-file-name=libasan.so) \
  ../tools/Godot_v4.7.1-stable_linux.x86_64 --path . tests/test_terrain_region_stager.tscn
```

`test_terrain_region_stager.tscn` is the narrowest of the six and the best starting scene.

Expect unrelated ASan noise from Godot itself; `detect_leaks=0` in `ASAN_OPTIONS` will cut most of
it. The target is a `heap-buffer-overflow` or `heap-use-after-free` naming a file in
`native/terrain_streamer/` or `native/src/esm/`.

## Definition of done

All six scenes exit `0` under `./run_tests.sh`, and ASan is clean on at least
`test_terrain_region_stager.tscn`.

## Out of scope

A separate, unrelated shutdown abort exists: `EsmServer` (`project/GodotBryo/Servers/EsmServer/
esm_server.gd`) starts a `Thread` in `_ready()` and only calls `wait_to_finish()` from `_process`
once it is already finished, so a scene quitting within the first frames destroys a running
`Thread`. A scene that awaits one frame and quits aborts on `master`. Different signature, different
fix, and `EsmServer/` is a folder that is only ever changed as its own task — do not touch it here.
