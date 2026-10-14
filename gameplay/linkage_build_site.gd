class_name LinkageBuildSite
extends Node3D
## The fabrication swarm in the world (phase B5): a crew of stick figures
## cutting, drilling, carrying, placing, bolting, lifting and deploying a
## placed Linkage Lab structure, posed from LinkageBuildTimeline.state_at.
##
## A rehearsal is ONE record on the prop, `build_run = {start_h, crew_n}`
## (the fire's pattern): build time = (clock − start_h) in seconds, so the
## build follows the world clock at any speed, scrubs backwards, and comes
## back at the right moment after a reload. Nothing here integrates.
##
## What it drives:
##   - the structure: LinkageStructureBuilder.set_part_states (parts not yet
##     placed are hidden, parts being placed slide in, the parked top ring
##     waits beside the bottom one until the lift) and set_fold_angle (the
##     ring stays part-open while it is built, then the deploy job opens it);
##     joint hardware the builder draws its own way (simple brackets) follows
##     its JOINT's state (timeline `joints`);
##   - the crew: one hi-detail NpcSimpleFigure per worker, walking the
##     timeline's legs, playing the job's authored clip (NpcAnimClip) with
##     the job's tool moving along its op path (FabContextRig — the context
##     the clip was authored against in the animation editor) and both hands
##     IK'd onto the tool's grips; a beam on the shoulder for carry legs;
##   - saw and drill benches at the timeline's stations.
## Two modes, one record:
##   - REHEARSAL (`build_run = {start_h, crew_n}`): build time = the clock.
##     The figures are ACTORS: they eat nothing and are not on the board.
##   - LABOUR (`build_run = {mode: "labour", iid, project_id, crew_n}`, set by
##     the Lab's "Queue build for crew"): build time follows the crew's REAL
##     credited work on the Site Project — the project's labour-weighted
##     progress mapped onto the timeline's cumulative-work curve, eased so it
##     glides between ticks. A lane is drawn only while a real person is DOING
##     one of the project's chores on site; that person's own body is hidden
##     (NpcStandIns, read by NpcPopulationHost) and the lane wears their colour, so
##     the crew you see working IS the population, posed by the plan.
##
## Coordinates: this node takes the builder's (ModelRoot's) local transform
## every frame, so its children live in the structure frame the timeline is
## planned in (metres, grounded).

const NODE_NAME := "LinkageBuildSite"
const RECORD_KEY := "build_run"
const DEFAULT_CREW := 9
## A labour-mode site plans at most this many lanes (a 40-person camp still
## builds with a crew a site can hold; the rest keep their own bodies).
const MAX_LABOUR_LANES := 16
## Build seconds the crew lingers after the last job before it disperses.
const LINGER_S := 90.0
## Benches stand this far outside the ring (LinkageBuildTimeline.BENCH_GAP_M
## + a station row).
const BENCH_REACH_M := 6.0
## Past this camera distance the crew is not posed (hidden).
const CULL_M := 160.0
## Clip cycles at a bench are offset per worker so the crew is not in step.
const PHASE_SPREAD_S := 0.731

## Labour mode: how often the project is read, and how fast the drawn
## build time eases onto the labour's (seconds, real time).
const STATUS_EVERY_S := 0.25
const LABOUR_EASE_S := 1.2
## Labour mode: a worker counts as on site within this of the structure's
## edge (benches stand BENCH_GAP_M outside the ring; chore targets near them).
const SITE_MARGIN_M := 16.0

## sig -> timeline. A prop rebuild re-attaches the site; the plan is reused.
static var _plan_cache: Dictionary = {}

var _prop: PlacedProp = null
var _builder: LinkageStructureBuilder = null
var _rec: Dictionary = {}
var _run: Dictionary = {}
var _tl: Dictionary = {}
var _main: Node = null
var _crew: Array = []          # [{fig, tools: {id: Node3D}, beam: Node3D, ground: {xz: y}}]
var _benches: Node3D = null
var _rigs: Dictionary = {}     # kind -> FabContextRig
var _clips: Dictionary = {}    # id -> NpcAnimClip
var _fx_t := 0.0
var _parts_sig := -1
var _fold_deg := -999.0
var _finished := false
var _disposed := false
var _last_state: Dictionary = {}
# Labour mode.
var _labour := false
var _t_disp := 0.0
var _t_target := 0.0
var _status: Dictionary = {}
var _status_accum := 0.0
var _lane_of: Dictionary = {}     # agent id -> lane (worker index)
var _cum_t: PackedFloat64Array = PackedFloat64Array()   # job breakpoints
var _work_total := 0.0
## Labour mode with no readable project (NPCs switched off, the bridge not
## up yet, a project cleared): the site steps aside — no staging, no crew —
## and the builder is the record's / the bridge's again.
var _suspended := false
var _took_builder := false


# ---------------------------------------------------------------------------
# Static API (the prop editor, the harness)
# ---------------------------------------------------------------------------

## Start (or restart) a rehearsal on a placed linkage prop: the build begins
## at `start_h` (absolute sim hours; NAN = now). Writes the record and attaches
## the site to the live prop. Returns false when the prop is not a linkage.
static func start_rehearsal(main: Node, prop_id: String, crew_n: int = DEFAULT_CREW, start_h: float = NAN) -> bool:
	var rec := PlacedPropService.get_prop_record(main, prop_id)
	if rec.is_empty() or str(rec.get("model_id", "")) != LinkageStructureBuilder.MODEL_ID:
		return false
	if is_nan(start_h):
		start_h = float(main.call("get_absolute_hours")) if main.has_method("get_absolute_hours") else 0.0
	var run := {"start_h": start_h, "crew_n": maxi(1, crew_n)}
	if not PlacedPropService.update_prop_record(main, prop_id, {RECORD_KEY: run}):
		return false
	var prop := PlacedPropService._find_prop_node(main, prop_id) as PlacedProp
	if prop == null:
		return true
	var old := prop.get_node_or_null(NODE_NAME)
	if old != null:
		(old as LinkageBuildSite).dispose(false)
		prop.remove_child(old)
		old.queue_free()
	var rec2 := PlacedPropService.get_prop_record(main, prop_id)
	attach(prop, rec2)
	return true


## End the rehearsal: the record goes, the structure stands as it did before.
static func clear_rehearsal(main: Node, prop_id: String) -> void:
	PlacedPropService.update_prop_record(main, prop_id, {RECORD_KEY: null})
	var prop := PlacedPropService._find_prop_node(main, prop_id)
	if prop == null:
		return
	var site := prop.get_node_or_null(NODE_NAME)
	if site != null:
		(site as LinkageBuildSite).dispose(true)
		prop.remove_child(site)
		site.queue_free()


## PlacedPropRuntime's hook: a linkage prop with a build_run gets a site.
static func attach(prop: PlacedProp, rec: Dictionary) -> void:
	if str(rec.get("model_id", "")) != LinkageStructureBuilder.MODEL_ID:
		return
	if not (rec.get(RECORD_KEY) is Dictionary):
		return
	var site := LinkageBuildSite.new()
	site.name = NODE_NAME
	site.configure(rec)
	prop.add_child(site)


static func site_for(main: Node, prop_id: String) -> LinkageBuildSite:
	var prop := PlacedPropService._find_prop_node(main, prop_id)
	return prop.get_node_or_null(NODE_NAME) as LinkageBuildSite if prop != null else null


## The plan for a design + crew, cached. `steps` = the design's saved build
## steps when it carries any, else the generated sequence.
static func plan_for(p: LinkageParams, crew_n: int) -> Dictionary:
	var cfg := p.to_config()
	var sig := "%d|%d" % [hash(JSON.stringify(cfg)), crew_n]
	if _plan_cache.has(sig):
		return _plan_cache[sig]
	var bs := p.get_build_steps()
	var steps: Array = (bs.get("steps", []) as Array) if bs is Dictionary else []
	var tl := LinkageBuildTimeline.plan(p, steps, crew_n)
	if _plan_cache.size() > 8:
		_plan_cache.clear()
	_plan_cache[sig] = tl
	return tl


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func configure(rec: Dictionary) -> void:
	_rec = rec.duplicate(true)
	_run = (rec.get(RECORD_KEY, {}) as Dictionary).duplicate(true)
	_labour = str(_run.get("mode", "")) == "labour"


func _ready() -> void:
	_prop = get_parent() as PlacedProp
	_builder = _prop.get_node_or_null("ModelRoot") as LinkageStructureBuilder if _prop != null else null
	if _builder == null or _run.is_empty():
		set_process(false)
		return
	_main = get_tree().current_scene
	var p := LinkageParams.new()
	p.from_config(_builder.params.to_config())
	_tl = plan_for(p, int(_run.get("crew_n", DEFAULT_CREW)))
	transform = Transform3D(_builder.transform.basis.orthonormalized(), _builder.transform.origin)
	if _labour:
		_build_work_curve()
		_poll_status()
		_t_disp = _t_target
	_build_benches()
	_build_crew()
	_update(0.0)


func _exit_tree() -> void:
	NpcStandIns.set_for(_stand_key(), {})


func _stand_key() -> String:
	return "build_site:%s" % (_prop.prop_id if _prop != null else str(get_instance_id()))


## True while this site draws the structure (the bridge's coarse build
## reveal skips its builder).
func owns_visuals() -> bool:
	return not _disposed and not _tl.is_empty() and not _suspended


func is_labour() -> bool:
	return _labour


## Leave the structure as it was without a build: every part seated, the
## fold the record (or the design) says. `restore_fold` false when a new run
## replaces this one (it sets its own fold on its first frame).
func dispose(restore_fold: bool) -> void:
	_disposed = true
	set_process(false)
	NpcStandIns.set_for(_stand_key(), {})
	if not is_instance_valid(_builder):
		return
	_builder.clear_part_states()
	if restore_fold:
		var fold := deg_to_rad(float(_rec["linkage_fold_deg"])) if _rec.has("linkage_fold_deg") \
			else _builder.closed_angle()
		_builder.set_fold_angle(fold)
		_builder.refresh_collision_mesh()
		if _prop != null:
			_prop.setup_collision()


## True while the crew is building (the deploy runtime keeps its hands off).
func is_running() -> bool:
	return not _disposed and not _finished and not _tl.is_empty()


func build_time() -> float:
	if _labour:
		return _t_disp
	if _main == null or not _main.has_method("get_absolute_hours"):
		return 0.0
	return (float(_main.call("get_absolute_hours")) - float(_run.get("start_h", 0.0))) * 3600.0


func timeline() -> Dictionary:
	return _tl


func last_state() -> Dictionary:
	return _last_state


func crew_figures() -> Array:
	return _crew.map(func(c): return c["fig"])


## "Building · 41 % · crew 9 · 1 h 12 min left" — the prop editor's line.
func progress_line() -> String:
	if _tl.is_empty():
		return "No build plan"
	var t := build_time()
	var mk := float(_tl["makespan"])
	if _labour:
		if not bool(_status.get("found", false)):
			return "No crew project for this structure"
		if _finished:
			return "Built by the crew"
		return "Crew building · %d %% of the work · %d at work on site · step %d" % [
			int(100.0 * float(_status.get("progress", 0.0))), (_status.get("present", []) as Array).size(),
			int(_last_state.get("step", -1)) + 1]
	if t < 0.0:
		return "Rehearsal starts in %s" % _fmt_s(-t)
	if t >= mk:
		return "Built in %s by a crew of %d" % [_fmt_s(mk), int(_tl["crew"])]
	var done := int(_last_state.get("jobs_done", 0))
	return "Building · %d %% · crew %d · %s left · %d / %d jobs" % [int(100.0 * t / maxf(mk, 1.0)),
		int(_tl["crew"]), _fmt_s(mk - t), done, (_tl["jobs"] as Array).size()]


static func _fmt_s(s: float) -> String:
	var n := int(s)
	return "%d h %02d min" % [n / 3600, (n % 3600) / 60] if n >= 3600 else "%d min" % maxi(1, n / 60)


# ---------------------------------------------------------------------------
# Per frame
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if _disposed or _builder == null or not is_instance_valid(_builder):
		set_process(false)
		return
	var r := SimFxRate.rate(_main, SimFxRate.SYS_NPC) if _main != null else 1.0
	_fx_t += delta * r
	if _labour:
		_status_accum += delta
		if _status_accum >= STATUS_EVERY_S:
			_status_accum = 0.0
			_poll_status()
			if _disposed:
				return
		_t_disp += (_t_target - _t_disp) * (1.0 - exp(-maxf(delta, 0.0) / LABOUR_EASE_S))
		if absf(_t_target - _t_disp) < 0.01:
			_t_disp = _t_target
	_update(delta)


func _update(delta: float) -> void:
	transform = Transform3D(_builder.transform.basis.orthonormalized(), _builder.transform.origin)
	if _labour and not bool(_status.get("found", false)):
		if not _suspended:
			_suspended = true
			_builder.clear_part_states()
			for c in _crew:
				(c["fig"] as Node3D).visible = false
				_hide_props(c)
			if _benches != null:
				_benches.visible = false
			NpcStandIns.set_for(_stand_key(), {})
			_took_builder = false
		return
	if _labour and not _took_builder:
		# The site stages every part from here; the construction prop's coarse
		# prefix reveal and ghost were the bridge's, which now stands down.
		_took_builder = true
		_builder.set_build_progress({})
		_builder.set_ghost_alpha(1.0)
	if _suspended:
		_suspended = false
		_benches.visible = true
		_parts_sig = -1
		_fold_deg = -999.0
	var t := build_time()
	var mk := float(_tl["makespan"])
	if t > mk + LINGER_S:
		if not _finished:
			_finish()
		return
	if _finished:
		# Scrubbed back into the build.
		_finished = false
		_benches.visible = true
		_parts_sig = -1
		_fold_deg = -999.0
	var st := LinkageBuildTimeline.state_at(_tl, t)
	_last_state = st
	_apply_structure(st)
	_apply_crew(st, delta)


func _finish() -> void:
	_finished = true
	_builder.clear_part_states()
	var dep := float((_tl["fold"] as Dictionary)["deployed_deg"])
	_builder.set_fold_angle(deg_to_rad(dep))
	_builder.refresh_collision_mesh()
	_prop.setup_collision()
	_fold_deg = dep
	for c in _crew:
		(c["fig"] as Node3D).visible = false
		_hide_props(c)
	if _benches != null:
		_benches.visible = false
	NpcStandIns.set_for(_stand_key(), {})
	if _labour and _prop != null and not _prop.get_meta("under_construction", false):
		# The crew raised it: hand the deployed state to the deploy runtime's
		# own settle (persists the fold, collision, the graph array).
		var dep_rt := _prop.get_node_or_null("LinkageDeployRuntime")
		if dep_rt != null and dep_rt.has_method("_settle"):
			dep_rt.call("_settle")


func _apply_structure(st: Dictionary) -> void:
	var fold := float(st["fold_deg"])
	var fold_moved := absf(fold - _fold_deg) > 0.05
	var parts: Dictionary = st["parts"]
	var joints: Dictionary = st["joints"]
	# Only rewrite transforms when something visibly changed.
	var sig := 17
	for k in parts:
		var ps: Dictionary = parts[k]
		sig = hash([sig, k, bool(ps["visible"]), ((ps["offset"] as Vector3) * 100.0).round()])
	for k in joints:
		var js: Dictionary = joints[k]
		sig = hash([sig, k, bool(js["visible"]), ((js["offset"] as Vector3) * 100.0).round()])
	if sig == _parts_sig and not fold_moved:
		return
	_parts_sig = sig
	if fold_moved:
		# The fold first: panels and support beams exist only past their
		# visibility angles, so the keys to stage are known only after it.
		_fold_deg = fold
		_builder.set_fold_angle(deg_to_rad(fold))
	var states := {}
	var joint_of := _builder.part_joint_keys()
	for key in _builder.part_keys():
		var s = parts.get(key)
		if s == null and joint_of.has(key):
			s = joints.get(joint_of[key])
		if s is Dictionary:
			states[key] = {"visible": bool(s["visible"]), "offset": Transform3D(Basis(), s["offset"])}
	_builder.set_part_states(states)


func _apply_crew(st: Dictionary, delta: float) -> void:
	var cam := get_viewport().get_camera_3d() if get_viewport() != null else null
	var far := cam != null and cam.global_position.distance_to(global_position) > CULL_M + float(_tl["radius_m"])
	var rate := SimFxRate.rate(_main, SimFxRate.SYS_NPC) if _main != null else 1.0
	var ws: Array = st["workers"]
	var manned := _man_lanes(ws) if _labour else {}
	for i in mini(ws.size(), _crew.size()):
		var c: Dictionary = _crew[i]
		var fig: NpcSimpleFigure = c["fig"]
		var shown := not far and (not _labour or manned.has(i))
		fig.visible = shown
		if not shown:
			_hide_props(c)
			continue
		if _labour:
			var col: Color = manned[i]
			if c.get("tint") != col:
				c["tint"] = col
				fig.set_tint(col)
		_pose_worker(c, ws[i], rate, delta)


func _pose_worker(c: Dictionary, w: Dictionary, rate: float, delta: float) -> void:
	var fig: NpcSimpleFigure = c["fig"]
	var pos: Vector3 = w["pos"]
	pos.y = _ground_local(c, pos)
	var face: Vector3 = w["face"]
	var dir := Vector3(face.x - pos.x, 0.0, face.z - pos.z)
	var basis := fig.transform.basis
	if dir.length() > 0.05:
		basis = Basis.looking_at(-dir.normalized(), Vector3.UP)
	fig.transform = Transform3D(basis, pos)
	var activity := str(w["activity"])
	var kind := str(w["kind"])
	_hide_props(c)
	var dt := maxf(delta, 1.0 / 120.0)
	match activity:
		"walk":
			fig.clear_clip()
			fig.set_hand_target(0, null)
			fig.set_hand_target(1, null)
			fig.pose("walk", maxf(rate, 0.3), dt)
		"carry":
			var clip := _clip(str(w["clip"]))
			var rig := _rig("carry")
			var beam: Node3D = c["beam"]
			beam.visible = true
			var phase := _phase(c, clip, 0.0)
			var xf := fig.transform * (FabContextRig.tool_at(rig, phase / maxf(clip.length_s, 0.01))["xform"] as Transform3D)
			beam.transform = xf
			_drive(fig, clip, phase, xf, FabContextRig.beam_sockets(), dt, rate)
		"work":
			var clip2 := _clip(str(w["clip"]))
			if clip2 == null:
				fig.clear_clip()
				fig.pose("idle", 1.0, dt)
				return
			var rig_kind := kind if kind in ["cut", "drill", "fasten", "place", "lift"] else ""
			var phase2: float
			if clip2.loop:
				phase2 = _phase(c, clip2, float(w["id"]) * PHASE_SPREAD_S)
			else:
				phase2 = float(w["u"]) * clip2.length_s
			var u := phase2 / maxf(clip2.length_s, 0.01)
			if rig_kind.is_empty():
				_drive(fig, clip2, phase2, Transform3D(), {}, dt, rate)
				return
			var rig2 := _rig(rig_kind)
			var tp := FabContextRig.tool_at(rig2, u)
			var xf2 := fig.transform * (tp["xform"] as Transform3D)
			var tool_id := str(rig2.get("tool_id", ""))
			var socks: Dictionary
			if tool_id.is_empty():
				socks = FabContextRig.beam_sockets()
			else:
				var tool := _tool(c, tool_id)
				tool.visible = true
				tool.transform = xf2
				FabToolCatalog.set_spin(tool, float(tp["spin"]))
				socks = tool.get_meta("sockets", {})
			_drive(fig, clip2, phase2, xf2, socks, dt, rate)
		_:
			fig.clear_clip()
			fig.set_hand_target(0, null)
			fig.set_hand_target(1, null)
			fig.pose("idle", 1.0, dt)


## A clip over a still idle, hands on the sockets the clip asks for.
func _drive(fig: NpcSimpleFigure, clip: NpcAnimClip, t: float, tool_xf: Transform3D,
		socks: Dictionary, dt: float, _rate: float) -> void:
	fig.set_clip(clip, t, 1.0)
	for i in 2:
		var sock := str(clip.ik.get("hand_r" if i == 0 else "hand_l", "none"))
		if sock != "none" and socks.get(sock) is Transform3D:
			# Hand targets are WORLD placements.
			fig.set_hand_target(i, global_transform * tool_xf * (socks[sock] as Transform3D))
		else:
			fig.set_hand_target(i, null)
	fig.pose("idle", 0.0, dt)


## The looping clip's time: the NPC cosmetic clock (time-lapsed at speed,
## frozen while paused), offset per worker.
func _phase(_c: Dictionary, clip: NpcAnimClip, offset: float) -> float:
	if clip == null or clip.length_s <= 0.0:
		return 0.0
	return fposmod(_fx_t + offset, clip.length_s)


func _hide_props(c: Dictionary) -> void:
	for id in c["tools"]:
		(c["tools"][id] as Node3D).visible = false
	(c["beam"] as Node3D).visible = false


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
			y = (global_transform.affine_inverse() * Vector3(wp.x, gy, wp.z)).y
			# The structure stands on its own footing; never sink a worker
			# under it or float one far above it.
			y = clampf(y, -1.5, 1.5)
	if cache.size() > 512:
		cache.clear()
	cache[key] = y
	return y


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
# Labour mode
# ---------------------------------------------------------------------------

func _bridge() -> Object:
	var sgv: Object = ServiceLocator.graph()
	if sgv == null and _main != null:
		sgv = _main.find_child("SystemGraphView", true, false)
	if sgv == null or not sgv.has_method("npc_population_bridge"):
		return null
	return sgv.call("npc_population_bridge")


## Read the project: progress -> the target build time, who is on site.
func _poll_status() -> void:
	var bridge := _bridge()
	if bridge == null or not bridge.has_method("linkage_build_status"):
		_status = {"found": false}
		return
	var c3 := global_transform.origin if is_inside_tree() else Vector3.ZERO
	_status = bridge.call("linkage_build_status", str(_run.get("iid", "")), str(_run.get("project_id", "")),
		Vector2(c3.x, c3.z), float(_tl.get("radius_m", 6.0)) + SITE_MARGIN_M + BENCH_REACH_M)
	if not bool(_status.get("found", false)):
		return
	var state := str(_status.get("state", ""))
	if state == "done":
		_t_target = float(_tl["makespan"]) + LINGER_S + 1.0
		_t_disp = maxf(_t_disp, _t_target - 0.5)
		return
	if state != "active":
		# Cancelled: the crew stopped; the bridge takes the visuals back.
		dispose(false)
		return
	_t_target = time_for_fraction(float(_status.get("progress", 0.0)))


## The timeline's cumulative work curve W(t) (person-seconds done by t) —
## labour fraction f maps to the time where W(t) = f x total.
func _build_work_curve() -> void:
	_work_total = 0.0
	for j in _tl.get("jobs", []):
		if float(j["t0"]) >= 0.0:
			_work_total += float(j["work_s"])


func _work_done_at(t: float) -> float:
	var w := 0.0
	for j in _tl.get("jobs", []):
		var t0 := float(j["t0"])
		var t1 := float(j["t1"])
		if t0 < 0.0 or t <= t0:
			continue
		w += float(j["work_s"]) * clampf((t - t0) / maxf(t1 - t0, 1e-6), 0.0, 1.0)
	return w


func time_for_fraction(f: float) -> float:
	var mk := float(_tl.get("makespan", 0.0))
	if f <= 0.0 or _work_total <= 0.0:
		return 0.0
	if f >= 1.0:
		return mk
	var want := f * _work_total
	var lo := 0.0
	var hi := mk
	for _i in 32:
		var mid := (lo + hi) * 0.5
		if _work_done_at(mid) < want:
			lo = mid
		else:
			hi = mid
	return hi


## Assign the people on site to lanes: the busiest lanes first (working,
## carrying, walking, then waiting / idle), an agent keeps its lane while it
## stays. Returns lane -> colour; registers the people as stood in.
func _man_lanes(ws: Array) -> Dictionary:
	var present: Array = _status.get("present", [])
	var here := {}
	for pr in present:
		here[str(pr["id"])] = pr
	for aid in _lane_of.keys():
		if not here.has(aid):
			_lane_of.erase(aid)
	var taken := {}
	for aid in _lane_of:
		taken[int(_lane_of[aid])] = true
	var order: Array = range(mini(ws.size(), _crew.size()))
	var rank := {"work": 0, "carry": 1, "walk": 2, "wait": 3, "idle": 4}
	order.sort_custom(func(a, b):
		var ra := int(rank.get(str(ws[a]["activity"]), 5))
		var rb := int(rank.get(str(ws[b]["activity"]), 5))
		return ra < rb if ra != rb else int(a) < int(b))
	var ids: Array = here.keys()
	ids.sort()
	for aid in ids:
		if _lane_of.has(aid):
			continue
		for lane in order:
			if not taken.has(lane):
				_lane_of[aid] = lane
				taken[lane] = true
				break
	var out := {}
	var stood := {}
	for aid in _lane_of:
		out[int(_lane_of[aid])] = (here[aid] as Dictionary).get("color", Color.WHITE)
		stood[aid] = true
	NpcStandIns.set_for(_stand_key(), stood)
	return out


func manned_count() -> int:
	return _lane_of.size()


# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

func _build_crew() -> void:
	var n := int(_tl.get("crew", DEFAULT_CREW))
	for i in n:
		var fig := NpcSimpleFigure.new()
		fig.hi_detail = true
		fig.name = "Builder%d" % i
		add_child(fig)
		var key := "%s_builder_%d" % [_prop.prop_id, i]
		fig.setup(key, Color.from_hsv(NpcHash.unit01(key, "tint"), 0.45, 0.9))
		fig.set_mocap_allowed(false)
		_crew.append({"fig": fig, "tools": {}, "beam": _beam_part(), "ground": {}})


func _beam_part() -> Node3D:
	var root3 := Node3D.new()
	root3.name = "CarriedBeam"
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = Vector3(1.4, 0.089, 0.038)
	mi.mesh = b
	mi.material_override = _mat(Color(0.86, 0.7, 0.5))
	root3.add_child(mi)
	root3.visible = false
	add_child(root3)
	return root3


## Saw and drill benches where the timeline's stations are, laid out exactly
## as the context the clips were authored against (FabContextRig), in the
## frame of the worker who stands at each.
func _build_benches() -> void:
	_benches = Node3D.new()
	_benches.name = "Benches"
	add_child(_benches)
	var stations: Dictionary = _tl.get("stations", {})
	for res in stations:
		var rig := _rig("cut" if res == "saw" else "drill")
		for s in stations[res]:
			var stand: Vector3 = (s["stand"] as Array)[0]
			var pos: Vector3 = s["pos"]
			var dir := Vector3(pos.x - stand.x, 0.0, pos.z - stand.z).normalized()
			var frame := Transform3D(Basis.looking_at(-dir, Vector3.UP),
				Vector3(stand.x, _ground_local({"ground": {}}, stand), stand.z))
			for wp in rig["workpieces"]:
				var size: Vector3 = wp["size"]
				var xf: Transform3D = frame * (wp["xform"] as Transform3D)
				if absf(size.y - FabContextRig.BENCH_TOP_M) < 0.01:
					_add_bench_table(size, xf, wp["color"])
				else:
					_add_box(size, xf, wp["color"])


## The context's bench box as a table: a top and four legs.
func _add_bench_table(size: Vector3, xf: Transform3D, col: Color) -> void:
	const TOP := 0.05
	const LEG := 0.06
	_add_box(Vector3(size.x, TOP, size.z), xf * Transform3D(Basis(), Vector3(0, size.y / 2.0 - TOP / 2.0, 0)), col)
	var leg_h := size.y - TOP
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var at := Vector3(sx * (size.x / 2.0 - LEG), -size.y / 2.0 + leg_h / 2.0, sz * (size.z / 2.0 - LEG))
			_add_box(Vector3(LEG, leg_h, LEG), xf * Transform3D(Basis(), at), col.darkened(0.25))


func _add_box(size: Vector3, xf: Transform3D, col: Color) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = _mat(col)
	mi.transform = xf
	_benches.add_child(mi)


static func _mat(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = 0.85
	return m
