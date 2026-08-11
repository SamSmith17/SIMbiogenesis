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
var _dot_interp: Dictionary = {}   # id -> {prev, next, at_ms, interval_s}
var _dot_sweep_ms: int = 0
## A sim jump past this (scrub / coarse catch-up / teleport) snaps instead of
## gliding a dot across the whole site.
const DOT_SNAP_M := 15.0


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
		return svc.call("world_to_canvas",
				Vector3(world_xz.x, center3.y, world_xz.y))
	return c.size * 0.5 + (c.get_view_pan() as Vector2) \
			+ GraphSiteLayout.world_xz_to_site(world_xz, center3) \
			* GraphSiteLayout.px_per_m(c.get_view_zoom())


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
	var marks: Variant = c.npc_spaces_provider.call()
	if not (marks is Array) or (marks as Array).is_empty():
		return
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
			var ring := PackedVector2Array()
			var ring_ok := true
			for wp in poly:
				var rv: Variant = project(wp)
				if rv == null:
					ring_ok = false
					break
				ring.append(rv as Vector2)
			if ring_ok:
				c.draw_colored_polygon(ring, Color(col.r, col.g, col.b, 0.06))
				ring.append(ring[0])
				c.draw_polyline(ring, Color(col.r, col.g, col.b, 0.7), 1.6, true)
		c.draw_circle(screen, r, Color(col.r, col.g, col.b, 0.05))
		c.draw_arc(screen, r, 0.0, TAU, 40, Color(col.r, col.g, col.b, 0.35), 1.2, true)
		# Occupancy sweep on the ring — a full space reads at a glance.
		if occupied > 0:
			var frac := clampf(float(occupied) / float(capacity), 0.0, 1.0)
			c.draw_arc(screen, r, -PI * 0.5, -PI * 0.5 + TAU * frac, 40,
					Color(1.0, 0.45, 0.35, 0.95) if full else col, 2.0, true)
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
	var dots: Variant = c.npc_agents_provider.call()
	if not (dots is Array) or (dots as Array).is_empty():
		return
	var s := GraphSiteLayout.px_per_m(c.get_view_zoom())
	var now_ms := Time.get_ticks_msec()
	var seen_ids: Dictionary = {}
	# Person-scale dot: ~0.6 m footprint on the plan, but always readable.
	var r := maxf(3.5, 0.35 * s)
	for dot_v in dots as Array:
		if not (dot_v is Dictionary):
			continue
		var dot: Dictionary = dot_v
		var world: Vector2 = dot.get("pos", Vector2.ZERO)
		# Rendering-side smoothing (see _dot_interp): glide toward the newest
		# sim position over the observed tick interval.
		var move_dir := Vector2.ZERO
		var did := str(dot.get("id", ""))
		if not did.is_empty():
			seen_ids[did] = true
			var rec: Dictionary = _dot_interp.get(did, {})
			if rec.is_empty():
				rec = {"prev": world, "next": world, "at_ms": now_ms, "interval_s": 0.35}
				_dot_interp[did] = rec
			elif (rec["next"] as Vector2) != world:
				if (rec["next"] as Vector2).distance_to(world) > DOT_SNAP_M:
					rec["prev"] = world   # scrub/catch-up jump: snap, don't glide
				else:
					rec["prev"] = rec["next"]
					var since := float(now_ms - int(rec["at_ms"])) / 1000.0
					rec["interval_s"] = clampf(
							lerpf(float(rec["interval_s"]), since, 0.3), 0.1, 1.0)
				rec["next"] = world
				rec["at_ms"] = now_ms
			var f := clampf(float(now_ms - int(rec["at_ms"]))
					/ (float(rec["interval_s"]) * 1000.0), 0.0, 1.0)
			move_dir = (rec["next"] as Vector2) - (rec["prev"] as Vector2)
			world = (rec["prev"] as Vector2).lerp(rec["next"] as Vector2, f)
		var screen_v: Variant = project(world)
		if screen_v == null:
			continue
		var screen: Vector2 = screen_v
		if screen.x < -20.0 or screen.y < -20.0 or screen.x > c.size.x + 20.0 \
				or screen.y > c.size.y + 20.0:
			continue
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
				var stride := 1
				if s < 1.5:
					stride = maxi(1, int(ceilf(float(n) / 8.0)))
				var prev_v: Variant = project(pts[0])
				var i := stride
				while i < n:
					var cur_v: Variant = project(pts[i])
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
		c.draw_circle(screen, r + 2.0, Color(0.0, 0.0, 0.0, 0.55))
		c.draw_circle(screen, r + 1.4, mood)
		c.draw_circle(screen, r, col)
		var asleep := str(dot.get("activity", "")) == "sleep"
		# Asleep reads as a dimmer dot.
		if asleep:
			c.draw_circle(screen, r * 0.55, Color(0.05, 0.08, 0.16, 0.75))
		# Carrying a crate: a small amber square riding the dot — a working
		# haul line reads as dots with items flowing along it (the payoff
		# image PACKING_PLAN Phase 6 names).
		elif bool(dot.get("carrying", false)):
			var hw := maxf(r * 0.55, 2.0)
			c.draw_rect(Rect2(screen - Vector2(hw, hw), Vector2(hw * 2.0, hw * 2.0)),
					Color(0.95, 0.72, 0.25, 0.95))
		# Heading tick: a short line ahead of a moving dot, in the direction of
		# travel. The interp segment gives the direction for free; it is
		# projected (not drawn in world axes) so it stays honest under an
		# orbited camera.
		if not asleep and move_dir.length_squared() > 0.0025:
			var tip_v: Variant = project(world + move_dir.normalized() * 1.2)
			if tip_v != null:
				var tip_dir: Vector2 = (tip_v as Vector2) - screen
				if tip_dir.length_squared() > 0.01:
					c.draw_line(screen + tip_dir.normalized() * r,
							screen + tip_dir.normalized() * (r + maxf(3.0, r * 0.9)),
							Color(col.r, col.g, col.b, 0.9), 1.6, true)
	# Drop interpolation records for departed/rerolled agents occasionally.
	if now_ms - _dot_sweep_ms > 2000:
		_dot_sweep_ms = now_ms
		for k in _dot_interp.keys():
			if not seen_ids.has(k):
				_dot_interp.erase(k)
