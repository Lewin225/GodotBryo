class_name NpcSimulationWorker
extends RefCounted

## NpcSimulationServer's own background thread: runs posted jobs one after
## another, in order, at its own pace. Off-screen work (LowLevelTravel's
## routes, PackageRunner's cross-space plans) goes here rather than to
## WorkerThreadPool, so a backlog of it never delays the pool's other work,
## such as an on-screen NpcController's route. A job must touch only
## thread-safe state (the immutable NavmeshReader and the indexes built at
## seed) and hand its result to the main thread with call_deferred.

var _thread := Thread.new()
var _mutex := Mutex.new()
var _semaphore := Semaphore.new()
var _jobs: Array[Callable] = []
var _stopping := false

func start() -> void:
	if not _thread.is_started():
		_thread.start(_run)

## Queues `job` to run on the thread.
func post(job: Callable) -> void:
	_mutex.lock()
	_jobs.append(job)
	_mutex.unlock()
	_semaphore.post()

## Jobs waiting to run.
func get_pending_count() -> int:
	_mutex.lock()
	var count := _jobs.size()
	_mutex.unlock()
	return count

## Drops waiting jobs, lets the running one finish and joins the thread.
func stop() -> void:
	if not _thread.is_started():
		return
	_mutex.lock()
	_stopping = true
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
		var job: Callable = _jobs.pop_front() if not _jobs.is_empty() else Callable()
		_mutex.unlock()
		if job.is_valid():
			job.call()
