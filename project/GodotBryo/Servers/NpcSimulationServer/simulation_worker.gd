class_name NpcSimulationWorker
extends RefCounted

## NpcSimulationServer's own background thread: runs posted jobs one after
## another at its own pace, every urgent job (an on-screen NpcController's
## route) before any other (off-screen routes and door sequences), each queue
## in order. All of the server's route work runs here, none on
## WorkerThreadPool, so a flood of it never delays the pool's other users
## (NifServer, TextureServer). A job must touch only thread-safe state (the
## immutable NavmeshReader and the indexes built at seed) and hand its result
## to the main thread with call_deferred.

var _thread := Thread.new()
var _mutex := Mutex.new()
var _semaphore := Semaphore.new()
var _urgent_jobs: Array[Callable] = []
var _jobs: Array[Callable] = []
var _stopping := false

func start() -> void:
	if not _thread.is_started():
		_thread.start(_run)

## Queues `job` to run on the thread; an `urgent` one runs before every
## other waiting job.
func post(job: Callable, urgent := false) -> void:
	_mutex.lock()
	if urgent:
		_urgent_jobs.append(job)
	else:
		_jobs.append(job)
	_mutex.unlock()
	_semaphore.post()

## Jobs waiting to run.
func get_pending_count() -> int:
	_mutex.lock()
	var count := _urgent_jobs.size() + _jobs.size()
	_mutex.unlock()
	return count

## Drops waiting jobs, lets the running one finish and joins the thread.
func stop() -> void:
	if not _thread.is_started():
		return
	_mutex.lock()
	_stopping = true
	_urgent_jobs.clear()
	_jobs.clear()
	_mutex.unlock()
	_semaphore.post()
	_thread.wait_to_finish()

func _run() -> void:
	while true:
		_semaphore.wait()
		_mutex.lock()
		if _stopping:
			_mutex.unlock()
			return
		var job := Callable()
		if not _urgent_jobs.is_empty():
			job = _urgent_jobs.pop_front()
		elif not _jobs.is_empty():
			job = _jobs.pop_front()
		_mutex.unlock()
		if job.is_valid():
			job.call()
