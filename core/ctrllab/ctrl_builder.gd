class_name CtrlBuilder
extends Node3D

## Draws a solved controller (CtrlDesign) in its local frame (metres; the
## spec's mm × 0.001): the body lofted from rounded-rectangle rings (front
## view corner radius, rounded front edges), a two-tone split, a front plate
## over a smaller shell, coloured bands, raised panels, the heatsink (back
## plate with fins, or fins all over a car-style extrusion), mounts, vents,
## the wiring bay (recess, back plate, cover with an optional window), every
## port from the shared connector kit, and printed text as Label3Ds.
##
## Nodes: "Mesh" (body), "BayCover", "Window", "Ports", "Labels",
## "CollisionMesh" (hidden). Meta "parts": [{id, kind, label, aabb}] for
## pick(). Every triangle goes through BattParts (wound to its normal).

const MODEL_ID := "ctrllab_unit"
const MM := 0.001
const SEG := 6        ## arc segments per rounded corner
const EDGE_SLICES := 4

var design: Dictionary = {}
var parts: Array = []


static func build_node(spec: Dictionary, node_name: String = "Controller") -> CtrlBuilder:
	var b := build_from_design(CtrlDesign.solve(spec))
	b.name = node_name
	return b


static func build_from_design(d: Dictionary, opts: Dictionary = {}) -> CtrlBuilder:
	var b := CtrlBuilder.new()
	b.design = d
	b._build(opts)
	return b


func _build(opts: Dictionary) -> void:
	var d := design
	var s: Dictionary = d["spec"]
	var g := BattParts.Geo.new()
	parts = []
	_body(g, d, s)
	_heatsink(g, d, s)
	_mounts(g, d, s)
	_vents(g, d, s)
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = g.commit()
	add_child(mi)
	# Bay cover and its window.
	if bool(s["bay"]["on"]) and d["faces"].has("bay"):
		var cg := BattParts.Geo.new()
		var win := _bay_cover(cg, d, s)
		var cv := MeshInstance3D.new()
		cv.name = "BayCover"
		cv.mesh = cg.commit()
		add_child(cv)
		if not win.is_empty():
			var wm := MeshInstance3D.new()
			wm.name = "Window"
			wm.mesh = _window_mesh(win)
			add_child(wm)
		parts.append({"id": "bay_cover", "kind": "cover", "label": "Wiring bay cover", "aabb": _bay_cover_aabb(d)})
		set_cover_visible(bool(opts.get("cover", s["bay"]["cover"]["show"])))
	# Ports and their printed marks.
	var pg := BattParts.Geo.new()
	var labels := Node3D.new()
	labels.name = "Labels"
	add_child(labels)
	for p in (d["ports"] as Array):
		var sp := _spec_port(s, str(p["id"]))
		var r := ConnectorParts.build(pg, str(p["connector"]), p["xf"], sp.get("opts", {}))
		for lb in (r["labels"] as Array):
			_label_from(labels, lb)
		var e: Dictionary = p["entry"]
		var bx: Vector3 = e["body"]
		var lab := str(p["label"]) if str(p["label"]) != "" else str(e["label"])
		parts.append({"id": str(p["id"]), "kind": "port", "label": lab,
			"aabb": _xf_aabb(p["xf"], AABB(Vector3(-bx.x * 0.5, -bx.y * 0.5, -2.0), Vector3(bx.x, bx.y, bx.z + 2.0)))})
	if not pg.is_empty():
		var pm := MeshInstance3D.new()
		pm.name = "Ports"
		pm.mesh = pg.commit()
		add_child(pm)
	for t in (s["texts"] as Array):
		_text(labels, d, t)
	parts.append({"id": "body", "kind": "body", "label": str(s["name"]), "aabb": _mm_aabb(CtrlDesign.bounds(d))})
	# Collision: the whole unit as one box.
	var col := MeshInstance3D.new()
	col.name = "CollisionMesh"
	var bm := BoxMesh.new()
	var ab := CtrlDesign.bounds(d)
	bm.size = ab.size * MM
	col.mesh = bm
	col.position = ab.get_center() * MM
	col.visible = false
	add_child(col)
	set_meta("parts", parts)
	set_meta("controller_spec", s)


# ---------------------------------------------------------------------------
# Body
# ---------------------------------------------------------------------------

## A rounded rectangle as points with outward 2D normals, CCW from +Z,
## always SEG + 1 points a corner (so rings of any radius line up).
static func _rr(w: float, h: float, r: float, cx: float, cy: float) -> Array:
	var rr := clampf(r, 0.0, minf(w, h) * 0.5)
	var out: Array = []
	var cs := [Vector2(w * 0.5 - rr, -h * 0.5 + rr), Vector2(w * 0.5 - rr, h * 0.5 - rr),
		Vector2(-w * 0.5 + rr, h * 0.5 - rr), Vector2(-w * 0.5 + rr, -h * 0.5 + rr)]
	for k in 4:
		var a0 := -PI * 0.5 + PI * 0.5 * float(k)
		for sgi in SEG + 1:
			var a := a0 + PI * 0.5 * float(sgi) / float(SEG)
			var n2 := Vector2(cos(a), sin(a))
			out.append([Vector2(cx, cy) + cs[k] + n2 * rr, n2])
	return out


## Points where the ring crosses y = yc inserted (normal of the edge).
static func _insert_y(ring: Array, yc: float) -> Array:
	var out: Array = []
	var n := ring.size()
	for i in n:
		var a: Array = ring[i]
		var b: Array = ring[(i + 1) % n]
		out.append(a)
		var pa: Vector2 = a[0]
		var pb: Vector2 = b[0]
		if (pa.y - yc) * (pb.y - yc) < 0.0:
			var t := (yc - pa.y) / (pb.y - pa.y)
			out.append([pa.lerp(pb, t), ((a[1] as Vector2) + (b[1] as Vector2)).normalized()])
	return out


## The ring above y = yc. The cut edge gets its own points facing down
## (−Y), so the underside it makes is lit as an underside.
static func _clip_above(ring: Array, yc: float) -> Array:
	var r2 := _insert_y(ring, yc).filter(func(q): return (q[0] as Vector2).y >= yc - 0.001)
	var out: Array = []
	var n := r2.size()
	for i in n:
		var a: Array = r2[i]
		var b: Array = r2[(i + 1) % n]
		out.append(a)
		if absf((a[0] as Vector2).y - yc) < 0.002 and absf((b[0] as Vector2).y - yc) < 0.002:
			out.append([a[0], Vector2.DOWN])
			out.append([b[0], Vector2.DOWN])
	return out


## Rings: [{pts, z, th}] (th = how far the surface has turned toward +Z).
## Sides between rings; a cap behind the first and in front of the last.
static func _loft(g: BattParts.Geo, rings: Array, colfn: Callable, fin: String, cap_back: bool, cap_front: bool,
		split_y: float = NAN) -> void:
	for i in rings.size() - 1:
		var ra: Array = rings[i]["pts"]
		var rb: Array = rings[i + 1]["pts"]
		var za := float(rings[i]["z"])
		var zb := float(rings[i + 1]["z"])
		var tha := float(rings[i]["th"])
		var thb := float(rings[i + 1]["th"])
		var n := mini(ra.size(), rb.size())
		for k in n:
			var k1 := (k + 1) % n
			var a0: Vector2 = ra[k][0]
			var a1: Vector2 = ra[k1][0]
			var b0: Vector2 = rb[k][0]
			var b1: Vector2 = rb[k1][0]
			var p0 := Vector3(a0.x, a0.y, za)
			var p1 := Vector3(a1.x, a1.y, za)
			var q1 := Vector3(b1.x, b1.y, zb)
			var q0 := Vector3(b0.x, b0.y, zb)
			if (p1 - p0).length() < 1e-4 and (q1 - q0).length() < 1e-4:
				continue
			var na0 := _nrm(ra[k][1], tha)
			var na1 := _nrm(ra[k1][1], tha)
			var nb1 := _nrm(rb[k1][1], thb)
			var nb0 := _nrm(rb[k][1], thb)
			var col: Color = colfn.call((a0.y + a1.y + b0.y + b1.y) * 0.25)
			g.quad(fin, col, p0, p1, q1, q0, na0, na1, nb1, nb0)
	if cap_back:
		_cap(g, rings[0]["pts"], float(rings[0]["z"]), Vector3.FORWARD, colfn, fin, split_y)
	if cap_front:
		_cap(g, rings[-1]["pts"], float(rings[-1]["z"]), Vector3.BACK, colfn, fin, split_y)


static func _nrm(n2: Vector2, th: float) -> Vector3:
	return Vector3(n2.x * cos(th), n2.y * cos(th), sin(th)).normalized()


## A flat convex cap at z facing `fn`, split in two colours along y.
static func _cap(g: BattParts.Geo, pts: Array, z: float, fn: Vector3, colfn: Callable, fin: String, split_y: float) -> void:
	var polys: Array = []
	if is_nan(split_y):
		polys.append(pts.map(func(q): return q[0]))
	else:
		var r2 := _insert_y(pts, split_y)
		polys.append(r2.filter(func(q): return (q[0] as Vector2).y <= split_y + 0.001).map(func(q): return q[0]))
		polys.append(r2.filter(func(q): return (q[0] as Vector2).y >= split_y - 0.001).map(func(q): return q[0]))
	for poly in polys:
		if (poly as Array).size() < 3:
			continue
		var c := Vector2.ZERO
		for q in poly:
			c += q as Vector2
		c /= float((poly as Array).size())
		var col: Color = colfn.call(c.y)
		var m := (poly as Array).size()
		for i in m:
			var a: Vector2 = poly[i]
			var b: Vector2 = poly[(i + 1) % m]
			if (b - a).length() < 1e-5:
				continue
			g.tri(fin, col, Vector3(c.x, c.y, z), Vector3(a.x, a.y, z), Vector3(b.x, b.y, z), fn, fn, fn, fn)


## Rings for an outline from z_a to z_b, the front edge rounded by e.
static func _rings(w: float, h: float, r: float, cy: float, z_a: float, z_b: float, e: float, clip_y: float = NAN) -> Array:
	var rings: Array = []
	var e2 := clampf(e, 0.0, (z_b - z_a) * 0.95)
	var mk := func(ins: float, z: float, th: float) -> Dictionary:
		var pts := _rr(w - 2.0 * ins, h - 2.0 * ins, maxf(r - ins, 0.0), 0.0, cy)
		if not is_nan(clip_y):
			pts = _clip_above(pts, clip_y)
		return {"pts": pts, "z": z, "th": th}
	rings.append(mk.call(0.0, z_a, 0.0))
	if e2 < 0.01:
		rings.append(mk.call(0.0, z_b, 0.0))
		return rings
	rings.append(mk.call(0.0, z_b - e2, 0.0))
	for k in range(1, EDGE_SLICES + 1):
		var th := PI * 0.5 * float(k) / float(EDGE_SLICES)
		rings.append(mk.call(e2 * (1.0 - cos(th)), z_b - e2 + e2 * sin(th), th))
	return rings


func _body(g: BattParts.Geo, d: Dictionary, s: Dictionary) -> void:
	var b: Dictionary = s["body"]
	var w := float(d["w"])
	var h := float(d["h"])
	var y0 := float(d["y0"])
	var z0 := float(d["z0"])
	var zf := float(d["zf"])
	var r := float(b["corner_r"])
	var e := float(b["edge_r"])
	var cy := y0 + h * 0.5
	var fin := _finish(str(b["finish"]))
	var body_col := CtrlSpec.color_of(b["color"])
	var sp: Dictionary = b["split"]
	var split_y := y0 + float(sp["y"]) if float(sp["y"]) > 0.0 else NAN
	if not is_nan(split_y) and (split_y <= y0 + r + 0.5 or split_y >= y0 + h - r - 0.5):
		split_y = NAN
	var low_col := CtrlSpec.color_of(sp["color"], body_col)
	var colfn := func(y: float) -> Color:
		return low_col if not is_nan(split_y) and y < split_y else body_col
	var caps: Dictionary = s["caps"]
	var cap_t := float(caps["t"])
	var plate: Dictionary = b["plate"]
	var bay: Dictionary = s["bay"]
	var bay_on: bool = bool(bay["on"]) and (d["faces"] as Dictionary).has("bay")
	if cap_t > 0.0:
		# Car style: an extruded body between two end caps a little bigger.
		var cap_col := CtrlSpec.color_of(caps["color"])
		var grow := 3.0
		if str(s["heatsink"]["where"]) == "full":
			grow = float(s["heatsink"]["fin_d"]) * 0.6
		var capfn := func(_y: float) -> Color:
			return cap_col
		_loft(g, _rings(w, h, r, cy, z0 + cap_t, zf - cap_t, 0.0), colfn, fin, false, false)
		_loft(g, _rings(w + grow * 2.0, h + grow * 2.0, r + grow, cy, z0, z0 + cap_t, 0.0), capfn, "plastic", true, true)
		_loft(g, _rings(w + grow * 2.0, h + grow * 2.0, r + grow, cy, zf - cap_t, zf, e), capfn, "plastic", true, true)
		return
	if bool(plate["on"]):
		var ins := float(plate["inset"])
		var pt := clampf(float(plate["t"]), 1.0, (zf - z0) * 0.5)
		var pr := float(plate["corner_r"]) if float(plate["corner_r"]) >= 0.0 else r
		_loft(g, _rings(w - 2.0 * ins, h - 2.0 * ins, maxf(pr - ins, 2.0), cy, z0, zf - pt, 0.0), colfn, fin, true, true, split_y)
		var pcol := CtrlSpec.color_of(plate["color"])
		var pfn := func(_y: float) -> Color:
			return pcol
		_loft(g, _rings(w, h, pr, cy, zf - pt, zf, minf(e, pt * 0.8)), pfn, fin, true, true)
	elif bay_on:
		var f: Dictionary = d["faces"]["bay"]
		var depth := float(f["depth"])
		var zb := zf - depth
		var ycut := y0 + float(f["y1"])
		var wall := float(bay["wall"])
		var bay_col := CtrlSpec.color_of(bay["color"])
		# Behind the bay: the full outline; its front cap is the bay's back plate.
		_loft(g, _rings(w, h, r, cy, z0, zb, 0.0), colfn, fin, true, false, split_y)
		var platefn := func(y: float) -> Color:
			return bay_col if y < ycut else colfn.call(y)
		_cap(g, _rr(w, h, r, 0.0, cy), zb, Vector3.BACK, platefn, fin, ycut)
		# Above the bay: rounded front, its underside the bay's ceiling.
		_loft(g, _rings(w, h, r, cy, zb, zf, e, ycut), colfn, fin, false, true, split_y)
		# The walls beside and under the bay.
		var outline := PackedVector2Array(_rr(w, h, r, 0.0, cy).map(func(q): return q[0]))
		var rects := [Rect2(-w * 0.5, y0, wall, ycut - y0), Rect2(w * 0.5 - wall, y0, wall, ycut - y0),
			Rect2(-w * 0.5 + wall, y0, w - 2.0 * wall, wall)]
		for rc in rects:
			var rp := PackedVector2Array([rc.position, rc.position + Vector2(rc.size.x, 0), rc.end,
				rc.position + Vector2(0, rc.size.y)])
			for poly in Geometry2D.intersect_polygons(outline, rp):
				var arr: Array = Array(poly)
				if arr.size() < 3:
					continue
				if _signed_area(arr) < 0.0:
					arr.reverse()
				var c := Vector2.ZERO
				for q in arr:
					c += q
				c /= float(arr.size())
				BattParts.prism(g, Vector3(0, 0, zb), Vector3.RIGHT, Vector3.UP, Vector3.BACK, arr, depth, colfn.call(c.y), fin)
	else:
		_loft(g, _rings(w, h, r, cy, z0, zf, e), colfn, fin, true, true, split_y)
	_bands(g, d, s)
	_panels(g, d, s)


static func _signed_area(pts: Array) -> float:
	var a := 0.0
	for i in pts.size():
		var p: Vector2 = pts[i]
		var q: Vector2 = pts[(i + 1) % pts.size()]
		a += p.x * q.y - q.x * p.y
	return a * 0.5


static func _finish(f: String) -> String:
	match f:
		"alu":
			return "tin"
		"plastic":
			return "plastic"
	return "plastic"


## Coloured bands across the front (an orange stripe, a green line).
func _bands(g: BattParts.Geo, d: Dictionary, s: Dictionary) -> void:
	var b: Dictionary = s["body"]
	var w := float(d["w"])
	var h := float(d["h"])
	var y0 := float(d["y0"])
	var e := float(b["edge_r"])
	var r := float(b["corner_r"])
	var front := PackedVector2Array(_rr(w - 2.0 * e, h - 2.0 * e, maxf(r - e, 0.0), 0.0, y0 + h * 0.5).map(func(q): return q[0]))
	for bd in (s["bands"] as Array):
		var xi := float(bd.get("x_inset", 0.0))
		var ya := y0 + float(bd.get("y0", 0.0))
		var yb := y0 + float(bd.get("y1", 0.0))
		var rp := PackedVector2Array([Vector2(-w * 0.5 + xi, ya), Vector2(w * 0.5 - xi, ya), Vector2(w * 0.5 - xi, yb),
			Vector2(-w * 0.5 + xi, yb)])
		for poly in Geometry2D.intersect_polygons(front, rp):
			var arr: Array = Array(poly)
			if arr.size() < 3:
				continue
			if _signed_area(arr) < 0.0:
				arr.reverse()
			BattParts.prism(g, Vector3(0, 0, float(d["zf"])), Vector3.RIGHT, Vector3.UP, Vector3.BACK, arr,
				float(bd.get("t", 0.5)), CtrlSpec.color_of(bd.get("color", [0.9, 0.4, 0.1])), "plastic")


## Raised panels on the front (front-face coordinates).
func _panels(g: BattParts.Geo, d: Dictionary, s: Dictionary) -> void:
	var f: Dictionary = d["faces"]["front"]
	var cy := (f["c"] as Vector3).y
	var zf := float(d["zf"])
	var body_col := CtrlSpec.color_of(s["body"]["color"])
	for pn in (s["panels"] as Array):
		var x0 := float(pn.get("x0", -20.0))
		var x1 := float(pn.get("x1", 20.0))
		var ya := float(pn.get("y0", -20.0))
		var yb := float(pn.get("y1", 20.0))
		var raise := float(pn.get("raise", 3.0))
		var col := CtrlSpec.color_of(pn.get("color", [-1.0, 0, 0]), body_col)
		var pfn := func(_y: float) -> Color:
			return col
		var rings := _rings(x1 - x0, yb - ya, float(pn.get("r", 4.0)), 0.0, zf, zf + raise, minf(float(pn.get("e", 2.0)), raise * 0.9))
		for ring in rings:
			for q in (ring["pts"] as Array):
				q[0] = (q[0] as Vector2) + Vector2((x0 + x1) * 0.5, cy + (ya + yb) * 0.5)
		_loft(g, rings, pfn, _finish(str(s["body"]["finish"])), false, true)


# ---------------------------------------------------------------------------
# Heatsink, mounts, vents
# ---------------------------------------------------------------------------

func _heatsink(g: BattParts.Geo, d: Dictionary, s: Dictionary) -> void:
	var hs: Dictionary = s["heatsink"]
	var where := str(hs["where"])
	if where == "none":
		return
	var col := CtrlSpec.color_of(hs["color"])
	var w := float(d["w"])
	var h := float(d["h"])
	var y0 := float(d["y0"])
	var n := maxi(int(hs["fins"]), 1)
	var fd := float(hs["fin_d"])
	var ft := float(hs["fin_t"])
	match where:
		"back":
			var ex := float(hs["extra_w"])
			var bw := w + 2.0 * ex
			var bt := float(hs["base_t"])
			var marg := minf(float(s["body"]["corner_r"]), h * 0.1)
			BattParts.abox(g, Vector3(0, y0 + h * 0.5, fd + bt * 0.5), Vector3(bw, h - marg * 0.5, bt), col, "tin")
			for i in n:
				var x := -bw * 0.5 + ft * 0.5 + (bw - ft) * float(i) / float(maxi(n - 1, 1))
				BattParts.abox(g, Vector3(x, y0 + h * 0.5, fd * 0.5), Vector3(ft, h - marg, fd), col, "tin")
			if ex > 6.0:
				# The wings stick out past the body: fins seen from the front, slots to screw through.
				for sg in [-1.0, 1.0]:
					var xw: float = sg * (w * 0.5 + ex * 0.5)
					var rows := maxi(int((h - marg) / 9.0), 2)
					for k in rows:
						var y := y0 + marg * 0.5 + 4.5 + (h - marg - 9.0) * float(k) / float(rows - 1)
						BattParts.abox(g, Vector3(xw, y, fd + bt + 1.0), Vector3(ex - 2.0, 2.4, 2.0), col.darkened(0.15), "tin")
					if bool(hs["slots"]):
						for yy in [y0 + h * 0.12, y0 + h * 0.88]:
							BattParts.abox(g, Vector3(xw, yy, fd + bt + 2.1), Vector3(ex * 0.45, 9.0, 0.2), Color(0.01, 0.01, 0.012), "rubber")
		"full", "top", "sides":
			var cap_t := float(s["caps"]["t"])
			var za := float(d["z0"]) + cap_t
			var zb := float(d["zf"]) - cap_t
			var zl := zb - za
			var zc := (za + zb) * 0.5
			if where != "sides":
				for i in n:
					var x2 := -w * 0.45 + w * 0.9 * float(i) / float(maxi(n - 1, 1))
					BattParts.abox(g, Vector3(x2, y0 + h + fd * 0.5, zc), Vector3(ft, fd, zl), col, "tin")
			if where != "top":
				var rows2 := maxi(int(h / 12.0), 2)
				for sg in [-1.0, 1.0]:
					for k in rows2:
						var y2 := y0 + h * 0.12 + h * 0.76 * float(k) / float(rows2 - 1)
						BattParts.abox(g, Vector3(sg * (w * 0.5 + fd * 0.3), y2, zc), Vector3(fd * 0.6, ft, zl), col, "tin")


func _mounts(g: BattParts.Geo, d: Dictionary, s: Dictionary) -> void:
	var m: Dictionary = s["mount"]
	var style := str(m["style"])
	if style == "none":
		return
	var w := float(d["w"])
	var h := float(d["h"])
	var y0 := float(d["y0"])
	var z0 := float(d["z0"])
	var zf := float(d["zf"])
	var mw := float(m["w"])
	var mh := float(m["h"])
	var base := CtrlSpec.color_of(s["body"]["color"])
	if str(s["heatsink"]["where"]) == "back":
		base = CtrlSpec.color_of(s["heatsink"]["color"])
	var col := CtrlSpec.color_of(m["color"], base)
	var hole := Color(0.01, 0.01, 0.012)
	match style:
		"tabs":
			var n := maxi(int(m["n"]), 1)
			var xs: Array = []
			for i in n:
				xs.append(0.0 if n == 1 else lerpf(-w * 0.5 + mw * 0.5 + 8.0, w * 0.5 - mw * 0.5 - 8.0, float(i) / float(n - 1)))
			var where := str(m["where"])
			for x in xs:
				if where in ["top", "both"]:
					BattParts.abox(g, Vector3(x, y0 + h + mh * 0.5 - 3.0, 1.25), Vector3(mw, mh + 6.0, 2.5), col, "tin")
					BattParts.disc(g, Vector3(x, y0 + h + mh * 0.5, 2.55), Vector3.BACK, minf(mw, mh) * 0.18, 0.1, hole, "rubber", 12)
				if where in ["bottom", "both"]:
					BattParts.abox(g, Vector3(x, y0 - mh * 0.5 + 3.0, 1.25), Vector3(mw, mh + 6.0, 2.5), col, "tin")
					BattParts.disc(g, Vector3(x, y0 - mh * 0.5, 2.55), Vector3.BACK, minf(mw, mh) * 0.18, 0.1, hole, "rubber", 12)
		"flange":
			# A sheet-metal mounting plate a rim wider than the body, with the
			# body's own corner radius and a slot at each corner (the Phoenix /
			# Orion back plate), never a bare rectangle.
			var pr := float(s["body"]["corner_r"]) + mh
			var pfn := func(_y: float) -> Color:
				return col
			# Behind the body (the body's own back cap sits at z0; a plate
			# sharing that plane z-fought it into an X of seams).
			_loft(g, _rings(w + 2.0 * mh, h + 2.0 * mh, pr, y0 + h * 0.5, z0 - 2.5, z0, 0.0), pfn, "tin", true, true)
			for sx in [-1.0, 1.0]:
				for sy in [-1.0, 1.0]:
					var hx: float = sx * (w * 0.5 + mh * 0.45)
					var hy: float = y0 + h * 0.5 + sy * (h * 0.5 - mh * 0.6)
					BattParts.abox(g, Vector3(hx, hy, z0 - 2.55), Vector3(minf(mh * 0.5, 5.0), minf(mh * 1.1, 11.0), 0.1), hole, "rubber")
		"side_feet":
			for sx in [-1.0, 1.0]:
				BattParts.abox(g, Vector3(sx * (w * 0.5 + 1.5), y0 + mh * 0.5, (z0 + zf) * 0.5), Vector3(3.0, mh, zf - z0), col, "plastic")
				BattParts.abox(g, Vector3(sx * (w * 0.5 + mw * 0.5), y0 + 1.5, (z0 + zf) * 0.5), Vector3(mw, 3.0, zf - z0), col, "plastic")
				for zz in [z0 + (zf - z0) * 0.25, z0 + (zf - z0) * 0.75]:
					BattParts.disc(g, Vector3(sx * (w * 0.5 + mw * 0.6), y0 + 3.05, zz), Vector3.UP, 3.5, 0.1, hole, "rubber", 12)
		"bracket":
			BattParts.abox(g, Vector3(0, y0 + h * 0.8, 2.0), Vector3(w * 0.8, h * 0.18, 4.0), Color(0.3, 0.31, 0.33), "tin")
		"feet":
			for sx in [-1.0, 1.0]:
				for sz in [0.15, 0.85]:
					BattParts.disc(g, Vector3(sx * (w * 0.5 - 18.0), 0.0, z0 + (zf - z0) * sz), Vector3.UP, 9.0, y0,
						Color(0.06, 0.06, 0.06), "rubber", 14)
		"ears":
			for sx in [-1.0, 1.0]:
				BattParts.abox(g, Vector3(sx * (w * 0.5 + mw * 0.5), y0 + 1.25, (z0 + zf) * 0.5), Vector3(mw + 4.0, 2.5, (zf - z0) * 0.6), col, "tin")
				for zz in [z0 + (zf - z0) * 0.3, z0 + (zf - z0) * 0.7]:
					BattParts.abox(g, Vector3(sx * (w * 0.5 + mw * 0.55), y0 + 2.55, zz), Vector3(mw * 0.35, 0.1, 10.0), hole, "rubber")
		"handles":
			for sz in [z0 + mw * 0.6, zf - mw * 0.6]:
				for sx in [-1.0, 1.0]:
					BattParts.abox(g, Vector3(sx * w * 0.32, y0 + h + mh * 0.5, sz), Vector3(14.0, mh, 20.0), col, "plastic")
				BattParts.abox(g, Vector3(0, y0 + h + mh - 6.0, sz), Vector3(w * 0.64 + 14.0, 12.0, 22.0), col, "plastic")


func _vents(g: BattParts.Geo, d: Dictionary, s: Dictionary) -> void:
	for v in (s["vents"] as Array):
		var face := str(v.get("face", "left"))
		if not d["faces"].has(face):
			continue
		var k := ConnectorParts.K.new(g, d["faces"][face]["xf"])
		var n := maxi(int(v.get("n", 6)), 1)
		var vw := float(v.get("w", 40.0))
		var vh := float(v.get("h", 40.0))
		var cu := float(v.get("u", 0.0))
		var cv := float(v.get("v", 0.0))
		var horiz := str(v.get("dir", "h")) == "h"
		for i in n:
			var t := (float(i) + 0.5) / float(n) - 0.5
			if horiz:
				k.hole_rect(Vector2(cu, cv + t * vh), Vector2(vw, vh / float(n) * 0.5), 0.0)
			else:
				k.hole_rect(Vector2(cu + t * vw, cv), Vector2(vw / float(n) * 0.5, vh), 0.0)


# ---------------------------------------------------------------------------
# Wiring bay cover
# ---------------------------------------------------------------------------

## The cover over the bay; returns the window rect in the cover (unit
## coordinates, mm: {x0, x1, y0, y1, z}) or {} with no window.
func _bay_cover(g: BattParts.Geo, d: Dictionary, s: Dictionary) -> Dictionary:
	var bay: Dictionary = s["bay"]
	var f: Dictionary = d["faces"]["bay"]
	var c: Vector3 = f["c"]
	var size: Vector2 = f["size"]
	var zf := float(d["zf"])
	var sp: Dictionary = s["body"]["split"]
	var under := CtrlSpec.color_of(sp["color"], CtrlSpec.color_of(s["body"]["color"])) \
		if float(sp["y"]) > float(f["y1"]) else CtrlSpec.color_of(s["body"]["color"])
	var col := CtrlSpec.color_of(bay["cover"]["color"], under)
	var x0 := -size.x * 0.5
	var x1 := size.x * 0.5
	var ya := c.y - size.y * 0.5
	var yb := c.y + size.y * 0.5
	var zc := zf - 1.0
	var win: Dictionary = bay["cover"]["window"]
	var out := {}
	if bool(win["on"]) and float(win["x1"]) > float(win["x0"]) and float(win["y1"]) > float(win["y0"]):
		var wx0 := clampf(float(win["x0"]), x0 + 2.0, x1 - 2.0)
		var wx1 := clampf(float(win["x1"]), wx0, x1 - 2.0)
		var wy0 := clampf(c.y + float(win["y0"]), ya + 2.0, yb - 2.0)
		var wy1 := clampf(c.y + float(win["y1"]), wy0, yb - 2.0)
		for rc in [Rect2(x0, ya, x1 - x0, wy0 - ya), Rect2(x0, wy1, x1 - x0, yb - wy1),
				Rect2(x0, wy0, wx0 - x0, wy1 - wy0), Rect2(wx1, wy0, x1 - wx1, wy1 - wy0)]:
			if rc.size.x > 0.1 and rc.size.y > 0.1:
				BattParts.abox(g, Vector3(rc.get_center().x, rc.get_center().y, zc), Vector3(rc.size.x, rc.size.y, 2.0), col, "plastic")
		out = {"x0": wx0, "x1": wx1, "y0": wy0, "y1": wy1, "z": zf - 0.5}
	else:
		BattParts.abox(g, Vector3(0, c.y, zc), Vector3(size.x, size.y, 2.0), col, "plastic")
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			BattParts.disc(g, Vector3(sx * (size.x * 0.5 - 6.0), c.y + sy * (size.y * 0.5 - 6.0), zf), Vector3.BACK, 2.6, 0.8,
				Color(0.7, 0.71, 0.73), "metal", 10)
	return out


func _bay_cover_aabb(d: Dictionary) -> AABB:
	var f: Dictionary = d["faces"]["bay"]
	var c: Vector3 = f["c"]
	var size: Vector2 = f["size"]
	return _mm_aabb(AABB(Vector3(-size.x * 0.5, c.y - size.y * 0.5, float(d["zf"]) - 2.0), Vector3(size.x, size.y, 2.0)))


static func _window_mesh(win: Dictionary) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var z := float(win["z"]) * MM
	var a := Vector3(float(win["x0"]), float(win["y0"]), 0) * MM + Vector3(0, 0, z)
	var b := Vector3(float(win["x1"]), float(win["y0"]), 0) * MM + Vector3(0, 0, z)
	var c := Vector3(float(win["x1"]), float(win["y1"]), 0) * MM + Vector3(0, 0, z)
	var dd := Vector3(float(win["x0"]), float(win["y1"]), 0) * MM + Vector3(0, 0, z)
	st.set_normal(Vector3.BACK)
	for v in [a, c, b, a, dd, c]:
		st.add_vertex(v)
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(0.75, 0.82, 0.88, 0.22)
	m.roughness = 0.08
	m.metallic_specular = 0.8
	var am := st.commit()
	am.surface_set_material(0, m)
	return am


func set_cover_visible(on: bool) -> void:
	for nn in ["BayCover", "Window"]:
		var n := get_node_or_null(nn)
		if n:
			(n as Node3D).visible = on


func cover_visible() -> bool:
	var n := get_node_or_null("BayCover")
	return n != null and (n as Node3D).visible


# ---------------------------------------------------------------------------
# Text, picking
# ---------------------------------------------------------------------------

## A printed text. `max_w` (mm) caps its width; with none, the text may
## not run past the face it is printed on (a left-aligned text to the right
## edge, a centred one to the nearer edge), which is what kept the long
## Victron names inside their panels.
func _text(parent: Node3D, d: Dictionary, t: Dictionary) -> void:
	var face := str(t.get("face", "front"))
	if not d["faces"].has(face):
		return
	var f: Dictionary = d["faces"][face]
	var u := float(t.get("u", 0.0))
	var v := float(t.get("v", 0.0))
	var align := str(t.get("align", "center"))
	var max_w := float(t.get("max_w", 0.0))
	if max_w <= 0.0 and absf(float(t.get("rot", 0.0))) < 0.01:
		var half: float = (f["size"] as Vector2).x * 0.5 - 2.0
		match align:
			"left":
				max_w = half - u
			"right":
				max_w = half + u
			_:
				max_w = 2.0 * (half - absf(u))
	var xf: Transform3D = (f["xf"] as Transform3D) * Transform3D(Basis(Vector3.BACK, deg_to_rad(float(t.get("rot", 0.0)))),
		Vector3(u, v, float(t.get("dz", 0.0)) + 0.3))
	_label3d(parent, str(t.get("text", "")), xf, float(t.get("size", 8.0)), CtrlSpec.color_of(t.get("color", [0.95, 0.95, 0.95])),
		bool(t.get("bold", false)), align, max_w)


func _label_from(parent: Node3D, lb: Dictionary) -> void:
	var n: Vector3 = lb["normal"]
	var up: Vector3 = lb["up"]
	var x := up.cross(n).normalized()
	_label3d(parent, str(lb["text"]), Transform3D(Basis(x, up, n), (lb["pos"] as Vector3) + n * 0.3), float(lb["size"]),
		lb["color"], false, "center")


static func _label3d(parent: Node3D, text: String, xf_mm: Transform3D, size_mm: float, col: Color, bold: bool, align: String,
		max_w: float = 0.0) -> void:
	if text.strip_edges() == "":
		return
	var l := Label3D.new()
	l.text = text
	l.font_size = 64
	var font := UITheme.font("semibold" if bold else "medium")
	var size := size_mm
	if max_w > 0.5 and font != null:
		var w_px := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 64).x
		var w_mm := w_px * size_mm / 64.0
		if w_mm > max_w:
			size = size_mm * max_w / w_mm
	l.pixel_size = size * MM / 64.0
	l.modulate = col
	l.outline_size = 0
	l.double_sided = false
	l.alpha_cut = Label3D.ALPHA_CUT_OPAQUE_PREPASS
	l.font = font
	match align:
		"left":
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		"right":
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	l.transform = Transform3D(xf_mm.basis, xf_mm.origin * MM)
	parent.add_child(l)


static func _xf_aabb(xf: Transform3D, ab: AABB) -> AABB:
	return _mm_aabb(xf * ab)


static func _mm_aabb(ab: AABB) -> AABB:
	return AABB(ab.position * MM, ab.size * MM)


func _spec_port(s: Dictionary, id: String) -> Dictionary:
	for p in (s["ports"] as Array):
		if str(p["id"]) == id:
			return p
	return {}


## The nearest part a ray (in this node's local metres) hits: "" for none.
## A hidden cover is skipped; the body counts only when nothing else is hit.
func pick(origin: Vector3, dir: Vector3) -> String:
	var best := ""
	var best_t := INF
	var body_hit := false
	for p in parts:
		if str(p["kind"]) == "cover" and not cover_visible():
			continue
		var ab: AABB = p["aabb"]
		var hit: Variant = ab.intersects_ray(origin, dir)
		if hit == null:
			continue
		if str(p["kind"]) == "body":
			body_hit = true
			continue
		var t := ((hit as Vector3) - origin).length()
		if t < best_t:
			best_t = t
			best = str(p["id"])
	if best == "" and body_hit:
		return "body"
	return best


func part(id: String) -> Dictionary:
	for p in parts:
		if str(p["id"]) == id:
			return p
	return {}
