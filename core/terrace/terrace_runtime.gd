class_name TerraceRuntime
extends Node3D

## The terraced fields of the map (a TerrainLoader child, "Terraces"):
##   * owns the records (TerraceLayer, saved per world) and their undo;
##   * writes every field's cut into the loader's TERRACE tile layer
##     (TerraceField.solve over the ground without terraces), re-measured when
##     the ground under a field changes (`ground_rev`, bumped by the loader);
##   * keeps one graph node per field (SystemGraphView.sync_terrace_node),
##     whose engine step runs the water and the crop;
##   * draws each field: the water in every paddy at the level the node
##     reports, the bunds along the lips, the crop near by (GardenCrops in
##     16 m chunks) and as a canopy further off, and the water spilling from
##     one paddy to the next while it does.
##
## The UI (the T toolbar's Terrace tool and the editor dock) calls the public
## functions below; every change is one undo step.

const POLL_S := 0.5
const PAD_LIFT_M := 0.0015
const CHUNK_M := 16.0
const CROP_DRAW_M := 55.0
const CANOPY_FROM_M := 42.0
const MAX_TUFTS := 36000
const FALL_PER_M := 18.0
const FALL_MAX := 4
## Farm jobs a field keeps on its camp's chore board at once.
const FARM_ACTIVE_MAX := 12
## How often the crews' work is read back (s).
const SERVICE_S := 1.0
## A step being dug shows its cut in steps of this share.
const DIG_QUANT := 0.1
## Board hours: farm jobs and digging happen by day.
const WORK_WINDOW := {"start_h": 6.5, "end_h": 18.5}
## The hand tool for each farm job (FabToolCatalog).
const FARM_TOOLS := {"prep": "hoe", "plant": "seedlings", "tend": "hoe", "harvest": "sickle"}
## How fast a drawn machine moves to where it should be (m/s, real time).
const RIG_SPEED_MPS := 3.0
## Bunds are earth walls that grass over within a season.
const EARTH := Color(0.33, 0.38, 0.2)
const GRASSY_EARTH := Color(0.32, 0.4, 0.2)

const _WATER_SHADER := preload("res://core/terrace/terrace_water.gdshader")
const _CANOPY_SHADER := preload("res://core/terrace/terrace_canopy.gdshader")
const _FALL_SHADER := preload("res://core/terrace/terrace_fall.gdshader")
const _CROP_SHADER := preload("res://vegetation/garden_crop.gdshader")

signal fields_changed(id: String)

var loader: Node = null
var layer := TerraceLayer.new()
## Bumped by the loader when the ground under a field changes.
var ground_rev := 0
## Bumped when the terrace layer's content changes (the DetailGround sink).
var sink_rev := 0
var last_error := ""
var selected := ""
var rebuild_count := 0
var last_rebuild_ms := 0.0

var _poll := 0.0
var _bound := false
var _geo_dirty := true
var _ground_seen := -1
var _solved: Dictionary = {}       ## id -> {key, s}
var _keys: Dictionary = {}         ## terrace-layer tile keys currently set
var _vis_dirty: Dictionary = {}    ## id -> true
var _vis: Dictionary = {}          ## id -> visual parts
var _graph_dirty: Dictionary = {}
var _sel_node: MeshInstance3D = null
var _focus_node: MeshInstance3D = null
var _focus_id := ""
var _svc := 0.0
var _farm_iid: Dictionary = {}     ## id -> the camp that works it
## The machine drawn at a field's work: id -> {node, model, target (Vector3),
## dir (Vector2), want (bool)}. Drawn while it works, moved every frame.
var _rigs: Dictionary = {}
## Where each field's machine should be (set by the dig / farm services).
var _rig_want: Dictionary = {}
## id -> {crew, dig, crew_n}: what the work is doing, in words.
var work_status: Dictionary = {}


func _ready() -> void:
	name = "Terraces"


func bind_map(lat: float, lon: float) -> void:
	layer.load_from(TerraceLayer.path_for(lat, lon))
	_solved.clear()
	for id in _vis.keys():
		_free_visual(str(id))
	_vis.clear()
	_keys.clear()
	_geo_dirty = true
	_bound = true
	for r in layer.fields:
		var id := str((r as Dictionary).get("id", ""))
		_vis_dirty[id] = true
		_graph_dirty[id] = true


func covers_tile(key: Vector2i) -> bool:
	return _keys.has(key)


func _process(delta: float) -> void:
	_drive_rigs(delta)
	_poll -= delta
	if _poll > 0.0:
		return
	_poll = POLL_S
	if loader == null or not _bound or not bool(loader.get("_built")):
		return
	if _geo_dirty or ground_rev != _ground_seen:
		rebuild_tiles()
	for id in _vis_dirty.keys():
		_build_visual(str(id))
	_vis_dirty.clear()
	for id in _graph_dirty.keys():
		_sync_graph(str(id))
	_graph_dirty.clear()
	_update_live()
	_svc -= POLL_S
	if _svc <= 0.0:
		_svc = SERVICE_S
		_service_work()


# ---------------------------------------------------------------------------
# Public API (toolbar + editor dock)
# ---------------------------------------------------------------------------

func record(id: String) -> Dictionary:
	return layer.find(id)


func field_ids() -> Array:
	var out: Array = []
	for r in layer.fields:
		out.append(str((r as Dictionary).get("id", "")))
	return out


func field_at(p: Vector2) -> String:
	return layer.field_at(p)


## "Terrace this hill from here up": an outline round the higher ground
## connected to `at`, at most `max_r` out.
func hill_outline(at: Vector2, max_r: float) -> PackedVector2Array:
	if loader == null:
		return PackedVector2Array()
	return TerraceField.hill_outline(Callable(loader, "ground_without_terraces"), at, max_r)


## A new field from an outline. Returns its id, or "" with `last_error`.
func create(poly: PackedVector2Array, settings: Dictionary = {}) -> String:
	last_error = TerraceField.outline_problem(poly)
	if not last_error.is_empty():
		return ""
	var other := layer.overlapping(poly)
	if not other.is_empty():
		last_error = "That overlaps %s — select it to change it" % str(layer.find(other).get("name", "a field"))
		return ""
	layer.checkpoint()
	var s := settings.duplicate()
	if not s.has("plant_abs_h"):
		s["plant_abs_h"] = _now_h()
	if str(s.get("build_mode", "instant")) != "instant":
		s["built"] = {}
	var r := layer.add(poly, s)
	layer.save()
	var id := str(r["id"])
	_geo_dirty = true
	_vis_dirty[id] = true
	_graph_dirty[id] = true
	_clear_vegetation(poly)
	_poll = 0.0
	fields_changed.emit(id)
	return id


## Change a field (a patch of record keys). One undo step unless `merge`
## (a slider being dragged keeps adding to the last step).
func update(id: String, patch: Dictionary, merge: bool = false) -> bool:
	var r := layer.find(id)
	if r.is_empty():
		return false
	var changed := false
	for k in patch.keys():
		if not r.has(k) or r[k] != patch[k]:
			changed = true
	if not changed:
		return false
	if not merge:
		layer.checkpoint()
	var geo_before := TerraceField.geometry_key(r)
	layer.update(id, patch)
	layer.save()
	if TerraceField.geometry_key(layer.find(id)) != geo_before:
		_geo_dirty = true
		if patch.has("poly"):
			_clear_vegetation(TerraceField.poly_of(layer.find(id)))
	_vis_dirty[id] = true
	_graph_dirty[id] = true
	_poll = minf(_poll, 0.05)
	fields_changed.emit(id)
	return true


func delete(id: String) -> bool:
	if layer.find(id).is_empty():
		return false
	_drop_work(id)
	layer.checkpoint()
	layer.remove(id)
	layer.save()
	_free_visual(id)
	_solved.erase(id)
	_geo_dirty = true
	var view := ServiceLocator.graph()
	if view != null and view.has_method("remove_terrace_node"):
		view.call("remove_terrace_node", id)
	if selected == id:
		set_selected("")
	_poll = 0.0
	fields_changed.emit(id)
	return true


func undo() -> bool:
	if not layer.undo():
		return false
	_after_undo()
	return true


func redo() -> bool:
	if not layer.redo():
		return false
	_after_undo()
	return true


func can_undo() -> bool:
	return layer.can_undo()


func _after_undo() -> void:
	var live := {}
	for r in layer.fields:
		live[str((r as Dictionary).get("id", ""))] = true
	var view := ServiceLocator.graph()
	for id in _vis.keys():
		if not live.has(id):
			_free_visual(str(id))
			if view != null and view.has_method("remove_terrace_node"):
				view.call("remove_terrace_node", str(id))
	for id in live.keys():
		_vis_dirty[id] = true
		_graph_dirty[id] = true
	if not selected.is_empty() and not live.has(selected):
		set_selected("")
	_geo_dirty = true
	_poll = 0.0
	fields_changed.emit("")


## One step's own crop and water ({} = as the field). One undo step.
func set_step(id: String, m: int, patch: Dictionary) -> void:
	var r := layer.find(id)
	if r.is_empty() or m == TerraceField.NO_STEP:
		return
	var steps: Dictionary = (TerraceField.resolve(r)["steps"] as Dictionary).duplicate(true)
	if patch.is_empty():
		steps.erase(str(m))
	else:
		var cur: Dictionary = (steps.get(str(m), {}) as Dictionary).duplicate()
		for k in patch.keys():
			cur[k] = patch[k]
		steps[str(m)] = cur
	update(id, {"steps": steps})


## How the steps are cut. A field already cut stays cut: changing from
## "instant" counts every step as dug.
func set_build_mode(id: String, mode: String) -> void:
	var r := layer.find(id)
	if r.is_empty() or not TerraceField.BUILD_MODES.has(mode):
		return
	var old := str(TerraceField.resolve(r)["build_mode"])
	if old == mode:
		return
	var patch := {"build_mode": mode}
	if old == "instant":
		var built := {}
		for st in (_solved.get(id, {}) as Dictionary).get("dig", []):
			built[str(int((st as Dictionary)["m"]))] = 1.0
		patch["built"] = built
	elif mode == "instant":
		_drop_dig(id)
	update(id, patch)
	_geo_dirty = true


## Sow the field's crop now (a new planting; the cycle restarts).
func sow_now(id: String) -> void:
	update(id, {"plant_abs_h": _now_h()})


## Fill every paddy (1) or drain them (0) at once.
func set_fill(id: String, frac: float) -> void:
	var view := ServiceLocator.graph()
	if view != null and view.has_method("set_terrace_fill"):
		view.call("set_terrace_fill", id, frac)


## The solved field (cut, paddies), {} before the map is built.
func solved(id: String) -> Dictionary:
	var e: Dictionary = _solved.get(id, {})
	return e.get("s", {}) as Dictionary


## Everything the editor shows about a field: the record, the cut's stats and
## the graph node's live numbers (empty without a graph).
func info(id: String) -> Dictionary:
	var r := layer.find(id)
	if r.is_empty():
		return {}
	var out := {"rec": TerraceField.resolve(r), "stats": {}, "node": {}, "graph_id": ""}
	var s := solved(id)
	if not s.is_empty():
		var st: Dictionary = (s["stats"] as Dictionary).duplicate()
		var cap := 0.0
		for p in s["paddies"]:
			cap += TerraceField.capacity_l(float((p as Dictionary)["area"]), r)
		st["cap_l"] = cap
		st["heads"] = (s["heads"] as PackedInt32Array).size()
		st["step_h"] = float(s["step_h"])
		out["stats"] = st
	var view := ServiceLocator.graph()
	if view != null and view.has_method("terrace_node_specs"):
		out["node"] = view.call("terrace_node_specs", id)
		out["graph_id"] = str(view.call("terrace_node_id", id))
	if not s.is_empty():
		var table := TerraceField.paddy_table(s, r)
		out["season"] = TerraceFarm.season_estimate(table)
		out["dig"] = dig_summary(id)
	out["work"] = work_status.get(id, {})
	return out


## The digging of a field: {steps, done (steps), vol_m3, hand, machine
## (TerraceDig.estimate totals for the whole field), done_share}.
func dig_summary(id: String) -> Dictionary:
	var e: Dictionary = _solved.get(id, {})
	var steps: Array = e.get("dig", [])
	var rr := TerraceField.resolve(layer.find(id))
	var vol := 0.0
	var done := 0
	var share := 0.0
	var tot := {"hand": {}, "skid_steer": {}, "tractor": {}}
	for mode in ["hand", "skid_steer", "tractor"]:
		var acc := {"hours": 0.0, "machine_h": 0.0, "fuel_l": 0.0, "work_kwh": 0.0, "food_kwh": 0.0,
			"fuel_kwh": 0.0}
		for st in steps:
			var sd: Dictionary = st
			var est := TerraceDig.estimate(float(sd["vol_m3"]), float(sd["floor_m2"]), mode,
				float(sd["length_m"]))
			for k in acc.keys():
				acc[k] = float(acc[k]) + float(est[k])
		tot[mode] = acc
	for st in steps:
		var sd2: Dictionary = st
		vol += float(sd2["vol_m3"])
		var b := TerraceField.step_built(rr, int(sd2["m"]))
		share += b * float(sd2["vol_m3"])
		if b >= 0.999:
			done += 1
	return {"steps": steps.size(), "done": done, "vol_m3": vol, "hand": tot["hand"],
		"skid_steer": tot["skid_steer"], "tractor": tot["tractor"], "machine": tot["skid_steer"],
		"ledger": (layer.find(id).get("dig", {}) as Dictionary).get("ledger", {}),
		"done_share": share / vol if vol > 0.0 else 1.0}


## Dig it all now (no crew), or start digging again by hand / machine.
func finish_dig_now(id: String) -> void:
	var e: Dictionary = _solved.get(id, {})
	var built := {}
	for st in e.get("dig", []):
		built[str(int((st as Dictionary)["m"]))] = 1.0
	_drop_dig(id)
	_write_quiet(id, {"built": built})
	_geo_dirty = true
	_vis_dirty[id] = true
	_graph_dirty[id] = true
	_poll = 0.0


## Every paddy of a field with its level, fill and spill (highest first):
## [{m, floor_y, area, fill, spill_lph, down}].
func paddies(id: String) -> Array:
	var s := solved(id)
	if s.is_empty():
		return []
	var node: Dictionary = info(id).get("node", {})
	var fills: Array = node.get("terrace_fill", [])
	var spills: Array = node.get("terrace_spill", [])
	var out: Array = []
	var i := 0
	for p in s["paddies"]:
		var pd: Dictionary = p
		var pv: Array = node.get("terrace_view", [])
		var stage := str((pv[i] as Array)[0]) if i < pv.size() else ""
		out.append({"m": int(pd["m"]), "floor_y": float(pd["floor_y"]), "area": float(pd["area"]),
			"stage": stage,
			"fill": float(fills[i]) if i < fills.size() else 0.0,
			"spill_lph": float(spills[i]) if i < spills.size() else 0.0,
			"down": (pd["down"] as PackedInt32Array).size()})
		i += 1
	return out


func set_selected(id: String) -> void:
	selected = id
	if _sel_node != null and is_instance_valid(_sel_node):
		_sel_node.queue_free()
	_sel_node = _outline(id, Color(1.0, 0.75, 0.2, 0.85), 0.6, "Selection")


## The crosshair's outline (first person, before a click selects it).
func set_focus(id: String) -> void:
	if id == _focus_id:
		return
	_focus_id = id
	if _focus_node != null and is_instance_valid(_focus_node):
		_focus_node.queue_free()
	_focus_node = null
	if id != selected:
		_focus_node = _outline(id, Color(0.85, 0.95, 1.0, 0.7), 0.35, "Focus")


func _outline(id: String, col: Color, width: float, nm: String) -> MeshInstance3D:
	if id.is_empty() or loader == null:
		return null
	var poly := TerraceField.poly_of(layer.find(id))
	if poly.size() < 3:
		return null
	var path := PackedVector3Array()
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		var ln := a.distance_to(b)
		var steps := maxi(1, ceili(ln / 1.5))
		for k in steps:
			var q := a.lerp(b, float(k) / float(steps))
			path.append(Vector3(q.x, float(loader.call("surface_height_at", q.x, q.y)) + 0.25, q.y))
	var buf := TerraceMesh.Buf.new()
	TerraceMesh.ribbon(buf, path, width, col, true)
	var node := MeshInstance3D.new()
	node.name = nm
	node.top_level = true
	node.mesh = buf.mesh()
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = col
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.no_depth_test = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	node.material_override = m
	node.set_meta("skip_prop_collision", true)
	add_child(node)
	return node


# ---------------------------------------------------------------------------
# The cut
# ---------------------------------------------------------------------------

func _solve_for(r: Dictionary) -> Dictionary:
	var id := str(r.get("id", ""))
	var key := "%s#%d" % [TerraceField.geometry_key(r), ground_rev]
	var e: Dictionary = _solved.get(id, {})
	if str(e.get("key", "")) == key:
		return e["s"] as Dictionary
	var s := TerraceField.solve(r, Callable(loader, "ground_without_terraces"))
	_solved[id] = {"key": key, "s": s, "dig": TerraceDig.steps_of(s), "rows": TerraceDig.paddy_rows(s)}
	_vis_dirty[id] = true
	_graph_dirty[id] = true
	return s


## Write every field's cut into the terrace tile layer (only the tiles that
## change are pushed).
func rebuild_tiles() -> void:
	var t0 := Time.get_ticks_usec()
	_geo_dirty = false
	_ground_seen = ground_rev
	var store: TerrainEditTiles = loader.call("terrace_tile_layer")
	var fresh := TerrainEditTiles.new()
	fresh.cell_m = store.cell_m
	fresh.tile_cells = store.tile_cells
	var live := {}
	for r in layer.fields:
		var rd: Dictionary = r
		live[str(rd.get("id", ""))] = true
		var s := _solve_for(rd)
		if s.is_empty():
			continue
		var deltas: Dictionary = s["deltas"]
		var rr := TerraceField.resolve(rd)
		if str(rr["build_mode"]) == "instant":
			for k in deltas.keys():
				var key: Vector2i = k
				fresh.set_delta_sample(key.x, key.y, float(deltas[k]))
		else:
			# Dug step by step: a step's cut shows as far as its crew has got.
			var built: Dictionary = rr["built"]
			var dm: Dictionary = s["delta_m"]
			var axes := {}
			for st in (_solved[str(rd.get("id", ""))] as Dictionary).get("dig", []):
				axes[int((st as Dictionary)["m"])] = st
			var cell := float((s["grid"] as Dictionary)["cell"])
			for k in deltas.keys():
				var key: Vector2i = k
				var m := int(dm.get(key, TerraceField.NO_STEP))
				var frac := clampf(float(built.get(str(m), 0.0)), 0.0, 1.0)
				if frac <= 0.0:
					continue
				var share := 1.0
				if frac < 0.999 and axes.has(m):
					var ax: Dictionary = axes[m]
					var u := (Vector2(key) * cell).dot(ax["axis"] as Vector2)
					share = TerraceDig.cell_share(u, float(ax["u0"]), float(ax["u1"]), frac)
				if share > 0.0:
					fresh.set_delta_sample(key.x, key.y, float(deltas[k]) * share)
	for id in _solved.keys():
		if not live.has(id):
			_solved.erase(id)
	# Pad every touched tile with its neighbours (EarthworksRuntime's rule):
	# the DetailGround sinks only under tiles whose neighbours are tiles too.
	var real_keys := fresh.active_tiles()
	var have := {}
	for k in real_keys:
		have[k] = true
	var pad := PackedFloat32Array()
	pad.resize((store.tile_cells + 1) * (store.tile_cells + 1))
	pad.fill(PAD_LIFT_M)
	for k in real_keys:
		var kk: Vector2i = k
		for oz in [-1, 0, 1]:
			for ox in [-1, 0, 1]:
				var nk := kk + Vector2i(ox, oz)
				if not have.has(nk):
					have[nk] = true
					fresh.set_tile_data(nk, pad.duplicate())
	var new_keys := {}
	for k in fresh.active_tiles():
		new_keys[k] = true
	var touched: Array = []
	var union := _keys.duplicate()
	for k in new_keys.keys():
		union[k] = true
	for k in union.keys():
		var key2: Vector2i = k
		var now_arr := fresh.tile_data(key2)
		if now_arr == store.tile_data(key2):
			continue
		store.set_tile_data(key2, now_arr)
		touched.append(key2)
	_keys = new_keys
	if not touched.is_empty():
		sink_rev += 1
		loader.call("commit_terrace_tiles", touched)
	rebuild_count += 1
	last_rebuild_ms = float(Time.get_ticks_usec() - t0) / 1000.0


func _clear_vegetation(poly: PackedVector2Array) -> void:
	if loader == null:
		return
	if loader.has_method("clear_auto_vegetation_in_polygon"):
		loader.call("clear_auto_vegetation_in_polygon", poly)
	if loader.has_method("count_manual_bulk_in_polygon") \
			and int(loader.call("count_manual_bulk_in_polygon", poly)) > 0 \
			and loader.has_method("clear_vegetation_in_polygon"):
		loader.call("clear_vegetation_in_polygon", poly)


# ---------------------------------------------------------------------------
# The graph node
# ---------------------------------------------------------------------------

func _sync_graph(id: String) -> void:
	var view := ServiceLocator.graph()
	if view == null or not view.has_method("sync_terrace_node"):
		return
	var r := layer.find(id)
	var s := solved(id)
	if r.is_empty() or s.is_empty():
		return
	var heads: Array = []
	for h in (s["heads"] as PackedInt32Array):
		heads.append(int(h))
	var poly := TerraceField.poly_of(r)
	var c := Vector2.ZERO
	for p in poly:
		c += p
	c /= float(maxi(poly.size(), 1))
	var y := float(loader.call("surface_height_at", c.x, c.y))
	view.call("sync_terrace_node", r, TerraceField.paddy_table(s, r), heads,
		float((s["stats"] as Dictionary)["floor_m2"]), Vector3(c.x, y, c.y))


# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

func _free_visual(id: String) -> void:
	var v: Dictionary = _vis.get(id, {})
	var node: Variant = v.get("node", null)
	if node is Node and is_instance_valid(node):
		(node as Node).queue_free()
	_vis.erase(id)


func _build_visual(id: String) -> void:
	_free_visual(id)
	var r := layer.find(id)
	var s := solved(id)
	if r.is_empty() or s.is_empty():
		return
	var rr := TerraceField.resolve(r)
	var grid: Dictionary = s["grid"]
	var cell := float(grid["cell"])
	var origin := Vector2(float(int(grid["i0"])) * cell, float(int(grid["j0"])) * cell)
	var hh := float(s["step_h"])
	var flooded := bool(rr["flooded"])
	var bund_h := float(rr["bund_h"])
	var root := Node3D.new()
	root.name = "Field_%s" % id
	root.top_level = true
	add_child(root)
	var water_mat := ShaderMaterial.new()
	water_mat.shader = _WATER_SHADER
	var rows_e: Array = (_solved.get(id, {}) as Dictionary).get("rows", [])
	var fall_mat := ShaderMaterial.new()
	fall_mat.shader = _FALL_SHADER
	var bund_buf := TerraceMesh.Buf.new()
	var boxes := TerraceMesh.paddy_boxes(grid)
	var waters: Array = []
	var falls: Array = []
	var canopies: Array = []
	var crop_mats: Array = []
	var canopy_mats: Array = []
	var cycles: Array = []
	var chunks := {}
	var dd: PackedFloat32Array = grid["d"]
	var fl: PackedFloat32Array = grid["flat"]
	var paddies: Array = s["paddies"]
	var total_floor := float((s["stats"] as Dictionary)["floor_m2"])
	var rng := RandomNumberGenerator.new()
	rng.seed = int(rr["seed"]) * 9173 + 7
	waters.resize(paddies.size())
	falls.resize(paddies.size())
	canopies.resize(paddies.size())
	crop_mats.resize(paddies.size())
	canopy_mats.resize(paddies.size())
	cycles.resize(paddies.size())
	for pi in paddies.size():
		if not boxes.has(pi):
			continue
		var pd: Dictionary = paddies[pi]
		# Each step its own crop and water; a step not dug yet is not drawn.
		var pm := int(pd["m"])
		if TerraceField.step_built(rr, pm) < 0.999:
			continue
		var ss := TerraceField.step_setting(rr, pm)
		var pcrop := str(ss["crop"])
		var pinfo := TerraceField.crop_info(pcrop)
		var pmesh := str(pinfo["mesh"])
		var pflood := bool(ss["flooded"])
		cycles[pi] = float(pinfo["cycle_d"])
		var canopy_mat := ShaderMaterial.new()
		canopy_mat.shader = _CANOPY_SHADER
		canopy_mat.set_shader_parameter("cycle", float(pinfo["cycle_d"]))
		canopy_mat.set_shader_parameter("height_m", float(pinfo["height"]))
		canopy_mat.set_shader_parameter("young", _col(pinfo["young"]))
		canopy_mat.set_shader_parameter("ripe", _col(pinfo["ripe"]))
		canopy_mat.set_shader_parameter("ripen_from", 0.78 if float(pinfo["food"]) > 0.0 else 0.9)
		canopy_mats[pi] = canopy_mat
		var crop_mat := ShaderMaterial.new()
		crop_mat.shader = _CROP_SHADER
		crop_mats[pi] = crop_mat
		var spacing := 0.0
		if not pmesh.is_empty():
			spacing = maxf(GardenCrops.spacing(pmesh) * 1.8, sqrt(total_floor / float(MAX_TUFTS)))
		# Plants are ranked down the paddy the way its crew works it, so a
		# planting or a cut shows as a line moving down the step.
		var r0 := Vector2.ZERO
		var rdir := Vector2(1, 0)
		var rlen := 1.0
		if pi < rows_e.size():
			var sp: Array = (rows_e[pi] as Dictionary)["spine"]
			if sp.size() >= 2:
				r0 = Vector2(float(sp[0][0]), float(sp[0][1]))
				var r1 := Vector2(float(sp[sp.size() - 1][0]), float(sp[sp.size() - 1][1]))
				rlen = maxf(r0.distance_to(r1), 0.5)
				rdir = (r1 - r0) / rlen
		var box: Rect2i = boxes[pi]
		var box_origin := origin + Vector2(box.position) * cell
		var fy := float(pd["floor_y"])
		var ff := TerraceMesh.paddy_field(grid, pi, box, "floor", 0.0, hh)
		var tris := PackedVector3Array()
		var segs := PackedVector2Array()
		TerraceMesh.march(ff, box.size.x, box.size.y, box_origin, cell, fy + 0.02, tris, segs)
		# The lip: floor edges on the downhill side or at the field's edge.
		var lip := PackedVector2Array()
		var i := 0
		while i + 1 < segs.size():
			var a := segs[i]
			var b := segs[i + 1]
			i += 2
			var mid := (a + b) * 0.5
			var d := TerraceMesh.sample(grid, dd, mid)
			var f := TerraceMesh.sample(grid, fl, mid)
			var d_edge := not is_nan(d) and absf(absf(d) - f) < 0.12
			if not d_edge or d < 0.0:
				lip.append(a)
				lip.append(b)
		if pcrop != "fallow" and float(pinfo["height"]) > 0.0:
			var b2 := TerraceMesh.Buf.new()
			var k := 0
			while k + 2 < tris.size():
				var ta := tris[k]
				var tb := tris[k + 1]
				var tc := tris[k + 2]
				b2.tri(ta, tb, tc, Vector3.UP, Color.WHITE, Vector2(ta.x, ta.z), Vector2(tb.x, tb.z),
					Vector2(tc.x, tc.z), Vector2(0, 1), Vector2(0, 1), Vector2(0, 1))
				k += 3
			TerraceMesh.skirts(b2, segs, fy + 0.02)
			if not b2.v.is_empty():
				var cn := MeshInstance3D.new()
				cn.name = "Canopy_%d" % pi
				cn.mesh = b2.mesh()
				cn.material_override = canopy_mat
				cn.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				cn.visibility_range_begin = CANOPY_FROM_M
				cn.visibility_range_begin_margin = 10.0
				cn.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
				cn.set_meta("skip_prop_collision", true)
				root.add_child(cn)
				canopies[pi] = cn
		if pflood:
			TerraceMesh.bunds(bund_buf, lip, fy, bund_h + 0.06, 0.7, 0.32, EARTH)
			var wf := TerraceMesh.paddy_field(grid, pi, box, "water", bund_h, hh)
			var wt := PackedVector3Array()
			var ws := PackedVector2Array()
			TerraceMesh.march(wf, box.size.x, box.size.y, box_origin, cell, fy + bund_h, wt, ws)
			var wm := MeshInstance3D.new()
			wm.name = "Water_%d" % pi
			wm.mesh = TerraceMesh.flat_mesh(wt)
			wm.material_override = water_mat
			wm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			wm.visible = false
			wm.set_meta("skip_prop_collision", true)
			root.add_child(wm)
			waters[pi] = wm
		else:
			TerraceMesh.bunds(bund_buf, lip, fy, 0.08, 0.5, 0.3, GRASSY_EARTH)
		# Where it spills: a few points along its lip, each a ribbon down the
		# riser to the floor below.
		var lip_len := 0.0
		var q := 0
		while q + 1 < lip.size():
			lip_len += lip[q].distance_to(lip[q + 1])
			q += 2
		var pts := TerraceMesh.spread_points(lip, clampi(int(lip_len / FALL_PER_M), 1, FALL_MAX))
		var dn: PackedInt32Array = pd["down"]
		var stop_y := fy - hh
		if not dn.is_empty():
			stop_y = float((paddies[dn[0]] as Dictionary)["floor_y"])
		var fbuf := TerraceMesh.Buf.new()
		for p in pts:
			var e := 0.4
			var gd := Vector2(TerraceMesh.sample(grid, dd, p + Vector2(e, 0)) - TerraceMesh.sample(grid, dd, p - Vector2(e, 0)),
				TerraceMesh.sample(grid, dd, p + Vector2(0, e)) - TerraceMesh.sample(grid, dd, p - Vector2(0, e)))
			var down_dir := Vector2.ZERO
			if not is_nan(gd.x) and not is_nan(gd.y) and gd.length() > 1e-5:
				down_dir = -gd.normalized()
			var path := PackedVector3Array([Vector3(p.x, fy + bund_h + 0.06, p.y)])
			path.append_array(TerraceMesh.fall_path(grid, p + down_dir * 0.35, stop_y))
			TerraceMesh.ribbon(fbuf, path, 0.75)
		var fm := MeshInstance3D.new()
		fm.name = "Fall_%d" % pi
		fm.mesh = fbuf.mesh()
		fm.material_override = fall_mat
		fm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		fm.visible = false
		fm.set_meta("skip_prop_collision", true)
		root.add_child(fm)
		falls[pi] = fm
		# The crop near by: one plant per `spacing`, jittered, in 16 m chunks.
		if spacing > 0.0 and pcrop != "fallow":
			var x0 := box_origin.x
			var z0 := box_origin.y
			var w := float(box.size.x - 1) * cell
			var h := float(box.size.y - 1) * cell
			var nx := int(w / spacing)
			var nz := int(h / spacing)
			for jz in nz:
				for ix in nx:
					var px := x0 + (float(ix) + 0.5 + rng.randf_range(-0.35, 0.35)) * spacing
					var pz := z0 + (float(jz) + 0.5 + rng.randf_range(-0.35, 0.35)) * spacing
					var fv := _box_sample(ff, box, cell, box_origin, Vector2(px, pz))
					if fv <= 0.02:
						continue
					var ck := "%d|%d|%d" % [pi, floori(px / CHUNK_M), floori(pz / CHUNK_M)]
					if not chunks.has(ck):
						chunks[ck] = {"pi": pi, "mesh": pmesh, "cycle": float(pinfo["cycle_d"]),
							"shadow": bool(GardenCrops.info(pmesh).get("shadow", false)),
							"mature": float(GardenCrops.info(pmesh).get("mature", 0.7)), "list": []}
					var b3 := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * rng.randf_range(0.85, 1.12))
					var rank := clampf((Vector2(px, pz) - r0).dot(rdir) / rlen + rng.randf_range(-0.03, 0.03), 0.001, 0.999)
					((chunks[ck] as Dictionary)["list"] as Array).append([Transform3D(b3, Vector3(px, fy, pz)),
						rng.randf_range(-1.5, 1.5), rank])
	var bund := MeshInstance3D.new()
	bund.name = "Bunds"
	bund.mesh = bund_buf.mesh()
	var bm := StandardMaterial3D.new()
	bm.vertex_color_use_as_albedo = true
	bm.vertex_color_is_srgb = true
	bm.roughness = 0.95
	bund.material_override = bm
	bund.set_meta("skip_prop_collision", true)
	root.add_child(bund)
	var tufts := 0
	for ck in chunks.keys():
		var cd: Dictionary = chunks[ck]
		var list: Array = cd["list"]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = GardenCrops.mesh(str(cd["mesh"]))
		mm.instance_count = list.size()
		for n in list.size():
			var e2: Array = list[n]
			mm.set_instance_transform(n, e2[0])
			mm.set_instance_custom_data(n, Color(float(e2[1]), float(cd["cycle"]),
				float(cd["mature"]), float(e2[2])))
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Crop_%s" % str(ck).replace("|", "_")
		mmi.multimesh = mm
		mmi.material_override = crop_mats[int(cd["pi"])]
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if bool(cd["shadow"]) \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.visibility_range_end = CROP_DRAW_M
		mmi.visibility_range_end_margin = 10.0
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		mmi.set_meta("skip_prop_collision", true)
		root.add_child(mmi)
		tufts += list.size()
	_vis[id] = {"node": root, "waters": waters, "falls": falls, "crop_mats": crop_mats,
		"canopy_mats": canopy_mats, "cycles": cycles, "bund_h": bund_h, "flooded": flooded,
		"tufts": tufts, "plant_abs_h": float(rr["plant_abs_h"]), "canopies": canopies}
	if selected == id:
		set_selected(id)


static func _col(a: Variant) -> Color:
	if a is Array and (a as Array).size() >= 3:
		return Color(float(a[0]), float(a[1]), float(a[2]))
	return Color(0.4, 0.6, 0.2)


static func _box_sample(field: PackedFloat32Array, box: Rect2i, cell: float, box_origin: Vector2, p: Vector2) -> float:
	var fx := (p.x - box_origin.x) / cell
	var fz := (p.y - box_origin.y) / cell
	if fx < 0.0 or fz < 0.0 or fx > float(box.size.x - 1) or fz > float(box.size.y - 1):
		return -1.0
	var ci := mini(int(fx), box.size.x - 2)
	var cj := mini(int(fz), box.size.y - 2)
	var tx := fx - float(ci)
	var tz := fz - float(cj)
	var k := cj * box.size.x + ci
	var a := lerpf(field[k], field[k + 1], tx)
	var b := lerpf(field[k + box.size.x], field[k + box.size.x + 1], tx)
	return lerpf(a, b, tz)


## Water levels, spills and the crop's clock from the graph node (twice a
## second).
func _update_live() -> void:
	var view := ServiceLocator.graph()
	var now := _now_h()
	for id in _vis.keys():
		var v: Dictionary = _vis[id]
		var specs: Dictionary = {}
		if view != null and view.has_method("terrace_node_specs"):
			specs = view.call("terrace_node_specs", str(id))
		var fills: Array = specs.get("terrace_fill", [])
		var spills: Array = specs.get("terrace_spill", [])
		var waters: Array = v["waters"]
		var bund_h := float(v["bund_h"])
		for i in waters.size():
			var wm: Variant = waters[i]
			if not (wm is MeshInstance3D) or not is_instance_valid(wm):
				continue
			var f := float(fills[i]) if i < fills.size() else 0.0
			(wm as MeshInstance3D).visible = f > 0.03
			(wm as MeshInstance3D).position.y = (f - 1.0) * bund_h
		var falls: Array = v["falls"]
		for i in falls.size():
			var fm: Variant = falls[i]
			if not (fm is MeshInstance3D) or not is_instance_valid(fm):
				continue
			var sp := float(spills[i]) if i < spills.size() else 0.0
			var on := sp > 1.0
			(fm as MeshInstance3D).visible = on
			if on:
				(fm as MeshInstance3D).set_instance_shader_parameter("flow",
					clampf(log(1.0 + sp) / log(1.0 + 20000.0), 0.15, 1.0))
		# Each paddy's crop from its own season: sown when its crew planted
		# it, shown as far down the step as the planting (and the cut) got.
		var pv: Array = specs.get("terrace_view", []) as Array
		var p := float(v["plant_abs_h"])
		var now_d := (now - p) / 24.0 if p >= 0.0 else -1.0
		var cms: Array = v["crop_mats"]
		var nms: Array = v["canopy_mats"]
		var cys: Array = v["cycles"]
		for i in cms.size():
			var cm: Variant = cms[i]
			if not (cm is ShaderMaterial):
				continue
			var fixed := -1.0
			var show := 2.0
			var cut := -1.0
			var cover := 1.0
			if i < pv.size():
				var e: Array = pv[i]
				var st := str(e[0])
				var cyc := maxf(float(cys[i]) * 24.0, 1.0)
				match st:
					TerraceFarm.STAGE_GROW:
						fixed = clampf((now - float(e[1])) / cyc, 0.0, 0.999)
					TerraceFarm.STAGE_HARVEST:
						fixed = 0.999
						cut = float(e[3])
						cover = 1.0 - cut
					TerraceFarm.STAGE_PLANT:
						fixed = TerraceField.FALLOW + 0.03
						show = float(e[2])
						cover = 0.0
					_:
						fixed = 0.0
						cover = 0.0
			(cm as ShaderMaterial).set_shader_parameter("now_d", now_d)
			(cm as ShaderMaterial).set_shader_parameter("fixed_f", fixed)
			(cm as ShaderMaterial).set_shader_parameter("rank_show", show)
			(cm as ShaderMaterial).set_shader_parameter("rank_cut", cut)
			var nm2: Variant = nms[i]
			if nm2 is ShaderMaterial:
				(nm2 as ShaderMaterial).set_shader_parameter("now_d", now_d)
				(nm2 as ShaderMaterial).set_shader_parameter("fixed_f", fixed)
				(nm2 as ShaderMaterial).set_shader_parameter("cover", cover)


func _now_h() -> float:
	var main: Node = loader.get("_main") if loader != null else null
	if main != null and main.has_method("get_absolute_hours"):
		return float(main.call("get_absolute_hours"))
	return 0.0


## One line for probes.
func debug_line() -> String:
	var n_tufts := 0
	for v in _vis.values():
		n_tufts += int((v as Dictionary).get("tufts", 0))
	return "terraces: %d fields, %d tiles, %d tufts, %d rebuilds (last %.1f ms)" % [
		layer.fields.size(), _keys.size(), n_tufts, rebuild_count, last_rebuild_ms]


# ---------------------------------------------------------------------------
# The work: crews digging the steps and working the paddies
# ---------------------------------------------------------------------------

## A record patch with no undo step (the crews' progress, the dig project).
func _write_quiet(id: String, patch: Dictionary) -> void:
	if layer.find(id).is_empty():
		return
	layer.update(id, patch)
	layer.save()


func _bridge() -> Object:
	var view := ServiceLocator.graph()
	if view == null or not view.has_method("npc_population_bridge"):
		return null
	return view.call("npc_population_bridge") as Object


func _centre(id: String) -> Vector2:
	var poly := TerraceField.poly_of(layer.find(id))
	var c := Vector2.ZERO
	for p in poly:
		c += p
	return c / float(maxi(poly.size(), 1))


func _status(id: String, key: String, text: String) -> void:
	var d: Dictionary = work_status.get(id, {})
	d[key] = text
	work_status[id] = d


func _service_work() -> void:
	var bridge := _bridge()
	_rig_want.clear()
	for r in layer.fields:
		var id := str((r as Dictionary).get("id", ""))
		if solved(id).is_empty():
			continue
		_service_dig(id, bridge)
		_service_farm(id, bridge)
	for id2 in _rigs.keys():
		if not _rig_want.has(id2):
			_park_rig(str(id2))
	for id3 in _rig_want.keys():
		_place_rig(str(id3), _rig_want[id3])


## The dig: one site project per field, a task per step (top step first),
## each worked in a line along the step; the cut shows as it goes.
func _service_dig(id: String, bridge: Object) -> void:
	var r := layer.find(id)
	var rr := TerraceField.resolve(r)
	var mode := str(rr["build_mode"])
	if mode == "instant":
		_status(id, "dig", "")
		return
	var steps: Array = (_solved.get(id, {}) as Dictionary).get("dig", [])
	var built: Dictionary = (rr["built"] as Dictionary).duplicate()
	var left := 0
	for st in steps:
		if float(built.get(str(int((st as Dictionary)["m"])), 0.0)) < 0.999:
			left += 1
	if left == 0:
		_status(id, "dig", "All %d steps dug" % steps.size())
		if not (r.get("dig", {}) as Dictionary).is_empty():
			_write_quiet(id, {"dig": {}})
		return
	if bridge == null:
		_status(id, "dig", "Waiting for a camp with people to dig it")
		return
	var dig: Dictionary = (r.get("dig", {}) as Dictionary).duplicate(true)
	var iid := str(dig.get("iid", ""))
	var pid := str(dig.get("pid", ""))
	var project: Dictionary = {}
	if not iid.is_empty() and not pid.is_empty():
		var store: Object = bridge.call("project_store_for", iid)
		if store != null:
			project = store.call("find", pid)
	if project.is_empty() or str(project.get("state", "")) == "cancelled" \
			or str(dig.get("mode", "")) != mode:
		if not project.is_empty() and str(project.get("state", "")) == "active":
			bridge.call("cancel_project", iid, pid)
		dig = _start_dig(id, bridge, steps, built, mode)
		if dig.is_empty():
			_status(id, "dig", "Waiting for a camp with people to dig it")
			return
		_write_quiet(id, {"dig": dig})
		return
	var board: Object = bridge.call("chore_board_for", iid)
	var fr: Dictionary = SiteProject.task_fractions(project, board)
	var base: Dictionary = dig.get("base", {})
	var machine := TerraceDig.MACHINES.has(mode)
	# What the machine burnt since the last look: its hours on each step's
	# progress × its diesel an hour, out of the store on the node's fuel_in.
	if machine:
		var seen: Dictionary = (dig.get("seen", {}) as Dictionary).duplicate()
		var want_l := 0.0
		var mh_done := 0.0
		for st0 in steps:
			var sd0: Dictionary = st0
			var k0 := "s%d" % int(sd0["m"])
			if not fr.has(k0):
				continue
			var est0 := TerraceDig.estimate(float(sd0["vol_m3"]), float(sd0["floor_m2"]), mode,
				float(sd0["length_m"]))
			var b00 := float(base.get(str(int(sd0["m"])), 0.0))
			var df := maxf(float(fr[k0]) - float(seen.get(k0, 0.0)), 0.0) * (1.0 - b00)
			want_l += df * float(est0["fuel_l"])
			mh_done += df * float(est0["machine_h"])
			seen[k0] = float(fr[k0])
		var paused_fuel := bool(dig.get("no_fuel", false))
		if want_l > 0.0 or paused_fuel:
			var view := ServiceLocator.graph()
			var got: Dictionary = view.call("terrace_take_fuel", id, maxf(want_l, 0.05)) \
				if view != null and view.has_method("terrace_take_fuel") else {}
			var led: Dictionary = (dig.get("ledger", {}) as Dictionary).duplicate()
			led["machine_h"] = float(led.get("machine_h", 0.0)) + mh_done
			led["fuel_l"] = float(led.get("fuel_l", 0.0)) + want_l
			if not bool(got.get("wired", false)):
				led["fuel_bought_l"] = float(led.get("fuel_bought_l", 0.0)) + want_l
			dig["ledger"] = led
			var dry := bool(got.get("wired", false)) and float(got.get("litres", 0.0)) < maxf(want_l, 0.05) * 0.5
			if dry != paused_fuel:
				bridge.call("set_project_paused", iid, pid, dry)
				dig["no_fuel"] = dry
		dig["seen"] = seen
		_write_quiet(id, {"dig": dig})
		if bool(dig.get("no_fuel", false)):
			_status(id, "dig", "Out of diesel — the %s has stopped. Fill the diesel store on the field's fuel input."
				% str((TerraceDig.MACHINES[mode] as Dictionary)["label"]).to_lower())
			return
	var changed := false
	var finished := false
	var working := 0
	var at_step := ""
	for st in steps:
		var sd: Dictionary = st
		var m := int(sd["m"])
		var key := "s%d" % m
		if not fr.has(key):
			continue
		var b0 := float(base.get(str(m), 0.0))
		var f := float(fr[key])
		var q := 1.0 if f >= 0.999 else b0 + (1.0 - b0) * floorf(f / DIG_QUANT) * DIG_QUANT
		if q > float(built.get(str(m), 0.0)) + 1e-4:
			built[str(m)] = q
			changed = true
			if q >= 0.999:
				finished = true
		if f > 0.0 and f < 0.999 and at_step.is_empty():
			at_step = "step %d of %d · %d %%" % [steps.find(st) + 1, steps.size(), int(f * 100.0)]
			if machine:
				# The machine works up and down the step as the job goes.
				var ta := TerraceFarm.tractor_at(sd["spine"], float(sd["half_w"]), f)
				_rig_want[id] = {"model": str((TerraceDig.MACHINES[mode] as Dictionary)["model"]),
					"pos": ta["pos"], "dir": ta["dir"], "busy": true}
	for t in project.get("tasks", []):
		var cid := str((t as Dictionary).get("chore_id", ""))
		if board != null and not cid.is_empty():
			working += int(board.call("worker_count", cid))
	if changed:
		_write_quiet(id, {"built": built})
		_geo_dirty = true
		_graph_dirty[id] = true
		if finished:
			_vis_dirty[id] = true
	var how := "by hand" if mode == "hand" else "with the %s" % str((TerraceDig.MACHINES[mode] as Dictionary)["label"]).to_lower()
	if _rig_want.has(id) and working == 0:
		_rig_want[id]["busy"] = false
	if at_step.is_empty():
		_status(id, "dig", "%d of %d steps dug %s · %s" % [steps.size() - left, steps.size(), how,
			"%d at work" % working if working > 0 else "waiting for the crew"])
	else:
		_status(id, "dig", "Digging %s %s · %d at work" % [at_step, how, working])


func _start_dig(id: String, bridge: Object, steps: Array, built: Dictionary, mode: String) -> Dictionary:
	var c := _centre(id)
	var iid := str(bridge.call("nearest_crew_habitat", c))
	if iid.is_empty():
		return {}
	var rows: Array = []
	var meta := {}
	var base := {}
	var prev := ""
	var nm := str(layer.find(id).get("name", "Terraces"))
	var machine := TerraceDig.MACHINES.has(mode)
	for st in steps:
		var sd: Dictionary = st
		var m := int(sd["m"])
		var b0 := clampf(float(built.get(str(m), 0.0)), 0.0, 1.0)
		if b0 >= 0.999:
			continue
		base[str(m)] = b0
		var est := TerraceDig.estimate(float(sd["vol_m3"]), float(sd["floor_m2"]), mode,
			float(sd["length_m"]))
		var mid: Vector2 = NpcRowWork.along(sd["spine"], 0.5)["pos"]
		var tid := "s%d" % m
		var row := {"task_id": tid,
			"label": "%s step %d of %s" % ["Dig" if not machine else "%s: cut" % str((TerraceDig.MACHINES[mode] as Dictionary)["label"]),
				rows.size() + 1, nm],
			"chore_hours": maxf(float(est["hours"]) * (1.0 - b0), 0.1),
			"min_workers": int(est["crew_min"]), "max_workers": int(est["crew_max"]),
			"exposure": NpcWeatherGate.EXPOSURE_OUTDOOR, "priority": 0,
			"target": {"kind": "pos", "x": mid.x, "z": mid.y}}
		if not prev.is_empty():
			row["depends_on"] = [prev]
		rows.append(row)
		meta[tid] = sd
		prev = tid
	if rows.is_empty():
		return {}
	var pid := str(bridge.call("create_site_project", iid, "terrace_build", "Dig %s" % nm, "",
		c, rows, WORK_WINDOW, {}, {"terrace_id": id}))
	if pid.is_empty():
		return {}
	var store: Object = bridge.call("project_store_for", iid)
	var board: Object = bridge.call("chore_board_for", iid)
	var project: Dictionary = store.call("find", pid) if store != null else {}
	for t in project.get("tasks", []):
		var td: Dictionary = t
		var sd2: Dictionary = meta.get(str(td.get("task_id", "")), {})
		if sd2.is_empty() or board == null:
			continue
		board.call("update_chore", str(td.get("chore_id", "")), {"row_spine": sd2["spine"],
			"row_half_w": float(sd2["half_w"]), "pose": "dig", "terrace_id": id, "tool": "shovel"})
	return {"iid": iid, "pid": pid, "mode": mode, "base": base}


func _drop_dig(id: String) -> void:
	var dig: Dictionary = layer.find(id).get("dig", {})
	var bridge := _bridge()
	if bridge != null and not dig.is_empty():
		bridge.call("cancel_project", str(dig.get("iid", "")), str(dig.get("pid", "")))
	if not dig.is_empty():
		_write_quiet(id, {"dig": {}})


## The farm jobs: each open job a chore on the camp's board, worked in a line
## down its paddy; how far each has got goes back to the engine.
func _service_farm(id: String, bridge: Object) -> void:
	var rr := TerraceField.resolve(layer.find(id))
	var view := ServiceLocator.graph()
	if view == null or not view.has_method("terrace_node_specs"):
		return
	var owner := "terr|%s" % id
	if str(rr["labour"]) == "machines":
		_want_tractor(id, view.call("terrace_node_specs", id) as Dictionary)
	if str(rr["labour"]) == "free":
		_drop_farm_chores(id, bridge)
		_status(id, "crew", "")
		return
	var specs: Dictionary = view.call("terrace_node_specs", id)
	var jobs: Array = specs.get("terrace_jobs", []) as Array
	if bridge == null:
		_status(id, "crew", "Waiting for a camp with people to farm it" if not jobs.is_empty() else "")
		return
	var iid := str(_farm_iid.get(id, ""))
	var board: Object = bridge.call("chore_board_for", iid) if not iid.is_empty() else null
	if board == null:
		iid = str(bridge.call("nearest_crew_habitat", _centre(id)))
		_farm_iid[id] = iid
		board = bridge.call("chore_board_for", iid) if not iid.is_empty() else null
	if board == null:
		_status(id, "crew", "Waiting for a camp with people to farm it" if not jobs.is_empty() else "")
		return
	var rows: Array = (_solved.get(id, {}) as Dictionary).get("rows", [])
	var nm := str(rr["name"])
	var want := {}
	var credit := {}
	var active := 0
	var working := 0
	var first := ""
	for j in jobs:
		var jd: Dictionary = j
		var pi := int(jd["paddy"])
		var key := "%s|%d|%d" % [owner, pi, int(jd["seq"])]
		want[key] = true
		var ch: Dictionary = board.call("find_by_key", key)
		if ch.is_empty():
			if active >= FARM_ACTIVE_MAX or pi >= rows.size():
				continue
			var row: Dictionary = rows[pi]
			var sp: Array = row["spine"]
			if sp.size() < 2:
				continue
			var mid: Vector2 = NpcRowWork.along(sp, 0.5)["pos"]
			var hours := maxf(float(jd["need_h"]) * (1.0 - float(jd["frac"])), 0.1)
			var cid := str(board.call("add_chore", "%s, step %d of %s" % [str(jd["verb"]), pi + 1, nm],
				hours, {"repeat": "once", "window": WORK_WINDOW.duplicate(),
					"exposure": NpcWeatherGate.EXPOSURE_OUTDOOR,
					"min_workers": int(jd["crew_min"]), "max_workers": int(jd["crew_max"]),
					"target": {"kind": "pos", "x": mid.x, "z": mid.y}, "chore_key": key}))
			if cid.is_empty():
				continue
			board.call("update_chore", cid, {"row_spine": sp, "row_half_w": float(row["half_w"]),
				"pose": "dig", "terrace_base": float(jd["frac"]), "terrace_id": id,
				"tool": FARM_TOOLS.get(str(jd["task"]), "hoe")})
			ch = board.call("find", cid)
		active += 1
		var hh := maxf(float(ch.get("chore_hours", 1.0)), 0.001)
		var f := clampf(float(ch.get("progress_h", 0.0)) / hh, 0.0, 1.0)
		if int(ch.get("done_day", -1)) >= 0:
			f = 1.0
		var b0 := float(ch.get("terrace_base", 0.0))
		credit[str(pi)] = [int(jd["seq"]), b0 + (1.0 - b0) * f]
		var w := int(board.call("worker_count", str(ch.get("id", ""))))
		working += w
		if first.is_empty() and w > 0:
			first = str(jd["verb"])
	var gone: Array = []
	for c in board.get("chores"):
		var cd: Dictionary = c
		var ck := str(cd.get("chore_key", ""))
		if ck.begins_with(owner + "|") and not want.has(ck):
			gone.append(str(cd.get("id", "")))
	for cid2 in gone:
		board.call("remove_chore", cid2)
	view.call("set_terrace_credit", id, credit)
	var pin := not jobs.is_empty() and bool(bridge.call("needs_pin_to_work", iid))
	bridge.call("pin_for_work", iid, owner, pin)
	if jobs.is_empty():
		_status(id, "crew", "")
	elif working > 0:
		_status(id, "crew", "%d at work · %s" % [working, first])
	else:
		_status(id, "crew", "%d %s waiting for the crew" % [jobs.size(), "job" if jobs.size() == 1 else "jobs"])
	var d: Dictionary = work_status.get(id, {})
	d["crew_n"] = working
	d["jobs"] = jobs.size()
	work_status[id] = d


func _drop_farm_chores(id: String, bridge: Object) -> void:
	if bridge == null:
		return
	var iid := str(_farm_iid.get(id, ""))
	if iid.is_empty():
		return
	var owner := "terr|%s" % id
	bridge.call("pin_for_work", iid, owner, false)
	var board: Object = bridge.call("chore_board_for", iid)
	if board == null:
		return
	var gone: Array = []
	for c in board.get("chores"):
		if str((c as Dictionary).get("chore_key", "")).begins_with(owner + "|"):
			gone.append(str((c as Dictionary).get("id", "")))
	for cid in gone:
		board.call("remove_chore", cid)


func _drop_work(id: String) -> void:
	_drop_farm_chores(id, _bridge())
	_drop_dig(id)
	_farm_iid.erase(id)
	work_status.erase(id)
	_park_rig(id)


# ---------------------------------------------------------------------------
# The machines at the work (the game's own skid steer and tractor)
# ---------------------------------------------------------------------------

func _want_tractor(id: String, specs: Dictionary) -> void:
	var rows: Array = (_solved.get(id, {}) as Dictionary).get("rows", [])
	var mjobs: Array = (specs.get("terrace_machine", []) as Array).duplicate()
	# The paddy it is on first (the others wait for it).
	mjobs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["frac"]) > float(b["frac"]) if (float(a["frac"]) > 0.0) != (float(b["frac"]) > 0.0) 			else int(a["paddy"]) < int(b["paddy"]))
	for j in mjobs:
		var jd: Dictionary = j
		var pi := int(jd["paddy"])
		var f := float(jd["frac"])
		if pi >= rows.size() or f >= 0.999:
			continue
		var row: Dictionary = rows[pi]
		if (row["spine"] as Array).size() < 2:
			continue
		var ta := TerraceFarm.tractor_at(row["spine"], float(row["half_w"]), f)
		_rig_want[id] = {"model": TerraceFarm.MACHINE_MODEL, "pos": ta["pos"], "dir": ta["dir"],
			"busy": bool(specs.get("fuel_ok", true))}
		var d: Dictionary = work_status.get(id, {})
		var mword := str(jd["machine"])
		d["machine"] = "%s · %s, step %d · %d %%" % [mword.substr(0, 1).to_upper() + mword.substr(1),
			TerraceFarm.TASK_LABELS.get(str(jd["task"]), str(jd["task"])).to_lower(), pi + 1, int(f * 100.0)] \
			if bool(specs.get("fuel_ok", true)) else "The tractor is out of diesel"
		work_status[id] = d
		return
	var d2: Dictionary = work_status.get(id, {})
	d2["machine"] = ""
	work_status[id] = d2


## Show (or move) a field's machine.
func _place_rig(id: String, want: Dictionary) -> void:
	var model := str(want.get("model", ""))
	var e: Dictionary = _rigs.get(id, {})
	if e.is_empty() or str(e.get("model", "")) != model or not is_instance_valid(e.get("node")):
		_park_rig(id)
		var node := _make_rig(model)
		add_child(node)
		var p0: Vector2 = want["pos"]
		node.global_position = Vector3(p0.x, _ground(p0), p0.y)
		e = {"node": node, "model": model, "yaw_off": _rig_yaw_off(model)}
		_rigs[id] = e
	e["target"] = want["pos"]
	e["dir"] = want["dir"]
	e["busy"] = bool(want.get("busy", true))


func _park_rig(id: String) -> void:
	var e: Dictionary = _rigs.get(id, {})
	var n: Variant = e.get("node")
	if n is Node and is_instance_valid(n):
		(n as Node).queue_free()
	_rigs.erase(id)


## The machine's own model (ModelCatalog), or a plain stand-in when the art
## is not installed. Not a placed prop: it collides with nothing.
func _make_rig(model: String) -> Node3D:
	var root := Node3D.new()
	root.name = "Machine"
	root.top_level = true
	var inst: Node3D = null
	if not ModelCatalog.find(model).is_empty():
		inst = ModelCatalog.instantiate(model, {})
	if inst != null:
		inst.name = "Model"
		root.add_child(inst)
	else:
		var body := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(1.3, 1.1, 2.6)
		body.mesh = bm
		body.position = Vector3(0, 1.0, 0)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.9, 0.45, 0.1)
		body.material_override = mat
		root.add_child(body)
	for mi in root.find_children("*", "GeometryInstance3D", true, false):
		(mi as Node).set_meta("skip_prop_collision", true)
	root.set_meta("rig_model", model)
	return root


## The turn that faces a machine's model forward (PlacedVehicle's yaw_deg for
## its vehicle profile; a stand-in faces -Z).
static func _rig_yaw_off(model: String) -> float:
	var veh := str(ModelCatalog.find(model).get("vehicle", ""))
	var prof: Dictionary = PlacedVehicle.PROFILES.get(veh, {}) as Dictionary
	return deg_to_rad(float(prof.get("yaw_deg", 0.0)))


func _ground(p: Vector2) -> float:
	if loader == null:
		return 0.0
	return float(loader.call("surface_height_at", p.x, p.y))


## Every frame: each machine drives toward where its job has got to and turns
## to its heading (the job moves in steps; the machine eases between them).
func _drive_rigs(delta: float) -> void:
	for id in _rigs.keys():
		var e: Dictionary = _rigs[id]
		var n: Node3D = e.get("node") as Node3D
		if n == null or not is_instance_valid(n) or not e.has("target"):
			continue
		var cur := Vector2(n.global_position.x, n.global_position.z)
		var tgt: Vector2 = e["target"]
		var step := RIG_SPEED_MPS * delta
		var nxt := cur.move_toward(tgt, step)
		var dir: Vector2 = e["dir"]
		if cur.distance_to(tgt) > 0.4:
			dir = (tgt - cur).normalized()
		n.global_position = Vector3(nxt.x, _ground(nxt), nxt.y)
		var want_yaw := atan2(-dir.x, -dir.y) + float(e.get("yaw_off", 0.0))
		n.rotation.y = lerp_angle(n.rotation.y, want_yaw, clampf(delta * 3.0, 0.0, 1.0))


## Probes: {id: {model, pos (Vector3), busy}} for every machine drawn.
func rigs_debug() -> Dictionary:
	var out := {}
	for id in _rigs.keys():
		var e: Dictionary = _rigs[id]
		var n: Node3D = e.get("node") as Node3D
		out[id] = {"model": str(e.get("model", "")), "busy": bool(e.get("busy", false)),
			"pos": n.global_position if n != null and is_instance_valid(n) else Vector3.INF,
			"target": e.get("target", Vector2.INF)}
	return out
