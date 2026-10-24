extends SceneTree

## Shoreline over time (offline): the USGS gauge parse, the level at a date,
## the NGVD29 → NAVD88 shift, the gauge pick, the Wayback release list, the
## tilemap walk, the capture metadata and the capture dedupe, the capture at a
## date, the Wayback source id / cache key, and the world record.
## Fixtures in testdata/ are trimmed copies of the real replies (2026-10-23).
##   Godot.exe --headless --path . --script core/terrain/shoreline/shoreline_selftest.gd

## A runtime error aborts a test function while PASS still prints: count.
const EXPECTED_CHECKS := 85
const TD := "res://core/terrain/shoreline/testdata/"
const _IMG := preload("res://core/terrain/imagery_service.gd")

var _pass := 0
var _fail := 0


func _initialize() -> void:
	_test_days()
	_test_dv_parse()
	_test_level_at()
	_test_datum()
	_test_gauge_pick()
	_test_config()
	_test_tilemap_walk()
	_test_metadata()
	_test_dedupe()
	_test_wayback_source()
	_test_record()
	_test_spill()
	var total := _pass + _fail
	if total != EXPECTED_CHECKS:
		print("FAIL check count %d, expected %d (a test function aborted?)" % [total, EXPECTED_CHECKS])
		_fail += 1
	print("shoreline selftest: %d passed, %d failed — %s" % [_pass, _fail, "PASS" if _fail == 0 else "FAILURE"])
	quit(0 if _fail == 0 else 1)


func _ok(cond: bool, what: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		print("FAIL ", what)


func _near(a: float, b: float, tol: float, what: String) -> void:
	_ok(absf(a - b) <= tol, "%s (%.6f vs %.6f)" % [what, a, b])


func _read(name: String) -> String:
	return FileAccess.get_file_as_string(TD + name)


func _test_days() -> void:
	_ok(LakeGauge.abs_day(1, 1, 1) == 0, "abs day of year 1 Jan 1 is 0")
	# The same epoch as the clock the level follows.
	var clock := CelestialClock.new()
	clock.year = 2024
	clock.month = 2
	clock.day = 29
	clock.day_time = 13.0
	_ok(int(floor(clock.get_absolute_hours() / 24.0)) == LakeGauge.abs_day(2024, 2, 29),
		"abs day == CelestialClock's absolute hours / 24 (leap day)")
	clock.year = 1987
	clock.month = 10
	clock.day = 1
	clock.day_time = 0.5
	_ok(int(floor(clock.get_absolute_hours() / 24.0)) == LakeGauge.abs_day(1987, 10, 1),
		"abs day == clock on the gauge's first day")
	var ok_rt := true
	for s in ["1987-10-01", "2000-02-29", "2000-03-01", "1900-03-01", "2026-12-31", "2024-01-01"]:
		if LakeGauge.date_of(LakeGauge.abs_day_of(s)) != s:
			ok_rt = false
			print("  round trip ", s, " -> ", LakeGauge.date_of(LakeGauge.abs_day_of(s)))
	_ok(ok_rt, "date ↔ abs day round trips (leap and century years)")
	_ok(LakeGauge.abs_day_of("garbage") == -1 and LakeGauge.abs_day_of("2020-13-01") == -1,
		"an unreadable date is -1")
	_ok(LakeGauge.abs_day_of("2026-09-22T00:00:00.000") == LakeGauge.abs_day(2026, 9, 22),
		"NWIS dateTime reads as its date")


func _test_dv_parse() -> void:
	var s := LakeGauge.parse_dv_json(_read("usgs_dv_10254005_sample.json"))
	_ok(bool(s["ok"]), "dv JSON parses")
	var days: PackedInt32Array = s["days"]
	var ft: PackedFloat64Array = s["ft"]
	_ok(days.size() == 8, "8 readings kept, the -999999 no-data skipped (got %d)" % days.size())
	_ok(str(s["first"]) == "1987-10-01" and str(s["last"]) == "2026-09-22", "record span 1987-10-01..2026-09-22")
	_near(ft[0], -228.20, 1e-9, "first reading -228.20 ft")
	_near(ft[ft.size() - 1], -244.00, 1e-9, "last reading -244.00 ft")
	var asc := true
	for i in range(1, days.size()):
		if days[i] <= days[i - 1]:
			asc = false
	_ok(asc, "days ascending")
	_ok(str(s["param"]) == LakeGauge.PARAM_NGVD29, "parameter 62614 (NGVD29)")
	_ok(str(s["unit"]) == "ft", "unit ft")
	_ok(str(s["name"]).contains("SALTON SEA"), "site name read")
	_ok(not str(s["provisional_from"]).is_empty(), "provisional readings flagged")
	_ok(not bool(LakeGauge.parse_dv_json("{}")["ok"]),
		"an empty / broken reply is not ok")


func _test_level_at() -> void:
	var days := PackedInt32Array([100, 110, 130])
	var ft := PackedFloat64Array([-230.0, -231.0, -233.0])
	_near(float(LakeGauge.level_at(days, ft, 105.0)["ft"]), -230.5, 1e-9, "linear between readings")
	_near(float(LakeGauge.level_at(days, ft, 120.0)["ft"]), -232.0, 1e-9, "linear across a gap")
	_ok(int(LakeGauge.level_at(days, ft, 120.0)["gap_days"]) == 10, "gap to the nearest reading")
	var before := LakeGauge.level_at(days, ft, 10.0)
	_ok(is_equal_approx(float(before["ft"]), -230.0) and not bool(before["inside"]),
		"before the record: the first reading, flagged outside")
	var after := LakeGauge.level_at(days, ft, 500.0)
	_ok(is_equal_approx(float(after["ft"]), -233.0) and not bool(after["inside"]),
		"after the record: the last reading, flagged outside")
	_near(float(LakeGauge.level_at(days, ft, 110.0)["ft"]), -231.0, 1e-9, "on a reading")
	_ok(is_nan(float(LakeGauge.level_at(PackedInt32Array(), PackedFloat64Array(), 1.0)["ft"])),
		"no series: NAN")
	# Scrubs backwards: the level is a pure function of the day.
	var a := float(LakeGauge.level_at(days, ft, 117.25)["ft"])
	LakeGauge.level_at(days, ft, 129.0)
	_near(float(LakeGauge.level_at(days, ft, 117.25)["ft"]), a, 0.0, "same day, same level (pure)")


func _test_datum() -> void:
	var shift := LakeGauge.parse_ncat_shift(_read("ncat_gauge_10254005.json"))
	_near(shift, 0.534, 0.0005, "VERTCON at the Salton Sea gauge: NGVD29 → NAVD88 +0.534 m")
	_near(float(LakeGauge.KNOWN[0]["shift_m"]), shift, 0.0005, "the KNOWN table carries the measured shift")
	_near(LakeGauge.navd88_m(-244.0, LakeGauge.PARAM_NGVD29, 0.534), -244.0 * 0.3048 + 0.534, 1e-9,
		"-244.00 ft NGVD29 = -73.837 m NAVD88")
	_near(LakeGauge.navd88_m(-230.0, LakeGauge.PARAM_NAVD88, 0.534), -230.0 * 0.3048, 1e-9,
		"a NAVD88 series takes no shift")
	_ok(is_nan(LakeGauge.parse_ncat_shift("{\"srcOrthoht\":\"N/A\"}")), "an NCAT reply without heights: NAN")
	# 1987 → 2026 the sea fell 15.8 ft: about 4.8 m.
	_near(LakeGauge.navd88_m(-228.2, "62614", shift) - LakeGauge.navd88_m(-244.0, "62614", shift),
		15.8 * 0.3048, 1e-6, "the drop is the same in either datum")


func _test_gauge_pick() -> void:
	var sites := LakeGauge.parse_site_rdb(_read("usgs_site_rdb_salton.txt"))
	_ok(sites.size() == 1, "one lake gauge in the Salton Sea search box (got %d)" % sites.size())
	if sites.is_empty():
		return
	var s0: Dictionary = sites[0]
	_ok(str(s0["id"]) == "10254005" and str(s0["param"]) == "62614" and int(s0["count"]) == 14237,
		"gauge 10254005, 62614, 14237 days")
	var g := LakeGauge.pick_gauge(sites, 33.3560, -115.7266)
	_ok(not g.is_empty(), "Bombay Beach picks the gauge")
	_near(float(g.get("distance_km", 0.0)), 23.3, 0.5, "22-23 km from Bombay Beach")
	_near(float(g.get("shift_m", NAN)), 0.534, 0.0005, "the pick takes the KNOWN shift")
	_ok(LakeGauge.pick_gauge(sites, 48.3252, -122.2469).is_empty(), "Mount Vernon is out of range")
	_ok(not LakeGauge.known_gauge_for(33.3560, -115.7266).is_empty(), "the known list covers Bombay Beach offline")
	_ok(LakeGauge.site_search_url(33.356, -115.7266).contains("bBox=") and LakeGauge.dv_url(g, "2026-10-23").contains("sites=10254005"),
		"request URLs")


func _test_config() -> void:
	var rels := WaybackCatalog.parse_config(_read("wayback_config_sample.json"))
	_ok(rels.size() == 5, "5 releases parsed")
	var dates: Array = rels.map(func(r: Dictionary) -> String: return str(r["date"]))
	var sorted := dates.duplicate()
	sorted.sort()
	_ok(dates == sorted, "oldest first by the DATE in the title (ids do not sort)")
	_ok(int((rels[0] as Dictionary)["id"]) == 10 and str((rels[0] as Dictionary)["date"]) == "2014-02-20",
		"release 10 is 2014-02-20")
	_ok(str((rels[-1] as Dictionary)["meta_url"]).contains("World_Imagery_Metadata_2026_r02"), "metadata URL kept")
	_ok(WaybackCatalog.release_date_of("World Imagery (Wayback 2019-06-26)") == "2019-06-26"
		and WaybackCatalog.release_date_of("no date") == "", "release date from the title")


func _test_tilemap_walk() -> void:
	var tm := WaybackCatalog.parse_tilemap('{"data":[1],"select":[64001],"valid":true}')
	_ok(bool(tm["has_tile"]) and int(tm["select"]) == 64001, "tilemap select read")
	var tm2 := WaybackCatalog.parse_tilemap('{"data":[1],"valid":true}')
	_ok(bool(tm2["has_tile"]) and int(tm2["select"]) == -1, "no select = this release changed it")
	_ok(not bool(WaybackCatalog.parse_tilemap('{"data":[0]}')["has_tile"]), "data 0 = no tile")
	# Ten releases, the tile changed at r2, r5 and r9 (oldest first).
	var rels: Array = []
	for i in 10:
		rels.append({"id": 100 + i, "date": "2015-%02d-01" % (i + 1)})
	var changed_at := {9: 109, 8: 105, 7: 105, 6: 105, 5: 105, 4: 102, 3: 102, 2: 102, 1: 100, 0: 100}
	var asked: Array = []
	var answer := func(rid: int) -> Dictionary:
		asked.append(rid)
		var sel := int(changed_at[rid - 100])
		return {"has_tile": true, "select": -1 if sel == rid else sel}
	var visited := WaybackCatalog.walk(rels, answer)
	_ok(visited == [109, 105, 102, 100], "the walk visits each change once (%s)" % str(visited))
	_ok(asked.size() == 4, "one request per change (%d)" % asked.size())


func _test_metadata() -> void:
	var m := WaybackCatalog.parse_metadata(_read("wayback_metadata_645.json"))
	_ok(bool(m["ok"]) and str(m["date"]) == "2017-09-10", "release 645 shows the 2017-09-10 capture")
	_ok(str(m["sensor"]) == "WV02" and str(m["provider"]) == "DigitalGlobe", "sensor + provider")
	_near(float(m["res_m"]), 0.5, 1e-6, "0.5 m capture")
	_ok(WaybackCatalog.meta_covers_zoom(m, 17), "covers z17")
	var hi := {"ok": true, "min_zoom": 19, "max_zoom": 19}
	_ok(not WaybackCatalog.meta_covers_zoom(hi, 17), "a z19-only feature is not the z17 photo (look further out)")
	_ok(not bool(WaybackCatalog.parse_metadata('{"features":[]}')["ok"]), "no feature: not ok")


## The real Bombay Beach walk at z17 (2026-10-23): 14 releases changed the
## centre tile; their metadata names 9 captures.
func _bombay_obs() -> Array:
	var rows := [
		[64001, "2026-02-26", "2024-08-07", "WV03", "Vantor", 0.31],
		[49849, "2024-11-18", "2024-08-07", "WV03", "Maxar", 0.31],
		[56102, "2023-12-07", "2022-09-23", "WV02", "Maxar", 0.5],
		[25982, "2023-06-13", "2022-04-13", "WV02", "Maxar", 0.5],
		[44988, "2022-10-12", "2022-04-13", "WV02", "Maxar", 0.5],
		[26120, "2021-12-21", "2020-01-31", "WV02", "Maxar", 0.5],
		[27659, "2021-04-28", "2020-01-31", "WV02", "Maxar", 0.5],
		[11135, "2020-06-10", "2019-02-23", "WV03", "Maxar", 0.31],
		[645, "2019-06-26", "2017-09-10", "WV02", "DigitalGlobe", 0.5],
		[11334, "2018-06-27", "2017-09-10", "WV02", "DigitalGlobe", 0.5],
		[13161, "2018-01-08", "2016-06-28", "WV02", "DigitalGlobe", 0.5],
		[14342, "2017-05-31", "2011-06-23", "UC-G", "Microsoft", 0.3],
		[24007, "2015-07-08", "2011-06-23", "UC-G", "Microsoft", 0.3],
		[10, "2014-02-20", "2011-06-23", "UC-G", "Microsoft", 0.3],
	]
	var out: Array = []
	for r in rows:
		out.append({"release": r[0], "release_date": r[1], "date": r[2], "sensor": r[3], "provider": r[4], "res_m": r[5]})
	return out


func _test_dedupe() -> void:
	var caps := WaybackCatalog.dedupe(_bombay_obs())
	var dates: Array = caps.map(func(c: Dictionary) -> String: return str(c["date"]))
	_ok(dates == ["2011-06-23", "2016-06-28", "2017-09-10", "2019-02-23", "2020-01-31",
		"2022-04-13", "2022-09-23", "2024-08-07"], "8 distinct captures, oldest first (%s)" % str(dates))
	var newest: Dictionary = caps[-1]
	_ok(int(newest["release"]) == 64001 and str(newest["provider"]) == "Vantor",
		"the newest release of a capture is kept (2024-08-07 → 64001)")
	_ok((newest["releases"] as Array).size() == 2, "both releases of that capture remembered")
	_ok(int((caps[0] as Dictionary)["release"]) == 14342, "2011 capture → its newest release 14342")
	_ok(int(WaybackCatalog.capture_at(caps, "1995-06-01").get("release", 0)) == 14342,
		"before the first capture: the first")
	_ok(str(WaybackCatalog.capture_at(caps, "2018-05-01")["date"]) == "2017-09-10", "2018-05 → the 2017-09-10 photo")
	_ok(str(WaybackCatalog.capture_at(caps, "2022-04-13")["date"]) == "2022-04-13", "on a capture's date: that capture")
	_ok(str(WaybackCatalog.capture_at(caps, "2026-10-23")["date"]) == "2024-08-07", "today → the newest")
	_ok(WaybackCatalog.capture_at([], "2020-01-01").is_empty(), "no captures: {}")
	_ok(str(WaybackCatalog.capture_of_release(caps, 11334).get("date", "")) == "2017-09-10",
		"a repeat release finds its capture")
	_ok(WaybackCatalog.capture_label(newest).begins_with("2024-08-07 · WV03"), "picker label")


func _test_wayback_source() -> void:
	var id := ImagerySources.wayback_id(645)
	_ok(id == "wayback_645" and ImagerySources.is_wayback(id) and ImagerySources.has(id), "wayback source id")
	_ok(not ImagerySources.is_wayback("wayback_x") and not ImagerySources.is_wayback("esri"), "not a wayback id")
	_ok(ImagerySources.tile_url(id, 17, 23400, 52641).ends_with("/tile/645/17/52641/23400"),
		"tile URL is release/level/row/col")
	ImagerySources.wayback_meta[645] = {"date": "2017-09-10", "provider": "DigitalGlobe", "res_m": 0.5,
		"release_date": "2019-06-26"}
	_ok(ImagerySources.attribution_for([id]).contains("Wayback") and ImagerySources.attribution_for([id]).contains("DigitalGlobe"),
		"attribution names Wayback and the provider")
	ImagerySources.wayback_meta.clear()
	var key := _IMG.layer_key(33.356, -115.7266, 1500.0, 4096, 19, [id])
	_ok(key.ends_with("_wayback_645"), "the release is in the cache key (%s)" % key)
	_ok(_IMG.cache_candidates(key).size() == 2, "no fallback to today's plain mosaic for an archived layer")
	var today := _IMG.layer_key(33.356, -115.7266, 1500.0, 4096, 19, ["esri_clarity", "esri"])
	_ok(_IMG.cache_candidates(today).size() == 4, "other chained layers keep their plain fallback")


func _test_record() -> void:
	_ok(ShorelineHistory.normalize_record({}) == {"mode": "current", "release": -1}, "empty record = today's imagery")
	_ok(str(ShorelineHistory.normalize_record({"mode": "pinned"})["mode"]) == "current", "pinned without a release = current")
	var r := ShorelineHistory.normalize_record({"mode": "pinned", "release": 645, "lake_level": false})
	_ok(int(r["release"]) == 645 and r["lake_level"] == false, "pinned + lake level off kept")
	_ok(str(ShorelineHistory.normalize_record({"mode": "sideways"})["mode"]) == "current", "unknown mode = current")


## A lake on the west, a beach rising east, a berm, and a hollow behind it
## lower than the berm: the hollow floods only once the lake tops the berm.
func _test_spill() -> void:
	var n := 41
	var half := 200.0
	var h := PackedFloat32Array()
	h.resize(n * n)
	for r in n:
		for c in n:
			var g := -10.0 + 0.5 * float(c)        # beach rising east, 0.5 m a cell
			if c >= 20 and c <= 21:
				g = 2.0                             # the berm, crest +2
			elif c >= 22 and c <= 30:
				g = -3.0                            # the hollow behind it
			h[r * n + c] = g
	var lake := PackedVector2Array([Vector2(-210, -210), Vector2(-150, -210), Vector2(-150, 210), Vector2(-210, 210)])
	var sd := LakeSpill.seeds(h, n, half, [lake], -8.0)
	var seeded := 0
	for i in sd.size():
		seeded += sd[i]
	_ok(seeded > 0, "lake cells seeded (%d)" % seeded)
	var sp := LakeSpill.spill(h, n, sd)
	var cell := 2.0 * half / float(n - 1)
	var x_of := func(c: int) -> float: return -half + float(c) * cell
	_near(LakeSpill.spill_at(sp, n, half, x_of.call(25), 0.0), 2.0, 1e-5, "the hollow's spill is the berm crest")
	_ok(LakeSpill.spill_at(sp, n, half, x_of.call(25), 0.0) > h[20 * n + 25], "the hollow is below its spill")
	_near(LakeSpill.spill_at(sp, n, half, x_of.call(10), 0.0), h[20 * n + 10], 1e-5, "open beach: spill = ground")
	var level := -1.0
	_ok(not (LakeSpill.spill_at(sp, n, half, x_of.call(25), 0.0) < level) and h[20 * n + 25] < level,
		"at -1 m the hollow (ground -3) stays dry behind the +2 berm")
	_ok(LakeSpill.spill_at(sp, n, half, x_of.call(15), 0.0) < level, "at -1 m the open beach below it is wet")
	# A DIAGONAL berm (one crest cell per row, stepping a column each row):
	# the cells touch only at corners, and must still hold the water back.
	var h2 := PackedFloat32Array()
	h2.resize(n * n)
	for r in n:
		for c in n:
			h2[r * n + c] = 2.0 if c == r else (-10.0 if c < r else -3.0)
	var sd2 := PackedByteArray()
	sd2.resize(n * n)
	sd2[(n - 1) * n] = 1   # the lake: the far corner below the diagonal
	var sp2 := LakeSpill.spill(h2, n, sd2)
	_ok(sp2[0 * n + (n - 1)] >= 2.0 - 1e-5,
		"a diagonal berm holds: the far side spills only over the crest (%.2f)" % sp2[n - 1])
	var none := PackedByteArray()
	none.resize(n * n)
	_ok(LakeSpill.spill(h, n, none)[0] == LakeSpill.UNREACHED, "no seed: nothing reachable")
