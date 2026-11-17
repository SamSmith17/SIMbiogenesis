extends TourStop

## Pipes and cables in 3D: the Route tools (Shift+R) join two machines by
## clicking a port and then the other, the ghost being the run you get; a bend
## dragged in; then the same run in the Process lens's "As built" picture.
## Whatever the stop wires up it removes again.

var _made: PackedStringArray = PackedStringArray()
var _placed: PackedStringArray = PackedStringArray()
var _wires_before := false
var _labels_before := false


func _init() -> void:
	id = "conduit_routing"
	title = "3D pipe and cable routing"
	chapter = "Systems"
	summary = "Join machines with real runs: square, with proper bends, round what is in the way."
	how = PackedStringArray(["Shift+R opens the Route tools: click a port, then a port on the other machine",
		"Bend: click a run, click it again to add a bend point, drag it",
		"Runs on the same line lie side by side in lanes; Lane drags one to another",
		"Open in Process → As built: the system drawn where it really is"])
	action = "route_edit"
	world = "mtvernon"
	budget_s = 45.0
	hour = 14.0
	blurb = ("Every pipe and cable on the graph can be a real run in the world. The " +
		"router lays it square, with bends at the real minimum radius of what it is " +
		"(NEC, PPI, TIA), round machines and buildings and over low things, through " +
		"any bend points you add. Runs on one line become a bundle of lanes with " +
		"matched bends. The style window lists the run's size, rating, weight, " +
		"supports and cost, and the Process lens can draw it all as built.")


func run(ctx: TourContext) -> void:
	var m := ctx.main
	var g := ctx.graph
	var mgr := m.get_node_or_null("ConduitManager")
	var ctrl := ctx.player.get_node_or_null("ConduitRouteController") if ctx.player != null else null
	var cam := ctx.player.get_node_or_null("CameraArm/Camera3D") as Camera3D if ctx.player != null else null
	if not ctx.require(g != null and mgr != null and ctrl != null and cam != null,
			"graph, conduit manager, route controller and camera present"):
		return
	var ssc := ctx.autoload("SimSettingsController")
	var rll := ctx.klass("RunLengthLabels")
	_wires_before = bool(ssc.get("conduits_3d_visible")) if ssc != null else false
	_labels_before = bool(rll.call("enabled")) if rll != null else false
	if ssc != null:
		ssc.call("set_conduits_3d_visible", true)
	mgr.call("set_global_visibility", true)
	if rll != null:
		rll.call("set_enabled", true)
	await ctx.wait(0.5)
	var model: Variant = g.get("model")
	# Two water tanks of our own: a pipe between two stores is what the
	# As built picture draws best. Else two free ports already on the site.
	var pair: Array = await _place_tank_pair(ctx, mgr, model)
	if pair.is_empty():
		pair = _pick_pair(ctx, mgr, model)
	var conn_id := ""
	if pair.is_empty():
		ctx.note("no two free, compatible ports nearby — showing an existing run")
		conn_id = _existing_run(model)
		if not ctx.require(not conn_id.is_empty(), "there is a run to show"):
			return
		var samples: PackedVector3Array = mgr.call("get_sample_points", conn_id)
		if samples.size() >= 2:
			var mid := samples[samples.size() / 2]
			ctx.place_camera(mid + Vector3(8.0, 6.0, 8.0), mid)
			await ctx.wait(1.0)
	else:
		var src: Dictionary = pair[0]
		var dst: Dictionary = pair[1]
		var a: Vector3 = src["world_pos"]
		var b: Vector3 = dst["world_pos"]
		var dxz := Vector3(b.x - a.x, 0.0, b.z - a.z)
		var side := dxz.cross(Vector3.UP).normalized()
		var stand := (a + b) * 0.5 + side * maxf(4.0, dxz.length() * 0.6)
		stand.y = ctx.ground_y(stand.x, stand.z) + 0.1
		ctx.player.global_position = stand
		ctx.aim_player_at(a)
		var mid := (a + b) * 0.5
		ctx.place_camera(mid + side * maxf(7.0, dxz.length() * 0.8) + Vector3.UP * maxf(5.0, dxz.length() * 0.5), mid)
		await ctx.wait(0.6)
		var tb: Node = ctx.main.find_child("EditToolbarUI", true, false)
		if not ctx.require(tb != null, "the edit toolbar"):
			return
		await ctx.press("route_edit")
		await ctx.wait(0.4)
		if not bool(tb.call("is_panel_open")):
			tb.call("open_with_section", "route")
		tb.call("_set_active_tool", "route_connect")
		ctx.caption("Shift+R: the Route tools. Click a port…", 2.5)
		await ctx.wait(1.2)
		var n_before: int = (model.get("connections") as Array).size()
		var cam3: Camera3D = ctx.tree().root.get_viewport().get_camera_3d()
		await ctx.click_at(cam3.unproject_position(a))
		await ctx.wait(0.4)
		await ctx.pointer_to(cam3.unproject_position(b), 1.2)
		await ctx.wait(0.6)
		ctx.caption("…the ghost is the run you will get: square, real bends, round what is in the way", 3.5)
		await ctx.wait(1.5)
		await ctx.hero()
		await ctx.click_at(cam3.unproject_position(b))
		await ctx.wait(0.8)
		for c in model.get("connections"):
			var cd: Dictionary = c
			var ends := [str(cd.get("source_item_id", "")), str(cd.get("target_item_id", ""))]
			if ends.has(str(src["item_id"])) and ends.has(str(dst["item_id"])):
				conn_id = str(cd.get("id", ""))
		ctx.require((model.get("connections") as Array).size() == n_before + 1 and not conn_id.is_empty(),
			"the release made one run")
		if not conn_id.is_empty():
			_made.append(conn_id)
			ctx.caption("Made: the run between them, with real bends, measured", 2.5)
			await ctx.wait(2.0)
			# A bend point, dragged.
			tb.call("_set_active_tool", "route_bend")
			await ctx.wait(0.3)
			var pts: PackedVector3Array = mgr.call("get_sample_points", conn_id)
			if pts.size() >= 2:
				var on := cam3.unproject_position(pts[pts.size() / 2])
				await ctx.click_at(on)
				await ctx.wait(0.3)
				await ctx.click_at(on)
				await ctx.wait(0.6)
				var vias: Array = (model.call("get_connection", conn_id) as Dictionary).get("route_3d", [])
				if vias.size() == 1:
					var v0 := Vector3(float(vias[0]["x"]), float(vias[0]["y"]), float(vias[0]["z"]))
					var sv := cam3.unproject_position(v0)
					ctx.caption("Bend: drag a bend point and the run is re-routed through it", 3.0)
					await ctx.drag_to(sv, sv + Vector2(90, 30), 1.2)
					await ctx.wait(1.2)
					await ctx.shot("bend")
	if conn_id.is_empty():
		return
	# The same run in the Process lens, drawn as built.
	g.call("open_run_in_process", conn_id)
	await ctx.wait(1.2)
	var canvas: Variant = g.get("_graph_canvas")
	var lens: Variant = canvas.call("process_lens") if canvas != null else null
	if ctx.require(lens != null, "the Process lens"):
		lens.call("set_built", true)
		await ctx.wait(1.0)
		ctx.caption("Process → As built: every machine where it stands, every run along its real path", 3.5)
		await ctx.wait(2.5)
		await ctx.shot("as_built")
		lens.call("set_built", false)
	ctx.close_graph()


## Two ports on different placed devices, unwired, compatible, 2–60 m apart
## (the closest such pair) — the conduits harness's own rule.
func _pick_pair(ctx: TourContext, mgr: Node, model: Object) -> Array:
	var cpl := ctx.klass("ConduitPlugLogic")
	var ck := ctx.klass("ConduitKinds")
	if cpl == null or ck == null:
		return []
	var ports: Array = mgr.call("gather_world_ports")
	var wired := {}
	for c in model.get("connections"):
		var cd: Dictionary = c
		wired["%s|%s" % [cd.get("source_item_id", ""), cd.get("source_handle_id", "")]] = true
		wired["%s|%s" % [cd.get("target_item_id", ""), cd.get("target_handle_id", "")]] = true
	var best: Array = []
	var best_d := INF
	var me := ctx.player_xz()
	for a in ports:
		var ad: Dictionary = a
		if bool(cpl.call("port_is_input", ad["port"])) and not bool(cpl.call("port_is_output", ad["port"])):
			continue
		for b in ports:
			var bd: Dictionary = b
			if str(bd["item_id"]) == str(ad["item_id"]):
				continue
			if wired.has("%s|%s" % [bd["item_id"], (bd["port"] as Dictionary).get("handle_id", "")]):
				continue
			if not bool(cpl.call("ports_compatible", ad, bd)):
				continue
			if bool(ck.call("is_direct_intake_connection",
					cpl.call("build_connection_spec", ad, bd, "extension_cord"), model)):
				continue
			var pa: Vector3 = ad["world_pos"]
			var pb: Vector3 = bd["world_pos"]
			var d := pa.distance_to(pb)
			if d < 3.0 or d > 60.0:
				continue
			# Prefer a pair near where the tour stands.
			var score := d + Vector2(pa.x, pa.z).distance_to(me) * 0.05
			if score < best_d:
				best_d = score
				best = [ad, bd]
	return best


## Two library water tanks ~12 m apart on open ground ahead (placeholder
## boxes with an inlet and an outlet, bound to graph nodes); the pair to plug.
func _place_tank_pair(ctx: TourContext, mgr: Node, model: Object) -> Array:
	var cp := ctx.klass("ComponentPresets")
	var tank := {}
	if cp != null:
		for p in cp.get_script_constant_map().get("RESOURCES", []):
			if p is Dictionary and str((p as Dictionary).get("label", "")) == "Water Tank (250 gal)":
				tank = p
	if tank.is_empty():
		return []
	var f := ctx.player_forward()
	var side := f.cross(Vector3.UP)
	var c := ctx.find_flat(ctx.player_xz() + Vector2(f.x, f.z) * 12.0, 8.0, 120.0, 8.0)
	for k in [-1.0, 1.0]:
		var at: Vector3 = c + side * 6.0 * float(k)
		at.y = ctx.ground_y(at.x, at.z)
		var pid := await ctx.place_preset(tank, at)
		if not pid.is_empty():
			_placed.append(pid)
	await ctx.wait(0.5)
	var ids := {}
	for pid in _placed:
		ids[str(ctx.prop_record(pid).get("graph_item_id", ""))] = true
	var pair := _pick_pair(ctx, mgr, model)
	if pair.size() == 2 and ids.has(str(pair[0]["item_id"])) and ids.has(str(pair[1]["item_id"])):
		return pair
	return pair


## A run already drawn in 3D (longest first), for maps with nothing left to wire.
func _existing_run(model: Object) -> String:
	var best := ""
	var best_l := 0.0
	for c in model.get("connections"):
		var cd: Dictionary = c
		var l := float(cd.get("route_length_m", 0.0))
		if bool(cd.get("visible_3d", false)) and l > best_l:
			best_l = l
			best = str(cd.get("id", ""))
	return best


func teardown(ctx: TourContext) -> void:
	var tb: Node = ctx.main.find_child("EditToolbarUI", true, false) if ctx.main != null else null
	if tb != null and bool(tb.call("is_panel_open")):
		tb.call("_exit_mode")
	var g := ctx.graph
	if g != null:
		var modal: Variant = g.get("_conduit_style_modal")
		if modal != null and is_instance_valid(modal) and bool((modal as CanvasItem).visible):
			modal.call("close")
		var model: Variant = g.get("model")
		if model != null:
			for cid in _made:
				if not (model.call("get_connection", cid) as Dictionary).is_empty():
					model.call("remove_connection", cid)
	_made = PackedStringArray()
	for pid in _placed:
		ctx.remove_prop(pid)
	_placed = PackedStringArray()
	var rll := ctx.klass("RunLengthLabels")
	if rll != null:
		rll.call("set_enabled", _labels_before)
	var ssc := ctx.autoload("SimSettingsController")
	if ssc != null:
		ssc.call("set_conduits_3d_visible", _wires_before)
	var mgr := ctx.main.get_node_or_null("ConduitManager") if ctx.main != null else null
	if mgr != null:
		mgr.call("set_global_visibility", _wires_before)
