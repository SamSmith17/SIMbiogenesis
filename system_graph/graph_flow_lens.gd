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

## A relayout moves every node, so it is rationed: the picture is laid out
## again at most this often when WHAT flows changed (a wire started or
## stopped), and far less often when only HOW MUCH changed. Between layouts
## the ribbons keep their shape and only their numbers follow.
const TOPO_MIN_S := 4.0
const VALUE_MIN_S := 8.0
const SHAPE_COLUMN := "column"
const SHAPE_TORUS := "torus"
const SHAPES := [["column", "Column"], ["torus", "Torus"]]
const LINK_ALPHA := 0.42
const BG_COLOR := Color(0.035, 0.05, 0.085)
const HEAT_COLOR := Color(0.96, 0.34, 0.20)
const SUN_COLOR := Color(1.0, 0.93, 0.30)
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
var _topo: String = ""
## The layout as the algorithm made it; `cur` is this with the player's
## moved nodes applied (LoopSankeyLayout.apply_pins).
var auto: Dictionary = {}
## "column" (LoopSankeyLayout) or "torus" (ToroidFlowLayout).
var shape: String = SHAPE_COLUMN
## Torus: which lobe is which. The layout fills the left lobe first; with
## this on (the default, the player's call) the lobes are swapped, so the
## first loops sit on the RIGHT of the trunk. "Swap sides" toggles it.
var mirror: bool = true
## Where the player dragged nodes, per shape: {shape: {id: centre}}.
var pins_by_shape: Dictionary = {}
## Per node, for drawing: {id: {kind: "store" | "battery" | "", level, color}}.
var visuals: Dictionary = {}
## Per node, for the card: {id: {value: "AC out 2.5 kW", media: "array" | ""}}.
var info: Dictionary = {}
## How many layouts were computed (for the bench and the checks).
## True while the player drags a node: no new layout until it is let go.
var dragging: bool = false
var layouts_done: int = 0
var _geo_rev: int = 0
var _label_rects: Array = []

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
## Screen paths and ribbon geometry per layout ribbon, kept while the view
## does not move (an animation frame only recolours). Keyed by the layout
## dict's identity, centre, pan and zoom.
var _geo_view: Array = []
var _geo: Dictionary = {}


## Hand the lens this frame's input. Relayouts at most every RELAYOUT_MIN_S,
## and only when the signature (topology + rounded flows + choices) moved.
func set_input(new_sig: String, input: Dictionary) -> void:
	keys_present = input.get("keys", [])
	if input.has("visuals"):
		visuals = input["visuals"]
	if input.has("info"):
		info = input["info"]
	if new_sig == sig and not cur.is_empty():
		_pending = {}
		return
	if not cur.is_empty():
		_refresh_values(input)
	_pending = {"sig": new_sig, "input": input, "topo": str(input.get("topo", new_sig))}
	if cur.is_empty() or (not dragging and _since_layout >= _pending_wait()):
		_apply_pending()


func _pending_wait() -> float:
	if _pending.is_empty():
		return 0.0
	return TOPO_MIN_S if str(_pending["topo"]) != _topo else VALUE_MIN_S


## Between layouts: the ribbons keep their shape, their numbers follow.
func _refresh_values(input: Dictionary) -> void:
	var by_id := {}
	for e in (input.get("edges", []) as Array):
		by_id[str((e as Dictionary).get("id", ""))] = float((e as Dictionary).get("value", 0.0))
	for rb in (cur.get("ribbons", []) as Array):
		var v: Variant = by_id.get(str((rb as Dictionary)["id"]))
		if v != null:
			(rb as Dictionary)["value"] = float(v)


func _apply_pending() -> void:
	if _pending.is_empty():
		return
	var inp: Dictionary = _pending["input"]
	var lay: Dictionary
	if shape == SHAPE_TORUS:
		var topts: Dictionary = (inp.get("opts", {}) as Dictionary).duplicate()
		topts["mirror"] = mirror
		lay = ToroidFlowLayout.layout(inp.get("nodes", []), inp.get("edges", []),
			inp.get("bin", []), inp.get("bout", []), topts)
	else:
		lay = LoopSankeyLayout.layout(inp.get("nodes", []), inp.get("edges", []),
			inp.get("bin", []), inp.get("bout", []), inp.get("opts", {}))
	lay["idle"] = inp.get("idle", [])
	lay["labels"] = inp.get("labels", {})
	lay["types"] = inp.get("types", {})
	layouts_done += 1
	var same_topo := str(_pending["topo"]) == _topo and not cur.is_empty()
	prev = cur
	auto = lay
	cur = LoopSankeyLayout.apply_pins(auto, pins())
	_geo_rev += 1
	# Only a change in WHAT flows cross-fades; new widths just appear.
	fade = 0.0 if (not prev.is_empty() and not same_topo) else 1.0
	if fade >= 1.0:
		prev = {}
	sig = str(_pending["sig"])
	_topo = str(_pending["topo"])
	_pending = {}
	_since_layout = 0.0
	hover_ribbon = -1


## The player asked for another picture (a resource, a window, a wire
## style): lay the next input out at once.
func force_next() -> void:
	_since_layout = 99.0


## Swap the torus's lobes. Nodes the player moved in the torus are put
## back (their places would be on the wrong side).
func set_mirror(on: bool) -> void:
	if on == mirror:
		return
	mirror = on
	pins_by_shape.erase(SHAPE_TORUS)
	sig = ""
	_topo = ""
	_since_layout = 99.0


## Switch between the column and the torus. The next input lays it out.
func set_shape(sh: String) -> void:
	if sh != SHAPE_TORUS:
		sh = SHAPE_COLUMN
	if sh == shape:
		return
	shape = sh
	cur = {}
	prev = {}
	auto = {}
	sig = ""
	_topo = ""
	_pending = {}
	_geo_rev += 1


## The player's moved nodes in the current shape: {id: centre}.
func pins() -> Dictionary:
	return pins_by_shape.get(shape, {}) as Dictionary


## Move one node (graph units). The ribbons follow at once.
func set_pin(id: String, centre: Vector2) -> void:
	if auto.is_empty() or not (auto["nodes"] as Dictionary).has(id):
		return
	if not pins_by_shape.has(shape):
		pins_by_shape[shape] = {}
	(pins_by_shape[shape] as Dictionary)[id] = snap_to_shell(id, centre)
	cur = LoopSankeyLayout.apply_pins(auto, pins())
	_geo_rev += 1


## Move several nodes at once (a multi-selection dragged together).
func set_pins(by_id: Dictionary) -> void:
	if auto.is_empty():
		return
	if not pins_by_shape.has(shape):
		pins_by_shape[shape] = {}
	for id in by_id:
		if (auto["nodes"] as Dictionary).has(id):
			(pins_by_shape[shape] as Dictionary)[id] = snap_to_shell(str(id), by_id[id] as Vector2)
	cur = LoopSankeyLayout.apply_pins(auto, pins())
	_geo_rev += 1


## On the torus a lobe node dragged near its own shell rides the shell (it
## slides round the loop); pulled further than SHELL_SNAP it comes free.
const SHELL_SNAP := 34.0

func snap_to_shell(id: String, centre: Vector2) -> Vector2:
	if str(auto.get("shape", "")) != SHAPE_TORUS:
		return centre
	var nd: Dictionary = auto["nodes"][id]
	if str(nd.get("shape", "")) != "disc":
		return centre
	var near: Array = ToroidFlowLayout.nearest_on_ring(auto, int(nd.get("ring", -1)), centre)
	if float(near[1]) > SHELL_SNAP:
		return centre
	return near[0]


## Put one node back where the layout had it.
func clear_pin(id: String) -> void:
	if not pins().has(id):
		return
	(pins_by_shape[shape] as Dictionary).erase(id)
	if not auto.is_empty():
		cur = LoopSankeyLayout.apply_pins(auto, pins())
		_geo_rev += 1


func clear_pins() -> void:
	pins_by_shape.erase(shape)
	if not auto.is_empty():
		cur = auto
		_geo_rev += 1


## Pins as plain data for the save file, and back.
func pins_to_data() -> Dictionary:
	var out := {}
	for sh in pins_by_shape:
		var d := {}
		for id in (pins_by_shape[sh] as Dictionary):
			var v: Vector2 = (pins_by_shape[sh] as Dictionary)[id]
			d[str(id)] = [v.x, v.y]
		if not d.is_empty():
			out[str(sh)] = d
	return out


func pins_from_data(data: Variant) -> void:
	pins_by_shape = {}
	if not (data is Dictionary):
		return
	for sh in (data as Dictionary):
		var d := {}
		var src: Variant = (data as Dictionary)[sh]
		if not (src is Dictionary):
			continue
		for id in (src as Dictionary):
			var a: Variant = (src as Dictionary)[id]
			if a is Array and (a as Array).size() >= 2:
				d[str(id)] = Vector2(float(a[0]), float(a[1]))
		pins_by_shape[str(sh)] = d
	if not auto.is_empty():
		cur = LoopSankeyLayout.apply_pins(auto, pins())
		_geo_rev += 1


func node_center(id: String) -> Vector2:
	if cur.is_empty() or not (cur["nodes"] as Dictionary).has(id):
		return Vector2.ZERO
	return (cur["nodes"][id]["rect"] as Rect2).get_center()


## Advance the cross-fade and the relayout timer. True while still fading.
func advance(dt: float) -> bool:
	_since_layout += dt
	if not _pending.is_empty() and not dragging and _since_layout >= _pending_wait():
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
	for rb in (cur.get("ribbons", []) as Array):
		if bool((rb as Dictionary).get("sun", false)):
			# Room over the picture for the sun and its words.
			b = b.grow_side(SIDE_TOP, 60.0)
			break
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
	_label_rects.clear()
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
	var look := GraphFlowStyle.look(style)
	var gv := [center, pan, zoom, far, _geo_rev]
	if gv != _geo_view or _geo.size() > 4000:
		_geo_view = gv
		_geo.clear()
	var lay_id := "%s|%d" % [str(lay.get("bounds", Rect2())), rs.size()]
	var b: Rect2 = lay["bounds"]
	var torus := str(lay.get("shape", "")) == SHAPE_TORUS
	if torus:
		_draw_torus_field(cv, lay, center, pan, zoom, o, alpha, live)
	# Sunlight first, as broad bands of light falling on what it reaches.
	if not torus:
		_draw_sun_bands(cv, lay, center, pan, zoom, o, alpha, live)
	# Returns first (behind), then boundary flows, then the main stream.
	var sel_set: Dictionary = o.get("selected_set", {})
	var quiet := hl_loop < 0 and hl_node == "" and sel == "" and sel_set.size() < 2
	for pass_kind in ["link", LoopSankeyLayout.KIND_RETURN, LoopSankeyLayout.KIND_IN,
			LoopSankeyLayout.KIND_OUT, LoopSankeyLayout.KIND_UP, LoopSankeyLayout.KIND_FORWARD]:
		for i in rs.size():
			var rb: Dictionary = rs[i]
			var is_link := bool(rb.get("link", false))
			if pass_kind == "link":
				if not is_link:
					continue
			elif is_link or str(rb["kind"]) != pass_kind:
				continue
			if not torus and bool(rb.get("sun", false)):
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
			elif sel_set.size() > 1:
				lit = sel_set.has(str(rb["a"])) or sel_set.has(str(rb["b"]))
			if not lit:
				a *= 0.16
			elif pass_kind == LoopSankeyLayout.KIND_RETURN and not torus:
				a *= float(style.get("lens_return_alpha", 0.86))
			if is_link and lit and quiet:
				# A link is a quiet line until something points at it.
				a *= LINK_ALPHA
			if live and i == hover_ribbon:
				col = col.lightened(0.25)
			var gk := "%s|%d" % [lay_id, i]
			var cached: Variant = _geo.get(gk)
			if cached == null:
				var sp := PackedVector2Array()
				for p in (rb["path"] as PackedVector2Array):
					sp.append(to_screen(p, center, pan, zoom))
				cached = [sp, GraphFlowRibbons.geometry(sp,
					GraphFlowRibbons.STEP_PX_FAR if far else GraphFlowRibbons.STEP_PX)]
				_geo[gk] = cached
			var path: PackedVector2Array = (cached as Array)[0]
			var w := float(rb["width"]) * zoom
			if bool(style.get("screen_space", false)):
				w = float(rb["width"])
			w = maxf(w, 1.5)
			var v := float(rb["value"])
			var ref := float(refs.get(key, v))
			var col_end := col.lightened(0.15)
			if bool(rb.get("heat", false)):
				# Work done, leaving as heat.
				col_end = HEAT_COLOR
			GraphFlowRibbons.draw(ci, path, {
				"width": w, "color": Color(col, col.a * a),
				"color_end": Color(col_end, col.a * a),
				"look": look, "geo": (cached as Array)[1],
				"heat": clampf(GraphFlowStyle.norm(v, ref, GraphFlowStyle.SCALE_LINEAR), 0.0, 1.0),
				"active": bool(o.get("flowing", true)), "anim": anim, "t": float(o.get("clock", 0.0)),
				"speed": GraphFlowStyle.anim_speed_px(style, v, ref),
				"blur": bool(o.get("blur", false)),
				"glow": float(style.get("glow", 0.6)) * (1.0 if lit and not is_link else 0.0),
				"intensity": clampf(GraphFlowStyle.norm(v, ref, GraphFlowStyle.SCALE_SQRT), 0.3, 1.0),
				"far": far,
			})
			# Boundary labels: where flows come from / go to.
			if torus and live and bool(rb.get("band", false)) and w >= 5.0 and path.size() > 4:
				_band_marks(cv, rb, path, w, col, a)
			var focused := (hl_node != "" and (str(rb["a"]) == hl_node or str(rb["b"]) == hl_node)) \
				or (sel != "" and (str(rb["a"]) == sel or str(rb["b"]) == sel))
			if live and lit and (pass_kind == LoopSankeyLayout.KIND_IN or pass_kind == LoopSankeyLayout.KIND_OUT) \
					and zoom >= 0.45 and path.size() > 1 \
					and (not torus or focused or bool(rb.get("major", false))):
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
	var label_scale := float(o.get("label_scale", 1.0))
	var fs := clampi(int(round(13.0 * clampf(zoom, 0.6, 1.4) * label_scale)), 8, 26)
	var clock := float(o.get("clock", 0.0))
	var lobe_a := float(lay.get("lobe_a", 0.0))
	for id in (lay["nodes"] as Dictionary):
		var nd: Dictionary = lay["nodes"][id]
		var r: Rect2 = nd["rect"]
		var sr := Rect2(to_screen(r.position, center, pan, zoom), r.size * zoom)
		var hot := str(id) == sel or sel_set.has(str(id)) or (live and str(id) == hover_node)
		var dim := (hl_loop >= 0 and int(nd.get("loop", -1)) != hl_loop) \
			or (hl_node != "" and str(id) != hl_node and not _touches(lay, str(id), hl_node))
		var a2 := alpha * (0.35 if dim else 1.0)
		var accent: Color = o["node_color"].call(str(id)) if o.has("node_color") else Color(0.6, 0.7, 0.9)
		var vis: Dictionary = visuals.get(id, {}) as Dictionary
		var name := str(labels.get(id, nd.get("label", id)))
		if str(nd.get("shape", "card")) == "disc":
			var gc := r.get_center()
			var out_dir := gc - Vector2(float(int(nd.get("side", 1))) * lobe_a, 0.0)
			out_dir = out_dir.normalized() if out_dir.length_squared() > 1.0 \
				else Vector2(float(int(nd.get("side", 1))), 0.0)
			_draw_node_disc(cv, sr, nd, vis, accent, a2, alpha, hot, name, zoom, clock, out_dir,
				label_scale, live)
		else:
			_draw_node_card(cv, sr, nd, vis, accent, a2, alpha, hot, name,
				str((lay.get("types", {}) as Dictionary).get(id, "")), fnt, fs, zoom, clock,
				info.get(id, {}) as Dictionary, o, str(id), live)
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
	var sub := "Sources on top, flow runs down; what cycles back returns up the sides. Shift-drag or Shift-click to select, Ctrl+G to group."
	if shape == SHAPE_TORUS:
		title = "Flows · torus"
		sub = "Sunlight comes down the middle and leaves as heat; the work it does keeps the loops on either side turning."
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
		elif shape == SHAPE_TORUS:
			pass
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
	var box_w := minf(maxf(maxf(tw, row_w + 20.0), 520.0) + 24.0, cv.size.x - 24.0)
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
	# The shape: a column or a torus. Then "reset" when nodes were moved.
	cx += 10.0
	var shape_items: Array = SHAPES.duplicate()
	if shape == SHAPE_TORUS:
		shape_items.append(["swap", "Swap sides"])
	if not pins().is_empty():
		shape_items.append(["", "Reset positions"])
	var n_sel := (o.get("selected_set", {}) as Dictionary).size()
	if n_sel >= 2:
		shape_items.append(["group", "Group %d" % n_sel])
	for shi in shape_items:
		var is_reset := str(shi[0]) == ""
		var is_group := str(shi[0]) == "group"
		var on3 := str(shi[0]) == shape
		var tw4 := small.get_string_size(str(shi[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		var r3 := Rect2(Vector2(cx, cy - 2.0), Vector2(tw4 + 16.0, CHIP_H - 6.0))
		if r3.end.x > box.end.x - 6.0:
			break
		var c3: Color = UITheme.C_WARN if is_reset else (UITheme.C_PRIMARY if is_group else Color(0.98, 0.74, 0.26))
		GraphFastDraw.rrect(cv, r3, 6.0, Color(c3, 0.28 if on3 else 0.08))
		cv.draw_rect(r3, Color(c3, 0.85 if on3 else 0.3), false, 1.0)
		cv.draw_string(small, Vector2(r3.position.x + 8.0, r3.position.y + 13.0), str(shi[1]),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.94, 0.96, 0.99) if on3 else Color(0.70, 0.76, 0.84))
		chips.append({"rect": r3, "kind": "reset" if is_reset else ("swap" if str(shi[0]) == "swap"
			else ("group" if is_group else "shape")), "value": str(shi[0])})
		cx += r3.size.x + 6.0
	# A hovered ribbon's words, under the header.
	var hr := ribbon(hover_ribbon)
	if not hr.is_empty():
		var labels: Dictionary = cur.get("labels", {})
		var fmt: Callable = o["fmt"]
		var a_name := str(labels.get(str(hr["a"]), hr["a"])) if str(hr["a"]) != "" else str(hr.get("label", "outside"))
		var b_name := str(labels.get(str(hr["b"]), hr["b"])) if str(hr["b"]) != "" else str(hr.get("label", "outside"))
		var kind_w := {"return": "returns to", "forward": "→", "in": "→", "out": "→", "up": "→"}
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


## A node as a card (the column, and the torus axis). A store is a vessel:
## its level stands in it as liquid with a moving surface; a battery fills
## left to right in cells; a machine glows in its own colour while it works.
## Its picture (the Process lens's model picture, else a pictogram) stands
## on the left, its name and what it is doing now beside it. A solar array
## shows every one of its panels, each lit by what it makes.
func _draw_node_card(cv: Control, sr: Rect2, nd: Dictionary, vis: Dictionary, accent: Color,
		a2: float, alpha: float, hot: bool, name: String, sub: String, fnt: Font, fs: int,
		zoom: float, clock: float, inf: Dictionary = {}, o: Dictionary = {}, id: String = "",
		live: bool = true) -> void:
	var rad := NODE_RADIUS * clampf(zoom, 0.5, 1.4)
	var kind := str(vis.get("kind", ""))
	var active := float(nd.get("through_px", 0.0)) > 0.0
	var is_store := kind == "store" or kind == "battery"
	var col: Color = vis.get("color", accent) if is_store else accent
	if active and zoom >= 0.3:
		GraphFastDraw.rrect(cv, sr.grow(3.0), rad + 3.0, Color(col, 0.10 * a2))
	GraphFastDraw.rrect(cv, sr, rad, Color(0.06, 0.08, 0.13, 0.94 * a2))
	var level := clampf(float(vis.get("level", 0.0)), 0.0, 1.0)
	if is_store:
		var inner := sr.grow(-2.0)
		if kind == "battery":
			if level > 0.004:
				cv.draw_rect(Rect2(inner.position, Vector2(inner.size.x * level, inner.size.y)),
					Color(col, 0.42 * a2))
			if inner.size.x > 40.0:
				for k in range(1, 5):
					var x := inner.position.x + inner.size.x * float(k) / 5.0
					cv.draw_line(Vector2(x, inner.position.y), Vector2(x, inner.end.y),
						Color(0.03, 0.04, 0.08, 0.8 * a2), 1.5)
		else:
			var fh := inner.size.y * level
			var top_y := inner.end.y - fh
			if fh > 0.5:
				cv.draw_rect(Rect2(Vector2(inner.position.x, top_y), Vector2(inner.size.x, fh)),
					Color(col, 0.40 * a2))
				if inner.size.x > 24.0 and level < 0.995:
					var pts := PackedVector2Array()
					var n := clampi(int(inner.size.x / 8.0), 4, 40)
					var amp := minf(1.6, fh * 0.5)
					for k2 in n + 1:
						var x2 := inner.position.x + inner.size.x * float(k2) / float(n)
						pts.append(Vector2(x2, top_y + sin(x2 * 0.11 + clock * 2.2) * amp))
					cv.draw_polyline(pts, Color(col.lightened(0.35), 0.9 * a2), 1.5, true)
		GraphFastDraw.rrect_border(cv, sr, rad, Color(col, 0.78 * a2), 1)
		cv.draw_line(sr.position + Vector2(rad, 3.0), sr.position + Vector2(sr.size.x * 0.4, 3.0),
			Color(1.0, 1.0, 1.0, 0.12 * a2), 1.0)
	else:
		GraphFastDraw.rrect(cv, sr, rad, Color(accent, (0.16 if active else 0.05) * a2))
		cv.draw_rect(Rect2(sr.position + Vector2(rad * 0.5, 0.0),
			Vector2(maxf(sr.size.x - rad, 1.0), maxf(2.0, 3.0 * zoom))), Color(accent, 0.95 * a2))
		GraphFastDraw.rrect_border(cv, sr, rad, Color(accent, 0.42 * a2), 1)
	if hot:
		cv.draw_rect(sr.grow(2.0), Color(UITheme.C_PRIMARY, 0.9 * alpha), false, 2.0)
	if bool(nd.get("pinned", false)) and zoom >= 0.5:
		GraphFastDraw.disc(cv, sr.position + Vector2(sr.size.x - 7.0, 7.0), 2.5, Color(1.0, 1.0, 1.0, 0.55 * a2))
	# The array's panels under a name strip; elsewhere a picture on the left.
	var media := str(inf.get("media", ""))
	var value := str(inf.get("value", ""))
	var body := sr
	var text_x := sr.position.x + 8.0
	if media == "array" and sr.size.y > 24.0:
		var head := minf(sr.size.y * 0.42, 30.0 * zoom)
		var m := clampf(8.0 * zoom, 2.0, 10.0)
		var mz := Rect2(sr.position + Vector2(m, head), Vector2(sr.size.x - m * 2.0, sr.size.y - head - m))
		if mz.size.x > 8.0 and mz.size.y > 6.0:
			GraphFastDraw.rrect(cv, mz.grow(2.0), 3.0, Color(0.02, 0.03, 0.06, 0.92 * a2))
			if live and o.has("draw_media"):
				(o["draw_media"] as Callable).call(id, mz)
		body = Rect2(sr.position, Vector2(sr.size.x, head))
	elif media == "panel" and sr.size.y >= 18.0:
		# A solar module: a dark blue face of cells in an aluminium frame,
		# brighter the more it makes.
		var m3 := clampf(5.0 * zoom, 2.0, 7.0)
		var ph := sr.size.y - m3 * 2.0
		var pbox := Rect2(sr.position + Vector2(m3, m3), Vector2(ph * 0.62, ph))
		var lit := clampf(float(nd.get("through_px", 0.0)) / maxf(sr.size.x * 0.25, 1.0), 0.0, 1.0)
		cv.draw_rect(pbox, Color(0.70, 0.74, 0.78, a2))
		var face := pbox.grow(-maxf(1.0, 1.6 * zoom))
		cv.draw_rect(face, Color(0.05, 0.13, 0.28, a2).lerp(Color(0.16, 0.42, 0.85, a2), lit))
		if face.size.x > 10.0:
			for cx in range(1, 6):
				var x5 := face.position.x + face.size.x * float(cx) / 6.0
				cv.draw_line(Vector2(x5, face.position.y), Vector2(x5, face.end.y), Color(0.75, 0.82, 0.95, 0.35 * a2), 1.0)
			for cy2 in range(1, 10):
				var y5 := face.position.y + face.size.y * float(cy2) / 10.0
				cv.draw_line(Vector2(face.position.x, y5), Vector2(face.end.x, y5), Color(0.75, 0.82, 0.95, 0.35 * a2), 1.0)
		text_x = pbox.end.x + clampf(8.0 * zoom, 4.0, 10.0)
	elif not is_store and o.has("icon_of") and sr.size.y >= 18.0 and zoom >= 0.18:
		var ic: Array = (o["icon_of"] as Callable).call(id)
		if ic.size() >= 2 and ic[0] is Texture2D:
			var tex: Texture2D = ic[0]
			var pic := bool(ic[1])
			var m2 := clampf(5.0 * zoom, 2.0, 7.0)
			var bh := sr.size.y - m2 * 2.0
			var ts := tex.get_size()
			var asp := ts.x / maxf(ts.y, 1.0)
			var bw := clampf(bh * asp, bh * 0.7, bh * 1.9) if pic else bh
			bw = minf(bw, sr.size.x * 0.45)
			var box := Rect2(sr.position + Vector2(m2, m2), Vector2(bw, bh))
			if pic:
				var sc := minf(box.size.x / maxf(ts.x, 1.0), box.size.y / maxf(ts.y, 1.0))
				var dsz := ts * sc
				cv.draw_texture_rect(tex, Rect2(box.position + (box.size - dsz) * 0.5, dsz), false,
					Color(1.0, 1.0, 1.0, a2))
			else:
				GraphFastDraw.rrect(cv, box, 4.0, Color(accent, 0.12 * a2))
				var gs := box.size.y * 0.66
				cv.draw_texture_rect(tex, Rect2(box.get_center() - Vector2(gs, gs) * 0.5, Vector2(gs, gs)), false,
					Color(accent.lightened(0.35), 0.95 * a2))
			text_x = box.end.x + clampf(8.0 * zoom, 4.0, 10.0)
	var room := body.end.x - text_x - 6.0
	var name_w := fnt.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	if (room < 34.0 or body.size.y < 14.0) and zoom >= 0.25:
		# Too narrow (or, zoomed out, too short) for its name: the name sits
		# beside the node instead.
		var at := Vector2(sr.end.x + 6.0, sr.get_center().y)
		var pr := Rect2(at - Vector2(0.0, fs * 0.75), Vector2(name_w + 10.0, fs * 1.5))
		GraphFastDraw.rrect(cv, pr, 5.0, Color(0.03, 0.04, 0.08, 0.78 * a2))
		cv.draw_string(fnt, Vector2(pr.position.x + 5.0, at.y + fs * 0.36), name,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.93, 0.95, 0.98, a2))
		return
	if room < 20.0 or body.size.y < 12.0:
		return
	var txt_c := Color(0.93, 0.95, 0.98, a2)
	var small := UITheme.font("medium", true)
	var sfs := maxi(8, fs - 2)
	var lvl_txt := UiText.pct(level) if is_store else ""
	var lvl_w := small.get_string_size(lvl_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, sfs).x if lvl_txt != "" else 0.0
	var show_lvl := lvl_txt != "" and room > lvl_w + 70.0
	var name_room := room - (lvl_w + 8.0 if show_lvl else 0.0)
	var line2 := value if value != "" else sub
	var two := body.size.y >= float(fs) * 2.5 and line2 != ""
	var cy := body.position.y + body.size.y * 0.5
	var name_y := cy - float(fs) * 0.12 if two else cy + float(fs) * 0.36
	if media == "array" and value != "":
		# One line in the strip: the name, and what the array makes at its right.
		var vw := small.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, sfs).x
		if vw + 60.0 < room:
			cv.draw_string(small, Vector2(body.end.x - vw - 8.0, cy + float(sfs) * 0.36), value,
				HORIZONTAL_ALIGNMENT_LEFT, -1, sfs, Color(accent.lightened(0.5), a2))
			name_room = room - vw - 12.0
		two = false
		name_y = cy + float(fs) * 0.36
	cv.draw_string(fnt, Vector2(text_x, name_y), UiText.fit(fnt, name, fs, name_room, "flow_lens"),
		HORIZONTAL_ALIGNMENT_LEFT, name_room, fs, txt_c)
	if show_lvl:
		cv.draw_string(small, Vector2(body.end.x - lvl_w - 8.0, name_y), lvl_txt,
			HORIZONTAL_ALIGNMENT_LEFT, -1, sfs, Color(col.lightened(0.45), a2))
	if two:
		var vc := Color(accent.lightened(0.45), a2) if value != "" else Color(0.62, 0.68, 0.78, a2)
		cv.draw_string(small, Vector2(text_x, name_y + float(fs) * 1.25),
			UiText.fit(small, line2, sfs, room, "flow_lens"), HORIZONTAL_ALIGNMENT_LEFT, room, sfs, vc)


## Sunlight as broad bands of light falling on what catches it: wider at
## the top like a beam, brightest where it lands, streaks of light running
## down it while the clock runs, and what it brings in words over it.
func _draw_sun_bands(cv: Control, lay: Dictionary, center: Vector2, pan: Vector2, zoom: float,
		o: Dictionary, alpha: float, live: bool) -> void:
	var fmt: Callable = o["fmt"]
	var clock := float(o.get("clock", 0.0))
	var flowing := bool(o.get("flowing", true))
	var nodes: Dictionary = lay["nodes"]
	for rbv in (lay["ribbons"] as Array):
		var rb: Dictionary = rbv
		if not bool(rb.get("sun", false)) or str(rb["kind"]) != LoopSankeyLayout.KIND_IN:
			continue
		var nid := str(rb["b"])
		if not nodes.has(nid):
			continue
		var r: Rect2 = nodes[nid]["rect"]
		var bot_y := r.position.y
		var top_y := bot_y - LoopSankeyLayout.BAND_H * 1.05
		var cx := r.get_center().x
		var half_b := maxf(r.size.x * 0.5 - 4.0, 8.0)
		var half_t := half_b * 1.12 + 6.0
		var tl := to_screen(Vector2(cx - half_t, top_y), center, pan, zoom)
		var tr := to_screen(Vector2(cx + half_t, top_y), center, pan, zoom)
		var br := to_screen(Vector2(cx + half_b, bot_y), center, pan, zoom)
		var bl := to_screen(Vector2(cx - half_b, bot_y), center, pan, zoom)
		var c0 := Color(SUN_COLOR, 0.0)
		var c1 := Color(SUN_COLOR, 0.46 * alpha)
		cv.draw_polygon(PackedVector2Array([tl, tr, br, bl]), PackedColorArray([c0, c0, c1, c1]))
		# A brighter core where the light lands.
		var mid_t := tl.lerp(tr, 0.5)
		var mid_b := bl.lerp(br, 0.5)
		var cw_t := (tr.x - tl.x) * 0.22
		var cw_b := (br.x - bl.x) * 0.36
		var c2 := Color(1.0, 0.98, 0.78, 0.0)
		var c3 := Color(1.0, 0.98, 0.78, 0.30 * alpha)
		cv.draw_polygon(PackedVector2Array([mid_t - Vector2(cw_t, 0.0), mid_t + Vector2(cw_t, 0.0),
			mid_b + Vector2(cw_b, 0.0), mid_b - Vector2(cw_b, 0.0)]), PackedColorArray([c2, c2, c3, c3]))
		# Streaks of light running down the band.
		var n := clampi(int((br.x - bl.x) / 22.0), 3, 22)
		var lw := maxf(1.5, 2.4 * zoom)
		for k in n:
			var u := (float(k) + 0.5) / float(n)
			var ph := fposmod((clock * 0.45 if flowing else 0.35) + float(k) * 0.618, 1.0)
			var p0 := tl.lerp(tr, u).lerp(bl.lerp(br, u), ph)
			var p1 := tl.lerp(tr, u).lerp(bl.lerp(br, u), minf(ph + 0.28, 1.0))
			cv.draw_line(p0, p1, Color(1.0, 0.99, 0.85, 0.55 * alpha * (1.0 - ph * 0.6)), lw, true)
		# A small sun over the band.
		var sc := mid_t + Vector2(0.0, -2.0)
		var sr := clampf(9.0 * zoom, 5.0, 14.0)
		GraphFastDraw.disc(cv, sc, sr * 1.9, Color(SUN_COLOR, 0.16 * alpha))
		GraphFastDraw.disc(cv, sc, sr, Color(SUN_COLOR, 0.95 * alpha))
		for ray in 8:
			var ang := TAU * float(ray) / 8.0 + clock * (0.25 if flowing else 0.0)
			var dv := Vector2(cos(ang), sin(ang))
			cv.draw_line(sc + dv * sr * 1.35, sc + dv * sr * 1.95, Color(SUN_COLOR, 0.85 * alpha), maxf(1.2, 1.6 * zoom), true)
		if live and zoom >= 0.3:
			var key := str(rb["key"])
			_pill(cv, sc + Vector2(0.0, -sr * 2.6), "Sunlight  %s" % str(fmt.call(key, float(rb["value"]))),
				SUN_COLOR, alpha)


## A node on a torus shell. A store is a round vessel with its level in it;
## a machine is a rounded block with a core that beats while it works. The
## name sits on the far side from the lobe's centre.
func _draw_node_disc(cv: Control, sr: Rect2, nd: Dictionary, vis: Dictionary, accent: Color,
		a2: float, alpha: float, hot: bool, name: String, zoom: float, clock: float,
		out_dir: Vector2, label_scale: float, live: bool) -> void:
	var c := sr.get_center()
	var rr := maxf(sr.size.x * 0.5, 2.0)
	var kind := str(vis.get("kind", ""))
	var is_store := kind == "store" or kind == "battery"
	var col: Color = vis.get("color", accent) if is_store else accent
	var active := float(nd.get("through_px", 0.0)) > 0.0
	var level := clampf(float(vis.get("level", 0.0)), 0.0, 1.0)
	if active and rr > 5.0:
		GraphFastDraw.disc(cv, c, rr + 4.0, Color(col, 0.13 * a2))
	if is_store:
		GraphFastDraw.disc(cv, c, rr, Color(0.05, 0.07, 0.12, 0.96 * a2))
		if rr > 4.0:
			GraphCard.fill_circle_level(cv, c, rr - 1.5, level, Color(col, 0.55 * a2))
		GraphFastDraw.ring(cv, c, rr, Color(col, 0.92 * a2), maxf(1.5, 2.0 * zoom))
		if rr >= 15.0:
			var f2 := UITheme.font("semibold", true)
			var t := UiText.pct(level)
			var fs2 := clampi(int(rr * 0.5), 8, 15)
			var tw := f2.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs2).x
			cv.draw_string(f2, c + Vector2(-tw * 0.5, fs2 * 0.36), t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs2,
				Color(0.96, 0.97, 0.99, a2))
		var sf := float(nd.get("store_flow", 0.0))
		if absf(sf) > 0.0 and rr >= 9.0:
			# Filling (up, in its colour) or emptying (down, amber).
			var m := c + Vector2(rr * 0.78, -rr * 0.78)
			var h := clampf(rr * 0.3, 3.5, 7.0)
			var up := sf > 0.0
			var tri := PackedVector2Array([m + Vector2(0.0, -h if up else h), m + Vector2(-h, h if up else -h),
				m + Vector2(h, h if up else -h)])
			cv.draw_colored_polygon(tri, Color(col.lightened(0.3) if up else UITheme.C_WARN, a2))
	else:
		var q := Rect2(c - Vector2(rr, rr) * 0.92, Vector2(rr, rr) * 1.84)
		var qr := rr * 0.42
		GraphFastDraw.rrect(cv, q, qr, Color(0.05, 0.07, 0.12, 0.96 * a2))
		GraphFastDraw.rrect(cv, q, qr, Color(accent, (0.20 if active else 0.06) * a2))
		GraphFastDraw.rrect_border(cv, q, qr, Color(accent, 0.85 * a2), 1)
		var pulse := (0.5 + 0.5 * sin(clock * 3.0 + c.x * 0.013)) if active else 0.0
		GraphFastDraw.disc(cv, c, rr * (0.20 + 0.07 * pulse), Color(accent.lightened(0.3), (0.45 + 0.45 * pulse) * a2))
	if hot:
		GraphFastDraw.ring(cv, c, rr + 3.0, Color(UITheme.C_PRIMARY, 0.95 * alpha), 2.0)
	if bool(nd.get("pinned", false)) and rr >= 10.0:
		GraphFastDraw.disc(cv, c + Vector2(-rr * 0.78, -rr * 0.78), 2.5, Color(1.0, 1.0, 1.0, 0.55 * a2))
	if not live or (zoom < 0.3 and not hot):
		return
	var f := UITheme.font("medium")
	var lfs := clampi(int(round(11.5 * clampf(zoom, 0.75, 1.3) * label_scale)), 8, 20)
	var shown := UiText.fit(f, name, lfs, 170.0 * clampf(zoom, 0.75, 1.3), "flow_lens")
	var ts := f.get_string_size(shown, HORIZONTAL_ALIGNMENT_LEFT, -1, lfs)
	var half := Vector2(ts.x * 0.5 + 5.0, lfs * 0.78)
	var pc := c + out_dir * (rr + 7.0) + Vector2(out_dir.x * half.x, out_dir.y * half.y)
	var pr := Rect2(pc - half, half * 2.0)
	if not hot:
		for other in _label_rects:
			if (other as Rect2).intersects(pr):
				return
	_label_rects.append(pr)
	GraphFastDraw.rrect(cv, pr, 5.0, Color(0.03, 0.04, 0.08, 0.80 * a2))
	cv.draw_string(f, Vector2(pr.position.x + 5.0, pc.y + lfs * 0.36), shown,
		HORIZONTAL_ALIGNMENT_LEFT, -1, lfs, Color(0.93, 0.95, 0.98, a2))


## Behind the torus: the beam down the axis (sunlight in at the top cooling
## to heat at the bottom) and the shells as faint field lines.
func _draw_torus_field(cv: Control, lay: Dictionary, center: Vector2, pan: Vector2, zoom: float,
		o: Dictionary, alpha: float, live: bool) -> void:
	var ax: Dictionary = lay.get("axis", {}) as Dictionary
	if ax.is_empty():
		return
	var top := to_screen(Vector2(0.0, float(ax["y0"])), center, pan, zoom)
	var bot := to_screen(Vector2(0.0, float(ax["y1"])), center, pan, zoom)
	var mid := top.lerp(bot, 0.5)
	var hw := maxf(float(ax["half"]) + 12.0, float(ax.get("width", 0.0)) * 0.5 + 12.0) * zoom
	var c_top := Color(SUN_COLOR, 0.30 * alpha)
	var c_mid := Color(1.0, 0.62, 0.22, 0.20 * alpha)
	var c_bot := Color(HEAT_COLOR, 0.30 * alpha)
	if hw > 1.0 and bot.y - top.y > 4.0:
		cv.draw_polygon(PackedVector2Array([top + Vector2(-hw, 0.0), top + Vector2(hw, 0.0),
			mid + Vector2(hw, 0.0), mid + Vector2(-hw, 0.0)]), PackedColorArray([c_top, c_top, c_mid, c_mid]))
		cv.draw_polygon(PackedVector2Array([mid + Vector2(-hw, 0.0), mid + Vector2(hw, 0.0),
			bot + Vector2(hw, 0.0), bot + Vector2(-hw, 0.0)]), PackedColorArray([c_mid, c_mid, c_bot, c_bot]))
		# An arrow: a notch where the energy comes in, a head where the heat leaves.
		cv.draw_colored_polygon(PackedVector2Array([bot + Vector2(-hw, 0.0), bot + Vector2(hw, 0.0),
			bot + Vector2(0.0, hw * 0.8)]), c_bot)
		cv.draw_colored_polygon(PackedVector2Array([top + Vector2(-hw - 1.0, -1.0), top + Vector2(hw + 1.0, -1.0),
			top + Vector2(0.0, hw * 0.55)]), Color(BG_COLOR, alpha))
	# Every ring as a faint track, so a loop reads as a loop even where
	# nothing is flowing along a stretch of it.
	for g in (lay.get("guides", []) as Array):
		var sp := PackedVector2Array()
		for p in ((g as Dictionary)["path"] as PackedVector2Array):
			sp.append(to_screen(p, center, pan, zoom))
		if sp.size() > 1:
			cv.draw_polyline(sp, Color(0.55, 0.68, 0.92, 0.075 * alpha),
				maxf(1.0, float((g as Dictionary)["width"]) * zoom), true)
	if live and zoom >= 0.28:
		var fmt: Callable = o["fmt"]
		var key := str(ax.get("key", ""))
		var e_in := float(ax.get("energy_in", 0.0))
		var e_out := float(ax.get("heat_out", 0.0))
		if e_in > 0.0:
			_pill(cv, top + Vector2(0.0, -34.0), "Energy in  %s" % str(fmt.call(key, e_in)), SUN_COLOR, alpha)
		if e_out > 0.0:
			_pill(cv, bot + Vector2(0.0, hw * 0.8 + 14.0), "Heat out  %s" % str(fmt.call(key, e_out)),
				HEAT_COLOR.lightened(0.25), alpha)


## What makes a band read as a moving thing: a chevron half way along it,
## an arrow head where a through-flow leaves and a notch where it comes in.
func _band_marks(cv: Control, rb: Dictionary, path: PackedVector2Array, w: float, col: Color, a: float) -> void:
	var n := path.size()
	var m := n / 2
	var dir := (path[mini(m + 1, n - 1)] - path[maxi(m - 1, 0)]).normalized()
	var nrm := Vector2(-dir.y, dir.x)
	var sz := clampf(w * 0.44, 4.0, 15.0)
	var p := path[m]
	cv.draw_polyline(PackedVector2Array([p - dir * sz * 0.45 + nrm * sz, p + dir * sz * 0.55,
		p - dir * sz * 0.45 - nrm * sz]), Color(col.darkened(0.55), 0.9 * a), maxf(1.5, w * 0.13), true)
	if bool(rb.get("arrow", false)):
		var e := path[n - 1]
		var d2 := (e - path[maxi(n - 3, 0)]).normalized()
		var n2 := Vector2(-d2.y, d2.x)
		cv.draw_colored_polygon(PackedVector2Array([e + n2 * w * 0.95, e + d2 * w * 1.15, e - n2 * w * 0.95]),
			Color(col, col.a * a))
	if bool(rb.get("tail", false)):
		var s0 := path[0]
		var d3 := (path[mini(2, n - 1)] - s0).normalized()
		var n3 := Vector2(-d3.y, d3.x)
		cv.draw_colored_polygon(PackedVector2Array([s0 - d3 * 1.0 - n3 * w * 0.62, s0 + d3 * w * 0.5,
			s0 - d3 * 1.0 + n3 * w * 0.62]), Color(BG_COLOR, a))
