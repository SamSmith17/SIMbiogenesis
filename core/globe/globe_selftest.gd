extends SceneTree

## Offline deterministic selftest for the globe's pure maths (core/globe/):
## GlobeMath (sphere frame, round trips, ray picks, great circles, Web
## Mercator tile maths pinned against GeoMath, ancestor UV rects, the
## sub-solar point pinned against Meeus's SPA (SolarPosition) and the 2024
## equinox / solstice) and GlobeQuadtree (far view = low zooms only, a close
## view refines to street-block tiles over the target, nothing behind the
## globe, no tile drawn with its ancestor, the budget held, determinism).
##
## Carries EXPECTED_CHECKS because a Godot runtime error aborts the enclosing
## test function while the suite still prints PASS.
##
## Run: Godot.exe.exe --headless --path . --import   (once, new class_names)
##      Godot.exe.exe --headless --path . --script core/globe/globe_selftest.gd

const EXPECTED_CHECKS := 162

var _fails := 0
var _checks := 0


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [name, detail])


func _initialize() -> void:
	_test_frame()
	_test_ray_and_distance()
	_test_tiles()
	_test_sun()
	_test_quadtree()
	_test_overlay()
	_test_weather()
	_test_grib()
	_test_gfs_helpers()
	_test_wind_field()
	_test_drape()
	_test_solar_atlas()
	_test_labels_and_climate()
	_test_aurora()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		push_error("FAIL: ran %d checks, expected %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	if _fails == 0:
		print("globe_selftest: PASS (%d checks)" % _checks)
	else:
		print("globe_selftest: FAIL (%d of %d)" % [_fails, _checks])
	quit(1 if _fails > 0 else 0)


func _test_frame() -> void:
	_check("lat0 lon0 is +Z", GlobeMath.to_unit(0, 0).distance_to(Vector3(0, 0, 1)) < 1e-6)
	_check("lon 90E is +X", GlobeMath.to_unit(0, 90).distance_to(Vector3(1, 0, 0)) < 1e-6)
	_check("north pole is +Y", GlobeMath.to_unit(90, 17).distance_to(Vector3(0, 1, 0)) < 1e-6)
	var worst := 0.0
	var pts := [[48.3252, -122.2469], [-33.86, 151.21], [0.0, 179.9], [-89.0, -45.0], [64.1, -21.9]]
	for p in pts:
		var ll := GlobeMath.to_latlon(GlobeMath.to_unit(p[0], p[1]))
		worst = maxf(worst, maxf(absf(ll[0] - p[0]), absf(ll[1] - p[1])))
	_check("lat/lon round trip within float32 (2e-5 deg)", worst < 2e-5, "worst %.7f" % worst)
	var e := GlobeMath.east_at(30.0)
	var n := GlobeMath.north_at(10.0, 30.0)
	var u := GlobeMath.to_unit(10.0, 30.0)
	_check("east is tangent", absf(e.dot(u)) < 1e-6)
	_check("north is tangent", absf(n.dot(u)) < 1e-6)
	_check("north points to higher latitude",
		GlobeMath.to_latlon(u + n * 0.01)[0] > 10.0)
	_check("east points to higher longitude",
		GlobeMath.to_latlon(u + e * 0.01)[1] > 30.0)
	_check("up x east = north (right-handed, east to the right)", u.cross(e).distance_to(n) < 1e-5)
	var s := GlobeMath.slerp_dir(GlobeMath.to_unit(0, 0), GlobeMath.to_unit(0, 90), 0.5)
	_check("slerp halfway is lon 45", absf(GlobeMath.to_latlon(s)[1] - 45.0) < 1e-4)


func _test_ray_and_distance() -> void:
	var t := GlobeMath.ray_sphere(Vector3(0, 0, 3), Vector3(0, 0, -1))
	_check("ray from 3R hits at t=2", absf(t - 2.0) < 1e-6, str(t))
	_check("ray pointing away misses", GlobeMath.ray_sphere(Vector3(0, 0, 3), Vector3(0, 0, 1)) < 0.0)
	_check("ray past the limb misses", GlobeMath.ray_sphere(Vector3(0, 1.01, 3), Vector3(0, 0, -1)) < 0.0)
	_check("ray from inside hits the far side",
		absf(GlobeMath.ray_sphere(Vector3.ZERO, Vector3(1, 0, 0)) - 1.0) < 1e-6)
	# London - Paris ~ 343.5 km (haversine on the mean radius).
	var d := GlobeMath.great_circle_km(51.5074, -0.1278, 48.8566, 2.3522)
	_check("London-Paris great circle ~343.5 km", absf(d - 343.5) < 1.5, "%.1f" % d)
	_check("quarter meridian = pi/2 R",
		absf(GlobeMath.great_circle_km(0, 0, 90, 0) - PI * 0.5 * GlobeMath.EARTH_RADIUS_KM) < 0.01)


func _test_tiles() -> void:
	# Mercator rows vs GeoMath (the terrain's tile maths).
	var worst := 0.0
	for z in [1, 5, 12]:
		for y in [0, 1, (1 << z) / 3, (1 << z) - 1]:
			var g: Vector2 = GeoMath.tile_to_lonlat(0.0, float(y), z)
			worst = maxf(worst, absf(GlobeMath.mercator_lat(float(y) / float(1 << z)) - g.y))
	_check("mercator_lat matches GeoMath", worst < 1e-4, "%.7f" % worst)
	_check("row 0 edge = 85.0511", absf(GlobeMath.mercator_lat(0.0) - GlobeMath.MERCATOR_MAX_LAT) < 1e-9)
	_check("mercator_y inverts mercator_lat",
		absf(GlobeMath.mercator_y(GlobeMath.mercator_lat(0.3)) - 0.3) < 1e-9)
	var mv := GlobeMath.tile_at(48.3252, -122.2469, 12)
	var gm := GeoMath.lonlat_to_tile(-122.2469, 48.3252, 12)
	_check("tile_at matches GeoMath", mv.y == gm.x and mv.z == gm.y, "%s vs %s" % [mv, gm])
	var b := GlobeMath.tile_bounds(mv.x, mv.y, mv.z)
	_check("Mount Vernon inside its tile bounds",
		48.3252 <= b[0] and 48.3252 >= b[1] and -122.2469 >= b[2] and -122.2469 <= b[3])
	var c := GlobeMath.tile_point(mv.x, mv.y, mv.z, 0.5, 0.5)
	var cl := GlobeMath.to_latlon(c)
	_check("tile centre lon is the middle", absf(cl[1] - (b[2] + b[3]) * 0.5) < 1e-4)
	var anc := GlobeMath.ancestor(Vector3i(5, 13, 22), 3)
	_check("ancestor z5 -> z3", anc == Vector3i(3, 3, 5), str(anc))
	var r := GlobeMath.uv_rect_in(Vector3i(5, 13, 22), anc)
	_check("uv rect scale 1/4", is_equal_approx(r.z, 0.25) and is_equal_approx(r.w, 0.25))
	_check("uv rect offset (1/4, 2/4)", is_equal_approx(r.x, 0.25) and is_equal_approx(r.y, 0.5), str(r))
	_check("uv rect of self is identity",
		GlobeMath.uv_rect_in(Vector3i(4, 1, 2), Vector3i(4, 1, 2)) == Vector4(0, 0, 1, 1))


func _test_sun() -> void:
	# Pinned against Meeus's SPA: at the sub-solar point the Sun is overhead.
	var worst_el := 90.0
	for i in 12:
		var jd := 2460310.5 + float(i) * 31.37 + float(i) * 0.137   # 2024 through the year
		var s := GlobeMath.subsolar_point(jd)
		var el: float = float(SolarPosition.get_position(s[0], s[1], jd).elevation_deg)
		worst_el = minf(worst_el, el)
	_check("Sun overhead at the sub-solar point (SPA > 89.6 deg)", worst_el > 89.6, "%.3f" % worst_el)
	# 2024 March equinox 2024-03-20 03:06 UTC: declination ~ 0.
	var eq := GlobeMath.subsolar_point(GlobeMath.jd_from_unix(1710903960.0))
	_check("equinox: sub-solar latitude ~0", absf(eq[0]) < 0.05, "%.3f" % eq[0])
	# 2024 June solstice 2024-06-20 20:51 UTC: declination ~ +23.44.
	var so := GlobeMath.subsolar_point(GlobeMath.jd_from_unix(1718916660.0))
	_check("solstice: sub-solar latitude ~23.44", absf(so[0] - 23.44) < 0.05, "%.3f" % so[0])
	# Midnight UTC near the equinox: the Sun is over the antimeridian.
	var mid := GlobeMath.subsolar_point(GlobeMath.jd_from_unix(1710892800.0))
	_check("00:00 UTC: sub-solar lon near 180", absf(absf(mid[1]) - 180.0) < 3.0, "%.2f" % mid[1])
	var sd := GlobeMath.sun_dir(GlobeMath.jd_from_unix(1710892800.0))
	_check("sun_dir is unit", absf(sd.length() - 1.0) < 1e-5)


func _cam(lat: float, lon: float, alt: float, tilt_deg: float = 0.0) -> Dictionary:
	var p := GlobeMath.to_unit(lat, lon)
	var n := GlobeMath.north_at(lat, lon)
	var t := deg_to_rad(tilt_deg)
	var back := p * cos(t) - n * sin(t)
	var pos := p + back * alt
	var up_hint := n * cos(t) + p * sin(t)
	var xf := Transform3D(Basis.IDENTITY, pos).looking_at(p, up_hint)
	return {"pos": pos, "basis": xf.basis}


func _sel(c: Dictionary, max_zoom: int = 17, budget: int = 220) -> Array[Vector3i]:
	return GlobeQuadtree.select(c.pos, c.basis, 40.0, 16.0 / 9.0, 1080.0, max_zoom, budget)


func _no_ancestor_pairs(keys: Array[Vector3i]) -> bool:
	var set := {}
	for k in keys:
		set[k] = true
	for k in keys:
		for z in range(GlobeQuadtree.MIN_ZOOM, k.x):
			if set.has(GlobeMath.ancestor(k, z)):
				return false
	return true


func _test_quadtree() -> void:
	var far := _sel(_cam(20.0, 0.0, 3.0))
	var far_max := 0
	for k in far:
		far_max = maxi(far_max, k.x)
	_check("far view: tiles selected", far.size() > 0)
	_check("far view: low zooms only (<= 4)", far_max <= 4, "max z %d" % far_max)
	var behind := 0
	var dir := GlobeMath.to_unit(20.0, 0.0)
	for k in far:
		if GlobeMath.tile_point(k.x, k.y, k.z, 0.5, 0.5).dot(dir) < -0.3:
			behind += 1
	_check("far view: nothing on the far side", behind == 0, "%d behind" % behind)
	_check("far view: no tile with its ancestor", _no_ancestor_pairs(far))

	# Close over Mount Vernon (6 km up, looking down).
	var near_c := _cam(48.3252, -122.2469, 0.001)
	var near := _sel(near_c)
	var top := 0
	for k in near:
		top = maxi(top, k.x)
	_check("close view: refines to >= z11", top >= 11, "max z %d" % top)
	var under := GlobeMath.tile_at(48.3252, -122.2469, top)
	var covered := false
	for k in near:
		if GlobeMath.ancestor(under, k.x) == k:
			covered = true
	_check("close view: the target point is covered", covered)
	_check("close view: no tile with its ancestor", _no_ancestor_pairs(near))
	_check("close view: within the budget", near.size() <= 220, str(near.size()))
	_check("close view: deterministic", near == _sel(near_c))
	var far_off := 0
	for k in near:
		var b := GlobeMath.tile_bounds(k.x, k.y, k.z)
		if b[3] < -150.0 or b[2] > -90.0:
			far_off += 1
	_check("close view: nothing on the other side of the world", far_off == 0, str(far_off))
	# Every screen corner lands on a selected tile (a float32 acos once
	# rounded z14 tiles to 0 rad and culled the corner: a hole in the ground).
	var t := tan(deg_to_rad(20.0))
	var holes := 0
	for cc in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
		var d: Vector3 = (near_c.basis * Vector3(cc.x * t * 16.0 / 9.0, cc.y * t, -1.0)).normalized()
		var ll := GlobeMath.to_latlon(near_c.pos + d * GlobeMath.ray_sphere(near_c.pos, d))
		var hit := false
		for k in near:
			var b := GlobeMath.tile_bounds(k.x, k.y, k.z)
			if ll[0] <= b[0] and ll[0] >= b[1] and ll[1] >= b[2] and ll[1] <= b[3]:
				hit = true
		if not hit:
			holes += 1
	_check("close view: every screen corner is covered", holes == 0, "%d holes" % holes)
	var capped := _sel(near_c, 9)
	var cmax := 0
	for k in capped:
		cmax = maxi(cmax, k.x)
	_check("zoom cap respected", cmax <= 9, str(cmax))
	var small := _sel(near_c, 17, 30)
	_check("tiny budget respected", small.size() <= 30, str(small.size()))
	_check("tiny budget: still covers the view", small.size() > 0)

	# Tilted low view (horizon in frame): still bounded, still clean.
	var tilt := _sel(_cam(48.3252, -122.2469, 0.002, 70.0))
	_check("tilted: within the budget", tilt.size() <= 220, str(tilt.size()))
	_check("tilted: no tile with its ancestor", _no_ancestor_pairs(tilt))
	var tmax := 0
	var tmin := 99
	for k in tilt:
		tmax = maxi(tmax, k.x)
		tmin = mini(tmin, k.x)
	_check("tilted: near tiles finer than far tiles", tmax - tmin >= 3, "%d..%d" % [tmin, tmax])
	# Poles are caps, not tiles: a polar view still selects border rows.
	var pole := _sel(_cam(89.0, 0.0, 0.5))
	_check("polar view selects tiles", pole.size() > 0)
	var row0 := false
	for k in pole:
		if k.z == 0:
			row0 = true
	_check("polar view uses the top row", row0)


func _test_overlay() -> void:
	var ghi := func(lat: float, _lon: float) -> float: return 4.0 if lat > 0.0 else 2.0
	# A land test that is wrong on exactly one latitude (the Fiji row).
	var row_bug := func(_lon: float, lat: float) -> bool: return absf(lat + 16.5) < 1e-6
	var img := GlobeGhiOverlay.build_image(ghi, row_bug)
	var land := 0
	for x in GlobeGhiOverlay.W:
		if img.get_pixel(x, 106).g > 0.5:
			land += 1
	_check("overlay: a one-latitude land glitch is voted out", land == 0, "%d land px" % land)
	var north := func(_lon: float, lat: float) -> bool: return lat > 0.0
	var img2 := GlobeGhiOverlay.build_image(ghi, north)
	_check("overlay: northern land kept", img2.get_pixel(10, 40).g > 0.5)
	_check("overlay: southern sea is not land", img2.get_pixel(10, 140).g < 0.5)
	_check("overlay: GHI encoded as value / MAX_GHI",
		absf(img2.get_pixel(10, 40).r * GlobeGhiOverlay.MAX_GHI - 4.0) < 0.05,
		"%.3f" % (img2.get_pixel(10, 40).r * GlobeGhiOverlay.MAX_GHI))
	# A ring across the antimeridian (Fiji in Natural Earth 110m) and one that
	# spans every longitude (Antarctica).
	var fiji := PackedVector2Array([Vector2(178, -16), Vector2(-179, -16),
		Vector2(-179, -17.5), Vector2(178, -17.5)])
	var ant := PackedVector2Array([Vector2(-180, -70), Vector2(180, -70),
		Vector2(180, -90), Vector2(-180, -90)])
	var lt := GlobeGhiOverlay.land_test([fiji, ant])
	_check("land test: open ocean at Fiji's latitude is sea", not bool(lt.call(0.0, -16.8)))
	_check("land test: Fiji west of 180 is land", bool(lt.call(179.0, -16.8)))
	_check("land test: Fiji east of -180 is land", bool(lt.call(-179.5, -16.8)))
	_check("land test: Antarctica still land", bool(lt.call(0.0, -80.0)))


func _test_weather() -> void:
	var u := GlobeWeather.parse_iso("2026-11-05T19:00:00.000Z")
	_check("weather: ISO with millis + Z parses", u == float(Time.get_unix_time_from_datetime_string("2026-11-05T19:00:00")))
	_check("weather: iso() round trips", GlobeWeather.parse_iso(GlobeWeather.iso(u)) == u, GlobeWeather.iso(u))
	_check("weather: unix_from_jd inverts jd_from_unix",
		absf(GlobeWeather.unix_from_jd(GlobeMath.jd_from_unix(1.7e9)) - 1.7e9) < 0.01)
	var caps := "<Layer><Name>other</Name><Dimension name=\"time\">2020-01-01T00:00:00Z</Dimension></Layer>" \
		+ "<Layer><Name>global_longwave_imagery_mosaic</Name><Title>x</Title>" \
		+ "<Dimension name=\"time\" default=\"2026-11-05T23:00:00Z\" units=\"ISO8601\">" \
		+ "2026-11-05T22:00:00.000Z,2026-11-05T19:00:00.000Z,2026-11-05T21:00:00.000Z</Dimension></Layer>"
	var times := GlobeWeather.layer_times(caps, GlobeWeather.CLOUD_LAYER)
	_check("weather: the cloud layer's times, sorted", times.size() == 3 and times[0] == u,
		str(times))
	_check("weather: nearest frame inside the gap", GlobeWeather.nearest_frame(times, u + 1500.0, 1.5) == 0)
	_check("weather: no frame beyond the gap", GlobeWeather.nearest_frame(times, u - 3.0 * 3600.0, 1.5) == -1)
	var now := u + 10.0 * 3600.0
	var slot := GlobeWeather.rain_slot(u + 1000.0, now)
	_check("weather: rain slot floors to the half hour", slot == u, GlobeWeather.iso(slot))
	var late := GlobeWeather.rain_slot(now, now)
	_check("weather: rain slot never newer than the latency",
		late <= now - GlobeWeather.RAIN_LATENCY_H * 3600.0 and fmod(late, 1800.0) == 0.0, GlobeWeather.iso(late))
	_check("weather: satellite date is yesterday at the newest",
		GlobeWeather.daily_date(now, now) == GlobeWeather.date_of(now - 86400.0))
	_check("weather: an older date is kept", GlobeWeather.daily_date(u - 5.0 * 86400.0, now) == "2026-10-31")
	var f := GlobeTileFetcher.new()
	f.register_layer("daily_2026-10-31", GlobeWeather.daily_layer_def("2026-10-31"))
	var url := f.tile_url("daily_2026-10-31", Vector3i(3, 2, 5))
	_check("weather: daily tile URL is z / y / x on the date", url.ends_with("/2026-10-31/GoogleMapsCompatible_Level9/3/5/2.jpg"), url)
	f.free()
	var blank := Image.create(256, 128, false, Image.FORMAT_RGBA8)
	_check("weather: a transparent image is empty", GlobeWeather.is_empty_image(blank))
	blank.fill_rect(Rect2i(40, 40, 30, 20), Color(0.2, 0.4, 1.0, 1.0))
	_check("weather: an image with rain is not empty", not GlobeWeather.is_empty_image(blank))


static func _be(v: int, n: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(n)
	for i in n:
		b[n - 1 - i] = (v >> (8 * i)) & 0xFF
	return b


## Signed, sign-magnitude, n bytes.
static func _sm(v: int, n: int) -> PackedByteArray:
	var b := _be(absi(v), n)
	if v < 0:
		b[0] = b[0] | 0x80
	return b


## A whole GRIB2 message: 3 x 2 lat/lon grid, simple packing (5.0), values
## (R + X) / 10 with X = 0..5, scan mode as given.
static func _tiny_grib(scan: int) -> PackedByteArray:
	var s1 := PackedByteArray([0, 0, 0, 21, 1, 0, 7, 0, 0, 2, 1, 1]) + _be(2024, 2) \
		+ PackedByteArray([6, 1, 12, 0, 0, 0, 1])
	var s3 := _be(72, 4) + PackedByteArray([3, 0]) + _be(6, 4) + PackedByteArray([0, 0]) + _be(0, 2)
	s3 += PackedByteArray([6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])  # shape + radii
	s3 += _be(3, 4) + _be(2, 4) + _be(0, 4) + _be(0, 4)                       # Ni Nj angle subdiv
	s3 += _sm(10000000, 4) + _sm(0, 4) + PackedByteArray([48])                # La1 Lo1 flags
	s3 += _sm(0, 4) + _sm(20000000, 4) + _be(10000000, 4) + _be(10000000, 4) # La2 Lo2 Di Dj
	s3 += PackedByteArray([scan])
	var s4 := _be(34, 4) + PackedByteArray([4]) + _be(0, 2) + _be(0, 2) \
		+ PackedByteArray([0, 2, 2, 0, 96]) + _be(0, 2) + PackedByteArray([0, 1]) + _be(6, 4) \
		+ PackedByteArray([103, 0]) + _be(2, 4) + PackedByteArray([255, 0]) + _be(0, 4)
	var r := PackedByteArray()
	r.resize(4)
	r.encode_float(0, 10.0)
	r.reverse()
	var s5 := _be(21, 4) + PackedByteArray([5]) + _be(6, 4) + _be(0, 2) + r + _sm(0, 2) + _sm(1, 2) \
		+ PackedByteArray([8, 0])
	var s6 := _be(6, 4) + PackedByteArray([6, 255])
	var s7 := _be(11, 4) + PackedByteArray([7, 0, 1, 2, 3, 4, 5])
	var body := s1 + s3 + s4 + s5 + s6 + s7 + "7777".to_ascii_buffer()
	return "GRIB".to_ascii_buffer() + PackedByteArray([0, 0, 0, 2]) + _be(16 + body.size(), 8) + body


func _test_grib() -> void:
	var m := Grib2Decoder.decode(_tiny_grib(0))
	_check("grib: a hand-built simple-packing message decodes", bool(m.ok), str(m.get("error", "")))
	var vals: PackedFloat32Array = m.get("values", PackedFloat32Array())
	_check("grib: Y = (R + X) / 10^D", vals.size() == 6 and absf(vals[0] - 1.0) < 1e-6
		and absf(vals[5] - 1.5) < 1e-6, str(vals))
	_check("grib: grid and product read", int(m.ni) == 3 and int(m.nj) == 2 and absf(float(m.la1) - 10.0) < 1e-9
		and int(m.forecast_h) == 6 and int(m.number) == 2 and absf(float(m.level) - 2.0) < 1e-9)
	var f := Grib2Decoder.to_field(m)
	_check("grib: north row first in a field", absf(f.values[0] - 1.0) < 1e-6 and absf(float(f.lat0) - 10.0) < 1e-9)
	var f2 := Grib2Decoder.to_field(Grib2Decoder.decode(_tiny_grib(0x40)))
	_check("grib: scan +j (south first) is flipped north-up", absf(f2.values[0] - 1.3) < 1e-6, str(f2.values))
	var bad := Grib2Decoder.decode("GRIB".to_ascii_buffer() + PackedByteArray([0, 0, 0, 1]))
	_check("grib: edition 1 refused", not bool(bad.ok))
	# The real NOAA GFS fields (2026-11-05 00z analysis, complex packing 5.3),
	# checked against Open-Meteo's GFS at the same hour where the 1° grid and
	# the finer model agree (open sea, Iceland's coast).
	var parts := {}
	for k in ["ugrd10m", "vgrd10m", "tmp2m"]:
		parts[k] = Grib2Decoder.decode(FileAccess.get_file_as_bytes(
			"res://core/globe/testdata/gfs_2026110500_f000_%s.grb2" % k))
	_check("grib: GFS fields decode (5.3)", bool(parts.ugrd10m.ok) and bool(parts.vgrd10m.ok)
		and bool(parts.tmp2m.ok) and int(parts.ugrd10m.template) == 3, str(parts.ugrd10m.get("error", "")))
	_check("grib: GFS 1° grid 360 x 181 from 90 N, 0 E", int(parts.ugrd10m.ni) == 360
		and int(parts.ugrd10m.nj) == 181 and absf(float(parts.ugrd10m.la1) - 90.0) < 1e-6)
	_check("grib: UGRD / VGRD / TMP by category and number",
		int(parts.ugrd10m.category) == 2 and int(parts.ugrd10m.number) == 2
		and int(parts.vgrd10m.number) == 3 and int(parts.tmp2m.category) == 0 and int(parts.tmp2m.number) == 0)
	_check("grib: reference time 2026-11-05 00z",
		float(parts.ugrd10m.ref_unix) == float(Time.get_unix_time_from_datetime_string("2026-11-05T00:00:00")))
	var fu := Grib2Decoder.to_field(parts.ugrd10m)
	var fv := Grib2Decoder.to_field(parts.vgrd10m)
	var ft := Grib2Decoder.to_field(parts.tmp2m)
	var sp := GlobeWindField.speed_at(fu, fv, 0.0, -150.0)
	_check("grib: equatorial Pacific wind ~ Open-Meteo 1.84 m/s", absf(sp - 1.84) < 0.5, "%.2f" % sp)
	var tp := Grib2Decoder.sample(ft, 0.0, -150.0) - 273.15
	_check("grib: equatorial Pacific 2 m air ~ Open-Meteo 28.8 °C", absf(tp - 28.8) < 0.6, "%.2f" % tp)
	var si := GlobeWindField.speed_at(fu, fv, 64.1, -21.9)
	_check("grib: Iceland wind ~ Open-Meteo 10.8 m/s", absf(si - 10.84) < 1.5, "%.2f" % si)
	var di := GlobeWindField.from_dir_deg(Grib2Decoder.sample(fu, 64.1, -21.9), Grib2Decoder.sample(fv, 64.1, -21.9))
	_check("grib: Iceland wind from ~128° like Open-Meteo", absf(di - 128.0) < 12.0, "%.0f" % di)
	var mn := 1e9
	var mx := -1e9
	for x in fu.values:
		mn = minf(mn, x)
		mx = maxf(mx, x)
	_check("grib: u wind in a plausible range", mn > -60.0 and mx < 60.0 and mx - mn > 20.0, "%.1f..%.1f" % [mn, mx])


func _test_gfs_helpers() -> void:
	var t := float(Time.get_unix_time_from_datetime_string("2026-03-20T15:00:00"))
	var ch := GlobeWeather.gfs_choice(t, t + 30.0 * 86400.0)
	_check("gfs: a past time uses its own 12z run +3 h",
		float(ch.cycle) == float(Time.get_unix_time_from_datetime_string("2026-03-20T12:00:00")) and int(ch.fhour) == 3, str(ch))
	var live := GlobeWeather.gfs_choice(t, t)
	_check("gfs: now uses the newest run that is out (06z +9 h)",
		float(live.cycle) == float(Time.get_unix_time_from_datetime_string("2026-03-20T06:00:00")) and int(live.fhour) == 9, str(live))
	_check("gfs: before the archive there is nothing", GlobeWeather.gfs_choice(1.5e9, 1.8e9).is_empty())
	var fut := GlobeWeather.gfs_choice(t + 30.0 * 86400.0, t)
	_check("gfs: far future clamps to the last forecast hour", int(fut.fhour) == GlobeWeather.GFS_MAX_FHOUR)
	var url := GlobeWeather.gfs_url(float(ch.cycle), 3)
	_check("gfs: bucket path", url.ends_with("/gfs.20260320/12/atmos/gfs.t12z.pgrb2.1p00.f003"), url)
	var idx := "580:34314607:d=2026110500:TMP:2 m above ground:anl:\n585:34680294:d=2026110500:UGRD:10 m above ground:anl:\n586:34758670:d=2026110500:VGRD:10 m above ground:anl:\n"
	var r := GlobeWeather.idx_ranges(idx, GlobeWeather.GFS_VARS)
	_check("gfs: idx ranges end at the next record", r.size() == 3 and r.u == Vector2i(34680294, 34758670)
		and r.t == Vector2i(34314607, 34680294), str(r))
	_check("gfs: the last record's range is open-ended", r.v == Vector2i(34758670, -1))
	_check("gfs: label", GlobeWeather.gfs_label(float(ch.cycle), 3) == "GFS 2026-03-20 12z +3 h")


func _field(fn: Callable) -> Dictionary:
	var vals := PackedFloat32Array()
	for j in 37:
		for i in 72:
			vals.append(float(fn.call(90.0 - float(j) * 5.0, float(i) * 5.0)))
	return {"nx": 72, "ny": 37, "lat0": 90.0, "lon0": 0.0, "dlat": 5.0, "dlon": 5.0, "values": vals}


func _test_wind_field() -> void:
	var east := _field(func(_la: float, _lo: float) -> float: return 10.0)
	var zero := _field(func(_la: float, _lo: float) -> float: return 0.0)
	var lines := GlobeWindField.trace(east, zero, {"seeds": 400, "max_lines": 400})
	_check("wind field: a uniform west wind makes lines", lines.size() > 20, str(lines.size()))
	var flat := true
	var eastward := true
	for l in lines:
		var ll: PackedFloat64Array = l.ll
		if absf(ll[0] - ll[ll.size() - 2]) > 1e-6:
			flat = false
		for q in range(1, ll.size() / 2):
			var d := fposmod(ll[q * 2 + 1] - ll[q * 2 - 1] + 180.0, 360.0) - 180.0
			if d <= 0.0:
				eastward = false
	_check("wind field: lines follow the latitude", flat)
	_check("wind field: lines run downwind (east)", eastward)
	var calm := GlobeWindField.trace(zero, zero, {"seeds": 200})
	_check("wind field: calm air makes no lines", calm.is_empty())
	var fu := Grib2Decoder.to_field(Grib2Decoder.decode(FileAccess.get_file_as_bytes(
		"res://core/globe/testdata/gfs_2026110500_f000_ugrd10m.grb2")))
	var fv := Grib2Decoder.to_field(Grib2Decoder.decode(FileAccess.get_file_as_bytes(
		"res://core/globe/testdata/gfs_2026110500_f000_vgrd10m.grb2")))
	var real := GlobeWindField.trace(fu, fv)
	_check("wind field: the real field makes 500..2600 lines", real.size() >= 500 and real.size() <= 2600, str(real.size()))
	_check("wind field: deterministic", real.size() == GlobeWindField.trace(fu, fv).size())
	var arr := GlobeWindField.line_arrays(real, 1.0025, 0.45)
	var verts: PackedVector3Array = arr.verts
	_check("wind field: line list is pairs on the shell", verts.size() % 2 == 0
		and absf(verts[0].length() - 1.0025) < 1e-4 and verts.size() < 200000, str(verts.size()))
	var p := GlobeWindField.power_density(10.0)
	_check("wind field: 10 m/s at 10 m -> ~1668 W/m² at 100 m (log law, z0 3 cm)", absf(p - 1668.0) < 5.0, "%.0f" % p)
	_check("wind field: a north wind blows from 0°", absf(GlobeWindField.from_dir_deg(0.0, -5.0)) < 1e-4)
	_check("wind field: a west wind blows from 270°", absf(GlobeWindField.from_dir_deg(5.0, 0.0) - 270.0) < 1e-4)


func _test_drape() -> void:
	var files := PackedStringArray([
		"img_v1_48.3252_-122.2469_15000_z12.png", "img_v1_48.3252_-122.2469_1500_z17.png",
		"img_v3_48.3252_-122.2469_1000_z18.png", "img_v3_48.3252_-122.2469_1500_z18.png",
		"img_v3_48.3252_-122.2469_1500_z18_skagit_2021_9in.png",
		"img_v3_48.3252_-122.2469_1500_z18_skagit_2021_9in.sources.json",
		"img_v3_48.3252_-122.2469_4000_z16.png", "img_v3_48.3252_-122.2469_500_z19.png",
		"img_v3_48.3252_-122.2469_600_z19_skagit_2021_9in.png",
		"img_v3_48.3252_-122.2469_600_z19_wayback_12345.png",
		"img_v1_-13.1643_-72.5450_1500_z17.png", "notes.txt"])
	var a := GlobeDrape.parse_name("img_v3_48.3252_-122.2469_600_z19_skagit_2021_9in.png")
	_check("drape: a chained cache name parses", float(a.half) == 600.0 and int(a.z) == 19
		and str(a.src) == "skagit_2021_9in" and absf(float(a.lon) + 122.2469) < 1e-9, str(a))
	var b := GlobeDrape.parse_name("img_v1_-13.1643_-72.5450_1500_z17.png")
	_check("drape: negative coordinates parse", absf(float(b.lat) + 13.1643) < 1e-9 and str(b.src).is_empty())
	_check("drape: other files are not drapes", GlobeDrape.parse_name("notes.txt").is_empty()
		and GlobeDrape.parse_name("img_v3_x.sources.json").is_empty())
	var c := GlobeDrape.drapes_for(48.3252, -122.2469, files)
	_check("drape: the site's own files, no archive photos", c.size() == 8, str(c.size()))
	var pk := GlobeDrape.pick(c)
	_check("drape: fine = the 9-inch county orthophoto", str(pk.fine.get("file", "")) == "img_v3_48.3252_-122.2469_600_z19_skagit_2021_9in.png", str(pk.fine.get("file", "")))
	_check("drape: wide = the sharpest few-km drape", str(pk.wide.get("file", "")) == "img_v3_48.3252_-122.2469_1500_z18_skagit_2021_9in.png", str(pk.wide.get("file", "")))
	var d := GlobeDrape.parse_name("img_v3_48.3252_-122.2469_1500_z18.png")
	var prm := GlobeDrape.shader_params("d0_", d)
	var mid := GlobeDrape.uv_of(prm, "d0_", 48.3252, -122.2469)
	var bb := GeoMath.bbox_for(48.3252, -122.2469, 1500.0)
	# The centre rides to the shader as float32 (Vector2), so like the shader
	# this is good to ~1e-4 of a 3 km box (~0.3 m), not to double precision.
	_check("drape: the site is in the middle (to float32, ~0.3 m)",
		absf(mid.x - 0.5) < 3e-4 and absf(mid.y - 0.5) < 3e-4, str(mid))
	var nw := GlobeDrape.uv_of(prm, "d0_", float(bb.north), float(bb.west))
	var se := GlobeDrape.uv_of(prm, "d0_", float(bb.south), float(bb.east))
	_check("drape: the box's corners are 0 and 1 (to float32)", nw.length() < 3e-4 and se.distance_to(Vector2.ONE) < 3e-4,
		"%s %s" % [nw, se])
	# The series against exact Mercator inside the box.
	var worst := 0.0
	for i in 11:
		var lat := lerpf(float(bb.south), float(bb.north), float(i) / 10.0)
		var exact := (GlobeDrape.merc_exact(deg_to_rad(float(bb.north))) - GlobeDrape.merc_exact(deg_to_rad(lat))) \
			/ (GlobeDrape.merc_exact(deg_to_rad(float(bb.north))) - GlobeDrape.merc_exact(deg_to_rad(float(bb.south))))
		worst = maxf(worst, absf(GlobeDrape.uv_of(prm, "d0_", lat, -122.2469).y - exact))
	_check("drape: the d³ series follows exact Mercator (to float32)", worst < 3e-5, "%.9f" % worst)
	var far := GlobeDrape.uv_of(prm, "d0_", 48.3252, 57.7531)
	_check("drape: the far side of the world is far outside", absf(far.x - 0.5) > 100.0)
	var circ := GlobeMode.circle_points(48.3252, -122.2469, 300.0, 36)
	var dmax := 0.0
	var dmin := 1e9
	for i in 36:
		var km := GlobeMath.great_circle_km(48.3252, -122.2469, circ[i * 2], circ[i * 2 + 1])
		dmax = maxf(dmax, km)
		dmin = minf(dmin, km)
	_check("drape: the SoI ring is 300 m round", absf(dmin - 0.3) < 0.003 and absf(dmax - 0.3) < 0.003, "%.4f..%.4f km" % [dmin, dmax])
	var sq := GlobeMode.square_points(48.3252, -122.2469, 15000.0)
	_check("drape: the map square's side is 30 km", absf(GlobeMath.great_circle_km(sq[0], sq[1], sq[2], sq[3]) - 30.0) < 0.3)


func _test_solar_atlas() -> void:
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://core/globe/testdata/gsa_lta_mtvernon.json"))
	var a := GlobeSolarAtlas.parse_lta(d)
	_check("atlas: Mount Vernon parses", bool(a.ok) and absf(float(a.ghi_year) - 1197.609375) < 1e-6
		and absf(float(a.pvout_year) - 1186.5770263671875) < 1e-6, str(a))
	_check("atlas: per day is per year / 365", absf(float(a.pvout_day) - 1186.5770263671875 / 365.0) < 1e-9)
	_check("atlas: best tilt and temperature", int(a.tilt_deg) == 36 and absf(float(a.temp_c) - 9.1875) < 1e-6)
	var pm: PackedFloat64Array = a.pvout_monthly
	var tot := 0.0
	for v in pm:
		tot += v
	_check("atlas: twelve months that sum to the year", pm.size() == 12 and absf(tot - float(a.pvout_year)) < 2.0,
		"%.1f vs %.1f" % [tot, float(a.pvout_year)])
	var t := GlobeSolarAtlas.card_text(a)
	_check("atlas: the card line", t.contains("3.25 kWh/day") and t.contains("1,187 kWh/yr")
		and t.contains("best tilt 36°") and t.contains("best Jul, worst Dec"), t)
	var o: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://core/globe/testdata/gsa_lta_ocean.json"))
	var b := GlobeSolarAtlas.parse_lta(o)
	_check("atlas: the open sea has no solar data", not bool(b.ok) and GlobeSolarAtlas.card_text(b).contains("no data here"))
	# An image: lon -180 at the left, north up, R = value / max, G = coverage.
	var img := Image.create(360, 180, false, Image.FORMAT_RGB8)
	img.set_pixel(57, 41, Color(5.0 / GlobeSolarAtlas.MAX_PVOUT, 1.0, 0.0))  # 48.3 N, 122.2 W
	var v := GlobeSolarAtlas.sample(img, 48.3252, -122.2469)
	_check("atlas: a layer pixel reads back its value", absf(v - 5.0) < 0.03, "%.3f" % v)
	_check("atlas: no coverage is NAN", is_nan(GlobeSolarAtlas.sample(img, 0.0, 0.0)))
	_check("atlas: longitude wraps", absf(GlobeSolarAtlas.sample(img, 48.3252, -122.2469 + 360.0) - v) < 1e-6)
	_check("atlas: cache keys are 0.001 deg", GlobeSolarAtlas.key_of(48.32524, -122.24691) == "48.325,-122.247")
	_check("atlas: legend numbers", GlobeMode._num(3.25) == "3.25" and GlobeMode._num(2.5) == "2.5" and GlobeMode._num(12.0) == "12")


func _test_labels_and_climate() -> void:
	_check("labels: an address becomes its town",
		GlobeMode.short_name("1234 Fir Road, Mount Vernon, Skagit County, Washington, 98274, United States") == "Mount Vernon")
	_check("labels: a road with no number is skipped",
		GlobeMode.short_name("Fir Road, Mount Vernon, Washington, United States") == "Mount Vernon")
	_check("labels: a plain place name stays", GlobeMode.short_name("Bombay Beach, Imperial County, California") == "Bombay Beach")
	_check("labels: a short name stays whole", GlobeMode.short_name("My camp") == "My camp")
	var long := GlobeMode.short_name("The very long name of a world somebody typed")
	_check("labels: a long name is cut", long.length() == GlobeMode.PIN_NAME_MAX and long.ends_with("…"), long)
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://core/globe/testdata/power_clim_mtvernon.json"))
	var c := GlobeClimate.parse(d)
	_check("climate: Mount Vernon parses", bool(c.ok) and absf(float(c.ws50.ann) - 3.4) < 1e-9
		and absf(float(c.t2m.ann) - 9.88) < 1e-9 and (c.rain.monthly as PackedFloat64Array).size() == 12)
	_check("climate: grid key is 0.5 deg", GlobeClimate.key_of(48.3252, -122.2469) == "48.5,-122.0")
	# 3.4 m/s at 50 m -> 3.718 at 100 m; 0.5 * 1.225 * (6/pi) * 3.718^3 = 59.7 W/m2
	_check("climate: mean power at 100 m by hand", absf(GlobeClimate.power_100m(3.4) - 59.7) < 0.5,
		"%.2f" % GlobeClimate.power_100m(3.4))
	var wl := GlobeClimate.wind_line(c)
	_check("climate: the wind line", wl.contains("3.4 m/s at 50 m") and wl.contains("2.1 at 10 m") and wl.contains("W/m² at 100 m"), wl)
	var tl := GlobeClimate.temp_line(c)
	_check("climate: the temperature line", tl.contains("Average 9.9 °C") and tl.contains("Dec 4 °C") and tl.contains("Aug 17 °C"), tl)
	var rl := GlobeClimate.rain_line(c)
	_check("climate: the rain line", rl.contains("3.6 mm/day") and rl.contains("wettest Nov") and rl.contains("driest Jul"), rl)
	_check("climate: the cloud line", GlobeClimate.cloud_line(c).contains("68 %") and GlobeClimate.cloud_line(c).contains("clearest Jul"))


func _test_aurora() -> void:
	# The shader include mirrors AuroraModel's constants.
	var inc := FileAccess.get_file_as_string("res://core/globe/aurora.gdshaderinc")
	for pair in [["AUR_EQ_MID0", AuroraModel.EQ_MID0], ["AUR_EQ_PER_KP", AuroraModel.EQ_PER_KP],
			["AUR_EQ_NOON", AuroraModel.EQ_NOON], ["AUR_WIDTH0", AuroraModel.WIDTH0],
			["AUR_WIDTH_PER_KP", AuroraModel.WIDTH_PER_KP], ["AUR_OVATION_FULL", AuroraModel.OVATION_FULL], ["AUR_OVATION_MIN", AuroraModel.OVATION_MIN]]:
		var rx := RegEx.create_from_string("const float %s = ([0-9.]+);" % pair[0])
		var mm := rx.search(inc)
		_check("aurora: shader %s == model" % pair[0], mm != null and absf(float(mm.get_string(1)) - float(pair[1])) < 1e-9)
	var pole := AuroraModel.pole_dir()
	_check("aurora: the geomagnetic pole is at 90 mag lat", absf(AuroraModel.mag_lat(pole) - 90.0) < 0.05)
	_check("aurora: Mount Vernon is ~54 deg magnetic", absf(AuroraModel.mag_lat(GlobeMath.to_unit(48.3252, -122.2469)) - 54.0) < 1.5,
		"%.2f" % AuroraModel.mag_lat(GlobeMath.to_unit(48.3252, -122.2469)))
	_check("aurora: the edge at midnight follows Kp", absf(AuroraModel.edge_lat(3.0, 0.0) - 59.4) < 1e-9
		and absf(AuroraModel.edge_lat(9.0, 0.0) - 46.2) < 1e-9)
	_check("aurora: the day side edge is EQ_NOON higher", absf(AuroraModel.edge_lat(3.0, PI) - 68.4) < 1e-9)
	# A sun over lon 0 at the equinox: a point at the pole's meridian on the
	# far side is near magnetic midnight, the one under the sun near noon.
	var sun := GlobeMath.to_unit(0.0, 0.0)
	var night := GlobeMath.to_unit(60.0, 180.0)
	var day := GlobeMath.to_unit(60.0, 0.0)
	_check("aurora: midnight and noon", AuroraModel.from_midnight(night, sun) < 0.6 and AuroraModel.from_midnight(day, sun) > 2.5,
		"%.2f %.2f" % [AuroraModel.from_midnight(night, sun), AuroraModel.from_midnight(day, sun)])
	# Peak of the band at midnight: mag lat = edge + width / 2.
	var best := 0.0
	var best_lat := 0.0
	for i in 400:
		var ml := 40.0 + i * 0.1
		var q := _point_at_mag_lat(ml, sun)
		var st := AuroraModel.strength(q, 5.0, sun)
		if st > best:
			best = st
			best_lat = absf(AuroraModel.mag_lat(q))
	var want := AuroraModel.edge_lat(5.0, 0.0) + 0.5 * AuroraModel.width(5.0, 0.0)
	_check("aurora: the band peaks mid-oval", absf(best_lat - want) < 1.2, "%.2f vs %.2f" % [best_lat, want])
	_check("aurora: stronger with Kp", AuroraModel.strength(_point_at_mag_lat(56.0, sun), 7.0, sun)
		> AuroraModel.strength(_point_at_mag_lat(56.0, sun), 2.0, sun) * 5.0)
	_check("aurora: the southern oval too", AuroraModel.strength(-_point_at_mag_lat(-best_lat, sun), 5.0, sun) > 0.0)
	_check("aurora: a 10 deg ray reaches 110 km ~ 500 km away", absf(AuroraModel.ground_km(10.0) - 502.0) < 20.0,
		"%.0f km" % AuroraModel.ground_km(10.0))
	_check("aurora: G scale", AuroraModel.g_scale(4.0) == "" and AuroraModel.g_scale(5.0) == "G1"
		and AuroraModel.g_scale(9.0) == "G5" and AuroraModel.g_scale(7.0) == "G3")
	# May 10-11, 2024: Kp 9 — the aurora reached Mount Vernon's sky at night.
	var msun := GlobeMath.sun_dir(GlobeMath.jd_from_unix(Time.get_unix_time_from_datetime_string("2024-05-11T07:00:00")))
	_check("aurora: Kp 9 is overhead at Mount Vernon at night", AuroraModel.seen_from(48.3252, -122.2469, 9.0, msun) == "overhead")
	_check("aurora: Kp 1 is not seen there", AuroraModel.seen_from(48.3252, -122.2469, 1.0, msun) == "")
	# Space weather parsers.
	var g: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://core/globe/testdata/gfz_kp_2024-05-10.json"))
	var gs := SpaceWeatherService.parse_gfz(g)
	var t11 := float(Time.get_unix_time_from_datetime_string("2024-05-11T01:30:00"))
	_check("aurora: GFZ archive parses (Kp 9 on 11 May 00-03 UTC)", gs.size() == 16 and absf(SpaceWeatherService.lookup(gs, t11) - 9.0) < 1e-6)
	var f: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://core/globe/testdata/swpc_kp_forecast.json"))
	var fs := SpaceWeatherService.parse_swpc(f)
	var has_fc := false
	for r in fs:
		if str(r[2]) == "predicted":
			has_fc = true
	_check("aurora: SWPC observed + forecast parse", fs.size() > 50 and has_fc, "%d rows" % fs.size())
	var o: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://core/globe/testdata/ovation_sample.json"))
	var ov := SpaceWeatherService.parse_ovation(o)
	var img: Image = ov.image
	_check("aurora: OVATION grid parses", img.get_width() == 360 and img.get_height() == 181 and float(ov.max) > 0.0
		and float(ov.forecast) > float(ov.obs))
	_check("aurora: month keys", SpaceWeatherService.month_key(t11) == "2024-05")


## A point at magnetic latitude `ml` on the magnetic midnight meridian.
func _point_at_mag_lat(ml: float, sun: Vector3) -> Vector3:
	var pole := AuroraModel.pole_dir()
	var away := -(sun - pole * sun.dot(pole)).normalized()
	var a := deg_to_rad(ml)
	return (pole * sin(a) + away * cos(a)).normalized()
