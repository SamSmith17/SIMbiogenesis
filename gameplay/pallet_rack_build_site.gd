class_name PalletRackBuildSite
extends Node3D
## A crew building a placed pallet rack (PalletRackBuildPlan, the Mars build
## lab's sequence): material piles on pallets in front of the rack, a crew of
## stick figures carrying uprights, beams and bundles from them, two raising
## each frame and holding it while two more seat the beams, then joists,
## sheets, steps, walls and the design's elements going in, and a visitor
## climbing onto the new deck at the end.
##
## A rehearsal is ONE record on the prop, `build_run = {start_h, crew_n}`
## (LinkageBuildSite's pattern): build time = (clock − start_h) in seconds, so
## the build follows the world clock at any speed, scrubs backwards, and is
## where it was after a reload. Nothing here integrates.
##
## What it draws: the rack as BUILD UNITS (PalletRackBuilder.build_units_node)
## posed every frame from PalletRackBuildPlan.state_at, while the prop's own
## mesh (ModelRoot) is hidden; the crew as hi-detail NpcSimpleFigures playing
## the job's clip (NpcAnimClip) with hands IK'd onto the FabContextRig the clip
## was authored against (the impact driver when fixing, the beam sockets when
## carrying, seating and laying). After the last job and a minute's linger the
## pieces go and the rack's own mesh comes back.
##
## Coordinates: this node takes ModelRoot's local transform every frame, so its
## children live in the rack's build frame (metres, grounded).

const NODE_NAME := "RackBuildSite"
const RECORD_KEY := "build_run"
## The build lab's crew: two frames held at once + two seating the beams.
const DEFAULT_CREW := 6
const MIN_CREW := 6
const LINGER_S := 60.0
const CULL_M := 160.0
const PHASE_SPREAD_S := 0.731

## sig -> {tl, units}. A prop rebuild re-attaches the site; the plan is reused.
static var _plan_cache: Dictionary = {}

var _prop: PlacedProp = null
var _model: Node3D = null
var _rec: Dictionary = {}
var _run: Dictionary = {}
var _tl: Dictionary = {}
var _main: Node = null
var _units_root: Node3D = null
var _unit_nodes: Dictionary = {}     # unit id -> Node3D
var _unit_sig: Dictionary = {}       # unit id -> last applied pose hash
var _crew: Array = []                # [{fig, tools: {id: Node3D}, ground: {}}]
var _rigs: Dictionary = {}
var _clips: Dictionary = {}
var _piles: Node3D = null
## The ground under the yard and the bundles set down (_ground_local's cache).
var _yard_ground := {"ground": {}}
## Fitted ground planes under resting stacks and bundles (_plane_at).
var _planes := {}
const PLANE_R := 0.8
const PLANE_MAX_DEG := 25.0
var _fx_t := 0.0
var _finished := false
var _disposed := false
var _last_state: Dictionary = {}
var _label: Label3D = null
var _label_ms := 0
## The rack's own collision is off while it is being built (nothing stands there
## yet); the record's setting comes back after.
var _collide := true
var _coll_ms := 0


# ---------------------------------------------------------------------------
# Static API (the rack builder, the harness)
# ---------------------------------------------------------------------------

## Start (or restart) a rehearsal on a placed pallet rack: the build begins at
## `start_h` (absolute sim hours; NAN = now). Returns false for other props.
static func start_rehearsal(main: Node, prop_id: String, crew_n: int = DEFAULT_CREW, start_h: float = NAN) -> bool:
	var rec := PlacedPropService.get_prop_record(main, prop_id)
	if rec.is_empty() or str(rec.get("model_id", "")) != PalletRackBuilder.MODEL_ID:
		return false
	if is_nan(start_h):
		start_h = float(main.call("get_absolute_hours")) if main.has_method("get_absolute_hours") else 0.0
	var run := {"start_h": start_h, "crew_n": maxi(MIN_CREW, crew_n)}
	if not PlacedPropService.update_prop_record(main, prop_id, {RECORD_KEY: run}):
		return false
	var prop := PlacedPropService._find_prop_node(main, prop_id) as PlacedProp
	if prop == null:
		return true
	var old := prop.get_node_or_null(NODE_NAME)
	if old != null:
		(old as PalletRackBuildSite).dispose()
		prop.remove_child(old)
		old.queue_free()
	attach(prop, PlacedPropService.get_prop_record(main, prop_id))
	return true


## End the rehearsal: the record goes, the rack stands as it did before.
static func clear_rehearsal(main: Node, prop_id: String) -> void:
	PlacedPropService.update_prop_record(main, prop_id, {RECORD_KEY: null})
	var prop := PlacedPropService._find_prop_node(main, prop_id)
	if prop == null:
		return
	var site := prop.get_node_or_null(NODE_NAME)
	if site != null:
		(site as PalletRackBuildSite).dispose()
		prop.remove_child(site)
		site.queue_free()


## PlacedPropRuntime's hook: a pallet rack with a build_run gets a site.
static func attach(prop: PlacedProp, rec: Dictionary) -> void:
	if str(rec.get("model_id", "")) != PalletRackBuilder.MODEL_ID:
		return
	if not (rec.get(RECORD_KEY) is Dictionary):
		return
	var site := PalletRackBuildSite.new()
	site.name = NODE_NAME
	site.configure(rec)
	prop.add_child(site)


static func site_for(main: Node, prop_id: String) -> PalletRackBuildSite:
	var prop := PlacedPropService._find_prop_node(main, prop_id)
	return prop.get_node_or_null(NODE_NAME) as PalletRackBuildSite if prop != null else null


## The plan for a rack + crew, cached by the spec.
static func plan_for(spec: Dictionary, crew_n: int, units: Dictionary = {}, yard_side: String = "-z") -> Dictionary:
	var s := PalletRackBuilder.resolve_spec(spec)
	s.erase("_stepped_cells")
	s.erase("_open_cells")
	var sig := "%d|%d|%s" % [hash(JSON.stringify(s, "", true)), crew_n, yard_side]
	if _plan_cache.has(sig):
		return _plan_cache[sig]
	var tl := PalletRackBuildPlan.plan(s, crew_n, units, {"yard_side": yard_side})
	if _plan_cache.size() > 6:
		_plan_cache.clear()
	_plan_cache[sig] = tl
	return tl


static func _rec_spec(rec: Dictionary) -> Dictionary:
	var spec: Dictionary = rec.get("rack_spec", {}) as Dictionary
	if spec.is_empty() and rec.has("record_extra"):
		spec = (rec.get("record_extra", {}) as Dictionary).get("rack_spec", {}) as Dictionary
	return spec


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func configure(rec: Dictionary) -> void:
	_rec = rec.duplicate(true)
	_collide = bool(rec.get("collision_enabled", true))
	_run = (rec.get(RECORD_KEY, {}) as Dictionary).duplicate(true)


func _ready() -> void:
	_prop = get_parent() as PlacedProp
	_model = _prop.get_node_or_null("ModelRoot") as Node3D if _prop != null else null
	if _model == null or _run.is_empty():
		set_process(false)
		return
	_main = get_tree().current_scene
	var spec := _rec_spec(_rec)
	_units_root = PalletRackBuilder.build_units_node(spec)
	add_child(_units_root)
	for c in _units_root.get_children():
		_unit_nodes[str(c.get_meta("unit_id", ""))] = c
	transform = _model.transform
	# The yard goes on the flattest side of the rack.
	var units: Dictionary = _units_root.get_meta("units", {})
	var side := PalletRackBuildPlan.yard_side(PalletRackBuildPlan.units_bounds(units), _ground_raw)
	_tl = plan_for(spec, int(_run.get("crew_n", DEFAULT_CREW)), units, side)
	_model.visible = false
	_build_piles()
	_build_crew()
	_build_label()
	_update(0.0)


func _exit_tree() -> void:
	if not _disposed and is_instance_valid(_model):
		_model.visible = true
	_restore_collision()


func _restore_collision() -> void:
	if is_instance_valid(_prop):
		_prop.set_collision_enabled(_collide)


## Leave the rack as it stands without a build.
func dispose() -> void:
	_disposed = true
	set_process(false)
	if is_instance_valid(_model):
		_model.visible = true
	if is_instance_valid(_units_root):
		_units_root.visible = false
	_restore_collision()


func is_running() -> bool:
	return not _disposed and not _finished and not _tl.is_empty()


func build_time() -> float:
	if _main == null or not _main.has_method("get_absolute_hours"):
		return 0.0
	return (float(_main.call("get_absolute_hours")) - float(_run.get("start_h", 0.0))) * 3600.0


func timeline() -> Dictionary:
	return _tl


func last_state() -> Dictionary:
	return _last_state


func crew_figures() -> Array:
	return _crew.map(func(c): return c["fig"])


func unit_node(id: String) -> Node3D:
	return _unit_nodes.get(id) as Node3D


## "Building · 41 % · crew 6 · 9 min left · seat beam …"
func progress_line() -> String:
	if _tl.is_empty():
		return "No build plan"
	var t := build_time()
	var mk := float(_tl["makespan"])
	if not (_tl["blocked"] as Array).is_empty():
		return "The crew can't finish this rack (%d jobs can't start)" % (_tl["blocked"] as Array).size()
	if t < 0.0:
		return "Rehearsal starts in %s" % _fmt_s(-t)
	if t >= mk:
		return "Built in %s by a crew of %d" % [_fmt_s(mk), int(_tl["crew"])]
	return "Building · %d %% · crew %d · %s left · %s" % [int(100.0 * t / maxf(mk, 1.0)), int(_tl["crew"]),
		_fmt_s(mk - t), str(_last_state.get("stage", ""))]


static func _fmt_s(s: float) -> String:
	var n := int(s)
	return "%d h %02d min" % [n / 3600, (n % 3600) / 60] if n >= 3600 else "%d min" % maxi(1, n / 60)


# ---------------------------------------------------------------------------
# Per frame
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if _disposed or not is_instance_valid(_model):
		set_process(false)
		return
	var r := SimFxRate.rate(_main, SimFxRate.SYS_NPC) if _main != null else 1.0
	_fx_t += delta * r
	_update(delta)


func _update(delta: float) -> void:
	transform = _model.transform
	var t := build_time()
	var mk := float(_tl["makespan"])
	if t > mk + LINGER_S or t < -5.0:
		if not _finished:
			_finished = true
			_model.visible = true
			_units_root.visible = false
			_piles.visible = false
			_label.visible = false
			_restore_collision()
			for c in _crew:
				(c["fig"] as Node3D).visible = false
				_hide_tools(c)
		return
	if _finished:
		_finished = false
		_model.visible = false
		_units_root.visible = true
		_piles.visible = true
		_label.visible = true
		_unit_sig.clear()
		_coll_ms = 0
	# Re-asserted: the prop may bake its collision after the site attached.
	if Time.get_ticks_msec() - _coll_ms > 1000:
		_coll_ms = Time.get_ticks_msec()
		_prop.set_collision_enabled(false)
	var st := PalletRackBuildPlan.state_at(_tl, t)
	_last_state = st
	_apply_units(st["units"])
	_apply_crew(st, delta)
	if Time.get_ticks_msec() - _label_ms > 500:
		_label_ms = Time.get_ticks_msec()
		_label.text = progress_line()


func _apply_units(units: Dictionary) -> void:
	for id in units:
		var n: Node3D = _unit_nodes.get(id)
		if n == null:
			continue
		var s: Dictionary = units[id]
		var xf: Transform3D = s["xf"]
		# On the ground (yard, carried, set down): on the terrain there.
		var g := float(s.get("g", 0.0))
		if g > 0.0:
			xf = _ground_xf(g, float(s.get("rest", g)), s.get("gxz", Vector2.ZERO)) * xf
		var h := hash([(xf.origin * 200.0).round(), (xf.basis.x * 200.0).round(), (xf.basis.y * 200.0).round(),
			bool(s["visible"])])
		if int(_unit_sig.get(id, 0)) == h:
			continue
		_unit_sig[id] = h
		n.transform = xf
		n.visible = bool(s["visible"])


func _apply_crew(st: Dictionary, delta: float) -> void:
	var cam := get_viewport().get_camera_3d() if get_viewport() != null else null
	var far := cam != null and cam.global_position.distance_to(global_position) > CULL_M + float(_tl["radius_m"])
	var rate := SimFxRate.rate(_main, SimFxRate.SYS_NPC) if _main != null else 1.0
	var ws: Array = st["workers"]
	for i in mini(ws.size(), _crew.size()):
		var c: Dictionary = _crew[i]
		var fig: NpcSimpleFigure = c["fig"]
		fig.visible = not far
		if far:
			_hide_tools(c)
			continue
		_pose_worker(c, ws[i], rate, delta)


func _pose_worker(c: Dictionary, w: Dictionary, rate: float, delta: float) -> void:
	var fig: NpcSimpleFigure = c["fig"]
	var pos: Vector3 = w["pos"]
	var up := pos.y
	pos.y = _ground_local(c, pos) + up
	var face: Vector3 = w["face"]
	var dir := Vector3(face.x - pos.x, 0.0, face.z - pos.z)
	var basis := fig.transform.basis
	if dir.length() > 0.05:
		basis = Basis.looking_at(-dir.normalized(), Vector3.UP)
	fig.transform = Transform3D(basis, pos)
	_hide_tools(c)
	var dt := maxf(delta, 1.0 / 120.0)
	var act := str(w["activity"])
	if act in ["walk", "look", "idle", "wait"] or str(w["clip"]).is_empty():
		fig.clear_clip()
		fig.set_hand_target(0, null)
		fig.set_hand_target(1, null)
		fig.pose("walk" if act == "walk" else "idle", maxf(rate, 0.3) if act == "walk" else 1.0, dt)
		return
	var clip := _clip(str(w["clip"]))
	if clip == null:
		fig.clear_clip()
		fig.pose("idle", 1.0, dt)
		return
	var phase := fposmod(_fx_t + float(w["id"]) * PHASE_SPREAD_S, clip.length_s) if clip.loop \
		else float(w["u"]) * clip.length_s
	var rig_kind := str(w["rig"])
	if rig_kind.is_empty():
		_drive(fig, clip, phase, Transform3D(), {}, dt)
		return
	var rig := _rig(rig_kind)
	var tp := FabContextRig.tool_at(rig, phase / maxf(clip.length_s, 0.01))
	var xf: Transform3D = fig.transform * (tp["xform"] as Transform3D)
	var tool_id := str(rig.get("tool_id", ""))
	var socks: Dictionary
	if tool_id.is_empty():
		socks = FabContextRig.beam_sockets()
	else:
		var tool := _tool(c, tool_id)
		tool.visible = true
		tool.transform = xf
		FabToolCatalog.set_spin(tool, float(tp["spin"]))
		socks = tool.get_meta("sockets", {})
	_drive(fig, clip, phase, xf, socks, dt)


func _drive(fig: NpcSimpleFigure, clip: NpcAnimClip, t: float, tool_xf: Transform3D, socks: Dictionary, dt: float) -> void:
	fig.set_clip(clip, t, 1.0)
	for i in 2:
		var sock := str(clip.ik.get("hand_r" if i == 0 else "hand_l", "none"))
		if sock != "none" and socks.get(sock) is Transform3D:
			fig.set_hand_target(i, global_transform * tool_xf * (socks[sock] as Transform3D))
		else:
			fig.set_hand_target(i, null)
	fig.pose("idle", 0.0, dt)


func _hide_tools(c: Dictionary) -> void:
	for id in c["tools"]:
		(c["tools"][id] as Node3D).visible = false


func _ground_local(c: Dictionary, pos: Vector3) -> float:
	var key := Vector2i(roundi(pos.x * 2.0), roundi(pos.z * 2.0))
	var cache: Dictionary = c["ground"]
	if cache.has(key):
		return cache[key]
	var y := 0.0
	if _main != null and is_inside_tree():
		var wp := global_transform * Vector3(pos.x, 0.0, pos.z)
		var gy := TerrainSurfaceQuery.ground_height_at(_main, wp.x, wp.z)
		if is_finite(gy):
			y = clampf((global_transform.affine_inverse() * Vector3(wp.x, gy, wp.z)).y, -12.0, 12.0)
	if cache.size() > 512:
		cache.clear()
	cache[key] = y
	return y


## The ground plane under a resting stack or bundle at `xz`: fitted (least
## squares) to the ground over its footprint (the plan's rests: stacks and
## set-down spots; ±PLANE_R for anything else), the tilt capped at
## PLANE_MAX_DEG (past that a real yard is levelled up on blocks), then raised
## onto the highest point under it, so a stack lies on the bumps and never
## sinks into the hill. Cached per point: the resting points are few.
func _plane_at(xz: Vector2) -> Dictionary:
	if _planes.has(xz):
		return _planes[xz]
	var half: Vector2 = (_tl.get("rests", {}) as Dictionary).get(xz, Vector2(PLANE_R, PLANE_R))
	half = half.max(Vector2(0.3, 0.3))
	var pts: Array = []
	for i in 3:
		for k in 3:
			var o := Vector2(half.x * (i - 1), half.y * (k - 1))
			pts.append(Vector3(o.x, _ground_raw(xz + o), o.y))
	var y0 := 0.0
	var sxx := 0.0
	var szz := 0.0
	var sxy := 0.0
	var szy := 0.0
	for q in pts:
		y0 += (q as Vector3).y
	y0 /= float(pts.size())
	for q in pts:
		var v := q as Vector3
		sxx += v.x * v.x
		szz += v.z * v.z
		sxy += v.x * (v.y - y0)
		szy += v.z * (v.y - y0)
	# The samples are a symmetric grid, so x and z decouple.
	var dx := sxy / maxf(sxx, 1e-6)
	var dz := szy / maxf(szz, 1e-6)
	var n := Vector3(-dx, 1.0, -dz).normalized()
	var ang := n.angle_to(Vector3.UP)
	var cap := deg_to_rad(PLANE_MAX_DEG)
	if ang > cap:
		n = Vector3.UP.slerp(n, cap / ang).normalized()
	# Onto the highest point under it: the plane's height over each sample.
	var lift := -INF
	for q in pts:
		var v := q as Vector3
		lift = maxf(lift, v.y - (y0 - (n.x * v.x + n.z * v.z) / n.y))
	if _planes.size() > 1024:
		_planes.clear()
	_planes[xz] = {"y": y0 + lift, "n": n}
	return _planes[xz]


## Site-frame ground height at xz, uncached (0 off the terrain).
func _ground_raw(xz: Vector2) -> float:
	if _main == null or not is_inside_tree():
		return 0.0
	var wp := global_transform * Vector3(xz.x, 0.0, xz.y)
	var gy := TerrainSurfaceQuery.ground_height_at(_main, wp.x, wp.z)
	if not is_finite(gy):
		return 0.0
	return clampf((global_transform.affine_inverse() * Vector3(wp.x, gy, wp.z)).y, -12.0, 12.0)


## A piece posed on flat ground at the rack's base, moved onto the terrain at
## xz: raised by g x the ground there, tilted to its slope by rest.
func _ground_xf(g: float, rest: float, xz: Vector2) -> Transform3D:
	var y := 0.0
	var bas := Basis()
	if rest > 0.0:
		var pl := _plane_at(xz)
		y = float(pl["y"])
		bas = Basis(Quaternion.IDENTITY.slerp(Quaternion(Vector3.UP, pl["n"]), rest))
	else:
		y = _ground_local(_yard_ground, Vector3(xz.x, 0.0, xz.y))
	var piv := Vector3(xz.x, 0.0, xz.y)
	return Transform3D(bas, piv + Vector3(0.0, g * y, 0.0)) * Transform3D(Basis(), -piv)


func _rig(kind: String) -> Dictionary:
	if not _rigs.has(kind):
		_rigs[kind] = FabContextRig.setup(kind)
	return _rigs[kind]


func _clip(id: String) -> NpcAnimClip:
	if id.is_empty():
		return null
	if not _clips.has(id):
		_clips[id] = NpcAnimClip.load_clip(id)
	return _clips[id]


func _tool(c: Dictionary, id: String) -> Node3D:
	var tools: Dictionary = c["tools"]
	if not tools.has(id):
		var t := FabToolCatalog.build(id)
		add_child(t)
		tools[id] = t
	return tools[id]


# ---------------------------------------------------------------------------
# Building the site
# ---------------------------------------------------------------------------

func _build_crew() -> void:
	var n := int(_tl.get("crew", DEFAULT_CREW))
	for i in n:
		var fig := NpcSimpleFigure.new()
		fig.hi_detail = true
		fig.name = "Builder%d" % i
		add_child(fig)
		var key := "%s_rack_builder_%d" % [_prop.prop_id, i]
		fig.setup(key, Color.from_hsv(NpcHash.unit01(key, "tint"), 0.45, 0.9))
		fig.set_mocap_allowed(false)
		_crew.append({"fig": fig, "tools": {}, "ground": {}})


## What the crew is doing, over the rack (seen through it, like a map pin).
func _build_label() -> void:
	_label = Label3D.new()
	_label.name = "Progress"
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.fixed_size = true
	_label.pixel_size = 0.0007
	_label.font_size = 26
	_label.outline_size = 8
	_label.modulate = Color(1.0, 0.93, 0.72)
	var b: AABB = _tl.get("bounds", AABB())
	_label.position = Vector3(b.get_center().x, b.end.y + 1.2, b.get_center().z)
	add_child(_label)


## Timber bearers across the underside of every stack in the yard, on the
## ground under the stack.
func _build_piles() -> void:
	_piles = Node3D.new()
	_piles.name = "Piles"
	add_child(_piles)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.36, 0.27, 0.18)
	mat.roughness = 0.9
	var h := PalletRackBuildPlan.DUNNAGE_H
	for st in _tl.get("stacks", []):
		var c: Vector3 = st["centre"]
		var sz: Vector3 = st["size"]
		# The same ground the stack's pieces lie on (unit_pose's gxz = centre),
		# along the stack's own length.
		var gxf := _ground_xf(1.0, 1.0, Vector2(c.x, c.z)) * Transform3D(st.get("basis", Basis()), c)
		var n := clampi(ceili(sz.z / 1.3) + 1, 2, 5)
		var bm := BoxMesh.new()
		bm.size = Vector3(sz.x + 0.15, h, h)
		for k in n:
			var mi := MeshInstance3D.new()
			mi.mesh = bm
			mi.material_override = mat
			var z := lerpf(sz.z * 0.5 - 0.2, -sz.z * 0.5 + 0.2, float(k) / float(n - 1))
			mi.transform = gxf * Transform3D(Basis(), Vector3(0.0, h * 0.5, z))
			mi.set_meta("stack", int(st.get("index", 0)))
			_piles.add_child(mi)
