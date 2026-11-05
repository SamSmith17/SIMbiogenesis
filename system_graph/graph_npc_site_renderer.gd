extends RefCounted

## Site Plan NPC layer renderer — the desire raster + legend, tagged spaces,
## crew work sites, and the agent dots (with their render-side motion
## interpolation). Extracted from graph_canvas.gd as a PURE MOVE: same draw
## calls, same providers, same z-order; the canvas keeps the provider vars and
## four one-line call sites in _draw. Deliberately a preloaded RefCounted with
## NO class_name (a new class_name needs a --headless --import before selftests
## resolve it — see CLAUDE.md).
##
## Everything here draws THROUGH the canvas (`c.draw_*`), so this file owns no
## CanvasItem of its own, and it never writes to the bridge/engine — the
## determinism and MP-replication contracts live upstream and are untouched.

## The GraphCanvas this renderer draws on. Untyped: typing it would preload
## graph_canvas.gd from a file graph_canvas.gd preloads (cycle).
var c

## SoI world centre for this draw pass — set by the canvas once per pass
## (each layer used to re-resolve the SoiService autoload per draw).
var center3 := Vector3.ZERO

## Rendering-side dot motion: population ticks land at ~2-4 Hz, so raw dot
## positions STEP — which is most of why the plan read as "nothing moves".
## Per-id prev/next segments with an EMA'd tick interval (the same scheme
## npc_population_host uses to smooth the 3D bodies) place each dot along the
## segment between its last two SIM positions while the canvas tick() drives a
## ~20 Hz redraw. When the sim pauses the lerp saturates and every dot rests
## on its exact sim position.
var _dot_interp: Dictionary = {}   # id -> [prev, next, at_ms, interval_s, sweep]
var _sweep_n := 0
var _dot_sweep_ms: int = 0
## A sim jump past this (scrub / coarse catch-up / teleport) snaps instead of
## gliding a dot across the whole site.
const DOT_SNAP_M := 15.0
## Dots smaller than this (px) draw no heading tick.
const HEADING_MIN_R := 5.0


func _init(canvas) -> void:
	c = canvas


## True while dots have interpolation state — the canvas tick() uses this to
## decide whether to hold the 20 Hz Site Plan redraw cadence.
func has_motion() -> bool:
	return not _dot_interp.is_empty()


## Project a world-XZ point to canvas for the Site Plan NPC overlays (agents,
## spaces, crew sites, desire raster): through the preview camera when it is
## the projection authority — i.e. whenever the live disc is up, which is how
## every other Site Plan element (node chips, elevation overlays) tracks
## orbit/tilt — else the flat top-down mapping. The NPC layers used the flat
## math unconditionally, so orbiting rotated the chips but left the people
## behind. One shared helper so the four layers can't drift again.
## Returns null when the point can't project (skip it).
func project(world_xz: Vector2) -> Variant:
	var svc = c.soi_preview_service
	if c._phys_camera_projection_active() and svc != null \
			and is_instance_valid(svc) and svc.has_method("world_to_canvas"):
		# On the GROUND, not at the SoI centre's height: the lens is a
		# perspective camera, so a point on a slope 10 m below the centre
		# projected at the centre's height lands metres off its 3D spot.
		var y := center3.y
		var soi: Node = c._cached_autoload("/root/SoiService")
		if soi != null and soi.has_method("ground_y_at"):
			y = c._ring_ground_y(soi, world_xz.x, world_xz.y)
		return c.world_to_canvas_cached(Vector3(world_xz.x, y, world_xz.y))
	return c.size * 0.5 + (c.get_view_pan() as Vector2) \
			+ GraphSiteLayout.world_xz_to_site(world_xz, center3) \
			* GraphSiteLayout.px_per_m(c.get_view_zoom())


## An area's outline on screen, cached per space while the view and the
## outline hold still (painted camp outlines run to hundreds of vertices, and
## Site Plan redraws at 20 Hz). `ring` = every vertex projected (empty when
## one falls behind the camera), `idx` = its triangulation (computed in world
## space; a projection keeps the triangles' order), `line` = the ring thinned
## to what shows at this zoom, closed.
var _ring_cache: Dictionary = {}   # space id -> {vk, h, ring, idx, line}


func _screen_ring(sid: String, world: PackedVector2Array, vk: int) -> Dictionary:
	var h := hash(world)
	var rec: Dictionary = _ring_cache.get(sid, {})
	if not rec.is_empty() and int(rec["vk"]) == vk and int(rec["h"]) == h:
		return rec
	ring_misses += 1
	var idx: PackedInt32Array = rec.get("idx", PackedInt32Array()) if not rec.is_empty() and int(rec["h"]) == h \
			else Geometry2D.triangulate_polygon(world)
	var ring := PackedVector2Array()
	for wp in world:
		var rv: Variant = project(wp)
		if rv == null:
			ring = PackedVector2Array()
			break
		ring.append(rv as Vector2)
	var line := PackedVector2Array()
	if not ring.is_empty():
		line = _thin(ring, 0.8)
		line.append(line[0])
	rec = {"vk": vk, "h": h, "ring": ring, "idx": idx, "line": line}
	_ring_cache[sid] = rec
	return rec


## Drop points closer than `tol` px to the last kept one (screen space).
static func _thin(pts: PackedVector2Array, tol: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var t2 := tol * tol
	for p in pts:
		if out.is_empty() or out[out.size() - 1].distance_squared_to(p) >= t2:
			out.append(p)
	return out


func _fill_tris(idx: PackedInt32Array, screen: PackedVector2Array, col: Color) -> void:
	if idx.is_empty():
		return
	var cols := PackedColorArray()
	cols.resize(screen.size())
	cols.fill(col)
	RenderingServer.canvas_item_add_triangle_array(c.get_canvas_item(), idx, screen, cols)


## `project` for points that MOVE (people, their trails): the projection is
## not cached (every frame of interpolation is a new point) and the ground is
## read on a coarse MOVING_GROUND_M grid, so a walking person costs one
## camera projection, not a terrain query per frame.
const MOVING_GROUND_M := 2.0
var _move_ground: Dictionary = {}
var _move_ground_ms := 0


func project_moving(world_xz: Vector2) -> Variant:
	if not c._phys_camera_projection_active():
		return project(world_xz)
	var svc = c.soi_preview_service
	if svc == null or not is_instance_valid(svc):
		return null
	var now := Time.get_ticks_msec()
	if now - _move_ground_ms > 2000 or _move_ground.size() > 20000:
		_move_ground.clear()
		_move_ground_ms = now
	var k := Vector2i(floori(world_xz.x / MOVING_GROUND_M), floori(world_xz.y / MOVING_GROUND_M))
	var y: float
	if _move_ground.has(k):
		y = _move_ground[k]
	else:
		y = center3.y
		var soi: Node = c._cached_autoload("/root/SoiService")
		if soi != null and soi.has_method("ground_y_at"):
			y = float(soi.call("ground_y_at", (float(k.x) + 0.5) * MOVING_GROUND_M,
					(float(k.y) + 0.5) * MOVING_GROUND_M))
		_move_ground[k] = y
	return svc.call("world_to_canvas", Vector3(world_xz.x, y, world_xz.y))


func draw_desire() -> void:
	if not c.npc_desire_provider.is_valid():
		return
	var payload: Variant = c.npc_desire_provider.call()
	if not (payload is Dictionary) or (payload as Dictionary).is_empty():
		return
	var d: Dictionary = payload
	var tex: Texture2D = d.get("texture")
	if tex == null:
		return
	var world: Rect2 = d.get("rect", Rect2())
	if world.size.x <= 0.0 or world.size.y <= 0.0:
		return
	# All four world corners projected individually: an axis-aligned
	# draw_texture_rect cannot follow the orbited camera, so the raster is a
	# textured quad. Un-orbited the projected corners ARE the old rect.
	var corners_w: Array = [
		world.position,
		Vector2(world.end.x, world.position.y),
		world.end,
		Vector2(world.position.x, world.end.y),
	]
	var pts := PackedVector2Array()
	for cw in corners_w:
		var cv: Variant = project(cw as Vector2)
		if cv == null:
			return  # a corner behind the camera — skip the raster this frame
		pts.append(cv as Vector2)
	var bb := Rect2(pts[0], Vector2.ZERO)
	for p in pts:
		bb = bb.expand(p)
	if bb.size.x < 1.0 or bb.size.y < 1.0:
		return
	var uvs := PackedVector2Array([
		Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	c.draw_colored_polygon(pts, Color.WHITE, uvs, tex)
	_draw_desire_legend(d)


## Key for the heat ramp. Without it the colours are just pretty — this says
## what "worn" means in metres.
func _draw_desire_legend(d: Dictionary) -> void:
	var fnt := ThemeDB.fallback_font
	var pad := 10.0
	var bar_w := 132.0
	var bar_h := 9.0
	# Sits clear of the Unplaced tray along the bottom edge.
	var box := Rect2(pad, c.size.y - 142.0, bar_w + pad * 2.0, 52.0)
	c.draw_rect(box, Color(0.04, 0.06, 0.10, 0.82), true)
	c.draw_rect(box, Color(0.30, 0.38, 0.52, 0.75), false, 1.0)
	var title := "Desire lines · %s" % str(d.get("channel_label", "all traffic"))
	c.draw_string(fnt, Vector2(box.position.x + pad, box.position.y + 15.0), title,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.88, 0.91, 0.94, 0.95))
	# The ramp itself, sampled the same way the raster is coloured.
	var bx := box.position.x + pad
	var by := box.position.y + 23.0
	var steps := 44
	for i in steps:
		var t := float(i) / float(steps - 1)
		c.draw_rect(Rect2(bx + bar_w * t, by, bar_w / float(steps) + 1.0, bar_h),
				NpcDesireMap.heat_color(t), true)
	var foot := "quiet → worn %d m · %s" % [
			int(round(float(d.get("peak", 0.0)))), str(d.get("window", ""))]
	c.draw_string(fnt, Vector2(bx, by + bar_h + 13.0), foot,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.62, 0.70, 0.80, 0.92))


## Site Plan: where the people are going. A quiet disc + ring per tagged
## space, with its glyph and live occupancy at closer zoom, so the
## destinations behind the agent dots are legible without swallowing them.
func draw_spaces() -> void:
	if not c.npc_spaces_provider.is_valid():
		return
	PerfSpan.begin("gv_d_sp_prov")
	var marks: Variant = c.npc_spaces_provider.call()
	PerfSpan.end("gv_d_sp_prov")
	if not (marks is Array) or (marks as Array).is_empty():
		return
	spaces_seen = (marks as Array).size()
	var vk := int(c.proj_view_key()) ^ hash(center3)
	var s := GraphSiteLayout.px_per_m(c.get_view_zoom())
	var fnt := ThemeDB.fallback_font
	# Quiet furniture: spaces are destinations, not the action. They used to be
	# 2.5-3x the size of an agent dot at full ring alpha, which visually
	# swallowed the people standing on them — the "markers block the NPCs"
	# report. Smaller, dimmer, and labels only arrive at closer zoom; the crew
	# sites keep full prominence since THEY are the "action here" signal.
	var r := maxf(7.0, 4.5 * s)
	for mark_v in marks as Array:
		if not (mark_v is Dictionary):
			continue
		var mark: Dictionary = mark_v
		var world: Vector2 = mark.get("pos", Vector2.ZERO)
		var screen_v: Variant = project(world)
		if screen_v == null:
			continue
		var screen: Vector2 = screen_v
		if screen.x < -60.0 or screen.y < -60.0 or screen.x > c.size.x + 60.0 \
				or screen.y > c.size.y + 60.0:
			continue
		var stype := str(mark.get("space_type", ""))
		var col := SpaceTypes.color(stype)
		var occupied := int(mark.get("occupied", 0))
		var capacity := maxi(int(mark.get("capacity", 1)), 1)
		var full := occupied >= capacity
		# An AREA space is a region, not a point — draw the outline the player
		# actually drew, with the marker at its interior point. Without this a
		# 40 m plaza and a single portaloo look identical on the plan.
		var poly: PackedVector2Array = mark.get("poly", PackedVector2Array())
		if poly.size() >= 3:
			var rr := _screen_ring(str(mark.get("id", "")), poly, vk)
			var ring: PackedVector2Array = rr["ring"]
			if not ring.is_empty():
				_fill_tris(rr["idx"], ring, Color(col.r, col.g, col.b, 0.06))
				c.draw_polyline(rr["line"], Color(col.r, col.g, col.b, 0.7), 1.6, true)
		GraphFastDraw.disc(c, screen, r, Color(col.r, col.g, col.b, 0.05))
		GraphFastDraw.ring(c, screen, r, Color(col.r, col.g, col.b, 0.35), 1.2)
		# Occupancy sweep on the ring — a full space reads at a glance.
		if occupied > 0:
			var frac := clampf(float(occupied) / float(capacity), 0.0, 1.0)
			if frac >= 0.999:
				GraphFastDraw.ring(c, screen, r, Color(1.0, 0.45, 0.35, 0.95) if full else col, 2.0)
			else:
				c.draw_arc(screen, r, -PI * 0.5, -PI * 0.5 + TAU * frac, maxi(6, int(24.0 * frac)),
						col, 2.0, true)
		if r >= 18.0:
			var glyph := SpaceTypes.icon(stype)
			var fs := 11
			var gw := fnt.get_string_size(glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			c.draw_string(fnt, screen - Vector2(gw * 0.5, -4.0), glyph,
					HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(col.r, col.g, col.b, 0.95))
			var occ := "%d/%d" % [occupied, capacity]
			var ow := fnt.get_string_size(occ, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
			c.draw_string(fnt, screen - Vector2(ow * 0.5, -r - 6.0), occ,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.85, 0.89, 0.94, 0.9))


## Site Plan: active WORK sites — where crews are building right now
## (PACKING_PLAN.md Phase 6.5). Amber disc + tool glyph, drawn under the
## agent dots so the gathered crowd visibly stands ON its work. Sub-quorum
## sites read as a muster ("2/6 ppl" — hands still gathering, work not yet
## paying); quorate sites show the progress sweep instead.
func draw_crew_sites() -> void:
	if not c.npc_crew_provider.is_valid():
		return
	var marks: Variant = c.npc_crew_provider.call()
	if not (marks is Array) or (marks as Array).is_empty():
		return
	var s := GraphSiteLayout.px_per_m(c.get_view_zoom())
	var fnt := ThemeDB.fallback_font
	var r := maxf(11.0, 4.0 * s)
	var amber := Color(1.0, 0.72, 0.20)
	for mark_v in marks as Array:
		if not (mark_v is Dictionary):
			continue
		var mark: Dictionary = mark_v
		var world: Vector2 = mark.get("pos", Vector2.ZERO)
		var screen_v: Variant = project(world)
		if screen_v == null:
			continue
		var screen: Vector2 = screen_v
		if screen.x < -60.0 or screen.y < -60.0 or screen.x > c.size.x + 60.0 \
				or screen.y > c.size.y + 60.0:
			continue
		var quorum := bool(mark.get("quorum", true))
		var col := amber if quorum else Color(0.95, 0.55, 0.25)
		# Haul route: the relay line the brigade posts along, drawn before
		# the site disc so the disc caps its end.
		if mark.has("from") and mark.has("to"):
			var fa_v: Variant = project(mark["from"] as Vector2)
			var fb_v: Variant = project(mark["to"] as Vector2)
			if fa_v != null and fb_v != null:
				var fa: Vector2 = fa_v
				var fb: Vector2 = fb_v
				c.draw_line(fa, fb, Color(col.r, col.g, col.b, 0.55), 2.4, true)
				c.draw_circle(fa, 4.0, Color(col.r, col.g, col.b, 0.8))
				c.draw_circle(fb, 4.0, Color(col.r, col.g, col.b, 0.8))
				# The payoff image: items FLOWING along a working brigade line.
				# Phase is sim time (mark.flow_t), so the pips crawl with the
				# clock, freeze on pause, and rewind on a scrub — and redraws
				# already ride the population tick.
				if quorum and str(mark.get("strategy", "")) == "brigade" \
						and float(mark.get("progress", 0.0)) > 0.0 \
						and float(mark.get("progress", 0.0)) < 1.0:
					var pip := maxf(3.0, 1.2 * s)
					var t0 := float(mark.get("flow_t", 0.0)) * 8.0
					for k in 4:
						var f := fposmod(t0 + float(k) / 4.0, 1.0)
						var at := fa.lerp(fb, f)
						c.draw_rect(Rect2(at - Vector2(pip, pip),
								Vector2(pip * 2.0, pip * 2.0)),
							Color(0.95, 0.72, 0.25, 0.95))
		c.draw_circle(screen, r, Color(col.r, col.g, col.b, 0.14))
		c.draw_arc(screen, r, 0.0, TAU, 40, Color(col.r, col.g, col.b, 0.9), 1.8, true)
		if quorum:
			# Work underway: the sweep is the chore's real progress.
			var frac := clampf(float(mark.get("progress", 0.0)), 0.0, 1.0)
			if frac > 0.0:
				c.draw_arc(screen, r, -PI * 0.5, -PI * 0.5 + TAU * frac, 40,
						Color(0.55, 1.0, 0.45, 0.95), 3.2, true)
		if r >= 11.0:
			var glyph := "🔨"
			var gw := fnt.get_string_size(glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
			c.draw_string(fnt, screen - Vector2(gw * 0.5, -4.0), glyph,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(col.r, col.g, col.b, 0.95))
			var head := str(mark.get("label", ""))
			var crew_txt := "%d/%d ppl — waiting" % [int(mark.get("workers", 0)),
					int(mark.get("min_workers", 1))] if not quorum \
					else "%d ppl" % int(mark.get("workers", 0))
			var lw := fnt.get_string_size(head, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
			c.draw_string(fnt, screen - Vector2(lw * 0.5, r + 16.0), head,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.92, 0.88, 0.78, 0.95))
			var cw := fnt.get_string_size(crew_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
			c.draw_string(fnt, screen - Vector2(cw * 0.5, r + 5.0), crew_txt,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
					Color(col.r, col.g, col.b, 0.95))
	# (Redraws ride the population tick, same as the agent dots.)


func draw_agents() -> void:
	if not c.npc_agents_provider.is_valid():
		return
	PerfSpan.begin("gv_d_ag_prov")
	var dots: Variant = c.npc_agents_provider.call()
	PerfSpan.end("gv_d_ag_prov")
	if not (dots is Array) or (dots as Array).is_empty():
		return
	var s := GraphSiteLayout.px_per_m(c.get_view_zoom())
	# Zoomed far out over a crowd: one count disc per few-metre patch of
	# ground (binned in WORLD space, so only the patch centres are projected).
	# A thousand overlapping 3.5 px dots read as one smear anyway.
	if (dots as Array).size() >= AGG_MIN_PEOPLE and s < AGG_PX_PER_M:
		_draw_agent_groups(dots as Array, s)
		return
	groups_drawn = 0
	agents_drawn = 0
	var now_ms := Time.get_ticks_msec()
	_sweep_n += 1
	var sweep := _sweep_n
	# Person-scale dot: ~0.6 m footprint on the plan, but always readable.
	var r := maxf(3.5, 0.35 * s)
	_after.clear()
	_b_pts.clear()
	_b_cols.clear()
	_b_uvs.clear()
	_b_idx.clear()
	for dot_v in dots as Array:
		if not (dot_v is Dictionary):
			continue
		var dot: Dictionary = dot_v
		var world: Vector2 = dot.get("pos", Vector2.ZERO)
		# Off screen: skip before any per-person work. Tested on the dot's
		# coarse cell, whose projection is cached while the view holds still.
		if not _cell_on_screen(world, s):
			continue
		# Rendering-side smoothing (see _dot_interp): glide toward the newest
		# sim position over the observed tick interval.
		var move_dir := Vector2.ZERO
		var did: Variant = dot.get("id", "")
		if did is String and not (did as String).is_empty():
			# [prev, next, at_ms, interval_s, sweep stamp] (an Array: this runs
			# for every person on screen at 20 Hz).
			var rec: Array = _dot_interp.get(did, [])
			if rec.is_empty():
				rec = [world, world, now_ms, 0.35, sweep]
				_dot_interp[did] = rec
			else:
				rec[4] = sweep
				var nxt: Vector2 = rec[1]
				if nxt != world:
					if nxt.distance_to(world) > DOT_SNAP_M:
						rec[0] = world   # scrub/catch-up jump: snap, don't glide
					else:
						rec[0] = nxt
						var since := float(now_ms - int(rec[2])) / 1000.0
						rec[3] = clampf(lerpf(float(rec[3]), since, 0.3), 0.1, 1.0)
					rec[1] = world
					rec[2] = now_ms
			var f := clampf(float(now_ms - int(rec[2])) / (float(rec[3]) * 1000.0), 0.0, 1.0)
			var pv: Vector2 = rec[0]
			var nv: Vector2 = rec[1]
			move_dir = nv - pv
			world = pv.lerp(nv, f)
		var screen_v: Variant = project_moving(world)
		if screen_v == null:
			continue
		var screen: Vector2 = screen_v
		if screen.x < -20.0 or screen.y < -20.0 or screen.x > c.size.x + 20.0 \
				or screen.y > c.size.y + 20.0:
			continue
		agents_drawn += 1
		# Recent trail behind the dot — the aggregate heat map is statistical;
		# this is what makes the view feel alive.
		if c.npc_trails_enabled:
			var trail: Variant = dot.get("trail", null)
			if trail is PackedVector2Array and (trail as PackedVector2Array).size() >= 2:
				var pts: PackedVector2Array = trail
				var n := pts.size()
				# Zoomed out a trail is a couple of pixels — decimate to ~8
				# segments so a big roster doesn't pay a camera unproject per
				# vertex per agent per draw (the per-point projection is the
				# cost under an orbited camera).
				var stride := maxi(1, int(ceilf(float(n) / (8.0 if s < 1.5 else 12.0))))
				var prev_v: Variant = project_moving(pts[0])
				var i := stride
				while i < n:
					var cur_v: Variant = project_moving(pts[i])
					if prev_v != null and cur_v != null:
						var fade := float(i) / float(n)
						var tc: Color = dot.get("color", Color.WHITE)
						tc.a = fade * 0.5
						c.draw_line(prev_v as Vector2, cur_v as Vector2, tc,
								maxf(1.0, r * 0.4), true)
					prev_v = cur_v
					i += stride
		# Body = the person's own pastel (identity); rim = their morale band,
		# so the camp's mood is readable at a glance across the whole site.
		var col: Color = dot.get("color", Color.WHITE)
		var mood: Color = dot.get("morale_color", Color(0.6, 0.6, 0.6))
		# Every person's discs go into ONE textured triangle array, drawn
		# after the loop (one draw instead of three or four per person).
		_batch_disc(screen, r + 2.0, Color(0.0, 0.0, 0.0, 0.55))
		_batch_disc(screen, r + 1.4, mood)
		_batch_disc(screen, r, col)
		var asleep := str(dot.get("activity", "")) == "sleep"
		# Asleep reads as a dimmer dot.
		if asleep:
			_batch_disc(screen, r * 0.55, Color(0.05, 0.08, 0.16, 0.75))
		# Carrying a crate: a small amber square riding the dot — a working
		# haul line reads as dots with items flowing along it (the payoff
		# image PACKING_PLAN Phase 6 names).
		elif bool(dot.get("carrying", false)):
			var hw := maxf(r * 0.55, 2.0)
			_after.append([0, Rect2(screen - Vector2(hw, hw), Vector2(hw * 2.0, hw * 2.0))])
		# Heading tick: a short line ahead of a moving dot, in the direction of
		# travel. The interp segment gives the direction for free; it is
		# projected (not drawn in world axes) so it stays honest under an
		# orbited camera.
		# (Not on a dot this small: the tick is a pixel or two and costs a
		# second projection per person.)
		if r >= HEADING_MIN_R and not asleep and move_dir.length_squared() > 0.0025:
			var tip_v: Variant = project_moving(world + move_dir.normalized() * 1.2)
			if tip_v != null:
				var tip_dir: Vector2 = (tip_v as Vector2) - screen
				if tip_dir.length_squared() > 0.01:
					_after.append([1, screen + tip_dir.normalized() * r,
							screen + tip_dir.normalized() * (r + maxf(3.0, r * 0.9)),
							Color(col.r, col.g, col.b, 0.9)])
	_flush_batch()
	for a_v in _after:
		var a: Array = a_v
		if int(a[0]) == 0:
			c.draw_rect(a[1] as Rect2, Color(0.95, 0.72, 0.25, 0.95))
		else:
			c.draw_line(a[1] as Vector2, a[2] as Vector2, a[3] as Color, 1.6, true)
	_after.clear()
	# Drop interpolation records for departed/rerolled agents occasionally.
	if now_ms - _dot_sweep_ms > 2000:
		_dot_sweep_ms = now_ms
		for k in _dot_interp.keys():
			if int((_dot_interp[k] as Array)[4]) < sweep - 40:
				_dot_interp.erase(k)


## People at or above this count may be grouped when zoomed out.
const AGG_MIN_PEOPLE := 250
## Below this many screen px per metre (a person is under ~1 px wide) they are.
const AGG_PX_PER_M := 2.0
## A group's patch on screen, px.
const AGG_CELL_PX := 16.0
## Count discs drawn on the last pass (0 = people drawn one by one).
var groups_drawn := 0
var spaces_seen := 0
var ring_misses := 0
var agents_drawn := 0


func _draw_agent_groups(dots: Array, s: float) -> void:
	var cell_m := AGG_CELL_PX / maxf(s, 1e-4)
	var bins: Dictionary = {}   # Vector2i -> [sum_pos, n, sum_morale_col]
	for dot_v in dots:
		if not (dot_v is Dictionary):
			continue
		var dot: Dictionary = dot_v
		var w: Vector2 = dot.get("pos", Vector2.ZERO)
		var k := Vector2i(floori(w.x / cell_m), floori(w.y / cell_m))
		var mood: Color = dot.get("morale_color", Color(0.6, 0.6, 0.6))
		var b: Array = bins.get(k, [])
		if b.is_empty():
			bins[k] = [w, 1, mood]
		else:
			b[0] = (b[0] as Vector2) + w
			b[1] = int(b[1]) + 1
			b[2] = (b[2] as Color) + mood
	var fnt := ThemeDB.fallback_font
	groups_drawn = 0
	for b_v in bins.values():
		var b: Array = b_v
		var n := int(b[1])
		var sv: Variant = project_moving((b[0] as Vector2) / float(n))
		if sv == null:
			continue
		var sc: Vector2 = sv
		if sc.x < -30.0 or sc.y < -30.0 or sc.x > c.size.x + 30.0 or sc.y > c.size.y + 30.0:
			continue
		var mc: Color = (b[2] as Color) / float(n)
		mc.a = 1.0
		var r := clampf(3.0 + sqrt(float(n)) * 1.6, 3.5, AGG_CELL_PX * 0.75)
		GraphFastDraw.disc(c, sc, r + 1.5, Color(0.0, 0.0, 0.0, 0.55))
		GraphFastDraw.disc(c, sc, r, mc)
		groups_drawn += 1
		if n >= 5 and r >= 7.0:
			var t := str(n)
			var tw := fnt.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
			c.draw_string(fnt, sc + Vector2(-tw * 0.5, 3.5), t, HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
					Color(0.04, 0.05, 0.08, 0.95))


## People are culled by their CULL_CELL_M cell: its centre, projected at the
## SoI centre's height (cached), must land within the canvas grown by the
## cell's own size and a margin.
const CULL_CELL_M := 8.0


func _cell_on_screen(world: Vector2, s: float) -> bool:
	var cx := (floorf(world.x / CULL_CELL_M) + 0.5) * CULL_CELL_M
	var cz := (floorf(world.y / CULL_CELL_M) + 0.5) * CULL_CELL_M
	var sp: Variant
	if c._phys_camera_projection_active():
		sp = c.world_to_canvas_cached(Vector3(cx, center3.y, cz))
		if sp == null:
			return true   # near or behind the camera: let the full test decide
	else:
		sp = project(Vector2(cx, cz))
	var pad := 160.0 + 2.0 * CULL_CELL_M * s
	var p: Vector2 = sp
	return p.x > -pad and p.y > -pad and p.x < c.size.x + pad and p.y < c.size.y + pad


## The people batch: textured quads of one white disc texture.
var _b_pts := PackedVector2Array()
var _b_cols := PackedColorArray()
var _b_uvs := PackedVector2Array()
var _b_idx := PackedInt32Array()
var _after: Array = []
const BATCH_TEX_D := 64


func _batch_disc(at: Vector2, r: float, col: Color) -> void:
	if r <= 0.25 or col.a <= 0.0:
		return
	# The texture is BATCH_TEX_D px of disc in a 1 px margin each side.
	var h := r * float(BATCH_TEX_D + 2) / float(BATCH_TEX_D)
	var i := _b_pts.size()
	_b_pts.append(at + Vector2(-h, -h))
	_b_pts.append(at + Vector2(h, -h))
	_b_pts.append(at + Vector2(h, h))
	_b_pts.append(at + Vector2(-h, h))
	_b_uvs.append(Vector2(0, 0))
	_b_uvs.append(Vector2(1, 0))
	_b_uvs.append(Vector2(1, 1))
	_b_uvs.append(Vector2(0, 1))
	for _k in 4:
		_b_cols.append(col)
	_b_idx.append(i)
	_b_idx.append(i + 1)
	_b_idx.append(i + 2)
	_b_idx.append(i)
	_b_idx.append(i + 2)
	_b_idx.append(i + 3)


func _flush_batch() -> void:
	if _b_idx.is_empty():
		return
	var t := GraphFastDraw._disc_tex(BATCH_TEX_D, 0.0)
	RenderingServer.canvas_item_add_triangle_array(c.get_canvas_item(), _b_idx, _b_pts, _b_cols,
		_b_uvs, PackedInt32Array(), PackedFloat32Array(), t.get_rid())
