class_name PvGridSnap
extends RefCounted

## Proximity snap that lines solar panels, strings and arrays up into clean
## rectangular grids — the way real arrays are built. Pure; one rule serves
## the 3D world (a placed `pv_array` rack, metres, with yaw) and the freeform
## graph (panel nodes, canvas units, no rotation).
##
## A RECT is {id, key, x, z, yaw (deg), w, d, h_top}: centre, Godot yaw about
## +Y, width along its local X (the row), depth along its local Z (the rack
## faces local +Z), and how high its rear edge stands above its front edge
## (the shadow caster; 0 for the graph). `key` is the array / controller the
## rect feeds: neighbours with the SAME key are preferred — that is the
## "auto-snap within one array".
##
## A dragged rect is offered slots next to a neighbour: beside it in its row
## (edge to edge, `gap` apart) or in the row in front / behind (at the row
## pitch), with its centre or an edge lined up. Yaw locks to the neighbour's
## when within `yaw_lock_deg`. The nearest slot within `radius` wins.
##
## Row pitch "auto" = no inter-row shading at winter-solstice solar noon: the
## clear gap behind a row is h_top / tan(α), α = 90° − |lat| − 23.44° (floored
## at 10°). For one tilted module of slant length L that gives the standard
## ground-coverage pitch L·cos t + L·sin t / tan α, front edge to front edge.

const DEFAULT_RADIUS_M := 1.5
const DEFAULT_GAP_M := 0.02
const DEFAULT_YAW_LOCK_DEG := 12.0
const MIN_SUN_ALT_DEG := 10.0
const SOLSTICE_DECL_DEG := 23.44


## Noon sun altitude at the winter solstice for latitude `lat` (degrees).
static func winter_noon_altitude_deg(lat: float) -> float:
	return maxf(90.0 - absf(lat) - SOLSTICE_DECL_DEG, MIN_SUN_ALT_DEG)


## Clear ground behind a row whose rear edge stands `h_top` above its front.
static func shade_gap_m(h_top: float, lat: float) -> float:
	if h_top <= 0.0:
		return 0.0
	return h_top / tan(deg_to_rad(winter_noon_altitude_deg(lat)))


## Centre-to-centre distance between a row `a` and the row behind or in front
## of it, `b`: `row_pitch` >= 0 forces it, otherwise the shading rule (and
## never closer than touching + gap).
static func row_pitch(a: Dictionary, b: Dictionary, opts: Dictionary) -> float:
	var forced := float(opts.get("row_pitch", -1.0))
	var gap := float(opts.get("gap", DEFAULT_GAP_M))
	var touch := (float(a.get("d", 0.0)) + float(b.get("d", 0.0))) * 0.5 + gap
	if forced >= 0.0:
		return maxf(forced, touch)
	var lat := float(opts.get("lat", NAN))
	if is_nan(lat):
		return touch
	var h := maxf(float(a.get("h_top", 0.0)), float(b.get("h_top", 0.0)))
	return maxf(touch, (float(a.get("d", 0.0)) + float(b.get("d", 0.0))) * 0.5 + shade_gap_m(h, lat))


## A rack rect for a `pv_array` prop spec at (x, z, yaw).
static func rect_for_pv_spec(spec: Dictionary, x: float, z: float, yaw_deg: float,
		id: String = "", key: String = "") -> Dictionary:
	var s := PvArrayBuilder.resolve_spec(spec)
	var cols := int(s["cols"])
	var rows := int(s["rows"])
	var pw := float(s["panel_w_m"])
	var ph := float(s["panel_h_m"])
	var t := deg_to_rad(float(s["tilt_deg"]))
	var step_z := ph * cos(t) + SolarArrayBuilder.ROW_GAP
	return {"id": id, "key": key, "x": x, "z": z, "yaw": yaw_deg,
		"w": float(cols) * pw + float(cols - 1) * SolarArrayBuilder.GAP_X,
		"d": float(rows - 1) * step_z + ph * cos(t),
		"h_top": ph * sin(t)}


## Local axes of a rect in the xz plane: row direction (local +X) and facing
## (local +Z), for a Godot yaw about +Y.
static func axes(yaw_deg: float) -> Array:
	var y := deg_to_rad(yaw_deg)
	return [Vector2(cos(y), -sin(y)), Vector2(sin(y), cos(y))]


static func _yaw_diff(a: float, b: float) -> float:
	return absf(wrapf(a - b, -180.0, 180.0))


## Snap `moving` against `neighbours`. Returns {snapped, x, z, yaw, target_id,
## kind ("row" | "front" | "behind"), guides: [[Vector2, Vector2], …]}; with
## nothing in reach, snapped = false and the input position/yaw.
static func snap(moving: Dictionary, neighbours: Array, opts: Dictionary = {}) -> Dictionary:
	var radius := float(opts.get("radius", DEFAULT_RADIUS_M))
	var gap := float(opts.get("gap", DEFAULT_GAP_M))
	var lock := float(opts.get("yaw_lock_deg", DEFAULT_YAW_LOCK_DEG))
	var c := Vector2(float(moving.get("x", 0.0)), float(moving.get("z", 0.0)))
	var mw := float(moving.get("w", 1.0))
	var md := float(moving.get("d", 1.0))
	var mkey := str(moving.get("key", ""))
	var out := {"snapped": false, "x": c.x, "z": c.y, "yaw": float(moving.get("yaw", 0.0)),
		"target_id": "", "kind": "", "guides": []}
	var best_score := INF
	for nb in neighbours:
		var n: Dictionary = nb
		if str(n.get("id", "")) == str(moving.get("id", "~")) and not str(n.get("id", "")).is_empty():
			continue
		var nyaw := float(n.get("yaw", 0.0))
		if _yaw_diff(float(moving.get("yaw", 0.0)), nyaw) > lock:
			continue
		var nc := Vector2(float(n.get("x", 0.0)), float(n.get("z", 0.0)))
		var nw := float(n.get("w", 1.0))
		var nd := float(n.get("d", 1.0))
		var ax: Array = axes(nyaw)
		var ux: Vector2 = ax[0]
		var uz: Vector2 = ax[1]
		var rel := Vector2((c - nc).dot(ux), (c - nc).dot(uz))
		# Quick reject: too far from this neighbour for any slot to be in reach.
		if absf(rel.x) > (nw + mw) * 0.5 + gap + radius + nw \
				and absf(rel.y) > (nd + md) * 0.5 + radius + nd * 3.0:
			continue
		var slots: Array = []
		var sx := (nw + mw) * 0.5 + gap
		var zs := [0.0, (nd - md) * 0.5, -(nd - md) * 0.5]
		for sgn in [1.0, -1.0]:
			for zz in zs:
				slots.append([Vector2(sgn * sx, zz), "row"])
		var pitch := row_pitch(n, moving, opts)
		var xs := [0.0, (nw - mw) * 0.5, -(nw - mw) * 0.5]
		for xx in xs:
			slots.append([Vector2(xx, pitch), "front"])
			slots.append([Vector2(xx, -pitch), "behind"])
		var same_array := not mkey.is_empty() and mkey == str(n.get("key", ""))
		for sl in slots:
			var p: Vector2 = sl[0]
			var dist := rel.distance_to(p)
			if dist > radius:
				continue
			# Own-array neighbours win ties and near-ties (half a radius).
			var score := dist - (radius * 0.5 if same_array else 0.0)
			if score < best_score:
				best_score = score
				var w := nc + ux * p.x + uz * p.y
				out = {"snapped": true, "x": w.x, "z": w.y, "yaw": nyaw,
					"target_id": str(n.get("id", "")), "kind": str(sl[1]),
					"guides": _guides(nc, ux, uz, nw, nd, p, mw, md, str(sl[1]))}
	return out


## Two guide segments: the shared edge line and the neighbour's centre axis
## extended through the snapped rect.
static func _guides(nc: Vector2, ux: Vector2, uz: Vector2, nw: float, nd: float,
		p: Vector2, mw: float, md: float, kind: String) -> Array:
	var g: Array = []
	if kind == "row":
		var ex := signf(p.x) * nw * 0.5
		var z0 := minf(-nd * 0.5, p.y - md * 0.5)
		var z1 := maxf(nd * 0.5, p.y + md * 0.5)
		g.append([nc + ux * ex + uz * z0, nc + ux * ex + uz * z1])
		g.append([nc + ux * minf(-nw * 0.5, p.x - mw * 0.5), nc + ux * maxf(nw * 0.5, p.x + mw * 0.5)])
	else:
		var x0 := minf(-nw * 0.5, p.x - mw * 0.5)
		var x1 := maxf(nw * 0.5, p.x + mw * 0.5)
		g.append([nc + ux * x0 + uz * p.y, nc + ux * x1 + uz * p.y])
		g.append([nc + uz * minf(-nd * 0.5, p.y - md * 0.5) + ux * p.x,
			nc + uz * maxf(nd * 0.5, p.y + md * 0.5) + ux * p.x])
	return g


## Lay `rects` out as a grid anchored on `anchor` (which keeps its place and
## yaw): `per_row` across (0 = one row up to 6, else ≈ square), rows marching
## BEHIND the anchor (away from the way it faces) at the row pitch. Returns
## {id: {x, z, yaw}} for every rect, the anchor included.
static func grid_layout(anchor: Dictionary, rects: Array, opts: Dictionary = {}, per_row: int = 0) -> Dictionary:
	var gap := float(opts.get("gap", DEFAULT_GAP_M))
	var all: Array = [anchor]
	for r in rects:
		if str((r as Dictionary).get("id", "")) != str(anchor.get("id", "")):
			all.append(r)
	var n := all.size()
	if per_row <= 0:
		per_row = n if n <= 6 else int(ceil(sqrt(float(n))))
	var yaw := float(anchor.get("yaw", 0.0))
	var ax: Array = axes(yaw)
	var ux: Vector2 = ax[0]
	var uz: Vector2 = ax[1]
	var origin := Vector2(float(anchor.get("x", 0.0)), float(anchor.get("z", 0.0)))
	var out := {}
	var row_z := 0.0
	var prev_row: Dictionary = {}
	var i := 0
	while i < n:
		var row: Array = all.slice(i, mini(i + per_row, n))
		if not prev_row.is_empty():
			row_z -= row_pitch(prev_row, row[0], opts)
		# Lay the row left to right starting at the anchor's left edge.
		var x := -float((all[0] as Dictionary).get("w", 1.0)) * 0.5
		var deepest: Dictionary = row[0]
		for r in row:
			var rd: Dictionary = r
			var w := float(rd.get("w", 1.0))
			var p := origin + ux * (x + w * 0.5) + uz * row_z
			out[str(rd.get("id", ""))] = {"x": p.x, "z": p.y, "yaw": yaw}
			x += w + gap
			if float(rd.get("d", 0.0)) > float(deepest.get("d", 0.0)):
				deepest = rd
		prev_row = deepest
		i += per_row
	return out



# ---------------------------------------------------------------------------
# Player prefs (user://ui_prefs.cfg [pv_snap]) — a taste, not a site property
# ---------------------------------------------------------------------------

const PREFS_PATH := "user://ui_prefs.cfg"
const PREF_DEFAULTS := {"enabled": true, "radius_m": DEFAULT_RADIUS_M, "gap_m": DEFAULT_GAP_M,
	"row_pitch_m": -1.0, "graph_gap_px": 24.0}
static var _prefs: Dictionary = {}


static func prefs() -> Dictionary:
	if _prefs.is_empty():
		_prefs = PREF_DEFAULTS.duplicate()
		var cfg := ConfigFile.new()
		if cfg.load(PREFS_PATH) == OK:
			for k in PREF_DEFAULTS:
				_prefs[k] = cfg.get_value("pv_snap", k, PREF_DEFAULTS[k])
	return _prefs


static func set_pref(key: String, value: Variant) -> void:
	prefs()[key] = value
	var cfg := ConfigFile.new()
	cfg.load(PREFS_PATH)
	cfg.set_value("pv_snap", key, value)
	cfg.save(PREFS_PATH)


## The 3D snap options for a site at latitude `lat`.
static func world_opts(lat: float) -> Dictionary:
	var p := prefs()
	return {"radius": float(p["radius_m"]), "gap": float(p["gap_m"]),
		"row_pitch": float(p["row_pitch_m"]), "lat": lat}


static func enabled() -> bool:
	return bool(prefs()["enabled"])
