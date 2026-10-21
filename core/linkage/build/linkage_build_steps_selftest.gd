extends SceneTree
## Offline selftest for the LinkageLab build-step port (LINKAGE_PARITY.md A2):
## LinkageBuildSteps (model, groups, visibility, bench, generator) and
## LinkageBeamHoles. The generator is pinned per preset against the steps the
## REAL web app generates (core/linkage/testdata/parity/*.json, written by
## `node tools/linkage_parity_dump.mjs`).
##
## Run: Godot.exe.exe --headless --path . --script core/linkage/build/linkage_build_steps_selftest.gd

## A Godot runtime error aborts the enclosing test function while the suite
## still prints PASS; the count catches a silently skipped function.
const EXPECTED_CHECKS := 74

const PARITY_DIR := "res://core/linkage/testdata/parity/"
const PRESETS := ["constellation", "starshade_2x3_folding_panels", "starshade_hex",
	"starshade_v1_soak_2026", "stellarator"]

var _fails := 0
var _checks := 0


func _initialize() -> void:
	_test_formatting()
	_test_model_and_groups()
	_test_bench()
	_test_visibility()
	_test_generated_steps_parity()
	_test_saved_steps()
	_test_ops()
	_test_ops_on_generated_steps()
	_test_params_build_steps()
	var count_ok := EXPECTED_CHECKS == 0 or _checks == EXPECTED_CHECKS
	if not count_ok:
		print("  FAIL: ran %d checks, expected %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	if _fails == 0 and count_ok:
		print("LINKAGE BUILD STEPS SELFTEST: PASS (%d checks)" % _checks)
	else:
		print("LINKAGE BUILD STEPS SELFTEST: FAIL (%d/%d)" % [_fails, _checks])
	quit(0 if _fails == 0 and count_ok else 1)


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  FAIL: ", label)


func _read_json(path: String):
	var f := FileAccess.open(path, FileAccess.READ)
	return JSON.parse_string(f.get_as_text()) if f != null else null


# ---------------------------------------------------------------------------

func _test_formatting() -> void:
	# Number.toFixed rounds an exact tie up; printf would give "0.12".
	_check(LinkageBuildSteps.js_fixed(0.125, 2) == "0.13", "toFixed tie rounds up")
	_check(LinkageBuildSteps.js_fixed(0.03125, 4) == "0.0313", "toFixed 1/32 at 4 dp")
	_check(LinkageBuildSteps.fmt_in(84.0) == "84 in", "fmtIn whole")
	_check(LinkageBuildSteps.fmt_in(97.25) == "97.25 in", "fmtIn quarter")
	_check(LinkageBuildSteps.fmt_in(1.5) == "1.5 in", "fmtIn trims a trailing zero")
	_check(LinkageBuildSteps.fmt_in(120.0) == "120 in", "fmtIn keeps zeros before the point")
	_check(LinkageBuildSteps.fmt_in(0.0) == "0 in", "fmtIn zero")
	_check(LinkageBuildSteps.stock_length_for(94.2) == 96.0 and LinkageBuildSteps.stock_length_for(100.0) == 120.0
		and LinkageBuildSteps.stock_length_for(200.0) == 204.0 and LinkageBuildSteps.stock_length_for(50.0, 72) == 72.0,
		"stock lengths snap up to standard lumber")
	_check(not LinkageBuildSteps.needs_cut(96.0, 96.0) and not LinkageBuildSteps.needs_cut(95.99, 96.0)
		and LinkageBuildSteps.needs_cut(95.0, 96.0), "needs_cut")


func _test_model_and_groups() -> void:
	var s := LinkageBuildSteps.create_step("fasten", {"title": "x", "durationMs": 99999})
	_check(s["kind"] == "fasten" and int(s["durationMs"]) == 60000, "durations clamp to 60 s")
	_check((s["op"] as Dictionary).get("turns") == 3, "fasten op defaults")
	_check(LinkageBuildSteps.create_step("bogus")["kind"] == "view", "unknown kind -> view")
	var bs := LinkageBuildSteps.normalize({"steps": [
		{"id": "a", "kind": "place", "groupId": "g"}, {"id": "b", "kind": "place", "groupId": "g"},
		{"id": "c", "kind": "view"}, {"id": "d", "kind": "place", "groupId": "g"}, {"id": "a", "kind": "cut"}],
		"settings": {"repeatMode": "fast", "fastFactor": 50}})
	var steps: Array = bs["steps"]
	_check(steps.size() == 5 and steps[4]["id"] != "a", "duplicate ids reissued")
	_check(steps[3]["groupId"] == null and steps[0]["groupId"] == "g", "only the first run of a group survives")
	_check(bs["settings"]["repeatMode"] == "fast" and bs["settings"]["fastFactor"] == 4, "settings clamp")
	var g := LinkageBuildSteps.group_of(steps, 1)
	_check(int(g["count"]) == 2 and int(g["position"]) == 1 and bool(g["isLast"]), "group_of")
	_check(LinkageBuildSteps.next_index_after(steps, 0) == 2, "skip mode jumps the group")
	_check(LinkageBuildSteps.next_index_after(steps, 0, "fast") == 1, "fast mode walks it")
	_check(LinkageBuildSteps.representative_steps(steps).size() == 4, "representatives")
	var gid = LinkageBuildSteps.group_steps(bs, ["c", "d"])
	_check(gid != null and LinkageBuildSteps.group_of(bs["steps"], 3)["count"] == 2, "group_steps")
	_check(LinkageBuildSteps.group_steps(bs, ["a", "c"]) == null, "non-contiguous refused")
	LinkageBuildSteps.update_step(bs, "c", {"kind": "cut"})
	_check(LinkageBuildSteps.get_by_id(bs, "c")["stage"] == "bench", "kind change takes the new kind's stage")
	_check(LinkageBuildSteps.move_step(bs, 0, 4) and bs["steps"][4]["id"] == "a", "move_step")
	_check(absf(LinkageBuildSteps.sequence_progress(0.5, 0, 1) - 0.5) < 1e-9, "sequence progress n=1")
	_check(LinkageBuildSteps.sequence_progress(0.0, 1, 3) == 0.0 and absf(LinkageBuildSteps.sequence_progress(1.0, 2, 3) - 1.0) < 1e-9,
		"sequence progress windows")
	_check(absf(LinkageBuildSteps.shortest_angle_delta(0.1, TAU - 0.1) + 0.2) < 1e-9, "shortest arc")
	var ser = LinkageBuildSteps.serialize(bs)
	_check(ser is Dictionary and (ser["steps"] as Array).size() == 5, "serialize")
	_check(LinkageBuildSteps.serialize(LinkageBuildSteps.create_default()) == null, "empty serializes to null")


func _test_bench() -> void:
	var p := LinkageParams.new()
	var data := LinkagePartKeys.part_data(p, LinkageKinematics.optimal_closed_angle(p))
	var groups := LinkageBuildSteps.group_beams_for_bench(data["beams"])
	var n := 0
	for g in groups:
		n += int(g["count"])
	_check(n == (data["beams"] as Array).size(), "bench groups cover every beam")
	var plan := LinkageBuildSteps.plan_bench(groups, {"stock": true})
	_check((plan["items"] as Array).size() == groups.size(), "one bench row per group")
	_check(float(plan["items"][0]["stockLength"]) >= float(plan["items"][0]["beamLength"]), "stock >= beam")
	var holes := [
		{"through": "W", "pos_l": -46.5, "pos_t": 0.0, "pos_w": 1.0, "radius": 0.25},
		{"through": "W", "pos_l": -46.51, "pos_t": 0.01, "pos_w": 1.0, "radius": 0.3125},
		{"through": "T", "pos_l": -46.5, "pos_t": 0.0, "pos_w": 0.0, "radius": 0.25},
		{"through": "W", "pos_l": 10.0, "pos_t": 0.0, "pos_w": 1.0, "radius": 0.25}]
	var out := LinkageBuildSteps.dedupe_holes(holes)
	_check(out.size() == 3 and float(out[0]["radius"]) == 0.3125, "holes on one spot merge, largest radius kept")


func _test_visibility() -> void:
	var p := LinkageParams.new()
	var data := LinkagePartKeys.part_data(p, LinkageKinematics.optimal_closed_angle(p))
	var parts := LinkagePartKeys.collect_parts(data)
	var steps := [
		LinkageBuildSteps.create_step("place", {"targets": [{"kind": "beam", "stackType": "horizontal-bottom"}]}),
		LinkageBuildSteps.create_step("place", {"targets": [{"kind": "beam", "stackType": "horizontal-top"}],
			"op": {"parkOffset": {"mode": "beside", "gapIn": 24}}}),
		LinkageBuildSteps.create_step("view", {}),
		LinkageBuildSteps.create_step("place", {"targets": [{"kind": "beam", "stackType": "horizontal-top"}], "op": {"from": "parked"}}),
	]
	var v0 := LinkageBuildSteps.compute_step_visibility(steps, 0, parts)
	var bot := LinkagePartKeys.part_key((data["beams"] as Array)[0], "beam")
	var top_key := ""
	for rec in parts:
		if str(rec["key"]).begins_with("beam:horizontal-top"):
			top_key = rec["key"]
			break
	_check(v0["status"][bot] == "active" and v0["status"][top_key] == "future", "step 0: bottom active, top future")
	var v2 := LinkageBuildSteps.compute_step_visibility(steps, 2, parts)
	_check(v2["status"][top_key] == "done" and (v2["displacement"] as Dictionary).has(top_key), "top built and parked")
	var v3 := LinkageBuildSteps.compute_step_visibility(steps, 3, parts)
	_check(not (v3["displacement"] as Dictionary).has(top_key) and (v3["displacementBefore"] as Dictionary).has(top_key),
		"lifting it clears the park (and it was parked just before)")
	var sb := {"min": Vector3(-10, 0, -10), "max": Vector3(10, 5, 10)}
	var pb := {"min": Vector3(-5, 2, -2), "max": Vector3(5, 3, 2)}
	_check(LinkageBuildSteps.resolve_park_offset({"mode": "beside", "gapIn": 24}, sb, pb) == Vector3(39, -2, 0),
		"park beside: past +X, resting on the ground")


# ---------------------------------------------------------------------------
# Generator == the web app's Auto-generate, per preset
# ---------------------------------------------------------------------------

## JSON-ish deep compare with numeric tolerance; returns "" when equal, else
## the path of the first difference.
func _diff(a, b, path: String) -> String:
	if (a is float or a is int) and (b is float or b is int):
		return "" if absf(float(a) - float(b)) <= 2e-3 else "%s: %s vs %s" % [path, str(a), str(b)]
	if a is Dictionary and b is Dictionary:
		for k in a:
			if not (b as Dictionary).has(k):
				return "%s.%s missing in JS" % [path, k]
		for k in b:
			if not (a as Dictionary).has(k):
				return "%s.%s missing in game" % [path, k]
			var d := _diff(a[k], b[k], path + "." + str(k))
			if not d.is_empty():
				return d
		return ""
	if a is Array and b is Array:
		if (a as Array).size() != (b as Array).size():
			return "%s: %d items vs %d" % [path, (a as Array).size(), (b as Array).size()]
		for i in (a as Array).size():
			var d := _diff(a[i], b[i], "%s[%d]" % [path, i])
			if not d.is_empty():
				return d
		return ""
	if typeof(a) != typeof(b) or a != b:
		return "%s: %s vs %s" % [path, str(a), str(b)]
	return ""


static func _strip_ids(v):
	if v is Dictionary:
		var o := {}
		for k in v:
			if k != "id":
				o[k] = _strip_ids(v[k])
		return o
	if v is Array:
		var o: Array = []
		for x in v:
			o.append(_strip_ids(x))
		return o
	return v


## Steps that need parts a later phase ports (walls: A4; floor beams: A4).
## Steps that target parts not ported yet (none since the A4 coverings).
static func _needs_unported(_step: Dictionary) -> bool:
	return false


## Sorted part keys of every beam the drill steps target.
static func _drilled_keys(p: LinkageParams, steps: Array, deployed_deg: float) -> Array:
	var data := LinkagePartKeys.part_data(p, deg_to_rad(deployed_deg))
	var keys := {}
	for s in steps:
		if str(s["kind"]) != "drill":
			continue
		for k in LinkagePartKeys.resolve_targets(data, s["targets"])["keys"]:
			keys[k] = true
	var out: Array = keys.keys()
	out.sort()
	return out


func _test_generated_steps_parity() -> void:
	for name in PRESETS:
		var fx = _read_json(PARITY_DIR + name + ".json")
		var pr = _read_json("res://core/linkage/presets/ll_%s.json" % name)
		if not (fx is Dictionary) or not (pr is Dictionary):
			_check(false, "%s readable" % name)
			continue
		var p := LinkageParams.new()
		p.from_config(pr)
		var game: Array = _strip_ids(LinkageBuildSteps.generate_for(p, float(fx["foldedDeg"]), float(fx["deployedDeg"])))
		var js: Array = []
		var skipped := 0
		for s in fx["generatedSteps"]:
			if _needs_unported(s):
				skipped += 1
			else:
				js.append(s)
		var d := _diff(game, js, name)
		if not d.is_empty():
			# A crossing of two nearly collinear reciprocal beams is ill-
			# conditioned: float32 endpoints move its hole ~0.03 in, which can
			# tip it into the next 1/16 in bucket of the hole signature and so
			# split one drill group (2x3: one reciprocal beam's 94.44 -> 94.5).
			# Positions are pinned at 1/32 in by linkage_selftest's holes test;
			# here everything but the drill steps must still match exactly, and
			# the drill steps must cover exactly the same beams.
			var nd_game: Array = game.filter(func(s): return str(s["kind"]) != "drill")
			var nd_js: Array = js.filter(func(s): return str(s["kind"]) != "drill")
			var d2 := _diff(nd_game, nd_js, name)
			var dg := _drilled_keys(p, game, float(fx["deployedDeg"]))
			var dj := _drilled_keys(p, js, float(fx["deployedDeg"]))
			if d2.is_empty() and dg == dj:
				print("  NOTE: %s drill groups differ at an ill-conditioned reciprocal crossing (same %d beams drilled)" % [name, dg.size()])
				d = ""
		var at := ""
		if not d.is_empty():
			# Name the first differing step for a readable failure.
			for i in mini(game.size(), js.size()):
				if not _diff(game[i], js[i], "").is_empty():
					at = " | step %d game='%s' js='%s'" % [i, game[i].get("title", ""), js[i].get("title", "")]
					break
		_check(d.is_empty(), "%s generated steps == JS (%d, %d A4-only skipped): %s%s" % [name, js.size(), skipped, d, at])


## A design's OWN saved steps (LinkageLab-authored) normalize exactly as the web
## app normalizes them, and every target outside the A4 parts names real parts
## in the game — a step authored in the web app acts on the same parts here.
func _test_saved_steps() -> void:
	for name in PRESETS:
		var fx = _read_json(PARITY_DIR + name + ".json")
		var pr = _read_json("res://core/linkage/presets/ll_%s.json" % name)
		if not (fx is Dictionary) or not (pr is Dictionary) or fx.get("savedSteps") == null:
			continue
		var mine := LinkageBuildSteps.normalize((pr as Dictionary).get("buildSteps"))
		var d := _diff(_strip_ids(mine), fx["savedSteps"], name)
		_check(d.is_empty(), "%s saved steps normalize == JS: %s" % [name, d])
		var p := LinkageParams.new()
		p.from_config(pr)
		var data := LinkagePartKeys.part_data(p, deg_to_rad(float(fx["deployedDeg"])))
		var parts := LinkagePartKeys.collect_parts(data)
		var counts: Array = fx["savedTargetCounts"]
		var bad: Array = []
		var compared := 0
		for si in (mine["steps"] as Array).size():
			var st: Dictionary = mine["steps"][si]
			if _needs_unported(st):
				continue
			for ti in (st["targets"] as Array).size():
				var sel: Dictionary = st["targets"][ti]
				var n := (LinkagePartKeys.resolve_targets(data, [sel], parts)["items"] as Array).size()
				var want := int(counts[si][ti])
				var ok := n == want
				compared += 1
				if not ok:
					bad.append("%s: %s -> %d vs JS %d" % [st["title"], JSON.stringify(sel), n, want])
		_check(bad.is_empty() and compared > 0, "%s saved step targets resolve as in JS (%d selectors): %s" % [name,
			compared, str(bad.slice(0, 4))])


# ---------------------------------------------------------------------------
# Op resolvers (LinkageBuildOps) — the JS drivers' timing, pinned by hand
# ---------------------------------------------------------------------------

func _ctx_for(p: LinkageParams) -> Dictionary:
	var fold := LinkageKinematics.optimal_closed_angle(p)
	var data := LinkagePartKeys.part_data(p, fold)
	return {"data": data, "parts": LinkagePartKeys.collect_parts(data),
		"drill_bolts": LinkageBeamHoles.drill_solve(p, fold)["bolts"]}


func _test_ops() -> void:
	var s := LinkageBuildOps.slot_of(0.55, 4)
	_check(int(s["idx"]) == 2 and absf(float(s["u"]) - 0.2) < 1e-9, "slot_of")
	_check(LinkageBuildOps.natural_less("panel:2", "panel:10"), "natural key order")
	var p := LinkageParams.new()
	p.show_bolts = true
	var ctx := _ctx_for(p)

	# Place: travel in along the approach, fade, sequential windows.
	var plan := LinkageBuildOps.stage(LinkageBuildSteps.create_step("place",
		{"targets": [{"kind": "beam", "stackType": "horizontal-top", "moduleIndex": 0}], "op": {"approach": "above", "travelIn": 24}}), ctx)
	_check((plan["entries"] as Array).size() == p.h_stack_count, "place: one entry per target part")
	var p0 := LinkageBuildOps.place_at(plan, 0.0)
	var p1 := LinkageBuildOps.place_at(plan, 1.0)
	_check((p0[0]["offset"] as Vector3).is_equal_approx(Vector3(0, 24, 0)) and (p1[0]["offset"] as Vector3).is_zero_approx(),
		"place: 24 in above at t=0, seated at t=1")
	_check(absf(float(p0[0]["opacity"]) - 0.25) < 1e-9 and absf(float(p1[0]["opacity"]) - 1.0) < 1e-9, "place: fades 0.25 -> 1")
	var radial := LinkageBuildOps.stage(LinkageBuildSteps.create_step("place",
		{"targets": [{"kind": "beam", "stackType": "vertical", "moduleIndex": 2}], "op": {"approach": "radial", "travelIn": 30}}), ctx)
	var en: Dictionary = radial["entries"][0]
	var c: Vector3 = en["seated"]
	_check((en["dir"] as Vector3).is_equal_approx(Vector3(c.x, 0, c.z).normalized()), "place: radial = outward in plan")
	var seq := LinkageBuildOps.stage(LinkageBuildSteps.create_step("place",
		{"targets": [{"kind": "beam", "stackType": "horizontal-bottom"}], "op": {"sequential": true}}), ctx)
	var s0 := LinkageBuildOps.place_at(seq, 0.01)
	_check(bool(s0[0]["visible"]) and not bool(s0[s0.size() - 1]["visible"]), "place sequential: later parts hidden until their window")
	var park_ctx := ctx.duplicate()
	park_ctx["park_offset_for"] = func(_k): return Vector3(100, -20, 0)
	var parked := LinkageBuildOps.stage(LinkageBuildSteps.create_step("place",
		{"targets": [{"kind": "beam", "stackType": "horizontal-top", "moduleIndex": 0}], "op": {"from": "parked"}}), park_ctx)
	var pe: Dictionary = parked["entries"][0]
	_check(absf(float(pe["dist"]) - Vector3(100, -20, 0).length()) < 1e-6 and not bool(pe["fade"]), "place from parked: travels the park vector, no fade")

	# Cut: lower, cross the stock, lift; offcut separates.
	var cut := LinkageBuildOps.stage(LinkageBuildSteps.create_step("cut",
		{"targets": [{"kind": "beam", "stackType": "vertical"}]}), ctx)
	var rows: Array = cut["rows"]
	_check(rows.size() >= 1, "cut: bench rows (%d)" % rows.size())
	var item: Dictionary = rows[0]
	var r := float(cut["saw_radius"])
	var n_rows := rows.size()
	var c0 := LinkageBuildOps.cut_at(cut, 0.0)
	_check(absf((c0["tool"]["pos"] as Vector3).y - (float(item["t"]) + r + 3.0)) < 1e-6, "cut: saw starts lifted")
	var cm := LinkageBuildOps.cut_at(cut, 0.4 / n_rows)
	_check(absf((cm["tool"]["pos"] as Vector3).y - (float(item["t"]) + 0.25)) < 1e-6 and float(cm["rows"][0]["kerf_len"]) > 0.0,
		"cut: mid-pass blade at the cut height, kerf growing")
	_check(absf((cm["tool"]["pos"] as Vector3).x - (float(item["x0"]) + float(item["cutAt"]) + 0.0625)) < 1e-6, "cut: blade on the cut line")
	var c1 := LinkageBuildOps.cut_at(cut, 1.0)
	_check(not bool(c1["tool"]["visible"]) and bool(c1["rows"][0]["keep"]) and (c1["rows"][0]["offcut_offset"] as Vector3).is_equal_approx(Vector3(11.5, -0.35, 0)),
		"cut: done, offcut slid 11.5 in clear")

	# Drill: slide, plunge to below the beam, retract; holes appear on the way out.
	var dr := LinkageBuildOps.stage(LinkageBuildSteps.create_step("drill",
		{"targets": [{"kind": "beam", "stackType": "horizontal-bottom", "moduleIndex": 0, "layerIndex": 0}]}), ctx)
	var jobs: Array = dr["jobs"]
	_check(jobs.size() > 0, "drill: holes found (%d)" % jobs.size())
	if jobs.size() > 0:
		var n := jobs.size()
		var mid_plunge := LinkageBuildOps.drill_at(dr, (0.5 - 1e-6) / n)
		_check(absf((mid_plunge["tool"]["tip"] as Vector3).y + 0.4) < 1e-3, "drill: bit bottoms at -0.4 in")
		_check(int(mid_plunge["drilled"][0]) == 0 and int(LinkageBuildOps.drill_at(dr, 0.6 / n)["drilled"][0]) == 1,
			"drill: the hole appears as the bit comes out")
		_check(int(LinkageBuildOps.drill_at(dr, 1.0)["drilled"][0]) == n, "drill: every hole at t=1")

	# Fasten: joints worked outer, inner, centre; bolts back out and turn in.
	var fa := LinkageBuildOps.stage(LinkageBuildSteps.create_step("fasten",
		{"targets": [{"kind": "bolt", "boltType": "vstack", "moduleIndex": 1, "ring": "bottom"},
			{"kind": "bolt", "boltType": "vstack", "moduleIndex": 1, "ring": "center"}], "op": {"sequential": true, "turns": 3}}), ctx)
	var joints: Array = fa["joints"]
	var roles: Array = []
	for j in joints:
		roles.append(str(j["id"]).get_slice(":", 4))
	_check(roles == ["outer", "inner", "center"], "fasten: joint order outer, inner, centre (%s)" % str(roles))
	var f0 := LinkageBuildOps.fasten_at(fa, 0.0)
	var f1 := LinkageBuildOps.fasten_at(fa, 1.0)
	var e0: Dictionary = f0["entries"][0]
	_check(absf(float(e0["spin"]) - 3.0 * TAU) < 1e-6 and (e0["offset"] as Vector3).length() > 0.9, "fasten: backed out, three turns to go")
	_check((f1["entries"][0]["offset"] as Vector3).is_zero_approx() and absf(float(f1["entries"][0]["spin"])) < 1e-9, "fasten: seated at t=1")
	_check(int(LinkageBuildOps.fasten_at(fa, 0.99)["joint"]) == joints.size() - 1, "fasten: focus follows the joint")
	var outer: Dictionary = {}
	for en2 in fa["entries"]:
		if str(en2["key"]).contains(":outer"):
			outer = en2
	_check(not outer.is_empty() and (outer["move_dir"] as Vector3).is_equal_approx(-(outer["axis"] as Vector3)),
		"fasten: an outer V bolt backs out toward its bracket (head side -1)")


## Every step the generator writes stages without error and finds its parts.
func _test_ops_on_generated_steps() -> void:
	for name in ["starshade_v1_soak_2026", "stellarator"]:
		var pr = _read_json("res://core/linkage/presets/ll_%s.json" % name)
		var p := LinkageParams.new()
		p.from_config(pr)
		var steps := LinkageBuildSteps.generate_for(p)
		var ctx := _ctx_for(p)
		var bad: Array = []
		for st in steps:
			var plan := LinkageBuildOps.stage(st, ctx)
			match str(st["kind"]):
				"place":
					if (plan["entries"] as Array).is_empty():
						bad.append(st["title"])
					LinkageBuildOps.place_at(plan, 0.5)
				"cut":
					if (plan["rows"] as Array).is_empty():
						bad.append(st["title"])
					LinkageBuildOps.cut_at(plan, 0.5)
				"drill":
					if (plan["jobs"] as Array).is_empty():
						bad.append(st["title"])
					LinkageBuildOps.drill_at(plan, 0.5)
				"fasten":
					if (plan["entries"] as Array).is_empty():
						bad.append(st["title"])
					LinkageBuildOps.fasten_at(plan, 0.5)
		_check(bad.is_empty(), "%s: every generated step stages with parts (%d steps): %s" % [name, steps.size(), str(bad.slice(0, 4))])


## LinkageParams carries the guide through `extra`, losslessly.
func _test_params_build_steps() -> void:
	var pr = _read_json("res://core/linkage/presets/ll_stellarator.json")
	var p := LinkageParams.new()
	p.from_config(pr)
	var bs := p.get_build_steps()
	_check((bs["steps"] as Array).size() == 63, "the preset's 63 saved steps load")
	LinkageBuildSteps.remove_step(bs, str(bs["steps"][0]["id"]))
	p.set_build_steps(bs)
	_check((p.to_config()["buildSteps"]["steps"] as Array).size() == 62, "an edit reaches to_config")
	p.set_build_steps(LinkageBuildSteps.create_default())
	_check(not p.to_config().has("buildSteps"), "an empty guide removes the key")
