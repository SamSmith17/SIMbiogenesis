class_name PerfSpan
extends RefCounted

## Autoload-safe PerfMonitor spans.
##
## Scripts that a selftest loads under `--headless --script` (planets.gd,
## the placed lights, gameplay runtimes) cannot name the `PerfMonitor` autoload
## directly: a bare autoload identifier does not COMPILE there and silently
## takes the whole selftest's dependency chain down with it. This resolves the
## autoload once through the scene tree and is a no-op when it is absent, so
## per-frame instrumentation can live in any script.
##
##     PerfSpan.begin("prop_ticks")
##     ...
##     PerfSpan.end("prop_ticks")

static var _pm: Node = null
static var _looked := false
## Mirrors PerfMonitor's enabled flag (it sets this in set_enabled): with the
## F3 HUD off a span costs one static read instead of two dynamic calls into
## the monitor, which there were hundreds of a frame (one pair per prop tick).
static var active := false


static func _monitor() -> Node:
	if _pm != null:
		if is_instance_valid(_pm):
			return _pm
		_pm = null
		_looked = false
	if _looked:
		return null
	_looked = true
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		var root := (loop as SceneTree).root
		if root != null:
			_pm = root.get_node_or_null("PerfMonitor")
	return _pm


static func begin(section: String) -> void:
	if not active:
		return
	var pm := _monitor()
	if pm != null:
		pm.call("begin", section)


static func end(section: String) -> void:
	if not active:
		return
	var pm := _monitor()
	if pm != null:
		pm.call("end", section)
