class_name HarnessReport
extends Logger

## The harness's one verdict. Installed as an engine Logger (OS.add_logger) for
## the whole run, so it sees EVERY line the captures print and every error the
## engine raises — the forty-odd captures keep their own print style and still
## end in one machine-readable result and a real exit code.
##
##   PASS / FAIL — counted from printed lines and push_error text. A FAIL is the
##     upper-case token FAIL / FAILED / FAILURE(S) (case-sensitive on purpose:
##     "0 failure(s)" is a pass). Explicit `check()` / `skip()` calls add to the
##     same tallies for captures written against this API.
##   SCRIPT ERRORS — a GDScript runtime error aborts the enclosing function while
##     the capture may still print PASS afterwards (the selftest trap), so any
##     script error FAILS the run. Engine errors (push_error from game code,
##     C++ conditions) are listed but do not fail it — several are long-standing.
##
## Logger callbacks may arrive from any thread: everything is under one Mutex.

const MAX_KEEP := 200
const RESULT_PREFIX := "HARNESS RESULT"

var _mutex := Mutex.new()
var _fail_re := RegEx.create_from_string("(?<![A-Za-z])FAIL(ED|URES?|URE\\(S\\))?(?![A-Za-z])")
var _pass_re := RegEx.create_from_string("(?<![A-Za-z])PASS(ED)?(?![A-Za-z])")

var passes := 0
var fails: Array[String] = []
var skips: Array[String] = []
var script_errors: Array[String] = []
var engine_errors: Array[String] = []
var last_line := ""
var phase := ""


func _log_message(message: String, error: bool) -> void:
	_mutex.lock()
	for raw in message.split("\n", false):
		_classify(raw.strip_edges())
	_mutex.unlock()


func _log_error(function: String, file: String, line: int, code: String, rationale: String,
		_editor_notify: bool, error_type: int, script_backtraces: Array) -> void:
	var text := rationale if not rationale.is_empty() else code
	var where := "%s:%d (%s)" % [file, line, function]
	# An engine error raised from script carries the GDScript stack — the C++
	# file:line alone ("gdscript_lambda_callable.cpp") says nothing actionable.
	for bt in script_backtraces:
		if bt is ScriptBacktrace and (bt as ScriptBacktrace).get_frame_count() > 0:
			var b := bt as ScriptBacktrace
			where += " <- %s:%d %s()" % [b.get_frame_file(0), b.get_frame_line(0), b.get_frame_function(0)]
			break
	_mutex.lock()
	match error_type:
		ERROR_TYPE_SCRIPT:
			_keep(script_errors, "%s — %s" % [where, text])
		ERROR_TYPE_WARNING:
			pass
		_:
			# push_error from a capture carries its own FAIL token.
			if _fail_re.search(text) != null:
				_keep(fails, text)
			else:
				_keep(engine_errors, "%s — %s" % [where, text])
	_mutex.unlock()


func _classify(line: String) -> void:
	if line.is_empty() or line.begins_with(RESULT_PREFIX):
		return
	last_line = line
	# "[FAIL]" / "[ok]" are PRODUCT text (PenstockDesign's check marks, printed
	# when a capture dumps the design summary), not a capture's verdict.
	var verdict_text := line.replace("[FAIL]", "")
	if _fail_re.search(verdict_text) != null:
		_keep(fails, line)
	elif _pass_re.search(verdict_text) != null:
		passes += 1


func _keep(arr: Array[String], s: String) -> void:
	if arr.size() < MAX_KEEP:
		arr.append(s)


# -- Explicit API (new captures) -------------------------------------------------

func set_phase(p: String) -> void:
	_mutex.lock()
	phase = p
	_mutex.unlock()
	print("harness phase: %s" % p)


func check(name: String, ok: bool, detail: String = "") -> bool:
	# Printed lines are classified by _log_message — one source of truth.
	print("%s %s%s" % [name, "PASS" if ok else "FAIL", ("  " + detail) if not detail.is_empty() else ""])
	return ok


func skip(name: String, why: String) -> void:
	_mutex.lock()
	_keep(skips, "%s — %s" % [name, why])
	_mutex.unlock()
	print("%s SKIPPED — %s" % [name, why])


# -- Verdict --------------------------------------------------------------------

func failed() -> bool:
	return not fails.is_empty() or not script_errors.is_empty()


func summary(mode: String, secs: float, status: String = "") -> Dictionary:
	_mutex.lock()
	var st := status
	if st.is_empty():
		st = "FAIL" if (not fails.is_empty() or not script_errors.is_empty()) else "PASS"
	var out := {
		"mode": mode, "status": st, "secs": snappedf(secs, 0.1),
		"passes": passes, "failures": fails.duplicate(), "skipped": skips.duplicate(),
		"script_errors": script_errors.duplicate(), "engine_errors": engine_errors.duplicate(),
		"phase": phase, "last_line": last_line,
	}
	_mutex.unlock()
	return out


static func result_line(s: Dictionary) -> String:
	return "%s %s %s passes=%d failed=%d skipped=%d script_errors=%d engine_errors=%d secs=%.1f%s" % [
		RESULT_PREFIX, str(s.get("mode", "?")), str(s.get("status", "?")),
		int(s.get("passes", 0)), (s.get("failures", []) as Array).size(),
		(s.get("skipped", []) as Array).size(), (s.get("script_errors", []) as Array).size(),
		(s.get("engine_errors", []) as Array).size(), float(s.get("secs", 0.0)),
		("  phase=" + str(s.get("phase", ""))) if str(s.get("status", "")) == "TIMEOUT" else ""]


static func write_json(path: String, data: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(data, "\t"))
		f.close()
