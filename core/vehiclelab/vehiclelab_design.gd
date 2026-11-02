class_name VehicleDesign
extends RefCounted

## A living vehicle solved (pure, cached by VehicleSpec.key_of): where every
## part is, what it weighs, who sleeps where, what it provides and what it
## burns. The builder, the placement hooks, the NPC bridge, the driving
## profile and the selftest all read THIS — never the spec directly.
##
## Frame (the builder's local space and every position here): metres, the
## origin on the GROUND under the middle of the overall length on the
## centreline, -Z = the FRONT (the rider's forward), +X = the right / curb
## side, +Y up. Internally the layout is worked out from the front bumper
## (`zf`, growing rearward) and shifted by -L/2 at the end.
##
## Sleepers lie along the BED's long axis (whichever of its footprint sides
## is longer). `beds` entries: {pos: Vector3 (the mattress top under the
## sleeper), yaw (the lying direction: yaw 0 = along Z, PI/2 = along X — the
## NPC convention, a body lies along (-sin yaw, -cos yaw)), length_m, bed}.

const CACHE_MAX := 64
const WALL_T := 0.06
const OCCUPANT_KG := 80.0
const FLOOR_KG_M2 := 30.0
## Travelling seats by type (incl. the driver), when the spec says -1.
const SEATS := {"van": 3, "cargo_van": 2, "shuttle_bus": 6, "school_bus": 8, "step_van": 2,
	"ambulance": 3, "rv": 6, "motorhome": 6, "box_truck": 3, "trailer": 0, "semi_container": 2}
## The gear a camp brings in a living vehicle on a typical trip, for the laden
## mass the energy model and the mpg bands use.
const GEAR_KG := 250.0
const MATTRESS_T := 0.15

static var _cache := {}


static func solve(spec: Dictionary) -> Dictionary:
	var key := VehicleSpec.key_of(spec)
	if _cache.has(key):
		return _cache[key]
	var d := _solve(VehicleSpec.resolve(spec))
	if _cache.size() >= CACHE_MAX:
		_cache.clear()
	_cache[key] = d
	return d


static func _solve(s: Dictionary) -> Dictionary:
	var ch: Dictionary = s["ch"]
	var bd: Dictionary = s["bd"]
	var d := {"spec": s, "type": str(s["type"]), "name": str(s.get("name", "")),
		"cab": str(ch.get("cab", "cutaway")), "fuel": str(ch.get("fuel", "gasoline")),
		"tank_l": float(ch.get("tank_l", 0.0)), "battery_kwh": float(ch.get("battery_kwh", 0.0)),
		"trip": s["trip"], "checks": []}
	_layout(d, ch, bd)
	_interior(d, s)
	_exterior(d, s)
	d["systems"] = VehicleInterior.systems(d)
	_masses(d, ch, bd, s)
	_cargo(d, bd)
	d["energy_55"] = VehicleEnergy.at_speed(d, VehicleEnergy.MPS_55MPH)
	d["trip_estimate"] = VehicleEnergy.trip(d, float((s["trip"] as Dictionary).get("one_way_mi", 0.0)))
	_checks(d)
	return d


# --- layout ---------------------------------------------------------------------

static func _layout(d: Dictionary, ch: Dictionary, bd: Dictionary) -> void:
	var cab := str(ch.get("cab", "cutaway"))
	var integral := bool(bd.get("integral", false)) or cab == "full_van"
	var body_len := float(bd["length_m"])
	# An integral body runs the length its chassis was built for (a 25 ft
	# bus is not a 35 ft bus with the same shell): a chassis `body_len_m`
	# beats the body's own length, and a length the player typed beats both.
	var body_ov: Dictionary = (d["spec"] as Dictionary).get("body", {})
	if integral and float(ch.get("body_len_m", 0.0)) > 0.0 and not body_ov.has("length_m"):
		body_len = float(ch["body_len_m"])
	var hood := float(ch.get("hood_len_m", 0.0))
	var cab_len := float(ch.get("cab_len_m", 0.0))
	var body_z0 := 0.0
	match cab:
		"full_van":
			# The shell IS the van; a separate box (a cutaway build on a
			# van chassis) sits behind the cab, never at the bumper.
			body_z0 = 0.0 if integral else cab_len
		"cutaway":
			body_z0 = cab_len - 0.05
		"cowl":
			body_z0 = hood if integral else cab_len + 0.08
		"forward":
			body_z0 = 0.0 if integral else cab_len + 0.08
		"tractor":
			body_z0 = cab_len + 0.35
		_:
			body_z0 = float(ch.get("front_overhang_m", 1.1))
	var body_z1 := body_z0 + body_len
	var length := body_z1
	var width := maxf(float(bd["width_m"]), float(ch.get("cab_w_m", 0.0)))
	var height := float(bd["height_m"])
	var floor_y := float(bd["floor_h_m"])
	var roof := str(bd.get("roof", "flat"))
	var roof_t := 0.1 if roof != "high_top" else 0.08
	# The living box: behind the driver (a van, a bus) or the whole box.
	var house_z0 := body_z0 + WALL_T
	if cab == "full_van":
		house_z0 = cab_len
	elif integral:
		house_z0 = body_z0 + maxf(cab_len - body_z0, 1.2)
	elif cab == "cutaway":
		house_z0 = body_z0 + 0.05
	var house_z1 := body_z1 - WALL_T
	var inner_w := float(bd["width_m"]) - 2.0 * WALL_T
	var ceil_y := height - roof_t
	if roof == "crown" or roof == "arched":
		ceil_y = height - roof_t - 0.05
	# Axles (zf) + wheels.
	var axles: Array = []
	var fo := float(ch.get("front_overhang_m", 1.0))
	var wb := float(ch.get("wheelbase_m", 0.0))
	var r := float(ch.get("tyre_d_m", 0.75)) * 0.5
	var tw := float(ch.get("tyre_w_m", 0.22))
	var track := float(ch.get("track_m", 1.8))
	var dually := bool(ch.get("dually", false))
	var n_rear := maxi(int(ch.get("rear_axles", 1)), 1)
	if cab == "none":
		var c := body_z0 + body_len * 0.55
		if n_rear == 2:
			axles.append({"zf": c - 0.45, "steer": false, "dual": false})
			axles.append({"zf": c + 0.45, "steer": false, "dual": false})
		else:
			axles.append({"zf": c, "steer": false, "dual": false})
	else:
		axles.append({"zf": fo, "steer": true, "dual": false})
		var rz := fo + wb
		if n_rear == 2:
			axles.append({"zf": rz - 0.65, "steer": false, "dual": dually})
			axles.append({"zf": rz + 0.65, "steer": false, "dual": dually})
		else:
			axles.append({"zf": rz, "steer": false, "dual": dually})
		if cab == "tractor":
			# The container chassis' own tandem near the box's rear.
			axles.append({"zf": body_z1 - 2.2, "steer": false, "dual": true})
			axles.append({"zf": body_z1 - 0.95, "steer": false, "dual": true})
	# Driver: seat z (from the front), x (left), eye height.
	var seat := Vector3.ZERO
	var drivable := cab != "none"
	match cab:
		"full_van", "cutaway":
			var fy0 := float(ch.get("frame_h_m", 0.6))
			seat = Vector3(-0.42, fy0 + 1.28, hood + 0.75)
			# The eye sits ~0.55 m behind the windshield at its own height
			# (the cab profile's slope from the hood's top to the roof, as
			# VehicleBuilder._cab draws it), not pressed against the glass.
			var ws_lo := fy0 + 0.65
			var ws_hi := float(ch.get("cab_h_m", 2.2))
			var frac := clampf((seat.y - ws_lo) / maxf(ws_hi - ws_lo, 0.1), 0.0, 1.0)
			seat.z = maxf(seat.z, hood + 0.85 * frac + 0.55)
			# A cutaway's cab is short: never behind its own back wall.
			if cab_len > 0.0:
				seat.z = minf(seat.z, cab_len - 0.25)
		"cowl":
			var eye := floor_y + 1.3 if integral else float(ch.get("frame_h_m", 1.0)) + 1.45
			seat = Vector3(-0.55, eye, hood + 0.7)
		"forward":
			var floor_ref := floor_y if integral else float(ch.get("frame_h_m", 0.8))
			seat = Vector3(-0.55, floor_ref + 1.35, 0.85)
		"tractor":
			seat = Vector3(-0.6, float(ch.get("frame_h_m", 1.1)) + 1.6, hood + 0.8)
	var half := length * 0.5
	var wheels: Array = []
	for a in axles:
		var ad: Dictionary = a
		var z := float(ad["zf"]) - half
		for side in [-1.0, 1.0]:
			var x: float = side * (track * 0.5)
			wheels.append({"pos": Vector3(x, r, z), "r": r, "w": tw, "steer": ad["steer"]})
			if bool(ad["dual"]):
				wheels.append({"pos": Vector3(x + side * (tw + 0.03), r, z), "r": r, "w": tw,
					"steer": false})
	d["length_m"] = length
	d["width_m"] = width
	d["height_m"] = height
	d["half_len"] = half
	d["integral"] = integral
	# The shell's cross-section and front rake (VehicleBuilder draws it from
	# these; VehicleExterior puts things on it): crown over straight walls
	# with a rounded corner, a bottom edge, and the front's lean-back.
	var hw := float(bd["width_m"]) * 0.5
	var corner := clampf(float(bd.get("corner_r_m", 0.1)), 0.0, minf(hw * 0.6, 0.4))
	var crown := float({"high_top": 0.03, "crown": 0.1, "arched": 0.3, "cabover": 0.07}.get(roof, 0.0))
	var y0 := clampf(floor_y - 0.45, 0.32, 0.6) if integral else floor_y - 0.12
	var shell_z0 := body_z0
	var rake_top := 0.0
	var rake_from := y0
	if cab == "full_van":
		# The cab covers the van's front to the windshield top; the shell
		# starts there and its high roof leans back.
		shell_z0 = hood + 0.8
		rake_from = float(ch.get("cab_h_m", 2.0))
		rake_top = 0.4
	elif cab == "forward" and integral:
		rake_top = 0.45 if str(d["spec"].get("body_id", "")) == "class_a_motorhome" else 0.12
		rake_from = y0 + 0.3
	elif cab == "none":
		rake_top = 0.3
		rake_from = (y0 + height) * 0.5
	d["body"] = {"z0": shell_z0 - half, "z1": body_z1 - half, "w": float(bd["width_m"]),
		"h": height, "floor_y": floor_y, "roof": roof, "corner_r": corner, "crown": crown,
		"y0": y0, "wall_top": height - crown - corner, "rake_top": rake_top, "rake_from": rake_from,
		"windows": str(bd.get("windows", "few")), "rear_door": str(bd.get("rear_door", "none")),
		"side_door": str(bd.get("side_door", "hinged")), "id": str(d["spec"].get("body_id", "")),
		"door_at": float(bd.get("door_at_m", -1.0))}
	d["cab_geo"] = {"style": cab, "hood": hood, "cab_len": cab_len, "z0": -half,
		"h": float(ch.get("cab_h_m", 2.2)), "w": float(ch.get("cab_w_m", width)),
		"frame_h": float(ch.get("frame_h_m", 0.7)), "integral": integral}
	d["house"] = {"z0": house_z0 - half, "z1": house_z1 - half, "len": house_z1 - house_z0,
		"w": inner_w, "floor_y": floor_y, "ceil_y": ceil_y, "height": ceil_y - floor_y}
	d["axles"] = axles
	d["wheels"] = wheels
	d["drivable"] = drivable
	d["driver_seat"] = Vector3(seat.x, seat.y, seat.z - half) if drivable else Vector3.ZERO
	d["frame"] = {"y": float(ch.get("frame_h_m", 0.7)), "track": track}
	# Towing (VehicleTow): a ball hitch just behind a drivable vehicle's rear
	# (none on the semi, whose fifth wheel already carries the box), and a
	# trailer's coupler at its tongue tip with its axles' middle.
	if drivable and cab != "tractor":
		d["hitch"] = Vector3(0.0, 0.5, half + 0.15)
	if cab == "none":
		var az := 0.0
		for a in axles:
			az += float((a as Dictionary)["zf"])
		d["axle_z"] = az / maxf(float(axles.size()), 1.0) - half
		d["coupler"] = Vector3(0.0, 0.5, -half)
	var steer := deg_to_rad(maxf(float(ch.get("max_steer_deg", 40.0)), 1.0))
	# The outer front wheel's turning radius (what a spec sheet quotes as the
	# turning circle / 2): rear-axle centre radius WB / tan δ, then out to the
	# front wheel across half the track.
	var rr := wb / tan(steer) if wb > 0.0 else 0.0
	d["turn_radius_m"] = sqrt(pow(rr + track * 0.5, 2.0) + wb * wb) if wb > 0.0 else 0.0
	var fill := VehicleEnergy.SHAPE_FILL
	d["frontal_m2"] = width * height * fill
	d["cd"] = float(bd.get("cd", 0.6))


# --- interior -------------------------------------------------------------------

static func _interior(d: Dictionary, s: Dictionary) -> void:
	var house: Dictionary = d["house"]
	var hw := float(house["w"])
	var fy := float(house["floor_y"])
	var els: Array = []
	var beds: Array = []
	var seats: Array = []
	var roles := {"kitchen": [], "shower": [], "restroom": []}
	var sleeps := 0
	var battery_kwh := 0.0
	var water_l := 0.0
	var grey_l := 0.0
	var mass := 0.0
	var n := 0
	var loads: Array = []
	for e in (s["interior"] as Dictionary).get("elements", []):
		if not (e is Dictionary):
			continue
		var ed: Dictionary = e
		n += 1
		var el := resolve_interior_element(d, ed, n)
		if el.is_empty():
			continue
		var type := str(el["type"])
		var t := VehicleCatalog.interior_type(type)
		var xc := float(el["x"])
		var lz := float(el["z"])
		var fx := float(el["fx"])
		els.append(el)
		mass += float(t.get("mass_kg", 0.0))
		var lw := float(ed.get("watts", t.get("load_w", 0.0)))
		if lw > 0.0:
			loads.append({"id": str(el["id"]), "name": str(t.get("label", type)).split(" (")[0],
				"watts": lw, "type": type})
		var provides: Array = t.get("provides", [])
		if provides.has("sleep"):
			var made := _bed_spots(el, type)
			sleeps += made.size()
			beds.append_array(made)
		if provides.has("seat"):
			seats.append_array(_seat_spots(el, type, fy))
		if provides.has("kitchen"):
			var dir := -1.0 if xc > 0.0 else 1.0   # stand toward the aisle
			var px := xc + dir * (fx * 0.5 + 0.32)
			if fx >= hw - 0.2:
				px = xc
			(roles["kitchen"] as Array).append({"pos": Vector3(px, fy, lz),
				"yaw": PI * 0.5 * dir, "kind": "stand"})
		if provides.has("shower"):
			(roles["shower"] as Array).append({"pos": Vector3(xc, fy + 0.04, lz), "yaw": 0.0,
				"kind": "stand"})
		if provides.has("restroom"):
			(roles["restroom"] as Array).append({"pos": Vector3(xc, fy, lz), "yaw": 0.0,
				"kind": "stand"})
		if provides.has("battery"):
			battery_kwh += float(ed.get("kwh", t.get("kwh", 5.0)))
		if provides.has("water"):
			water_l += float(ed.get("litres", t.get("litres", 100.0)))
		if provides.has("grey"):
			grey_l += float(ed.get("litres", t.get("litres", 80.0)))
	d["interior"] = els
	d["beds"] = beds
	d["sleeps"] = sleeps
	d["seat_spots"] = seats
	d["role_spots"] = roles
	d["house_battery_kwh"] = battery_kwh
	d["water_l"] = water_l
	d["grey_l"] = grey_l
	d["interior_kg"] = mass
	d["house_loads"] = loads
	var st := int(s.get("seats", -1))
	d["seats"] = st if st >= 0 else int(SEATS.get(str(s["type"]), 2))


## One interior element as the design draws it: {id, type, x (across, from
## the centre line), z (vehicle-local), fx / fz (footprint across / along),
## base_y / top_y, yaw90, color, label}, clamped inside the living box,
## wall-hung things on the nearer wall, a ceiling light on the ceiling, the
## cab-over bunk over the cab. The spec's own z is from the box's FRONT
## (< 0 counts from its rear). {} for an unknown type. The designer's ghost
## goes through this too, so a placed element lands where its ghost stood.
static func resolve_interior_element(d: Dictionary, ed: Dictionary, n: int = 0) -> Dictionary:
	var type := str(ed.get("type", ""))
	var t := VehicleCatalog.interior_type(type)
	if t.is_empty():
		return {}
	var house: Dictionary = d["house"]
	var hlen := float(house["len"])
	var hw := float(house["w"])
	var fy := float(house["floor_y"])
	var cy := float(house["ceil_y"])
	var w := clampf(float(ed.get("w", t["w"])), 0.02, hw)
	var l := clampf(float(ed.get("l", t["l"])), 0.02, maxf(hlen, 0.5))
	var h := clampf(float(ed.get("h", t["h"])), 0.02, maxf(cy - fy, 0.5))
	var yaw90 := absf(float(ed.get("yaw", 0.0))) > 45.0
	var fx := l if yaw90 else w       # footprint across
	var fz := w if yaw90 else l       # footprint along
	var zc := float(ed.get("z", hlen * 0.5))
	if zc < 0.0:
		zc = hlen + zc
	var xc := float(ed.get("x", 0.0))
	xc = clampf(xc, -hw * 0.5 + fx * 0.5, hw * 0.5 - fx * 0.5) if fx < hw else 0.0
	zc = clampf(zc, fz * 0.5, hlen - fz * 0.5) if fz < hlen else hlen * 0.5
	var base_y := fy
	if t.has("wall_hung"):
		base_y = fy + float(t["wall_hung"])
		var side := 1.0 if xc >= 0.0 else -1.0
		xc = side * (hw * 0.5 - fx * 0.5)
	elif bool(t.get("ceiling", false)):
		base_y = cy - h
	var top := base_y + h
	var lz := float(house["z0"]) + zc
	var el := {"id": str(ed.get("id", "i%d" % n)), "type": type, "x": xc, "z": lz,
		"zc": zc, "fx": fx, "fz": fz, "base_y": base_y, "top_y": top, "yaw90": yaw90,
		"w": w, "l": l, "h": h,
		"color": t.get("color", [0.6, 0.5, 0.4]), "label": str(t.get("label", type))}
	for k in ["kwh", "litres", "watts"]:
		if ed.has(k):
			el[k] = float(ed[k])
		elif t.has(k if k != "watts" else "load_w"):
			el[k] = float(t[k if k != "watts" else "load_w"])
	# The cab-over bunk sits over the cab, not on the floor.
	if type == "cabover_bed":
		var cg: Dictionary = d["cab_geo"]
		var bunk_floor := float(cg["h"]) + 0.08
		var z_back := float(house["z0"]) + 0.3
		var z_front := maxf(float(cg["z0"]) + float(cg["hood"]) * 0.45, z_back - fz)
		el["z"] = (z_front + z_back) * 0.5
		el["fz"] = z_back - z_front
		el["x"] = 0.0
		el["base_y"] = bunk_floor
		el["top_y"] = bunk_floor + 0.2
		el["cabover"] = true
	return el


## The doors people walk in by, vehicle-local: side doors on the curb side
## (+X), a rear door across the back. {where, x, z0, z1, y0, y1}. The builder
## draws them from these and the interior's access check starts from them.
static func door_spans(d: Dictionary) -> Array:
	var out: Array = []
	var b: Dictionary = d["body"]
	var house: Dictionary = d["house"]
	var cg: Dictionary = d["cab_geo"]
	var hw := float(b["w"]) * 0.5
	var floor_y := float(b["floor_y"])
	var z0 := float(b["z0"])
	var z1 := float(b["z1"])
	var side := str(b["side_door"])
	if side != "none":
		var w := 1.25 if side == "slider" else (0.85 if side == "bus" else 0.72)
		var dz0 := float(house["z0"]) + 0.2
		if side == "bus":
			dz0 = z0 + 0.1 if bool(d["integral"]) else float(house["z0"]) + 0.1
		elif str(cg["style"]) == "full_van":
			dz0 = float(house["z0"]) - 0.25
		# A body override: the door's front edge this far back from the
		# front of the living box (a travel trailer's door is mid-curbside).
		var at := float(b.get("door_at", -1.0))
		if at >= 0.0:
			dz0 = clampf(float(house["z0"]) + at, z0 + 0.1, z1 - 0.3 - w)
		var dz1 := minf(dz0 + w, z1 - 0.3)
		out.append({"where": "side", "x": hw, "z0": dz0, "z1": dz1, "y0": float(b["y0"]) + 0.03,
			"y1": minf(float(b["wall_top"]) - 0.05, floor_y + 1.95)})
	var rear := str(b["rear_door"])
	if rear != "none":
		var rw := hw - 0.08
		out.append({"where": "rear", "x0": -rw, "x1": rw, "z": z1, "y0": floor_y - 0.05,
			"y1": minf(float(b["wall_top"]) - 0.08, floor_y + (2.2 if rear == "barn" else 2.4))})
	return out


## One spot per sleeper on a bed: side by side across its short side, lying
## along its long side, on the mattress.
static func _bed_spots(el: Dictionary, type: String) -> Array:
	var out: Array = []
	var fx := float(el["fx"])
	var fz := float(el["fz"])
	var along_z := fz >= fx
	var short := fx if along_z else fz
	var long := fz if along_z else fx
	var lie_yaw := 0.0 if along_z else PI * 0.5
	var x := float(el["x"])
	var z := float(el["z"])
	if type == "bunk":
		var lower := float(el["base_y"]) + 0.45
		for top in [lower, float(el["top_y"])]:
			out.append({"pos": Vector3(x, top, z), "yaw": lie_yaw, "length_m": long, "bed": el["id"]})
		return out
	var n := VehicleCatalog.bed_sleepers(type, short)
	for k in n:
		var off := (float(k) - float(n - 1) * 0.5) * (short / float(n))
		var p := Vector3(x + off, float(el["top_y"]), z) if along_z else Vector3(x, float(el["top_y"]), z + off)
		out.append({"pos": p, "yaw": lie_yaw, "length_m": long, "bed": el["id"]})
	return out


## Seats on a bench, a dinette or a sofa, facing across it.
static func _seat_spots(el: Dictionary, type: String, floor_y: float) -> Array:
	var out: Array = []
	var x := float(el["x"])
	var z := float(el["z"])
	var fx := float(el["fx"])
	var fz := float(el["fz"])
	var sy := floor_y + 0.45
	if type == "dinette":
		# Two benches facing over the table (along the vehicle).
		for side in [-1.0, 1.0]:
			var zz: float = z + side * (fz * 0.5 - 0.22)
			var yaw := 0.0 if side > 0.0 else PI   # yaw 0 faces -Z (toward the table from behind)
			out.append({"pos": Vector3(x, sy, zz), "yaw": yaw, "kind": "sit"})
		return out
	# A bench / sofa along a wall: sit facing the aisle.
	var face := -1.0 if x > 0.0 else 1.0
	var n := maxi(int(floor(maxf(fx, fz) / 0.6)), 1)
	for k in n:
		var off := (float(k) - float(n - 1) * 0.5) * 0.6
		var p := Vector3(x, sy, z + off) if fz >= fx else Vector3(x + off, sy, z)
		# yaw turns -Z to face: facing -X is +PI/2, +X is -PI/2.
		out.append({"pos": p, "yaw": -PI * 0.5 * face, "kind": "sit"})
	return out


# --- exterior ---------------------------------------------------------------------

## The roof / side / rear items, resolved onto their faces (VehicleExterior),
## with ids filled in, plus their totals (mass, solar watts, loads).
static func _exterior(d: Dictionary, s: Dictionary) -> void:
	var out: Array = []
	var n := 0
	for e in (s.get("exterior", {}) as Dictionary).get("elements", []):
		if not (e is Dictionary):
			continue
		n += 1
		var el := VehicleExterior.resolve_element(d, e as Dictionary)
		if el.is_empty():
			continue
		if str(el["id"]).is_empty():
			el["id"] = "x%d" % n
		out.append(el)
	d["exterior"] = out
	d["exterior_totals"] = VehicleExterior.totals(out)
	d["solar_w"] = float((d["exterior_totals"] as Dictionary)["solar_w"])


# --- masses, cargo, checks ---------------------------------------------------------

static func _masses(d: Dictionary, ch: Dictionary, bd: Dictionary, s: Dictionary) -> void:
	var b: Dictionary = d["body"]
	var L := float(b["z1"]) - float(b["z0"])
	var W := float(b["w"])
	var H := float(b["h"]) - float(b["floor_y"])
	var body_kg := 0.0
	if not bool(bd.get("in_curb", false)):
		if bd.has("mass_kg"):
			body_kg = float(bd["mass_kg"])
		else:
			var skin := 2.0 * L * H + 2.0 * W * H + L * W
			body_kg = skin * float(bd.get("wall_kg_m2", 12.0)) + L * W * FLOOR_KG_M2
	var curb := float(ch.get("curb_kg", 3000.0)) + body_kg + float(d["interior_kg"]) \
		+ float((d.get("exterior_totals", {}) as Dictionary).get("kg", 0.0))
	var gvwr := float(ch.get("gvwr_kg", curb * 1.3))
	var occupants := float(maxi(int(d["seats"]), 1)) * OCCUPANT_KG
	d["body_kg"] = body_kg
	d["curb_kg"] = curb
	d["gvwr_kg"] = gvwr
	d["laden_kg"] = curb + minf(occupants, 2.0 * OCCUPANT_KG) + GEAR_KG
	d["payload_kg"] = gvwr - curb - occupants


static func _cargo(d: Dictionary, bd: Dictionary) -> void:
	var house: Dictionary = d["house"]
	var floor_area := float(house["len"]) * float(house["w"])
	var used := 0.0
	for e in d["interior"]:
		var ed: Dictionary = e
		if bool(ed.get("cabover", false)) or float(ed["base_y"]) > float(house["floor_y"]) + 0.3:
			continue
		used += float(ed["fx"]) * float(ed["fz"])
	var free := maxf(floor_area - used, 0.0)
	var h := float(house["height"])
	var doors: Array = []
	var rd := str(bd.get("rear_door", "none"))
	if rd != "none":
		doors.append({"where": "rear", "kind": rd, "w_m": float(house["w"]) - 0.1,
			"h_m": minf(h - 0.05, 2.2 if rd == "barn" else h - 0.05)})
	var sd := str(bd.get("side_door", "none"))
	if sd != "none":
		var sw := 1.25 if sd == "slider" else (0.85 if sd == "bus" else 0.75)
		doors.append({"where": "side", "kind": sd, "w_m": sw, "h_m": minf(h, 1.9)})
	d["cargo"] = {"floor_free_m2": free, "volume_m3": free * h * 0.7, "doors": doors,
		"payload_kg": maxf(float(d["payload_kg"]), 0.0)}


static func _checks(d: Dictionary) -> void:
	var c: Array = d["checks"]
	var house: Dictionary = d["house"]
	if float(d["payload_kg"]) < 0.0:
		c.append({"level": "error", "text": "Over the GVWR by %d kg with %d aboard — lighten the build." %
			[int(-float(d["payload_kg"])), int(d["seats"])]})
	if float(house["height"]) < 1.7 and str(d["type"]) != "trailer":
		c.append({"level": "warn", "text": "Only %.2f m of headroom inside — most people stoop." %
			float(house["height"])})
	if int(d["sleeps"]) == 0:
		c.append({"level": "warn", "text": "No bed: nobody can sleep in it."})
	var els: Array = d["interior"]
	for i in els.size():
		for j in range(i + 1, els.size()):
			if _overlap(els[i], els[j]):
				c.append({"level": "warn", "text": "%s and %s overlap." %
					[str((els[i] as Dictionary)["label"]), str((els[j] as Dictionary)["label"])],
					"ids": [str((els[i] as Dictionary)["id"]), str((els[j] as Dictionary)["id"])]})
	c.append_array(VehicleInterior.checks(d))
	var drag := float(d["length_m"])
	if drag > 13.0:
		c.append({"level": "info", "text": "%.1f m long: it needs a wide road and room to turn." % drag})


## Stored under a bed platform: a battery, a tank, an inverter.
const UNDER_BED_OK := ["battery", "water_tank", "grey_tank", "inverter"]


static func _overlap(a: Dictionary, b: Dictionary) -> bool:
	if bool(a.get("cabover", false)) != bool(b.get("cabover", false)):
		return false
	for pair in [[a, b], [b, a]]:
		var bed: Dictionary = pair[0]
		var other: Dictionary = pair[1]
		if (str(bed["type"]) == "bed" or str(bed["type"]) == "bunk") \
				and UNDER_BED_OK.has(str(other["type"])) \
				and float(other["top_y"]) <= float(bed["top_y"]) - MATTRESS_T - 0.05:
			return false
	var ya0 := float(a["base_y"])
	var ya1 := float(a["top_y"])
	var yb0 := float(b["base_y"])
	var yb1 := float(b["top_y"])
	if ya1 <= yb0 + 0.02 or yb1 <= ya0 + 0.02:
		return false
	var dx := absf(float(a["x"]) - float(b["x"])) - (float(a["fx"]) + float(b["fx"])) * 0.5
	var dz := absf(float(a["z"]) - float(b["z"])) - (float(a["fz"]) + float(b["fz"])) * 0.5
	return dx < -0.02 and dz < -0.02


# --- what other systems read -------------------------------------------------------

## The PlacedVehicle riding profile (the same keys as PlacedVehicle.PROFILES)
## for a solved design. {} for something that cannot be driven (a trailer).
static func riding_profile(d: Dictionary) -> Dictionary:
	if not bool(d.get("drivable", false)):
		return {}
	var L := float(d["length_m"])
	var R := maxf(float(d["turn_radius_m"]), 3.0)
	var top := float(((d["spec"] as Dictionary)["ch"] as Dictionary).get("top_speed_mps", 30.0))
	var max_speed := minf(clampf(26.0 - L * 1.3, 9.0, 16.0), top)
	var seat: Vector3 = d["driver_seat"]
	var fuel := str(d["fuel"])
	var e15 := VehicleEnergy.at_speed(d, 15.0)
	var label := str(VehicleCatalog.type_info(str(d["type"])).get("label", "vehicle")).to_lower()
	return {
		"display_name": str(d.get("name", "Vehicle")),
		"prompt": "Drive the %s" % label.split(" (")[0],
		"speed_multiplier": 0.8, "max_speed": max_speed, "max_camera_tilt": 0.0,
		"tilt_speed": 0.0, "camera_shake_intensity": 0.01, "camera_shake_speed": 7.0,
		"min_shake_speed": 0.5,
		# The player's eye sits ~1.65 m over the prop origin; the offset puts it
		# at the driver's eye.
		"camera_offset": Vector3(seat.x, seat.y - 1.65, seat.z),
		"is_golf_cart": true, "use_cart_steering": true, "min_turn_radius": R, "turn_by_radius": true,
		"max_turn_rate": clampf(rad_to_deg(max_speed * 0.35 / R), 12.0, 40.0),
		"yaw_deg": 0.0, "radius": maxf(L, float(d["width_m"])) * 0.5 + 1.2,
		"battery_wh": float(d["battery_kwh"]) * 1000.0 if fuel == "electric" else 0.0,
		"wh_per_mile": float(e15["kwh_per_km"]) * 1000.0 * VehicleEnergy.MI_M / 1000.0,
		"charge_w": 7200.0 if fuel == "electric" else 0.0,
		"fuel_l": float(d["tank_l"]) if fuel == "gasoline" or fuel == "diesel" else 0.0,
		"chase_m": clampf(L * 1.25, 6.0, 22.0), "chase_h": clampf(float(d["height_m"]) * 0.9 + 0.8, 2.2, 5.5),
		"half_width": float(d["width_m"]) * 0.5,
	}


## The fastest a vehicle turning on its tightest circle can swing round, in
## degrees a second: yaw rate = v / R (kinematic, no slip), so a bus at walking
## pace barely turns and nothing pivots on the spot.
static func yaw_rate_limit_deg(v: float, turn_radius_m: float) -> float:
	if turn_radius_m <= 0.0:
		return INF
	return rad_to_deg(absf(v) / turn_radius_m)


## Miles left at a steady 55 mph from `litres` of fuel (or `kwh` for an
## electric chassis): the dashboard's range.
static func range_mi(d: Dictionary, litres: float, kwh: float = 0.0) -> float:
	var e := VehicleEnergy.at_speed(d, VehicleEnergy.MPS_55MPH)
	var km := 0.0
	if str(d.get("fuel", "")) == "electric":
		km = kwh / maxf(float(e["kwh_per_km"]), 1e-6)
	else:
		km = litres / maxf(float(e["l_per_km"]), 1e-6)
	return km * 1000.0 / VehicleEnergy.MI_M


## Litres (or kWh) drawn over `metres` at `v` m/s — what the dashboard bills
## while it is driven.
static func energy_for_distance(d: Dictionary, metres: float, v: float) -> Dictionary:
	var e := VehicleEnergy.at_speed(d, v)
	return {"litres": metres / 1000.0 * float(e["l_per_km"]),
		"kwh": metres / 1000.0 * float(e["kwh_per_km"])}


## Every space the vehicle offers, for the NPC registry: {role ("" = the
## sleep space), space_type, capacity, anchor: Vector3 (local)}.
static func spaces(d: Dictionary) -> Array:
	var out: Array = []
	if int(d.get("sleeps", 0)) > 0:
		out.append({"role": "", "space_type": "sleep", "capacity": int(d["sleeps"]),
			"anchor": Vector3.ZERO})
	var roles: Dictionary = d.get("role_spots", {})
	for role in ["kitchen", "shower", "restroom"]:
		var spots: Array = roles.get(role, [])
		if spots.is_empty():
			continue
		out.append({"role": role, "space_type": role, "capacity": spots.size(),
			"anchor": (spots[0] as Dictionary)["pos"]})
	return out


## The packed (shipping) envelope: a vehicle drives itself, but the packing
## lab still needs its box.
static func packed_spec(d: Dictionary) -> Dictionary:
	return {"w_m": float(d["length_m"]), "d_m": float(d["width_m"]), "h_m": float(d["height_m"]),
		"mass_kg": float(d["curb_kg"]), "form": "folded", "source": "computed", "this_side_up": true}
