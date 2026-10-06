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
const FLAG_HIDDEN := 1.0
const FIGURE_DIST_M := 150.0
const CARD_DIST_M := 3000.0

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
var _full_entries: Dictionary = {}
var _full_order: Array = []
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
	var gen := NpcDisplayPrefs.generation()
	if gen != _last_pref_gen:
		_last_pref_gen = gen
		_apply_prefs()


func _apply_prefs() -> void:
	var mode := NpcDisplayPrefs.crowd_draw()
	var draw := 1.0 if (mode == NpcDisplayPrefs.CROWD_ALL or mode == NpcDisplayPrefs.CROWD_LOD) else 0.0
	var lod := NpcDisplayPrefs.crowd_lod_m() if mode == NpcDisplayPrefs.CROWD_LOD else 0.0
	for m in [_fig_mat, _card_mat]:
		m.set_shader_parameter("draw_mode", draw)
		m.set_shader_parameter("lod_dist", lod)
		m.set_shader_parameter("figure_dist", FIGURE_DIST_M)
	_card_mat.set_shader_parameter("card_dist", CARD_DIST_M)
	visible = draw > 0.5


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
		_rebuild_layout(cohorts, total)
		for iid in cohorts:
			var c: CrowdCohort = cohorts[iid]
			c.take_dirty()
			for i in c.count():
				write_slot(c, i, int(_base[iid]) + i)
		_write_full_slots()
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
	_total = total + _full_order.size()
	_mm_fig.instance_count = _total
	_mm_card.instance_count = _total
	_ground_cache.clear()


## The slot layout (see crowd_figure.gdshader):
##   basis.x = a (world)   basis.y = b (world)   basis.z = (t0, t1, yaw_hint)
##   origin  = (pose, seed, flags)                color = pastel + morale
func write_slot(c: CrowdCohort, i: int, slot: int) -> void:
	var a := Vector2(c.ax[i], c.az[i])
	var b := Vector2(c.bx[i], c.bz[i])
	var ya := _ground_y(a)
	var yb := ya if b.distance_squared_to(a) < 0.01 else _ground_y(b)
	var t0 := float(c.t0[i] - _time_base)
	var t1 := float(c.t1[i] - _time_base)
	if c.state[i] != CrowdCohort.S_TRAVEL:
		# Parked: the segment is a point at the current position.
		var p := c.pos_at(i, c._last_abs_h if not is_nan(c._last_abs_h) else _time_base)
		a = p
		b = p
		yb = ya
		t0 = 0.0
		t1 = 1.0
	var flags := FLAG_HIDDEN if c.alive[i] == 0 else 0.0
	var seed := NpcHash.unit01(c.ids[i], "pose")
	var xf := Transform3D(
		Vector3(a.x, ya, a.y),
		Vector3(b.x, yb, b.y),
		Vector3(t0, t1, c.face_yaw(i)),
		Vector3(float(c.pose_code(i)), seed, flags))
	var col := NpcPopulationEngine.color_for_agent(c.ids[i])
	col.a = c.morale[i]
	_mm_fig.set_instance_transform(slot, xf)
	_mm_fig.set_instance_color(slot, col)
	_mm_card.set_instance_transform(slot, xf)
	_mm_card.set_instance_color(slot, col)


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
	var ids: Array = []
	var next_entries: Dictionary = {}
	for e in entries:
		var d: Dictionary = e
		var id := str(d.get("id", ""))
		if id.is_empty():
			continue
		ids.append(id)
		next_entries[id] = d
	var changed := ids.size() != _full_order.size()
	if not changed:
		for i in ids.size():
			if str(ids[i]) != str(_full_order[i]):
				changed = true
				break
	_full_entries = next_entries
	_full_order = ids
	if changed or absf(abs_h - _time_base) > REBASE_H:
		# Re-lay the table: the light cohorts keep their bases (recomputed
		# from the same bridge state), the full block follows them.
		_time_base = abs_h if absf(abs_h - _time_base) > REBASE_H else _time_base
		var cohorts: Dictionary = _bridge.call("light_cohorts") if _bridge != null and _bridge.has_method("light_cohorts") else {}
		var total := 0
		for iid in cohorts:
			total += int((cohorts[iid] as CrowdCohort).count())
		_rebuild_layout(cohorts, total)
		for iid in cohorts:
			var c: CrowdCohort = cohorts[iid]
			c.take_dirty()
			for i in c.count():
				write_slot(c, i, int(_base[iid]) + i)
	_write_full_slots()


func _write_full_slots() -> void:
	for i in _full_order.size():
		var e: Dictionary = _full_entries.get(str(_full_order[i]), {})
		if e.is_empty():
			continue
		var a: Vector2 = e.get("prev", Vector2.ZERO)
		var b: Vector2 = e.get("next", a)
		var ya := _ground_y(a)
		var yb := ya if b.distance_squared_to(a) < 0.01 else _ground_y(b)
		var t0 := float(e.get("t0", _time_base)) - _time_base
		var t1 := float(e.get("t1", _time_base + 1.0)) - _time_base
		if t1 <= t0:
			t1 = t0 + 1.0
		var flags := FLAG_HIDDEN if bool(e.get("hidden", false)) else 0.0
		var xf := Transform3D(
			Vector3(a.x, ya, a.y), Vector3(b.x, yb, b.y),
			Vector3(t0, t1, float(e.get("yaw", 0.0))),
			Vector3(float(e.get("pose", 0)), NpcHash.unit01(str(e.get("id", "")), "pose"), flags))
		var col: Color = e.get("color", Color.WHITE)
		col.a = float(e.get("morale", 0.7))
		var slot := _full_base + i
		_mm_fig.set_instance_transform(slot, xf)
		_mm_fig.set_instance_color(slot, col)
		_mm_card.set_instance_transform(slot, xf)
		_mm_card.set_instance_color(slot, col)


func full_people_drawn() -> int:
	return _full_order.size()
