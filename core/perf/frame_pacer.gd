class_name FramePacer
extends RefCounted

## Heavy periodic jobs take turns: at most one a frame.
##
## Several jobs run a few times a second, each costing ~10 ms on a busy site:
## the people tick, the flow step, the SCADA tag gather, the element ledger,
## the timeline's needs strip, the water poll. Each ran on its own timer, so
## they kept landing on the same frame (measured on Walton: 25-40 ms frames
## several times a second on top of a ~19 ms base). A job that is due asks
## `claim`; when another heavy job already ran this frame it waits for the
## next one and asks again, with how many frames it has waited. After
## MAX_WAIT_FRAMES it runs anyway, so nothing starves and no job is ever more
## than a few frames late.
##
## Only WHEN a job runs moves (by a frame or two); what it computes does not.
## The first to ask in a frame wins: tree order decides, nothing is queued.
## Autoload-free on purpose (selftests load its callers under --script).

const MAX_WAIT_FRAMES := 6

## Off = every claim succeeds (the old behaviour; a probe can compare).
static var enabled := true
static var _frame := -1
static var _taken := ""
## How often a job waited and how often it ran late anyway (diagnostics).
static var waits := 0
static var forced := 0


## May `job` run this frame? `waited` = frames it has already waited.
static func claim(job: String, waited: int = 0) -> bool:
	if not enabled:
		return true
	var f := Engine.get_process_frames()
	if f != _frame:
		_frame = f
		_taken = ""
	if _taken.is_empty():
		_taken = job
		return true
	if waited >= MAX_WAIT_FRAMES:
		forced += 1
		return true
	waits += 1
	return false


## The job that took this frame ("" = none yet).
static func taken() -> String:
	return _taken if Engine.get_process_frames() == _frame else ""
