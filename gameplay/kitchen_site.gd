class_name KitchenSite
extends Node3D

## A meal being cooked, drawn at the kitchen (NPC life pass, Phase 7). The
## build sites' labour mode applied to a meal step: the kitchen's recipe step
## is a chore on the board (`mach|<kitchen>|<step>`, several cooks at once);
## its credited labour, mapped onto MealJobPlan's own schedule, is the time
## the plan is drawn at. A lane is drawn only while a real person is DOING
## that chore here: their own body is hidden (NpcStandIns) and the lane wears
## their colour, at the job's station with its tool in hand (the clip's IK on
## the tool's sockets, FabContextRig's path for where the tool is) — chopping
## at the prep table, stirring at the stove, plating at the serving table,
## washing up at the basins.
##
## On a prop that is not a camp kitchen (an EZ-up bound to the Kitchen node)
## the counters are drawn too while a meal is under way (CampKitchenBuilder,
## no canopy), so the cooks have something to work at.
##
## Attached by PlacedPropRuntime to a camp kitchen and to any prop bound to a
## graph node (it checks the node's role itself and steps aside if it is not
## a kitchen). Nothing here integrates: progress comes from the board.

const NODE_NAME := "KitchenSite"
const POLL_S := 0.25
const ROLE_CHECK_S := 2.0
const EASE_S := 1.0
const SITE_RADIUS_M := 14.0
const CULL_M := 90.0
const MAX_LANES := 6

var _prop: PlacedProp = null
var _model: Node3D = null
var _main: Node = null
var _gid := ""
var _is_kitchen_model := false
var _poll := 0.0
var _role_t := 0.0
var _status: Dictionary = {}
var _tl: Dictionary = {}
var _tl_key := ""
var _t_disp := 0.0
var _t_target := 0.0
var _crew: Array = []          # [{fig, tools: {id: Node3D}}]
var _lane_of: Dictionary = {}  # agent id -> lane
var _clips: Dictionary = {}
var _rigs: Dictionary = {}
var _fx_t := 0.0
var _furniture: Node3D = null
var _label: Label3D = null


static func attach(prop: PlacedProp, rec: Dictionary) -> void:
	if prop == null or prop.get_node_or_null(NODE_NAME) != null:
		return
	var is_kitchen := str(rec.get("model_id", "")) == CampKitchenBuilder.MODEL_ID
	if not is_kitchen and str(rec.get("graph_item_id", "")).is_empty():
		return
	var s := KitchenSite.new()
	s.name = NODE_NAME
	s._is_kitchen_model = is_kitchen
	prop.add_child(s)


func _ready() -> void:
	_prop = get_parent() as PlacedProp
	_model = _prop.get_node_or_null("ModelRoot") as Node3D if _prop != null else null
	_main = get_tree().current_scene
	_role_t = ROLE_CHECK_S   # check on the first frame


func _stand_key() -> String:
	return "kitchen:%s" % (_prop.prop_id if _prop != null else "")


func _exit_tree() -> void:
	NpcStandIns.set_for(_stand_key(), {})


## The kitchen graph node this prop is bound to ("" = none / not a kitchen).
func _resolve_gid() -> String:
	var g := ServiceLocator.graph()
	if g == null or _prop == null:
		return ""
	var model = g.get("model")
	if model == null:
		return ""
	var rec := PlacedPropService.get_prop_record(_main, _prop.prop_id)
	var gid := str(rec.get("graph_item_id", ""))
	if not gid.is_empty():
		var it: Dictionary = model.get_item(gid)
		if str((it.get("specs", {}) as Dictionary).get("role", "")) == "kitchen":
			return gid
	# A camp kitchen with no binding: the kitchen node bound to it, if any.
	for it in model.items:
		var sp: Dictionary = (it as Dictionary).get("specs", {})
		if str(sp.get("role", "")) == "kitchen" and str(sp.get("bound_prop_id", "")) == _prop.prop_id:
			return str((it as Dictionary).get("id", ""))
	return ""


## Duck-typed on purpose: naming the bridge's class here would pull its
## autoload dependencies into every --script selftest that loads a placed prop.
func _bridge() -> Object:
	var g := ServiceLocator.graph()
	if g == null or not g.has_method("npc_population_bridge"):
		return null
	return g.call("npc_population_bridge")


func _process(delta: float) -> void:
	if _prop == null or _model == null:
		return
	_role_t += delta
	if _role_t >= ROLE_CHECK_S:
		_role_t = 0.0
		_gid = _resolve_gid()
		if _gid.is_empty() and not _is_kitchen_model:
			# Bound to something that is not a kitchen: nothing to draw, ever
			# (until the binding changes, which rebuilds the prop).
			_set_active(false)
			set_process(false)
			return
	if _gid.is_empty():
		_set_active(false)
		return
	transform = _site_xf()
	_poll += delta
	if _poll >= POLL_S:
		_poll = 0.0
		_poll_status()
	if _tl.is_empty() or not bool(_status.get("found", false)):
		_set_active(false)
		return
	_set_active(true)
	var rate := SimFxRate.rate(_main, SimFxRate.SYS_NPC) if _main != null else 1.0
	_fx_t += delta * maxf(rate, 0.0)
	_t_disp = lerpf(_t_disp, _t_target, clampf(delta / EASE_S, 0.0, 1.0))
	var st := CrewJobPlan.state_at(_tl, _t_disp)
	_apply_crew(st, delta, rate)
	_update_label(st)


## The model's place, without its scale (stations are metres).
func _site_xf() -> Transform3D:
	var xf := _model.transform
	return Transform3D(xf.basis.orthonormalized(), xf.origin)


func _poll_status() -> void:
	var b := _bridge()
	if b == null:
		_status = {"found": false}
		return
	var c := _prop.global_position
	_status = b.call("kitchen_status", _gid, Vector2(c.x, c.z), SITE_RADIUS_M)
	if not bool(_status.get("found", false)):
		_tl = {}
		_tl_key = ""
		return
	var key := "%s|%s|%d|%.1f|%.3f" % [str(_status["chore_id"]), str(_status["kind"]),
		int(_status["crew"]), float(_status["servings"]), float(_status["hours"])]
	if key != _tl_key:
		_tl_key = key
		var kind := str(_status["kind"])
		if kind.is_empty():
			kind = MealJobPlan.STEP_PREP
		_tl = MealJobPlan.build(kind, float(_status["servings"]), int(_status["crew"]),
			{"person_hours": float(_status["hours"]), "stations": _stations()})
		_t_disp = MealJobPlan.time_for_progress(_tl, float(_status["progress"]))
	_t_target = MealJobPlan.time_for_progress(_tl, float(_status["progress"]))


func _stations() -> Dictionary:
	if _model != null and _model.has_meta("stations"):
		return _model.get_meta("stations")
	return MealJobPlan.default_stations()


func _set_active(on: bool) -> void:
	if not on:
		for c in _crew:
			(c["fig"] as Node3D).visible = false
			_hide_tools(c)
		if not _lane_of.is_empty():
			_lane_of.clear()
			NpcStandIns.set_for(_stand_key(), {})
		if _label != null:
			_label.visible = false
		if _furniture != null:
			_furniture.visible = false
		return
	if not _is_kitchen_model and _furniture == null:
		_furniture = CampKitchenBuilder.build_node({"canopy": false}, "PopUpKitchen")
		add_child(_furniture)
	if _furniture != null:
		_furniture.visible = true
	if _label == null:
		_label = Label3D.new()
		_label.name = "Progress"
		_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_label.no_depth_test = true
		_label.fixed_size = true
		_label.pixel_size = 0.0007
		_label.font_size = 24
		_label.outline_size = 8
		_label.modulate = Color(1.0, 0.93, 0.72)
		_label.position = Vector3(0, 2.9, 0)
		add_child(_label)
	_label.visible = true


func _ensure_crew(n: int) -> void:
	while _crew.size() < n:
		var i := _crew.size()
		var fig := NpcSimpleFigure.new()
		fig.hi_detail = true
		fig.name = "Cook%d" % i
		add_child(fig)
		var key := "%s_cook_%d" % [_prop.prop_id, i]
		fig.setup(key, Color.from_hsv(NpcHash.unit01(key, "tint"), 0.45, 0.9))
		fig.set_mocap_allowed(false)
		fig.visible = false
		_crew.append({"fig": fig, "tools": {}, "tint": null})


## Lanes for the people on site: an agent keeps its lane while it stays;
## new arrivals take the busiest free lane.
func _man_lanes(ws: Array) -> Dictionary:
	var here := {}
	for pr in _status.get("present", []):
		here[str(pr["id"])] = pr
	for aid in _lane_of.keys():
		if not here.has(aid):
			_lane_of.erase(aid)
	var taken := {}
	for aid in _lane_of:
		taken[int(_lane_of[aid])] = true
	var order: Array = range(mini(ws.size(), MAX_LANES))
	var rank := {"work": 0, "walk": 1, "wait": 2, "idle": 3}
	order.sort_custom(func(a, b) -> bool:
		var ra := int(rank.get(str((ws[a] as Dictionary).get("activity", "")), 4))
		var rb := int(rank.get(str((ws[b] as Dictionary).get("activity", "")), 4))
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


func timeline() -> Dictionary:
	return _tl


func status() -> Dictionary:
	return _status


func display_time() -> float:
	return _t_disp


func crew_figures() -> Array:
	return _crew.map(func(c): return c["fig"])


func _apply_crew(st: Dictionary, delta: float, rate: float) -> void:
	var ws: Array = st["workers"]
	_ensure_crew(mini(ws.size(), MAX_LANES))
	var cam := get_viewport().get_camera_3d() if get_viewport() != null else null
	var far := cam != null and cam.global_position.distance_to(global_position) > CULL_M
	var manned := _man_lanes(ws)
	for i in _crew.size():
		var c: Dictionary = _crew[i]
		var fig: NpcSimpleFigure = c["fig"]
		var shown := not far and manned.has(i) and i < ws.size()
		fig.visible = shown
		if not shown:
			_hide_tools(c)
			continue
		var col: Color = manned[i]
		if c.get("tint") != col:
			c["tint"] = col
			fig.set_tint(col)
		_pose_worker(c, ws[i], rate, delta)


func _pose_worker(c: Dictionary, w: Dictionary, rate: float, delta: float) -> void:
	var fig: NpcSimpleFigure = c["fig"]
	var pos: Vector3 = w["pos"]
	var face: Vector3 = w["face"]
	var dir := Vector3(face.x - pos.x, 0.0, face.z - pos.z)
	var basis := fig.transform.basis
	if dir.length() > 0.05:
		basis = Basis.looking_at(-dir.normalized(), Vector3.UP)
	fig.transform = Transform3D(basis, pos)
	_hide_tools(c)
	var dt := maxf(delta, 1.0 / 120.0)
	var act := str(w["activity"])
	var clip := _clip(str(w["clip"]))
	if act != "work" or clip == null:
		fig.clear_clip()
		fig.set_hand_target(0, null)
		fig.set_hand_target(1, null)
		fig.pose("walk" if act == "walk" else "idle", maxf(rate, 0.3) if act == "walk" else 1.0, dt)
		return
	var phase := fposmod(_fx_t + float(w["id"]) * 0.37, clip.length_s)
	var rig := _rig(str(w["rig"]))
	var tp := FabContextRig.tool_at(rig, phase / maxf(clip.length_s, 0.01))
	var xf: Transform3D = fig.transform * (tp["xform"] as Transform3D)
	var tool_id := str(rig.get("tool_id", ""))
	var socks: Dictionary = {}
	if not tool_id.is_empty():
		var tool := _tool(c, tool_id)
		tool.visible = true
		tool.transform = xf
		socks = tool.get_meta("sockets", {})
	fig.set_clip(clip, phase, 1.0)
	for i in 2:
		var sock := str(clip.ik.get("hand_r" if i == 0 else "hand_l", "none"))
		if sock != "none" and socks.get(sock) is Transform3D:
			fig.set_hand_target(i, global_transform * xf * (socks[sock] as Transform3D))
		else:
			fig.set_hand_target(i, null)
	fig.pose("idle", 0.0, dt)


func _hide_tools(c: Dictionary) -> void:
	for id in c["tools"]:
		(c["tools"][id] as Node3D).visible = false


func _tool(c: Dictionary, id: String) -> Node3D:
	var tools: Dictionary = c["tools"]
	if not tools.has(id):
		var t := FabToolCatalog.build(id)
		add_child(t)
		tools[id] = t
	return tools[id]


func _clip(id: String) -> NpcAnimClip:
	if id.is_empty():
		return null
	if not _clips.has(id):
		_clips[id] = NpcAnimClip.load_clip(id)
	return _clips[id]


func _rig(kind: String) -> Dictionary:
	if not _rigs.has(kind):
		_rigs[kind] = FabContextRig.setup(kind)
	return _rigs[kind]


func _update_label(st: Dictionary) -> void:
	if _label == null:
		return
	var who: Array = []
	for pr in _status.get("present", []):
		who.append(NpcAgent.name_for(str(pr["id"])))
	var cur: Array = st.get("current", [])
	var txt := "%s · %d %%" % [str(_status.get("label", "Cooking")), roundi(float(_status.get("progress", 0.0)) * 100.0)]
	if not cur.is_empty():
		txt += "\n%s" % ", ".join(PackedStringArray(cur.slice(0, 3)))
	if not who.is_empty():
		txt += "\n%s" % ", ".join(PackedStringArray(who))
	if _label.text != txt:
		_label.text = txt
