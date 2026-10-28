extends TourStop

## The ∞ speed preset: one calendar day per frame at mean solar noon. Four
## acts on the one stepper: the sun draws its figure-eight over a full year;
## a grove of broadleaf trees goes through its seasons (leaf-out, summer,
## autumn colour, leaf drop) as the days fly; the planets' paths at the same
## noons; then the lunar analemma, the moon caught at each transit.

## Broadleaf species ids (vegetation/species/species_catalog.json family
## "deciduous" with a deciduous phenology).
const BROADLEAF := ["deciduous", "chestnut", "maple", "cottonwood", "aspen", "birch",
	"beech", "walnut", "apple", "pear", "oak"]
const DAY_INDEX := "_analemma_session_day_index"

var _clock := {}
var _saved := {}


func _init() -> void:
	id = "analemma"
	title = "Analemma mode"
	chapter = "World"
	summary = "A day per frame at solar noon: the sun's figure-eight, a year of leaves, the planets and the moon."
	how = PackedStringArray(["Click the timeline's faster button past the top speed to the ∞ preset",
		"Space plays; ∞×2 steps two days a frame",
		"Settings → Sky: solar or lunar analemma, sun / moon / planet paths, stars through daylight"])
	button = "∞ on the timeline speed control"
	world = "burningman"
	budget_s = 120.0
	hour = 12.0
	blurb = ("The ∞ preset steps the calendar one day per frame to the site's mean " +
		"solar noon, so the sun traces the analemma for the real latitude while years " +
		"go by and the forest runs through its seasons — leaf-out, autumn colour and " +
		"leaf drop — at the same pace. The stars stay visible through daylight, the " +
		"planets' paths are sampled at the same instants (Mercury and Venus loop round " +
		"the sun's figure-eight), and the lunar mode catches the moon at each transit " +
		"to draw its own analemma.")


func run(ctx: TourContext) -> void:
	var m := ctx.main
	_clock = ctx.save_clock()
	for k in ["show_sun_path", "show_moon_path", "show_planet_paths", "analemma_type"]:
		_saved[k] = m.get(k)
	_saved["reveal"] = m.call("get_analemma_star_reveal")
	m.set("show_sun_path", true)
	m.set("show_moon_path", false)
	m.set("show_planet_paths", false)
	m.set("analemma_type", 0)
	m.call("set_analemma_star_reveal", 0.75)
	ctx.clear_sky(true)
	var lat := float(m.get("latitude"))
	var clock: Variant = m.get("clock")
	# Start at the winter solstice so the year (and the leaves) begin bare.
	m.set("month", 12)
	m.set("day", 21)
	ctx.set_hour(12.0)
	await ctx.frames(2)
	var sd: Vector3 = clock.call("get_sun_direction") if clock != null else Vector3(0, 0.5, 1)
	var flat := Vector3(sd.x, 0.0, sd.z)
	flat = flat.normalized() if flat.length() > 1e-3 else Vector3.BACK
	var sky_dir := _sky_dir(flat, lat)
	var eye := ctx.player.global_position + Vector3.UP * 40.0
	ctx.hud(false)
	var cam := ctx.tour_camera()
	cam.fov = 78.0
	ctx.place_camera(eye, eye + sky_dir * 100.0)
	m.set("time_scale", 0.0)

	# 1 — the sun's figure-eight, a full year.
	m.set("analemma_mode", true)
	ctx.require(bool(m.get("analemma_mode")), "analemma mode switched on")
	ctx.caption("∞: a day per frame, always at solar noon", 3.0)
	await _until_days(ctx, 200)
	ctx.caption("The sun's figure-eight for %.1f° N — stars kept up through daylight" % lat, 4.0)
	await _until_days(ctx, 380)
	await ctx.hero()
	await ctx.wait(1.0)

	# 2 — a year of leaves on the nearest broadleaf grove.
	var grove := _broadleaf_grove(ctx)
	if grove == Vector3.INF:
		ctx.note("no broadleaf trees within 400 m — skipping the leaves")
	else:
		var to := grove - ctx.player.global_position
		to.y = 0.0
		var dir := to.normalized() if to.length() > 1.0 else flat
		var g_eye := grove - dir * 34.0 + Vector3.UP * 11.0
		g_eye.y = maxf(g_eye.y, ctx.ground_y(g_eye.x, g_eye.z) + 6.0)
		cam.fov = 55.0
		ctx.place_camera(g_eye, grove + Vector3.UP * 5.0)
		ctx.caption("…and the forest runs through its year at the same pace", 3.5)
		var seen := {}
		var d0 := int(m.get(DAY_INDEX))
		var t := 0.0
		while int(m.get(DAY_INDEX)) < d0 + 400 and t < 25.0 and not ctx.cancelled:
			var mo := int(m.get("month"))
			if mo in [4, 6, 10, 11, 1] and not seen.has(mo) and int(m.get("day")) >= 12:
				seen[mo] = true
				ctx.caption(_season_caption(mo), 2.0)
				await ctx.shot("leaves_%02d" % mo, true)
			await ctx.frames(1)
			t += ctx.host.get_process_delta_time()

	# 3 — planet paths at the same noons.
	cam.fov = 78.0
	ctx.place_camera(eye, eye + sky_dir * 100.0)
	m.set("show_planet_paths", true)
	ctx.caption("Planet paths, sampled at the same noons: Venus and Mercury loop round the sun", 4.0)
	var d1 := int(m.get(DAY_INDEX))
	await _until_days(ctx, d1 + 420)
	await ctx.shot("planet_paths", true)

	# 4 — the lunar analemma: the moon at each transit.
	m.set("show_planet_paths", false)
	m.set("analemma_mode", false)
	m.set("analemma_type", 1)
	m.set("show_sun_path", false)
	m.set("show_moon_path", true)
	m.set("analemma_mode", true)
	await ctx.frames(2)
	var md: Vector3 = clock.call("get_moon_direction") if clock != null else sky_dir
	var mflat := Vector3(md.x, 0.0, md.z)
	mflat = mflat.normalized() if mflat.length() > 1e-3 else flat
	ctx.place_camera(eye, eye + _sky_dir(mflat, lat) * 100.0)
	ctx.caption("Lunar mode: the moon caught at each transit draws its own analemma", 4.0)
	await _until_days(ctx, 120)
	await ctx.shot("lunar", true)
	await ctx.wait(1.0)


## A view direction toward `flat` (horizontal) at the analemma's middle
## altitude (90° − |lat|).
func _sky_dir(flat: Vector3, lat: float) -> Vector3:
	var mid_alt := deg_to_rad(clampf(90.0 - absf(lat), 5.0, 85.0))
	return (flat * cos(mid_alt) + Vector3.UP * sin(mid_alt)).normalized()


## Let the stepper run until its day counter reaches `n` (a day a frame,
## whatever the tour's pace), with a real-time cap.
func _until_days(ctx: TourContext, n: int) -> void:
	var t := 0.0
	while int(ctx.main.get(DAY_INDEX)) < n and t < 25.0 and not ctx.cancelled:
		await ctx.frames(1)
		t += ctx.host.get_process_delta_time()


func _season_caption(month: int) -> String:
	match month:
		4: return "Spring: leaf-out"
		6: return "Summer: full canopy"
		10: return "Autumn colour"
		11: return "Leaf drop"
		1: return "Winter: bare branches"
	return ""


## The middle of the densest broadleaf patch within 400 m of the player
## (INF if none): the 25 m cell holding the most broadleaf trees.
func _broadleaf_grove(ctx: TourContext) -> Vector3:
	if ctx.loader == null:
		return Vector3.INF
	var me := ctx.player_xz()
	var cells := {}
	# Painted trees and the generated forest (either may be empty or off).
	var bulk := {}
	for lname in ["_vegetation_layer", "_auto_veg_layer"]:
		var layer: Variant = ctx.loader.get(lname)
		if layer == null:
			continue
		var b: Dictionary = layer.get("bulk")
		for slot in b:
			bulk["%s|%s" % [lname, slot]] = b[slot]
	for slot in bulk:
		var name := str(slot).get_slice("|", 1).to_lower()
		var broad := false
		for b in BROADLEAF:
			if name.contains(b):
				broad = true
				break
		if not broad:
			continue
		for rec in bulk[slot]:
			var p := Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0)))
			if p.distance_to(me) > 400.0:
				continue
			var key := Vector2i(floori(p.x / 25.0), floori(p.y / 25.0))
			var c: Array = cells.get(key, [0, Vector2.ZERO])
			cells[key] = [int(c[0]) + 1, (c[1] as Vector2) + p]
	var best := -INF
	var best_n := 0
	var at := Vector2.ZERO
	for key in cells:
		var c: Array = cells[key]
		var n := int(c[0])
		var mid := (c[1] as Vector2) / float(n)
		# Prefer near patches a little: a big grove 300 m off can lose to a
		# good one at 80 m.
		var score := float(n) - mid.distance_to(me) * 0.02
		if score > best:
			best = score
			best_n = n
			at = mid
	if best_n < 4:
		return Vector3.INF
	return Vector3(at.x, ctx.ground_y(at.x, at.y), at.y)


func teardown(ctx: TourContext) -> void:
	var m := ctx.main
	m.set("analemma_mode", false)
	for k in ["analemma_type", "show_sun_path", "show_moon_path", "show_planet_paths"]:
		if _saved.has(k):
			m.set(k, _saved[k])
	if _saved.has("reveal"):
		m.call("set_analemma_star_reveal", float(_saved["reveal"]))
	_saved = {}
	ctx.restore_clock(_clock)
	_clock = {}
	ctx.hud(true)
