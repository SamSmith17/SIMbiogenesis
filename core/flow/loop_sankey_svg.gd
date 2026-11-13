class_name LoopSankeySvg
extends RefCounted

## A LoopSankeyLayout picture as an SVG file (plans/FLOW_VIZ_PLAN.md Part C):
## the same layout the graph's Flows lens draws, on the dark graph theme, so
## a simkit year or any run can be looked at, shared or printed outside the
## game. Pure: text in, text out.
##
##   svg := LoopSankeySvg.render(layout, {title, subtitle, color_of: Callable,
##          fmt: Callable, name_of: Callable})
##
## Forward ribbons are solid, returns lighter and dashed-free but translucent,
## boundary ribbons fade to the edge; each node is a bar with its name, and
## every ribbon carries a <title> with its value for a hover in a browser.

const MARGIN := 40.0
const HEAD_H := 64.0
const BG := "#0b0f16"
const NODE_FILL := "#1a2130"
const NODE_EDGE := "#5b6b86"
const TEXT := "#e6ecf5"
const TEXT_S := "#94a3b8"


static func render(lay: Dictionary, o: Dictionary = {}) -> String:
	var b: Rect2 = lay.get("bounds", Rect2()) as Rect2
	var nodes: Dictionary = lay.get("nodes", {})
	var ribbons: Array = lay.get("ribbons", [])
	var color_of: Callable = o.get("color_of", Callable())
	var fmt: Callable = o.get("fmt", Callable())
	var name_of: Callable = o.get("name_of", Callable())
	# Room for labels beside narrow nodes and boundary captions.
	var extra_r := 180.0
	var w := b.size.x + MARGIN * 2.0 + extra_r
	var h := b.size.y + MARGIN * 2.0 + HEAD_H
	var off := Vector2(MARGIN, MARGIN + HEAD_H) - b.position
	var out := PackedStringArray()
	out.append('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" font-family="Inter, Segoe UI, sans-serif">' % [
		int(ceil(w)), int(ceil(h)), int(ceil(w)), int(ceil(h))])
	out.append('<rect width="100%%" height="100%%" fill="%s"/>' % BG)
	out.append('<text x="%d" y="%d" font-size="20" font-weight="600" fill="%s">%s</text>' % [
		int(MARGIN), int(MARGIN + 6.0), TEXT, esc(str(o.get("title", "Flows")))])
	var sub := str(o.get("subtitle", ""))
	if sub != "":
		out.append('<text x="%d" y="%d" font-size="13" fill="%s">%s</text>' % [
			int(MARGIN), int(MARGIN + 28.0), TEXT_S, esc(sub)])
	# A legend: one swatch per resource, biggest first.
	var tot := {}
	for r0 in ribbons:
		var k0 := str(r0.get("key", ""))
		tot[k0] = float(tot.get(k0, 0.0)) + float(r0.get("value", 0.0))
	var keys: Array = tot.keys()
	keys.sort_custom(func(a, b2) -> bool: return float(tot[a]) > float(tot[b2]))
	var lx := MARGIN
	for k1 in keys:
		var c1: Color = color_of.call(str(k1)) if color_of.is_valid() else Color(0.55, 0.75, 1.0)
		var nm := str(name_of.call(str(k1))) if name_of.is_valid() else str(k1)
		out.append('<rect x="%.1f" y="%.1f" width="18" height="6" rx="2" fill="#%s"/>' % [lx, MARGIN + 38.0, c1.to_html(false)])
		out.append('<text x="%.1f" y="%.1f" font-size="12" fill="%s">%s</text>' % [lx + 24.0, MARGIN + 45.0, TEXT_S, esc(nm)])
		lx += 24.0 + nm.length() * 7.0 + 18.0
	# Returns first (under), then boundaries, then the forward stream.
	var order := {"return": 0, "in": 1, "out": 1, "forward": 2}
	var rs := ribbons.duplicate()
	rs.sort_custom(func(x, y) -> bool:
		return int(order.get(str(x.get("kind", "")), 2)) < int(order.get(str(y.get("kind", "")), 2)))
	for r in rs:
		var path: PackedVector2Array = r.get("path", PackedVector2Array())
		if path.size() < 2:
			continue
		var key := str(r.get("key", ""))
		var col: Color = color_of.call(key) if color_of.is_valid() else Color(0.55, 0.75, 1.0)
		var kind := str(r.get("kind", "forward"))
		var alpha := 0.9
		if kind == "return":
			alpha = 0.62
		elif kind == "in" or kind == "out":
			alpha = 0.5
		var pts := PackedStringArray()
		for p in path:
			var q := p + off
			pts.append("%.1f,%.1f" % [q.x, q.y])
		var tip := "%s: %s" % [str(name_of.call(key)) if name_of.is_valid() else key,
			str(fmt.call(key, float(r.get("value", 0.0)))) if fmt.is_valid() else "%.3g" % float(r.get("value", 0.0))]
		if str(r.get("label", "")) != "":
			tip = str(r["label"]) + " · " + tip
		out.append('<polyline points="%s" fill="none" stroke="#%s" stroke-opacity="%.2f" stroke-width="%.1f" stroke-linejoin="round"><title>%s</title></polyline>' % [
			" ".join(pts), col.to_html(false), alpha, maxf(float(r.get("width", 1.0)), 1.0), esc(tip)])
		if (kind == "in" or kind == "out") and str(r.get("label", "")) != "":
			var end := (path[0] if kind == "in" else path[path.size() - 1]) + off
			var ty := end.y - 6.0 if kind == "in" else end.y + 16.0
			out.append('<text x="%.1f" y="%.1f" font-size="12" text-anchor="middle" fill="#%s">%s</text>' % [
				end.x, ty, col.lightened(0.25).to_html(false), esc(str(r["label"]))])
	for id in nodes:
		var n: Dictionary = nodes[id]
		var rect: Rect2 = n.get("rect", Rect2()) as Rect2
		var rr := Rect2(rect.position + off, rect.size)
		out.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="5" fill="%s" stroke="%s"/>' % [
			rr.position.x, rr.position.y, rr.size.x, rr.size.y, NODE_FILL, NODE_EDGE])
		var label := str(n.get("label", id))
		if rr.size.x >= label.length() * 7.0 + 16.0:
			out.append('<text x="%.1f" y="%.1f" font-size="12" fill="%s">%s</text>' % [
				rr.position.x + 8.0, rr.position.y + rr.size.y * 0.5 + 4.0, TEXT, esc(label)])
		else:
			out.append('<text x="%.1f" y="%.1f" font-size="12" fill="%s">%s</text>' % [
				rr.end.x + 6.0, rr.position.y + rr.size.y * 0.5 + 4.0, TEXT, esc(label)])
	out.append("</svg>")
	return "\n".join(out)


static func esc(s: String) -> String:
	return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
