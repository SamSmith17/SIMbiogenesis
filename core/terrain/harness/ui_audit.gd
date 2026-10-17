class_name UiAudit
extends RefCounted

## Measures what a screenshot only shows: UI that overhangs the screen, is cut
## off by its own panel, collides with another panel or line of text, is too
## small to hit, or reads machine-made. Run on the live tree (the feature tour
## runs it at every hero shot and writes ui_audit.json per stop); pure apart
## from reading node state, so it is cheap to call anywhere.
##
## Findings, each {kind, severity, path, owner, text, rect, other?}:
##   overhang   ERROR  a control's visible rect leaves the viewport
##   clipped    ERROR  a text-bearing control cut off by a clipping ancestor
##                     (a ScrollContainer only counts on an axis it does not
##                     scroll — the graph inspector's values were this)
##   overlap    ERROR  panels from two different HUD owners intersect
##                     (a modal on LAYER_MODAL+ over the HUD is intended)
##   text_overlap ERROR two lines of text collide (ink rects, so a wide label
##                     with short text does not count its empty space)
##   truncated  WARN   text hard-cut by clip_text with no ellipsis
##   tiny       WARN   a visible button under MIN_HIT px
##   raw_text   WARN   "(s)" plurals, snake_case ids, 3+ decimal numbers
##
## Canvas-drawn text (graph canvas, stat decks) is not a Control; draw code
## that fits text calls `note_canvas_truncation(where)` and the counts are
## reported as `canvas_truncated`.

const MIN_HIT := 20.0
const EDGE_TOL := 2.0
## A panel this large is a backdrop / full-screen root, not a HUD panel.
const MAX_PANEL_AREA_FRAC := 0.6
## Layers at or above this are modal: covering the HUD is the point.
const MODAL_LAYER := 50
const IGNORE_LAYERS := ["TourCaptions"]
const CELL := 96.0

static var _canvas_truncations: Dictionary = {}

static var _raw_plural := RegEx.create_from_string("\\w\\(s\\)")
static var _raw_one_days := RegEx.create_from_string("(?<![\\d.])1 (days|hours|people|steps|items|nodes)\\b")
static var _raw_id := RegEx.create_from_string("\\b[a-z]+_[0-9]{6,}(_[0-9]+)?\\b")
static var _raw_decimals := RegEx.create_from_string("\\d\\.\\d{3,}")
## A latitude, longitude pair is legitimately written to 4+ decimals.
static var _coord_pair := RegEx.create_from_string("-?\\d{1,3}\\.\\d{3,}\\s*,\\s*-?\\d{1,3}\\.\\d{3,}")


## Canvas text redraws every frame, so count DISTINCT strings per place, not
## calls (a per-call count read 172 "truncations" off one inspector).
static func note_canvas_truncation(where: String, text: String = "") -> void:
	var seen: Dictionary = _canvas_truncations.get(where, {})
	seen[text] = true
	_canvas_truncations[where] = seen


static func _canvas_truncation_summary() -> Dictionary:
	var out := {}
	for k in _canvas_truncations:
		out[k] = (_canvas_truncations[k] as Dictionary).keys().slice(0, 8)
	return out


static func reset_canvas_truncations() -> void:
	_canvas_truncations.clear()


## Audit everything visible in `vp` (the root viewport). Returns
## {findings: [...], counts: {kind: n}, errors: n, warnings: n, controls: n}.
static func run(vp: Viewport) -> Dictionary:
	var vrect := Rect2(Vector2.ZERO, vp.get_visible_rect().size)
	var findings: Array = []
	var leaves: Array = []    # text-bearing, with ink rects
	var panels: Array = []    # opaque surfaces for owner-vs-owner overlap
	var n := 0
	for node in vp.find_children("*", "Control", true, false):
		var c := node as Control
		if c.get_viewport() != vp or not _shown(c):
			continue
		var layer := _layer_of(c)
		if layer != null and String(layer.name) in IGNORE_LAYERS:
			continue
		var r := _screen_rect(c)
		if r.size.x < 1.0 or r.size.y < 1.0:
			continue
		n += 1
		var vis := _visible_rect(c, r)
		if vis.size.x < 1.0 or vis.size.y < 1.0:
			continue
		var owner := _owner_of(c)
		var info := {"c": c, "r": r, "vis": vis, "owner": owner,
			"layer": layer.layer if layer != null else 0, "modal": _is_modal_layer(layer)}
		# --- overhang: visible part leaves the viewport ---------------------------
		if _is_leaf(c) or _is_surface(c, vrect):
			if vis.position.x < vrect.position.x - EDGE_TOL or vis.position.y < vrect.position.y - EDGE_TOL \
					or vis.end.x > vrect.end.x + EDGE_TOL or vis.end.y > vrect.end.y + EDGE_TOL:
				findings.append(_f("overhang", "error", c, owner, vis))
		if _is_leaf(c):
			var clip := _clipped_by_ancestor(c, r)
			if not clip.is_empty():
				findings.append(_f("clipped", "error", c, owner, r, clip))
			if _hard_truncated(c):
				findings.append(_f("truncated", "warn", c, owner, r))
			var raw := _raw_text_issue(_text_of(c))
			if not raw.is_empty():
				findings.append(_f("raw_text", "warn", c, owner, r, raw))
			var ink := _ink_rect(c, r).intersection(vis)
			if ink.size.x >= 2.0 and ink.size.y >= 2.0:
				info["ink"] = ink
				leaves.append(info)
		if c is BaseButton and not (c is CheckBox or c is CheckButton) \
				and (r.size.x < MIN_HIT or r.size.y < MIN_HIT) and r.size.x * r.size.y > 4.0:
			findings.append(_f("tiny", "warn", c, owner, r))
		if _is_surface(c, vrect):
			panels.append(info)
	findings.append_array(_panel_overlaps(panels))
	findings.append_array(_text_overlaps(leaves))
	var counts := {}
	var errors := 0
	var warnings := 0
	for fd in findings:
		counts[fd["kind"]] = int(counts.get(fd["kind"], 0)) + 1
		if fd["severity"] == "error":
			errors += 1
		else:
			warnings += 1
	if not _canvas_truncations.is_empty():
		var total := 0
		for k in _canvas_truncations:
			total += (_canvas_truncations[k] as Dictionary).size()
		counts["canvas_truncated"] = total
		warnings += total
	return {"findings": findings, "counts": counts, "errors": errors, "warnings": warnings,
		"controls": n, "canvas_truncated": _canvas_truncation_summary(),
		"viewport": [int(vrect.size.x), int(vrect.size.y)]}


## One line for the log: "overlap 3 · clipped 12 · …".
static func summary_line(res: Dictionary) -> String:
	var parts: PackedStringArray = PackedStringArray()
	var counts: Dictionary = res.get("counts", {})
	var keys := counts.keys()
	keys.sort()
	for k in keys:
		parts.append("%s %d" % [k, int(counts[k])])
	var e := int(res.get("errors", 0))
	var w := int(res.get("warnings", 0))
	return "%d %s, %d %s%s" % [e, "error" if e == 1 else "errors", w, "warning" if w == 1 else "warnings",
		(" — " + " · ".join(parts)) if not parts.is_empty() else ""]


# ---------------------------------------------------------------------------
# Visibility / geometry
# ---------------------------------------------------------------------------

static func _shown(c: Control) -> bool:
	if not c.is_visible_in_tree():
		return false
	var a := 1.0
	var n: Node = c
	while n != null:
		if n is CanvasLayer:
			if not (n as CanvasLayer).visible:
				return false
		elif n is CanvasItem:
			a *= (n as CanvasItem).modulate.a * (n as CanvasItem).self_modulate.a if n == c \
				else (n as CanvasItem).modulate.a
		n = n.get_parent()
	return a > 0.05


static func _layer_of(c: Node) -> CanvasLayer:
	var n := c.get_parent()
	while n != null:
		if n is CanvasLayer:
			return n
		n = n.get_parent()
	return null


static func _is_modal_layer(layer: CanvasLayer) -> bool:
	return layer != null and layer.layer >= MODAL_LAYER


## The HUD-level node a control belongs to: the ancestor directly under its
## CanvasLayer (or under a full-screen root Control under it — docks and the
## edit toolbar hang their panels off a screen-filling root).
static func _owner_of(c: Control) -> Node:
	var n: Node = c
	var prev: Node = c
	while n != null and not (n is CanvasLayer) and not (n is Window):
		prev = n
		n = n.get_parent()
	return prev


static func _screen_rect(c: Control) -> Rect2:
	var xf := c.get_global_transform_with_canvas()
	return xf * Rect2(Vector2.ZERO, c.size)


## The part of `r` left after every clipping ancestor.
static func _visible_rect(c: Control, r: Rect2) -> Rect2:
	var out := r
	var n := c.get_parent()
	while n != null and not (n is CanvasLayer) and not (n is Window):
		if n is Control and (n as Control).clip_contents:
			out = out.intersection(_screen_rect(n))
			if out.size.x <= 0.0 or out.size.y <= 0.0:
				return Rect2()
		n = n.get_parent()
	return out


## {by, axis, over} when a clipping ancestor cuts this text-bearing control on
## an axis that ancestor (or a ScrollContainer between) does not scroll.
static func _clipped_by_ancestor(c: Control, r: Rect2) -> Dictionary:
	var scroll_h := false
	var scroll_v := false
	var n := c.get_parent()
	while n != null and not (n is CanvasLayer) and not (n is Window):
		if n is ScrollContainer:
			var sc := n as ScrollContainer
			if sc.horizontal_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED:
				scroll_h = true
			if sc.vertical_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED:
				scroll_v = true
		if n is Control and (n as Control).clip_contents:
			var a := _screen_rect(n)
			var over_x := maxf(a.position.x - r.position.x, r.end.x - a.end.x)
			var over_y := maxf(a.position.y - r.position.y, r.end.y - a.end.y)
			# Fully scrolled out of view is not "cut off".
			if r.intersection(a).size.x <= 0.0 or r.intersection(a).size.y <= 0.0:
				return {}
			if over_x > EDGE_TOL and not scroll_h:
				return {"by": str((n as Node).name), "axis": "x", "over": snappedf(over_x, 0.1)}
			if over_y > EDGE_TOL and not scroll_v:
				return {"by": str((n as Node).name), "axis": "y", "over": snappedf(over_y, 0.1)}
		n = n.get_parent()
	return {}


# ---------------------------------------------------------------------------
# Text
# ---------------------------------------------------------------------------

static func _is_leaf(c: Control) -> bool:
	if c is Label or c is LineEdit or c is OptionButton:
		return not _text_of(c).strip_edges().is_empty() or c is LineEdit
	if c is Button:
		return not (c as Button).text.strip_edges().is_empty()
	if c is SpinBox:
		return true
	return false


static func _text_of(c: Control) -> String:
	if c is Label:
		return (c as Label).text
	if c is Button:
		return (c as Button).text
	if c is LineEdit:
		return (c as LineEdit).text
	if c is SpinBox:
		return (c as SpinBox).get_line_edit().text if (c as SpinBox).get_line_edit() != null else ""
	return ""


static func _font_of(c: Control) -> Array:
	if c is Label and (c as Label).label_settings != null:
		var ls := (c as Label).label_settings
		var f: Font = ls.font if ls.font != null else c.get_theme_font("font")
		return [f, ls.font_size]
	return [c.get_theme_font("font"), c.get_theme_font_size("font_size")]


static func _text_width(c: Control, text: String) -> float:
	var fs := _font_of(c)
	var f := fs[0] as Font
	if f == null:
		return 0.0
	var w := 0.0
	for line in text.split("\n"):
		w = maxf(w, f.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, int(fs[1])).x)
	return w


static func _hard_truncated(c: Control) -> bool:
	if c is Label:
		var l := c as Label
		if l.autowrap_mode != TextServer.AUTOWRAP_OFF or not l.clip_text:
			return false
		if l.text_overrun_behavior != TextServer.OVERRUN_NO_TRIMMING:
			return false
		return _text_width(c, l.text) > c.size.x + 1.0
	if c is Button:
		var b := c as Button
		if not b.clip_text or b.text_overrun_behavior != TextServer.OVERRUN_NO_TRIMMING:
			return false
		var sb := b.get_theme_stylebox("normal")
		var pad := sb.get_minimum_size().x if sb != null else 8.0
		var icon_w := float(b.icon.get_width()) + 4.0 if b.icon != null else 0.0
		return _text_width(c, b.text) + pad + icon_w > c.size.x + 1.0
	return false


## Where the glyphs actually are: a wide Label with short text only "uses"
## the text's width, placed by its alignment.
static func _ink_rect(c: Control, r: Rect2) -> Rect2:
	if c is Label:
		var l := c as Label
		var lines := maxi(l.get_line_count(), 1) if l.autowrap_mode != TextServer.AUTOWRAP_OFF else l.text.count("\n") + 1
		var fs := _font_of(c)
		var f := fs[0] as Font
		var lh := f.get_height(int(fs[1])) if f != null else 14.0
		var w := minf(_text_width(c, l.text), r.size.x) if l.autowrap_mode == TextServer.AUTOWRAP_OFF else r.size.x
		var h := minf(lh * lines, r.size.y)
		var x := r.position.x
		match l.horizontal_alignment:
			HORIZONTAL_ALIGNMENT_CENTER: x += (r.size.x - w) * 0.5
			HORIZONTAL_ALIGNMENT_RIGHT: x += r.size.x - w
		var y := r.position.y
		match l.vertical_alignment:
			VERTICAL_ALIGNMENT_CENTER: y += (r.size.y - h) * 0.5
			VERTICAL_ALIGNMENT_BOTTOM: y += r.size.y - h
		return Rect2(x, y, w, h)
	return r


static func _raw_text_issue(t: String) -> String:
	if t.is_empty():
		return ""
	if _raw_plural.search(t) != null:
		return "\"(s)\" plural"
	if _raw_one_days.search(t) != null:
		return "singular count with a plural noun"
	if _raw_id.search(t) != null:
		return "internal id shown"
	if _raw_decimals.search(_coord_pair.sub(t, "", true)) != null:
		return "3+ decimal places"
	return ""


# ---------------------------------------------------------------------------
# Overlaps (spatial hash so a 2000-control graph screen stays cheap)
# ---------------------------------------------------------------------------

static func _is_surface(c: Control, vrect: Rect2) -> bool:
	var r := _screen_rect(c)
	if r.size.x * r.size.y > vrect.size.x * vrect.size.y * MAX_PANEL_AREA_FRAC:
		return false
	if r.size.x < 24.0 or r.size.y < 16.0:
		return false
	if c is PanelContainer or c is Panel:
		var sb := c.get_theme_stylebox("panel")
		return sb != null and not (sb is StyleBoxEmpty)
	if c is ColorRect:
		return (c as ColorRect).color.a > 0.3
	return false


static func _panel_overlaps(panels: Array) -> Array:
	var out: Array = []
	var seen := {}
	var grid := _bucket(panels, "vis")
	for key in grid:
		var cell: Array = grid[key]
		for i in cell.size():
			for j in range(i + 1, cell.size()):
				var a: Dictionary = panels[cell[i]]
				var b: Dictionary = panels[cell[j]]
				if a["owner"] == b["owner"]:
					continue
				if (a["c"] as Node).is_ancestor_of(b["c"]) or (b["c"] as Node).is_ancestor_of(a["c"]):
					continue
				# A modal layer covering the HUD below it is the point of a modal.
				if int(a["layer"]) != int(b["layer"]) and (bool(a["modal"]) or bool(b["modal"])):
					continue
				var pair := "%d|%d" % [mini(cell[i], cell[j]), maxi(cell[i], cell[j])]
				if seen.has(pair):
					continue
				var ov: Rect2 = (a["vis"] as Rect2).intersection(b["vis"])
				if ov.size.x > 4.0 and ov.size.y > 4.0:
					seen[pair] = true
					var fd := _f("overlap", "error", a["c"], a["owner"], ov)
					fd["other"] = str((b["c"] as Node).get_path())
					fd["other_owner"] = str((b["owner"] as Node).name)
					out.append(fd)
	return out


static func _text_overlaps(leaves: Array) -> Array:
	var out: Array = []
	var seen := {}
	var grid := _bucket(leaves, "ink")
	for key in grid:
		var cell: Array = grid[key]
		for i in cell.size():
			for j in range(i + 1, cell.size()):
				var a: Dictionary = leaves[cell[i]]
				var b: Dictionary = leaves[cell[j]]
				var ca := a["c"] as Node
				var cb := b["c"] as Node
				if ca.is_ancestor_of(cb) or cb.is_ancestor_of(ca):
					continue
				# A SpinBox owns its LineEdit; an OptionButton its popup text.
				if ca.get_parent() == cb or cb.get_parent() == ca:
					continue
				if int(a["layer"]) != int(b["layer"]) and (bool(a["modal"]) or bool(b["modal"])):
					continue
				var pair := "%d|%d" % [mini(cell[i], cell[j]), maxi(cell[i], cell[j])]
				if seen.has(pair):
					continue
				var ra: Rect2 = a["ink"]
				var rb: Rect2 = b["ink"]
				var ov := ra.intersection(rb)
				var small := minf(ra.size.x * ra.size.y, rb.size.x * rb.size.y)
				if ov.size.x > 2.0 and ov.size.y > 2.0 and ov.size.x * ov.size.y > small * 0.15:
					seen[pair] = true
					var fd := _f("text_overlap", "error", a["c"], a["owner"], ov)
					fd["other"] = str(cb.get_path())
					fd["other_text"] = _text_of(b["c"]).left(60)
					out.append(fd)
	return out


static func _bucket(items: Array, key: String) -> Dictionary:
	var grid := {}
	for i in items.size():
		var r: Rect2 = items[i][key]
		var x0 := int(floor(r.position.x / CELL))
		var x1 := int(floor(r.end.x / CELL))
		var y0 := int(floor(r.position.y / CELL))
		var y1 := int(floor(r.end.y / CELL))
		for gx in range(x0, x1 + 1):
			for gy in range(y0, y1 + 1):
				var k := Vector2i(gx, gy)
				if not grid.has(k):
					grid[k] = []
				(grid[k] as Array).append(i)
	return grid


static func _f(kind: String, severity: String, c: Control, owner: Node, r: Rect2, extra: Variant = null) -> Dictionary:
	var fd := {
		"kind": kind, "severity": severity,
		"path": str(c.get_path()), "owner": str(owner.name) if owner != null else "",
		"class": c.get_class(), "text": _text_of(c).left(80),
		"rect": [int(r.position.x), int(r.position.y), int(r.size.x), int(r.size.y)],
	}
	if extra is Dictionary:
		fd.merge(extra)
	elif extra is String and not (extra as String).is_empty():
		fd["why"] = extra
	return fd
