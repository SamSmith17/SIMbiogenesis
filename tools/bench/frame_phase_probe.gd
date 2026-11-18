extends Node

## Where one frame's time goes, for frame_spike_bench. Two of these: one with
## `last` false (its _process runs first in the tree), one with `last` true
## (runs last). Per frame they mark the physics steps, the first and last
## _process, and RenderingServer's frame_pre_draw / frame_post_draw. At the
## first _process of a frame the previous frame is closed:
##   scripts        first _process .. last _process
##   after_scripts  last _process .. frame_pre_draw (deferred calls, the
##                  delete queue)
##   render_main    frame_pre_draw .. frame_post_draw (sync, uploads, shader
##                  compiles; on the main thread)
##   physics        the physics steps that ran before this frame's scripts
##   between        what is left of the gap: present, vsync, input, audio
## `last_phases` then describes the same frame PerfMonitor.last_frame does
## when read at the start of the frame after (what the bench does).

var last := false
static var t_phys0 := 0
static var t_phys1 := 0
static var t_proc0 := 0
static var t_proc1 := 0
static var t_pre := 0
static var t_post := 0
static var last_phases: Dictionary = {}
static var _hooked := false


func _ready() -> void:
	process_priority = 100000 if last else -100000
	process_physics_priority = 100000 if last else -100000
	if not _hooked:
		_hooked = true
		RenderingServer.frame_pre_draw.connect(_on_pre)
		RenderingServer.frame_post_draw.connect(_on_post)


static func _on_pre() -> void:
	t_pre = Time.get_ticks_usec()


static func _on_post() -> void:
	t_post = Time.get_ticks_usec()


func _physics_process(_d: float) -> void:
	var now := Time.get_ticks_usec()
	if last:
		t_phys1 = now
	elif t_phys1 <= t_proc1:
		t_phys0 = now   # the first physics step since the last scripts ran


func _process(_d: float) -> void:
	var now := Time.get_ticks_usec()
	if last:
		t_proc1 = now
		return
	if t_post > t_proc1 and t_proc1 > t_proc0:
		var gap := maxi(now - t_post, 0)
		var phys := maxi(t_phys1 - t_phys0, 0) if t_phys0 > t_post else 0
		last_phases = {
			"scripts": float(t_proc1 - t_proc0) / 1000.0,
			"after_scripts": float(maxi(t_pre - t_proc1, 0)) / 1000.0,
			"render_main": float(maxi(t_post - t_pre, 0)) / 1000.0,
			"physics": float(phys) / 1000.0,
			"between": float(maxi(gap - phys, 0)) / 1000.0,
		}
	t_proc0 = now


func phases() -> Dictionary:
	return last_phases
