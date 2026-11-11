class_name FarmBotDesign
extends RefCounted

## The one solved FarmBot design the modal, the builder, the runtime and the
## graph all read: the resolved spec, the plant layout, the robot's steady
## days, the money, the design checks. Cached by the spec's key.

const CACHE_MAX := 12
static var _cache := {}
static var _order: Array = []


static func solve(spec: Dictionary) -> Dictionary:
	var key := FarmBotSpec.key_of(spec)
	if _cache.has(key):
		return _cache[key]
	var s := FarmBotSpec.resolve(spec)
	var lay := FarmBotLayout.solve(s)
	var robot := FarmBotEconomics.robot_days(s, lay)
	var money := FarmBotEconomics.compute(s, robot)
	var d := {"key": key, "spec": s, "layout": lay, "robot": robot, "money": money,
		"area_m2": FarmBotSpec.area_m2(s)}
	d["checks"] = checks(d)
	_cache[key] = d
	_order.append(key)
	while _order.size() > CACHE_MAX:
		_cache.erase(_order.pop_front())
	return d


## {level: error|warn|info, text, why}
static func checks(d: Dictionary) -> Array:
	var out: Array = []
	var s: Dictionary = d["spec"]
	var b: Dictionary = s["bed"]
	var lay: Dictionary = d["layout"]
	var robot: Dictionary = d["robot"]
	var money: Dictionary = d["money"]
	if FarmBotGeom.is_radial(s):
		var arm := FarmBotGeom.rail_r(s)
		var sw := FarmBotGeom.sweep(s)
		if arm > FarmBotSpec.MAX_ARM_M:
			out.append({"level": "warn", "text": "A %.1f m arm is long even as a truss." % arm,
				"why": "The arm hangs from the post and rides the rail at its end; past ~12 m it needs a wheel part way out on a rail of its own, as a centre-pivot irrigator has towers."})
		elif arm > FarmBotSpec.LONG_ARM_M:
			out.append({"level": "info", "text": "The %.1f m arm is a light truss, not FarmBot's 3 m extrusion." % arm,
				"why": "One extrusion would sag across this span. The arm is drawn and priced as an aluminium triangle truss, supported at the post and at the rail."})
		var na := FarmBotGeom.arm_count(s)
		if na > 1:
			out.append({"level": "info", "text": "%d arms share the rail, a %.0f° sector each." % [na, rad_to_deg(sw.y) / float(na)],
				"why": "Each arm has its own carriage, tools and controller and works only its sector, so the day's jobs run side by side. Where two sectors meet, the later arm waits for the other to move off (not simulated)."})
		if str(FarmBotGeom.keyhole(s)["sweep"]) == "full":
			out.append({"level": "info", "text": "The rail bridges the keyhole slot.",
				"why": "A short removable rail section crosses the path in; lift it out to wheel a barrow through. With the rail stopping at the slot instead, the arm turns back at each side (%.0f° of travel)." % rad_to_deg(TAU - 2.0 * (FarmBotGeom.RAIL_CLEAR_RAD + asin(clampf(float(FarmBotGeom.keyhole(s)["slot_w"]) * 0.5 / arm, 0.0, 0.99))))})
		var tip_s := FarmBotGeom.rail_r(s) * sw.y / float(na) / (float((s["motion"] as Dictionary)["xy_max_mm_s"]) / 1000.0)
		if tip_s > 1800.0:
			out.append({"level": "info", "text": "A full swing of an arm's sector takes %s at the rail." % UiText.duration(tip_s / 3600.0),
				"why": "The arm is driven at its outer wheel, so the rail's speed is X's top speed. Jobs are ordered to swing once round the bed."})
	elif float(b["width_m"]) > FarmBotSpec.MAX_WIDTH_M:
		out.append({"level": "warn", "text": "The gantry spans %.1f m; FarmBot's widest is 3 m." % float(b["width_m"]),
			"why": "The gantry beam is one aluminium extrusion between two columns. Past 3 m it sags and the cross-slide rocks; a wider bed needs a stiffer beam or a centre track."})
	if not FarmBotGeom.is_radial(s) and float(b["length_m"]) > FarmBotSpec.LONG_TRACK_M:
		out.append({"level": "warn", "text": "%.0f m of track is long for one belt and one cable carrier." % float(b["length_m"]),
			"why": "Each X belt runs the whole track and stretches with length; the cable carrier and the water hose must reach the far end. Two shorter beds with a robot each, or a heavier drive, are the usual answer."})
	var tall: Array = lay["tall"]
	if not tall.is_empty():
		var names: Array = []
		for c in tall:
			names.append(str(GardenCrops.info(str(c)).get("label", c)))
		out.append({"level": "warn", "text": "%s grow%s taller than the gantry's %.2f m clearance." % [", ".join(names),
			"" if names.size() > 1 else "s", float((s["gantry"] as Dictionary)["clearance_m"])],
			"why": "The gantry rolls over the whole bed. A crop taller than the beam stops it; raise the columns or keep tall crops out of the robot's bed."})
	var busy := float(robot["max_busy_h"])
	if busy > 24.0:
		out.append({"level": "error", "text": "Its busiest day needs %.1f h of work." % busy,
			"why": "The jobs of one day do not fit in a day. Water less often, weed less often, sow smaller sections, or split the bed between two robots."})
	elif busy > 16.0:
		out.append({"level": "warn", "text": "Its busiest day runs %.1f h." % busy,
			"why": "Jobs are pushed back when the one before overruns; past ~16 h the evening watering runs into the night."})
	if int(lay["total"]) == 0:
		out.append({"level": "error", "text": "No plants fit in this bed at this spacing.", "why": "Make the bed bigger or the spacing smaller."})
	if float(money["saved_h_year"]) <= 0.0:
		out.append({"level": "info", "text": "It saves no hand work at these settings.",
			"why": "The upkeep and seed refills take as long as the hand work it would do. A bigger bed, or more watering, makes it worth more."})
	elif float(money["payback_years"]) > float((s["cost"] as Dictionary)["lifetime_years"]):
		out.append({"level": "info", "text": "It does not pay for itself in its %.0f-year life at $%.0f/h." % [
			float((s["cost"] as Dictionary)["lifetime_years"]), float((s["cost"] as Dictionary)["labor_usd_h"])],
			"why": "The hours it saves, at your labour rate, are worth less a year than it costs to buy and run spread over its life."})
	var soil := float((s["gantry"] as Dictionary)["soil_z_mm"])
	if -soil > float((s["gantry"] as Dictionary)["z_travel_mm"]) - 20.0:
		out.append({"level": "warn", "text": "The soil is at the bottom of the Z travel.",
			"why": "The seeder and the weeder plunge below the soil; the Z axis needs room past it. Lower the gantry or lengthen the Z axis."})
	return out


## The graph node a designed FarmBot bed is: a food plant of the bed's area
## (the graph's growth model), with the robot's power as its load.
static func graph_specs(d: Dictionary) -> Dictionary:
	var robot: Dictionary = d["robot"]
	return {
		"area_m2": float(d["area_m2"]),
		"farmbot_busy_h_day": float(robot["busy_h_day"]),
		"farmbot_water_l_day": float(robot["water_l_day"]),
		"farmbot_power_w": FarmBotEconomics.IDLE_W + FarmBotEconomics.WORK_W * float(robot["busy_h_day"]) / 24.0,
	}


static func clear_cache() -> void:
	_cache.clear()
	_order.clear()
