extends TourStop

## Wires and pipes in 3D: a cord pulled off one device's port and plugged into
## another in first person, measured as it is drawn, then restyled live in the
## conduit modal. Whatever the stop wires up it removes again.

var _made: PackedStringArray = PackedStringArray()
var _placed: PackedStringArray = PackedStringArray()
var _wires_before := false
var _labels_before := false


func _init() -> void:
	id = "conduit_routing"
	title = "3D wire and pipe routing"
	chapter = "Systems"
	summary = "Pull a cord or a pipe off a device's port and plug it in — measured as you go."
	how = PackedStringArray(["Aim at a device's port, press and drag to the other device, release",
		"Shift+release keeps chaining from the device you plugged into",
		"Click a run to restyle it live: kind, size, colour — Revert puts it back"])
	button = "a device's port (press and drag)"
	world = "mtvernon"
	budget_s = 45.0
	hour = 14.0
	blurb = ("Every wire, hose, penstock and culvert on the graph can be a real run in " +
		"the world, drawn from port to port over the ground and bent round obstacles. " +
		"The HUD measures the run as it is pulled with the same rule the committed run " +
		"uses, run-length tags show metres and feet, and the style modal edits the live " +
		"run with the I²R loss and a stock-length fit in its header.")


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
	var pair := _pick_pair(ctx, mgr, model)
	if pair.is_empty():
		# Nothing free to wire on this site: set out two water tanks of our own.
		pair = await _place_tank_pair(ctx, mgr, model)
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
		await ctx.wait(0.6)
		ctx.caption("Press on a port and pull a cord off it…", 2.5)
		await ctx.wait(1.5)
		var n_before: int = (model.get("connections") as Array).size()
		ctrl.call("begin_plug", src)
		# Swing the view across to the far port, the plug following the aim.
		var steps := 40
		for i in steps + 1:
			var p := a.lerp(b, float(i) / float(steps))
			ctx.aim_player_at(p)
			await ctx.frames(1)
		await ctx.wait(0.5)
		ctx.caption("…measured as you pull it, snapped onto the far port", 3.0)
		await ctx.wait(1.5)
		await ctx.hero()
		var vp := ctx.tree().root.get_viewport()
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = false
		ev.position = vp.get_visible_rect().size * 0.5
		ev.global_position = ev.position
		vp.push_input(ev, true)
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
			mgr.call("force_remesh", conn_id)
			ctx.caption("Plugged in — the run carries its length", 2.5)
			await ctx.wait(2.0)
	if conn_id.is_empty():
		return
	g.call("open_conduit_style_modal", conn_id)
	await ctx.wait(1.0)
	var modal: Variant = g.get("_conduit_style_modal")
	if ctx.require(modal != null and bool((modal as CanvasItem).visible), "the conduit style modal opened"):
		ctx.caption("Click a run: restyle it live, on the real run", 3.0)
		await ctx.wait(3.0)
		if _made.is_empty():
			await ctx.hero()
		await ctx.shot("style_modal")
		modal.call("close")


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
