class_name GraphView3D
extends RefCounted

## The freeform canvas seen in 3D (Layout ▾ → 3D: nested spheres / torus).
## Holds the camera (yaw, pitch, a little orbit inertia), the GraphSchema3D
## layout of the active scope, and the per-frame projection of every node;
## draws the shells, the system names and the connectors on the canvas.
##
## The canvas asks `rect_for(id, flat_tl, flat_size)` from its one
## card-position function (_item_screen_tl / _item_screen_size), so cards,
## ports, picking, wire drags and the selection all follow the 3D view
## without any of them knowing about it. Positions in the model are never
## written: the flat ring stays the arrangement underneath.

var mode := ""                ## GraphSchema3D.SPHERE | TORUS | "" (flat)
## The scope the 3D view belongs to: a group opened from it is shown flat
## inside, and coming back out lands on the 3D view again.
var scope_id := "root"
var yaw := 0.55
var pitch := -0.32
## 0 = the flat graph, 1 = the 3D view; eases both ways on enter / leave.
var blend := 0.0
var _blend_to := 0.0
var _leave_after := false
var _vel := Vector2.ZERO      ## orbit inertia, radians per second
var orbiting := false

var layout: Dictionary = {}
var _key := ""
## id -> Vector3(graph x, graph y offset from the centre, depth) and the
## perspective factor, refreshed when the camera or the layout moves.
var _proj: Dictionary = {}
var _proj_dirty := true
var _centre := Vector2.ZERO
var _extent := 1.0
var _dist := 1.0

const BLEND_S := 0.7
const ORBIT_RAD_PER_PX := 0.0075
const INERTIA_DECAY := 4.0
## Cards shrink with distance, but not past these (readable / not huge).
const SCALE_MIN := 0.55
const SCALE_MAX := 1.45
## How much a far card is faded toward the canvas (0 near … this far).
const FOG_MAX := 0.74
const C_MEMBRANE := Color(0.42, 0.72, 1.0)
const C_NUCLEUS := Color(1.0, 0.78, 0.45)
const C_TORUS := Color(0.55, 0.80, 1.0)


func active() -> bool:
	return not mode.is_empty()


## Enter a 3D mode (or "" to leave) for `scope`. Returns true when anything changed.
func set_mode(m: String, animate: bool = true, scope: String = "") -> bool:
	if not scope.is_empty() and scope != scope_id and not m.is_empty():
		scope_id = scope
		_key = ""
		_proj_dirty = true
		if m == mode and not _leave_after:
			return true
	if m == mode and not _leave_after:
		return false
	if m.is_empty():
		if mode.is_empty():
			return false
		_blend_to = 0.0
		_leave_after = true
		if not animate:
			blend = 0.0
			_finish_leave()
		return true
	var was := mode
	mode = m
	_leave_after = false
	if was != m:
		var dv: Dictionary = GraphSchema3D.DEFAULT_VIEW.get(m, {})
		yaw = float(dv.get("yaw", 0.5))
		pitch = float(dv.get("pitch", 0.0))
		_key = ""
	_blend_to = 1.0
	if not animate:
		blend = 1.0
	_proj_dirty = true
	return true


func _finish_leave() -> void:
	mode = ""
	_leave_after = false
	layout = {}
	_key = ""
	_proj.clear()
	_proj_dirty = true


## Per frame. Returns true while anything is moving (the canvas redraws).
func advance(delta: float) -> bool:
	var moving := false
	if blend != _blend_to:
		var step := delta / BLEND_S
		blend = move_toward(blend, _blend_to, step)
		moving = true
		if blend == 0.0 and _leave_after:
			_finish_leave()
	if not orbiting and _vel.length() > 0.002:
		orbit_by(_vel * delta)
		_vel *= exp(-INERTIA_DECAY * delta)
		moving = true
	elif not orbiting:
		_vel = Vector2.ZERO
	return moving


func eased_blend() -> float:
	return blend * blend * (3.0 - 2.0 * blend)


## Ctrl+drag: screen pixels -> yaw (left / right) and pitch (up / down).
func orbit_px(rel: Vector2, delta: float) -> void:
	var r := rel * ORBIT_RAD_PER_PX
	orbit_by(r)
	if delta > 0.0:
		_vel = _vel.lerp(r / delta, 0.5)


func orbit_by(r: Vector2) -> void:
	yaw = wrapf(yaw + r.x, -PI, PI)
	pitch = clampf(pitch - r.y, -GraphSchema3D.PITCH_LIMIT, GraphSchema3D.PITCH_LIMIT)
	_proj_dirty = true


## `stale`: the pointer had stopped before the release, so no spin.
func end_orbit(stale: bool = false) -> void:
	orbiting = false
	if stale:
		_vel = Vector2.ZERO
	_vel = _vel.limit_length(6.0)


func state() -> Dictionary:
	return {"mode": mode if not _leave_after else "", "yaw": yaw, "pitch": pitch, "scope": scope_id}


func apply_state(d: Dictionary) -> void:
	var m := str(d.get("mode", ""))
	if m.is_empty() or not GraphSchema3D.MODES.has(m):
		if active():
			blend = 0.0
			_finish_leave()
		return
	set_mode(m, false, str(d.get("scope", "root")))
	yaw = float(d.get("yaw", yaw))
	pitch = clampf(float(d.get("pitch", pitch)), -GraphSchema3D.PITCH_LIMIT, GraphSchema3D.PITCH_LIMIT)
	_proj_dirty = true


## The layout for this scope, recomputed when the graph's structure changes
## or a person edits it (user_rev: a card placed on its shell, an undo).
func ensure(model: Object, port_side: Callable, spacing: float) -> void:
	if not active() or model == null or not _drag_ovr.is_empty():
		return
	var key := "%s|%s|%d|%d" % [mode, scope_id, int(model.get("struct_rev")), int(model.get("user_rev"))]
	if key == _key:
		return
	_key = key
	var items := GraphLayout.filter_layout_items(model.call("get_items_in_scope", scope_id))
	var ids := {}
	for it in items:
		ids[str((it as Dictionary).get("id", ""))] = true
	var conns: Array = []
	for c in model.call("get_connections_in_scope", scope_id):
		var cd: Dictionary = c
		if ids.has(str(cd.get("source_item_id", ""))) and ids.has(str(cd.get("target_item_id", ""))):
			conns.append(cd)
	layout = GraphSchema3D.layout(mode, items, conns, port_side, {"spacing": spacing})
	_centre = layout.get("centre", Vector2.ZERO) as Vector2
	_extent = maxf(float(layout.get("extent", 1.0)), 1.0)
	_dist = _extent * GraphSchema3D.EYE_EXTENTS
	_proj_dirty = true


func _refresh_proj() -> void:
	if not _proj_dirty:
		return
	_proj_dirty = false
	_proj.clear()
	var pos: Dictionary = layout.get("pos", {})
	for iid in pos:
		var r := GraphSchema3D.rotate(pos[iid] as Vector3, yaw, pitch)
		var f := GraphSchema3D.persp(r.z, _dist)
		_proj[iid] = [Vector2(r.x, r.y) * f, r.z, f]


# ---------------------------------------------------------------------------
# Dragging a card over its shell
# ---------------------------------------------------------------------------

## id -> the value being dragged (Vector3 dir / Vector2(theta, phi)). While
## a drag is on the layout is not recomputed under it.
var _drag_ovr: Dictionary = {}


func can_drag(iid: String) -> bool:
	return has(iid) and str((layout.get("role", {}) as Dictionary).get(iid, "")) != "middle"


## Whether the card is on the near side now (a drag keeps to that side).
func is_front(iid: String) -> bool:
	return depth_of(iid) >= 0.0


## Where on its shell the card goes for the pointer at graph point `g`
## (graph units, the canvas's own graph space). Null when it cannot move.
func shell_value_at(iid: String, g: Vector2, front: bool) -> Variant:
	if not can_drag(iid):
		return null
	var q := g - _centre
	if mode == GraphSchema3D.SPHERE:
		var r := ((layout["pos"] as Dictionary)[iid] as Vector3).length()
		# The eye ray in view space: from (0, 0, D) through (q, 0).
		var e := Vector3(0.0, 0.0, _dist)
		var d := Vector3(q.x, q.y, -_dist)
		var aa := d.dot(d)
		var bb := 2.0 * e.dot(d)
		var cc := e.dot(e) - r * r
		var disc := bb * bb - 4.0 * aa * cc
		var p: Vector3
		if disc < 0.0:
			# Past the silhouette: the closest point of the ray, onto the rim.
			p = (e + d * (-bb / (2.0 * aa))).normalized() * r
		else:
			var sq := sqrt(disc)
			var t := (-bb - sq) / (2.0 * aa) if front else (-bb + sq) / (2.0 * aa)
			p = e + d * t
		return GraphSchema3D.unrotate(p, yaw, pitch).normalized()
	var sh: Array = layout.get("shells", [])
	if sh.is_empty():
		return null
	var big_r := float((sh[0] as Dictionary)["R"])
	var a := float((sh[0] as Dictionary)["a"])
	# The torus: the (theta, phi) whose point projects nearest the pointer,
	# on the side the card started on. A coarse grid, then two finer passes.
	var best := Vector2.ZERO
	var best_s := INF
	var steps := [[0.0, TAU, 72, 0.0, TAU, 18]]
	for pass_i in 3:
		var st: Array = steps[pass_i] if pass_i < steps.size() else []
		if st.is_empty():
			break
		var t0 := float(st[0])
		var tw := float(st[1])
		var tn := int(st[2])
		var p0 := float(st[3])
		var pw := float(st[4])
		var pn := int(st[5])
		for i in tn:
			var th := t0 + tw * (float(i) + 0.5) / float(tn)
			for j in pn:
				var ph := p0 + pw * (float(j) + 0.5) / float(pn)
				var pr := GraphSchema3D.project(GraphSchema3D.torus_point(big_r, a, th, ph), yaw, pitch, _dist)
				var score := Vector2(pr.x, pr.y).distance_to(q)
				if (pr.z >= 0.0) != front:
					score += _extent * 0.25
				if score < best_s:
					best_s = score
					best = Vector2(th, ph)
		var span_t := tw / float(tn) * 2.0
		var span_p := pw / float(pn) * 2.0
		steps.append([best.x - span_t, span_t * 2.0, 12, best.y - span_p, span_p * 2.0, 8])
	return Vector2(wrapf(best.x, -PI, PI), wrapf(best.y, -PI, PI))


## Show a card at a dragged place now (before it is written to the model).
func set_drag_value(iid: String, v: Variant) -> void:
	if v == null or not has(iid):
		return
	_drag_ovr[iid] = v
	var pos: Dictionary = layout["pos"]
	if v is Vector3:
		pos[iid] = (v as Vector3) * (pos[iid] as Vector3).length()
	elif v is Vector2:
		var sd: Dictionary = (layout["shells"] as Array)[0]
		pos[iid] = GraphSchema3D.torus_point(float(sd["R"]), float(sd["a"]), (v as Vector2).x, (v as Vector2).y)
	_proj_dirty = true


## The drag is over: the layout is worked out again from the model next time.
func end_drag() -> void:
	_drag_ovr.clear()
	_key = ""
	_proj_dirty = true


## A card's place in graph units (screen rect at zoom 1 about the graph
## origin), eased like `rect_for`: what the scope transitions map onto.
func graph_rect(iid: String, flat_tl: Vector2, flat_size: Vector2) -> Rect2:
	return rect_for(iid, flat_tl, flat_size, Vector2.ZERO, 1.0)


func has(iid: String) -> bool:
	return active() and (layout.get("pos", {}) as Dictionary).has(iid)


## Depth of a node (larger = nearer); -INF when it is not in the layout.
func depth_of(iid: String) -> float:
	_refresh_proj()
	var e: Variant = _proj.get(iid)
	return float((e as Array)[1]) if e is Array else -INF


## 0 far side … 1 near side.
func nearness(z: float) -> float:
	return clampf(z / _extent * 0.5 + 0.5, 0.0, 1.0)


## The card's screen rect in 3D, eased from its flat rect while blending.
## `origin` = the screen point of graph (0, 0); `zoom` = the canvas zoom.
func rect_for(iid: String, flat_tl: Vector2, flat_size: Vector2, origin: Vector2, zoom: float) -> Rect2:
	_refresh_proj()
	var e: Variant = _proj.get(iid)
	if not (e is Array):
		return Rect2(flat_tl, flat_size)
	var ea: Array = e
	var s := clampf(float(ea[2]), SCALE_MIN, SCALE_MAX)
	var sz := flat_size * s
	var c := origin + (_centre + (ea[0] as Vector2)) * zoom
	var r3 := Rect2(c - sz * 0.5, sz)
	var b := eased_blend()
	if b >= 1.0:
		return r3
	return Rect2(flat_tl.lerp(r3.position, b), flat_size.lerp(sz, b))


func _scr(p: Vector3, origin: Vector2, zoom: float) -> Vector3:
	var r := GraphSchema3D.rotate(p, yaw, pitch)
	var f := GraphSchema3D.persp(r.z, _dist)
	return Vector3(origin.x + (_centre.x + r.x * f) * zoom, origin.y + (_centre.y + r.y * f) * zoom, r.z)


## A ring of 3D points as one polyline, each vertex faded by its depth.
func _stroke(ci: CanvasItem, pts: PackedVector3Array, col: Color, width: float,
		origin: Vector2, zoom: float, closed: bool) -> void:
	var n := pts.size()
	if n < 2:
		return
	var p2 := PackedVector2Array()
	var cs := PackedColorArray()
	for i in n + (1 if closed else 0):
		var s := _scr(pts[i % n], origin, zoom)
		p2.append(Vector2(s.x, s.y))
		var near := nearness(s.z)
		cs.append(Color(col.r, col.g, col.b, col.a * (0.18 + 0.82 * near * near)))
	ci.draw_polyline_colors(p2, cs, width, true)


func _circle(u: Vector3, v: Vector3, c: Vector3, r: float, n: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in n:
		var a := TAU * float(i) / float(n)
		out.append(c + (u * cos(a) + v * sin(a)) * r)
	return out


## Under the cards: the membrane and nucleus (or the torus), and each
## system's name where its machines sit.
func draw_backdrop(ci: CanvasItem, origin: Vector2, zoom: float, font: Font) -> void:
	if not active():
		return
	var b := eased_blend()
	if b <= 0.01:
		return
	var w := clampf(1.2 * zoom, 0.8, 2.2)
	for sh in (layout.get("shells", []) as Array):
		var sd: Dictionary = sh
		if str(sd.get("kind", "")) == "sphere":
			var r := float(sd.get("r", 100.0))
			var nucleus := str(sd.get("role", "")) == "nucleus"
			var col := C_NUCLEUS if nucleus else C_MEMBRANE
			# The silhouette, filled faintly: a sphere seen in perspective
			# is a disc of r·d/√(d² − r²).
			var cs := _scr(Vector3.ZERO, origin, zoom)
			var sil := r * _dist / sqrt(maxf(_dist * _dist - r * r, 1.0)) * zoom
			GraphFastDraw.disc(ci, Vector2(cs.x, cs.y), sil,
				Color(col.r, col.g, col.b, (0.10 if nucleus else 0.05) * b))
			ci.draw_arc(Vector2(cs.x, cs.y), sil, 0.0, TAU, 96,
				Color(col.r, col.g, col.b, (0.45 if nucleus else 0.38) * b), w * 1.4, true)
			var a_col := Color(col.r, col.g, col.b, (0.30 if nucleus else 0.22) * b)
			var lats := [-0.5, 0.0, 0.5] if nucleus else [-0.78, -0.5, -0.17, 0.17, 0.5, 0.78]
			for la in lats:
				var y := float(la) * r
				var rr := sqrt(maxf(r * r - y * y, 0.0))
				_stroke(ci, _circle(Vector3.RIGHT, Vector3.BACK, Vector3(0, y, 0), rr, 56),
					a_col, w, origin, zoom, true)
			var mers := 4 if nucleus else 8
			for k in mers:
				var t := PI * float(k) / float(mers)
				_stroke(ci, _circle(Vector3(cos(t), 0, sin(t)), Vector3.UP, Vector3.ZERO, r, 56),
					a_col, w, origin, zoom, true)
		elif str(sd.get("kind", "")) == "torus":
			var big_r := float(sd.get("R", 100.0))
			var a := float(sd.get("a", 30.0))
			_draw_torus_skin(ci, big_r, a, origin, zoom, b)
			var col2 := Color(C_TORUS.r, C_TORUS.g, C_TORUS.b, 0.42 * b)
			for k2 in 28:
				var th := TAU * float(k2) / 28.0
				var pts := PackedVector3Array()
				for j in 24:
					pts.append(GraphSchema3D.torus_point(big_r, a, th, TAU * float(j) / 24.0))
				_stroke(ci, pts, col2, w, origin, zoom, true)
			for ph in [0.0, PI * 0.5, PI, PI * 1.5]:
				var pts2 := PackedVector3Array()
				for j2 in 96:
					pts2.append(GraphSchema3D.torus_point(big_r, a, TAU * float(j2) / 96.0, float(ph)))
				var strong := float(ph) == 0.0 or float(ph) == PI
				_stroke(ci, pts2, Color(col2.r, col2.g, col2.b, col2.a * (1.6 if strong else 1.0)),
					w * (1.3 if strong else 1.0), origin, zoom, true)
	_draw_group_titles(ci, origin, zoom, font, b)


## The tube as glass: one quad per patch, more opaque where the surface
## turns away from the eye (a rim light), so the torus reads as a body
## behind the cards. Cheap: 4-point primitives, no triangulation.
const SKIN_U := 40
const SKIN_V := 16


func _draw_torus_skin(ci: CanvasItem, big_r: float, a: float, origin: Vector2, zoom: float, b: float) -> void:
	var pts := []
	var nrm := []
	for i in SKIN_U:
		var th := TAU * float(i) / float(SKIN_U)
		var row_p := []
		var row_n := []
		for j in SKIN_V:
			var ph := TAU * float(j) / float(SKIN_V)
			var s := _scr(GraphSchema3D.torus_point(big_r, a, th, ph), origin, zoom)
			row_p.append(Vector2(s.x, s.y))
			# Surface normal: from the tube's core circle out through the point.
			var core := GraphSchema3D.torus_point(big_r, 0.0, th, 0.0)
			var n := (GraphSchema3D.torus_point(big_r, a, th, ph) - core).normalized()
			row_n.append(GraphSchema3D.rotate(n, yaw, pitch).z)
		pts.append(row_p)
		nrm.append(row_n)
	var quad := PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
	var cols := PackedColorArray([Color(), Color(), Color(), Color()])
	for i2 in SKIN_U:
		var i3 := (i2 + 1) % SKIN_U
		for j2 in SKIN_V:
			var j3 := (j2 + 1) % SKIN_V
			var idx := [[i2, j2], [i3, j2], [i3, j3], [i2, j3]]
			for k in 4:
				var ii: int = idx[k][0]
				var jj: int = idx[k][1]
				quad[k] = (pts[ii] as Array)[jj]
				var facing := absf(float((nrm[ii] as Array)[jj]))
				var rim := pow(1.0 - facing, 2.2)
				cols[k] = Color(C_TORUS.r, C_TORUS.g, C_TORUS.b, (0.015 + 0.16 * rim) * b)
			ci.draw_primitive(quad, cols, PackedVector2Array())


func _draw_group_titles(ci: CanvasItem, origin: Vector2, zoom: float, font: Font, b: float) -> void:
	if font == null:
		return
	var pos: Dictionary = layout.get("pos", {})
	var torus := mode == GraphSchema3D.TORUS
	var sh: Array = layout.get("shells", [])
	var fs := clampi(int(15.0 * zoom), 10, 22)
	for g in (layout.get("groups", []) as Array):
		var gd: Dictionary = g
		var sum := Vector3.ZERO
		var n := 0
		for iid in (gd.get("ids", []) as Array):
			if pos.has(iid):
				sum += pos[iid] as Vector3
				n += 1
		if n == 0:
			continue
		var anchor: Vector3
		if torus and not sh.is_empty():
			var sd: Dictionary = sh[0]
			var th := atan2(-sum.z, sum.x)
			anchor = GraphSchema3D.torus_point(float(sd["R"]), float(sd["a"]) * 1.9, th, 0.0)
		else:
			var dir := sum.normalized() if sum.length() > 1e-3 else Vector3.UP
			anchor = dir * _extent * 1.06
		var s := _scr(anchor, origin, zoom)
		var near := nearness(s.z)
		var col: Color = GraphSchemaLayout.COLORS.get(str(gd.get("domain", "")), Color.WHITE)
		var title := str(gd.get("title", ""))
		var tw := font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var alpha := (0.45 + 0.55 * near) * b
		var pr := Rect2(Vector2(s.x - tw * 0.5 - 8.0, s.y - float(fs) * 0.62 - 2.0), Vector2(tw + 16.0, float(fs) + 8.0))
		GraphFastDraw.rrect(ci, pr, pr.size.y * 0.5, Color(0.05, 0.08, 0.15, 0.86 * alpha))
		ci.draw_string(font, Vector2(s.x - tw * 0.5, s.y + float(fs) * 0.35), title,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(col.lightened(0.18), alpha))


## The wires as curves through the inside, under the cards. `info(conn)`
## returns {color, width, flowing, reverse, dim}.
func draw_connectors(ci: CanvasItem, conns: Array, origin: Vector2, zoom: float,
		info: Callable, flow_phase: float) -> bool:
	if not active():
		return false
	var b := eased_blend()
	if b <= 0.01:
		return false
	var pos: Dictionary = layout.get("pos", {})
	var torus := mode == GraphSchema3D.TORUS
	var big_r := 0.0
	if torus and not (layout.get("shells", []) as Array).is_empty():
		big_r = float(((layout["shells"] as Array)[0] as Dictionary).get("R", 0.0))
	var any_flow := false
	for c in conns:
		var cd: Dictionary = c
		var sid := str(cd.get("source_item_id", ""))
		var tid := str(cd.get("target_item_id", ""))
		if not pos.has(sid) or not pos.has(tid) or sid == tid:
			continue
		var d: Dictionary = info.call(cd)
		var col: Color = d.get("color", Color.WHITE)
		var pts := GraphSchema3D.connector_points_torus(pos[sid] as Vector3, pos[tid] as Vector3, big_r, 0.8, 18) 			if torus else GraphSchema3D.connector_points(pos[sid] as Vector3, pos[tid] as Vector3, 0.62, 18)
		var p2 := PackedVector2Array()
		var cs := PackedColorArray()
		var depth_sum := 0.0
		for p in pts:
			var s := _scr(p, origin, zoom)
			p2.append(Vector2(s.x, s.y))
			var near := nearness(s.z)
			depth_sum += near
			cs.append(Color(col.r, col.g, col.b, col.a * (0.22 + 0.78 * near) * b))
		var mean_near := depth_sum / float(pts.size())
		var width := maxf(1.0, float(d.get("width", 2.0)) * (0.65 + 0.6 * mean_near))
		ci.draw_polyline_colors(p2, cs, width, true)
		if bool(d.get("flowing", false)):
			any_flow = true
			var rev := bool(d.get("reverse", false))
			var off := float(absi(hash(str(cd.get("id", "")))) % 997) / 997.0
			for k in 3:
				var t := fposmod(flow_phase / TAU * 0.6 + off + float(k) / 3.0, 1.0)
				if rev:
					t = 1.0 - t
				var fi := t * float(p2.size() - 1)
				var i0 := int(floor(fi))
				var i1 := mini(i0 + 1, p2.size() - 1)
				var bp := p2[i0].lerp(p2[i1], fi - float(i0))
				var bc := cs[i0]
				GraphFastDraw.disc(ci, bp, width * 1.3,
					Color(minf(col.r * 1.3, 1.0), minf(col.g * 1.3, 1.0), minf(col.b * 1.3, 1.0), bc.a))
	return any_flow


## How far a card is faded toward the canvas colour (far side of the shell).
func fog_for(iid: String) -> float:
	var z := depth_of(iid)
	if z == -INF:
		return 0.0
	var far := 1.0 - nearness(z)
	return pow(far, 1.3) * FOG_MAX * eased_blend()


## Screen point of the arrangement's centre and the zoom that holds it all
## in `canvas_size` (for the view's fit on entering).
func fit_zoom(canvas_size: Vector2) -> float:
	var span := _extent * 2.3
	return minf(canvas_size.x, canvas_size.y) / maxf(span, 1.0)


func centre() -> Vector2:
	return _centre


## Eye distance from the arrangement's centre (graph pixels).
func camera_dist() -> float:
	return _dist


## A node's place in the 3D arrangement (graph pixels, relative to the
## centre). Vector3.ZERO when it is not on the shell.
func node_pos(iid: String) -> Vector3:
	var pos: Dictionary = layout.get("pos", {})
	var v: Variant = pos.get(iid, null)
	if v is Vector3:
		return v as Vector3
	return Vector3.ZERO
