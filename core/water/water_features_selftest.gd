extends SceneTree

## Offline selftest for the water-feature pipeline (core/water/): the feature
## layer and its span edits, StreamNetwork resolution (OSM overrides, kinds,
## culvert spans, drainage links, outlets-first order), ChannelProfile (the
## running-minimum bed is monotone, the max-cut cap flags blocked stations, a
## tributary is floored at its junction), StreamHydraulics against a hand-
## computed trapezoid and the rational method, ChannelCarver (only lowers, the
## bed sits under the centreline, a brute-force reference agrees, incremental
## re-runs touch nothing / only a moved feature's footprint), and the delta
## stack (compose = channel + player; player undo never touches the channel).
##
## Run: Godot.exe.exe --headless --path . --script core/water/water_features_selftest.gd
## (run --import first after adding a class_name).

const EXPECTED_CHECKS := 63

var _fails := 0
var _checks := 0


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [name, detail])


func _initialize() -> void:
	_test_layer()
	_test_network()
	_test_profile()
	_test_hydraulics()
	_test_carver()
	_test_stack()
	_test_osm_cache()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		push_error("FAIL: ran %d checks, expected %d (a runtime error aborted a test?)"
				% [_checks, EXPECTED_CHECKS])
	if _fails == 0:
		print("WATER FEATURES SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("WATER FEATURES SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(1 if _fails > 0 else 0)


func _near(a: float, b: float, eps: float = 1e-3) -> bool:
	return absf(a - b) <= eps


# ---------------------------------------------------------------------------

func _test_layer() -> void:
	var l := WaterFeatureLayer.new()
	var id := l.add_stream(PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(20, 0)]),
		{"name": "Brook", "modes": ["surface", "culvert"]})
	_check("stream added", id == "ws_1")
	var rec := l.stream(id)
	_check("modes fit spans", (rec["modes"] as Array).size() == 2)
	# Insert a pin in the culvert span: both halves stay culvert.
	var ins := WaterFeatureLayer.insert_point(rec["points"], rec["modes"], 1, Vector2(15, 1))
	_check("insert adds a point", (ins["points"] as PackedVector2Array).size() == 4)
	_check("insert keeps the split span's mode", ins["modes"] == ["surface", "culvert", "culvert"])
	var rem := WaterFeatureLayer.remove_point(ins["points"], ins["modes"], 1)
	_check("remove merges into the span before", rem["modes"] == ["surface", "culvert"])
	var floor2 := WaterFeatureLayer.remove_point(
		PackedVector2Array([Vector2.ZERO, Vector2.ONE]), ["surface"], 0)
	_check("never below two points", (floor2["points"] as PackedVector2Array).size() == 2)
	l.set_osm_override(77, {"carve": false, "section": {"depth": 2.5}})
	l.set_osm_override(77, {"name": "Mill Race"})
	_check("override patches merge", l.osm_override(77).get("carve") == false
		and str(l.osm_override(77).get("name")) == "Mill Race")
	l.set_osm_override(77, {"carve": null, "section": null, "name": null})
	_check("null patches erase, empty override drops", l.osm_override(77).is_empty() and l.osm.is_empty())
	l.set_osm_override(5, {"hidden": true})
	l.set_setting("min_catchment_ha", 4.0)
	var path := "user://__water_features_selftest.json"
	_check("saves", l.save_to(path))
	var l2 := WaterFeatureLayer.new()
	_check("loads", l2.load_from(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var r2 := l2.stream("ws_1")
	_check("round trip keeps points", (r2.get("points", PackedVector2Array()) as PackedVector2Array).size() == 3)
	_check("round trip keeps modes + name", r2.get("modes") == ["surface", "culvert"] and r2.get("name") == "Brook")
	_check("round trip keeps overrides + settings",
		bool(l2.osm_override(5).get("hidden", false)) and float(l2.setting("min_catchment_ha")) == 4.0)
	_check("next id survives", l2.add_stream(PackedVector2Array([Vector2.ZERO, Vector2.ONE])) == "ws_2")


func _osm_line(osm_id: int, pts: Array, kind: String = "stream", extra: Dictionary = {}) -> Dictionary:
	var cl := PackedVector2Array()
	for p in pts:
		cl.append(p)
	var d := {"points": PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1)]),
		"kind": kind, "tags": {"name": "OSM %d" % osm_id}, "centerline": cl,
		"half_width": 0.0, "osm_id": osm_id}
	for k in extra.keys():
		d[k] = extra[k]
	return d


func _test_network() -> void:
	var osm := [
		_osm_line(1, [Vector2(0, 0), Vector2(100, 0)], "river"),
		_osm_line(2, [Vector2(50, 80), Vector2(50, 2)], "stream", {"culvert": true}),
		_osm_line(3, [Vector2(-50, 0), Vector2(-60, 0)]),
		{"points": PackedVector2Array([Vector2(0, 0), Vector2(5, 0), Vector2(5, 5)]), "kind": "pond"},
	]
	var l := WaterFeatureLayer.new()
	l.set_osm_override(3, {"hidden": true})
	l.add_stream(PackedVector2Array([Vector2(30, -60), Vector2(30, -1)]), {"kind": "ditch"})
	var feats := StreamNetwork.resolve(osm, l)
	_check("hidden override and the pond drop out", feats.size() == 3)
	var by_id := {}
	for f in feats:
		by_id[f["id"]] = f
	_check("osm ids", by_id.has("osm:1") and by_id.has("osm:2") and by_id.has("ws_1"))
	_check("culvert way → culvert spans", by_id["osm:2"]["modes"] == ["culvert"])
	_check("kind section applies", _near(float(by_id["ws_1"]["section"]["bed_w"]),
		float(StreamNetwork.KIND_SECTIONS["ditch"]["bed_w"])))
	l.set_osm_override(1, {"section": {"depth": 3.0}})
	var f1: Dictionary = StreamNetwork.resolve(osm, l)[0]
	_check("per-feature section override wins", _near(float(f1["section"]["depth"]), 3.0)
		and bool(f1["overridden"]))
	var links := StreamNetwork.drainage_links(feats)
	_check("tributary drains into the river", str(links.get("osm:2", {}).get("into", "")) == "osm:1")
	_check("junction arc on the river", _near(float(links["osm:2"]["at_s"]), 50.0, 0.5))
	_check("river is an outlet", not links.has("osm:1"))
	var order := StreamNetwork.downstream_first_order(feats, links)
	var pos := {}
	for i in order.size():
		pos[order[i]["id"]] = i
	_check("outlets first", int(pos["osm:1"]) < int(pos["osm:2"]) and int(pos["osm:1"]) < int(pos["ws_1"]))
	var downhill := func(x: float, _z: float) -> float: return 100.0 - x
	_check("orientation test", StreamNetwork.runs_downhill(
		PackedVector2Array([Vector2(0, 0), Vector2(50, 0)]), downhill)
		and not StreamNetwork.runs_downhill(PackedVector2Array([Vector2(50, 0), Vector2(0, 0)]), downhill))


func _test_profile() -> void:
	# A 1 % slope with a 3 m bump the DEM put across the channel.
	var g := func(x: float, _z: float) -> float:
		return 50.0 - 0.01 * x + 3.0 * exp(-pow((x - 120.0) / 15.0, 2.0))
	var line := PackedVector2Array([Vector2(0, 0), Vector2(300, 0)])
	var p := ChannelProfile.compute(line, g, 1.0)
	var bed: PackedFloat32Array = p["bed"]
	_check("bed is monotone downstream", ChannelProfile.is_monotone(bed))
	_check("bed under the ground everywhere", _bed_below_ground(p))
	_check("bed starts a depth below the smoothed ground", _near(bed[0], 49.0, 0.25))
	_check("arc length", _near(float(p["length_m"]), 300.0, 0.01))
	# A 10 m wall with a 2 m cap: blocked, and flagged.
	var wall := func(x: float, _z: float) -> float:
		return 50.0 - 0.01 * x + (10.0 if absf(x - 150.0) < 30.0 else 0.0)
	var pc := ChannelProfile.compute(line, wall, 1.0, 2.0)
	var flagged := 0
	for v in (pc["blocked"] as PackedByteArray):
		flagged += int(v)
	_check("a cut past max_cut flags stations", flagged > 0)
	var pf := ChannelProfile.compute(line, g, 1.0, 8.0, 49.5)
	var pfb: PackedFloat32Array = pf["bed"]
	var pfg: PackedFloat32Array = pf["ground"]
	var never_above := true
	for i in pfb.size():
		if pfb[i] > pfg[i] - 0.5 + 1e-4:
			never_above = false
	var pond := 0
	for v in (pf["blocked"] as PackedByteArray):
		pond += int(v)
	_check("junction floor lifts the bed where the ground allows, never above it",
		pfb[0] >= 49.5 - 1e-3 and never_above and pond > 0)
	var at := ChannelProfile.bed_at(p, 150.0)
	_check("bed_at interpolates + slope positive", is_finite(at.x) and at.y > 0.0)


func _bed_below_ground(p: Dictionary) -> bool:
	var bed: PackedFloat32Array = p["bed"]
	var gr: PackedFloat32Array = p["ground"]
	for i in bed.size():
		if bed[i] > gr[i] + 1e-4:
			return false
	return true


func _test_hydraulics() -> void:
	# Hand calc: b = 2, z = 1.5, y = 0.5, S = 0.001, n = 0.040
	#   A = (2 + 0.75)·0.5 = 1.375 m²; P = 2 + 2·0.5·√3.25 = 3.80278 m
	#   R = 0.36158 m; R^(2/3) = 0.50754; Q = 25 · 1.375 · 0.50754 · 0.031623 = 0.5517 m³/s
	var q := StreamHydraulics.manning_q_m3s(2.0, 1.5, 0.5, 0.001, 0.040)
	_check("Manning trapezoid Q (hand calc)", _near(q, 0.5517, 0.002), "%.4f" % q)
	var y := StreamHydraulics.normal_depth_m(0.5517, 2.0, 1.5, 0.001, 0.040)
	_check("normal depth inverts Manning", _near(y, 0.5, 0.002), "%.4f" % y)
	var st := StreamHydraulics.state(551.7, 2.0, 1.5, 0.001, 0.040)
	_check("state: top width + velocity", _near(float(st["top_w_m"]), 3.5, 0.01)
		and _near(float(st["velocity_ms"]), 0.5517 / 1.375, 0.01))
	# Rational: C 0.25, 10 mm/h, 1 ha → 0.25·(10/1000/3600)·10000 = 0.006944 m³/s
	_check("rational method", _near(StreamHydraulics.runoff_m3s(10.0, 10000.0, 0.25), 0.006944, 1e-5))
	_check("discharge = base + runoff", _near(StreamHydraulics.discharge_lps(3.0, 10000.0, 10.0, 0.25), 9.944, 0.01))
	_check("no flow, no depth", StreamHydraulics.normal_depth_m(0.0, 2.0, 1.5, 0.01) == 0.0)
	_check("dry rain adds nothing", StreamHydraulics.runoff_m3s(0.0, 1e6) == 0.0)
	var deeper := StreamHydraulics.normal_depth_m(2.0, 2.0, 1.5, 0.001)
	_check("more flow, more depth", deeper > y)


func _plane_sampler() -> WaterGroundSampler:
	var g := func(x: float, z: float) -> float:
		return 40.0 - 0.02 * x + 0.05 * absf(z)   # a gentle V-valley along +x
	var s := WaterGroundSampler.from_fn(g)
	s.patch_half_m = 500.0
	return s


func _carve_feature(id: String, pts: Array, modes: Array = []) -> Dictionary:
	var line := PackedVector2Array()
	for p in pts:
		line.append(p)
	var ms := modes
	if ms.is_empty():
		for _i in line.size() - 1:
			ms.append("surface")
	return {"id": id, "source": "user", "osm_id": -1, "kind": "stream", "name": id,
		"points": line, "modes": ms,
		"section": {"bed_w": 3.0, "depth": 1.0, "bank_slope": 1.5, "max_cut": 5.0},
		"carve": true, "base_lps": 10.0, "covered": false, "overridden": false}


func _test_carver() -> void:
	var sampler := _plane_sampler()
	var f := _carve_feature("a", [Vector2(-100, 10), Vector2(200, 10)])
	var res := ChannelCarver.run({"features": [f], "sampler": sampler, "force_all": true})
	var tiles: Dictionary = res["tiles"]
	_check("carve produced tiles", not tiles.is_empty())
	var only_lowers := true
	for k in tiles.keys():
		for v in (tiles[k] as PackedFloat32Array):
			if v > 1e-6:
				only_lowers = false
	_check("carving only lowers", only_lowers)
	var stack := TerrainEditTiles.new()
	for k in tiles.keys():
		stack.set_tile_data(k, tiles[k])
	var prof: Dictionary = res["profiles"]["a"]
	var bed_mid := ChannelProfile.bed_at(prof, 150.0).x
	var surf := sampler.base_at(50.0, 10.0) + stack.sample_delta(50.0, 10.0)
	_check("bed under the centreline", _near(surf, bed_mid, 0.15), "%.3f vs %.3f" % [surf, bed_mid])
	_check("untouched beyond the banks", absf(stack.sample_delta(50.0, 60.0)) < 1e-6)
	# Brute-force reference at a bank sample: target = bed + (d − hb)/z.
	var x := 51.0
	var zq := 12.0
	var bed_here := ChannelProfile.bed_at(prof, x + 100.0).x
	var want := ChannelCarver.soft_cut(bed_here + ChannelCarver.section_offset(absf(zq - 10.0), 1.5, 1.5)
		- sampler.base_at(x, zq))
	_check("bank sample matches the reference", _near(stack.sample_delta(x, zq), want, 0.12),
		"%.3f vs %.3f" % [stack.sample_delta(x, zq), want])
	# Incremental: nothing changed → nothing touched.
	var res2 := ChannelCarver.run({"features": [f], "sampler": sampler,
		"prev_sigs": res["sigs"], "prev_footprints": res["footprints"]})
	_check("unchanged re-run touches nothing", (res2["touched"] as Array).is_empty())
	# A second, far feature moves → only its footprint is touched.
	var g := _carve_feature("b", [Vector2(-100, 300), Vector2(200, 300)])
	var res3 := ChannelCarver.run({"features": [f, g], "sampler": sampler,
		"prev_sigs": res["sigs"], "prev_footprints": res["footprints"]})
	var touched_a := false
	var fp_a: Array = res["footprints"]["a"]
	for k in res3["touched"]:
		if k in fp_a:
			touched_a = true
	_check("adding b leaves a's tiles alone", not touched_a and not (res3["touched"] as Array).is_empty())
	# A culvert span is not carved.
	var c := _carve_feature("c", [Vector2(-100, 10), Vector2(50, 10), Vector2(200, 10)], ["surface", "culvert"])
	var resc := ChannelCarver.run({"features": [c], "sampler": sampler, "force_all": true})
	var sc := TerrainEditTiles.new()
	for k in (resc["tiles"] as Dictionary).keys():
		sc.set_tile_data(k, resc["tiles"][k])
	_check("surface span carved, culvert span not",
		sc.sample_delta(0.0, 10.0) < -0.5 and absf(sc.sample_delta(150.0, 10.0)) < 1e-6)
	# carve off → no tiles.
	var resoff := ChannelCarver.run({"features": [f], "sampler": sampler, "carve_enabled": false,
		"force_all": true})
	_check("carve switch off carves nothing", (resoff["tiles"] as Dictionary).is_empty())
	# A steep (20 %) reach: no segment's end-cap may dig the next station's
	# lower bed into the one upstream of it (the old terrace artefact).
	var steep := WaterGroundSampler.from_fn(func(x: float, _z: float) -> float: return 60.0 - 0.2 * x)
	steep.patch_half_m = 500.0
	var fs := _carve_feature("s", [Vector2(-90, 0), Vector2(90, 0)])
	var ress := ChannelCarver.run({"features": [fs], "sampler": steep, "force_all": true})
	var ts := TerrainEditTiles.new()
	for k in (ress["tiles"] as Dictionary).keys():
		ts.set_tile_data(k, ress["tiles"][k])
	var worst := 0.0
	for xi in range(-40, 41):
		var xs := float(xi) * 1.5
		var want_bed := ChannelProfile.bed_at(ress["profiles"]["s"], xs + 90.0).x
		worst = maxf(worst, absf(steep.base_at(xs, 0.0) + ts.sample_delta(xs, 0.0) - want_bed))
	_check("steep reach: centreline == bed (no terraces)", worst < 0.06, "worst %.3f" % worst)
	# The section is C1: no step in value or slope at the toe, and the lip
	# soft-min is continuous with the deep cut.
	var e := 1e-4
	var r := minf(ChannelCarver.TOE_ROUND_M, 1.5)
	var toe_l := ChannelCarver.section_offset(1.5 - r - e, 1.5, 1.5)
	var toe_r := ChannelCarver.section_offset(1.5 + r + e, 1.5, 1.5)
	_check("toe blend is continuous", absf(toe_l) < 1e-3 and absf(toe_r - (r + e) / 1.5) < 1e-3)
	_check("lip soft-min meets the cut", absf(ChannelCarver.soft_cut(-3.0) + 3.0) < 1e-6
		and absf(ChannelCarver.soft_cut(3.0)) < 1e-6 and ChannelCarver.soft_cut(0.0) < 0.0)
	# Outside the patch → nothing.
	var far := _carve_feature("far", [Vector2(900, 900), Vector2(950, 900)])
	var resfar := ChannelCarver.run({"features": [far], "sampler": sampler, "force_all": true})
	_check("outside the hi-res patch carves nothing", (resfar["tiles"] as Dictionary).is_empty())


func _test_stack() -> void:
	var channel := TerrainEditTiles.new()
	var player := TerrainEditTiles.new()
	var composed := TerrainEditTiles.new()
	channel.set_delta_sample(3, 3, -2.0)
	player.set_delta_sample(3, 3, 0.5)
	player.set_delta_sample(80, 3, 1.0)
	var keys := {}
	for k in channel.consume_dirty():
		keys[k] = true
	for k in player.consume_dirty():
		keys[k] = true
	composed.compose_from([channel, player], keys.keys())
	_check("compose sums layers", _near(composed.get_delta_sample(3, 3), -1.5, 1e-5))
	_check("compose carries player-only tiles", _near(composed.get_delta_sample(80, 3), 1.0, 1e-5))
	# Player undo: a session over a player edit, then restore — channel intact.
	player.begin_session()
	player.set_delta_sample(3, 3, 4.0)
	var snap := player.end_session()
	player.apply_snapshot(snap)
	_check("player undo restores the player value", _near(player.get_delta_sample(3, 3), 0.5, 1e-5))
	_check("player undo never touches the channel", _near(channel.get_delta_sample(3, 3), -2.0, 1e-5))
	# Channel layer cleared → composed falls back to the player alone.
	var ckeys := channel.active_tiles()
	for k in ckeys:
		channel.set_tile_data(k, PackedFloat32Array())
	composed.compose_from([channel, player], ckeys)
	_check("clearing the channel leaves the player edit", _near(composed.get_delta_sample(3, 3), 0.5, 1e-5))
	# The one-pass mesher equals the reference mesher.
	var fn := func(x: float, z: float) -> float: return 0.1 * x + 0.05 * z
	var key: Vector2i = player.active_tiles()[0]
	var md := player.build_tile_mesh_data(key, fn, 0.0, 0.001, 0.5)
	var ref := player.build_tile_arrays(key, fn, 0.0, 0.001, 0.5)
	var hm_ref := player.build_tile_heightmap(key, fn, 0.0)
	var a_v: PackedVector3Array = (md["arrays"] as Array)[Mesh.ARRAY_VERTEX]
	var r_v: PackedVector3Array = ref[Mesh.ARRAY_VERTEX]
	var a_n: PackedVector3Array = (md["arrays"] as Array)[Mesh.ARRAY_NORMAL]
	var r_n: PackedVector3Array = ref[Mesh.ARRAY_NORMAL]
	var same := a_v.size() == r_v.size()
	for i in mini(a_v.size(), r_v.size()):
		if a_v[i].distance_to(r_v[i]) > 1e-4 or a_n[i].distance_to(r_n[i]) > 1e-4:
			same = false
			break
	_check("one-pass mesher == reference mesher", same)
	_check("one-pass heightmap == reference", (md["heightmap"] as PackedFloat32Array) == hm_ref)


func _test_osm_cache() -> void:
	# BuildingService is an autoload with no class_name — load the script so the
	# statics are reachable under --script.
	var BS: GDScript = load("res://core/terrain/building_service.gd")
	# A cache written before the centreline keys: the centreline comes back
	# from the buffered ribbon, with a stable pseudo id.
	var line := PackedVector2Array([Vector2(0, 0), Vector2(30, 5), Vector2(60, 0), Vector2(90, 12)])
	var ribbon := OsmWaterParser._buffer_polyline(line, 4.0)
	var d: Dictionary = BS._derive_centerline(ribbon)
	var cl: PackedVector2Array = d.get("centerline", PackedVector2Array())
	var ok := cl.size() == line.size()
	for i in mini(cl.size(), line.size()):
		if cl[i].distance_to(line[i]) > 1e-3:
			ok = false
	_check("centreline derived from an old-cache ribbon", ok)
	_check("half width derived", _near(float(d.get("half_width", 0.0)), 4.0, 1e-3))
	var raw := {"points": [], "tags": {"waterway": "stream", "tunnel": "culvert"}, "kind": "stream"}
	for p in ribbon:
		raw["points"].append([p.x, p.y])
	var item: Dictionary = BS._deser_item(raw, "water")
	_check("legacy cache item gets a pseudo id + culvert flag",
		int(item.get("osm_id", -1)) >= BS.PSEUDO_OSM_ID_BASE and bool(item.get("culvert", false)))
	# A v6 item written by THIS build round-trips its real keys.
	var fresh := {"points": ribbon, "tags": {"waterway": "stream"}, "kind": "stream",
		"centerline": line, "half_width": 4.0, "osm_id": 1234, "covered": true}
	var back: Dictionary = BS._deser_item(BS._ser_item(fresh), "water")
	_check("serializer keeps centreline / id / covered",
		(back.get("centerline", PackedVector2Array()) as PackedVector2Array).size() == 4
		and int(back.get("osm_id", -1)) == 1234 and bool(back.get("covered", false)))
