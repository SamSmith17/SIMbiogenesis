class_name CrowdRenderer
extends Node3D

## Draws every LIGHT-tier person on the map from two MultiMeshes — a low-poly
## figure (crowd_figure.gdshader) and a constant-apparent-size card
## (crowd_card.gdshader) — with NO per-frame CPU work beyond one uniform.
##
## A person is a SLOT: the MultiMesh "transform" carries their current motion
## segment and pose (see write_slot), the GPU interpolates the position from
## the sim clock, and the slot is rewritten only when the cohort fires an
## event for that person (CrowdCohort.take_dirty). This is the growth-year
## pattern from the vegetation tiers applied to people: nothing ticks per
## person per frame, and the crowd scrubs backwards inside a segment for free.
##
## Times are float32 on the GPU, so they are stored relative to `time_base`
## and everything is rewritten when the clock drifts more than REBASE_H from
## it. Heights come from TerrainSurfaceQuery at the segment ENDPOINTS (two
## samples per event, linear in between) — a height raster is Phase 4b.
##
## The full-tier camp keeps its NpcAvatar bodies (NpcPopulationHost); this
## node only ever draws people whose dots say tier == "light".

const REBASE_H := 24.0
## Instance COLOR.a carries MOOD — see NpcPeak.pack_mood (pure, so the
## selftest can pin it; this file references an autoload and cannot load
## under --script).
const FLAG_HIDDEN := 1.0
const FIGURE_DIST_M := 150.0
const CARD_DIST_M := 3000.0
## The height raster (Phase 4b): ground heights over the population region
## at HEIGHT_CELL_M, baked HEIGHT_SAMPLES_PER_FRAME terrain queries per frame
## (never inline — the nav grid's TDR note applies). Until it lands the
## shaders interpolate the segment endpoints as before. Rebuilt when the
## region moves by more than HEIGHT_REBUILD_M or grows past its bounds.
const HEIGHT_CELL_M := 2.0
const HEIGHT_MAX_AXIS := 1024
const HEIGHT_PAD_M := 80.0
const HEIGHT_SAMPLES_PER_FRAME := 6000
## ...but never more than this much time per frame: 6000 terrain queries
## measured 36 ms on Walton, a visible hitch every frame of the bake.
const HEIGHT_BUDGET_US := 2000
const HEIGHT_REBUILD_M := 60.0
var _h_img: Image = null
var _h_tex: ImageTexture = null
var _h_origin := Vector2.ZERO
var _h_size := Vector2.ONE
var _h_nx := 0
var _h_nz := 0
var _h_cursor := 0
var _h_ready := false
var _h_region_center := Vector2.INF
var _h_region_half := 0.0

var _bridge = null
var _main: Node = null
var _mm_fig: MultiMesh = null
var _mm_card: MultiMesh = null
var _mi_fig: MultiMeshInstance3D = null
var _mi_card: MultiMeshInstance3D = null
var _fig_mat: ShaderMaterial = null
var _card_mat: ShaderMaterial = null
## iid -> first slot index; iid -> count.
var _base: Dictionary = {}
var _counts: Dictionary = {}
var _total := 0
var _time_base := NAN
var _last_pref_gen := -1
var _ground_cache: Dictionary = {}
## FULL-tier people beyond the hero budget (NpcPopulationHost hands them
## over): id -> entry, written as point-to-point segments per sim tick so the
## GPU glides them exactly as the host's own prev→next interpolation would.
## Each full-tier person keeps ONE slot for as long as they are handed over
## (id -> index in the full block); a leaver's slot is hidden and reused.
## The block is laid out with slack (FULL_SLACK) so the hero set changing —
## every frame while a circle turns — rewrites a few slots instead of
## re-laying the whole table (a MultiMesh instance_count change clears every
## instance, the light tier's included).
const FULL_SLACK := 32
var _full_entries: Dictionary = {}
var _full_slot: Dictionary = {}
var _full_free: Array = []
var _full_cap := 0
var _light_on := true
## NO JUMPS: the last segment written for each person (id -> {a, b: Vector3,
## t0, t1: ABSOLUTE sim hours, elev}), kept by id so a re-layout does not lose
## it. A new segment whose start is not where the figure is DRAWN right now —
## an event the cohort processed a tick after its time (the walker stood at
## the end of a leg, then leapt), a tier switch, a hand-off — starts from the
## drawn point instead and catches up no faster than EASE_MPS of sim walking.
## `_seg_old` holds the records across a re-layout; `_gone` keeps a person
## who just left the renderer for GONE_KEEP_MS so the host can hand them in
## at the exact spot they were drawn.
const EASE_MIN_M := 0.3
const EASE_MAX_M := 400.0
const EASE_MPS := 3.0
const GONE_KEEP_MS := 3000
## yaw_hint above this marks a FIXED facing (yaw_hint - YAW_FIXED): an eased
## glide into a standing spot keeps the person's own facing instead of
## turning to the glide direction and snapping back on arrival.
const YAW_FIXED := 1000.0
var _seg_rec: Dictionary = {}
var _seg_old: Dictionary = {}
var _gone: Dictionary = {}
## Who holds a LIGHT slot right now. A person whose camp just switched to the
## light tier is still in the host's full list until its next push: their
## stale full slot is hidden at once (two figures for one person otherwise),
## and must not overwrite the light slot's record.
var _light_ids: Dictionary = {}
var _full_base := 0


func setup(bridge, main: Node) -> void:
	_bridge = bridge
	_main = main
	name = "CrowdRenderer"


func _ready() -> void:
	_fig_mat = ShaderMaterial.new()
	_fig_mat.shader = load("res://core/population/crowd_figure.gdshader")
	_card_mat = ShaderMaterial.new()
	_card_mat.shader = load("res://core/population/crowd_card.gdshader")
	_mm_fig = MultiMesh.new()
	_mm_fig.transform_format = MultiMesh.TRANSFORM_3D
	_mm_fig.use_colors = true
	_mm_fig.mesh = CrowdFigureMesh.mesh()
	_mm_card = MultiMesh.new()
	_mm_card.transform_format = MultiMesh.TRANSFORM_3D
	_mm_card.use_colors = true
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	_mm_card.mesh = quad
	_mi_fig = MultiMeshInstance3D.new()
	_mi_fig.name = "CrowdFigures"
	_mi_fig.multimesh = _mm_fig
	_mi_fig.material_override = _fig_mat
	_mi_fig.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mi_fig)
	_mi_card = MultiMeshInstance3D.new()
	_mi_card.name = "CrowdCards"
	_mi_card.multimesh = _mm_card
	_mi_card.material_override = _card_mat
	_mi_card.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mi_card)
	# The instance "transforms" are data, so Godot's own AABB is meaningless:
	# cover the whole site so nothing is ever culled by it.
	var big := AABB(Vector3(-4000.0, -500.0, -4000.0), Vector3(8000.0, 1500.0, 8000.0))
	_mi_fig.custom_aabb = big
	_mi_card.custom_aabb = big


func _process(_delta: float) -> void:
	if _bridge == null or _main == null or not is_instance_valid(_main) or _total == 0:
		return
	if _main.has_method("get_absolute_hours") and not is_nan(_time_base):
		var t_rel := float(_main.call("get_absolute_hours")) - _time_base
		_fig_mat.set_shader_parameter("t_rel", t_rel)
		_card_mat.set_shader_parameter("t_rel", t_rel)
	PerfMonitor.begin("crowd_raster")
	_service_height_raster()
	PerfMonitor.end("crowd_raster")
	var gen := NpcDisplayPrefs.generation()
	if gen != _last_pref_gen:
		_last_pref_gen = gen
		_apply_prefs()


func _apply_prefs() -> void:
	var mode := NpcDisplayPrefs.crowd_draw()
	# The LIGHT tier follows the "Draw people" mode and the light-crowd
	# switch; full-tier people handed over by the host (past the full-figure
	# budget) are drawn in every mode but "Nobody" — hiding them made people
	# blink out whenever the nearest set changed.
	var light := 1.0 if (mode == NpcDisplayPrefs.CROWD_ALL or mode == NpcDisplayPrefs.CROWD_LOD) \
		and NpcDisplayPrefs.light_crowd() else 0.0
	var draw := 0.0 if mode == NpcDisplayPrefs.CROWD_NONE else 1.0
	_light_on = light > 0.5
	var lod := NpcDisplayPrefs.crowd_lod_m() if mode == NpcDisplayPrefs.CROWD_LOD else 0.0
	for m in [_fig_mat, _card_mat]:
		m.set_shader_parameter("draw_mode", draw)
		m.set_shader_parameter("light_draw", light)
		m.set_shader_parameter("lod_dist", lod)
		m.set_shader_parameter("figure_dist", figure_dist())
	_card_mat.set_shader_parameter("card_dist", CARD_DIST_M)
	visible = draw > 0.5


## Where the capsule figures give way to dots: the player's number
## (Settings -> NPCs), else the graphics tier's.
func figure_dist() -> float:
	if NpcDisplayPrefs.figure_dist_m() > 0.0:
		return NpcDisplayPrefs.figure_dist_m()
	var q := int(_main.get("graphics_quality")) if _main != null and _main.get("graphics_quality") != null \
		else RenderProfile.QUALITY_HIGH
	return float(RenderProfile.npc_profile(q).get("figure_dist_m", FIGURE_DIST_M))


## Called once per sim tick (after the bridge ticked). Rebuilds the slot
## table when the roster membership changed or the clock drifted past the
## rebase window; otherwise rewrites only the people whose events fired.
func sync(abs_h: float) -> void:
	if _bridge == null or not _bridge.has_method("light_cohorts"):
		return
	var cohorts: Dictionary = _bridge.call("light_cohorts")
	var layout_changed := cohorts.size() != _counts.size()
	var total := 0
	for iid in cohorts:
		var n := int((cohorts[iid] as CrowdCohort).count())
		total += n
		if int(_counts.get(iid, -1)) != n:
			layout_changed = true
	var rebase := is_nan(_time_base) or absf(abs_h - _time_base) > REBASE_H
	if layout_changed or rebase:
		_time_base = abs_h
		_relayout_all(cohorts, total)
		return
	for iid in cohorts:
		var c: CrowdCohort = cohorts[iid]
		var d: Dictionary = c.take_dirty()
		var base := int(_base[iid])
		if bool(d["all"]):
			for i in c.count():
				write_slot(c, i, base + i)
		else:
			for i in (d["indices"] as PackedInt32Array):
				write_slot(c, i, base + i)


## Re-lay the whole table and rewrite every slot. The records move to
## `_seg_old` first so every rewrite still eases from where its person is
## drawn; whoever is not written again has left (kept briefly in `_gone`).
func _relayout_all(cohorts: Dictionary, total: int) -> void:
	_seg_old = _seg_rec
	_seg_rec = {}
	_light_ids = {}
	_rebuild_layout(cohorts, total)
	for iid in cohorts:
		var c: CrowdCohort = cohorts[iid]
		c.take_dirty()
		for i in c.count():
			write_slot(c, i, int(_base[iid]) + i)
	_write_full_slots()
	var now_ms := Time.get_ticks_msec()
	for id in _seg_old:
		if not _seg_rec.has(id):
			_gone[id] = {"rec": _seg_old[id], "ms": now_ms}
	_seg_old = {}
	for id in _gone.keys():
		if now_ms - int((_gone[id] as Dictionary)["ms"]) > GONE_KEEP_MS:
			_gone.erase(id)


func _rebuild_layout(cohorts: Dictionary, total: int) -> void:
	_base = {}
	_counts = {}
	var at := 0
	for iid in cohorts:
		var n := int((cohorts[iid] as CrowdCohort).count())
		_base[iid] = at
		_counts[iid] = n
		at += n
	_full_base = total
	_total = total + _full_cap
	_mm_fig.instance_count = _total
	_mm_card.instance_count = _total
	_ground_cache.clear()
	for m in [_fig_mat, _card_mat]:
		m.set_shader_parameter("full_base", float(_full_base))


## The slot layout (see crowd_figure.gdshader):
##   basis.x = a (world)   basis.y = b (world)   basis.z = (t0, t1, yaw_hint)
##   origin  = (pose, seed, flags)                color = pastel + morale
## `flags`: >= 1 hidden; < 0 = the feet stand -flags metres ABOVE the ground
## (the DJ on a stage deck) — the shaders skip the height raster's clamp.
func write_slot(c: CrowdCohort, i: int, slot: int) -> void:
	var id := c.ids[i]
	var a := Vector2(c.ax[i], c.az[i])
	var b := Vector2(c.bx[i], c.bz[i])
	var t0 := float(c.t0[i])
	var t1 := float(c.t1[i])
	var parked := c.state[i] != CrowdCohort.S_TRAVEL and c.state[i] != CrowdCohort.S_CIRCLE
	if parked:
		# Parked: the segment is a point at the current position. (A circle
		# step IS a segment — the arc's chord over its step — so it glides;
		# collapsed, the effigy's circle jumped from step to step.)
		var p := c.pos_at(i, c._last_abs_h if not is_nan(c._last_abs_h) else _time_base)
		a = p
		b = p
		t0 = _now_abs()
		t1 = t0
	var col := NpcPopulationEngine.color_for_agent(id)
	var ps := c.peak_since[i] if i < c.peak_since.size() else NAN
	col.a = NpcPeak.pack_mood(c.morale[i], ps - _time_base if not is_nan(ps) else NAN, c.buzz_of(i))
	_light_ids[id] = true
	_put(slot, id, a, b, t0, t1, c.face_yaw(i), c.pose_code(i), c.alive[i] == 0, c.elev_of(i), parked, col, false)


## Write one slot (both MultiMeshes), easing the segment from where this
## person is drawn now (see EASE_MPS) and recording it. Times are ABSOLUTE.
func _put(slot: int, id: String, a: Vector2, b: Vector2, t0: float, t1: float, yaw: float,
		pose: int, hidden: bool, elev: float, parked: bool, col: Color, full: bool) -> void:
	var a3 := Vector3(a.x, _ground_y(a), a.y)
	var b3 := a3 if b.distance_squared_to(a) < 0.01 else Vector3(b.x, _ground_y(b), b.y)
	var yaw_out := yaw
	if hidden:
		_seg_rec.erase(id)
	else:
		var now := _now_abs()
		var prev: Variant = _seg_rec.get(id, _seg_old.get(id, null))
		if prev == null and _gone.has(id) \
				and Time.get_ticks_msec() - int((_gone[id] as Dictionary)["ms"]) <= GONE_KEEP_MS:
			prev = (_gone[id] as Dictionary)["rec"]
		if prev is Dictionary and now >= float((prev as Dictionary)["t0"]) - 1e-9:
			var from := _rec_at(prev, now)
			var here := _seg_at(a3, b3, t0, t1, now)
			var d := Vector2(from.x - here.x, from.z - here.z).length()
			if d > EASE_MIN_M and d < EASE_MAX_M:
				var reach := Vector2(from.x - b3.x, from.z - b3.z).length()
				var arrive := maxf(maxf(t1, now), now + reach / (EASE_MPS * 3600.0))
				a3 = from
				t0 = now
				t1 = arrive
				if parked:
					yaw_out = yaw + YAW_FIXED
		_seg_rec[id] = {"a": a3, "b": b3, "t0": t0, "t1": t1, "elev": elev, "full": full}
	var t0r := t0 - _time_base
	var t1r := t1 - _time_base
	if t1r <= t0r:
		t1r = t0r + 1e-4
	var flags := FLAG_HIDDEN if hidden else -elev
	var xf := Transform3D(a3, b3, Vector3(t0r, t1r, yaw_out),
		Vector3(float(pose), NpcHash.unit01(id, "pose"), flags))
	_mm_fig.set_instance_transform(slot, xf)
	_mm_fig.set_instance_color(slot, col)
	_mm_card.set_instance_transform(slot, xf)
	_mm_card.set_instance_color(slot, col)


func _now_abs() -> float:
	if _main != null and _main.has_method("get_absolute_hours"):
		return float(_main.call("get_absolute_hours"))
	return 0.0 if is_nan(_time_base) else _time_base


static func _seg_at(a: Vector3, b: Vector3, t0: float, t1: float, t: float) -> Vector3:
	if t1 - t0 <= 1e-9:
		return b if t >= t1 else a
	return a.lerp(b, clampf((t - t0) / (t1 - t0), 0.0, 1.0))


static func _rec_at(rec: Dictionary, t: float) -> Vector3:
	return _seg_at(rec["a"], rec["b"], float(rec["t0"]), float(rec["t1"]), t)


## Ease this person's figure in from `from` (the host hands over a body it
## was drawing — an avatar whose person just went to the light tier).
func ease_from(agent_id: String, from: Vector3) -> void:
	var slot := _slot_of(agent_id)
	if slot < 0:
		return   # left the site, or not drawn here: nothing to ease
	var now := _now_abs()
	_seg_rec[agent_id] = {"a": from, "b": from, "t0": now, "t1": now, "elev": 0.0}
	if slot >= _full_base:
		_write_full_one(agent_id)
		return
	var cohorts: Dictionary = _bridge.call("light_cohorts") if _bridge != null and _bridge.has_method("light_cohorts") else {}
	for iid in _base:
		var c: CrowdCohort = cohorts.get(iid)
		if c == null:
			continue
		var i := c.agent_index(agent_id)
		if i >= 0:
			write_slot(c, i, int(_base[iid]) + i)
			return


## The height raster: sized from the bridge's population region, baked a
## slice per frame, pushed to both shaders when complete. Endpoint heights
## (write_slot) stay as the fallback outside the rect.
func _service_height_raster() -> void:
	if _bridge == null or not _bridge.has_method("population_region"):
		return
	var region: Dictionary = _bridge.call("population_region")
	if region.is_empty():
		return
	var center: Vector2 = region.get("center", Vector2.ZERO)
	var half := float(region.get("half", 0.0)) + HEIGHT_PAD_M
	var need_new := _h_img == null \
		or _h_region_center == Vector2.INF \
		or center.distance_to(_h_region_center) > HEIGHT_REBUILD_M \
		or half > _h_region_half + 1.0
	if need_new:
		_begin_height_raster(center, half)
	if _h_img == null or _h_ready:
		return
	var total := _h_nx * _h_nz
	var done := 0
	var t_start := Time.get_ticks_usec()
	while _h_cursor < total and done < HEIGHT_SAMPLES_PER_FRAME:
		if (done & 63) == 0 and done > 0 and Time.get_ticks_usec() - t_start > HEIGHT_BUDGET_US:
			break
		var ix := _h_cursor % _h_nx
		var iz := _h_cursor / _h_nx
		var x := _h_origin.x + (float(ix) + 0.5) * HEIGHT_CELL_M
		var z := _h_origin.y + (float(iz) + 0.5) * HEIGHT_CELL_M
		_h_img.set_pixel(ix, iz, Color(TerrainSurfaceQuery.ground_height_at(_main, x, z), 0.0, 0.0, 1.0))
		_h_cursor += 1
		done += 1
	if _h_cursor >= total:
		_h_ready = true
		if _h_tex == null:
			_h_tex = ImageTexture.create_from_image(_h_img)
		else:
			_h_tex.update(_h_img)
		var rect := Vector4(_h_origin.x, _h_origin.y, _h_size.x, _h_size.y)
		for m in [_fig_mat, _card_mat]:
			m.set_shader_parameter("height_tex", _h_tex)
			m.set_shader_parameter("height_rect", rect)
			m.set_shader_parameter("height_ready", 1.0)


func _begin_height_raster(center: Vector2, half: float) -> void:
	var n := clampi(int(ceil(half * 2.0 / HEIGHT_CELL_M)), 4, HEIGHT_MAX_AXIS)
	_h_nx = n
	_h_nz = n
	_h_size = Vector2(float(n), float(n)) * HEIGHT_CELL_M
	_h_origin = center - _h_size * 0.5
	_h_region_center = center
	_h_region_half = half
	_h_cursor = 0
	_h_ready = false
	_h_img = Image.create(n, n, false, Image.FORMAT_RF)
	# A new size needs a new texture (update() requires matching dimensions).
	_h_tex = null
	# The old raster (if any) keeps serving until the new one lands.


func height_raster_ready() -> bool:
	return _h_ready


## Ground height at a point, memoised on a 0.5 m grid (segment endpoints
## repeat — camps, spaces, queue slots).
func _ground_y(xz: Vector2) -> float:
	var key := Vector2i(int(round(xz.x * 2.0)), int(round(xz.y * 2.0)))
	if _ground_cache.has(key):
		return float(_ground_cache[key])
	var y := TerrainSurfaceQuery.ground_height_at(_main, xz.x, xz.y)
	if _ground_cache.size() > 20000:
		_ground_cache.clear()
	_ground_cache[key] = y
	return y


## Where this person's figure is DRAWN right now — the shader's own sum
## replayed on the CPU: the slot's segment mixed at the current t_rel, on the
## ground under it, plus any deck elevation. null when they have no slot or
## are hidden. The beacon and the fire props follow this, so they sit on the
## body the player sees rather than on the sim's last tick.
func drawn_position(agent_id: String) -> Variant:
	if not visible or _main == null:
		return null
	var rec: Variant = _seg_rec.get(agent_id, null)
	if not (rec is Dictionary):
		return null
	var p := _rec_at(rec, _now_abs())
	p.y = _ground_y(Vector2(p.x, p.z)) + maxf(float((rec as Dictionary).get("elev", 0.0)), 0.0)
	if not _light_on and not bool((rec as Dictionary).get("full", false)):
		# The distant crowd is off: a light-tier figure is drawn only inside
		# the figure reach (it dissolves out toward its edge).
		var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
		if cam != null and cam.global_position.distance_to(p) > figure_dist():
			return null
	return p


## Where this person was last drawn, also for a moment after they left the
## renderer (became a full figure): the host hands a new avatar in THERE.
func last_drawn_position(agent_id: String) -> Variant:
	var p: Variant = drawn_position(agent_id)
	if p is Vector3:
		return p
	var g: Variant = _gone.get(agent_id, null)
	if g is Dictionary and Time.get_ticks_msec() - int((g as Dictionary)["ms"]) <= GONE_KEEP_MS:
		var q := _rec_at((g as Dictionary)["rec"], _now_abs())
		q.y = _ground_y(Vector2(q.x, q.z))
		return q
	return null


## The yaw the shader gives this figure (radians, its atan2(x, z) convention).
func drawn_yaw(agent_id: String) -> float:
	var slot := _slot_of(agent_id)
	if slot < 0 or _mm_fig == null or slot >= _mm_fig.instance_count:
		return 0.0
	var xf := _mm_fig.get_instance_transform(slot)
	var yh := xf.basis.z.z
	if yh > YAW_FIXED * 0.5:
		return yh - YAW_FIXED
	var seg := xf.basis.y - xf.basis.x
	if Vector2(seg.x, seg.z).length() > 0.05:
		return atan2(seg.x, seg.z)
	return yh


func _slot_of(agent_id: String) -> int:
	if _bridge != null and _bridge.has_method("light_cohorts"):
		var cohorts: Dictionary = _bridge.call("light_cohorts")
		for iid in _base:
			var c: CrowdCohort = cohorts.get(iid)
			if c == null:
				continue
			var i := c.agent_index(agent_id)
			if i >= 0:
				return int(_base[iid]) + i
	var k := int(_full_slot.get(agent_id, -1))
	return _full_base + k if k >= 0 else -1


func people_drawn() -> int:
	return _total


## Full-tier people the host is NOT drawing as NpcAvatars (the hero pool is
## full). `entries` = [{id, prev: Vector2, next: Vector2, t0, t1, pose, yaw,
## color: Color, morale, hidden}] with t0/t1 in absolute sim hours — the
## host's last two tick positions, so the figure glides between ticks on
## the GPU. A membership change re-lays the slot table; otherwise each call
## rewrites only these slots (~tens to a hundred writes per tick).
func set_full_people(entries: Array, abs_h: float) -> void:
	if _mm_fig == null:
		return
	if is_nan(_time_base):
		_time_base = abs_h
	var next_entries: Dictionary = {}
	for e in entries:
		var d: Dictionary = e
		var id := str(d.get("id", ""))
		if not id.is_empty():
			next_entries[id] = d
	# Leavers free their slot (hidden below); joiners take a free one.
	var freed: Array = []
	for id in _full_slot.keys():
		if not next_entries.has(id):
			freed.append(int(_full_slot[id]))
			_full_free.append(int(_full_slot[id]))
			_full_slot.erase(id)
			if _seg_rec.has(id) and bool((_seg_rec[id] as Dictionary).get("full", false)):
				_gone[id] = {"rec": _seg_rec[id], "ms": Time.get_ticks_msec()}
				_seg_rec.erase(id)
	var relayout := absf(abs_h - _time_base) > REBASE_H
	var sorted_free := false
	for id in next_entries:
		if _full_slot.has(id):
			continue
		if _full_free.is_empty():
			# Out of room: grow with slack and re-lay the table once.
			var cap := maxi(_full_cap * 3 / 2, next_entries.size() + FULL_SLACK)
			for k in range(_full_cap, cap):
				_full_free.append(k)
			_full_cap = cap
			relayout = true
			sorted_free = false
		if not sorted_free:
			_full_free.sort()
			sorted_free = true
		_full_slot[id] = int(_full_free.pop_front())
	_full_entries = next_entries
	if relayout:
		if absf(abs_h - _time_base) > REBASE_H:
			_time_base = abs_h
		var cohorts: Dictionary = _bridge.call("light_cohorts") if _bridge != null and _bridge.has_method("light_cohorts") else {}
		var total := 0
		for iid in cohorts:
			total += int((cohorts[iid] as CrowdCohort).count())
		_relayout_all(cohorts, total)
		return
	# A freed slot a joiner did not take this call is hidden.
	for k in freed:
		if _full_free.has(int(k)):
			_hide_full_slot(int(k))
	_write_full_slots(false)


func _hide_full_slot(k: int) -> void:
	var slot := _full_base + k
	if slot < 0 or slot >= _mm_fig.instance_count:
		return
	var xf := Transform3D(Vector3.ZERO, Vector3.ZERO, Vector3(0.0, 1.0, 0.0), Vector3(0.0, 0.0, FLAG_HIDDEN))
	_mm_fig.set_instance_transform(slot, xf)
	_mm_card.set_instance_transform(slot, xf)


## Writes every handed-over person's slot; `all_slots` also hides the free
## ones (after a re-layout the buffer is zero transforms — and a zero slot is
## a VISIBLE figure standing at the world origin).
func _write_full_slots(all_slots: bool = true) -> void:
	if all_slots:
		for k in _full_free:
			_hide_full_slot(int(k))
	for id in _full_entries:
		_write_full_one(id)


func _write_full_one(id: String) -> void:
	var e: Dictionary = _full_entries.get(id, {})
	var k := int(_full_slot.get(id, -1))
	if e.is_empty() or k < 0:
		return
	if _light_ids.has(id):
		_hide_full_slot(k)   # gone to the light tier; the host drops it next push
		return
	var a: Vector2 = e.get("prev", Vector2.ZERO)
	var b: Vector2 = e.get("next", a)
	var t0 := float(e.get("t0", _time_base))
	var t1 := float(e.get("t1", t0))
	var col: Color = e.get("color", Color.WHITE)
	var ps := float(e.get("peak_since", NAN))
	col.a = NpcPeak.pack_mood(float(e.get("morale", 0.7)), ps - _time_base if not is_nan(ps) else NAN,
		float(e.get("peak_buzz", 0.0)))
	_put(_full_base + k, id, a, b, t0, t1, float(e.get("yaw", 0.0)), int(e.get("pose", 0)),
		bool(e.get("hidden", false)), float(e.get("elev", 0.0)), a.distance_squared_to(b) < 0.01, col, true)


func full_people_drawn() -> int:
	return _full_slot.size()
