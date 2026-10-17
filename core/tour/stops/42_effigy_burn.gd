extends TourStop

var _prop_id := ""


func _init() -> void:
	id = "effigy_burn"
	title = "The burn"
	chapter = "People"
	summary = "Light the effigy: the crowd gathers in rings, the fire climbs, it falls, they circle."
	how = PackedStringArray(["Click a burnable structure → prop editor → Fire → 🔥 Ignite",
		"Planned climb, bonfire and ember durations can be set before lighting"])
	button = "Prop editor → Fire"
	world = "walton"
	budget_s = 75.0
	hour = 22.0
	blurb = ("A fire is a pure function of the clock: it climbs the structure's real " +
		"surface, collapses into a pile that burns down to embers, and scrubs " +
		"backwards. At an effigy the crowd forms rings outside a perimeter of height " +
		"plus ten feet, sandmen hold the line, fire dancers perform, and after the " +
		"fall everyone circles counter-clockwise.")


func run(ctx: TourContext) -> void:
	var sv: Variant = await ctx.open_festival()
	if not ctx.require(sv != null, "festival mode opened"):
		return
	var reg: Variant = ctx.space_registry()
	var eff: Dictionary = {}
	if reg != null:
		for rec in reg.get("spaces"):
			if str((rec as Dictionary).get("space_type", "")) == "effigy":
				eff = rec
				break
	if not ctx.require(not eff.is_empty(), "the site has a tagged effigy"):
		return
	_prop_id = str((eff.get("target", {}) as Dictionary).get("prop_id", ""))
	var ep: Variant = reg.call("cached_position", str(eff.get("id", "")))
	var at: Vector2 = ep if ep is Vector2 else ctx.player_xz()
	var ft := ctx.klass("FireTimeline")
	var fn := ctx.klass("FireNode")
	if not ctx.require(ft != null and fn != null and not _prop_id.is_empty(), "the effigy is a burnable prop"):
		return
	var dark := ctx.hour_for_sun(-14.0, true)
	if not is_nan(dark):
		ctx.set_hour(dark)
	ctx.settle_cam(at, 70.0, true)
	await ctx.wait(1.0)
	ctx.run_clock(120.0)
	var now_h := float(ctx.main.call("get_absolute_hours"))
	ctx.loader.call("set_prop_burn_record", _prop_id, ft.call("make", now_h,
		{"climb_h": 0.35, "bonfire_h": 1.0, "ember_h": 0.5, "mass_kg": 600.0,
			"height_m": 8.0, "footprint_r_m": 3.0, "preroll_h": 0.15}))
	fn.call("sync_prop_fires", ctx.main, ctx.loader)
	ctx.caption("Lit: the crowd gathers in rings outside the perimeter", 3.5)
	await ctx.wait(4.5)
	ctx.settle_cam(at, 45.0)
	ctx.caption("Fire dancers inside the line, sandmen holding it", 3.0)
	await ctx.wait(4.0)
	ctx.caption("The fire climbs…", 2.5)
	await ctx.wait(4.0)
	await ctx.hero()
	ctx.caption("…the fall, and the circle", 3.0)
	await ctx.wait(6.0)


func teardown(ctx: TourContext) -> void:
	if not _prop_id.is_empty() and ctx.loader != null:
		ctx.loader.call("clear_prop_burn_record", _prop_id)
		var fn := ctx.klass("FireNode")
		if fn != null:
			fn.call("sync_prop_fires", ctx.main, ctx.loader)
	_prop_id = ""
	if ctx.main.has_method("close_festival_mode"):
		ctx.main.call("close_festival_mode")
