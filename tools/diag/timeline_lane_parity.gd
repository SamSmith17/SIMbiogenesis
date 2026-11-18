extends RefCounted

## Sandbox: TimelineWaveformDraw.draw_bins_cached (draw operations kept per
## lane) against a frozen copy of draw_bins as it was before, on the world's
## real lane bins. Every shown waveform lane is drawn both ways into its own
## SubViewport at the timeline's window and the pixels are compared byte for
## byte; the cached side is drawn a second time (the replay) and compared
## again. Then the real timeline's per-lane caches are checked against fresh
## computations (value range, unit-mapped weather bins).
##   tools\harness.ps1 -World walton -RunScript res://tools/diag/timeline_lane_parity.gd -Timeout 900

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("tl-lane-parity %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


# --- draw_bins before the operation cache, word for word ---------------------

static func _old_draw_bins(canvas : Control, rect : Rect2, b : Dictionary, view_t0 : float,
		view_span : float, v_min : float, v_max : float, color : Color) -> void:
	var n := int(b.get("n", 0))
	if n <= 0 or rect.size.x <= 1.0 or rect.size.y <= 1.0 or view_span <= 0.0:
		return
	var w := float(b["w"])
	var i0 := int(b["i0"])
	var mn : PackedFloat32Array = b["mn"]
	var me : PackedFloat32Array = b["mean"]
	var mx : PackedFloat32Array = b["mx"]
	var span := maxf(v_max - v_min, 1e-6)
	var pad := 2.0
	var inner := Rect2(rect.position.x, rect.position.y + pad,
		rect.size.x, maxf(rect.size.y - pad * 2.0, 1.0))
	var px_per_h := inner.size.x / view_span
	var mean_pts := PackedVector2Array()
	var hi_pts := PackedVector2Array()
	var lo_pts := PackedVector2Array()
	for k in n + 1:
		var known := k < n and not is_nan(me[k])
		var x := inner.position.x + ((float(i0 + k) + 0.5) * w - view_t0) * px_per_h
		if known and x >= inner.position.x - px_per_h * w and x <= inner.end.x + px_per_h * w:
			x = clampf(x, inner.position.x, inner.end.x)
			mean_pts.append(Vector2(x, _old_y(me[k], v_min, span, inner)))
			hi_pts.append(Vector2(x, _old_y(mx[k], v_min, span, inner)))
			lo_pts.append(Vector2(x, _old_y(mn[k], v_min, span, inner)))
			continue
		if not known or k == n:
			_old_flush_run(canvas, inner, mean_pts, hi_pts, lo_pts, color, px_per_h * w)
			mean_pts = PackedVector2Array()
			hi_pts = PackedVector2Array()
			lo_pts = PackedVector2Array()


static func _old_y(v : float, v_min : float, span : float, inner : Rect2) -> float:
	return inner.end.y - clampf((v - v_min) / span, 0.0, 1.0) * inner.size.y


static func _old_flush_run(canvas : Control, inner : Rect2, mean_pts : PackedVector2Array,
		hi_pts : PackedVector2Array, lo_pts : PackedVector2Array, color : Color, bin_px : float) -> void:
	var m := mean_pts.size()
	if m == 0:
		return
	if m == 1:
		var half := maxf(bin_px * 0.5, 1.5)
		var p := mean_pts[0]
		canvas.draw_rect(Rect2(p.x - half, hi_pts[0].y, half * 2.0, maxf(lo_pts[0].y - hi_pts[0].y, 1.0)),
			Color(color.r, color.g, color.b, 0.30), true)
		canvas.draw_line(Vector2(p.x - half, p.y), Vector2(p.x + half, p.y), Color(color.r, color.g, color.b, 0.95), 1.5)
		return
	var floor_pts := PackedVector2Array()
	floor_pts.resize(m)
	for i in m:
		floor_pts[i] = Vector2(mean_pts[i].x, inner.end.y)
	_old_strip(canvas, mean_pts, floor_pts, Color(color.r, color.g, color.b, 0.18))
	_old_strip(canvas, hi_pts, lo_pts, Color(color.r, color.g, color.b, 0.32))
	canvas.draw_polyline(mean_pts, Color(color.r, color.g, color.b, 0.95), 1.5, true)


static func _old_strip(canvas : Control, top : PackedVector2Array, bottom : PackedVector2Array, col : Color) -> void:
	var m := top.size()
	if m < 2:
		return
	var pts := PackedVector2Array()
	pts.resize(m * 2)
	for i in m:
		pts[i * 2] = top[i]
		pts[i * 2 + 1] = bottom[i]
	var idx := PackedInt32Array()
	for i in m - 1:
		var a := i * 2
		idx.append_array([a, a + 2, a + 1, a + 1, a + 2, a + 3])
	var cols := PackedColorArray()
	cols.resize(pts.size())
	cols.fill(col)
	RenderingServer.canvas_item_add_triangle_array(canvas.get_canvas_item(), idx, pts, cols)


# --- the comparison ------------------------------------------------------------

func _viewport(main: Node, size: Vector2i) -> Array:
	var vp := SubViewport.new()
	vp.size = size
	vp.transparent_bg = false
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	var c := Control.new()
	c.size = Vector2(size)
	vp.add_child(c)
	main.add_child(vp)
	return [vp, c]


func _grab(tree: SceneTree, vp: SubViewport) -> Image:
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	await tree.process_frame
	await RenderingServer.frame_post_draw
	return vp.get_texture().get_image()


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	for _i in 300:
		await tree.process_frame
	var tl: Node = main.find_child("TimelineUI", true, false)
	if tl == null:
		return {"ok": false, "why": "no TimelineUI"}
	main.set("time_scale", 0.0)
	var t0 := Time.get_ticks_msec()
	while int(tl.call("lane_jobs_pending")) > 0 and Time.get_ticks_msec() - t0 < 60000:
		await tree.process_frame
	for _i in 30:
		await tree.process_frame
	var win: PackedFloat64Array = tl.call("_track_window")
	var cache: Dictionary = tl.get("_waveform_cache")
	var layout: Object = tl.get("_track_layout")
	var lanes: Array = []
	for t in (layout.call("shown_tracks") as Array):
		var td: Object = t
		var b: Dictionary = (cache.get(str(td.get("id")), {}) as Dictionary).get("bins", {})
		if int(b.get("n", 0)) > 0:
			lanes.append([td, b])
	_ok(not lanes.is_empty(), "%d waveform lanes with bins" % lanes.size())
	var size := Vector2i(1280, 40)
	var blank_vp := _viewport(main, size)
	var blank: Image = await _grab(tree, blank_vp[0])
	(blank_vp[0] as Node).queue_free()
	var compared := 0
	for pair in lanes:
		var td: Object = pair[0]
		var b: Dictionary = pair[1]
		var r := TimelineBinning.value_range(b)
		var axis := Vector2(r.x - 0.1 * absf(r.x) - 0.05, r.y + 0.1 * absf(r.y) + 0.05) if not is_nan(r.x) else Vector2(0.0, 1.0)
		var rect := Rect2(0.0, 4.0, float(size.x), 30.0)
		var col: Color = td.get("color")
		var a := _viewport(main, size)
		var n := _viewport(main, size)
		var lane_cache := {}
		(a[1] as Control).draw.connect(func() -> void:
			_old_draw_bins(a[1], rect, b, win[0], win[1], axis.x, axis.y, col))
		(n[1] as Control).draw.connect(func() -> void:
			TimelineWaveformDraw.draw_bins_cached(n[1], rect, b, win[0], win[1], axis.x, axis.y, col, lane_cache))
		var img_a: Image = await _grab(tree, a[0])
		var img_n: Image = await _grab(tree, n[0])
		var first_same := img_a.get_data() == img_n.get_data()
		var ops_before: Variant = lane_cache.get("ops")
		(n[1] as Control).queue_redraw()
		var img_n2: Image = await _grab(tree, n[0])
		var replay_same := img_a.get_data() == img_n2.get_data()
		var replayed := is_same(lane_cache.get("ops"), ops_before)
		var lbl := "%s / %s" % [str(td.get("source")), str(td.get("channel"))]
		_ok(img_a.get_data() != blank.get_data(), "%s: the old code drew something" % lbl)
		_ok(first_same, "%s: first draw pixel-identical to the old code" % lbl)
		_ok(replay_same and replayed, "%s: the replay (cached operations) pixel-identical" % lbl)
		compared += 1
		(a[0] as Node).queue_free()
		(n[0] as Node).queue_free()
	# The real timeline's caches against fresh numbers.
	var draw_cache: Dictionary = tl.get("_lane_draw")
	var checked := 0
	for pair in lanes:
		var td: Object = pair[0]
		var lc: Dictionary = draw_cache.get(str(td.get("id")), {})
		if lc.has("range_src"):
			var fresh := TimelineBinning.value_range(lc["range_src"])
			var kept: Vector2 = lc["range"]
			_ok(var_to_str(fresh) == var_to_str(kept), "%s: kept value range == fresh" % str(td.get("channel")))
			checked += 1
		if lc.has("map_src"):
			var si := str(lc["map_key"][0])
			var imp := bool(lc["map_key"][1])
			var fresh_map := TimelineBinning.mapped(lc["map_src"], func(v : float) -> float:
				return float(TimelineWeatherChannels.display(v, si, imp)["value"]))
			_ok(var_to_str(fresh_map) == var_to_str(lc["map"]), "%s: kept unit-mapped bins == fresh" % str(td.get("channel")))
	print("tl-lane-parity: %d lanes compared, %d ranges checked, window %.1f h" % [compared, checked, win[1]])
	return {"ok": _fails.is_empty(), "failures": _fails}
