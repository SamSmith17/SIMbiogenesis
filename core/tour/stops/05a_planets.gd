extends TourStop

## The five naked-eye planets placed by their own Kepler solve, with the name
## tags on: the stop hunts the coming weeks for a dark evening with the most
## planets up and frames them together.

## Planets count as "up" above this altitude (degrees).
const MIN_ALT := 8.0

var _clock := {}
var _labels := -1


func _init() -> void:
	id = "planets"
	title = "Planets"
	chapter = "World"
	summary = "Mercury to Saturn where they really are tonight, with name tags."
	how = PackedStringArray(["Scrub the timeline to night",
		"Settings → Planets: name tags (off / when you look at one / always), colours, sizes"])
	button = "Settings → Planets"
	world = "mtvernon"
	budget_s = 40.0
	hour = 21.0
	blurb = ("Each planet's position is solved from its orbital elements (JPL's " +
		"Keplerian set) for the clock's own instant and drawn into the sky shader as a " +
		"point of light. Name tags can follow the view or stay on, and the same solve " +
		"draws the planets' paths in analemma mode.")


func run(ctx: TourContext) -> void:
	var m := ctx.main
	var ps: Node = m.call("get_planet_system") if m.has_method("get_planet_system") else null
	if not ctx.require(ps != null, "the planet system exists"):
		return
	_clock = ctx.save_clock()
	_labels = int(ps.get("planet_labels_mode"))
	ctx.clear_sky(true)
	m.set("time_scale", 0.0)
	var day0 := float(m.call("get_absolute_hours")) - float(m.get("day_time"))
	# Search the next 90 nights — after dusk and before dawn — for the most
	# planets up (the bright ones are often morning objects).
	var best_t := NAN
	var best_n := -1
	var best_alt := -INF
	var dusk := ctx.hour_for_sun(-14.0, true)
	if is_nan(dusk):
		dusk = 21.5
	var dawn := ctx.hour_for_sun(-14.0, false)
	if is_nan(dawn):
		dawn = 5.0
	var hours := [dusk + 0.3, dusk + 2.5, dawn + 24.0 - 2.5, dawn + 24.0 - 0.3]
	for d in 90:
		for hh in hours:
			var t := day0 + float(d) * 24.0 + float(hh)
			m.call("set_absolute_hours", t)
			ps.call("force_update")
			var n := 0
			var alt_sum := 0.0
			for pn in ps.get("planet_altitudes"):
				var a := float((ps.get("planet_altitudes") as Dictionary)[pn])
				if a > MIN_ALT:
					n += 1
					alt_sum += a
			if n > best_n or (n == best_n and alt_sum > best_alt):
				best_n = n
				best_alt = alt_sum
				best_t = t
	if not ctx.require(best_n >= 1 and not is_nan(best_t), "a dark night with a planet up in the next 90 days"):
		return
	m.call("set_absolute_hours", best_t)
	ps.call("force_update")
	var dirs: Array = []
	var names: PackedStringArray = PackedStringArray()
	var alts: Dictionary = ps.get("planet_altitudes")
	var pdirs: Dictionary = ps.get("planet_directions")
	for pn in alts:
		if float(alts[pn]) > MIN_ALT:
			dirs.append(pdirs[pn])
			names.append(str(pn).capitalize())
	var c := Vector3.ZERO
	for v in dirs:
		c += v as Vector3
	c = c.normalized() if c.length() > 1e-4 else Vector3(0, 0.5, -1).normalized()
	var spread := 0.0
	for v in dirs:
		spread = maxf(spread, rad_to_deg((v as Vector3).angle_to(c)))
	ps.set("planet_labels_mode", 2)
	var eye := ctx.player.global_position + Vector3.UP * 60.0
	var cam := ctx.tour_camera()
	cam.fov = clampf(spread * 2.4 + 14.0, 40.0, 95.0)
	ctx.hud(false)
	# The name tags live on the planet system's own CanvasLayer, which hud(false)
	# took down with the rest.
	var tags: Variant = ps.get("_label_layer")
	if tags is CanvasLayer:
		(tags as CanvasLayer).visible = true
	ctx.place_camera(eye, eye + c * 100.0)
	var dd: Dictionary = (m.get("clock") as Object).call("abs_hours_to_date", best_t)
	ctx.note("%d planet(s) up on %d-%02d-%02d: %s" % [best_n, int(dd.get("year", 0)),
		int(dd.get("month", 0)), int(dd.get("day", 0)), ", ".join(names)])
	ctx.caption("%s — tonight's planets, from their own orbits" % ", ".join(names), 3.5)
	ctx.run_clock(300.0)
	await ctx.wait(3.0)
	await ctx.hero()
	ctx.caption("The sky turns; the tags follow", 2.5)
	await ctx.wait(3.0)


func teardown(ctx: TourContext) -> void:
	var m := ctx.main
	var ps: Node = m.call("get_planet_system") if m.has_method("get_planet_system") else null
	if ps != null and _labels >= 0:
		ps.set("planet_labels_mode", _labels)
	_labels = -1
	ctx.restore_clock(_clock)
	_clock = {}
	ctx.hud(true)
