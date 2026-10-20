class_name GraphHydroRouting
extends RefCounted

## ONE water-source model for hydro turbines. A turbine draws from a SOURCE:
##   pond   — a pond tank on the graph (level-driven: siphon / penstock from a
##            reservoir, HydroReach draws the level down)
##   stream — a mapped / drawn stream (flow-driven: the intake is BOUND to the
##            feature and takes its discharge at the intake station)
##   spring — bare ground: a tapped spring with authored base flow + rain
## Every way of making a penstock (the 3D plug drag, the Lab's drag / auto-route
## / From pond, the WATER toolbar's Penstock chip, a Site Plan wire drop, a
## plain pond→turbine wire) resolves a source with resolve_hydro_source_at and
## routes it with route_penstock_to_source. Nothing else mints intakes.
##
## Lifted out of SystemGraphView on 2026-10-18 (NEXT_PASS_PLAN Push 4, the
## first monolith slice). The view keeps a one-line delegate for every
## function the Hydro Lab, the route controller, the WATER toolbar, the canvas
## and the harness call — same names, same signatures — so no caller moved.
## State stays on the view: `model`, the active scope, the autosave flags,
## the toast, the terrain-loader / conduit-manager lookups and the item-XZ
## cache are all reached through `view`. The functions are otherwise the
## view's own, byte for byte, including their rules:
##   - ONE penstock per turbine (`_remove_existing_penstock`).
##   - A stream intake is a FLOW, not a reservoir (no level to draw down).
##   - A pond→penstock-kind wire the player draws by hand becomes the
##     penstock (`auto_penstock_for_new_water_wires`); the SIPHON kind alone
##     drinks through a direct intake.
##   - A stream-fed turbine is never auto-rebound to a pond
##     (`turbine_has_stream_source`).

## The SystemGraphView that owns this helper (a Control; duck-typed so this
## file compiles under --script without the view).
var view: Control = null

## The view's live GraphModel (null until the view has one).
var model: GraphModel:
	get:
		return view.model if view != null else null


## Specs for a freshly minted stream intake. `stream_source` is the marker the
## flow engine and the inspector key off (model_id is the fallback, so intakes
## made before this key existed still resolve).
func _stream_intake_specs(prop_id: String) -> Dictionary:
	var specs := {
		"name": "Stream Intake",
		"resource_kind": "water",
		# NOT pond_storage: this is a running source, not a reservoir with a
		# level to draw down — the turbine reads its ELEVATION for head.
		"pond_storage": false,
		"stream_source": true,
		"unlimited_capacity": true,
		"capacity_qty": 1000.0, "capacity_unit": "L", "level": 1.0,
		"bound_prop_id": prop_id,
		"model_id": StreamIntakeBuilder.MODEL_ID,
		"daily_note": "Tapped by a penstock. Its ground elevation sets the gross head, its base flow + rain response set how much water it runs.",
	}
	specs.merge(HydroSupply.default_intake_specs())
	return specs


## Mint a Stream Intake at a world point and wire a penstock from it to
## `turbine_id`'s inlet handle. This is what "drop the pipe here and that's the
## source" means mechanically: a conduit has NO free endpoints (both ends must
## resolve to an item with a 3D anchor, and a `resource` item only gets one via
## bound_prop_id), so the drop has to create a real prop + graph node. Head then
## follows from the intake's terrain elevation through the normal invert path.
## Returns the new connection id, or "" on failure.
func create_penstock_intake_at(world_pos: Vector3, turbine_id: String,
		turbine_handle: String, style_ov: Dictionary = {}, opts: Dictionary = {}) -> String:
	if model == null or turbine_id.is_empty():
		return ""
	var turbine := model.get_item(turbine_id)
	if turbine.is_empty() \
			or str((turbine.get("specs", {}) as Dictionary).get("role", "")) != "siphon_hydro":
		view._show_toast("Penstock needs a hydro turbine at the other end")
		return ""
	var main: Node = view._get_scene_main_node()
	if main == null:
		return ""
	# One penstock per turbine: a re-route replaces the old intake + run.
	_remove_existing_penstock(turbine_id)
	# Head is the intake's ground above the turbine's. Say so BEFORE routing a
	# pipe that can only ever report "no head".
	var t_xz: Vector2 = view._item_world_xz(turbine)
	if is_finite(t_xz.x):
		var t_y := TerrainSurfaceQuery.ground_height_at(main, t_xz.x, t_xz.y)
		var i_y := TerrainSurfaceQuery.ground_height_at(main, world_pos.x, world_pos.z)
		if is_finite(t_y) and is_finite(i_y) and i_y <= t_y + 0.25:
			view._show_toast("Intake is not above the turbine — the penstock will have no head", 4.0)
	var placed: Dictionary = PlacedPropService.place_model_at_xz(
			main, StreamIntakeBuilder.MODEL_ID, world_pos.x, world_pos.z)
	if not bool(placed.get("ok", false)):
		view._show_toast("Couldn't place the intake here")
		return ""
	var prop_id := str(placed.get("prop_id", ""))
	var ground_y := float(placed.get("ground_y", world_pos.y))
	var item_id: String = model.generate_item_id()
	var site := Vector2.ZERO
	var soi := view.get_node_or_null("/root/SoiService")
	if soi != null and soi.has_method("world_center"):
		site = GraphSiteLayout.world_xz_to_site(
				Vector2(world_pos.x, world_pos.z), soi.call("world_center") as Vector3)
	var graph_pos := Vector2(randf_range(-90.0, 90.0), randf_range(-70.0, 70.0))
	model.add_item({
		"id": item_id,
		"type": "resource",
		"x": graph_pos.x, "y": graph_pos.y,
		"width": 90.0, "height": 100.0,
		"scope_id": view._active_scope_id,
		"site_x_m": site.x, "site_z_m": site.y,
		"elevation_m": ground_y,
		"is_virtual": false,
		# A new intake ships with a real dry-weather flow and a rain response
		# (HydroSupply.default_intake_specs), so the turbine produces the moment
		# the penstock is routed. Zeros here would leave the whole
		# place-intake-then-route flow ending at 0 W with nothing saying why.
		"specs": _stream_intake_specs(prop_id),
	})
	var wf_id := str(opts.get("water_feature_id", ""))
	var wf_name := str(opts.get("water_feature_name", ""))
	if not wf_id.is_empty():
		# BOUND to a stream (the Penstock span tool): the engine takes this
		# stream's discharge at the intake station whatever the distance.
		var isp: Dictionary = (model.get_item(item_id).get("specs", {}) as Dictionary).duplicate(true)
		isp["water_feature_bind"] = wf_id
		isp["water_feature_name"] = wf_name
		if not wf_name.is_empty():
			isp["name"] = "Stream Intake: %s" % wf_name
		model.update_item(item_id, {"specs": isp})
	PlacedPropService.update_prop_record(main, prop_id,
			{"graph_item_id": item_id}, false)
	var style: Dictionary = style_ov.duplicate(true)
	style.erase("route_mode")
	# A pinned 3D route (the stream's own line) rides the conn as locked
	# waypoints — that is the only form ConduitManager honours.
	var route_3d: Array = []
	for wp: Variant in (opts.get("route_3d", []) as Array):
		if wp is Vector3:
			route_3d.append(ConduitKinds.waypoint_dict(wp as Vector3))
	# add_connection() returns void and stamps a generated id when absent, so
	# mint the id here to hand it straight to the reveal/remesh path.
	var conn_id: String = model.generate_connection_id()
	model.add_connection({
		"id": conn_id,
		"source_item_id": item_id, "source_handle_id": "output",
		"target_item_id": turbine_id,
		"target_handle_id": turbine_handle if not turbine_handle.is_empty() else "res_in_0",
		"polarity": "resource", "resource_type": "water",
		"conduit_type": "poly_penstock",
		"conduit_style": style,
		"route_3d": route_3d, "route_locked": not route_3d.is_empty(),
		"visible_3d": true, "flow_glow": true,
	})
	reveal_penstock_conduit(conn_id)
	view._schedule_graph_autosave()
	view._autosave_pending = true
	view._flush_graph_autosave()
	if wf_id.is_empty():
		view._show_toast("Stream Intake placed — penstock routed to the turbine")
	else:
		view._show_toast("Penstock tapped from %s" % (wf_name if not wf_name.is_empty() else "the stream"))
	return conn_id


# ---------------------------------------------------------------------------
# Stream → penstock (the WATER toolbar's Penstock span tool). A reach of a
# mapped / drawn / traced stream becomes the penstock of a PowerSpout: the
# intake stands at the reach's upstream vertex, the routed poly_penstock
# follows the stream's own line down to the turbine, and the intake is BOUND
# to that stream so the flow engine takes its discharge at the intake
# station however the prop or bank moves. Mirrors what the water system does
# with the span (mode "penstock" = no channel, no barrel: the conduit IS the
# visual).
# ---------------------------------------------------------------------------

func _on_canvas_stream_tap_requested(feature_id: String, seg: int, turbine_id: String,
		handle_id: String) -> void:
	tap_stream_for_turbine(feature_id, seg, turbine_id, handle_id)


## Make a stream reach the penstock of `turbine_id`, from a point ON that
## stream: the Site Plan wire drop and the first-person stream rung both land
## here. If `seg` lies inside an existing penstock / pipe run the whole run is
## the reach (its upstream vertex is the intake, its outlet the exit); else
## the reach runs from `seg`'s upstream vertex down to the vertex nearest the
## turbine. The water side is marked penstock, the graph side routed + bound.
## Returns the connection id, "" on failure (with a toast saying why).
func tap_stream_for_turbine(feature_id: String, seg: int, turbine_id: String,
		handle_id: String = "res_in_0", style_ov: Dictionary = {}) -> String:
	var loader: Node = view._find_terrain_loader(view._get_scene_main_node())
	if loader == null or not loader.has_method("water_network") or model == null:
		return ""
	var wn: Node = loader.call("water_network")
	if wn == null:
		return ""
	var turbine := model.get_item(turbine_id)
	if str((turbine.get("specs", {}) as Dictionary).get("role", "")) != "siphon_hydro":
		view._show_toast("Only a hydro turbine can tap a stream")
		return ""
	var ep: Dictionary = wn.call("editable_points", feature_id)
	var pts: PackedVector2Array = ep.get("points", PackedVector2Array())
	var modes: Array = ep.get("modes", [])
	if pts.size() < 2:
		return ""
	seg = clampi(seg, 0, pts.size() - 2)
	var is_run := func(i: int) -> bool:
		return i >= 0 and i < modes.size() and (str(modes[i]) == WaterFeatureLayer.MODE_PENSTOCK or str(modes[i]) == "pipe")
	var intake_i := seg
	var exit_i := -1
	if bool(is_run.call(seg)):
		while bool(is_run.call(intake_i - 1)):
			intake_i -= 1
		exit_i = seg + 1
		while bool(is_run.call(exit_i)):
			exit_i += 1
	else:
		var t_xz: Vector2 = view._item_world_xz(turbine)
		var best := INF
		for i in range(intake_i + 1, pts.size()):
			var d := pts[i].distance_to(t_xz) if is_finite(t_xz.x) else float(pts.size() - i)
			if d < best:
				best = d
				exit_i = i
	if exit_i <= intake_i:
		view._show_toast("The turbine sits upstream of that point — tap the stream above it")
		return ""
	wn.call("checkpoint")
	var nid := feature_id
	for i in range(intake_i, exit_i):
		nid = str(wn.call("set_span_mode", nid, i, WaterFeatureLayer.MODE_PENSTOCK))
	wn.call("commit")
	var f: Dictionary = wn.call("feature", nid)
	var fname := str(f.get("name", ""))
	if fname.is_empty():
		fname = str(f.get("kind", "stream")).capitalize()
	var conn := create_penstock_from_stream(nid, fname, pts.slice(intake_i, exit_i + 1), turbine_id, style_ov)
	if conn.is_empty():
		return ""
	# The drop named a handle; the route defaults to res_in_0 — honour the
	# player's port when it is a different water input.
	if not handle_id.is_empty() and handle_id != "res_in_0":
		model.update_connection(conn, {"target_handle_id": handle_id})
	return conn


# ---------------------------------------------------------------------------
# ONE water-source model for hydro turbines. A turbine draws from a SOURCE:
#   pond   — a pond tank on the graph (level-driven: siphon / penstock from a
#            reservoir, HydroReach draws the level down)
#   stream — a mapped / drawn stream (flow-driven: the intake is BOUND to the
#            feature and takes its discharge at the intake station)
#   spring — bare ground: a tapped spring with authored base flow + rain
# Every way of making a penstock (the 3D plug drag, the Lab's drag / auto-route
# / From pond, the WATER toolbar's Penstock chip, a Site Plan wire drop, a
# plain pond→turbine wire) resolves a source with resolve_hydro_source_at and
# routes it with route_penstock_to_source. Nothing else mints intakes.
# ---------------------------------------------------------------------------

## A water wire the player drew by hand from a pond tank or a stream intake
## into a hydro turbine's water input becomes that turbine's penstock — the
## same contour-routed poly run every other entry makes. Without this the
## Site Plan port drop made a bare schematic wire the physics ignored, and
## the Lab then said "Not routed".
func auto_penstock_for_new_water_wires() -> void:
	if model == null or view._history_suppress:
		return
	for conn: Dictionary in model.connections.duplicate():
		if str(conn.get("conduit_type", "")) == "poly_penstock":
			continue
		if str(conn.get("polarity", "")) != "resource" \
				or not (ResourceKinds.normalize_kind(str(conn.get("resource_type", "water"))) in ["water", ""]):
			continue
		var tgt := model.get_item(str(conn.get("target_item_id", "")))
		var src := model.get_item(str(conn.get("source_item_id", "")))
		var turbine := tgt if str((tgt.get("specs", {}) as Dictionary).get("role", "")) == "siphon_hydro" else \
			(src if str((src.get("specs", {}) as Dictionary).get("role", "")) == "siphon_hydro" else {})
		if turbine.is_empty():
			continue
		var other := src if turbine == tgt else tgt
		var osp: Dictionary = other.get("specs", {}) as Dictionary
		var handle := str(conn.get("target_handle_id", "")) if turbine == tgt else str(conn.get("source_handle_id", ""))
		if not handle.begins_with("res_in"):
			continue
		# A SIPHON drinks through its dip tube (direct intake, no pipe) — only
		# penstock kinds get a routed run. This used to convert the bind's own
		# pond→siphon wire into a poly penstock anchored at the tank's centroid,
		# which is the "immovable intake node" the player saw in 3D. The KIND
		# decides: a wire stamped direct_intake before the turbine became a
		# penstock kind (or by an older build) is not a dip tube any more.
		var tk := str((turbine.get("specs", {}) as Dictionary).get("turbine_kind", "siphon"))
		if not bool(HydroSource.kind_meta(tk).get("has_penstock", false)):
			continue
		if bool(conn.get("direct_intake", false)):
			model.update_connection(str(conn.get("id", "")), {"direct_intake": false})
		if bool(osp.get("pond_storage", false)):
			_route_penstock_from_pond(str(turbine.get("id", "")), str(other.get("id", "")), handle, {})
		elif ResourceFlowEngine.is_stream_intake(other):
			_remove_existing_penstock(str(turbine.get("id", "")), str(conn.get("id", "")))
			model.update_connection(str(conn.get("id", "")), {
				"conduit_type": "poly_penstock", "visible_3d": true, "flow_glow": true})
			reveal_penstock_conduit(str(conn.get("id", "")))


## Classify a world point as a water source: {kind: "pond"|"stream"|"spring", …}.
## Pond beats stream beats bare ground; `stream_max_m` is the snap distance.
func resolve_hydro_source_at(world_xz: Vector2, stream_max_m: float = 8.0) -> Dictionary:
	var loader: Node = view._find_terrain_loader(view._get_scene_main_node())
	if loader != null and loader.has_method("pick_water_at_world"):
		var w: Dictionary = loader.call("pick_water_at_world", world_xz.x, world_xz.y)
		if bool(w.get("valid", false)):
			var tank := _pond_tank_for_tag(str(w.get("tag", "")))
			if not tank.is_empty():
				return {"kind": "pond", "item_id": str(tank.get("id", "")),
					"label": str((tank.get("specs", {}) as Dictionary).get("name", "Pond"))}
			return {"kind": "pond_unadded", "tag": str(w.get("tag", "")), "water_idx": int(w.get("water_idx", -1))}
	if loader != null and loader.has_method("pick_stream_at_world"):
		var st: Dictionary = loader.call("pick_stream_at_world", world_xz.x, world_xz.y, stream_max_m)
		if bool(st.get("valid", false)):
			return {"kind": "stream", "feature_id": str(st.get("id", "")), "seg": int(st.get("seg", 0)),
				"label": str(st.get("name", "")) if not str(st.get("name", "")).is_empty() else str(st.get("kind", "stream")).capitalize()}
	var y := TerrainSurfaceQuery.ground_height_at(view._get_scene_main_node(), world_xz.x, world_xz.y)
	return {"kind": "spring", "world_pos": Vector3(world_xz.x, y if is_finite(y) else 0.0, world_xz.y), "label": "Spring"}


## The pond tank on the graph for a picked water body's tag, or {}.
func _pond_tank_for_tag(tag: String) -> Dictionary:
	if model == null or tag.is_empty():
		return {}
	for it in model.items_of_type("resource"):
		var sp: Dictionary = it.get("specs", {}) as Dictionary
		if bool(sp.get("pond_storage", false)) and str(sp.get("osm_water_tag", "")) == tag:
			return it
	return {}


## Route `turbine_id`'s penstock from `source` (resolve_hydro_source_at's
## dict). ONE penstock per turbine: whatever it had is replaced. `opts`:
## pipe_size_in / pipe_sdr / stock_length_m (style), handle_id (default
## res_in_0). Returns the connection id, "" on failure (with a toast).
func route_penstock_to_source(turbine_id: String, source: Dictionary, opts: Dictionary = {}) -> String:
	if model == null or turbine_id.is_empty() or source.is_empty():
		return ""
	var turbine := model.get_item(turbine_id)
	if str((turbine.get("specs", {}) as Dictionary).get("role", "")) != "siphon_hydro":
		view._show_toast("Only a hydro turbine takes a penstock")
		return ""
	var handle := str(opts.get("handle_id", "res_in_0"))
	var style := {}
	for k in ["pipe_size_in", "pipe_sdr", "stock_length_m"]:
		if opts.has(k):
			style[k] = opts[k]
	match str(source.get("kind", "")):
		"pond":
			return _route_penstock_from_pond(turbine_id, str(source.get("item_id", "")), handle, style)
		"pond_unadded":
			view._show_toast("Add that pond to the graph first (aim at it → Pond settings → Add to graph)", 4.0)
			return ""
		"stream":
			return tap_stream_for_turbine(str(source.get("feature_id", "")), int(source.get("seg", 0)),
					turbine_id, handle, style)
		"spring":
			return create_penstock_intake_at(source.get("world_pos", Vector3.ZERO) as Vector3,
					turbine_id, handle, style)
	return ""


## A pond on the graph feeds the turbine through a contour-routed poly
## penstock: reuse the pond→turbine water wire when there is one (the Lab's
## old "From pond" restyle), else add it; any other penstock goes.
func _route_penstock_from_pond(turbine_id: String, tank_id: String, handle: String,
		style_ov: Dictionary) -> String:
	var tank := model.get_item(tank_id)
	if tank.is_empty() or not bool((tank.get("specs", {}) as Dictionary).get("pond_storage", false)):
		view._show_toast("That is not a pond on the graph")
		return ""
	var conn_id := ""
	for conn: Dictionary in model.connections:
		var s := str(conn.get("source_item_id", ""))
		var t := str(conn.get("target_item_id", ""))
		if (s == tank_id and t == turbine_id) or (s == turbine_id and t == tank_id):
			conn_id = str(conn.get("id", ""))
			break
	if conn_id.is_empty():
		conn_id = model.generate_connection_id()
		model.add_connection({
			"id": conn_id,
			"source_item_id": tank_id, "source_handle_id": "output",
			"target_item_id": turbine_id, "target_handle_id": handle,
			"polarity": "resource", "resource_type": "water",
			"conduit_type": "poly_penstock", "conduit_style": {},
			"visible_3d": true, "flow_glow": true,
		})
	_remove_existing_penstock(turbine_id, conn_id)
	var conn := model.get_connection(conn_id)
	var style: Dictionary = (conn.get("conduit_style", {}) as Dictionary).duplicate(true)
	for k in style_ov:
		style[k] = style_ov[k]
	style.erase("route_mode")
	model.update_connection(conn_id, {
		"conduit_type": "poly_penstock",
		"conduit_style": style,
		"visible_3d": true, "flow_glow": true,
		"route_3d": [], "route_locked": false,
	})
	reveal_penstock_conduit(conn_id)
	view._schedule_graph_autosave()
	view._show_toast("Penstock routed from %s" % str((tank.get("specs", {}) as Dictionary).get("name", "the pond")))
	return conn_id


## The best uphill source for a turbine: a STREAM vertex within `max_m` that
## stands ≥ 1 m above it (highest wins, shorter run on a tie), else the
## highest bare ground on a ring scan (the old Lab auto-route). {} = nothing
## higher. A creek is where the water is; the terrain scan found hilltops
## with no flow on them.
func find_uphill_source(turbine_id: String, max_m: float = 150.0) -> Dictionary:
	var turbine := model.get_item(turbine_id) if model != null else {}
	var t_xz: Vector2 = view._item_world_xz(turbine)
	var main: Node = view._get_scene_main_node()
	if not is_finite(t_xz.x) or main == null:
		return {}
	var t_y := TerrainSurfaceQuery.ground_height_at(main, t_xz.x, t_xz.y)
	var loader: Node = view._find_terrain_loader(main)
	var best := {}
	var best_y := t_y + 1.0
	var best_d := INF
	if loader != null and loader.has_method("water_network"):
		var wn: Node = loader.call("water_network")
		if wn != null:
			for f_v in wn.call("features"):
				var f: Dictionary = f_v
				var fid := str(f.get("id", ""))
				if fid.begins_with("dc_"):
					continue
				var pts: PackedVector2Array = f.get("points", PackedVector2Array())
				for i in range(0, pts.size() - 1):
					var d := pts[i].distance_to(t_xz)
					if d > max_m:
						continue
					var y := TerrainSurfaceQuery.ground_height_at(main, pts[i].x, pts[i].y)
					if y > best_y + 0.05 or (absf(y - best_y) <= 0.05 and d < best_d):
						best_y = y
						best_d = d
						best = {"kind": "stream", "feature_id": fid, "seg": i,
							"label": str(f.get("name", "")) if not str(f.get("name", "")).is_empty() else str(f.get("kind", "stream")).capitalize(),
							"rise_m": y - t_y}
	if not best.is_empty():
		return best
	for i in 48:
		var a := TAU * float(i) / 48.0
		for r in [30.0, 60.0, 90.0, 120.0]:
			var wx: float = t_xz.x + cos(a) * float(r)
			var wz: float = t_xz.y + sin(a) * float(r)
			var gy := TerrainSurfaceQuery.ground_height_at(main, wx, wz)
			var d2 := float(r)
			if gy > best_y + 0.05 or (absf(gy - best_y) <= 0.05 and d2 < best_d):
				best_y = gy
				best_d = d2
				best = {"kind": "spring", "world_pos": Vector3(wx, gy, wz), "label": "Spring", "rise_m": gy - t_y}
	return best


## What feeds this turbine now — for the Lab's source line:
## {kind: "pond"|"stream"|"spring"|"none", label, detail}.
func hydro_source_summary(turbine_id: String) -> Dictionary:
	if model == null or turbine_id.is_empty():
		return {"kind": "none", "label": "", "detail": ""}
	var item := model.get_item(turbine_id)
	var intake: Dictionary = {}
	if view._resource_flow != null and view._resource_flow.has_method("_stream_intake_for"):
		intake = view._resource_flow.call("_stream_intake_for", item)
	if not intake.is_empty():
		var isp: Dictionary = intake.get("specs", {}) as Dictionary
		var q := float(isp.get("live_supply_lps", NAN))
		var wf := str(isp.get("water_feature_name", ""))
		if not str(isp.get("water_feature_bind", isp.get("water_feature_id", ""))).is_empty():
			return {"kind": "stream", "label": wf if not wf.is_empty() else "Stream",
				"detail": ("%.2f L/s at the intake" % q) if not is_nan(q) else "measuring…"}
		return {"kind": "spring", "label": str(isp.get("name", "Spring intake")),
			"detail": ("%.2f L/s (base %.2f + rain)" % [q, float(isp.get("base_flow_lps", 0.0))]) if not is_nan(q) else ""}
	var pond: Dictionary = view.resolve_siphon_pond(turbine_id)
	if not pond.is_empty():
		var ps: Dictionary = pond.get("specs", {}) as Dictionary
		var lvl := float(ps.get("level_m", NAN))
		return {"kind": "pond", "label": str(ps.get("name", "Pond")),
			"detail": ("level %.2f m" % lvl) if not is_nan(lvl) else "stored water"}
	return {"kind": "none", "label": "No source", "detail": "drag the intake uphill, tap a stream, or bind a pond"}


## Hydro turbines (role siphon_hydro) on the graph, nearest `world_xz` first,
## with their world XZ: [{item, xz, dist}].
func hydro_turbines_near(world_xz: Vector2, max_m: float) -> Array:
	var out: Array = []
	if model == null:
		return out
	for it: Dictionary in model.items_of_type("processor"):
		if str((it.get("specs", {}) as Dictionary).get("role", "")) != "siphon_hydro":
			continue
		var xz: Vector2 = view._item_world_xz(it)
		if not is_finite(xz.x):
			continue
		var d := xz.distance_to(world_xz)
		if d <= max_m:
			out.append({"item": it, "xz": xz, "dist": d})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["dist"]) < float(b["dist"]))
	return out


## Seat a PowerSpout PLT at `world_xz`: the prop, the graph node bound to it,
## the spin binding — exactly what the penstock harness and the library's
## "Place model" flow do. Returns the new item id, "" on failure.
func place_powerspout_at(world_xz: Vector2) -> String:
	var main: Node = view._get_scene_main_node()
	if main == null or model == null:
		return ""
	var preset := ComponentPresets.preset_with_turbine_kind("powerspout_pelton")
	if preset.is_empty():
		return ""
	var placed: Dictionary = PlacedPropService.place_model_at_xz(
			main, "powerspout_plt", world_xz.x, world_xz.y)
	if not bool(placed.get("ok", false)):
		return ""
	var prop_id := str(placed.get("prop_id", ""))
	var specs: Dictionary = (preset.get("specs", {}) as Dictionary).duplicate(true)
	specs["bound_prop_id"] = prop_id
	specs["gross_head_m"] = 0.0  # the routed geometry is the authority
	var item_id: String = model.generate_item_id()
	var site := Vector2.ZERO
	var soi := view.get_node_or_null("/root/SoiService")
	if soi != null and soi.has_method("world_center"):
		site = GraphSiteLayout.world_xz_to_site(world_xz, soi.call("world_center") as Vector3)
	model.add_item({
		"id": item_id, "type": "processor",
		"x": randf_range(-90.0, 90.0), "y": randf_range(-70.0, 70.0),
		"width": float(preset.get("width", 150.0)), "height": float(preset.get("height", 130.0)),
		"scope_id": view._active_scope_id,
		"site_x_m": site.x, "site_z_m": site.y,
		"elevation_m": float(placed.get("ground_y", 0.0)),
		"is_virtual": false,
		"specs": specs,
	})
	PlacedPropService.update_prop_record(main, prop_id,
			{"graph_item_id": item_id, "kind": "siphon_hydro",
			"turbine_node": ModelCatalog.turbine_node_for("powerspout_plt"),
			"spin_axis": ModelCatalog.spin_axis_for("powerspout_plt")}, true)
	return item_id


## Turn a stream reach into a penstock. `reach_xz` = the stream's vertices
## from the intake vertex DOWN to the exit vertex (world XZ, downstream
## order); `turbine_id` the PowerSpout to feed. Places the intake at the
## first vertex, routes the penstock through the reach's interior vertices
## (so the pipe follows the creek bed, not a straight chord over the ridge),
## binds the intake to `feature_id`, and replaces any penstock the turbine
## already had. Returns the connection id, "" on failure.
func create_penstock_from_stream(feature_id: String, feature_name: String,
		reach_xz: PackedVector2Array, turbine_id: String, style_ov: Dictionary = {}) -> String:
	if reach_xz.size() < 2 or turbine_id.is_empty():
		return ""
	var main: Node = view._get_scene_main_node()
	var mgr: Node3D = view._get_conduit_manager()
	var ground := func(xz: Vector2) -> float:
		if mgr != null and mgr.has_method("ground_y_at"):
			return float(mgr.call("ground_y_at", Vector3(xz.x, 0.0, xz.y)))
		return TerrainSurfaceQuery.ground_height_at(main, xz.x, xz.y)
	var head := reach_xz[0]
	var route: Array = []
	# Interior vertices only — the endpoints are the intake's and turbine's
	# own port anchors. A creek meanders tighter than coil bends: keep a
	# vertex only when it is at least 2.5 bend radii past the last kept one
	# (so every corner has legs long enough for its arc), and never more than
	# 24 of them — the contour router resamples every metre anyway.
	var r_min := ConduitKinds.contour_bend_radius_m("poly_penstock", style_ov)
	var min_leg := maxf(2.5 * r_min, 3.0)
	var kept: Array = []
	var last := reach_xz[0]
	var tail := reach_xz[reach_xz.size() - 1]
	for i in range(1, reach_xz.size() - 1):
		var p := reach_xz[i]
		if p.distance_to(last) < min_leg or p.distance_to(tail) < min_leg:
			continue
		kept.append(p)
		last = p
	var stride := maxi(1, int(ceilf(float(kept.size()) / 24.0)))
	for i in range(0, kept.size(), stride):
		var p2: Vector2 = kept[i]
		route.append(Vector3(p2.x, float(ground.call(p2)), p2.y))
	return create_penstock_intake_at(Vector3(head.x, float(ground.call(head)), head.y),
			turbine_id, "res_in_0", style_ov,
			{"route_3d": route, "water_feature_id": feature_id,
				"water_feature_name": feature_name})


## The turbine's existing contour penstock, its intake (when that intake is
## a stream tap wired to nothing else) and the intake's prop — removed, so a
## re-routed penstock REPLACES the old one. A second drag used to leave two
## penstocks and two intakes, and the engine fed the turbine from whichever
## connection it found first.
func _remove_existing_penstock(turbine_id: String, keep_conn_id: String = "") -> void:
	if model == null:
		return
	var doomed: Array[Dictionary] = []
	for conn: Dictionary in model.connections:
		if str(conn.get("id", "")) == keep_conn_id:
			continue
		if str(conn.get("source_item_id", "")) != turbine_id \
				and str(conn.get("target_item_id", "")) != turbine_id:
			continue
		if str(conn.get("conduit_type", "")) != "poly_penstock":
			continue
		doomed.append(conn)
	for old in doomed:
		var other_id := str(old.get("source_item_id", ""))
		if other_id == turbine_id:
			other_id = str(old.get("target_item_id", ""))
		model.remove_connection(str(old.get("id", "")))
		var other := model.get_item(other_id)
		if not ResourceFlowEngine.is_stream_intake(other):
			continue
		var still_wired := false
		for conn2: Dictionary in model.connections:
			if str(conn2.get("source_item_id", "")) == other_id \
					or str(conn2.get("target_item_id", "")) == other_id:
				still_wired = true
		if still_wired:
			continue
		var pid := str((other.get("specs", {}) as Dictionary).get("bound_prop_id", ""))
		model.remove_item(other_id)
		var loader: Node = view._find_terrain_loader(view._get_scene_main_node())
		if loader != null and not pid.is_empty() and loader.has_method("delete_prop_by_id"):
			loader.call("delete_prop_by_id", pid)


## A penstock the player just routed must RENDER, or nothing downstream works:
## ConduitManager skips `_on_model_changed` entirely while global 3D wires are
## off, and only the focused connection is built otherwise — so the mesh never
## exists, and because `route_length_m` / the endpoint inverts are stamped
## INSIDE the rebuild, the flow engine never adopts the measured run either.
## Turning wires on + focusing + forcing one remesh is what closes that loop.
func reveal_penstock_conduit(conn_id: String) -> void:
	if conn_id.is_empty():
		return
	var mgr: Node3D = view._get_conduit_manager()
	if mgr == null:
		return
	# The conn carries visible_3d: true, and the manager now renders explicit
	# conns whatever the global 3D-wires toggle says — no need to flip the
	# player's global preference anymore. Focus + a forced remesh (twice: the
	# first can race empty port anchors) is all it takes.
	if mgr.has_method("set_focus_highlight"):
		mgr.call("set_focus_highlight", conn_id)
	if mgr.has_method("force_remesh"):
		mgr.call("force_remesh", conn_id)
		view.get_tree().create_timer(0.15).timeout.connect(
				func() -> void:
					if mgr != null and is_instance_valid(mgr) \
							and mgr.has_method("force_remesh"):
						mgr.call("force_remesh", conn_id),
				CONNECT_ONE_SHOT)
	if view._graph_canvas != null:
		view._graph_canvas.call("queue_redraw")


## True when this turbine is wired to a tapped stream/spring intake. Such a
## turbine already HAS a water source — the penstock — and must never be
## auto-rebound to a pond, because binding replaces the water-in wiring.
## The explicit "Rebind to nearest pond" button is deliberately not gated by this:
## that one is the player asking.
func turbine_has_stream_source(siphon_id: String) -> bool:
	if model == null or siphon_id.is_empty():
		return false
	for conn: Dictionary in model.connections:
		var src := str(conn.get("source_item_id", ""))
		var tgt := str(conn.get("target_item_id", ""))
		if src != siphon_id and tgt != siphon_id:
			continue
		var other_id := tgt if src == siphon_id else src
		if ResourceFlowEngine.is_stream_intake(model.get_item(other_id)):
			return true
	return false
