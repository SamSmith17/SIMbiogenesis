class_name VehicleInterior
extends RefCounted

## The inside of a living vehicle as the designer edits it: the palette,
## where a ray meets the floor, the armed template's ghost, picking an
## element under a ray, and the checks a real conversion is held to — a way
## in to every bed and fixture from a door, room to sit up in bed, standing
## room in the shower, and things too big for any door. Pure: VehicleDesign
## (its checks) and the designer modal both call it.
##
## Frame: vehicle-local (origin on the ground at the middle of the length,
## -Z the front, +X the curb side). An element's spec position is x across
## the centre line and z from the living box's FRONT (VehicleDesign
## .resolve_interior_element turns it into a vehicle-local z).

## The narrowest walkway a person gets along: a 95th-percentile adult's
## shoulders (bideltoid breadth) are ~0.5 m (ANSUR II), and 0.5 m is about
## the tightest aisle van and bus conversions are built with.
const AISLE_M := 0.5
## Grid cell of the access check.
const CELL_M := 0.1
## How close a free floor cell must come to an element to use it: an arm's
## reach to a bed edge, a counter, a shower door.
const REACH_M := 0.45
## Below the shoulders only the hips need room: beside anything no higher
## than LOW_TOP_M above the floor (a bed, a bench, a counter) the clear width
## is HIP_M, about the 95th-percentile standing hip breadth (ANSUR II: men
## ~0.38 m, women ~0.41 m), not the shoulder aisle.
const HIP_M := 0.4
const LOW_TOP_M := 1.0
## Sitting up in bed needs ~0.85 m over the mattress; below 0.6 m you can
## only lie down (a typical van platform bed under a stock roof).
const SIT_UP_M := 0.6
## Standing to shower: a 1.75 m adult needs ~1.85 m.
const SHOWER_STAND_M := 1.85
## Headroom: under STAND_M most adults stoop (a warning); under CROUCH_M it
## is a crawl-in (a note — a teardrop or a low-roof van is built that way on
## purpose). Trailers are held to the same bars. 1.85 m is a stock school
## bus's 6' 2" inside, which a 1.75 m adult stands under; a bar at 1.9 would
## flag every unraised skoolie.
const STAND_M := 1.85
const CROUCH_M := 1.5
## A bed shorter than this leaves most adults curled up (a 1.75 m adult
## stretched out needs ~1.85 m).
const BED_MIN_M := 1.85
## The cab walk-through: the strip between the front seats a person steps
## through into the living box, as wide as an aisle.
const CAB_WALK_M := 0.6
## Water on board per sleeper per day, the camp's own planning rate
## (CampProvisioning: 50 L); under WATER_DAYS_NOTE days it is noted, under
## one day it is a warning.
const WATER_DAYS_NOTE := 3.0

## The palette, grouped as the designer shows it.
const GROUPS := [
	["Sleep", ["bed", "bunk", "cabover_bed"]],
	["Sit & eat", ["dinette", "bench", "sofa", "table"]],
	["Kitchen & bath", ["galley", "fridge", "shower", "toilet", "shoilet"]],
	["Storage & work", ["cabinet", "cubby", "workbench"]],
	["Power & water", ["battery", "inverter", "shore_inlet", "water_tank", "grey_tank", "black_tank",
		"water_heater", "propane", "heater"]],
	["Fittings", ["wall", "light", "monitor", "mirror"]],
]

## Elements a person has to reach (the access check), and those that block
## the floor (a ceiling light or a cubby on the wall does not).
const NEEDS_ACCESS := ["bed", "bunk", "dinette", "bench", "sofa", "galley", "fridge",
	"shower", "toilet", "shoilet", "workbench"]
## Things carried in whole: they have to fit through a door.
const CARRIED_WHOLE := ["fridge", "shower", "shoilet", "water_tank", "grey_tank", "black_tank",
	"battery", "water_heater", "propane"]

## The per-type fields of the selected element's card: [key, label, kind,
## min, max, step, unit]. Size and turn are on every card.
const FIELDS := {
	"battery": [["kwh", "Capacity", "float", 0.5, 40.0, 0.1, " kWh"]],
	"water_tank": [["litres", "Holds", "float", 10.0, 800.0, 5.0, " L"]],
	"grey_tank": [["litres", "Holds", "float", 10.0, 800.0, 5.0, " L"]],
	"black_tank": [["litres", "Holds", "float", 10.0, 400.0, 5.0, " L"]],
	"propane": [["lb", "Propane", "float", 20.0, 200.0, 20.0, " lb"]],
	"inverter": [["supply_w", "Rated", "float", 300.0, 6000.0, 100.0, " W"]],
	"heater": [["watts", "Fan draw", "float", 1.0, 200.0, 1.0, " W"]],
	"fridge": [["watts", "Average draw", "float", 1.0, 400.0, 1.0, " W"]],
	"light": [["watts", "Draw", "float", 1.0, 100.0, 1.0, " W"]],
	"monitor": [["watts", "Draw", "float", 1.0, 300.0, 1.0, " W"]],
}


## Every armed tool, in palette order: {id, label, group, element: {type}}.
static func tools() -> Array:
	var out: Array = []
	for g in GROUPS:
		for type in (g as Array)[1]:
			var t := VehicleCatalog.interior_type(str(type))
			if t.is_empty():
				continue
			out.append({"id": str(type), "label": str(t["label"]).split(" (")[0],
				"group": str((g as Array)[0]), "element": {"type": str(type)},
				"tip": str(t["label"])})
	return out


## Where a ray meets the living floor (or the plane at `level`):
## {x, z (vehicle-local), zc (from the box's front), inside}. {} when the ray
## runs away from the plane.
static func floor_hit(d: Dictionary, o: Vector3, dir: Vector3, level: float = NAN) -> Dictionary:
	var house: Dictionary = d["house"]
	var y := float(house["floor_y"]) if is_nan(level) else level
	if absf(dir.y) < 1e-5:
		return {}
	var t := (y - o.y) / dir.y
	if t <= 0.0:
		return {}
	var p := o + dir * t
	var hw := float(house["w"]) * 0.5
	var z0 := float(house["z0"])
	var z1 := float(house["z1"])
	var inside := absf(p.x) <= hw + 0.05 and p.z >= z0 - 0.05 and p.z <= z1 + 0.05
	return {"x": p.x, "z": p.z, "zc": p.z - z0, "inside": inside, "t": t}


## The armed template resolved at a floor hit (the ghost the designer draws
## and then places). {} when the hit is outside the living box.
static func candidate(d: Dictionary, template: Dictionary, hit: Dictionary) -> Dictionary:
	if hit.is_empty() or not bool(hit.get("inside", false)):
		return {}
	var ed := template.duplicate(true)
	ed["x"] = snappedf(float(hit["x"]), 0.05)
	ed["z"] = snappedf(float(hit["zc"]), 0.05)
	ed["id"] = ""
	return VehicleDesign.resolve_interior_element(d, ed, 0)


## An element's box, vehicle-local: {centre, size}.
static func box_of(el: Dictionary) -> Dictionary:
	var b0 := float(el["base_y"])
	var b1 := float(el["top_y"])
	return {"centre": Vector3(float(el["x"]), (b0 + b1) * 0.5, float(el["z"])),
		"size": Vector3(float(el["fx"]), maxf(b1 - b0, 0.02), float(el["fz"]))}


## The interior element under a ray: its id, or "". The nearest box wins,
## except that a smaller box inside it (a battery under a bed, a tank in a
## bench) is taken instead, so nested pieces can still be picked, and a
## ceiling piece only when nothing else is hit.
static func pick(d: Dictionary, o: Vector3, dir: Vector3) -> String:
	var hits: Array = []
	for e in d.get("interior", []):
		var el: Dictionary = e
		var bx := box_of(el)
		var size: Vector3 = bx["size"] + Vector3(0.04, 0.04, 0.04)
		var ab := AABB((bx["centre"] as Vector3) - size * 0.5, size)
		var hp: Variant = ab.intersects_ray(o, dir)
		if hp == null:
			continue
		var ceiling := bool(VehicleCatalog.interior_type(str(el["type"])).get("ceiling", false))
		hits.append({"t": ((hp as Vector3) - o).length(), "ab": ab, "id": str(el["id"]), "ceiling": ceiling})
	if hits.is_empty():
		return ""
	hits.sort_custom(func(x, y): return float(x["t"]) < float(y["t"]))
	# Looking in with the skin off is looking through the ceiling: a ceiling
	# light only wins when nothing else is under the pointer.
	var floor_hits := hits.filter(func(h): return not bool(h["ceiling"]))
	if not floor_hits.is_empty():
		hits = floor_hits
	var best: Dictionary = hits[0]
	var outer: AABB = (best["ab"] as AABB).grow(0.05)
	for h in hits:
		var ab2: AABB = h["ab"]
		if h == best:
			continue
		if outer.encloses(ab2) and ab2.get_volume() < (best["ab"] as AABB).get_volume():
			best = h
			outer = ab2.grow(0.05)
	return str(best["id"])


static func element(d: Dictionary, id: String) -> Dictionary:
	for e in d.get("interior", []):
		if str((e as Dictionary)["id"]) == id:
			return e
	return {}


# --- access: a way in to every bed and fixture --------------------------------------

## Does `el` stand on the floor in the way of someone walking?
static func blocks_floor(d: Dictionary, el: Dictionary) -> bool:
	if bool(el.get("cabover", false)):
		return false
	var fy := float((d["house"] as Dictionary)["floor_y"])
	return float(el["base_y"]) < fy + 0.3


## Where people come in, vehicle-local xz points on the floor's edge: the
## side and rear doors, and the cab walk-through — a CAB_WALK_M strip at the
## box's front where the driver steps back between the seats (a van shell,
## a bus, a Class A or a Class C). A step van has no walk-through: its
## curb-side cab door IS its side door (`sliding_step`), an entry on the
## right only.
static func entries(d: Dictionary) -> Array:
	var out: Array = []
	var house: Dictionary = d["house"]
	var hw := float(house["w"]) * 0.5
	var z0 := float(house["z0"])
	var z1 := float(house["z1"])
	for sp in VehicleDesign.door_spans(d):
		var sd: Dictionary = sp
		if str(sd["where"]) == "side":
			var a := clampf(float(sd["z0"]), z0, z1)
			var b := clampf(float(sd["z1"]), z0, z1)
			if b - a < 0.3:
				continue
			out.append({"where": "side", "a": Vector2(hw, a), "b": Vector2(hw, b)})
		else:
			out.append({"where": "rear", "a": Vector2(float(sd["x0"]), z1), "b": Vector2(float(sd["x1"]), z1)})
	var body: Dictionary = d["body"]
	var roof := str(body.get("roof", ""))
	var walk_through := bool(d.get("drivable", false)) and (bool(d.get("integral", false)) or roof == "cabover") \
		and str(body.get("side_door", "")) != "sliding_step"
	if walk_through:
		var wx := cab_walk_x(d)
		var half := minf(CAB_WALK_M * 0.5, hw - 0.05)
		out.append({"where": "cab", "a": Vector2(wx - half, z0), "b": Vector2(wx + half, z0)})
	return out


## Where the cab walk-through runs, across (x): between the two front seats
## of a van (the centre line), beside the driver on a bus or a Class A (the
## aisle is on the curb side of the seat).
static func cab_walk_x(d: Dictionary) -> float:
	var style := str((d["cab_geo"] as Dictionary).get("style", ""))
	var hw := float((d["house"] as Dictionary)["w"]) * 0.5
	if style == "full_van" or style == "cutaway":
		return 0.0
	var seat: Vector3 = d.get("driver_seat", Vector3.ZERO)
	return clampf(seat.x + 0.85, -hw + CAB_WALK_M * 0.5, hw - CAB_WALK_M * 0.5)


## The walkway analysis: a grid over the living floor, cells a person fits
## in (AISLE_M clear of the walls and of everything standing on the floor),
## flooded from the entries. {reachable: {id: bool}, entries, cells, walk,
## nx, nz} — `walk` is a PackedByteArray (0 blocked, 1 walkable, 2 reached).
## Cached on the design (`d["access"]`): the checks, the designer's info
## line and the cargo bay all ask, and the flood is the dearest thing in a
## solve.
static func access(d: Dictionary) -> Dictionary:
	if d.has("access"):
		return d["access"]
	var out := _access(d)
	d["access"] = out
	return out


static func _access(d: Dictionary) -> Dictionary:
	var house: Dictionary = d["house"]
	var hw := float(house["w"])
	var z0 := float(house["z0"])
	var hlen := float(house["len"])
	var nx := maxi(int(ceil(hw / CELL_M)), 1)
	var nz := maxi(int(ceil(hlen / CELL_M)), 1)
	var walk := PackedByteArray()
	walk.resize(nx * nz)
	var r := AISLE_M * 0.5
	var obstacles: Array = []
	for e in d.get("interior", []):
		if blocks_floor(d, e as Dictionary):
			obstacles.append(e)
	for iz in nz:
		var z := z0 + (float(iz) + 0.5) * CELL_M
		for ix in nx:
			var x := -hw * 0.5 + (float(ix) + 0.5) * CELL_M
			# Clear of the side walls by half an aisle (a narrow box still
			# counts its middle: a 0.9 m aisle-less box is not "no way in").
			var wall_r := minf(r, hw * 0.5 - 0.05)
			var ok := absf(x) <= hw * 0.5 - wall_r + 1e-4
			if ok:
				for o in obstacles:
					var od: Dictionary = o
					var cr := _clear_r(d, od)
					var dx := absf(x - float(od["x"])) - float(od["fx"]) * 0.5
					var dz := absf(z - float(od["z"])) - float(od["fz"]) * 0.5
					if dx < cr - 1e-4 and dz < cr - 1e-4:
						if Vector2(maxf(dx, 0.0), maxf(dz, 0.0)).length() < cr - 1e-4:
							ok = false
							break
			walk[iz * nx + ix] = 1 if ok else 0
	# (obstacle clearances are per item: see _clear_r)
	# Seeds: walkable cells within reach of each entry.
	var ents := entries(d)
	var queue: Array = []
	for en in ents:
		var a: Vector2 = (en as Dictionary)["a"]
		var b: Vector2 = (en as Dictionary)["b"]
		for iz in nz:
			var z := z0 + (float(iz) + 0.5) * CELL_M
			for ix in nx:
				var k := iz * nx + ix
				if walk[k] != 1:
					continue
				var x := -hw * 0.5 + (float(ix) + 0.5) * CELL_M
				var p := Vector2(x, z)
				# A step in from the doorway: never far enough to jump a wall.
				if _seg_dist(p, a, b) <= r + CELL_M * 2.0:
					walk[k] = 2
					queue.append(k)
	var head := 0
	while head < queue.size():
		var k: int = queue[head]
		head += 1
		var ix := k % nx
		var iz := k / nx
		# Eight neighbours: every cell already carries the walker's clearance,
		# so a diagonal step between two walkable cells is a real one.
		for nb in [[ix - 1, iz], [ix + 1, iz], [ix, iz - 1], [ix, iz + 1],
				[ix - 1, iz - 1], [ix + 1, iz - 1], [ix - 1, iz + 1], [ix + 1, iz + 1]]:
			var jx: int = nb[0]
			var jz: int = nb[1]
			if jx < 0 or jz < 0 or jx >= nx or jz >= nz:
				continue
			var j := jz * nx + jx
			if walk[j] == 1:
				walk[j] = 2
				queue.append(j)
	var reachable := {}
	for e in d.get("interior", []):
		var el: Dictionary = e
		var type := str(el["type"])
		if not NEEDS_ACCESS.has(type):
			continue
		if bool(el.get("cabover", false)):
			reachable[str(el["id"])] = _reached_near(walk, nx, nz, hw, z0, Vector2(0.0, z0 + 0.3), 1.2)
			continue
		var found := false
		var reach := REACH_M + r
		for iz in nz:
			var z := z0 + (float(iz) + 0.5) * CELL_M
			if absf(z - float(el["z"])) > float(el["fz"]) * 0.5 + reach:
				continue
			for ix in nx:
				if walk[iz * nx + ix] != 2:
					continue
				var x := -hw * 0.5 + (float(ix) + 0.5) * CELL_M
				var dx := maxf(absf(x - float(el["x"])) - float(el["fx"]) * 0.5, 0.0)
				var dz := maxf(absf(z - float(el["z"])) - float(el["fz"]) * 0.5, 0.0)
				if Vector2(dx, dz).length() <= reach:
					found = true
					break
			if found:
				break
		reachable[str(el["id"])] = found
	return {"reachable": reachable, "entries": ents.size(), "walk": walk, "nx": nx, "nz": nz,
		"reached": queue.size()}


## Half the clear width someone needs beside `el`: shoulders by tall things,
## hips by low ones.
static func _clear_r(d: Dictionary, el: Dictionary) -> float:
	var fy := float((d["house"] as Dictionary)["floor_y"])
	return HIP_M * 0.5 if float(el["top_y"]) - fy <= LOW_TOP_M else AISLE_M * 0.5


static func _reached_near(walk: PackedByteArray, nx: int, nz: int, hw: float, z0: float,
		p: Vector2, rad: float) -> bool:
	for iz in nz:
		var z := z0 + (float(iz) + 0.5) * CELL_M
		if absf(z - p.y) > rad:
			continue
		for ix in nx:
			if walk[iz * nx + ix] != 2:
				continue
			var x := -hw * 0.5 + (float(ix) + 0.5) * CELL_M
			if Vector2(x, z).distance_to(p) <= rad:
				return true
	return false


static func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 1e-9:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


# --- checks -----------------------------------------------------------------------

## The interior's checks: {level, text, ids?}. VehicleDesign adds them to its own.
static func checks(d: Dictionary) -> Array:
	var c: Array = []
	var els: Array = d.get("interior", [])
	if els.is_empty():
		return c
	var house: Dictionary = d["house"]
	var ceil_y := float(house["ceil_y"])
	var ac := access(d)
	if int(ac["entries"]) == 0:
		c.append({"level": "warn", "text": "No door into the living space: add a side or rear door.",
			"why": "Nobody can get in: the body has no side or rear door and no cab to walk through from."})
	else:
		var reach: Dictionary = ac["reachable"]
		for e in els:
			var el: Dictionary = e
			var id := str(el["id"])
			if reach.has(id) and not bool(reach[id]):
				c.append({"level": "warn", "ids": [id],
					"text": "No way in to the %s from a door: leave a %d cm aisle." %
						[_short(el), int(round(AISLE_M * 100.0))],
					"why": "A person needs a 50 cm aisle (40 cm past low furniture) from a door to reach it; something stands across the way."})
	# A wet bath's toilet flushes into a tank; a composting toilet needs none.
	var has_black := els.any(func(e): return str((e as Dictionary)["type"]) == "black_tank")
	var water_l := float(d.get("water_l", 0.0))
	var grey_l := float(d.get("grey_l", 0.0))
	for e in els:
		var el: Dictionary = e
		var type := str(el["type"])
		if type == "shoilet" and not has_black:
			c.append({"level": "info", "ids": [str(el["id"])],
				"text": "The wet bath's toilet has no black / cassette tank to flush into.",
				"why": "A flush toilet holds its waste in a tank until a dump station; without one the bath is a shower."})
		if (type == "shower" or type == "shoilet") and (water_l <= 0.0 or grey_l <= 0.0):
			var missing := "a fresh-water tank" if water_l <= 0.0 else "a grey tank"
			if water_l <= 0.0 and grey_l <= 0.0:
				missing = "fresh and grey water tanks"
			c.append({"level": "warn", "ids": [str(el["id"])],
				"text": "The %s needs %s." % [_short(el), missing],
				"why": "A shower draws from the fresh tank and drains into the grey tank; with either missing it cannot run."})
		if type == "bed" or type == "bunk" or type == "cabover_bed":
			var long := maxf(float(el["fx"]), float(el["fz"]))
			if long < BED_MIN_M - 1e-6:
				c.append({"level": "warn", "ids": [str(el["id"])],
					"text": "The %s is %.2f m long: under %.2f m most adults can't stretch out." %
						[_short(el), long, BED_MIN_M],
					"why": "A 1.75 m adult lying flat needs about 1.85 m; shorter beds are slept in curled up."})
		if type == "bed" or type == "bunk" or type == "cabover_bed":
			var top := float(el["top_y"])
			var lid := ceil_y
			if type == "cabover_bed":
				lid = float((d["body"] as Dictionary)["h"]) - 0.12
			var room := lid - top
			if room < SIT_UP_M:
				c.append({"level": "info", "ids": [str(el["id"])],
					"text": "Only %d cm over the %s: you can lie in it, not sit up." %
						[maxi(int(round(room * 100.0)), 0), _short(el)]})
		if (type == "shower" or type == "shoilet") and float(house["height"]) < SHOWER_STAND_M:
			c.append({"level": "info", "ids": [str(el["id"])],
				"text": "%.2f m of standing room in the shower." % float(house["height"])})
	# Everybody aboard needs a seat on the road (a trailer's people ride in
	# the tow vehicle).
	var sleeps := int(d.get("sleeps", 0))
	var seats := int(d.get("seats", 0))
	if bool(d.get("drivable", false)) and sleeps > seats:
		c.append({"level": "warn",
			"text": "Sleeps %d but seats %d: %d %s no seat belt on the road." %
				[sleeps, seats, sleeps - seats, "has" if sleeps - seats == 1 else "have"],
			"why": "Everyone riding needs a belted seat; add seats or carry the rest in another vehicle."})
	# Anything that draws power needs a house battery (an EV's pack counts).
	var loads: Array = d.get("house_loads", [])
	var draw := 0.0
	var load_ids: Array = []
	for l in loads:
		draw += float((l as Dictionary).get("watts", 0.0))
		load_ids.append(str((l as Dictionary).get("id", "")))
	if draw > 0.0 and float(d.get("house_battery_kwh", 0.0)) <= 0.0 and float(d.get("battery_kwh", 0.0)) <= 0.0:
		c.append({"level": "warn", "ids": load_ids,
			"text": "%s of loads and no house battery to run them from." % UiText.num(draw, "W"),
			"why": "The fridge and lights run off a house battery; the engine's starter battery is not one."})
	# AC loads (a rooftop AC) need an inverter that carries them, or shore power.
	var ac_w := 0.0
	var ac_ids: Array = []
	for e in d.get("exterior", []):
		var el: Dictionary = e
		var t := VehicleExterior.type_info(str(el["type"]))
		if bool(t.get("ac_load", false)):
			ac_w += float(t.get("load_w", 0.0))
			ac_ids.append(str(el["id"]))
	var inv_w := float(d.get("inverter_w", 0.0))
	if ac_w > 0.0 and inv_w <= 0.0 and float(d.get("shore_w", 0.0)) <= 0.0:
		c.append({"level": "warn", "ids": ac_ids,
			"text": "%s of AC loads and no inverter or shore-power inlet to run them." % UiText.num(ac_w, "W"),
			"why": "A rooftop AC runs on 120 V; off the battery that takes an inverter rated for it."})
	elif ac_w > 0.0 and inv_w > 0.0 and inv_w < ac_w:
		c.append({"level": "warn", "ids": ac_ids,
			"text": "The inverter is rated %s; the AC loads ask for %s." % [UiText.num(inv_w, "W"), UiText.num(ac_w, "W")],
			"why": "An inverter under the load trips off; size it above the biggest AC load's running watts."})
	# Water for the sleepers at the camp's planning rate.
	if sleeps > 0 and water_l > 0.0:
		var lpd := float(CampProvisioning.RATES_PER_PERSON_DAY.get("water", 50.0))
		var days := water_l / (float(sleeps) * lpd)
		if days < 1.0:
			c.append({"level": "warn",
				"text": "%d L of water is %.1f days for %d at %d L a day." % [int(round(water_l)), days, sleeps, int(lpd)],
				"why": "Camp planning counts 50 L a person a day (drinking, cooking, washing); under a day means a daily fill."})
		elif days < WATER_DAYS_NOTE:
			c.append({"level": "info",
				"text": "%d L of water is %.1f days for %d at %d L a day." % [int(round(water_l)), days, sleeps, int(lpd)],
				"why": "Camp planning counts 50 L a person a day; a weekend away wants three."})
	# Carried in whole: the smallest face must pass through the biggest door.
	var door_w := 0.0
	var door_h := 0.0
	for dr in ((d.get("cargo", {}) as Dictionary).get("doors", []) as Array):
		var dd: Dictionary = dr
		if float(dd["w_m"]) * float(dd["h_m"]) > door_w * door_h:
			door_w = float(dd["w_m"])
			door_h = float(dd["h_m"])
	if door_w > 0.0:
		for e in els:
			var el: Dictionary = e
			if not CARRIED_WHOLE.has(str(el["type"])):
				continue
			var dims := [float(el.get("w", el["fx"])), float(el.get("l", el["fz"])), float(el.get("h", 0.5))]
			dims.sort()
			var fits: bool = (dims[0] <= door_w - 0.02 and dims[1] <= door_h - 0.02) \
				or (dims[0] <= door_h - 0.02 and dims[1] <= door_w - 0.02)
			if not fits:
				c.append({"level": "info", "ids": [str(el["id"])],
					"text": "The %s (%.2f × %.2f m) won't pass the %.2f × %.2f m door: it goes in before the walls." %
						[_short(el), dims[0], dims[1], door_w, door_h]})
	return c


static func _short(el: Dictionary) -> String:
	return str(el["label"]).split(" (")[0].to_lower()


## The element's name as a title ("Bed", "Shoilet").
static func label_of(el: Dictionary) -> String:
	return str(el.get("label", el.get("type", ""))).split(" (")[0]


## One line under the selected element: its size, mass and what it gives.
static func info_line(d: Dictionary, el: Dictionary) -> String:
	var t := VehicleCatalog.interior_type(str(el["type"]))
	var bits: Array = ["%.2f × %.2f × %.2f m" % [float(el["fx"]), float(el["fz"]), float(el["top_y"]) - float(el["base_y"])]]
	if float(el.get("mass_kg", t.get("mass_kg", 0.0))) > 0.0:
		bits.append("%.0f kg" % float(el.get("mass_kg", t.get("mass_kg", 0.0))))
	var sleeps := 0
	for b in d.get("beds", []):
		if str((b as Dictionary).get("bed", "")) == str(el["id"]):
			sleeps += 1
	if sleeps > 0:
		bits.append("sleeps %d" % sleeps)
	if el.has("kwh"):
		bits.append(UiText.num(float(el["kwh"]) * 1000.0, "Wh"))
	if el.has("litres"):
		bits.append("%d L" % int(round(float(el["litres"]))))
	if float(el.get("watts", 0.0)) > 0.0:
		bits.append("draws %s" % UiText.num(float(el["watts"]), "W"))
	var reach: Dictionary = (access(d)["reachable"] as Dictionary)
	if reach.has(str(el["id"])) and not bool(reach[str(el["id"])]):
		bits.append("no way in")
	return " · ".join(bits)


# --- the vehicle's systems ----------------------------------------------------------

## What the vehicle's graph node is built from: {battery_kwh, voltage, solar
## [{module, count, watts}], solar_w, loads [{name, watts}], water_l, grey_l}.
## The house bank's voltage follows its size the way conversions are built:
## 12.8 V up to ~3 kWh, 25.6 V to ~8 kWh, 51.2 V beyond.
static func systems(d: Dictionary) -> Dictionary:
	var kwh := float(d.get("house_battery_kwh", 0.0))
	var v := 12.8 if kwh <= 3.0 else (25.6 if kwh <= 8.0 else 51.2)
	var solar: Array = []
	var loads: Array = []
	for e in d.get("exterior", []):
		var el: Dictionary = e
		if str(el["type"]) == "solar":
			var m: Dictionary = VehicleExterior.MODULES[str(el["module"])]
			var n := int(el["rows"]) * int(el["cols"])
			solar.append({"id": str(el["id"]), "module": str(el["module"]), "count": n,
				"watts": float(m["watts"])})
			continue
		var t := VehicleExterior.type_info(str(el["type"]))
		var lw := float(t.get("load_w", 0.0))
		if lw > 0.0:
			loads.append({"id": str(el["id"]), "name": VehicleExterior.label_of(el), "watts": lw})
	for l in d.get("house_loads", []):
		loads.append((l as Dictionary).duplicate())
	# (`shore_w` is a shore-power inlet's rating: the graph's controller type
	# has no AC-in handle yet, so it is reported, not wired.)
	return {"battery_kwh": kwh, "voltage": v, "solar": solar,
		"solar_w": float(d.get("solar_w", 0.0)), "loads": loads,
		"water_l": float(d.get("water_l", 0.0)), "grey_l": float(d.get("grey_l", 0.0)),
		"black_l": float(d.get("black_l", 0.0)), "shore_w": float(d.get("shore_w", 0.0))}
