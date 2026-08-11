class_name ConduitRouteDispatch
extends RefCounted

## Single source of truth for conduit route control-point generation, shared by the
## committed-wire builder (ConduitManager.build_control_points) and the drag preview
## (conduit_route_controller). Previously each re-implemented the port-end resolver +
## route-mode cascade in parallel, and they had drifted — the live wire could differ
## from the ghost the player dragged (obstacles ignored in preview, per-connection
## fitting-angle override dropped, ortho/culvert routers missing from the preview).
##
## Both callers now feed THESE two statics, so the preview and the commit produce
## identical geometry from identical inputs. Pure static — no scene/model state; the
## caller resolves anchors, obstacles, and waypoints and passes them in.
##
## The seating/legalization layer (ConduitManager._approach_chain /
## _seat_approaches_legal / _packed_to_array) and the routers (ConduitOrthoRouter /
## ConduitPipesRouter / CulvertRouter / ConduitAStar / PipeFittingExpander) were
## already shared statics; this file consolidates the DISPATCH that sits above them.


## Resolve the true port seats + approach route ends for a connection's two endpoints.
## `a`/`b` are the resolved anchor positions (the preview overrides these with its live
## drag anchors, so they can't be reconstructed from the connection alone). Returns
## {a, b, a_route, b_route, seat_a, seat_b, out_a, out_b}. Hang-edit cords own their
## own end approach, so they get pass-through ends.
static func resolve_route_ends(a: Vector3, b: Vector3, src: Dictionary, tgt: Dictionary,
		src_h: String, tgt_h: String, type_id: String, main: Node) -> Dictionary:
	var out := {
		"a": a, "b": b,
		"a_route": a, "b_route": b,
		"seat_a": false, "seat_b": false,
		"out_a": Vector3.ZERO, "out_b": Vector3.ZERO,
	}
	if ConduitKinds.supports_hang_edit(type_id):
		return out
	var a_bind := ConduitManager.resolve_port_binding(src, src_h, main)
	var b_bind := ConduitManager.resolve_port_binding(tgt, tgt_h, main)
	var a_stub := a_bind.get("approach", Vector3.INF) as Vector3
	var b_stub := b_bind.get("approach", Vector3.INF) as Vector3
	out["out_a"] = a_bind.get("outward", Vector3.ZERO) as Vector3
	out["out_b"] = b_bind.get("outward", Vector3.ZERO) as Vector3
	if is_finite(a_stub.x) and a_stub.distance_to(a) >= ConnectionPortDefs.MIN_APPROACH_M:
		out["a_route"] = a_stub
		out["seat_a"] = true
	if is_finite(b_stub.x) and b_stub.distance_to(b) >= ConnectionPortDefs.MIN_APPROACH_M:
		out["b_route"] = b_stub
		out["seat_b"] = true
	return out


## The route-mode dispatch cascade (ortho / culvert / pipes[kit|locked|fitting|A*] /
## direct). `ends` is the dict from resolve_route_ends(). `waypoints` are the mid
## points already resolved to Vector3 (manager: locked route_3d; preview: live
## working waypoints + the ghost cursor). `obstacles` is the prop-obstacle set for
## A* (empty = no avoidance). `allow_astar` gates the expensive obstacle-aware A*
## pass: the preview passes false while the cursor is actively moving (cheap route)
## and true once motion settles, so the ghost converges to the exact committed
## geometry without a drop-time snap; commit always passes true.
static func control_points(ends: Dictionary, type_id: String, style_ov: Dictionary,
		waypoints: Array, locked: bool, obstacles: Array, allow_astar: bool,
		site_clearance_m: float, ground_fn: Callable = Callable()) -> Array:
	var a: Vector3 = ends.get("a", Vector3.ZERO)
	var b: Vector3 = ends.get("b", Vector3.ZERO)
	var a_route: Vector3 = ends.get("a_route", a)
	var b_route: Vector3 = ends.get("b_route", b)
	var seat_a := bool(ends.get("seat_a", false))
	var seat_b := bool(ends.get("seat_b", false))
	var out_a: Vector3 = ends.get("out_a", Vector3.ZERO)
	var out_b: Vector3 = ends.get("out_b", Vector3.ZERO)

	var meta: Dictionary = ConduitKinds.type_meta(type_id)
	var route_mode := ConduitKinds.normalize_route_mode(
		str(style_ov.get("route_mode", meta.get("route_mode", ""))))
	var elbow_frac := float(style_ov.get("elbow_radius_frac",
		meta.get("elbow_radius_frac", 0.35)))
	var want_culvert := route_mode == "culvert" \
			or (route_mode.is_empty() and ConduitKinds.uses_culvert_kit(type_id))
	# Contour (poly penstock): the ground samples ARE the route — this is the
	# ONE mode that receives the ground callable (the pipes branch deliberately
	# passes Callable(); see the comment there).
	if route_mode == "contour":
		var c_pts: Array = [a_route]
		for wp: Vector3 in waypoints:
			c_pts.append(wp)
		c_pts.append(b_route)
		var r_min := ConduitKinds.contour_bend_radius_m(type_id, style_ov)
		var packed_c := ContourRouter.route_polyline(c_pts, ground_fn, r_min)
		return ConduitManager._seat_approaches_legal(a, b,
			ConduitManager._packed_to_array(packed_c),
			seat_a, seat_b, out_a, out_b, false, 0.0)
	var want_pipes := (route_mode == "pipes" \
			or (route_mode.is_empty() and ConduitKinds.is_pipes_type(type_id))) \
			and not want_culvert
	var want_ortho := route_mode == "ortho" \
			or (route_mode.is_empty() and ConduitKinds.is_rigid_type(type_id) \
				and not want_pipes and not want_culvert and not locked)
	var pipes_frac := elbow_frac if style_ov.has("elbow_radius_frac") \
			or meta.has("elbow_radius_frac") else ConduitPipesRouter.DEFAULT_ELBOW_FRAC
	# Per-connection fitting override flows through style_ov for BOTH callers now.
	var fit_step := ConduitKinds.fitting_step_deg(type_id, style_ov) if want_pipes else 0.0
	var use_kit := want_pipes and ConduitKinds.uses_pipe_kit(type_id) \
			and not ConduitKinds.uses_culvert_kit(type_id)
	if use_kit:
		pipes_frac = 0.0
	# Honor explicit mid-points whenever present. For the committed builder that
	# only happens when the route is locked (it passes [] otherwise), so manager
	# behavior is byte-identical; the drag preview passes its LIVE working
	# waypoints (+ ghost) so the ghost shows the pinned route it will commit to.
	var has_pins := not waypoints.is_empty()

	if want_ortho:
		var op_mids: Array = []
		if has_pins:
			for wp: Vector3 in waypoints:
				op_mids.append(wp)
		var op := ConduitOrthoRouter.route(a_route, b_route, op_mids, true, elbow_frac)
		return ConduitManager._seat_approaches_legal(a, b, ConduitManager._packed_to_array(op),
			seat_a, seat_b, out_a, out_b, false, 0.0)
	if want_culvert:
		var cul_mids: Array = waypoints if has_pins else []
		var cul_chain: Array = ConduitManager._approach_chain(
			a, b, a_route, b_route, cul_mids, seat_a, seat_b, out_a, out_b)
		var r_bend := CulvertKit.bend_radius_for_type(type_id, style_ov)
		return ConduitManager._packed_to_array(CulvertRouter.expand(cul_chain, r_bend))
	if want_pipes:
		# Pipes route at the PORTS' heights (empty ground callable) — an actual
		# ground fn made runs dive to the floor and back.
		var step := fit_step if fit_step > 0.5 else 45.0
		if use_kit:
			var kit_mids: Array = waypoints if has_pins else []
			var sharp_kit: Array = ConduitManager._approach_chain(
				a, b, a_route, b_route, kit_mids, seat_a, seat_b, out_a, out_b)
			return ConduitManager._packed_to_array(PipeFittingExpander.expand(sharp_kit, step))
		if has_pins:
			var pin_mids: Array = []
			for wp: Vector3 in waypoints:
				pin_mids.append(wp)
			var packed_locked := ConduitPipesRouter.route(
				a_route, b_route, pin_mids, Callable(), 0.12,
				pipes_frac, obstacles, 0.0)
			return ConduitManager._seat_approaches_legal(a, b,
				ConduitManager._packed_to_array(packed_locked),
				seat_a, seat_b, out_a, out_b, true, step)
		if fit_step > 0.0:
			var packed_fit := ConduitPipesRouter.route(
				a_route, b_route, [], Callable(), 0.12,
				pipes_frac, obstacles, fit_step)
			return ConduitManager._seat_approaches_legal(a, b,
				ConduitManager._packed_to_array(packed_fit),
				seat_a, seat_b, out_a, out_b, true, step)
		# Unlocked axis pipes: obstacle-aware A* (settle-gated), else geometric fallback.
		if allow_astar:
			var astar_packed := ConduitAStar.route_local(
				a_route, b_route, obstacles, pipes_frac, site_clearance_m)
			var astar_path := ConduitManager._packed_to_array(astar_packed)
			if astar_path.size() >= 2:
				return ConduitManager._seat_approaches_legal(a, b, astar_path,
					seat_a, seat_b, out_a, out_b, true, step)
		var packed_fb := ConduitPipesRouter.route(
			a_route, b_route, [], Callable(), 0.12,
			pipes_frac, obstacles, 0.0)
		return ConduitManager._seat_approaches_legal(a, b,
			ConduitManager._packed_to_array(packed_fb),
			seat_a, seat_b, out_a, out_b, true, step)
	# Direct / flexible: endpoints + locked pins only.
	var pts: Array = [a_route]
	for wp: Vector3 in waypoints:
		pts.append(wp)
	pts.append(b_route)
	return ConduitManager._seat_approaches_legal(a, b, pts, seat_a, seat_b,
		out_a, out_b, false, 0.0)
