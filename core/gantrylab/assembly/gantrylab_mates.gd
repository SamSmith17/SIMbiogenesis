class_name GantryLabMates
extends RefCounted

## How two parts fasten: which feature classes mate (COMPAT), where the child
## lands for a mate (`place`), whether that spot is real (`fits`: every bolt
## on a slot line, a hole on the grid, the four NEMA bolts on the four holes),
## where it may slide (`slide_range`), the nearest real spot to a wish
## (`snap`), the inverse (`infer`: a world pose → mate numbers, how mirrored
## twins and secondary contacts are solved), and the FASTENERS a mate needs —
## T-nuts and bolts cut to a stock length, nylocs, spacers, the wheels of a
## V-wheel carriage with their eccentric spacers.
##
## A mate: {to, tf (target feature id), f (child feature id), s, anchor
## ("start" | "end" | "centre"), lat (across the face), h (off the face, on
## spacers), turn (quarter turns about the shared normal)}. The child lands at
##   W_child = W_target · F_target · T(s·x + lat·z + h·y) · Ry(turn·90°) · Rx(180°) · F_child⁻¹
## so the two feature normals oppose, their x axes align at turn 0. A shaft
## mate slides along the axis (y) instead.

const TOL := 0.0006
const ENGAGE_TNUT_M5 := 0.005   # thread an M5 needs in a drop-in T-nut
const ENGAGE_TNUT_M3 := 0.004
const NUT_H := 0.005            # M5 nyloc height (DIN 985)
const WASHER := 0.001

## child class → {target class → mate type}
const COMPAT := {
	"m5": {"s20": "slot", "m5grid": "grid"},
	"m3": {"s20": "slot"},
	# Set-screwed inside the slot (the hidden corner bracket).
	"hid": {"s20": "slot"},
	# Into a beam's tapped end: through a cube connector's face, or a
	# 3-way connector's spigot pushed into the end.
	"tap5": {"end20": "pattern"},
	"end20": {"s20": "butt", "m5grid": "endgrid"},
	"run": {"s20": "run"},
	"nema17": {"nema17": "pattern"},
	"nema23": {"nema23": "pattern"},
	"tr8": {"tr8": "pattern"},
	"tool": {"tool": "pattern"},
	"springs": {"springs": "pattern"},
	"d5": {"d5": "shaft"},
	"d635": {"d635": "shaft"},
	"d8": {"d8": "shaft"},
	"b5": {"s20": "idler", "m5grid": "idler"},
	# A beam's own slotted face bolted flat to a plate's hole grid (an X
	# beam on its Z plates): T-nuts in the beam, bolts through the plate.
	"s20": {"m5grid": "lines"},
}

## Mates whose child rides the target (a carriage on its wheels).
const MOTION := ["run"]


static func mate_type(cf: Dictionary, tf: Dictionary) -> String:
	if cf.is_empty() or tf.is_empty():
		return ""
	if bool(cf.get("target", false)):
		return ""
	return str((COMPAT.get(str(cf["cls"]), {}) as Dictionary).get(str(tf["cls"]), ""))


static func slides_along_y(kind: String) -> bool:
	return kind == "shaft"


## The slide length of a target feature.
static func length_of(tf: Dictionary) -> float:
	return float(tf.get("len", 0.0))


## Absolute slide from a stored (s, anchor).
static func abs_s(tf: Dictionary, mate: Dictionary) -> float:
	var s := float(mate.get("s", 0.0))
	var L := length_of(tf)
	match str(mate.get("anchor", "start")):
		"end":
			return L - s
		"centre":
			return L * 0.5 + s
	return s


## Stored s for an absolute slide, keeping the mate's anchor.
static func rel_s(tf: Dictionary, anchor: String, s_abs: float) -> float:
	var L := length_of(tf)
	match anchor:
		"end":
			return L - s_abs
		"centre":
			return s_abs - L * 0.5
	return s_abs


static func _rot(turn: int) -> Basis:
	return Basis(Vector3.UP, float(posmod(turn, 4)) * PI * 0.5) * Basis(Vector3.RIGHT, PI)


## The offset of the child's feature in the target feature's frame.
static func _offset(kind: String, s_abs: float, mate: Dictionary) -> Vector3:
	if slides_along_y(kind):
		return Vector3(0, s_abs, 0)
	return Vector3(s_abs, float(mate.get("h", 0.0)), float(mate.get("lat", 0.0)))


## Where the child's origin lands (target-part space when `wt` is identity).
static func place(wt: Transform3D, tf: Dictionary, cf: Dictionary, mate: Dictionary) -> Transform3D:
	var kind := mate_type(cf, tf)
	var off := _offset(kind, abs_s(tf, mate), mate)
	var m: Transform3D = (tf["xf"] as Transform3D) * Transform3D(_rot(int(mate.get("turn", 0))), off)
	return wt * m * (cf["xf"] as Transform3D).affine_inverse()


## The child's holes in the target feature's frame (x, z; y = 0 on the face).
static func holes_on_target(tf: Dictionary, cf: Dictionary, mate: Dictionary) -> PackedVector3Array:
	var kind := mate_type(cf, tf)
	var off := _offset(kind, abs_s(tf, mate), mate)
	var r := _rot(int(mate.get("turn", 0)))
	var out := PackedVector3Array()
	for hv in cf.get("holes", PackedVector2Array()):
		var h: Vector2 = hv
		out.append(r * Vector3(h.x, 0, h.y) + off)
	return out


static func _on_line(z: float, lines: PackedFloat32Array) -> bool:
	for l in lines:
		if absf(z - float(l)) < TOL:
			return true
	return false


static func _on_grid(v: float, pitch: float) -> bool:
	var k := v / pitch
	return absf(k - roundf(k)) * pitch < TOL


## The child's footprint along the target's x after its turn: Vector2(lo, hi).
static func _ext_x(cf: Dictionary, turn: int) -> Vector2:
	var r: Rect2 = cf.get("ext", Rect2(0, 0, 0, 0))
	var ext_x := Vector2(r.position.x, r.end.x)
	var ext_z := Vector2(r.position.y, r.end.y)
	# Rx(180) takes (x, z) to (x, -z); Ry(90°) then takes (x, -z) to x' = -z.
	match posmod(turn, 4):
		1:
			return Vector2(-ext_z.y, -ext_z.x)
		2:
			return Vector2(-ext_x.y, -ext_x.x)
		3:
			return Vector2(ext_z.x, ext_z.y)
	return ext_x


## {ok, why}: whether the child really fastens there.
static func fits(tf: Dictionary, cf: Dictionary, mate: Dictionary) -> Dictionary:
	var kind := mate_type(cf, tf)
	if kind.is_empty():
		return {"ok": false, "why": "%s does not fasten to %s" % [str(cf.get("cls", "?")), str(tf.get("cls", "?"))]}
	var s_abs := abs_s(tf, mate)
	match kind:
		"slot", "butt", "idler":
			if str(tf["kind"]) == "grid":
				return _fits_grid(tf, cf, mate)
			var lines: PackedFloat32Array = tf.get("lines", PackedFloat32Array())
			var L := length_of(tf)
			for q in holes_on_target(tf, cf, mate):
				if not _on_line(q.z, lines):
					return {"ok": false, "why": "a bolt misses the slot"}
				if q.x < -TOL or q.x > L + TOL:
					return {"ok": false, "why": "off the end of the extrusion"}
			if kind == "idler":
				if s_abs < -TOL or s_abs > L + TOL:
					return {"ok": false, "why": "off the end of the extrusion"}
				if not _on_line(float(mate.get("lat", 0.0)), lines):
					return {"ok": false, "why": "the idler bolt misses the slot"}
			return {"ok": true, "why": ""}
		"grid", "endgrid":
			return _fits_grid(tf, cf, mate)
		"lines":
			var pitch := float(tf.get("pitch", 0.01))
			var r := _rot(int(mate.get("turn", 0)))
			for l in cf.get("lines", PackedFloat32Array()):
				var q := r * Vector3(0, 0, float(l)) + _offset("lines", abs_s(tf, mate), mate)
				var across := q.z if posmod(int(mate.get("turn", 0)), 2) == 0 else q.x
				if not _on_grid(across, pitch):
					return {"ok": false, "why": "the slots miss the plate's holes"}
			return {"ok": true, "why": ""}
		"pattern":
			var tholes: PackedVector2Array = tf.get("holes", PackedVector2Array())
			for q in holes_on_target(tf, cf, mate):
				var hit := false
				for th in tholes:
					if Vector2(q.x, q.z).distance_to(th) < TOL * 2.0:
						hit = true
						break
				if not hit:
					return {"ok": false, "why": "the bolt pattern does not match"}
			return {"ok": true, "why": ""}
		"run":
			var w := float(tf.get("width", 0.0))
			var ok_w := false
			for a in cf.get("across", []):
				if absf(float(a) - w) < 0.001:
					ok_w = true
			if not ok_w:
				return {"ok": false, "why": "the wheels cannot straddle a %.0f mm face" % (w * 1000.0)}
			if absf(float(mate.get("lat", 0.0))) > TOL:
				return {"ok": false, "why": "the plate must sit centred on the face"}
			if posmod(int(mate.get("turn", 0)), 2) != 0:
				return {"ok": false, "why": "the wheels must run along the extrusion"}
			return {"ok": true, "why": ""}
		"shaft":
			var L2 := length_of(tf)
			if s_abs < -TOL or s_abs > L2 + TOL:
				return {"ok": false, "why": "off the end of the shaft"}
			return {"ok": true, "why": ""}
	return {"ok": true, "why": ""}


static func _fits_grid(tf: Dictionary, cf: Dictionary, mate: Dictionary) -> Dictionary:
	var pitch := float(tf.get("pitch", 0.01))
	var rect: Rect2 = tf.get("rect", Rect2(-1, -1, 2, 2))
	var pts := holes_on_target(tf, cf, mate)
	if mate_type(cf, tf) == "idler":
		pts = PackedVector3Array([Vector3(abs_s(tf, mate), 0, float(mate.get("lat", 0.0)))])
	for q in pts:
		if not _on_grid(q.x, pitch) or not _on_grid(q.z, pitch):
			return {"ok": false, "why": "a bolt misses the hole grid"}
		if not rect.grow(TOL).has_point(Vector2(q.x, q.z)):
			return {"ok": false, "why": "off the edge of the plate"}
	return {"ok": true, "why": ""}


## The lateral offsets at which every child hole lands on a slot line.
static func lat_options(tf: Dictionary, cf: Dictionary, turn: int) -> Array:
	var lines: PackedFloat32Array = tf.get("lines", PackedFloat32Array())
	var r := _rot(turn)
	var zs: Array = []
	for hv in cf.get("holes", PackedVector2Array()):
		var h: Vector2 = hv
		zs.append((r * Vector3(h.x, 0, h.y)).z)
	if zs.is_empty():
		return Array(lines)
	var out: Array = []
	for l in lines:
		var o := float(l) - float(zs[0])
		var ok := true
		for z in zs:
			if not _on_line(float(z) + o, lines):
				ok = false
				break
		if ok:
			out.append(o)
	return out


## The slide range (absolute s) that keeps every hole and the footprint on.
static func slide_range(tf: Dictionary, cf: Dictionary, mate: Dictionary) -> Vector2:
	var kind := mate_type(cf, tf)
	var L := length_of(tf)
	if kind == "shaft":
		return Vector2(0.0, maxf(L - float(cf.get("depth", 0.0)) * 0.0, 0.0))
	if kind == "pattern" or kind == "butt":
		return Vector2(abs_s(tf, mate), abs_s(tf, mate))
	if str(tf.get("kind", "")) == "grid":
		var rect: Rect2 = tf.get("rect", Rect2())
		return Vector2(rect.position.x, rect.end.x)
	var e := _ext_x(cf, int(mate.get("turn", 0)))
	var lo := -e.x
	var hi := L - e.y
	if kind == "run":
		var wb := float(cf.get("wheelbase", 0.06))
		lo = maxf(lo, wb * 0.5 + WHEEL_R)
		hi = minf(hi, L - wb * 0.5 - WHEEL_R)
	if hi < lo:
		var m := (lo + hi) * 0.5
		return Vector2(m, m)
	return Vector2(lo, hi)


const WHEEL_R := GantryLabCatalog.WHEEL_R


## The nearest real mate to a wish: the turn kept when it can be, the lateral
## offset snapped to a slot line (or the grid), s clamped and stepped.
static func snap(tf: Dictionary, cf: Dictionary, wish: Dictionary, step: float = 0.001) -> Dictionary:
	var kind := mate_type(cf, tf)
	var m := wish.duplicate()
	if kind.is_empty():
		return {}
	if not m.has("anchor"):
		m["anchor"] = "start"
	var turns := [int(m.get("turn", 0)), int(m.get("turn", 0)) + 2, int(m.get("turn", 0)) + 1, int(m.get("turn", 0)) + 3]
	match kind:
		"slot", "butt":
			if str(tf["kind"]) == "grid":
				return _snap_grid(tf, cf, m, step)
			for t in turns:
				var opts := lat_options(tf, cf, t)
				if opts.is_empty():
					continue
				var want := float(m.get("lat", 0.0))
				var best := float(opts[0])
				for o in opts:
					if absf(float(o) - want) < absf(best - want):
						best = float(o)
				m["turn"] = posmod(t, 4)
				m["lat"] = best
				m["h"] = float(m.get("h", 0.0)) if bool(cf.get("standoff", false)) else 0.0
				_clamp_s(tf, cf, m, step)
				return m
			return {}
		"idler":
			if str(tf["kind"]) == "grid":
				return _snap_grid(tf, cf, m, step)
			var lines: PackedFloat32Array = tf.get("lines", PackedFloat32Array())
			var want2 := float(m.get("lat", 0.0))
			var best2 := float(lines[0]) if lines.size() > 0 else 0.0
			for l in lines:
				if absf(float(l) - want2) < absf(best2 - want2):
					best2 = float(l)
			m["lat"] = best2
			m["turn"] = 0
			var sa := clampf(abs_s(tf, m), 0.0, length_of(tf))
			m["s"] = rel_s(tf, str(m["anchor"]), _step(sa, step))
			return m
		"grid", "endgrid":
			return _snap_grid(tf, cf, m, step)
		"lines":
			var pitch2 := float(tf.get("pitch", 0.01))
			m["anchor"] = "start"
			m["h"] = 0.0
			m["turn"] = posmod(int(m.get("turn", 0)), 4)
			if posmod(int(m["turn"]), 2) == 0:
				m["lat"] = roundf(float(m.get("lat", 0.0)) / pitch2) * pitch2
			else:
				m["s"] = roundf(float(m.get("s", 0.0)) / pitch2) * pitch2
			return m if bool(fits(tf, cf, m)["ok"]) else {}
		"pattern":
			for t in turns:
				m["turn"] = posmod(t, 4)
				m["s"] = 0.0
				m["lat"] = 0.0
				m["h"] = 0.0
				m["anchor"] = "start"
				if bool(fits(tf, cf, m)["ok"]):
					return m
			return {}
		"run":
			m["lat"] = 0.0
			m["turn"] = 0 if posmod(int(m.get("turn", 0)), 4) < 2 else 2
			if not m.has("h"):
				m["h"] = float(cf.get("gap", 0.0011))
			if not bool(fits(tf, cf, m)["ok"]):
				return {}
			_clamp_s(tf, cf, m, step)
			return m
		"shaft":
			m["lat"] = 0.0
			m["h"] = 0.0
			var r := slide_range(tf, cf, m)
			m["s"] = rel_s(tf, str(m["anchor"]), _step(clampf(abs_s(tf, m), r.x, r.y), step))
			return m
	return m


static func _step(v: float, step: float) -> float:
	if step <= 0.0:
		return v
	return roundf(v / step) * step


static func _clamp_s(tf: Dictionary, cf: Dictionary, m: Dictionary, step: float) -> void:
	var r := slide_range(tf, cf, m)
	var sa := clampf(_step(abs_s(tf, m), step), r.x, r.y)
	m["s"] = rel_s(tf, str(m.get("anchor", "start")), sa)


static func _snap_grid(tf: Dictionary, cf: Dictionary, m: Dictionary, _step_unused: float) -> Dictionary:
	var pitch := float(tf.get("pitch", 0.01))
	m["anchor"] = "start"
	var base_turn := int(m.get("turn", 0))
	for dt in [0, 2, 1, 3]:
		var t := base_turn + int(dt)
		var c := m.duplicate()
		c["turn"] = posmod(t, 4)
		# Snap so the FIRST hole lands on a grid point; the rest follow
		# when the pattern is a multiple of the pitch.
		var holes := holes_on_target(tf, cf, {"turn": c["turn"], "s": 0.0, "lat": 0.0, "anchor": "start"})
		var h0 := holes[0] if holes.size() > 0 else Vector3.ZERO
		if mate_type(cf, tf) == "idler":
			h0 = Vector3.ZERO
		var sx := roundf((float(c.get("s", 0.0)) + h0.x) / pitch) * pitch - h0.x
		var sz := roundf((float(c.get("lat", 0.0)) + h0.z) / pitch) * pitch - h0.z
		c["s"] = sx
		c["lat"] = sz
		if not bool(cf.get("standoff", false)) and mate_type(cf, tf) != "idler":
			c["h"] = 0.0
		if bool(fits(tf, cf, c)["ok"]):
			return c
		# Pull it back inside the plate.
		var rect: Rect2 = tf.get("rect", Rect2())
		for _i in 40:
			var hs := holes_on_target(tf, cf, c)
			var dx := 0.0
			var dz := 0.0
			for q in hs:
				if q.x < rect.position.x:
					dx = maxf(dx, pitch)
				if q.x > rect.end.x:
					dx = minf(dx, -pitch)
				if q.z < rect.position.y:
					dz = maxf(dz, pitch)
				if q.z > rect.end.y:
					dz = minf(dz, -pitch)
			if dx == 0.0 and dz == 0.0:
				break
			c["s"] = float(c["s"]) + dx
			c["lat"] = float(c["lat"]) + dz
		if bool(fits(tf, cf, c)["ok"]):
			return c
	return {}


## World pose → mate numbers (the inverse of `place`): {s (abs), lat, h, turn,
## err (how far the pose is from any pure mate: tilt / lift)}.
static func infer(wt: Transform3D, tf: Dictionary, cf: Dictionary, wc: Transform3D) -> Dictionary:
	var m: Transform3D = ((tf["xf"] as Transform3D).affine_inverse()) * wt.affine_inverse() * wc * (cf["xf"] as Transform3D)
	var r := m.basis * Basis(Vector3.RIGHT, PI).inverse()
	# r should be a rotation about y: read the angle off its x column.
	var xc := r.x
	var ang := atan2(-xc.z, xc.x)
	var turn := posmod(int(roundf(ang / (PI * 0.5))), 4)
	var tilt := absf(r.y.normalized().dot(Vector3.UP) - 1.0)
	var o := m.origin
	var kind := mate_type(cf, tf)
	if slides_along_y(kind):
		return {"s": o.y, "lat": 0.0, "h": 0.0, "turn": turn, "err": tilt + Vector2(o.x, o.z).length()}
	return {"s": o.x, "lat": o.z, "h": o.y, "turn": turn, "err": tilt}


# ---------------------------------------------------------------------------
# Fasteners
# ---------------------------------------------------------------------------

static func stock_len(min_m: float, max_m: float = INF) -> float:
	var lo := min_m * 1000.0 - 0.05
	var hi := max_m * 1000.0 + 0.05
	var best := -1.0
	for l in GantryLabCatalog.STOCK_LEN:
		if float(l) >= lo:
			best = float(l)
			break
	if best < 0.0:
		best = float(GantryLabCatalog.STOCK_LEN[-1])
	if best > hi:
		# Nothing fits the window: the longest that does not bottom out.
		best = -1.0
		for l in GantryLabCatalog.STOCK_LEN:
			if float(l) <= hi:
				best = float(l)
		if best < 0.0:
			best = float(GantryLabCatalog.STOCK_LEN[0])
	return best * 0.001


static func _bolt(d: float, len: float, head_face: Vector3, toward_head: Vector3, head: String = "shcs") -> Dictionary:
	return {"kind": "bolt", "d": d, "len": len, "head": head, "xf": Transform3D(GantryLabDetail.basis_y(toward_head), head_face),
		"label": "M%d×%d %s" % [int(round(d * 1000.0)), int(round(len * 1000.0)), "button head" if head == "bhcs" else "cap screw"]}


static func _nut(d: float, at: Vector3, up: Vector3) -> Dictionary:
	return {"kind": "nut", "d": d, "xf": Transform3D(GantryLabDetail.basis_y(up), at), "label": "M%d nyloc nut" % int(round(d * 1000.0))}


static func _tnut(d: float, at: Vector3, out: Vector3, along: Vector3) -> Dictionary:
	return {"kind": "tnut", "d": d, "xf": Transform3D(GantryLabDetail.basis_yz(out, along.cross(out)), at), "label": "M%d drop-in T-nut" % int(round(d * 1000.0))}


static func _spacer(a: Vector3, axis: Vector3, len: float, label: String, ecc: bool = false) -> Dictionary:
	return {"kind": "spacer", "len": len, "ecc": ecc, "xf": Transform3D(GantryLabDetail.basis_y(axis), a), "label": label}


static func _washer(at: Vector3, up: Vector3) -> Dictionary:
	return {"kind": "washer", "xf": Transform3D(GantryLabDetail.basis_y(up), at), "label": "M5 washer"}


static func _mm(v: float) -> String:
	return "%.1f" % (v * 1000.0) if absf(v * 1000.0 - round(v * 1000.0)) > 0.05 else "%d" % int(round(v * 1000.0))


## Everything a mate needs to hold: [{kind, xf, label, …}] in the space of
## `wt` (the target part's world), plus generated wheels for a run mate.
## `tt` = the target's material thickness where it matters.
static func fasteners(wt: Transform3D, tf: Dictionary, cf: Dictionary, mate: Dictionary, extra: Dictionary = {}) -> Array:
	var kind := mate_type(cf, tf)
	var out: Array = []
	var fx: Transform3D = wt * (tf["xf"] as Transform3D)
	var n := fx.basis.y.normalized()
	var along := fx.basis.x.normalized()
	var tc := float(cf.get("t", 0.0))
	var tt := float(tf.get("t", 0.0))
	var h := float(mate.get("h", 0.0))
	match kind:
		"slot", "grid":
			var on_grid := str(tf["kind"]) == "grid"
			if str(cf["cls"]) == "hid":
				for _q in holes_on_target(tf, cf, mate):
					out.append({"kind": "grub_hidden", "label": "M5×6 set screw", "count": 1})
				return out
			for q in holes_on_target(tf, cf, mate):
				var p := fx * Vector3(q.x, 0, q.z)
				var d := 0.003 if str(cf["cls"]) == "m3" else 0.005
				var head_face := p + n * (h + tc)
				if on_grid:
					var L := stock_len(tc + h + tt + NUT_H + 0.001)
					out.append(_bolt(d, L, head_face, n))
					out.append(_nut(d, p - n * tt, -n))
				else:
					var eng := ENGAGE_TNUT_M3 if d < 0.004 else ENGAGE_TNUT_M5
					out.append(_bolt(d, stock_len(tc + h + eng), head_face, n, "bhcs" if tc > 0.0 else "shcs"))
					out.append(_tnut(d, p - n * 0.0028, n, along))
				if h > 0.0005:
					out.append(_spacer(p, n, h, "Spacer %s mm" % _mm(h)))
		"pattern":
			var cls := str(cf["cls"])
			for q in holes_on_target(tf, cf, mate):
				var p := fx * Vector3(q.x, 0, q.z)
				match cls:
					"nema17":
						# Through the bracket into the motor's tapped holes: never
						# longer than the 4.5 mm of thread (would bottom out).
						out.append(_bolt(0.003, stock_len(tt + 0.003, tt + 0.0045), p - n * tt, -n))
					"nema23":
						out.append(_bolt(0.005, stock_len(tt + 0.005 + NUT_H + 0.001), p - n * tt, -n))
						out.append(_nut(0.005, p + n * 0.005, n))
					"tr8":
						out.append(_bolt(0.003, stock_len(tc + tt + 0.004), p + n * tc, n))
						out.append(_nut(0.003, p - n * tt, -n))
					"tool":
						out.append(_bolt(0.003, stock_len(tt + 0.006), p - n * tt, -n))
					"tap5":
						if bool(cf.get("grub", false)):
							out.append({"kind": "grub_hidden", "label": "M5×6 set screw", "count": 1})
						else:
							# From inside the connector into the beam's tapped end.
							out.append(_bolt(0.005, stock_len(tc + 0.008), p + n * tc, n))
					"springs":
						var sh := GantryLabCatalog.SPRING_H
						out.append({"kind": "spring_knob", "h": sh, "xf": Transform3D(GantryLabDetail.basis_y(n), p - n * sh), "label": "Bed spring + knob"})
						out.append({"kind": "bolt_hidden", "label": "M3×%d countersunk" % int(round((sh + tt + 0.016) * 1000.0)), "d": 0.003})
		"run":
			out.append_array(wheels(wt, tf, cf, mate, extra))
		"idler":
			var lat := float(mate.get("lat", 0.0))
			var p := fx * Vector3(abs_s(tf, mate), 0, lat)
			var bw := float(extra.get("belt_w", 0.006))
			var stack := bw + 0.004
			var head_face := p + n * (h + stack + WASHER)
			if str(tf["kind"]) == "grid":
				out.append(_bolt(0.005, stock_len(h + stack + WASHER + tt + NUT_H + 0.001), head_face, n))
				out.append(_nut(0.005, p - n * tt, -n))
			else:
				out.append(_bolt(0.005, stock_len(h + stack + WASHER + ENGAGE_TNUT_M5), head_face, n))
				out.append(_tnut(0.005, p - n * 0.0028, n, along))
			out.append(_washer(p + n * (h + stack), n))
			if h > 0.0005:
				out.append(_spacer(p, n, h, "Spacer %s mm" % _mm(h)))
		"shaft":
			out.append({"kind": "grub_hidden", "label": "M3×4 grub screw", "count": 2})
		"endgrid":
			# Through the plate into the beam's tapped end.
			for q in holes_on_target(tf, cf, mate):
				var p := fx * Vector3(q.x, 0, q.z)
				out.append(_bolt(0.005, stock_len(tt + 0.012), p - n * tt, -n))
		"lines":
			# Two bolts per slot line where the beam lies on the plate.
			var rect: Rect2 = tf.get("rect", Rect2())
			var r2 := _rot(int(mate.get("turn", 0)))
			var off := _offset("lines", abs_s(tf, mate), mate)
			var beam_len := float(cf.get("len", 0.0))
			var pitch3 := float(tf.get("pitch", 0.01))
			for l in cf.get("lines", PackedFloat32Array()):
				var a0 := r2 * Vector3(0, 0, float(l)) + off
				var a1 := r2 * Vector3(beam_len, 0, float(l)) + off
				var pts: Array = []
				var k0 := ceili((rect.position.x) / pitch3)
				var k1 := floori((rect.end.x) / pitch3)
				var k0z := ceili((rect.position.y) / pitch3)
				var k1z := floori((rect.end.y) / pitch3)
				# Grid points on the line's segment, inside the plate.
				for kx in range(k0, k1 + 1):
					for kz in range(k0z, k1z + 1):
						var gp := Vector3(kx * pitch3, 0, kz * pitch3)
						var seg := a1 - a0
						var t := clampf((gp - a0).dot(seg) / maxf(seg.length_squared(), 1e-12), 0.0, 1.0)
						if (a0 + seg * t).distance_to(gp) < TOL and t > 0.02 and t < 0.98:
							pts.append(gp)
				pts.sort_custom(func(u: Vector3, v: Vector3) -> bool: return u.x + u.z < v.x + v.z)
				var pick: Array = []
				if pts.size() > 0:
					pick.append(pts[0])
				if pts.size() > 2:
					pick.append(pts[pts.size() - 1])
				for gp2 in pick:
					var p := fx * (gp2 as Vector3)
					out.append(_bolt(0.005, stock_len(tt + ENGAGE_TNUT_M5), p - n * tt, -n))
					out.append(_tnut(0.005, p + n * 0.0028, -n, along))
	return out


## The wheels of a V-wheel carriage, in the space of `wt`: on each side of
## the face, centred in the side face's slot (`depth` below the face, the
## rim WHEEL_IN into the V), on a spacer up to the plate (6 mm eccentric on
## one side for adjusting, a precision spacer on the other), an M5 bolt from
## the plate's top through to a nyloc under the wheel.
static func wheels(wt: Transform3D, tf: Dictionary, cf: Dictionary, mate: Dictionary, extra: Dictionary = {}) -> Array:
	var out: Array = []
	var fx: Transform3D = wt * (tf["xf"] as Transform3D)
	var n := fx.basis.y.normalized()
	var across := float(tf.get("width", 0.02))
	var depth := float(tf.get("depth", GantryLabCatalog.SLOT_DEPTH_SIDE))
	var h := float(mate.get("h", cf.get("gap", 0.0011)))
	var t := float(cf.get("t", 0.006))
	var wb := float(extra.get("wheelbase", 0.06))
	var count := int(extra.get("wheels", 4))
	var s := abs_s(tf, mate)
	var lat := float(mate.get("lat", 0.0))
	var wr := float(extra.get("wheel_r", GantryLabCatalog.WHEEL_R))
	var ww := float(extra.get("wheel_w", GantryLabCatalog.WHEEL_W))
	var wlabel := "Mini V-wheel" if wr < 0.01 else "Solid V-wheel (625 bearings)"
	var zoff := across * 0.5 + wr - GantryLabCatalog.WHEEL_IN
	var pts: Array = []
	if count == 3:
		pts = [Vector2(s - wb * 0.5, lat + zoff), Vector2(s + wb * 0.5, lat + zoff), Vector2(s, lat - zoff)]
	else:
		pts = [Vector2(s - wb * 0.5, lat + zoff), Vector2(s + wb * 0.5, lat + zoff), Vector2(s - wb * 0.5, lat - zoff), Vector2(s + wb * 0.5, lat - zoff)]
	var spacer := h + depth - ww * 0.5
	for pv in pts:
		var pp: Vector2 = pv
		var ecc := pp.y < lat
		var c := fx * Vector3(pp.x, -depth, pp.y)
		out.append({"kind": "wheel", "xf": Transform3D(GantryLabDetail.basis_y(n), c), "label": wlabel, "r": wr, "w": ww})
		var top := c + n * (ww * 0.5)
		out.append(_spacer(top, n, spacer, ("Eccentric spacer %s mm" if ecc else "Precision spacer %s mm") % _mm(spacer), ecc))
		var bottom := c - n * (ww * 0.5 + WASHER)
		out.append(_washer(bottom, -n))
		out.append(_nut(0.005, bottom - n * 0.0, -n))
		var head_face := c + n * (ww * 0.5 + spacer + t)
		out.append(_bolt(0.005, stock_len(t + spacer + ww + WASHER + NUT_H + 0.001), head_face, n, "bhcs"))
	return out


## The wheel centres alone (plate space), for clash exemption / probes.
static func wheel_count(extra: Dictionary) -> int:
	return int(extra.get("wheels", 4))
