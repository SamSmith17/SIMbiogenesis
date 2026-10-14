extends SceneTree

## Offline deterministic selftest for the points-of-interest import
## (core/poi/): KmlPoiParser over the shipped Google Earth export of the Mount
## Vernon property (testdata/compoundity.kml — 11 pins + 4 lines, HTML
## descriptions, CascadingStyle/StyleMap colours, a MultiGeometry case built
## in-line), the KMZ path through a zip written to a TEMP folder, PoiLayer
## records / stable ids / idempotent re-import / file round-trip against a
## TEMP path, the WGS84 → site-metre mapping pinned against GeoMath by hand
## (the House pin is ~7 m east and ~7 m south of the site centre), the
## WorldPaths registration (legacy path byte-identical, dir-world path), and
## PoiRuntime building one marker per record on a flat ground callable.
##
## Carries EXPECTED_CHECKS because a Godot runtime error aborts the enclosing
## test function while the suite still prints PASS.
##
## Run: Godot.exe.exe --headless --path . --import   (once, new class_names)
##      Godot.exe.exe --headless --path . --script core/poi/poi_selftest.gd

const EXPECTED_CHECKS := 121
const FIXTURE := "res://core/poi/testdata/compoundity.kml"
const TMP_DIR := "user://selftest_tmp_poi"
## Mount Vernon site centre (the loader's _lat/_lon for that map).
const LAT := 48.3252
const LON := -122.2469

var _fails := 0
var _checks := 0


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [name, detail])


func _near(a: float, b: float, eps: float) -> bool:
	return absf(a - b) <= eps


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP_DIR))
	_test_parser_fixture()
	_test_parser_helpers()
	_test_parser_multigeometry_and_folders()
	_test_kmz()
	_test_layer_records()
	_test_layer_roundtrip()
	_test_world_mapping()
	_test_world_paths()
	_test_runtime()
	_cleanup_tmp()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		push_error("FAIL: check count drifted — expected %d, ran %d (a runtime error aborted a test function?)" % [EXPECTED_CHECKS, _checks])
	if _fails == 0:
		print("POI SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("POI SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(0 if _fails == 0 else 1)


func _fixture() -> Dictionary:
	return KmlPoiParser.parse_file(FIXTURE)


func _find(pms: Array, name: String) -> Dictionary:
	for pm in pms:
		if str(pm.get("name", "")) == name:
			return pm
	return {}


func _test_parser_fixture() -> void:
	var r := _fixture()
	_check("fixture parses", bool(r.get("ok", false)), str(r.get("error", "")))
	_check("document name", str(r.get("name", "")) == "Compoundity", str(r.get("name", "")))
	var pms: Array = r.get("placemarks", [])
	_check("15 placemarks", pms.size() == 15, str(pms.size()))
	var points := 0
	var lines := 0
	for pm in pms:
		if str(pm["kind"]) == KmlPoiParser.KIND_POINT:
			points += 1
		elif str(pm["kind"]) == KmlPoiParser.KIND_LINE:
			lines += 1
	_check("11 points", points == 11, str(points))
	_check("4 lines", lines == 4, str(lines))
	_check("no warnings on the real export", (r.get("warnings", []) as Array).is_empty(), str(r.get("warnings", [])))

	var house := _find(pms, "House")
	_check("House found", not house.is_empty())
	if not house.is_empty():
		_check("House kml id", str(house["kml_id"]) == "0E1A59DB093A6D7F9133")
		var c: Array = house["coords"][0]
		# 1e-9°: coordinates must survive as 64-bit floats (a Vector3 would
		# already be a metre off here).
		_check("House lon", _near(float(c[0]), -122.2468056, 1e-9), str(c))
		_check("House lat", _near(float(c[1]), 48.3251389, 1e-9), str(c))
		_check("House alt 0", _near(float(c[2]), 0.0, 1e-9))
		# Point style: no IconStyle colour, so the Google Earth icon URL's colour.
		_check("House colour from icon href", str(house["color"]) == "#1976d2", str(house["color"]))
		_check("House has no description", str(house["description"]).is_empty())

	var pond := _find(pms, "Pond")
	_check("Pond keeps its altitude", not pond.is_empty() and _near(float(pond["coords"][0][2]), 113.7831840051151, 1e-9))

	var ravine := _find(pms, "Intersection of Path and Ravine")
	_check("Ravine found", not ravine.is_empty())
	if not ravine.is_empty():
		_check("HTML description stripped to words",
			str(ravine["description"]) == "bottom path, ravine below pond outlet drainage",
			"[%s]" % str(ravine["description"]))

	var upper := _find(pms, "Upper Culvert")
	_check("CDATA description with <br> stripped", not upper.is_empty() and str(upper["description"]) == "Upper Culvert",
		"[%s]" % str(upper.get("description", "")))

	var hill := _find(pms, "Longest Possible Run from Hillside")
	_check("Hillside line found", not hill.is_empty())
	if not hill.is_empty():
		_check("Hillside line is a line", str(hill["kind"]) == KmlPoiParser.KIND_LINE)
		_check("Hillside line 9 vertices", (hill["coords"] as Array).size() == 9, str((hill["coords"] as Array).size()))
		var first: Array = hill["coords"][0]
		_check("Hillside first vertex", _near(float(first[0]), -122.2473462444882, 1e-11) and _near(float(first[1]), 48.32523350848468, 1e-11))
		# StyleMap __managed_style_2D75… → normal → LineStyle ff2dc0fb (aabbggrr) → #fbc02d.
		_check("line colour via StyleMap normal pair", str(hill["color"]) == "#fbc02d", str(hill["color"]))
	var pond_run := _find(pms, "Longest Possible Run From Pond")
	_check("pond run colour (ffd27619 → #1976d2)", not pond_run.is_empty() and str(pond_run["color"]) == "#1976d2",
		str(pond_run.get("color", "")))
	# Two placemarks share a name; both must survive as separate entries.
	var dup := 0
	for pm in pms:
		if str(pm["name"]) == "Longest Possible Run from Hillside":
			dup += 1
	_check("duplicate names both kept", dup == 2, str(dup))
	var drain := _find(pms, "Existing Pond Drainage Run")
	_check("2-vertex line kept", not drain.is_empty() and (drain["coords"] as Array).size() == 2)


func _test_parser_helpers() -> void:
	_check("kml colour aabbggrr → #rrggbb", KmlPoiParser.kml_color_to_html("ff2dc0fb") == "#fbc02d")
	_check("kml colour 6-digit tolerated", KmlPoiParser.kml_color_to_html("2dc0fb") == "#fbc02d")
	_check("kml colour garbage → empty", KmlPoiParser.kml_color_to_html("zz") == "")
	_check("icon href colour", KmlPoiParser.icon_href_color("https://earth.google.com/earth/document/icon?color=1976d2&id=2000") == "#1976d2")
	_check("icon href without colour", KmlPoiParser.icon_href_color("https://x/icon.png") == "")
	var coords := KmlPoiParser.parse_coordinates("\n\t -1.5,2.25,7 3,4 \n 5,6,x bad 100,200,0")
	_check("coordinates: 3 valid tuples", coords.size() == 3, str(coords))
	if coords.size() == 3:
		_check("coordinates: lon,lat,alt order", coords[0] == [-1.5, 2.25, 7.0], str(coords[0]))
		_check("coordinates: alt optional", coords[1] == [3.0, 4.0, 0.0], str(coords[1]))
		_check("coordinates: non-numeric alt → 0", coords[2] == [5.0, 6.0, 0.0], str(coords[2]))
	_check("strip_html words + newlines", KmlPoiParser.strip_html("<div>Hello <b>there</b><br>again &amp; more</div>") == "Hello there\nagain & more",
		"[%s]" % KmlPoiParser.strip_html("<div>Hello <b>there</b><br>again &amp; more</div>"))
	_check("strip_html plain text untouched", KmlPoiParser.strip_html("  plain  ") == "plain")
	var bad := KmlPoiParser.parse_text("this is not xml at all")
	_check("non-XML fails cleanly", not bool(bad["ok"]) and not str(bad["error"]).is_empty())
	var nokml := KmlPoiParser.parse_text("<?xml version=\"1.0\"?><root><Placemark><name>x</name></Placemark></root>")
	_check("no <kml> root fails cleanly", not bool(nokml["ok"]))
	var missing := KmlPoiParser.parse_file("user://definitely_missing_file.kml")
	_check("missing file fails cleanly", not bool(missing["ok"]))


const MULTI_KML := """<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>Multi</name>
<Style id="red"><IconStyle><color>ff0000ff</color></IconStyle><LineStyle><color>ff00ff00</color></LineStyle></Style>
<Folder><name>Hydro</name>
<Placemark id="m1"><name>Both</name><styleUrl>#red</styleUrl><MultiGeometry>
<Point><coordinates>-122.1,48.1,5</coordinates></Point>
<LineString><coordinates>-122.1,48.1,0 -122.2,48.2,0</coordinates></LineString>
</MultiGeometry></Placemark>
<Placemark><name>Field</name><Polygon><outerBoundaryIs><LinearRing><coordinates>
-122.0,48.0,0 -122.0,48.01,0 -121.99,48.01,0 -121.99,48.0,0 -122.0,48.0,0
</coordinates></LinearRing></outerBoundaryIs><innerBoundaryIs><LinearRing><coordinates>
-121.995,48.005,0 -121.995,48.006,0 -121.994,48.006,0 -121.995,48.005,0
</coordinates></LinearRing></innerBoundaryIs></Polygon></Placemark>
<Placemark><name>Empty</name><Point><coordinates></coordinates></Point></Placemark>
<Placemark><name>Nameless geometry</name></Placemark>
</Folder>
<Placemark><Point><coordinates>1,2,0</coordinates></Point></Placemark>
</Document></kml>"""


func _test_parser_multigeometry_and_folders() -> void:
	var r := KmlPoiParser.parse_text(MULTI_KML)
	_check("multi parses", bool(r["ok"]), str(r.get("error", "")))
	var pms: Array = r["placemarks"]
	# Both (2 geoms) + Field + the nameless point = 4; Empty and the geometry-less one are skipped.
	_check("multi: 4 entries", pms.size() == 4, str(pms.size()))
	var both := _find(pms, "Both")
	var both2 := _find(pms, "Both (2)")
	_check("multi: first geometry keeps the name", not both.is_empty() and str(both["kind"]) == KmlPoiParser.KIND_POINT)
	_check("multi: second geometry suffixed", not both2.is_empty() and str(both2["kind"]) == KmlPoiParser.KIND_LINE)
	_check("multi: point colour from IconStyle (ff0000ff → #ff0000)", not both.is_empty() and str(both["color"]) == "#ff0000", str(both.get("color", "")))
	_check("multi: line colour from LineStyle (ff00ff00 → #00ff00)", not both2.is_empty() and str(both2["color"]) == "#00ff00", str(both2.get("color", "")))
	_check("multi: folder recorded", not both.is_empty() and str(both["folder"]) == "Hydro", str(both.get("folder", "")))
	_check("multi: shared kml id on both halves", not both2.is_empty() and str(both2["kml_id"]) == "m1")
	var field := _find(pms, "Field")
	_check("polygon kind", not field.is_empty() and str(field["kind"]) == KmlPoiParser.KIND_POLYGON)
	_check("polygon: closing vertex dropped, hole ignored", not field.is_empty() and (field["coords"] as Array).size() == 4,
		str((field.get("coords", []) as Array).size()))
	var warns: Array = r["warnings"]
	_check("multi: empty coordinates warned", warns.size() >= 2, str(warns))
	var nameless := _find(pms, "")
	_check("nameless point kept with empty name", not nameless.is_empty())


func _test_kmz() -> void:
	var kmz := TMP_DIR + "/fixture.kmz"
	var zp := ZIPPacker.new()
	_check("kmz: zip writer opens", zp.open(kmz) == OK)
	var f := FileAccess.open(FIXTURE, FileAccess.READ)
	var text := f.get_as_text()
	f.close()
	zp.start_file("images/readme.txt")
	zp.write_file("not the document".to_utf8_buffer())
	zp.close_file()
	zp.start_file("doc.kml")
	zp.write_file(text.to_utf8_buffer())
	zp.close_file()
	zp.close()
	var r := KmlPoiParser.parse_file(kmz)
	_check("kmz parses doc.kml", bool(r["ok"]), str(r.get("error", "")))
	_check("kmz: same 15 placemarks", (r["placemarks"] as Array).size() == 15)
	var bad := TMP_DIR + "/bad.kmz"
	var bf := FileAccess.open(bad, FileAccess.WRITE)
	bf.store_string("not a zip")
	bf.close()
	var br := KmlPoiParser.parse_file(bad)
	_check("kmz: corrupt zip fails cleanly", not bool(br["ok"]))


func _test_layer_records() -> void:
	var r := _fixture()
	var layer := PoiLayer.create_empty()
	var res := layer.import_kml(r, "compoundity.kml")
	_check("import adds 15", int(res["added"]) == 15, str(res))
	_check("import replaced 0 on first run", int(res["replaced"]) == 0)
	_check("layer count 15", layer.count() == 15)
	var ids: Array = []
	for rec in layer.records:
		ids.append(str(rec["id"]))
	var first_ids := ids.duplicate()
	# Re-import = replace, never double.
	var res2 := layer.import_kml(r, "compoundity.kml")
	_check("re-import replaces 15", int(res2["replaced"]) == 15, str(res2))
	_check("re-import still 15", layer.count() == 15)
	var ids2: Array = []
	for rec in layer.records:
		ids2.append(str(rec["id"]))
	_check("ids stable across re-import", ids2 == first_ids)
	_check("ids unique", _unique(ids2))
	# A second source stacks.
	var r2 := KmlPoiParser.parse_text(MULTI_KML)
	layer.import_kml(r2, "multi.kml")
	_check("second source stacks (19)", layer.count() == 19, str(layer.count()))
	_check("sources lists both", layer.sources() == ["compoundity.kml", "multi.kml"], str(layer.sources()))
	_check("remove_source drops 4", layer.remove_source("multi.kml") == 4 and layer.count() == 15)

	var house: Dictionary = {}
	var hill: Dictionary = {}
	for rec in layer.records:
		if str(rec["name"]) == "House":
			house = rec
		elif str(rec["name"]) == "Longest Possible Run from Hillside" and hill.is_empty():
			hill = rec
	_check("record: point lat/lon", not house.is_empty() and _near(float(house["lat"]), 48.3251389, 1e-7) and _near(float(house["lon"]), -122.2468056, 1e-7))
	_check("record: point has no points list", not house.is_empty() and not house.has("points"))
	_check("record: source + kml id", not house.is_empty() and str(house["source"]) == "compoundity.kml" and str(house["kml_id"]) == "0E1A59DB093A6D7F9133")
	_check("record: line carries 9 [lat, lon] pairs", not hill.is_empty() and (hill["points"] as Array).size() == 9
		and (hill["points"][0] as Array).size() == 2 and _near(float(hill["points"][0][0]), 48.32523350848468, 1e-9))
	_check("record: line anchor is the vertex mean", not hill.is_empty() and _near(float(hill["lat"]), 48.325664, 2e-4) and _near(float(hill["lon"]), -122.24685, 5e-4),
		"%s %s" % [str(hill.get("lat", 0)), str(hill.get("lon", 0))])
	_check("record: colour kept", not hill.is_empty() and str(hill["color"]) == "#fbc02d")
	_check("get_record by id", not house.is_empty() and layer.get_record(str(house["id"])) == house)
	_check("get_record miss → {}", layer.get_record("nope").is_empty())
	_check("remove by id", not house.is_empty() and layer.remove(str(house["id"])) and layer.count() == 14)
	_check("remove miss false", not layer.remove("nope"))
	layer.clear()
	_check("clear empties", layer.count() == 0 and layer.sources().is_empty())
	# A nameless placemark gets a readable fallback name.
	var rec := PoiLayer.record_from_placemark({"kind": "point", "coords": [[1.0, 2.0, 0.0]]}, "x.kml", 4)
	_check("nameless record named Pin N", str(rec["name"]) == "Pin 5", str(rec.get("name", "")))
	_check("record_from_placemark without coords → {}", PoiLayer.record_from_placemark({"kind": "point", "coords": []}, "x", 0).is_empty())
	_check("color_of default point is blue-ish", PoiLayer.color_of({"kind": "point"}).b > 0.8)
	_check("color_of default line is amber", PoiLayer.color_of({"kind": "line"}).r > 0.9)
	_check("color_of parses html", PoiLayer.color_of({"color": "#ff0000"}).is_equal_approx(Color(1, 0, 0)))


func _unique(arr: Array) -> bool:
	var seen := {}
	for v in arr:
		if seen.has(v):
			return false
		seen[v] = true
	return true


func _test_layer_roundtrip() -> void:
	var path := TMP_DIR + "/poi.json"
	var layer := PoiLayer.create_empty()
	layer.import_kml(_fixture(), "compoundity.kml")
	_check("save_to writes", layer.save_to(path))
	var back := PoiLayer.create_empty()
	_check("load_from reads", back.load_from(path))
	_check("round-trip count", back.count() == 15)
	_check("round-trip records identical", JSON.stringify(back.serialize()) == JSON.stringify(layer.serialize()))
	_check("round-trip keeps points as arrays", (back.get_record(str(layer.records[11]["id"]))["points"] as Array).size() >= 2)
	var missing := PoiLayer.create_empty()
	_check("load_from missing → false, empty", not missing.load_from(TMP_DIR + "/none.json") and missing.count() == 0)
	var junk := FileAccess.open(path, FileAccess.WRITE)
	junk.store_string("[not json")
	junk.close()
	_check("corrupt file → false, empty", not back.load_from(path) and back.count() == 0)
	# Deserialize drops what it cannot place, keeps the rest.
	var ok := PoiLayer.create_empty().deserialize({"records": [
		{"id": "a", "lat": 1.0, "lon": 2.0},
		{"id": "", "lat": 1.0, "lon": 2.0},
		{"id": "b", "lat": "x", "lon": 2.0},
		{"id": "c", "lat": 200.0, "lon": 2.0},
		{"id": "d", "lat": 1.0, "lon": 2.0, "kind": "line", "points": [[1, 2]]},
		{"id": "e", "lat": 1.0, "lon": 2.0, "kind": "line", "points": [[1, 2], [3, 4]]},
		"junk",
	]})
	_check("deserialize accepts the list", ok)
	var l2 := PoiLayer.create_empty()
	l2.deserialize({"records": [
		{"id": "a", "lat": 1.0, "lon": 2.0},
		{"id": "", "lat": 1.0, "lon": 2.0},
		{"id": "b", "lat": "x", "lon": 2.0},
		{"id": "c", "lat": 200.0, "lon": 2.0},
		{"id": "d", "lat": 1.0, "lon": 2.0, "kind": "line", "points": [[1, 2]]},
		{"id": "e", "lat": 1.0, "lon": 2.0, "kind": "line", "points": [[1, 2], [3, 4]]},
		"junk",
	]})
	_check("deserialize keeps only the valid 2", l2.count() == 2, str(l2.count()))
	_check("deserialize fills a missing kind", str(l2.records[0]["kind"]) == "point")
	_check("deserialize rejects a non-list", not PoiLayer.create_empty().deserialize({"records": "x"}))


func _test_world_mapping() -> void:
	# House: 48.3251389, -122.2468056 against the site centre 48.3252, -122.2469.
	# Δlon = +0.0000944° × (111320 × cos 48.3252°) ≈ +6.99 m east;
	# Δlat = −0.0000611° × 111320 ≈ 6.80 m SOUTH (+Z).
	var house := {"lat": 48.3251389, "lon": -122.2468056}
	var xz := PoiLayer.world_xz(house, LAT, LON)
	_check("House ~7 m east of centre", _near(xz.x, 6.99, 0.15), str(xz))
	_check("House ~6.8 m south (+Z) of centre", _near(xz.y, 6.80, 0.15), str(xz))
	var ref := GeoMath.lonlat_to_local_m(48.3251389, -122.2468056, LAT, LON)
	_check("world_xz == GeoMath.lonlat_to_local_m", xz == ref)
	# Top Culvert Inlet is north-east of the centre: x > 0, z < 0.
	var top := PoiLayer.world_xz({"lat": 48.3260278, "lon": -122.2461667}, LAT, LON)
	_check("Top Culvert Inlet NE: x > 0, z < 0", top.x > 50.0 and top.y < -80.0, str(top))
	_check("Top Culvert ~92 m north", _near(-top.y, 92.1, 0.5), str(top))
	# Round trip through the inverse.
	# GeoMath's inverse returns a Vector2 of DEGREES (float32), so ~1e-5° is
	# its own floor; the layer never round-trips through it (records keep the
	# 64-bit values), this just pins the two mappings as inverses.
	var back := GeoMath.local_m_to_lonlat(top.x, top.y, LAT, LON)
	_check("inverse recovers lat/lon", _near(back.y, 48.3260278, 2e-5) and _near(back.x, -122.2461667, 2e-5), str(back))
	var line := {"kind": "line", "points": [[48.3252, -122.2469], [48.3252, -122.2459]]}
	var pts := PoiLayer.points_world_xz(line, LAT, LON)
	_check("line points: 2 vertices", pts.size() == 2)
	_check("line points: first at the centre", pts.size() == 2 and pts[0].is_equal_approx(Vector2.ZERO), str(pts))
	_check("line points: 0.001° lon ≈ 74 m east", pts.size() == 2 and _near(pts[1].x, 74.0, 0.5) and _near(pts[1].y, 0.0, 1e-6), str(pts))
	_check("points_world_xz on a point record → empty", PoiLayer.points_world_xz(house, LAT, LON).is_empty())


func _test_world_paths() -> void:
	var found := false
	for k in WorldPaths.KINDS:
		if str(k[0]) == "poi" and str(k[1]) == "json":
			found = true
	_check("WorldPaths.KINDS carries poi.json", found)
	_check("legacy path byte-identical to the per-site literal",
		PoiLayer.save_path_for_map(LAT, LON) == "user://maps/poi_48p3252_n122p2469.json",
		PoiLayer.save_path_for_map(LAT, LON))
	_check("scene path", PoiLayer.save_path_for_scene("res://scenes/maps/soak_festival_2026.tscn") == "user://maps/poi_scene_soak_festival_2026.json",
		PoiLayer.save_path_for_scene("res://scenes/maps/soak_festival_2026.tscn"))
	var key := WorldPaths.site_key_for(LAT, LON)
	WorldPaths.set_active("w_test", "user://worlds/w_test", WorldPaths.STORAGE_DIR, key)
	_check("dir-world path", PoiLayer.save_path_for_map(LAT, LON) == "user://worlds/w_test/poi.json", PoiLayer.save_path_for_map(LAT, LON))
	WorldPaths.clear_active()
	_check("back to legacy after clear", PoiLayer.save_path_for_map(LAT, LON) == "user://maps/poi_48p3252_n122p2469.json")


func _test_runtime() -> void:
	var layer := PoiLayer.create_empty()
	layer.import_kml(_fixture(), "compoundity.kml")
	var rt := PoiRuntime.new()
	root.add_child(rt)
	var ground := func(x: float, z: float) -> float:
		return 100.0 + 0.01 * x - 0.02 * z
	rt.sync(layer, LAT, LON, ground)
	_check("runtime: one marker per record", rt.marker_count() == 15, str(rt.marker_count()))
	var house: Dictionary = {}
	var hill: Dictionary = {}
	for rec in layer.records:
		if str(rec["name"]) == "House":
			house = rec
		elif str(rec["name"]) == "Longest Possible Run from Hillside" and hill.is_empty():
			hill = rec
	var hp := rt.marker_position(str(house["id"]))
	var exp_xz := PoiLayer.world_xz(house, LAT, LON)
	_check("runtime: House marker at its site xz", _near(hp.x, exp_xz.x, 1e-4) and _near(hp.z, exp_xz.y, 1e-4), str(hp))
	_check("runtime: House marker on the ground callable", _near(hp.y, 100.0 + 0.01 * exp_xz.x - 0.02 * exp_xz.y, 1e-4), str(hp))
	var hn: Node3D = rt.get_node_or_null("Poi_" + str(house["id"]))
	_check("runtime: point marker has a label with the name", hn != null and hn.get_node_or_null("Label") != null
		and str((hn.get_node("Label") as Label3D).text) == "House")
	_check("runtime: point marker has no ribbon", hn != null and hn.get_node_or_null("Ribbon") == null)
	var ln: Node3D = rt.get_node_or_null("Poi_" + str(hill["id"]))
	_check("runtime: line marker has a ribbon", ln != null and ln.get_node_or_null("Ribbon") != null)
	if ln != null and ln.get_node_or_null("Ribbon") != null:
		var mesh: ArrayMesh = (ln.get_node("Ribbon") as MeshInstance3D).mesh
		var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		_check("runtime: ribbon has 2 verts per sample, many samples", verts.size() >= 2 * 9 and verts.size() % 2 == 0, str(verts.size()))
		# Ribbon verts are world-space under a node offset by -root.position: the
		# first vertex pair straddles the line's first vertex.
		var first_xz := PoiLayer.points_world_xz(hill, LAT, LON)[0]
		var mid := (verts[0] + verts[1]) * 0.5
		_check("runtime: ribbon starts at the first vertex", _near(mid.x, first_xz.x, 1e-3) and _near(mid.z, first_xz.y, 1e-3), str(mid))
		_check("runtime: ribbon lifted off the ground", _near(mid.y, 100.0 + 0.01 * first_xz.x - 0.02 * first_xz.y + PoiRuntime.LINE_LIFT_M, 1e-3), str(mid.y))
	_check("runtime: missing id → INF", rt.marker_position("nope") == Vector3.INF)
	rt.set_shown(false)
	_check("runtime: hidden", hn != null and not hn.visible and not rt.is_shown())
	rt.set_shown(true)
	_check("runtime: shown again", hn != null and hn.visible)
	rt.sync(PoiLayer.create_empty(), LAT, LON, ground)
	_check("runtime: sync with an empty layer clears", rt.marker_count() == 0 and rt.get_child_count() == 0)
	rt.sync(null, LAT, LON, ground)
	_check("runtime: sync with null is safe", rt.marker_count() == 0)
	root.remove_child(rt)
	rt.free()


func _cleanup_tmp() -> void:
	var dir := DirAccess.open(TMP_DIR)
	if dir == null:
		return
	for f in dir.get_files():
		dir.remove(f)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_DIR))
