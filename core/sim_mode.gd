extends Node
## SimMode — compatibility shim over the TimeDirector autoload.
##
## Mode authority moved to core/time_director.gd, which also owns the wall-clock
## NOW anchor, the playhead, and data provenance. This shim preserves the
## long-standing SimMode public API (is_live / is_sim / is_historical /
## should_apply_live_data / should_run_realworld_actions / set_historical_active /
## current_mode + the mode_changed signal) so every existing consumer keeps
## working without changes.
##
## Note the enum ordering here is the historical SimMode one
## (LIVE=0, SIMULATE=1, HISTORICAL=2); TimeDirector uses
## (LIVE=0, PLAYBACK=1, SIMULATE=2). The shim translates between them.

enum Mode { LIVE, SIMULATE, HISTORICAL }

signal mode_changed(new_mode: int)

var _td: Node = null
var _last_mode: int = Mode.SIMULATE


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_resolve_director()
	if _td != null and not _td.mode_changed.is_connected(_on_td_mode_changed):
		_td.mode_changed.connect(_on_td_mode_changed)
	_last_mode = current_mode()
	mode_changed.emit(_last_mode)


func _resolve_director() -> void:
	if _td == null or not is_instance_valid(_td):
		_td = get_node_or_null("/root/TimeDirector")


## Map TimeDirector.Mode → legacy SimMode.Mode.
func _from_td(td_mode: int) -> int:
	match td_mode:
		0: return Mode.LIVE        # TimeDirector.Mode.LIVE
		1: return Mode.HISTORICAL  # TimeDirector.Mode.PLAYBACK
		2: return Mode.SIMULATE    # TimeDirector.Mode.SIMULATE
	return Mode.SIMULATE


func _on_td_mode_changed(td_mode: int) -> void:
	var m := _from_td(td_mode)
	if m != _last_mode:
		_last_mode = m
		mode_changed.emit(m)


# ---------------------------------------------------------------------------
# Public API (delegates to TimeDirector)
# ---------------------------------------------------------------------------

func current_mode() -> int:
	_resolve_director()
	if _td != null:
		return _from_td(int(_td.call("current_mode")))
	return _last_mode

func is_live() -> bool:
	_resolve_director()
	return _td != null and bool(_td.call("is_live"))

func is_sim() -> bool:
	_resolve_director()
	if _td != null:
		return bool(_td.call("is_sim"))
	return true

func is_historical() -> bool:
	_resolve_director()
	return _td != null and bool(_td.call("is_playback"))

func should_apply_live_data() -> bool:
	return is_live()

func should_run_realworld_actions() -> bool:
	return is_live()

func set_historical_active(active: bool) -> void:
	_resolve_director()
	if _td != null:
		_td.call("set_historical_active", active)
