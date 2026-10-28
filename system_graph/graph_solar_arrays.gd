class_name GraphSolarArrays
extends RefCounted

## Solar arrays on the systems graph — ONE model for both kinds:
##   "array"     an imported / placed / grouped array (add_imported_solar_panels,
##               bind_pv_array_prop, Make array),
##   "pv_design" an MPPT input of a Solar designer array (GraphPvLabArrays).
##
## Outside, an array is one card with a single + / − pair and a picture of
## its real panel layout (`array_cells`). Inside are the real panels, wired
## + to − along each string and the strings joined in parallel at the
## compound's ports, placed where they sit on the rack — so double-clicking
## or zooming in grows the panels out of the picture.
##
## An "array" used to be HOLLOW: one opaque node the sim read through its
## `array_equiv_*` specs, with nothing inside. `materialize` gives it its
## panels (`array_interior` "panels"), or above MATERIALIZE_MAX_PANELS one
## STRING-PROXY panel per string (`array_interior` "strings": a panel item
## whose voc / vmp / wmp are its string's, `panel_count` its panel count), so
## a 2,000-panel solar farm is not 2,000 graph items. A materialized array is
## a transparent compound: the flow, the string Voc checks and the energy sum
## all see its panels.
##
## The layout snapshot (`specs.array_cells`) is in METRES, face-on, north up:
##   {w_m, h_m, cells: [[x, y, w, h, idx, string], ...]}
## x / y from the layout's top-left, idx the panel's index (its child's
## `array_panel` / `pvlab_panel`), string its string (-1 unknown).

const KIND_ARRAY := "array"
const KIND_DESIGN := "pv_design"
const INTERIOR_PANELS := "panels"
const INTERIOR_STRINGS := "strings"
## Above this many panels an array's inside is one node per string.
const MATERIALIZE_MAX_PANELS := 120
## Interior panel nodes: the short side of the smallest one, and the clear gap
## between neighbours (graph px).
const NODE_MIN_SIDE := 150.0
const NODE_GAP := 22.0
## Gap drawn between tables / tracker rows, × module depth (the real row
## pitch for no winter shade is several metres of empty ground).
const ROW_GAP_FRAC := 0.35
## Module size when nothing better is known (SolarArrayBuilder's defaults).
const DEFAULT_MODULE_W_M := 1.05
const DEFAULT_MODULE_H_M := 1.76
const DEFAULT_GAP_M := 0.04
## The card around the picture (graph px at zoom 1; see GraphCard.layout).
const CARD_HEAD_H := 28.0
const CARD_FOOT_H := 24.0
const CARD_PAD := 8.0
const CARD_HERO_H := 74.0
const CARD_MEDIA_GAP := 6.0
const CARD_MEDIA_MIN_W := 200.0
const CARD_MEDIA_MAX_W := 560.0
const CARD_MEDIA_MIN_H := 48.0
const CARD_MEDIA_MAX_H := 300.0
## One colour per string (the miniature's cell edges, the wires inside).
const STRING_COLORS: Array[Color] = [
	Color(0.36, 0.84, 1.0), Color(1.0, 0.72, 0.30), Color(0.62, 0.92, 0.46),
	Color(0.98, 0.50, 0.72), Color(0.74, 0.62, 1.0), Color(0.98, 0.92, 0.42),
]


static func kind(item: Dictionary) -> String:
	return str((item.get("specs", {}) as Dictionary).get("compound_kind", "")) \
		if str(item.get("type", "")) == "compound" else ""


static func is_solar_array(item: Dictionary) -> bool:
	var k := kind(item)
	return k == KIND_ARRAY or k == KIND_DESIGN


static func is_materialized(item: Dictionary) -> bool:
	var k := kind(item)
	if k == KIND_DESIGN:
		return true
	if k != KIND_ARRAY:
		return false
	var mode := str((item.get("specs", {}) as Dictionary).get("array_interior", ""))
	return mode == INTERIOR_PANELS or mode == INTERIOR_STRINGS


## An "array" the sim still reads as one aggregate (array_equiv_*).
static func is_aggregate_array(item: Dictionary) -> bool:
	return kind(item) == KIND_ARRAY and not is_materialized(item)


static func string_color(si: int) -> Color:
	if si < 0:
		return Color(0.42, 0.90, 0.98)
	return STRING_COLORS[si % STRING_COLORS.size()]


## Whether zooming into this compound should open it: a generic super-node
## (as always), or a solar array with something inside.
static func zoom_enterable(model: GraphModel, item: Dictionary) -> bool:
	if model == null or str(item.get("type", "")) != "compound":
		return false
	var cs := str(item.get("child_scope_id", ""))
	if cs.is_empty():
		return false
	var k := kind(item)
	if k == "":
		return true
	if k != KIND_ARRAY and k != KIND_DESIGN:
		return false
	return not model.get_items_in_scope(cs).is_empty()


# ---------------------------------------------------------------------------
# Layout snapshot
# ---------------------------------------------------------------------------

## A snapshot from cell rects in metres (any origin): [{r: Rect2, idx, string}].
static func cells_from_rects(rects: Array) -> Dictionary:
	if rects.is_empty():
		return {}
	var bb := Rect2((rects[0] as Dictionary)["r"])
	for e in rects:
		bb = bb.merge((e as Dictionary)["r"])
	var cells: Array = []
	for e2 in rects:
		var d: Dictionary = e2
		var r: Rect2 = d["r"]
		cells.append([snappedf(r.position.x - bb.position.x, 0.001), snappedf(r.position.y - bb.position.y, 0.001),
			snappedf(r.size.x, 0.001), snappedf(r.size.y, 0.001), int(d.get("idx", cells.size())),
			int(d.get("string", -1))])
	return {"w_m": snappedf(maxf(bb.size.x, 0.01), 0.001), "h_m": snappedf(maxf(bb.size.y, 0.01), 0.001),
		"cells": cells}


## `count` modules on a cols × rows grid, rows marching north (row 0 at the
## bottom, nearest the sun, as PvArrayBuilder), `series` panels per string in
## index order.
static func cells_grid(cols: int, rows: int, count: int, mod_w: float, mod_h: float,
		gap: float = DEFAULT_GAP_M, row_gap: float = -1.0, series: int = 0) -> Dictionary:
	cols = maxi(cols, 1)
	rows = maxi(rows, int(ceil(float(maxi(count, 1)) / float(cols))))
	if row_gap < 0.0:
		row_gap = gap
	var rects: Array = []
	for i in maxi(count, 1):
		var c := i % cols
		var r := i / cols
		var y_up := float(r) * (mod_h + row_gap)
		rects.append({"r": Rect2(float(c) * (mod_w + gap), -(y_up + mod_h), mod_w, mod_h), "idx": i,
			"string": i / series if series > 0 else -1})
	return cells_from_rects(rects)


## The snapshot an "array" compound gets from its own specs: the placed rack's
## cols × rows when it has one (`array_cols`), else series along a row and
## one row per string.
static func cells_for_specs(specs: Dictionary) -> Dictionary:
	var count := maxi(1, int(specs.get("array_panel_units", specs.get("panel_count", specs.get("child_count", 1)))))
	var series := maxi(1, int(specs.get("design_series", 0)))
	if int(specs.get("design_series", 0)) <= 0:
		series = maxi(1, int(specs.get("array_series", count)))
	var mw := float(specs.get("panel_w_m", DEFAULT_MODULE_W_M))
	var mh := float(specs.get("panel_h_m", DEFAULT_MODULE_H_M))
	if mw <= 0.0 or mh <= 0.0:
		mw = DEFAULT_MODULE_W_M
		mh = DEFAULT_MODULE_H_M
	var cols := int(specs.get("array_cols", 0))
	var row_gap := float(specs.get("row_gap_m", DEFAULT_GAP_M))
	if cols <= 0:
		cols = mini(series, count)
		row_gap = DEFAULT_GAP_M * 2.0
	return cells_grid(cols, int(specs.get("array_rows", 0)), count, mw, mh, DEFAULT_GAP_M,
		clampf(row_gap, DEFAULT_GAP_M, mh * ROW_GAP_FRAC), series)


## The snapshot of one MPPT input of a solved Solar designer array: the
## modules of `strings` ([[panel index]]) as they sit on the rack, face-on,
## tables (or tracker rows) drawn a short gap apart.
static func cells_for_design(design: Dictionary, strings: Array) -> Dictionary:
	var lay: Dictionary = design.get("layout", {}) as Dictionary
	if lay.is_empty():
		return {}
	var spec: Dictionary = design.get("spec", {}) as Dictionary
	var a: Dictionary = PvLabArray.resolve_array(spec.get("array", {}) as Dictionary)
	var across := float(lay.get("across_m", DEFAULT_MODULE_W_M))
	var depth := float(lay.get("module_depth_m", DEFAULT_MODULE_H_M))
	var gap := float(a.get("gap_mm", 20.0)) * 0.001
	var stack := maxi(1, int(a.get("stack", 1)))
	var length := depth * float(stack) + gap * float(stack - 1)
	var row_gap := maxf(depth * ROW_GAP_FRAC, gap * 2.0)
	var tracker := str(lay.get("mount", "")) == "tracker"
	var string_of := {}
	for si in strings.size():
		for idx in strings[si] as Array:
			string_of[int(idx)] = si
	var rects: Array = []
	for p in lay.get("panels", []) as Array:
		var pd: Dictionary = p
		var idx := int(pd.get("index", -1))
		if not string_of.has(idx):
			continue
		var t := int(pd.get("table", 0))
		var col := int(pd.get("col", 0))
		var k := int(pd.get("k", 0))
		var r: Rect2
		if tracker:
			# Rows of trackers side by side (x); along each axis by column (y).
			r = Rect2(float(t) * (length + row_gap) + float(k) * (depth + gap),
				float(col) * (across + gap), depth, across)
		else:
			# Tables marching north, each `stack` modules up its slope.
			var y_up := float(t) * (length + row_gap) + float(k) * (depth + gap)
			r = Rect2(float(col) * (across + gap), -(y_up + depth), across, depth)
		rects.append({"r": r, "idx": idx, "string": int(string_of[idx])})
	return cells_from_rects(rects)


## Cells as Rect2 normalised into `zone` (letterboxed, aspect kept):
## [{r: Rect2 screen, idx, string}] plus the fitted grid rect.
static func fit_cells(cells: Dictionary, zone: Rect2) -> Dictionary:
	var w := float(cells.get("w_m", 0.0))
	var h := float(cells.get("h_m", 0.0))
	if w <= 0.0 or h <= 0.0 or zone.size.x <= 1.0 or zone.size.y <= 1.0:
		return {}
	var s := minf(zone.size.x / w, zone.size.y / h)
	var origin := zone.position + (zone.size - Vector2(w, h) * s) * 0.5
	var out: Array = []
	for c in cells.get("cells", []) as Array:
		var a: Array = c
		out.append({"r": Rect2(origin + Vector2(float(a[0]), float(a[1])) * s, Vector2(float(a[2]), float(a[3])) * s),
			"idx": int(a[4]), "string": int(a[5])})
	return {"cells": out, "grid": Rect2(origin, Vector2(w, h) * s), "scale": s}


## The card size that frames `cells` as its picture (graph px at zoom 1).
static func card_size(cells: Dictionary) -> Vector2:
	var w := maxf(float(cells.get("w_m", 1.0)), 0.01)
	var h := maxf(float(cells.get("h_m", 1.0)), 0.01)
	var aspect := w / h
	var mw := clampf(sqrt(aspect) * 170.0, CARD_MEDIA_MIN_W, CARD_MEDIA_MAX_W)
	var mh := mw / aspect
	if mh > CARD_MEDIA_MAX_H:
		mh = CARD_MEDIA_MAX_H
		mw = clampf(mh * aspect, CARD_MEDIA_MIN_W, CARD_MEDIA_MAX_W)
	mh = clampf(mh, CARD_MEDIA_MIN_H, CARD_MEDIA_MAX_H)
	return Vector2(roundf(mw + CARD_PAD * 2.0),
		roundf(CARD_HEAD_H + CARD_MEDIA_GAP + mh + CARD_MEDIA_GAP + CARD_HERO_H + CARD_FOOT_H))


# ---------------------------------------------------------------------------
# Children
# ---------------------------------------------------------------------------

static func child_scope(model: GraphModel, cid: String) -> String:
	return str(model.get_item(cid).get("child_scope_id", ""))


## The panel items inside an array: {idx: item} by their layout index.
static func children_by_index(model: GraphModel, item: Dictionary) -> Dictionary:
	var out := {}
	var cs := str(item.get("child_scope_id", ""))
	if model == null or cs.is_empty():
		return out
	for it in model.get_items_in_scope(cs):
		var d: Dictionary = it
		if str(d.get("type", "")) != "panel":
			continue
		var sp: Dictionary = d.get("specs", {}) as Dictionary
		var idx := int(sp.get("array_panel", sp.get("pvlab_panel", -1)))
		if idx >= 0:
			out[idx] = d
	return out


## Live / peak watts of an array from its panels (a hollow array: its own).
static func live_summary(model: GraphModel, item: Dictionary) -> Dictionary:
	var sp: Dictionary = item.get("specs", {}) as Dictionary
	if not is_materialized(item):
		return {"peak_w": float(sp.get("array_equiv_wmp", 0.0)), "live_w": -1.0,
			"count": int(sp.get("array_panel_units", sp.get("panel_count", 0)))}
	var peak := 0.0
	var live := 0.0
	var seen_live := false
	var count := 0
	var cs := str(item.get("child_scope_id", ""))
	for it in model.get_items_in_scope(cs):
		var d: Dictionary = it
		if str(d.get("type", "")) != "panel":
			continue
		var ps: Dictionary = d.get("specs", {}) as Dictionary
		peak += float(ps.get("wmp", 0.0))
		count += int(ps.get("panel_count", 1))
		if ps.has("current_output_kw"):
			live += float(ps.get("current_output_kw", 0.0)) * 1000.0
			seen_live = true
	return {"peak_w": peak, "live_w": live if seen_live else -1.0, "count": count}


## Interior placement: each cell's node rect in graph px, centred on (0, 0).
## Panel nodes take their cell's shape, the smallest NODE_MIN_SIDE across.
static func interior_rects(cells: Dictionary) -> Dictionary:
	var out := {}
	var list: Array = cells.get("cells", []) as Array
	if list.is_empty():
		return out
	var min_side := INF
	for c in list:
		min_side = minf(min_side, minf(float((c as Array)[2]), float((c as Array)[3])))
	var s := (NODE_MIN_SIDE + NODE_GAP) / maxf(min_side, 0.01)
	var cx := float(cells.get("w_m", 0.0)) * s * 0.5
	var cy := float(cells.get("h_m", 0.0)) * s * 0.5
	for c2 in list:
		var a: Array = c2
		out[int(a[4])] = Rect2(float(a[0]) * s - cx + NODE_GAP * 0.5, float(a[1]) * s - cy + NODE_GAP * 0.5,
			maxf(float(a[2]) * s - NODE_GAP, 40.0), maxf(float(a[3]) * s - NODE_GAP, 40.0))
	return out


## Build an array's inside: one panel per index of `strings` ([[idx]]) placed
## at its cell, wired + to − along each string, the strings joined in parallel
## at the first string's ends, whose + / − the compound's ports lead out of.
## `module` = the specs every panel copies; opts: index_key ("array_panel"),
## string_key ("array_string"), extra (specs merged into each panel),
## name_fn (Callable(si, k, idx) -> String), proxy (bool: each STRING is one
## panel — `module` is then per module and scaled up per string).
## Returns {count, ids: [[id per string position]]}.
static func build_interior(model: GraphModel, cid: String, strings: Array, module: Dictionary,
		cells: Dictionary, opts: Dictionary = {}) -> Dictionary:
	var item := model.get_item(cid)
	var cs := str(item.get("child_scope_id", ""))
	if cs.is_empty():
		cs = "scope_%s" % cid
		model.ensure_scope(cs, str(item.get("scope_id", "root")), cid, str((item.get("specs", {}) as Dictionary).get("name", "Array")))
		model.update_item(cid, {"child_scope_id": cs})
	var index_key := str(opts.get("index_key", "array_panel"))
	var string_key := str(opts.get("string_key", "array_string"))
	var extra: Dictionary = opts.get("extra", {}) as Dictionary
	var name_fn: Callable = opts.get("name_fn", Callable())
	var proxy := bool(opts.get("proxy", false))
	var rects := interior_rects(cells)
	var cell_of := {}
	for c in cells.get("cells", []) as Array:
		cell_of[int((c as Array)[4])] = c
	var rows: Array = []
	var n := 0
	var fallback_y := 0.0
	for si in strings.size():
		var st: Array = strings[si]
		if st.is_empty():
			continue
		var row: Array = []
		var units: Array = [st] if proxy else st.map(func(v: Variant) -> Array: return [v])
		for k in units.size():
			var members: Array = units[k]
			var pid := model.generate_item_id()
			var ps := module.duplicate(true)
			for ek in extra:
				ps[ek] = extra[ek]
			var first_idx := int(members[0])
			ps[index_key] = first_idx
			ps[string_key] = si
			if proxy:
				var m := members.size()
				ps["string_proxy"] = true
				ps["panel_count"] = m
				for vk in ["wmp", "voc", "vmp", "cost"]:
					if ps.has(vk):
						ps[vk] = float(ps[vk]) * float(m)
				ps["proxy_panels"] = members.duplicate()
				ps["name"] = "String %d · %s" % [si + 1, UiText.count(m, "panel")]
			elif name_fn.is_valid():
				ps["name"] = str(name_fn.call(si, k, first_idx))
			else:
				ps["name"] = "S%d·M%d" % [si + 1, k + 1]
			var r: Rect2
			if proxy:
				r = Rect2()
				var have := false
				for mi in members:
					if rects.has(int(mi)):
						r = (rects[int(mi)] as Rect2) if not have else r.merge(rects[int(mi)] as Rect2)
						have = true
				if not have:
					r = Rect2(0.0, fallback_y, 260.0, NODE_MIN_SIDE)
			elif rects.has(first_idx):
				r = rects[first_idx]
			else:
				r = Rect2(float(k) * (NODE_MIN_SIDE + NODE_GAP), fallback_y, NODE_MIN_SIDE, NODE_MIN_SIDE)
			model.add_item({"id": pid, "type": "panel", "x": r.position.x, "y": r.position.y,
				"width": r.size.x, "height": r.size.y, "scope_id": cs, "parent_compound_id": cid,
				"specs": ps, "is_virtual": false})
			# Series: this panel's − to the next one's + (a short hop between
			# neighbours, + on each card's left); the string's + is its first
			# panel's, its − its last panel's.
			if k > 0:
				GraphPvWiring.add_pv_connection(model, "negative", str(row[k - 1]), "negative", pid, "positive", cs)
			row.append(pid)
			n += int(ps.get("panel_count", 1)) if proxy else 1
		fallback_y += NODE_MIN_SIDE + NODE_GAP * 2.0
		rows.append(row)
	if rows.is_empty():
		return {"count": 0, "ids": []}
	var first: Array = rows[0]
	for si2 in range(1, rows.size()):
		var r2: Array = rows[si2]
		GraphPvWiring.add_pv_connection(model, "positive", str(r2[0]), "positive", str(first[0]), "positive", cs)
		GraphPvWiring.add_pv_connection(model, "negative", str(r2[r2.size() - 1]), "negative",
			str(first[first.size() - 1]), "negative", cs)
	var id_map := {"plus": str(first[0]), "minus": str(first[first.size() - 1])}
	GraphComponentDefs._apply_exposed_ports(model, cid, [
		{"handle_id": "positive", "child": "plus", "child_handle": "positive", "direction": "out",
			"polarity": "positive", "label": "PV +"},
		{"handle_id": "negative", "child": "minus", "child_handle": "negative", "direction": "out",
			"polarity": "negative", "label": "PV −"},
	], id_map)
	model.update_item(cid, {"handles": GraphArrayLayout.default_handles()})
	return {"count": n, "ids": rows}


## Put every panel inside an array back where it sits on the rack (its
## cell), sized to its cell; a string proxy covers its string's cells.
## Returns how many panels moved.
static func relayout_children(model: GraphModel, cid: String, cells: Dictionary) -> int:
	var item := model.get_item(cid)
	var rects := interior_rects(cells)
	if item.is_empty() or rects.is_empty():
		return 0
	var moved := 0
	for it in model.get_items_in_scope(str(item.get("child_scope_id", ""))):
		var d: Dictionary = it
		if str(d.get("type", "")) != "panel":
			continue
		var sp: Dictionary = d.get("specs", {}) as Dictionary
		var members: Array = sp.get("proxy_panels", []) as Array
		if members.is_empty():
			members = [int(sp.get("array_panel", sp.get("pvlab_panel", -1)))]
		var r := Rect2()
		var have := false
		for m in members:
			if rects.has(int(m)):
				r = (rects[int(m)] as Rect2) if not have else r.merge(rects[int(m)] as Rect2)
				have = true
		if not have:
			continue
		if Rect2(float(d.get("x", 0.0)), float(d.get("y", 0.0)), float(d.get("width", 0.0)),
				float(d.get("height", 0.0))).is_equal_approx(r):
			continue
		model.update_item(str(d.get("id", "")), {"x": r.position.x, "y": r.position.y,
			"width": r.size.x, "height": r.size.y})
		moved += 1
	return moved


static func clear_interior(model: GraphModel, cid: String) -> void:
	var cs := child_scope(model, cid)
	if cs.is_empty():
		return
	var kill: Array = []
	for it in model.items:
		if str((it as Dictionary).get("scope_id", "")) == cs:
			kill.append(str((it as Dictionary).get("id", "")))
	for k in kill:
		model.remove_item(str(k))
	var kill_c: Array = []
	for c in model.connections:
		if str((c as Dictionary).get("scope_id", "")) == cs:
			kill_c.append(str((c as Dictionary).get("id", "")))
	for kc in kill_c:
		model.remove_connection(str(kc))


## Consecutive strings of `series` over `count` panels (the last one short
## when the count does not divide — what best_series_parallel's ceil means).
static func chunk_strings(count: int, series: int) -> Array:
	var out: Array = []
	series = maxi(series, 1)
	var i := 0
	while i < count:
		var st: Array = []
		for j in mini(series, count - i):
			st.append(i + j)
		out.append(st)
		i += series
	return out


## The per-module panel specs of a hollow "array" compound.
static func module_specs_of(specs: Dictionary) -> Dictionary:
	var count := maxi(1, int(specs.get("array_panel_units", specs.get("panel_count", 1))))
	var m := {
		"wmp": float(specs.get("wmp", SolarArrayBuilder.PANEL_WATTS)),
		"voc": float(specs.get("voc", SolarArrayBuilder.PANEL_VOC)),
		"vmp": float(specs.get("vmp", SolarArrayBuilder.PANEL_VMP)),
		"isc": float(specs.get("isc", SolarArrayBuilder.PANEL_ISC)),
		"imp": float(specs.get("imp", SolarArrayBuilder.PANEL_IMP)),
		"cost": float(specs.get("cost", 0.0)) / float(count),
		"panel_w_m": float(specs.get("panel_w_m", DEFAULT_MODULE_W_M)),
		"panel_h_m": float(specs.get("panel_h_m", DEFAULT_MODULE_H_M)),
	}
	for k in ["voc_temp_coeff_pct", "pmax_temp_coeff_pct", "vmp_temp_coeff_pct", "tilt_deg", "azimuth_deg",
			"mount_style"]:
		if specs.has(k):
			m[k] = specs[k]
	return m


## Give a hollow "array" its panels (or string proxies above the cap). A
## grouped array that already holds panels is adopted as it is. Idempotent:
## an array that is already materialized is left alone. Returns true when it
## changed something.
static func materialize(model: GraphModel, cid: String) -> bool:
	var item := model.get_item(cid)
	if item.is_empty() or kind(item) != KIND_ARRAY or is_materialized(item):
		return false
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	var cs := str(item.get("child_scope_id", ""))
	var existing: Array = []
	if not cs.is_empty():
		for it in model.get_items_in_scope(cs):
			if str((it as Dictionary).get("type", "")) == "panel":
				existing.append(it)
	if not existing.is_empty():
		_adopt_grouped(model, cid, existing)
	else:
		var count := int(specs.get("array_panel_units", specs.get("panel_count", 0)))
		if count <= 0:
			return false
		var series := int(specs.get("design_series", 0))
		if series <= 0:
			series = int(specs.get("array_series", count))
		var strings := chunk_strings(count, series)
		var cells := cells_for_specs(specs)
		var proxy := count > MATERIALIZE_MAX_PANELS
		var extra := {"array_owner": cid}
		_clear_ports_of(model, cid)
		build_interior(model, cid, strings, module_specs_of(specs), cells,
			{"extra": extra, "proxy": proxy})
		specs = (model.get_item(cid).get("specs", {}) as Dictionary).duplicate(true)
		specs["array_interior"] = INTERIOR_STRINGS if proxy else INTERIOR_PANELS
		specs["array_generated"] = true
		specs["array_cells"] = cells
		specs["child_count"] = count
		model.update_item(cid, {"specs": specs})
	_consolidate_outer_handles(model, cid)
	propagate_state(model, cid)
	return true


## Rebuild a generated array's inside from its specs (after a re-tile, a new
## count or a new rack layout). Outside wires survive (they use the
## compound's own + / − ids).
static func rebuild_generated(model: GraphModel, cid: String) -> bool:
	var item := model.get_item(cid)
	if item.is_empty() or kind(item) != KIND_ARRAY:
		return false
	var sp: Dictionary = item.get("specs", {}) as Dictionary
	if is_materialized(item) and not bool(sp.get("array_generated", false)):
		return false
	clear_interior(model, cid)
	var specs: Dictionary = sp.duplicate(true)
	specs.erase("array_interior")
	specs.erase("exposed_ports")
	model.update_item(cid, {"specs": specs})
	return materialize(model, cid)


## Packed / stowed belong to the whole array: its panels carry the flag too,
## so every reader that skips a crated or folded panel skips them.
static func propagate_state(model: GraphModel, cid: String) -> void:
	var item := model.get_item(cid)
	if item.is_empty() or not is_materialized(item):
		return
	var sp: Dictionary = item.get("specs", {}) as Dictionary
	var packed := bool(sp.get("packed_3d", false))
	var stowed := bool(sp.get("array_stowed", false))
	# An imported / placed array's plane belongs to the whole rack: its panels
	# follow the compound's tilt / azimuth (a turned rack turns them all).
	var plane := {}
	if kind(item) == KIND_ARRAY:
		for k in ["tilt_deg", "azimuth_deg", "mount_style"]:
			if sp.has(k):
				plane[k] = sp[k]
	for it in model.get_items_in_scope(str(item.get("child_scope_id", ""))):
		var d: Dictionary = it
		if str(d.get("type", "")) != "panel":
			continue
		var ps: Dictionary = d.get("specs", {}) as Dictionary
		var plane_ok := true
		if ps.has("array_owner"):
			for pk in plane:
				if ps.get(pk) != plane[pk]:
					plane_ok = false
		if plane_ok and bool(ps.get("packed_3d", false)) == packed \
				and bool(ps.get("array_stowed", false)) == stowed:
			continue
		var p2 := ps.duplicate(true)
		if ps.has("array_owner"):
			for pk2 in plane:
				p2[pk2] = plane[pk2]
		if packed:
			p2["packed_3d"] = true
		else:
			p2.erase("packed_3d")
		if stowed:
			p2["array_stowed"] = true
		else:
			p2.erase("array_stowed")
		model.update_item(str(d.get("id", "")), {"specs": p2})


## Children of an array that is packed or stowed make nothing.
static func panel_off(specs: Dictionary) -> bool:
	return bool(specs.get("packed_3d", false)) or bool(specs.get("array_stowed", false))


static func _clear_ports_of(model: GraphModel, cid: String) -> void:
	var sp: Dictionary = (model.get_item(cid).get("specs", {}) as Dictionary).duplicate(true)
	sp.erase("exposed_ports")
	model.update_item(cid, {"specs": sp})


## Old array saves wired the compound through legacy multi-port ids
## (pv_positive_1, …). Once the compound is transparent those must be its own
## "positive" / "negative", or they resolve to nothing; duplicates collapse.
static func _consolidate_outer_handles(model: GraphModel, cid: String) -> void:
	var seen := {}
	var kill: Array = []
	for c in model.connections.duplicate():
		var cd: Dictionary = c
		var patch := {}
		for end in [["source_item_id", "source_handle_id"], ["target_item_id", "target_handle_id"]]:
			if str(cd.get(end[0], "")) != cid:
				continue
			var h := str(cd.get(end[1], ""))
			if h == "positive" or h == "negative":
				continue
			patch[end[1]] = "negative" if h.contains("neg") else "positive"
		var merged := cd.duplicate()
		for pk in patch:
			merged[pk] = patch[pk]
		var key := "%s|%s|%s|%s" % [merged.get("source_item_id", ""), merged.get("source_handle_id", ""),
			merged.get("target_item_id", ""), merged.get("target_handle_id", "")]
		if (str(merged.get("source_item_id", "")) == cid or str(merged.get("target_item_id", "")) == cid) \
				and seen.has(key):
			kill.append(str(cd.get("id", "")))
			continue
		seen[key] = true
		if not patch.is_empty():
			model.update_connection(str(cd.get("id", "")), patch)
	for k in kill:
		model.remove_connection(str(k))


## A "Make array" group already holds real panels, possibly each wired out on
## its own. One + and one − leave the compound; every other panel that left
## through the same port is joined to the first in parallel inside.
static func _adopt_grouped(model: GraphModel, cid: String, panels: Array) -> void:
	var item := model.get_item(cid)
	var sp: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	var cs := str(item.get("child_scope_id", ""))
	var by_handle := {}
	for ep in sp.get("exposed_ports", []) as Array:
		var e: Dictionary = ep
		var hid := "negative" if str(e.get("handle_id", "")).contains("neg") else "positive"
		if not by_handle.has(hid):
			by_handle[hid] = []
		(by_handle[hid] as Array).append(e)
	var keep: Array = []
	for hid in ["positive", "negative"]:
		var list: Array = by_handle.get(hid, []) as Array
		if list.is_empty():
			continue
		var head: Dictionary = (list[0] as Dictionary).duplicate()
		head["handle_id"] = hid
		keep.append(head)
		for i in range(1, list.size()):
			var e2: Dictionary = list[i]
			if str(e2.get("child_item_id", "")) == str(head.get("child_item_id", "")):
				continue
			GraphPvWiring.add_pv_connection(model, hid, str(e2.get("child_item_id", "")), str(e2.get("child_handle_id", hid)),
				str(head.get("child_item_id", "")), str(head.get("child_handle_id", hid)), cs)
	# Order the panels by where they sit (rows top to bottom, then left to
	# right) and find their strings from the links inside.
	panels.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ay := float(a.get("y", 0.0))
		var by := float(b.get("y", 0.0))
		if absf(ay - by) > 20.0:
			return ay < by
		return float(a.get("x", 0.0)) < float(b.get("x", 0.0)))
	var ids: Array = []
	for p in panels:
		ids.append(str((p as Dictionary).get("id", "")))
	var next_of := {}
	for c in model.connections:
		var cd: Dictionary = c
		if str(cd.get("scope_id", "")) != cs:
			continue
		var s := str(cd.get("source_item_id", ""))
		var t := str(cd.get("target_item_id", ""))
		var sh := str(cd.get("source_handle_id", ""))
		var th := str(cd.get("target_handle_id", ""))
		# A series link (one + one −) runs from the earlier panel to the later.
		if (sh == "positive" and th == "negative") or (sh == "negative" and th == "positive"):
			next_of[s] = t
	var chains := PvLabArray.strings_from_links(ids, next_of, {})
	var string_of := {}
	for si in chains.size():
		for k in chains[si] as Array:
			string_of[int(k)] = si
	var rects: Array = []
	for i in panels.size():
		var d: Dictionary = panels[i]
		var ps: Dictionary = (d.get("specs", {}) as Dictionary).duplicate(true)
		ps["array_panel"] = i
		ps["array_owner"] = cid
		ps["array_string"] = int(string_of.get(i, -1))
		model.update_item(str(d.get("id", "")), {"specs": ps})
		# Cells in "metres" from the panels' own graph rects (1 px = 1 cm).
		rects.append({"r": Rect2(float(d.get("x", 0.0)) * 0.01, float(d.get("y", 0.0)) * 0.01,
				float(d.get("width", 210.0)) * 0.01, float(d.get("height", 128.0)) * 0.01),
			"idx": i, "string": int(string_of.get(i, -1))})
	sp = (model.get_item(cid).get("specs", {}) as Dictionary).duplicate(true)
	sp["exposed_ports"] = keep
	sp["array_interior"] = INTERIOR_PANELS
	sp["array_cells"] = cells_from_rects(rects)
	sp["child_count"] = panels.size()
	sp["port_in_count"] = 0
	sp["port_out_count"] = 2
	model.update_item(cid, {"specs": sp, "handles": GraphArrayLayout.default_handles()})
