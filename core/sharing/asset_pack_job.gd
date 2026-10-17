class_name AssetPackJob
extends Node

## Runs one pack job (write / extract / catalog scan) on a WorkerThreadPool
## task and reports back on the main thread. The task is always waited on —
## an un-waited task crashes the engine on quit (see the imagery BC7 note in
## CLAUDE.md) — so the job keeps the tree alive until it finishes: closing
## the UI cancels and then waits.

signal finished(result: Variant)

var progress := AssetPackProgress.new()
var _task := -1
var _result: Variant = null
var _work: Callable


## `work` takes the AssetPackProgress and returns the result.
func start(work: Callable) -> void:
	_work = work
	_task = WorkerThreadPool.add_task(_run, true, "asset pack")
	set_process(true)


func running() -> bool:
	return _task >= 0


func cancel() -> void:
	progress.cancel()


func _run() -> void:
	_result = _work.call(progress)


func _process(_dt: float) -> void:
	if _task < 0:
		set_process(false)
		return
	if not WorkerThreadPool.is_task_completed(_task):
		return
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	set_process(false)
	finished.emit(_result)


func _exit_tree() -> void:
	if _task >= 0:
		progress.cancel()
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
