class_name ConduitBundler
extends RefCounted

## Organised runs. Runs the solver laid on the same line (the same horizontal
## leg, the same height, overlapping by at least MIN_OVERLAP_M) become a
## BUNDLE: each run gets a lane, side by side at a pitch of the widest pipe
## plus GAP_M, as pipes on a wall or cables in a tray are laid. Where a bundle
## turns, every lane bends about the SAME centre (concentric matched bends:
## the inner lane at the bend radius, each lane outside it that much wider).
## A run joining or leaving the bundle steps across with a short jog.
##
## Lanes are ordered by the player's dragged order (`lane_index`), then by
## service (ServicePalette.lane_rank: hot above cold, power apart from data),
## then by connection id, so the result never depends on the order runs were
## built in. A run the player pulled out (`lane_free`) is never bundled. A
## run whose shifted legs would hit something stays where the solver put it
## (flag "unbundled").
##
## Runs are given as their SHARP corners (the solver's), with the first and
## last legs being the port stubs: those never move, so ports stay put.
## Pure static.

const KEY_STEP := 0.1
const MIN_OVERLAP_M := 0.6
const MIN_LEG_M := 0.3
const GAP_M := 0.04
const MAX_LANES := 16
const AXIS_EPS := 0.02
## How many times a run that would collide is dropped and the rest re-laned.
const MAX_PASSES := 3


## runs: [{id, corners: PackedVector3Array, od, bend_r, service, lane_index
## (-1 = automatic), lane_free}]. opts: {field: ConduitObstacleField, gap}.
## -> {id: {corners, radii: PackedFloat64Array (one per corner, 0 = the run's
##    own bend radius), lane, lanes, bundle, flags}} for every run given.
static func bundle(runs: Array, opts: Dictionary = {}) -> Dictionary:
	var gap := float(opts.get("gap", GAP_M))
	var field: ConduitObstacleField = opts.get("field") as ConduitObstacleField
	var dropped := {}
	var out := {}
	for _pass: int in range(MAX_PASSES):
		out = _bundle_once(runs, gap, dropped)
		var newly := false
		if field != null:
			for r: Dictionary in runs:
				var id := str(r["id"])
				var res: Dictionary = out[id]
				if int(res["lanes"]) < 2:
					continue
				if _hits(res["corners"] as PackedVector3Array, r["corners"] as PackedVector3Array,
						float(r.get("od", 0.03)), field):
					dropped[id] = true
					newly = true
		if not newly:
			break
	for id: Variant in dropped:
		if out.has(id):
			(out[id]["flags"] as Dictionary)["unbundled"] = true
	return out


static func _bundle_once(runs: Array, gap: float, dropped: Dictionary) -> Dictionary:
	# 1. Collinear legs, grouped by line.
	var by_line := {}
	for ri: int in range(runs.size()):
		var r: Dictionary = runs[ri]
		if bool(r.get("lane_free", false)) or dropped.has(str(r["id"])):
			continue
		var c: PackedVector3Array = r["corners"]
		for i: int in range(1, c.size() - 2):
			var leg := _leg(c[i], c[i + 1])
			if leg.is_empty():
				continue
			var key := str(leg["key"])
			if not by_line.has(key):
				by_line[key] = []
			leg["run"] = ri
			leg["i"] = i
			(by_line[key] as Array).append(leg)
	# 2. Overlapping stretches on a line: clusters (union-find over legs).
	var clusters: Array = []   # [{legs: [...], runs: {ri: leg}}]
	for key: Variant in by_line:
		var legs: Array = by_line[key]
		legs.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
			return float(x["lo"]) < float(y["lo"]) or (float(x["lo"]) == float(y["lo"])
				and int(x["run"]) < int(y["run"])))
		var cur: Array = []
		var reach := -INF
		for lg: Dictionary in legs:
			if cur.is_empty() or float(lg["lo"]) < reach - MIN_OVERLAP_M:
				cur.append(lg)
				reach = maxf(reach, float(lg["hi"]))
			else:
				clusters.append(cur)
				cur = [lg]
				reach = float(lg["hi"])
		if not cur.is_empty():
			clusters.append(cur)
	var multi: Array = []
	for cl: Array in clusters:
		var seen := {}
		var legs2: Array = []
		for lg: Dictionary in cl:
			if not seen.has(int(lg["run"])):
				seen[int(lg["run"])] = true
				legs2.append(lg)
		if seen.size() >= 2:
			multi.append(legs2)
	# 3. Bundles = runs linked through shared clusters.
	var parent := PackedInt32Array()
	parent.resize(runs.size())
	for i: int in range(runs.size()):
		parent[i] = i
	for cl: Array in multi:
		var r0 := int((cl[0] as Dictionary)["run"])
		for lg: Dictionary in cl:
			_union(parent, r0, int(lg["run"]))
	var members := {}
	for cl: Array in multi:
		for lg: Dictionary in cl:
			var root := _find(parent, int(lg["run"]))
			if not members.has(root):
				members[root] = {}
			(members[root] as Dictionary)[int(lg["run"])] = true
	# 4. Lane order and direction sign per run, within each bundle.
	var slot := {}       # ri -> lane offset (m, in the bundle's frame)
	var sign := {}       # ri -> +1 / -1 against the bundle's reference run
	var lanes_of := {}   # ri -> lane count
	var lane_no := {}    # ri -> lane index
	var bundle_of := {}  # ri -> bundle id (the reference run's id)
	for root: Variant in members:
		var ris: Array = (members[root] as Dictionary).keys()
		ris.sort_custom(func(x: int, y: int) -> bool:
			return _order_key(runs[x]) < _order_key(runs[y]))
		if ris.size() > MAX_LANES:
			ris = ris.slice(0, MAX_LANES)
		var pitch := 0.0
		for ri: int in ris:
			pitch = maxf(pitch, float((runs[ri] as Dictionary).get("od", 0.03)))
		pitch += gap
		var signs := _orient(ris, multi)
		var n := ris.size()
		for k: int in range(n):
			var ri: int = ris[k]
			slot[ri] = (float(k) - float(n - 1) * 0.5) * pitch
			sign[ri] = int(signs.get(ri, 1))
			lanes_of[ri] = n
			lane_no[ri] = k
			bundle_of[ri] = str((runs[ris[0]] as Dictionary)["id"])
	# Which legs of each run are in a bundle (shifted).
	var in_cluster := {}   # "ri|i" -> cluster index
	for ci: int in range(multi.size()):
		for lg: Dictionary in multi[ci]:
			if slot.has(int(lg["run"])):
				in_cluster["%d|%d" % [int(lg["run"]), int(lg["i"])]] = ci
	# 5. Shift each run.
	var out := {}
	var shifted := {}   # ri -> new corners (before radii)
	for ri: int in range(runs.size()):
		var r: Dictionary = runs[ri]
		var id := str(r["id"])
		var c: PackedVector3Array = r["corners"]
		if not slot.has(ri):
			out[id] = {"corners": c, "radii": _zeros(c.size()), "lane": 0, "lanes": 1,
				"bundle": "", "flags": {}}
			continue
		var o := float(slot[ri]) * float(sign[ri])
		var shifts: Array = []
		for i: int in range(c.size() - 1):
			var d := c[i + 1] - c[i]
			if i > 0 and i < c.size() - 2 and in_cluster.has("%d|%d" % [ri, i]):
				var u := d.normalized()
				shifts.append(Vector3(u.z, 0.0, -u.x) * o)
			else:
				shifts.append(null)
		_fill_vertical_shifts(c, shifts)
		var nc := _apply_shifts(c, shifts)
		shifted[ri] = nc
		out[id] = {"corners": nc, "radii": _zeros(nc.size()), "lane": int(lane_no[ri]),
			"lanes": int(lanes_of[ri]), "bundle": str(bundle_of[ri]), "flags": {}}
	# 6. Concentric bends where a bundle turns together.
	_concentric(runs, shifted, out)
	return out


## A horizontal, axis-aligned leg -> {key, axis, lo, hi, dir}, else {}.
static func _leg(a: Vector3, b: Vector3) -> Dictionary:
	var d := b - a
	if absf(d.y) > AXIS_EPS or Vector2(d.x, d.z).length() < MIN_LEG_M:
		return {}
	var axis := ""
	if absf(d.z) <= AXIS_EPS:
		axis = "x"
	elif absf(d.x) <= AXIS_EPS:
		axis = "z"
	else:
		return {}
	var along_a := a.x if axis == "x" else a.z
	var along_b := b.x if axis == "x" else b.z
	var perp := a.z if axis == "x" else a.x
	return {"key": "%s|%d|%d" % [axis, roundi(perp / KEY_STEP), roundi(a.y / KEY_STEP)],
		"axis": axis, "lo": minf(along_a, along_b), "hi": maxf(along_a, along_b),
		"dir": 1 if along_b > along_a else -1}


static func _order_key(r: Dictionary) -> Array:
	var li := int(r.get("lane_index", -1))
	return [li if li >= 0 else 1000, ServicePalette.lane_rank(str(r.get("service", ""))), str(r["id"])]


## Each run's direction against the bundle's first run, carried through the
## shared stretches (a run laid the other way round takes the mirrored slot,
## so it lands on its own lane, not on top of another).
static func _orient(ris: Array, multi: Array) -> Dictionary:
	var sign := {int(ris[0]): 1}
	var set := {}
	for ri: int in ris:
		set[ri] = true
	for _iter: int in range(ris.size()):
		var changed := false
		for cl: Array in multi:
			var known := -1
			var known_dir := 0
			for lg: Dictionary in cl:
				var ri := int(lg["run"])
				if set.has(ri) and sign.has(ri):
					known = ri
					known_dir = int(lg["dir"]) * int(sign[ri])
					break
			if known < 0:
				continue
			for lg: Dictionary in cl:
				var ri := int(lg["run"])
				if set.has(ri) and not sign.has(ri):
					sign[ri] = known_dir * int(lg["dir"])
					changed = true
		if not changed:
			break
	return sign


## A vertical leg (or another unbundled leg between two shifted ones) takes
## the shift that keeps both its corners clean: the two neighbours' shifts
## added when they cross at right angles, else the one before it. The stubs
## (first and last legs) never move.
static func _fill_vertical_shifts(c: PackedVector3Array, shifts: Array) -> void:
	var n := shifts.size()
	for i: int in range(1, n - 1):
		if shifts[i] != null:
			continue
		var d := c[i + 1] - c[i]
		if absf(d.y) <= AXIS_EPS:
			continue
		var prev: Variant = shifts[i - 1]
		var nxt: Variant = shifts[i + 1] if i + 1 < n else null
		var up := c[i] - c[i - 1]
		var un := c[i + 2] - c[i + 1] if i + 2 < c.size() else Vector3.ZERO
		if prev != null and nxt != null:
			var cross := Vector2(up.x, up.z).normalized().dot(Vector2(un.x, un.z).normalized())
			shifts[i] = (prev as Vector3) + (nxt as Vector3) if absf(cross) < 0.1 else prev
		elif prev != null:
			shifts[i] = prev
		elif nxt != null:
			shifts[i] = nxt


## New corners from per-leg shifts: each corner where the two shifted legs
## meet, or a short jog across where they cannot (parallel legs at different
## offsets, a stub meeting a shifted leg end-on).
static func _apply_shifts(c: PackedVector3Array, shifts: Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.append(c[0])
	for i: int in range(1, c.size() - 1):
		var sp: Vector3 = shifts[i - 1] if shifts[i - 1] != null else Vector3.ZERO
		var sq: Vector3 = shifts[i] if shifts[i] != null else Vector3.ZERO
		var up := (c[i] - c[i - 1]).normalized()
		var uq := (c[i + 1] - c[i]).normalized()
		var sol := _meet(sp, up, sq, uq)
		if sol.size() == 1:
			out.append(c[i] + (sol[0] as Vector3))
		else:
			out.append(c[i] + (sol[0] as Vector3))
			out.append(c[i] + (sol[1] as Vector3))
	out.append(c[c.size() - 1])
	return _dedupe(out)


## Where line (sp + a·up) meets line (sq + b·uq): one point, or the two ends
## of a jog between them.
static func _meet(sp: Vector3, up: Vector3, sq: Vector3, uq: Vector3) -> Array:
	if sp.is_equal_approx(sq):
		return [sp]
	var w := sq - sp
	var a11 := up.dot(up)
	var a12 := -up.dot(uq)
	var a22 := uq.dot(uq)
	var b1 := up.dot(w)
	var b2 := -uq.dot(w)
	var det := a11 * a22 - a12 * a12
	if absf(det) > 1e-9:
		var al := (b1 * a22 - a12 * b2) / det
		var be := (a11 * b2 - a12 * b1) / det
		var p := sp + up * al
		var q := sq + uq * be
		if p.distance_to(q) < 1e-3:
			return [p]
	# A jog: along the first leg as far as the second line, then across.
	var p1 := sp + up * up.dot(w)
	var p2 := sq + uq * uq.dot(p1 - sq)
	return [p1, p2]


## Where a bundle turns together, the lanes' bends share one centre: each
## run's radius at that corner is the bundle's base radius plus how far
## outside the inner lane it runs.
static func _concentric(runs: Array, shifted: Dictionary, out: Dictionary) -> void:
	# Group the bundled runs' corners by where they were before shifting.
	var groups := {}
	for ri: Variant in shifted:
		var r: Dictionary = runs[int(ri)]
		var c: PackedVector3Array = r["corners"]
		for i: int in range(2, c.size() - 2):
			var up := (c[i] - c[i - 1]).normalized()
			var uq := (c[i + 1] - c[i]).normalized()
			if absf(up.y) > 0.1 or absf(uq.y) > 0.1 or absf(up.dot(uq)) > 0.1:
				continue
			var key := "%d|%d|%d|%s|%s" % [roundi(c[i].x / KEY_STEP), roundi(c[i].y / KEY_STEP),
				roundi(c[i].z / KEY_STEP), _dkey(up), _dkey(uq)]
			if not groups.has(key):
				groups[key] = []
			(groups[key] as Array).append({"ri": int(ri), "c": c[i], "up": up, "uq": uq})
	for key: Variant in groups:
		var g: Array = groups[key]
		if g.size() < 2:
			continue
		var w := ((g[0] as Dictionary)["uq"] as Vector3) - ((g[0] as Dictionary)["up"] as Vector3)
		var base_r := 0.0
		for e: Dictionary in g:
			base_r = maxf(base_r, float((runs[int(e["ri"])] as Dictionary).get("bend_r", 0.0)))
		# Each run's new corner nearest the old one.
		var depth := {}
		var corner_at := {}
		var dmax := -INF
		for e: Dictionary in g:
			var nc: PackedVector3Array = shifted[int(e["ri"])]
			var best := -1
			var bd := INF
			for j: int in range(1, nc.size() - 1):
				var dd := nc[j].distance_to(e["c"] as Vector3)
				if dd < bd:
					bd = dd
					best = j
			if best < 0:
				continue
			var dv := (nc[best] - (e["c"] as Vector3)).dot(w.normalized())
			depth[int(e["ri"])] = dv
			corner_at[int(e["ri"])] = best
			dmax = maxf(dmax, dv)
		for ri: Variant in depth:
			var id := str((runs[int(ri)] as Dictionary)["id"])
			var radii: PackedFloat64Array = out[id]["radii"]
			radii[int(corner_at[ri])] = base_r + (dmax - float(depth[ri])) / sqrt(2.0)
			out[id]["radii"] = radii


static func _dkey(u: Vector3) -> String:
	return "%d,%d,%d" % [roundi(u.x), roundi(u.y), roundi(u.z)]


## Would the shifted run hit something its unshifted legs did not? An
## obstacle the solver's own path already passes through (a machine an end is
## jammed against, the host of a port) is not counted: the solver chose that.
static func _hits(nc: PackedVector3Array, oc: PackedVector3Array, od: float,
		field: ConduitObstacleField) -> bool:
	var c := od * 0.5 + 0.015
	var already := {}
	for j: int in range(oc.size() - 1):
		var oa := oc[j]
		var ob := oc[j + 1]
		var omn := Vector2(minf(oa.x, ob.x) - c, minf(oa.z, ob.z) - c)
		var omx := Vector2(maxf(oa.x, ob.x) + c, maxf(oa.z, ob.z) + c)
		for e: int in field.query_xz(omn, omx):
			if not already.has(e) and field.segment_blocked(oa, ob, c, PackedInt32Array([e])):
				already[e] = true
	for i: int in range(1, nc.size() - 2):
		var a := nc[i]
		var b := nc[i + 1]
		var moved := true
		for j: int in range(oc.size() - 1):
			if oc[j].distance_to(a) < 1e-4 and oc[j + 1].distance_to(b) < 1e-4:
				moved = false
				break
		if not moved:
			continue
		var mn := Vector2(minf(a.x, b.x) - c, minf(a.z, b.z) - c)
		var mx := Vector2(maxf(a.x, b.x) + c, maxf(a.z, b.z) + c)
		var entries := PackedInt32Array()
		for e: int in field.query_xz(mn, mx):
			if not already.has(e):
				entries.append(e)
		if entries.size() > 0 and field.segment_blocked(a, b, c, entries):
			return true
	return false


static func _zeros(n: int) -> PackedFloat64Array:
	var a := PackedFloat64Array()
	a.resize(n)
	return a


static func _dedupe(pts: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for p: Vector3 in pts:
		if out.is_empty() or out[out.size() - 1].distance_to(p) > 1e-4:
			out.append(p)
	return out


static func _find(parent: PackedInt32Array, i: int) -> int:
	while parent[i] != i:
		parent[i] = parent[parent[i]]
		i = parent[i]
	return i


static func _union(parent: PackedInt32Array, a: int, b: int) -> void:
	var ra := _find(parent, a)
	var rb := _find(parent, b)
	if ra != rb:
		parent[maxi(ra, rb)] = mini(ra, rb)
