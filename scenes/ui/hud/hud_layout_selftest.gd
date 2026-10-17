extends SceneTree

## Offline selftest for HudLayoutCore — the pure HUD placement solver.
##
## Run: Godot.exe.exe --headless --path . --script scenes/ui/hud/hud_layout_selftest.gd
##
## The properties the HUD's look depends on: no two placed panels overlap,
## everything stays inside the screen and above the timeline, a tool's claim
## pushes every region clear of the space it takes and tucks what it asks to,
## an overflowing column tucks its LOWEST-priority panels first, the bottom
## region stacks upward, the prompt never lands on the timeline, and claims
## combine (max inset per edge) and release cleanly. EXPECTED_CHECKS guards
## against a runtime error silently skipping a test.

const EXPECTED_CHECKS := 30
const VP := Vector2(1920, 1080)
const TL := 162.0

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_test_basic_hud()
	_test_claim_tool()
	_test_overflow_priority()
	_test_bottom_and_prompt()
	_test_hide_and_combine()
	_test_bottom_outranks_top()
	_check(_checks + 1 == EXPECTED_CHECKS, "check count %d == EXPECTED_CHECKS %d" % [_checks + 1, EXPECTED_CHECKS])
	print("hud_layout_selftest: %d checks, %d failed — %s" % [_checks, _fails, "PASS" if _fails == 0 else "FAIL"])
	quit(0 if _fails == 0 else 1)


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("  FAIL: %s" % what)


func _hud() -> Array:
	return [
		{"id": "weather", "region": "top_left", "order": 0, "priority": 5, "size": Vector2(380, 100)},
		{"id": "scoreboard", "region": "top_left", "order": 10, "priority": 3, "size": Vector2(380, 610)},
		{"id": "terrain", "region": "top_right", "order": 0, "priority": 2, "size": Vector2(260, 40)},
		{"id": "fun", "region": "top_right", "order": 10, "priority": 6, "size": Vector2(236, 178)},
		{"id": "hazard", "region": "top_center", "order": 0, "tuckable": false, "size": Vector2(180, 26)},
		{"id": "peak", "region": "top_center", "order": 1, "tuckable": false, "size": Vector2(150, 26)},
		{"id": "toasts", "region": "bottom_left", "order": 0, "tuckable": false, "size": Vector2(220, 120)},
		{"id": "feed", "region": "bottom_left", "order": 10, "size": Vector2(420, 90)},
		{"id": "prompt", "region": "center_prompt", "tuckable": false, "size": Vector2(288, 54)},
	]


func _rects(res: Dictionary, only_state: String = "") -> Dictionary:
	var out := {}
	for id in res:
		if str(res[id]["state"]) == "hidden":
			continue
		if not only_state.is_empty() and str(res[id]["state"]) != only_state:
			continue
		out[id] = res[id]["rect"]
	return out


func _no_overlaps(res: Dictionary) -> bool:
	var r := _rects(res)
	var ids := r.keys()
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			var a: Rect2 = r[ids[i]]
			var b: Rect2 = r[ids[j]]
			var ov := a.intersection(b)
			if ov.size.x > 0.5 and ov.size.y > 0.5:
				print("    overlap %s x %s" % [ids[i], ids[j]])
				return false
	return true


func _inside(res: Dictionary, area: Rect2) -> bool:
	for id in _rects(res):
		var r: Rect2 = res[id]["rect"]
		if not area.grow(0.5).encloses(r):
			print("    %s %s outside %s" % [id, str(r), str(area)])
			return false
	return true


func _test_basic_hud() -> void:
	var res := HudLayoutCore.solve(VP, TL, _hud(), [])
	var area := HudLayoutCore.usable_rect(VP, TL, [])
	_check(_no_overlaps(res), "the plain HUD has no overlaps")
	_check(_inside(res, area), "every panel is inside the usable area (above the timeline)")
	_check(res["weather"]["rect"].position == Vector2(12, 12), "weather sits in the top-left corner")
	_check(res["scoreboard"]["rect"].position.y >= res["weather"]["rect"].end.y, "the scoreboard stacks under the weather card")
	_check(is_equal_approx(res["terrain"]["rect"].end.x, VP.x - 12.0), "terrain options hug the right margin")
	_check(res["hazard"]["rect"].position.x >= res["weather"]["rect"].end.x, "the chip row stays clear of the left column")
	# Under a full 610 px scoreboard only ~150 px is left above the timeline:
	# the toasts keep it and the (tuckable) alarm feed becomes a pill.
	_check(_rects(res, "pill").keys() == ["feed"], "only the feed tucks, for lack of room, without a claim")


func _test_claim_tool() -> void:
	var claim := {"owner": "edit_toolbar", "inset": {"left": 96.0, "top": 64.0}, "tuck": ["top_left", "top_right"]}
	var res := HudLayoutCore.solve(VP, TL, _hud(), [claim])
	var area := HudLayoutCore.usable_rect(VP, TL, [claim])
	_check(_no_overlaps(res), "with the toolbar claim nothing overlaps")
	_check(_inside(res, area), "every panel stays clear of the toolbar's strip and bar")
	_check(res["weather"]["state"] == "pill" and res["scoreboard"]["state"] == "pill", "the left HUD is tucked to pills")
	_check(res["terrain"]["state"] == "pill" and res["fun"]["state"] == "pill", "the right HUD is tucked to pills")
	_check(res["hazard"]["state"] == "full", "untuckable chips stay full")
	_check(res["weather"]["rect"].position == Vector2(108, 76), "pills start inside the claimed insets")


func _test_overflow_priority() -> void:
	# A short screen (UI scale 1.25 at 720p → 864 logical rows).
	var vp := Vector2(1536, 864)
	var res := HudLayoutCore.solve(vp, TL, _hud(), [])
	var area := HudLayoutCore.usable_rect(vp, TL, [])
	_check(_inside(res, area), "a short screen still fits")
	_check(res["scoreboard"]["state"] == "pill", "the lower-priority scoreboard tucks first")
	_check(res["weather"]["state"] == "full", "the higher-priority weather card survives")
	_check(_no_overlaps(res), "no overlaps on the short screen")


func _test_bottom_and_prompt() -> void:
	var res := HudLayoutCore.solve(VP, TL, _hud(), [])
	var bottom := VP.y - TL - 12.0
	_check(is_equal_approx(res["toasts"]["rect"].end.y, bottom), "the bottom region starts right above the timeline")
	_check(res["feed"]["rect"].end.y <= res["toasts"]["rect"].position.y, "the bottom region stacks upward")
	_check(res["prompt"]["rect"].end.y <= bottom + 0.5, "the prompt never lands on the timeline")
	var big := HudLayoutCore.solve(VP, 600.0, _hud(), [])
	_check(big["prompt"]["rect"].end.y <= VP.y - 600.0 - 12.0 + 0.5, "a tall timeline pushes the prompt up")


func _test_hide_and_combine() -> void:
	var graph := {"owner": "graph", "hide": ["*"]}
	var res := HudLayoutCore.solve(VP, TL, _hud(), [graph])
	_check(_rects(res).is_empty(), "a hide-everything claim hides the whole HUD")
	var a := {"owner": "a", "inset": {"right": 380.0}}
	var b := {"owner": "b", "inset": {"right": 410.0, "top": 20.0}}
	var ins := HudLayoutCore.combined_insets([a, b])
	_check(is_equal_approx(float(ins["right"]), 410.0) and is_equal_approx(float(ins["top"]), 20.0),
		"insets combine by max per edge")
	var dock := {"owner": "light_dock", "inset": {"right": 390.0}, "tuck": ["top_right"]}
	var res2 := HudLayoutCore.solve(VP, TL, _hud(), [dock])
	_check(res2["terrain"]["rect"].end.x <= VP.x - 12.0 - 390.0 + 0.5, "a right dock pushes the right column left")
	_check(_no_overlaps(res2), "no overlaps with a dock")
	var hidden := _hud()
	hidden[1]["visible"] = false
	var res3 := HudLayoutCore.solve(VP, TL, hidden, [])
	_check(res3["scoreboard"]["state"] == "hidden" and res3["weather"]["state"] == "full",
		"a panel that hides itself frees its slot")


## An untuckable bottom panel (the ride dashboard) that does not fit under the
## top-left column tucks the top column rather than spilling onto the timeline.
func _test_bottom_outranks_top() -> void:
	var hud := _hud()
	hud.append({"id": "dash", "region": "bottom_left", "order": -10, "tuckable": false, "size": Vector2(320, 254)})
	var res := HudLayoutCore.solve(VP, TL, hud, [])
	var area := HudLayoutCore.usable_rect(VP, TL, [])
	_check(res["dash"]["state"] == "full" and is_equal_approx(res["dash"]["rect"].size.y, 254.0),
		"the dashboard keeps its full height")
	_check(res["scoreboard"]["state"] == "pill" and res["weather"]["state"] == "full",
		"the lower-priority scoreboard tucks to make room")
	_check(_no_overlaps(res) and _inside(res, area), "no overlaps, nothing on the timeline")
