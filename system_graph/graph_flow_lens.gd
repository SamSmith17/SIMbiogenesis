class_name GraphFlowLens
extends RefCounted

## The Flows lens (plans: now-i-want-to-linked-garden): the scope's real
## nodes laid out as a loop-aware Sankey (LoopSankeyLayout). The canvas owns
## the camera, input routing and the flow values; this object owns the
## layout cache, the cross-fade between layouts, drawing, picking and the
## on-canvas chips (which resource, which time window).
##
## Positions are never written to the model: the lens is a way of LOOKING at
## the graph, like the 3D ring view.

const RELAYOUT_MIN_S := 0.9
const FADE_S := 0.45
const NODE_RADIUS := 7.0
const CHIP_H := 24.0
const WINDOWS := [["now", "Now"], ["24h", "24 h"], ["7d", "7 days"]]

## Current layout and the one fading out.
var cur: Dictionary = {}
var prev: Dictionary = {}
var fade: float = 1.0
var sig: String = ""
var _since_layout: float = 99.0
var _pending: Dictionary = {}

## The player's choices (saved with the graph through the canvas).
var channel: String = ""          # "" = every resource; else one scale key
var window: String = "now"

## Hover / selection state (set by the canvas input routing).
var hover_node: String = ""
var hover_ribbon: int = -1
var hover_loop: int = -1

## Chip hit rects (screen) from the last draw: [{rect, kind, value}].
var chips: Array = []
## The header (title, metrics, chips). Off when the picture is embedded in
## a window that has its own controls (LoopSankeyView).
var show_header := true
## Keys present in the last input (for the channel chips).
var keys_present: Array = []


## Hand the lens this frame's input. Relayouts at most every RELAYOUT_MIN_S,
## and only when the signature (topology + rounded flows + choices) moved.
func set_input(new_sig: String, input: Dictionary) -> void:
	keys_present = input.get("keys", [])
	if new_sig == sig and not cur.is_empty():
		return
	_pending = {"sig": new_sig, "input": input}
	if cur.is_empty() or _since_layout >= RELAYOUT_MIN_S:
		_apply_pending()


func _apply_pending() -> void:
	if _pending.is_empty():
		return
	var inp: Dictionary = _pending["input"]
	var lay := LoopSankeyLayout.layout(inp.get("nodes", []), inp.get("edges", []),
		inp.get("bin", []), inp.get("bout", []), inp.get("opts", {}))
	lay["idle"] = inp.get("idle", [])
	lay["labels"] = inp.get("labels", {})
	lay["types"] = inp.get("types", {})
	prev = cur
	cur = lay
	fade = 0.0 if not prev.is_empty() else 1.0
	sig = str(_pending["sig"])
	_pending = {}
	_since_layout = 0.0
	hover_ribbon = -1


## Advance the cross-fade and the relayout timer. True while still fading.
func advance(dt: float) -> bool:
	_since_layout += dt
	if not _pending.is_empty() and _since_layout >= RELAYOUT_MIN_S:
		_apply_pending()
	if fade < 1.0:
		fade = minf(1.0, fade + dt / FADE_S)
		if fade >= 1.0:
			prev = {}
		return true
	return false


func has_layout() -> bool:
	return not cur.is_empty()


## The camera that frames the whole picture in a `view` sized canvas.
func fit(view: Vector2, margin: Vector2 = Vector2(60.0, 110.0), drop: float = 26.0) -> Dictionary:
	if cur.is_empty():
		return {}
	var b: Rect2 = cur["bounds"]
	var avail := (view - margin * 2.0).max(Vector2(50.0, 50.0))
	var z := clampf(minf(avail.x / maxf(b.size.x, 1.0), avail.y / maxf(b.size.y, 1.0)), 0.08, 1.6)
	var c := b.get_center()
	# screen = view/2 + pan + p * z  →  pan puts the bounds' centre mid-view
	# (a little low, under the header).
	return {"zoom": z, "pan": -c * z + Vector2(0.0, drop)}


static func to_screen(p: Vector2, center: Vector2, pan: Vector2, zoom: float) -> Vector2:
	return center + pan + p * zoom


func node_rect(id: String, center: Vector2, pan: Vector2, zoom: float) -> Rect2:
	if cur.is_empty() or not (cur["nodes"] as Dictionary).has(id):
		return Rect2()
	var r: Rect2 = cur["nodes"][id]["rect"]
	return Rect2(to_screen(r.position, center, pan, zoom), r.size * zoom)


func pick_node(pos: Vector2, center: Vector2, pan: Vector2, zoom: float) -> String:
	if cur.is_empty():
		return ""
	for id in (cur["nodes"] as Dictionary):
		if node_rect(str(id), center, pan, zoom).grow(3.0).has_point(pos):
			return str(id)
	return ""


## The ribbon under the pointer (index into cur.ribbons), -1 when none.
func pick_ribbon(pos: Vector2, center: Vector2, pan: Vector2, zoom: float) -> int:
	if cur.is_empty():
		return -1
	var best := -1
	var best_d := INF
	var rs: Array = cur["ribbons"]
	var q := (pos - center - pan) / maxf(zoom, 1e-6)
	for i in rs.size():
		var rb: Dictionary = rs[i]
		var p: PackedVector2Array = rb["path"]
		var half := float(rb["width"]) * 0.5 + 4.0 / maxf(zoom, 1e-6)
		for j in range(1, p.size()):
			var d := _seg_dist(q, p[j - 1], p[j])
			if d < half and d < best_d:
				best_d = d
				best = i
	return best


func ribbon(i: int) -> Dictionary:
	if cur.is_empty() or i < 0 or i >= (cur["ribbons"] as Array).size():
		return {}
	return cur["ribbons"][i]


func pick_chip(pos: Vector2) -> Dictionary:
	for c in chips:
		if (c["rect"] as Rect2).has_point(pos):
			return c
	return {}


## Draw the lens. `o`: style (GraphFlowStyle), clock, flowing, blur,
## selected, font, color_of (Callable key -> Color), fmt (Callable key,
## value -> String), name_of (Callable key -> String).
func draw(cv: Control, center: Vector2, pan: Vector2, zoom: float, o: Dictionary) -> void:
	chips.clear()
	if not prev.is_empty() and fade < 1.0:
		_draw_layout(cv, prev, center, pan, zoom, o, 1.0 - fade, false)
	if not cur.is_empty():
		_draw_layout(cv, cur, center, pan, zoom, o, fade, true)
	if show_header:
		_draw_header(cv, o)


func _draw_layout(cv: Control, lay: Dictionary, center: Vector2, pan: Vector2, zoom: float,
		o: Dictionary, alpha: float, live: bool) -> void:
	if alpha <= 0.01:
		return
	var style: Dictionary = o.get("style", {})
	var color_of: Callable = o["color_of"]
	var fmt: Callable = o["fmt"]
	var ci := cv.get_canvas_item()
	var rs: Array = lay["ribbons"]
	var anim := str(style.get("anim", GraphFlowStyle.ANIM_STREAKS))
	var far := zoom < 0.35
	if far and anim != GraphFlowStyle.ANIM_NONE:
		anim = GraphFlowStyle.ANIM_PULSE
	var refs: Dictionary = lay.get("refs", {})
	var hl_loop := hover_loop if live else -1
	var hl_node := hover_node if live else ""
	var sel := str(o.get("selected", ""))
	# The column guide: a faint spine down the middle of the main stream.
	var b: Rect2 = lay["bounds"]
	# Returns first (behind), then boundary flows, then the main stream.
	for pass_kind in [LoopSankeyLayout.KIND_RETURN, LoopSankeyLayout.KIND_IN,
			LoopSankeyLayout.KIND_OUT, LoopSankeyLayout.KIND_FORWARD]:
		for i in rs.size():
			var rb: Dictionary = rs[i]
			if str(rb["kind"]) != pass_kind:
				continue
			var key := str(rb["key"])
			var col: Color = color_of.call(key)
			var a := alpha
			var lit := true
			if hl_loop >= 0:
				lit = int(rb["loop"]) == hl_loop
			elif hl_node != "":
				lit = str(rb["a"]) == hl_node or str(rb["b"]) == hl_node
			elif sel != "":
				lit = str(rb["a"]) == sel or str(rb["b"]) == sel
			if not lit:
				a *= 0.16
			elif pass_kind == LoopSankeyLayout.KIND_RETURN:
				a *= 0.86
			if live and i == hover_ribbon:
				col = col.lightened(0.25)
			var path := PackedVector2Array()
			for p in (rb["path"] as PackedVector2Array):
				path.append(to_screen(p, center, pan, zoom))
			var w := float(rb["width"]) * zoom
			if bool(style.get("screen_space", false)):
				w = float(rb["width"])
			w = maxf(w, 1.5)
			var v := float(rb["value"])
			var ref := float(refs.get(key, v))
			GraphFlowRibbons.draw(ci, path, {
				"width": w, "color": Color(col, col.a * a),
				"color_end": Color(col.lightened(0.15), col.a * a) if bool(style.get("gradient", true)) else Color(col, col.a * a),
				"active": bool(o.get("flowing", true)), "anim": anim, "t": float(o.get("clock", 0.0)),
				"speed": GraphFlowStyle.anim_speed_px(style, v, ref),
				"blur": bool(o.get("blur", false)),
				"glow": float(style.get("glow", 0.6)) * (1.0 if lit else 0.0),
				"intensity": clampf(GraphFlowStyle.norm(v, ref, GraphFlowStyle.SCALE_SQRT), 0.3, 1.0),
				"far": far,
			})
			# Boundary labels: where flows come from / go to.
			if live and lit and (pass_kind == LoopSankeyLayout.KIND_IN or pass_kind == LoopSankeyLayout.KIND_OUT) \
					and zoom >= 0.45 and path.size() > 1:
				var lab := str(rb.get("label", ""))
				var txt := "%s %s" % [lab, str(fmt.call(key, v))] if lab != "" else str(fmt.call(key, v))
				var at := path[0] if pass_kind == LoopSankeyLayout.KIND_IN else path[path.size() - 1]
				_pill(cv, at + Vector2(0.0, -6.0 if pass_kind == LoopSankeyLayout.KIND_IN else 14.0), txt,
					Color(col, 0.9 * alpha), alpha)
			# Value pills on the wide ribbons (zoomed in).
			elif live and lit and zoom >= 0.75 and w >= 7.0 and path.size() > 2:
				var mid := path[path.size() / 2]
				_pill(cv, mid, str(fmt.call(key, v)), Color(col, 0.9 * alpha), alpha)
	# Nodes.
	var labels: Dictionary = lay.get("labels", {})
	var fnt: Font = o.get("font", UITheme.font("semibold"))
	var fs := clampi(int(round(13.0 * clampf(zoom, 0.6, 1.4))), 9, 18)
	for id in (lay["nodes"] as Dictionary):
		var nd: Dictionary = lay["nodes"][id]
		var r: Rect2 = nd["rect"]
		var sr := Rect2(to_screen(r.position, center, pan, zoom), r.size * zoom)
		var is_sel := str(id) == sel
		var dim := (hl_loop >= 0 and int(nd.get("loop", -1)) != hl_loop) \
			or (hl_node != "" and str(id) != hl_node and not _touches(lay, str(id), hl_node))
		var a2 := alpha * (0.35 if dim else 1.0)
		var accent: Color = o["node_color"].call(str(id)) if o.has("node_color") else Color(0.6, 0.7, 0.9)
		GraphFastDraw.rrect(cv, sr, NODE_RADIUS * clampf(zoom, 0.5, 1.4), Color(0.06, 0.08, 0.13, 0.94 * a2))
		cv.draw_rect(Rect2(sr.position, Vector2(sr.size.x, maxf(2.0, 3.0 * zoom))), Color(accent, 0.95 * a2))
		if is_sel or (live and str(id) == hover_node):
			cv.draw_rect(sr.grow(2.0), Color(UITheme.C_PRIMARY, 0.9 * alpha), false, 2.0)
		else:
			cv.draw_rect(sr, Color(accent, 0.35 * a2), false, 1.0)
		var name := str(labels.get(id, nd.get("label", id)))
		var name_w := fnt.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		if name_w > sr.size.x - 14.0 and zoom >= 0.25:
			# Too narrow for its name: the name sits beside the node instead.
			var at := Vector2(sr.end.x + 6.0, sr.get_center().y)
			var pr := Rect2(at - Vector2(0.0, fs * 0.75), Vector2(name_w + 10.0, fs * 1.5))
			GraphFastDraw.rrect(cv, pr, 5.0, Color(0.03, 0.04, 0.08, 0.78 * a2))
			cv.draw_string(fnt, Vector2(pr.position.x + 5.0, at.y + fs * 0.36), name,
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.93, 0.95, 0.98, a2))
		elif sr.size.y >= 14.0 and sr.size.x >= 30.0:
			var txt_c := Color(0.93, 0.95, 0.98, a2)
			var name_fs := fs
			cv.draw_string(fnt, sr.position + Vector2(8.0, sr.size.y * 0.5 + name_fs * 0.36 - (5.0 * zoom if sr.size.y > 30.0 else 0.0)),
				UiText.fit(fnt, name, name_fs, sr.size.x - 14.0, "flow_lens"),
				HORIZONTAL_ALIGNMENT_LEFT, sr.size.x - 14.0, name_fs, txt_c)
			if sr.size.y > 30.0:
				var sub := str((lay.get("types", {}) as Dictionary).get(id, ""))
				cv.draw_string(UITheme.font("regular"), sr.position + Vector2(8.0, sr.size.y * 0.5 + name_fs * 0.9 + 2.0),
					sub, HORIZONTAL_ALIGNMENT_LEFT, sr.size.x - 14.0, maxi(8, name_fs - 3),
					Color(0.62, 0.68, 0.78, a2))
	# Nodes with nothing flowing, listed under the picture.
	var idle: Array = lay.get("idle", [])
	if live and not idle.is_empty() and zoom >= 0.3:
		var at2 := to_screen(Vector2(b.position.x + 20.0, b.end.y + 30.0), center, pan, zoom)
		var names: Array = []
		for idv in idle.slice(0, 12):
			names.append(str(labels.get(idv, idv)))
		var more := idle.size() - names.size()
		var line := "Nothing flowing: " + ", ".join(names) + (" and %d more" % more if more > 0 else "")
		cv.draw_string(UITheme.font("regular"), at2, line, HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
			Color(0.62, 0.68, 0.78, 0.8 * alpha))


static func _touches(lay: Dictionary, a: String, b: String) -> bool:
	for rb in (lay["ribbons"] as Array):
		if (str(rb["a"]) == a and str(rb["b"]) == b) or (str(rb["a"]) == b and str(rb["b"]) == a):
			return true
	return false


func _pill(cv: Control, at: Vector2, txt: String, col: Color, alpha: float) -> void:
	var f := UITheme.font("medium", true)
	var fs := 11
	var ts := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var r := Rect2(at - Vector2(ts.x * 0.5 + 5.0, ts.y * 0.5 + 2.0), ts + Vector2(10.0, 4.0))
	GraphFastDraw.rrect(cv, r, 5.0, Color(0.03, 0.04, 0.08, 0.82 * alpha))
	cv.draw_string(f, Vector2(r.position.x + 5.0, r.position.y + ts.y * 0.82), txt,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(col.r, col.g, col.b, alpha))


## The header: per resource how much cycles (Finn's index) and how many
## loops, then the resource chips and the time window chips.
func _draw_header(cv: Control, o: Dictionary) -> void:
	var fnt := UITheme.font("semibold")
	var small := UITheme.font("medium", true)
	var name_of: Callable = o["name_of"]
	var color_of: Callable = o["color_of"]
	var x := 12.0
	var y := 12.0
	# Title + metrics line.
	var title := "Flows"
	var sub := "Sources on top, flow runs down; what cycles back returns up the sides."
	if not cur.is_empty():
		var parts: Array = []
		var m: Dictionary = cur.get("metrics", {})
		var ks: Array = m.keys()
		ks.sort()
		for k in ks:
			if channel != "" and str(k) != channel:
				continue
			var mm: Dictionary = m[k]
			var loops := int(mm.get("loops", 0))
			if loops <= 0 and float(mm.get("fci", 0.0)) < 0.005:
				continue
			parts.append("%s %d %% cycled%s" % [str(name_of.call(str(k))), int(round(float(mm.get("fci", 0.0)) * 100.0)),
				(" · %s" % UiText.count(loops, "loop")) if loops > 0 else ""])
		if not parts.is_empty():
			sub = "  ·  ".join(parts.slice(0, 5))
		elif not (cur.get("nodes", {}) as Dictionary).is_empty():
			sub = "Nothing cycles back in this window: the flows run one way." + (" Try 24 h or 7 days." if window == "now" else "")
	var tw := maxf(fnt.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x,
		small.get_string_size(sub, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x)
	# Chips row width.
	var chip_items: Array = [["", "All"]]
	for k in keys_present:
		chip_items.append([str(k), str(name_of.call(str(k)))])
	var row_w := 0.0
	for ci in chip_items:
		row_w += small.get_string_size(str(ci[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x + 22.0
	var box_w := minf(maxf(tw, row_w + 20.0) + 24.0, cv.size.x - 24.0)
	var box := Rect2(Vector2(x, y), Vector2(box_w, 96.0))
	GraphFastDraw.rrect(cv, box, 9.0, Color(0.04, 0.06, 0.10, 0.86))
	cv.draw_string(fnt, Vector2(x + 12.0, y + 22.0), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 15,
		Color(0.94, 0.96, 0.99))
	cv.draw_string(small, Vector2(x + 12.0, y + 41.0), sub, HORIZONTAL_ALIGNMENT_LEFT, box_w - 24.0, 12,
		Color(0.70, 0.76, 0.84))
	var cx := x + 12.0
	var cy := y + 52.0
	for ci in chip_items:
		var on := str(ci[0]) == channel
		var tw2 := small.get_string_size(str(ci[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		var r := Rect2(Vector2(cx, cy), Vector2(tw2 + 16.0, CHIP_H - 4.0))
		if r.end.x > box.end.x - 6.0:
			break
		var col: Color = color_of.call(str(ci[0])) if str(ci[0]) != "" else UITheme.C_PRIMARY
		GraphFastDraw.rrect(cv, r, 6.0, Color(col, 0.30 if on else 0.10))
		cv.draw_rect(r, Color(col, 0.9 if on else 0.35), false, 1.0)
		cv.draw_string(small, Vector2(r.position.x + 8.0, r.position.y + 14.5), str(ci[1]),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.94, 0.96, 0.99) if on else Color(0.74, 0.80, 0.88))
		chips.append({"rect": r, "kind": "channel", "value": str(ci[0])})
		cx += r.size.x + 6.0
	# Window chips on their own line.
	cx = x + 12.0
	cy += CHIP_H
	for wi in WINDOWS:
		var on2 := str(wi[0]) == window
		var tw3 := small.get_string_size(str(wi[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		var r2 := Rect2(Vector2(cx, cy - 2.0), Vector2(tw3 + 16.0, CHIP_H - 6.0))
		GraphFastDraw.rrect(cv, r2, 6.0, Color(UITheme.C_PRIMARY, 0.28 if on2 else 0.08))
		cv.draw_string(small, Vector2(r2.position.x + 8.0, r2.position.y + 13.0), str(wi[1]),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.94, 0.96, 0.99) if on2 else Color(0.70, 0.76, 0.84))
		chips.append({"rect": r2, "kind": "window", "value": str(wi[0])})
		cx += r2.size.x + 6.0
	# A hovered ribbon's words, under the header.
	var hr := ribbon(hover_ribbon)
	if not hr.is_empty():
		var labels: Dictionary = cur.get("labels", {})
		var fmt: Callable = o["fmt"]
		var a_name := str(labels.get(str(hr["a"]), hr["a"])) if str(hr["a"]) != "" else str(hr.get("label", "outside"))
		var b_name := str(labels.get(str(hr["b"]), hr["b"])) if str(hr["b"]) != "" else str(hr.get("label", "outside"))
		var kind_w := {"return": "returns to", "forward": "→", "in": "→", "out": "→"}
		var line := "%s %s %s · %s %s" % [a_name, str(kind_w.get(str(hr["kind"]), "→")), b_name,
			str(fmt.call(str(hr["key"]), float(hr["value"]))), str(name_of.call(str(hr["key"])))]
		if int(hr["loop"]) >= 0:
			line += " · part of a loop"
		var lw := small.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		var lr := Rect2(Vector2(x, box.end.y + 6.0), Vector2(lw + 20.0, 24.0))
		GraphFastDraw.rrect(cv, lr, 7.0, Color(0.04, 0.06, 0.10, 0.9))
		cv.draw_string(small, lr.position + Vector2(10.0, 16.0), line, HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
			Color(color_of.call(str(hr["key"])), 1.0))


static func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 1e-9:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)
