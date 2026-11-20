extends SceneTree

## Offline checks for the simulation kernel's data side (core/simkit/): the
## design guard (what a design from outside may contain), the compact report's
## rounding and tables, the AI inbox reader on a TEMP folder, and the catalog.
## The kernel run itself is checked end to end by tools/simkit_mcp/mcp_selftest.py.
##
##   Godot --headless --path . --script core/simkit/simkit_selftest.gd

const Guard := preload("res://core/simkit/simkit_guard.gd")
const Compact := preload("res://core/simkit/simkit_compact.gd")
const Inbox := preload("res://core/simkit/simkit_inbox.gd")
const Catalog := preload("res://core/simkit/simkit_catalog.gd")
const Site := preload("res://core/simkit/simkit_site.gd")
const Report := preload("res://core/simkit/simkit_report.gd")

const EXPECTED_CHECKS := 41

var _n := 0
var _fails := 0


func _initialize() -> void:
	_test_guard()
	_test_clean()
	_test_round()
	_test_inbox()
	_test_catalog()
	_test_mode()
	_test_waste_kinds()
	if _n != EXPECTED_CHECKS:
		_check(false, "ran %d checks, expected %d (a test function aborted?)" % [_n, EXPECTED_CHECKS])
	print("SIMKIT SELFTEST %s (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _n, _fails])
	quit(1 if _fails > 0 else 0)


func _check(ok: bool, what: String) -> void:
	_n += 1
	if not ok:
		_fails += 1
		print("FAIL ", what)


func _test_guard() -> void:
	var d := Site.load_design("bombay_ten")
	_check(not d.is_empty(), "the built-in design loads")
	_check(Guard.check_design(d).is_empty(), "the built-in design passes the guard")
	_check(not Guard.check_design({"nodes": [], "exec": 1}).is_empty(), "an unknown top-level key is refused")
	_check(not Guard.check_design({"nodes": [{"id": "a/b", "preset": "Kitchen"}]}).is_empty(), "a node id with a slash is refused")
	_check(not Guard.check_design({"nodes": [{"id": "a", "preset": "Kitchen"}, {"id": "a", "preset": "Kitchen"}]}).is_empty(),
		"a repeated node id is refused")
	_check(not Guard.check_design({"nodes": [{"id": "a", "preset": "Kitchen", "count": 999}]}).is_empty(), "a huge count is refused")
	_check(not Guard.check_design({"nodes": [{"id": "a", "preset": "Kitchen", "recipe_file": "../../x"}]}).is_empty(),
		"a recipe_file with a path is refused")
	_check(not Guard.check_design({"nodes": [{"id": "a", "preset": "Kitchen", "script": "x"}]}).is_empty(),
		"an unknown node key is refused")
	_check(not Guard.check_design({"nodes": [], "days": 99999}).is_empty(), "days past the limit are refused")
	var big := {"nodes": [], "note": "x".repeat(700000)}
	_check(not Guard.check_design(big).is_empty(), "an oversized design is refused")
	var deep: Variant = 1
	for i in 12:
		deep = [deep]
	_check(not Guard.check_design({"nodes": [{"id": "a", "preset": "Kitchen", "set": {"x": deep}}]}).is_empty(),
		"a too-deep value is refused")


func _test_clean() -> void:
	var d := {"nodes": [{"id": "a", "preset": "Kitchen", "set": {"capacity_qty": 5, "scene_device_path": "/root/Main",
		"ha_links": {"x": "sensor.y"}, "device_path": "/root", "url": "http://x", "urine_fraction": 0.8},
		"automations": [{"alias": "x", "triggers": [{"kind": "numeric", "entity_id": "tank.a.level", "below": 5}],
			"actions": [{"kind": "scene_node", "command": "turn_on", "extra": 1},
				{"kind": "ha_service", "service": "switch.turn_on", "entity_id": "switch.real_pump"},
				{"kind": "set_value", "entity_id": "number.x", "value": 3},
				{"kind": "delay", "delay_seconds": 60}]}]}], "world": {"x": 1}}
	var c := Guard.clean_design(d)
	var st: Dictionary = c["nodes"][0]["set"]
	_check(st.has("capacity_qty"), "clean keeps an ordinary field")
	_check(st.has("urine_fraction"), "clean keeps a field that merely contains a short forbidden word")
	_check(not st.has("scene_device_path") and not st.has("device_path"), "clean drops scene and device paths")
	_check(not st.has("ha_links") and not st.has("url"), "clean drops Home Assistant links and URLs")
	var acts: Array = c["nodes"][0]["automations"][0]["actions"]
	_check(acts.size() == 2, "clean keeps only switch and delay actions (got %d)" % acts.size())
	_check(not (acts[0] as Dictionary).has("extra"), "clean drops unknown action keys")
	_check(not c.has("world"), "clean drops the world block")
	_check((c["nodes"][0]["automations"][0]["triggers"] as Array).size() == 1, "clean keeps triggers")
	var g := {"items": [{"id": "x", "type": "appliance", "device_path": "/root/Main/X",
		"specs": {"name": "X", "scene_device_path": "/root/Main/Y", "ha_links": {}, "watts": 5}}], "connections": []}
	var cg := Guard.clean_graph(g)
	var it: Dictionary = cg["items"][0]
	_check(not it.has("device_path") and not (it["specs"] as Dictionary).has("scene_device_path"),
		"clean_graph drops scene paths")
	_check((it["specs"] as Dictionary).get("watts", 0) == 5, "clean_graph keeps the specs")


func _test_round() -> void:
	_check(str(Compact._r(1234.567)) == "1230", "3 significant figures (1230 got %s)" % str(Compact._r(1234.567)))
	_check(str(Compact._r(0.012345)) == "0.0123", "small numbers keep 3 figures (got %s)" % str(Compact._r(0.012345)))
	_check(Compact._r(NAN) == 0 and Compact._r(INF) == 0, "NaN and INF become 0")
	_check(Compact._r(100.0) is int, "whole numbers come back as ints")
	_check(str(Compact._r(-5.5555)) == "-5.56", "negatives round too (got %s)" % str(Compact._r(-5.5555)))
	var rd := Compact._round_dict({"a": 1.23456, "b": 2.0})
	_check(str(rd["a"]) == "1.23" and rd["b"] is int, "round_dict")


func _test_inbox() -> void:
	var dir := OS.get_user_data_dir().path_join("simkit_selftest_inbox_%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	_check(Inbox.entries(dir).is_empty(), "an empty inbox lists nothing")
	var e := {"v": 1, "id": "d1", "name": "Bigger cistern", "note": "more water", "site": "w1", "created": 2.0,
		"summary": {"verdict": "SUSTAINED", "days": 366, "fails": [], "bottlenecks": ["cistern was empty 3 h"]},
		"graph": {"items": [{"id": "x", "type": "resource", "specs": {"name": "X", "ha_links": {"a": 1}}}], "connections": []}}
	_write(dir.path_join("d1.json"), JSON.stringify(e))
	var e2 := e.duplicate(true)
	e2["id"] = "d2"
	e2["created"] = 5.0
	_write(dir.path_join("d2.json"), JSON.stringify(e2))
	_write(dir.path_join("junk.json"), "not json")
	var list := Inbox.entries(dir)
	_check(list.size() == 2, "the inbox lists the two good entries (got %d)" % list.size())
	_check(list.size() == 2 and str(list[0]["id"]) == "d2", "newest first")
	var g := Inbox.graph_of(dir.path_join("d1.json"))
	_check(not g.is_empty() and not ((g["items"][0] as Dictionary)["specs"] as Dictionary).has("ha_links"),
		"the inbox graph comes back cleaned")
	_check(Inbox.describe(list[0]).begins_with("sustained over 366 days"), "describe: %s" % Inbox.describe(list[0]))
	Inbox.archive(dir.path_join("d1.json"))
	_check(Inbox.entries(dir).size() == 1 and FileAccess.file_exists(dir.path_join("imported/d1.json")),
		"archive moves an entry out of the inbox")
	_rm(dir)


func _test_catalog() -> void:
	var c := Catalog.build()
	var rows: Array = c.get("rows", [])
	_check(rows.size() > 50, "the catalog lists the library (%d)" % rows.size())
	var labels := {}
	for r in rows:
		labels[str(r[0])] = true
	var d := Site.load_design("bombay_ten")
	var missing: Array = []
	for n in (d.get("nodes", []) as Array):
		if not labels.has(str((n as Dictionary).get("preset", ""))):
			missing.append(str((n as Dictionary).get("preset", "")))
	_check(missing.is_empty(), "every preset the built-in design names is in the catalog %s" % str(missing))
	var det: Dictionary = (c.get("detail", {}) as Dictionary).get("Kitchen", {})
	_check(not det.is_empty() and det.get("specs") is Dictionary, "a module's detail has its specs")
	_check(JSON.stringify(c).length() < 400000, "the catalog stays small enough to serve")


func _test_mode() -> void:
	_check(not SimkitMode.active(), "a selftest is not the kernel")
	_check(not SimkitMode.blocks("ha"), "outside the kernel nothing is blocked")


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _rm(dir: String) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for sub in d.get_directories():
		_rm(dir.path_join(sub))
	for f in d.get_files():
		d.remove(f)
	DirAccess.remove_absolute(dir)


## Every toilet stream counts as waste in "no waste overflowed": brownwater
## (urine-diverting toilets) was missing, so a full toilet tank passed.
func _test_waste_kinds() -> void:
	_check("brownwater" in Report.WASTE_KINDS, "brownwater is a waste kind")
	_check("blackwater" in Report.WASTE_KINDS and "urine" in Report.WASTE_KINDS,
		"blackwater and urine are waste kinds")
