class_name HudLayoutCore
extends RefCounted

## The pure half of the HUD layout manager: given the screen, the timeline's
## height, the registered panels and the live claims, where does every panel
## go and in what state. No nodes — tested by hud_layout_selftest.gd.
##
## REGIONS (each a stack that grows away from its corner):
##   top_left      down from the top-left inset corner
##   top_right     down from the top-right inset corner
##   top_center    one centred row along the top inset edge
##   bottom_left   UP from the bottom-left corner, above the timeline
##   center_prompt centred, below screen centre, kept above the timeline
##
## CLAIMS — a tool or mode that takes screen space:
##   {owner, inset: {left, top, right, bottom} (px it occupies along each
##    edge), tuck: ["top_left", …] (tuckable panels there shrink to pills),
##    hide: [...] (panels there are hidden; "*" = every region)}
## Insets from all claims combine by MAX per edge, so a left tool strip and a
## top options bar push every region inward and nothing is drawn under them.
##
## PANELS — {id, region, order (stack order), priority (higher survives an
## overflow longer), size: Vector2 (full), pill: Vector2 (tucked),
## tuckable, visible}. A region that still does not fit after its claim
## tucks its lowest-priority tuckable panels until it does.
##
## Output: {id: {state: "full" | "pill" | "hidden", rect: Rect2}}.

const MARGIN := 12.0
const GAP := 10.0
const REGIONS := ["top_left", "top_right", "top_center", "bottom_left", "center_prompt"]
## How far below screen centre the interaction prompt sits (its old offset).
const PROMPT_DROP := 220.0


static func combined_insets(claims: Array) -> Dictionary:
	var out := {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
	for c in claims:
		var ins: Dictionary = (c as Dictionary).get("inset", {})
		for k in out:
			out[k] = maxf(float(out[k]), float(ins.get(k, 0.0)))
	return out


static func region_flag(claims: Array, key: String, region: String) -> bool:
	for c in claims:
		var arr: Array = (c as Dictionary).get(key, [])
		if region in arr or "*" in arr:
			return true
	return false


## The usable rectangle: screen minus margins, minus the timeline, minus every
## claim's inset.
static func usable_rect(vp: Vector2, timeline_h: float, claims: Array) -> Rect2:
	var ins := combined_insets(claims)
	var x0 := MARGIN + float(ins["left"])
	var y0 := MARGIN + float(ins["top"])
	var x1 := vp.x - MARGIN - float(ins["right"])
	var y1 := vp.y - timeline_h - MARGIN - float(ins["bottom"])
	return Rect2(x0, y0, maxf(x1 - x0, 0.0), maxf(y1 - y0, 0.0))


static func solve(vp: Vector2, timeline_h: float, panels: Array, claims: Array) -> Dictionary:
	var out := {}
	var area := usable_rect(vp, timeline_h, claims)
	var by_region := {}
	for p0 in panels:
		var p: Dictionary = p0
		var id := str(p["id"])
		var region := str(p.get("region", "top_left"))
		if not bool(p.get("visible", true)) or region_flag(claims, "hide", region):
			out[id] = {"state": "hidden", "rect": Rect2()}
			continue
		if not by_region.has(region):
			by_region[region] = []
		var st := "pill" if bool(p.get("tuckable", true)) and region_flag(claims, "tuck", region) else "full"
		(by_region[region] as Array).append({"p": p, "state": st})
	for region in by_region:
		(by_region[region] as Array).sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var oa := int(a["p"].get("order", 0))
			var ob := int(b["p"].get("order", 0))
			return oa < ob if oa != ob else str(a["p"]["id"]) < str(b["p"]["id"]))
	# Columns first: the centre row then fits BETWEEN them.
	for region in ["top_left", "top_right"]:
		if by_region.has(region):
			_column(region, by_region[region], area, out)
	if by_region.has("bottom_left"):
		# Shares the left edge with top_left: it may only use the height left
		# under that column, and tucks its own panels if that is not enough.
		# What it CANNOT tuck (the ride dashboard, toasts) outranks the top
		# column: tuck top-left panels, lowest priority first, until it fits —
		# a fixed-height panel squeezed below its minimum just draws past its
		# slot (onto the timeline).
		var must := 0.0
		var n_must := 0
		for it in by_region["bottom_left"]:
			if not bool(it["p"].get("tuckable", true)) or it["state"] == "pill":
				must += _size_of(it).y
				n_must += 1
		must += GAP * maxf(n_must - 1, 0)
		var floor_y := _column_floor(by_region.get("top_left", []), area, out)
		var guard := 0
		while area.end.y - floor_y < must and guard < 16:
			guard += 1
			var victim := _lowest_full_tuckable(by_region.get("top_left", []))
			if victim.is_empty():
				break
			victim["state"] = "pill"
			_column("top_left", by_region["top_left"], area, out)
			floor_y = _column_floor(by_region["top_left"], area, out)
		var below := Rect2(area.position.x, floor_y, area.size.x, maxf(area.end.y - floor_y, 0.0))
		_column("bottom_left", by_region["bottom_left"], below, out)
	if by_region.has("top_center"):
		var lo := area.position.x
		var hi := area.end.x
		for it in by_region.get("top_left", []):
			var r: Rect2 = out[str(it["p"]["id"])]["rect"]
			lo = maxf(lo, r.end.x + GAP)
		for it in by_region.get("top_right", []):
			var r: Rect2 = out[str(it["p"]["id"])]["rect"]
			hi = minf(hi, r.position.x - GAP)
		var band := Rect2(lo, area.position.y, maxf(hi - lo, 0.0), area.size.y)
		_row(by_region["top_center"], band if band.size.x > 0.0 else area, out)
	if by_region.has("center_prompt"):
		_prompt(by_region["center_prompt"], vp, area, out)
	return out


## The first free y under a column's last panel.
static func _column_floor(items: Array, area: Rect2, out: Dictionary) -> float:
	var floor_y := area.position.y
	for it in items:
		var r: Rect2 = out[str(it["p"]["id"])]["rect"]
		floor_y = maxf(floor_y, r.end.y + GAP)
	return floor_y


static func _lowest_full_tuckable(items: Array) -> Dictionary:
	var victim: Dictionary = {}
	var lowest := INF
	for it in items:
		if it["state"] != "full" or not bool(it["p"].get("tuckable", true)):
			continue
		var pr := float(it["p"].get("priority", 0))
		if pr < lowest:
			lowest = pr
			victim = it
	return victim


static func _size_of(it: Dictionary) -> Vector2:
	var p: Dictionary = it["p"]
	return (p.get("pill", Vector2(140, 30)) if it["state"] == "pill" else p.get("size", Vector2(200, 100))) as Vector2


## A column, tucking the lowest-priority tuckable panels until it fits the
## usable height. A panel that cannot tuck and still does not fit is clamped
## to the space left (the panel scrolls its own content).
static func _column(region: String, items: Array, area: Rect2, out: Dictionary) -> void:
	var total := func() -> float:
		var h := 0.0
		for it in items:
			h += _size_of(it).y
		return h + GAP * maxf(items.size() - 1, 0)
	var guard := 0
	while float(total.call()) > area.size.y and guard < items.size():
		guard += 1
		var victim := -1
		var lowest := INF
		for i in items.size():
			var it: Dictionary = items[i]
			if it["state"] != "full" or not bool(it["p"].get("tuckable", true)):
				continue
			var pr := float(it["p"].get("priority", 0))
			if pr < lowest:
				lowest = pr
				victim = i
		if victim < 0:
			break
		items[victim]["state"] = "pill"
	var up := region == "bottom_left"
	var right := region == "top_right"
	var y := area.end.y if up else area.position.y
	for it in items:
		var s := _size_of(it)
		var room := (y - area.position.y) if up else (area.end.y - y)
		s.y = minf(s.y, maxf(room, 0.0))
		s.x = minf(s.x, area.size.x)
		var x := area.end.x - s.x if right else area.position.x
		var r := Rect2(x, y - s.y if up else y, s.x, s.y)
		out[str(it["p"]["id"])] = {"state": it["state"], "rect": r}
		y = (r.position.y - GAP) if up else (r.end.y + GAP)


## One centred row (hazard / vibe / peak chips). Wider than the space between
## the side columns, it just centres on the usable width.
static func _row(items: Array, area: Rect2, out: Dictionary) -> void:
	var w := 0.0
	for it in items:
		w += _size_of(it).x
	w += GAP * maxf(items.size() - 1, 0)
	var x := area.position.x + maxf((area.size.x - w) * 0.5, 0.0)
	for it in items:
		var s := _size_of(it)
		out[str(it["p"]["id"])] = {"state": it["state"], "rect": Rect2(x, area.position.y, s.x, s.y)}
		x += s.x + GAP


static func _prompt(items: Array, vp: Vector2, area: Rect2, out: Dictionary) -> void:
	var y := vp.y * 0.5 + PROMPT_DROP
	for it in items:
		var s := _size_of(it)
		var yy := minf(y, area.end.y - s.y)
		out[str(it["p"]["id"])] = {"state": it["state"],
			"rect": Rect2((vp.x - s.x) * 0.5, yy, s.x, s.y)}
		y = yy + s.y + GAP
