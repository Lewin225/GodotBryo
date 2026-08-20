class_name GamebryoResolverPool
extends RefCounted

## phases/2/10-threaded-streaming-workers.md, step 2: a small pool of
## independently-constructed GamebryoResolveContexts, one per concurrent
## tile-resolve task a caller wants in flight at once. Each pool member owns
## its own private BSA readers, NIF/mesh/texture/material/collision caches,
## AND its own private EsmReader (see GamebryoResolveContext's own doc
## comment for why the EsmReader had to join this pool too, discovered while
## building step 3's resolve_placement() -- DOOR/SCOL/LIGH resolution reads
## the ESM directly, and EsmFile is exactly as not-thread-safe as BsaArchive)
## -- exactly the per-task-private state 2.10's design needs so no two
## WorkerThreadPool tasks ever touch the same reader concurrently, without
## needing a Mutex anywhere.
##
## checkout()/checkin() are NOT thread-safe themselves and must only be
## called from the main thread -- by design, not by accident: a tile task
## is checked out before its WorkerThreadPool.add_task() call and checked
## back in once the main thread has finished consuming its result, both of
## which are main-thread-only operations in 2.10's own design (see that
## task doc's "resolve on workers, commit on main" section). This is what
## lets checkout/checkin stay two plain Array ops with no Mutex at all --
## if that assumption ever stops holding (a future caller wants to check
## out from a worker thread), this class would need real synchronization
## added, not silently rely on the current caller discipline.

var _available: Array[GamebryoResolveContext] = []
var _checked_out_count := 0
var _size := 0

## `size`, if given, overrides the automatic sizing below -- mainly for
## tests that want a small, deterministic pool. Automatic sizing is
## OS.get_processor_count() minus one (reserve a core for the main thread,
## which is doing real work too: streaming bookkeeping, the actual RS/PS3D/
## Node commit step, plus everything else the game does), floored at 2 so
## even a 1-2 core machine still gets some real overlap between resolve and
## commit rather than degenerating to fully serial. Deliberately NOT a fixed
## constant -- this project runs on whatever hardware it's asked to, and a
## hardcoded worker count would leave real cores idle on a bigger machine
## (or oversubscribe a smaller one).
func _init(size: int = -1) -> void:
	if size <= 0:
		size = maxi(2, OS.get_processor_count() - 1)
	_size = size
	for i in range(_size):
		_available.append(GamebryoResolveContext.new())

## Returns a context not currently in use, or null if every instance is
## already checked out -- callers (2.10 step 4's WorldStreamer wiring) are
## responsible for deferring a tile's resolve start until a slot frees up
## (checkin()), the same way WorldStreamer already defers tile starts via
## its own _pending bookkeeping; this class doesn't queue/block on the
## caller's behalf.
func checkout() -> GamebryoResolveContext:
	if _available.is_empty():
		return null
	_checked_out_count += 1
	return _available.pop_back()

## Returns a previously checked-out context to the pool. `context` must have
## come from this same pool's checkout() -- no ownership tracking is done to
## verify that (kept simple; a caller passing back something it didn't check
## out from here is a caller bug, not a case worth guarding).
func checkin(context: GamebryoResolveContext) -> void:
	if context == null:
		return
	_checked_out_count -= 1
	_available.append(context)

func get_size() -> int:
	return _size

func get_checked_out_count() -> int:
	return _checked_out_count

func get_available_count() -> int:
	return _available.size()
