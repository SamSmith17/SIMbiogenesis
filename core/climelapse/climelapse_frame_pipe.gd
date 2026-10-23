class_name ClimelapseFramePipe
extends RefCounted

## Raw RGB frames → ffmpeg's stdin → H.264 MP4, with the writes on a worker
## thread so the GPU renders the next frame while x264 encodes this one.
##
##   var pipe := ClimelapseFramePipe.new()
##   var err := pipe.open(ffmpeg, opts, out_path)      # "" = running
##   while pipe.queued() >= ClimelapseFramePipe.MAX_QUEUE: await tree.process_frame
##   pipe.push(img)                                     # FORMAT_RGB8, opts' size
##   var res := await pipe.close(tree)                  # {ok, reason}
##
## Measured on this machine (2026-10-22): a BLOCKING pipe is required —
## `OS.execute_with_pipe(..., false)` dropped every write once the pipe buffer
## filled and ffmpeg wrote a 262-byte file. ffmpeg runs `-loglevel error`, so
## its stderr stays tiny and cannot fill and stall it; it is read once ffmpeg
## has exited.

const MAX_QUEUE := 6

var _io: FileAccess = null
var _err_io: FileAccess = null
var _pid := -1
var _thread: Thread = null
var _mutex := Mutex.new()
var _sem := Semaphore.new()
var _queue: Array = []
var _closing := false
var _write_failed := false
var _frames_written := 0
var _frame_bytes := 0
var _out_path := ""


## Start ffmpeg. Returns "" on success, else why not.
func open(ffmpeg: String, opts: Dictionary, out_path: String) -> String:
	if ffmpeg.is_empty():
		return "ffmpeg not found — install ffmpeg, add it to PATH, or set [climelapse] ffmpeg_path= in user://terrain_config.cfg"
	_out_path = out_path
	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	_frame_bytes = int(opts["width"]) * int(opts["height"]) * 3
	var d: Dictionary = OS.execute_with_pipe(ffmpeg, ClimelapseExportOptions.ffmpeg_pipe_args(opts, out_path), true)
	if d.is_empty() or not (d.get("stdio") is FileAccess):
		return "Could not start ffmpeg (%s)." % ffmpeg
	_io = d["stdio"]
	_err_io = d.get("stderr") as FileAccess
	_pid = int(d.get("pid", -1))
	_thread = Thread.new()
	_thread.start(_writer)
	return ""


func queued() -> int:
	_mutex.lock()
	var n := _queue.size()
	_mutex.unlock()
	return n


func failed() -> bool:
	return _write_failed


func frames_written() -> int:
	return _frames_written


## Hand one frame to the writer. The image must be RGB8 at the export size.
func push(img: Image) -> bool:
	if _io == null or _write_failed:
		return false
	var data := img.get_data()
	if data.size() != _frame_bytes:
		push_warning("ClimelapseFramePipe: frame is %d bytes, expected %d" % [data.size(), _frame_bytes])
		return false
	_mutex.lock()
	_queue.append(data)
	_mutex.unlock()
	_sem.post()
	return true


func _writer() -> void:
	while true:
		_sem.wait()
		_mutex.lock()
		var item: Variant = _queue.pop_front() if not _queue.is_empty() else null
		var stop := _closing and item == null
		_mutex.unlock()
		if stop:
			return
		if item == null or _write_failed:
			continue
		if not _io.store_buffer(item as PackedByteArray):
			_write_failed = true
			continue
		_frames_written += 1


## Flush, end the stream and wait for ffmpeg. Awaits on the tree's frames so
## the game keeps drawing while x264 finishes.
func close(tree: SceneTree) -> Dictionary:
	if _thread != null:
		_mutex.lock()
		_closing = true
		_mutex.unlock()
		_sem.post()
		while _thread.is_alive():
			await tree.process_frame
		_thread.wait_to_finish()
		_thread = null
	if _io != null:
		_io.close()
		_io = null
	var waited := 0.0
	while _pid > 0 and OS.is_process_running(_pid) and waited < 600.0:
		await tree.process_frame
		waited += tree.root.get_process_delta_time() if tree.root != null else 0.016
	var code := OS.get_process_exit_code(_pid) if _pid > 0 else -1
	var log := ""
	if _err_io != null:
		log = _err_io.get_buffer(16384).get_string_from_utf8().strip_edges()
		_err_io.close()
		_err_io = null
	if _write_failed or code != 0:
		return {"ok": false, "reason": "ffmpeg failed (exit %d, %d frames written): %s" % [code, _frames_written, log]}
	if not FileAccess.file_exists(_out_path):
		return {"ok": false, "reason": "ffmpeg finished but %s is missing" % _out_path}
	return {"ok": true, "reason": "", "frames": _frames_written}


## Stop without caring about the result (cancel).
func abort(tree: SceneTree) -> void:
	_mutex.lock()
	_queue.clear()
	_mutex.unlock()
	await close(tree)
	if FileAccess.file_exists(_out_path):
		DirAccess.remove_absolute(_out_path)
