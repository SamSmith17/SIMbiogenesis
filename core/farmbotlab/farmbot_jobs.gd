class_name FarmBotJobs
extends RefCounted

## What a FarmBot does in a day, step by step, and where it is at any moment.
##
## A day is a list of JOBS (watering at each watering time, seeding the
## sections due that day, a weeding pass every few days, a photo survey, soil
## readings), each starting at its hour or when the job before it ends. A job
## is a list of SEGMENTS: moves (FarmBotMotion: the axes at once, each on its
## own ramp) and dwells (water running, the seeder's vacuum, the camera). The
## whole day is a pure function of the spec, the layout and the day number, so
## the machine in the world can be drawn at any second without integrating
## anything: scrub the clock back and it is back where it was.
##
## How the jobs are built follows the FarmBot sequences:
##  - tools hang in a tool bay on the bed wall (y ~ 40 mm) and are picked up
##    by lowering the universal tool mount onto them and sliding out along Y,
##    put back the other way round;
##  - the seeder takes one seed at a time from a seed trough that rides on the
##    gantry (so the trip is across the bed, not back to the bed's end), holds
##    it by vacuum and plunges it into the soil;
##  - watering lowers the nozzle once to just above the canopy and visits each
##    plant at that height, dwelling as long as its share of water takes at
##    the nozzle's flow;
##  - weeding photographs the bed on a grid, then plunges the weeder at each
##    weed it found;
##  - monitoring is the photo grid alone; the soil sensor is pushed in once a
##    section.
## Estimates (said so): the camera's footprint, the weed emergence rate, the
## dwell times. Positions are machine mm (FarmBotLayout.to_machine), z = 0 at
## the top of the Z travel, negative down.

const SAFE_Z_MM := -40.0
const TOOL_ABOVE_SOIL_MM := 80.0   # the tool bay's height over the soil
const WATER_ABOVE_SOIL_MM := 250.0  # the nozzle over the soil while watering
const SLOT_Y_MM := 40.0
const SLOT_X0_MM := 150.0
const SLOT_PITCH_MM := 160.0
const SLIDE_MM := 120.0             # how far the tool slides out of its slot
const TROUGH_IN_MM := 80.0          # the seed trough, this far in from the far side
const VACUUM_S := 1.0               # the seeder picking a seed
const RELEASE_S := 0.6
const PLUNGE_MM := 12.0             # seed depth below the soil
const PHOTO_W_MM := 400.0           # camera footprint along X (estimate)
const PHOTO_H_MM := 300.0           # and across (estimate)
const PHOTO_S := 1.5                # settle + capture
const WEED_PLUNGE_S := 1.2
const WEEDS_PER_M2_DAY := 0.4       # new weeds the camera finds (estimate)
const SOIL_READ_S := 3.0
const SOIL_DEPTH_MM := 60.0
const MAX_SOIL_READS := 12
const TOOL_ORDER := ["seeder", "watering", "weeder", "soil_sensor", "rotary"]


## The tool bay's slot for a tool (machine mm, at tool height). A linear
## robot's bay runs along the -Z wall; a radial one's tools hang on a ring
## round the post, inside the innermost bed, a slot pitch apart on that ring
## (so further apart in rail X).
static func slot_of(spec: Dictionary, tool: String, arm := 0) -> Vector3:
	var k := maxi(TOOL_ORDER.find(tool), 0)
	var soil := float((spec["gantry"] as Dictionary)["soil_z_mm"])
	if FarmBotGeom.is_radial(spec):
		# Each arm has its own tools, at the start of its own sector.
		var tr := FarmBotGeom.tool_r(spec)
		var along := (SLOT_X0_MM + SLOT_PITCH_MM * float(k)) / 1000.0
		return Vector3(along / tr * FarmBotGeom.rail_r(spec) * 1000.0 + arm_range(spec, arm).x, tr * 1000.0,
			soil + TOOL_ABOVE_SOIL_MM)
	return Vector3(SLOT_X0_MM + SLOT_PITCH_MM * float(k), SLOT_Y_MM, soil + TOOL_ABOVE_SOIL_MM)


## Where the machine waits between jobs: over the tool bay, at the top.
static func park_pos(spec: Dictionary, arm := 0) -> Vector3:
	if FarmBotGeom.is_radial(spec):
		var sl := slot_of(spec, TOOL_ORDER[0], arm)
		return Vector3(sl.x, sl.y + SLIDE_MM, 0.0)
	return Vector3(SLOT_X0_MM, SLOT_Y_MM + SLIDE_MM, 0.0)


## The machine X each arm works (mm): its share of the rail. A linear robot
## has one gantry and the whole bed.
static func arm_range(spec: Dictionary, arm: int) -> Vector2:
	var n := FarmBotGeom.arm_count(spec)
	if n <= 1:
		return Vector2(-INF, INF) if not FarmBotGeom.is_radial(spec) else Vector2(0.0, FarmBotGeom.x_max_mm(spec))
	var w := FarmBotGeom.x_max_mm(spec) / float(n)
	return Vector2(w * float(arm), w * float(arm + 1))


## The seed trough's Y: on the far side of a linear gantry, over the path
## nearest the middle of a radial arm.
static func trough_y(spec: Dictionary) -> float:
	if FarmBotGeom.is_radial(spec):
		return FarmBotGeom.trough_r(spec) * 1000.0
	return float((spec["bed"] as Dictionary)["width_m"]) * 1000.0 - TROUGH_IN_MM


## One day's plan. day = whole days since the bed was planted (0 = the day it
## was). detail false = times and totals only (no segments): what the cost
## model sums over many days.
## -> {day, jobs: [{id, label, tool, start_s, dur_s, segs}], busy_s, water_l,
##    seeded, weeds, photos, soil_reads, travel_mm, end_pos}
## A radial robot with several arms runs one schedule per arm, each confined
## to its own sector of the rail; `arms` holds them, `jobs` is arm 0's,
## `windows` the jobs as seen across every arm (first start to last end).
## busy_s is the longest arm's day (wall clock), arm_s the arms' hours summed.
static func day_plan(spec: Dictionary, lay: Dictionary, day: int, detail := true) -> Dictionary:
	var s := spec if spec.has("motion") and spec.has("care") else FarmBotSpec.resolve(spec)
	var n := FarmBotGeom.arm_count(s)
	var arms: Array = []
	var shared := {}
	for i in n:
		arms.append(_arm_plan(s, lay, day, detail, i, shared))
	var plan: Dictionary = (arms[0] as Dictionary).duplicate()
	plan["arms"] = arms
	var keys := ["water_l", "seeded", "weeds", "photos", "soil_reads", "travel_mm"]
	for k in keys:
		var t := 0.0
		for a in arms:
			t += float((a as Dictionary)[k])
		plan[k] = t
	var wall := 0.0
	var arm_s := 0.0
	var windows := {}
	var order: Array = []
	for a2 in arms:
		var ad: Dictionary = a2
		wall = maxf(wall, float(ad["busy_s"]))
		arm_s += float(ad["busy_s"])
		for jv in (ad["jobs"] as Array):
			var j: Dictionary = jv
			var id := str(j["id"])
			var e := float(j["start_s"]) + float(j["dur_s"])
			if not windows.has(id):
				windows[id] = {"id": id, "label": j["label"], "start_s": float(j["start_s"]), "end_s": e}
				order.append(id)
			else:
				windows[id]["start_s"] = minf(float(windows[id]["start_s"]), float(j["start_s"]))
				windows[id]["end_s"] = maxf(float(windows[id]["end_s"]), e)
	var wl: Array = []
	for id2 in order:
		var w: Dictionary = windows[id2]
		w["dur_s"] = float(w["end_s"]) - float(w["start_s"])
		wl.append(w)
	wl.sort_custom(func(a3, b3): return float(a3["start_s"]) < float(b3["start_s"]))
	plan["windows"] = wl
	plan["busy_s"] = wall
	plan["arm_s"] = arm_s
	return plan


## Where every arm is at second `t` of a day plan.
static func sample_arms(plan: Dictionary, t: float) -> Array:
	var out: Array = []
	for a in (plan.get("arms", [plan]) as Array):
		out.append(sample_day(a, t))
	return out


static func _arm_plan(s: Dictionary, lay: Dictionary, day: int, detail: bool, arm: int, shared: Dictionary) -> Dictionary:
	var cr: Dictionary = s["care"]
	var tools: Dictionary = s["tools"]
	var xr := arm_range(s, arm)
	var plan := {"day": day, "arm": arm, "jobs": [], "busy_s": 0.0, "water_l": 0.0, "seeded": 0, "weeds": 0,
		"photos": 0, "soil_reads": 0, "travel_mm": 0.0}
	var growing_all := _growing(lay, day)
	var growing := _in_arm(s, growing_all, xr)
	# Every plant's share of the day's water (shared over every arm's plants).
	var n_times := maxi((cr["water_times"] as Array).size(), 1)
	var per_l := float(cr["water_mm_day"]) / float(n_times) * FarmBotSpec.area_m2(s) / float(maxi(growing_all.size(), 1))
	var due := FarmBotLayout.sections_sown_on(lay, day)
	var sow: Array = []
	for p in (lay["plants"] as Array):
		if int((p as Dictionary)["section"]) in due:
			sow.append(p)
	sow = _in_arm(s, sow, xr)
	var queue: Array = []   # [hour, id]
	if bool(tools["watering"]) and float(cr["water_mm_day"]) > 0.0 and not growing.is_empty():
		for i in (cr["water_times"] as Array).size():
			queue.append([float(cr["water_times"][i]), "water_%d" % i])
	if bool(tools["seeder"]) and not sow.is_empty():
		queue.append([float(cr["seed_hour"]), "seed"])
	if bool(tools["weeder"]) and int(cr["weed_every_days"]) > 0 and day > 0 and day % int(cr["weed_every_days"]) == 0:
		queue.append([float(cr["weed_hour"]), "weed"])
	if int(cr["photo_every_days"]) > 0 and day % int(cr["photo_every_days"]) == 0:
		queue.append([float(cr["photo_hour"]), "photo"])
	if bool(tools["soil_sensor"]) and int(cr["soil_every_days"]) > 0 and day % int(cr["soil_every_days"]) == 0:
		queue.append([float(cr["photo_hour"]) + 0.01, "soil"])
	queue.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
	var pos := park_pos(s, arm)
	var free_s := 0.0
	for q in queue:
		var start := maxf(float(q[0]) * 3600.0, free_s)
		var b := _Build.new(s, pos, detail)
		b.arm = arm
		var id := str(q[1])
		match id:
			"seed":
				_job_seed(b, s, sow)
				plan["seeded"] = int(plan["seeded"]) + b.count
			"weed":
				if not shared.has("grid"):
					shared["grid"] = _photo_grid(s)
				if not shared.has("weeds"):
					shared["weeds"] = weeds_on(s, day)
				_job_weed(b, s, _pts_in(shared["grid"], xr), _pts_in(shared["weeds"], xr))
				plan["weeds"] = int(plan["weeds"]) + b.count
				plan["photos"] = int(plan["photos"]) + b.photos
			"photo":
				if not shared.has("grid"):
					shared["grid"] = _photo_grid(s)
				_job_photo(b, _pts_in(shared["grid"], xr))
				plan["photos"] = int(plan["photos"]) + b.photos
			"soil":
				_job_soil(b, s, lay, xr)
				plan["soil_reads"] = int(plan["soil_reads"]) + b.count
			_:
				# Both waterings visit the same plants in the same order.
				if not shared.has("water_%d" % arm):
					shared["water_%d" % arm] = _serpentine(s, growing)
				_job_water(b, s, shared["water_%d" % arm], per_l)
				plan["water_l"] = float(plan["water_l"]) + b.water_l
		b.use_tool("")
		b.go(park_pos(s, arm))
		pos = b.pos
		free_s = start + b.t
		plan["busy_s"] = float(plan["busy_s"]) + b.t
		plan["travel_mm"] = float(plan["travel_mm"]) + b.travel
		(plan["jobs"] as Array).append({"id": id, "label": _label(id), "tool": b.main_tool,
			"start_s": start, "dur_s": b.t, "segs": b.segs})
	plan["end_pos"] = pos
	plan["park"] = park_pos(s, arm)
	return plan


## Where the machine is at second `t` of a day plan:
## -> {pos: Vector3 machine mm, act, tool, job, spray, busy}
static func sample_day(plan: Dictionary, t: float) -> Dictionary:
	var jobs: Array = plan["jobs"]
	var last: Vector3 = plan.get("park", Vector3(SLOT_X0_MM, SLOT_Y_MM + SLIDE_MM, 0.0))
	for j in jobs:
		var jd: Dictionary = j
		var s0 := float(jd["start_s"])
		if t < s0:
			break
		if t < s0 + float(jd["dur_s"]):
			var r := sample_job(jd, t - s0)
			r["job"] = str(jd["id"])
			r["busy"] = true
			return r
		var segs: Array = jd["segs"]
		if not segs.is_empty():
			last = (segs[segs.size() - 1] as Dictionary)["b"]
	return {"pos": last, "act": "idle", "tool": "", "job": "", "spray": false, "busy": false}


## Where the machine is t seconds into a job (binary search on the segments).
static func sample_job(job: Dictionary, t: float) -> Dictionary:
	var segs: Array = job["segs"]
	if segs.is_empty():
		return {"pos": Vector3.ZERO, "act": "idle", "tool": "", "spray": false}
	var lo := 0
	var hi := segs.size() - 1
	while lo < hi:
		var mid := (lo + hi + 1) >> 1
		if float((segs[mid] as Dictionary)["t0"]) <= t:
			lo = mid
		else:
			hi = mid - 1
	var sg: Dictionary = segs[lo]
	var u := clampf(t - float(sg["t0"]), 0.0, float(sg["dur"]))
	var pos: Vector3 = sg["a"]
	if str(sg["k"]) == "move":
		pos = FarmBotMotion.move_pos(sg["lim"], sg["a"], sg["b"], u)
	return {"pos": pos, "act": str(sg["act"]), "tool": str(sg["tool"]), "spray": str(sg["act"]) == "water"}


## The plants (layout dicts) on an arm's share of the rail.
static func _in_arm(s: Dictionary, plants: Array, xr: Vector2) -> Array:
	if is_inf(xr.x) and is_inf(xr.y):
		return plants
	var out: Array = []
	for p in plants:
		var m := machine_of(s, p)
		if m.x >= xr.x and m.x < xr.y:
			out.append(p)
	return out


static func _pts_in(pts: Array, xr: Vector2) -> Array:
	if is_inf(xr.x) and is_inf(xr.y):
		return pts
	return pts.filter(func(q: Variant) -> bool: return (q as Vector2).x >= xr.x and (q as Vector2).x < xr.y)


## Plants already sown on a day (their first sowing at or before it).
static func _growing(lay: Dictionary, day: int) -> Array:
	var out: Array = []
	for p in (lay["plants"] as Array):
		if float((p as Dictionary)["sow_d"]) <= float(day) + 0.5:
			out.append(p)
	return out


static func _label(id: String) -> String:
	if id.begins_with("water"):
		return "Watering"
	match id:
		"seed":
			return "Seeding"
		"weed":
			return "Weeding"
		"photo":
			return "Photo survey"
		"soil":
			return "Soil readings"
	return id


# --- the jobs -----------------------------------------------------------

static func _job_water(b: _Build, s: Dictionary, growing: Array, per: float) -> void:
	var cr: Dictionary = s["care"]
	b.use_tool("watering")
	var soil := float((s["gantry"] as Dictionary)["soil_z_mm"])
	var wz := minf(soil + WATER_ABOVE_SOIL_MM, SAFE_Z_MM)
	var dwell := per / float(cr["flow_l_min"]) * 60.0
	var pts := growing
	var first := true
	for q in pts:
		var m: Vector2 = q
		if first:
			b.go(Vector3(m.x, m.y, SAFE_Z_MM))
			b.go(Vector3(m.x, m.y, wz))
			first = false
		else:
			b.go(Vector3(m.x, m.y, wz))
		b.dwell(dwell, "water")
		b.water_l += per
	b.go(Vector3(b.pos.x, b.pos.y, SAFE_Z_MM))


static func _job_seed(b: _Build, s: Dictionary, plants: Array) -> void:
	b.use_tool("seeder")
	var soil := float((s["gantry"] as Dictionary)["soil_z_mm"])
	var ty := FarmBotJobs.trough_y(s)
	var tz := soil + TOOL_ABOVE_SOIL_MM
	for q in _serpentine(s, plants):
		var m: Vector2 = q
		# The trough rides on the gantry: pick from it at the gantry's own X.
		b.go(Vector3(m.x, ty, SAFE_Z_MM))
		b.go(Vector3(m.x, ty, tz))
		b.dwell(VACUUM_S, "pick")
		b.go(Vector3(m.x, ty, SAFE_Z_MM))
		b.go(Vector3(m.x, m.y, SAFE_Z_MM))
		b.go(Vector3(m.x, m.y, soil - PLUNGE_MM), "seed")
		b.dwell(RELEASE_S, "seed")
		b.go(Vector3(m.x, m.y, SAFE_Z_MM))
		b.count += 1


static func _job_photo(b: _Build, grid: Array) -> void:
	b.use_tool("")
	for q in grid:
		var m: Vector2 = q
		b.go(Vector3(m.x, m.y, 0.0))
		b.dwell(PHOTO_S, "photo")
		b.photos += 1


static func _job_weed(b: _Build, s: Dictionary, grid: Array, weeds: Array) -> void:
	# The camera first (to find them), then the weeder at each.
	b.use_tool("")
	for q in grid:
		var m: Vector2 = q
		b.go(Vector3(m.x, m.y, 0.0))
		b.dwell(PHOTO_S, "photo")
		b.photos += 1
	if weeds.is_empty():
		return
	b.use_tool("weeder")
	var soil := float((s["gantry"] as Dictionary)["soil_z_mm"])
	for q2 in weeds:
		var m2: Vector2 = q2
		b.go(Vector3(m2.x, m2.y, SAFE_Z_MM))
		b.go(Vector3(m2.x, m2.y, soil - 20.0), "weed")
		b.dwell(WEED_PLUNGE_S, "weed")
		b.go(Vector3(m2.x, m2.y, SAFE_Z_MM))
		b.count += 1


static func _job_soil(b: _Build, s: Dictionary, lay: Dictionary, xr: Vector2) -> void:
	b.use_tool("soil_sensor")
	var soil := float((s["gantry"] as Dictionary)["soil_z_mm"])
	var secs: Array = []
	for sv in (lay["sections"] as Array):
		var cc: Vector2 = (sv as Dictionary)["c"]
		var mx := FarmBotLayout.to_machine(s, cc.x, cc.y).x
		if (is_inf(xr.x) and is_inf(xr.y)) or (mx >= xr.x and mx < xr.y):
			secs.append(sv)
	var stride := maxi(int(ceil(float(secs.size()) / float(MAX_SOIL_READS))), 1)
	var i := 0
	while i < secs.size():
		var c: Vector2 = (secs[i] as Dictionary)["c"]
		var m := FarmBotLayout.to_machine(s, c.x, c.y)
		b.go(Vector3(m.x, m.y, SAFE_Z_MM))
		b.go(Vector3(m.x, m.y, soil - SOIL_DEPTH_MM), "sense")
		b.dwell(SOIL_READ_S, "sense")
		b.go(Vector3(m.x, m.y, SAFE_Z_MM))
		b.count += 1
		i += stride


## The weeds the camera finds on a weeding day: emergence since the last pass
## over the bed, at hashed spots (deterministic per day).
static func weeds_on(s: Dictionary, day: int) -> Array:
	var cr: Dictionary = s["care"]
	var every := maxi(int(cr["weed_every_days"]), 1)
	var n := int(roundf(WEEDS_PER_M2_DAY * FarmBotSpec.area_m2(s) * float(every)))
	if FarmBotGeom.is_radial(s):
		return _weeds_radial(s, day, n)
	var b: Dictionary = s["bed"]
	var L := float(b["length_m"]) * 1000.0
	var W := float(b["width_m"]) * 1000.0
	var out: Array = []
	for i in n:
		var hx := fposmod(float(hash("w%d:%d:x" % [day, i])) / 2147483647.0, 1.0)
		var hz := fposmod(float(hash("w%d:%d:z" % [day, i])) / 2147483647.0, 1.0)
		out.append(Vector2(100.0 + hx * (L - 200.0), 100.0 + hz * (W - 200.0)))
	out.sort_custom(func(a, c): return a.x < c.x)
	return out


## Weeds in the ring beds, spread by area (hashed, deterministic per day).
static func _weeds_radial(s: Dictionary, day: int, n: int) -> Array:
	var rs := FarmBotGeom.rings(s)
	var areas: Array = []
	var tot := 0.0
	for r in rs:
		var rr: Dictionary = r
		var a := 0.5 * (float(rr["a1"]) - float(rr["a0"])) * (pow(float(rr["r1"]), 2.0) - pow(float(rr["r0"]), 2.0))
		tot += a
		areas.append(tot)
	var out: Array = []
	for i in n:
		var u := fposmod(float(hash("w%d:%d:u" % [day, i])) / 2147483647.0, 1.0) * tot
		var k := 0
		while k < areas.size() - 1 and u > float(areas[k]):
			k += 1
		var rr2: Dictionary = rs[k]
		var hr := fposmod(float(hash("w%d:%d:r" % [day, i])) / 2147483647.0, 1.0)
		var ha := fposmod(float(hash("w%d:%d:a" % [day, i])) / 2147483647.0, 1.0)
		var r0 := float(rr2["r0"]) + 0.08
		var r1 := float(rr2["r1"]) - 0.08
		var r := sqrt(lerpf(r0 * r0, r1 * r1, hr))
		var ang := lerpf(float(rr2["a0"]) + 0.08 / r, float(rr2["a1"]) - 0.08 / r, ha)
		out.append(FarmBotGeom.to_machine(s, sin(ang) * r, cos(ang) * r))
	out.sort_custom(func(a, c): return a.x < c.x)
	return out


## Camera stops covering the bed, serpentine along X. On the radial bed the
## stops run round arcs a photo's height apart, over the ring beds only.
static func _photo_grid(s: Dictionary) -> Array:
	if FarmBotGeom.is_radial(s):
		var out2: Array = []
		var sw := FarmBotGeom.sweep(s)
		var rail := FarmBotGeom.rail_r(s) * 1000.0
		var flip := false
		for rv in FarmBotGeom.rings(s):
			var rr: Dictionary = rv
			var nr := maxi(int(ceil((float(rr["r1"]) - float(rr["r0"])) * 1000.0 / PHOTO_H_MM)), 1)
			for j in nr:
				var r := float(rr["r0"]) + (float(j) + 0.5) * (float(rr["r1"]) - float(rr["r0"])) / float(nr)
				var a0 := fposmod(float(rr["a0"]) - sw.x, TAU)
				var a1 := minf(a0 + float(rr["a1"]) - float(rr["a0"]), sw.y)
				var na := maxi(int(ceil((a1 - a0) * r * 1000.0 / PHOTO_W_MM)), 1)
				var row: Array = []
				for k in na:
					row.append(Vector2((a0 + (float(k) + 0.5) * (a1 - a0) / float(na)) * rail, r * 1000.0))
				if flip:
					row.reverse()
				out2.append_array(row)
				flip = not flip
		return out2
	var b: Dictionary = s["bed"]
	var L := float(b["length_m"]) * 1000.0
	var W := float(b["width_m"]) * 1000.0
	var nx := maxi(int(ceil(L / PHOTO_W_MM)), 1)
	var ny := maxi(int(ceil(W / PHOTO_H_MM)), 1)
	var out: Array = []
	for i in nx:
		for j in ny:
			var jj := j if i % 2 == 0 else ny - 1 - j
			out.append(Vector2((float(i) + 0.5) * L / float(nx), (float(jj) + 0.5) * W / float(ny)))
	return out


## A layout plant's machine X, Y (precomputed by FarmBotLayout.solve).
static func machine_of(s: Dictionary, p: Dictionary) -> Vector2:
	if p.has("mx"):
		return Vector2(float(p["mx"]), float(p["my"]))
	return FarmBotLayout.to_machine(s, float(p["x"]), float(p["z"]))


## Plants as machine points in a serpentine order (columns along X, each
## column walked one way then the other) so the gantry rolls the bed once.
static func _serpentine(s: Dictionary, plants: Array) -> Array:
	# Columns: X bins (25 mm on a straight bed; on the radial bed 2 degrees
	# of the arm's swing, as X there is arc along the rail). Sorted natively
	# on (column, Y, X): a comparator lambda cost seconds on a big keyhole.
	var bin := 25.0
	if FarmBotGeom.is_radial(s):
		bin = FarmBotGeom.rail_r(s) * 1000.0 * deg_to_rad(2.0)
	var keyed: Array = []
	for p in plants:
		var m0 := machine_of(s, p)
		keyed.append(Vector3(floorf(m0.x / bin), m0.y, m0.x))
	keyed.sort()
	# Walk every other column the other way.
	var out: Array = []
	var col: Array = []
	var flip := false
	var ck := -INF
	for q in keyed:
		var v: Vector3 = q
		var m := Vector2(v.z, v.y)
		if not col.is_empty() and v.x != ck:
			if flip:
				col.reverse()
			out.append_array(col)
			col = []
			flip = not flip
		col.append(m)
		ck = v.x
	if flip:
		col.reverse()
	out.append_array(col)
	return out


# --- the builder ----------------------------------------------------------

class _Build:
	var lim: Array
	var spec: Dictionary
	var detail: bool
	var pos: Vector3
	var t := 0.0
	var tool := ""
	var main_tool := ""
	var segs: Array = []
	var travel := 0.0
	var count := 0
	var photos := 0
	var water_l := 0.0
	var arm := 0

	func _init(s: Dictionary, start: Vector3, keep: bool) -> void:
		spec = s
		lim = FarmBotMotion.limits(s)
		pos = start
		detail = keep

	func go(to: Vector3, act := "travel") -> void:
		if to.is_equal_approx(pos):
			return
		var d := FarmBotMotion.move_time(lim, pos, to)
		if detail:
			segs.append({"k": "move", "a": pos, "b": to, "t0": t, "dur": d, "act": act, "tool": tool, "lim": lim})
		travel += absf(to.x - pos.x) + absf(to.y - pos.y) + absf(to.z - pos.z)
		t += d
		pos = to

	func dwell(sec: float, act: String) -> void:
		if sec <= 0.0:
			return
		if detail:
			segs.append({"k": "dwell", "a": pos, "b": pos, "t0": t, "dur": sec, "act": act, "tool": tool, "lim": lim})
		t += sec

	## Put the mounted tool back and pick up `want` ("" = none).
	func use_tool(want: String) -> void:
		if want != "":
			main_tool = want
		if tool == want:
			return
		if tool != "":
			var sl := FarmBotJobs.slot_of(spec, tool, arm)
			go(Vector3(sl.x, sl.y + FarmBotJobs.SLIDE_MM, FarmBotJobs.SAFE_Z_MM))
			go(Vector3(sl.x, sl.y + FarmBotJobs.SLIDE_MM, sl.z), "mount")
			go(Vector3(sl.x, sl.y, sl.z), "mount")
			tool = ""
			go(Vector3(sl.x, sl.y, FarmBotJobs.SAFE_Z_MM), "mount")
		if want != "":
			var s2 := FarmBotJobs.slot_of(spec, want, arm)
			go(Vector3(s2.x, s2.y, FarmBotJobs.SAFE_Z_MM))
			go(Vector3(s2.x, s2.y, s2.z), "mount")
			tool = want
			go(Vector3(s2.x, s2.y + FarmBotJobs.SLIDE_MM, s2.z), "mount")
			go(Vector3(s2.x, s2.y + FarmBotJobs.SLIDE_MM, FarmBotJobs.SAFE_Z_MM), "mount")
