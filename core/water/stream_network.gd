class_name StreamNetwork
extends RefCounted

## Resolves every flowing line on a map — OSM waterways (with the player's
## overrides applied) and the player's own streams — into ONE list of
## features, each oriented DOWNSTREAM, with a cross-section and span modes.
## Pure static; the WaterNetwork node owns the instance data.
##
## Feature dict:
##   id        "osm:<way id>" | "ws_<n>"
##   source    "osm" | "user" | "derived"
##   osm_id    int (OSM only, else -1)
##   kind      river | stream | canal | ditch | drain
##   name      display name
##   points    PackedVector2Array, world XZ, downstream order
##   modes     Array of "surface" | "culvert" | "pipe", one per span
##   section   {bed_w, depth, bank_slope, max_cut}
##   carve     bool — carve a channel along surface spans
##   base_lps  authored base flow (L/s)
##   covered   true when a riverbank polygon draws this reach's surface
##   overridden true when the player edited an OSM way
##   smooth / meander  the effective StreamCurve knobs (the feature's own, else
##             the map's `curve_smooth` / `curve_meander`); curve_own = true
##             when this feature carries its own
##   ctrl_points / ctrl_modes  the WAYPOINTS and their span modes: what the
##             editor shows and edits. `points` / `modes` are the centreline
##             StreamCurve made from them (identical when both knobs are 0)
##   ctrl_seg  PackedInt32Array: per `points` span, its waypoint span
##   ctrl_vtx  PackedInt32Array: per waypoint, its index in `points`

## Default cross-sections per kind. bed_w/depth are typical small-channel
## proportions (width:depth ~ 3–12 for natural streams — Leopold & Maddock
## 1953 hydraulic geometry); bank_slope is horizontal:vertical, 2–3 being
## the stable range for cohesive banks (USDA NRCS NEH 654 ch. 8) — and a bank
## gentler than ~2:1 spans enough 1.5 m edit cells to render smooth. They are
## starting points the player tunes per map and per stream.
## The bed is sized for BANKFULL flow, so base flow occupies only part of it
## (as in a real channel) — which also keeps the water's own smooth edge over
## a flat bed instead of meeting banks rasterised on the 1.5 m edit grid.
const KIND_SECTIONS := {
	"river":  {"bed_w": 14.0, "depth": 1.8, "bank_slope": 3.0, "max_cut": 8.0},
	"stream": {"bed_w": 3.5, "depth": 0.7, "bank_slope": 2.5, "max_cut": 5.0},
	"canal":  {"bed_w": 6.0, "depth": 1.5, "bank_slope": 2.0, "max_cut": 6.0},
	"ditch":  {"bed_w": 1.8, "depth": 0.5, "bank_slope": 2.0, "max_cut": 3.0},
	"drain":  {"bed_w": 1.5, "depth": 0.4, "bank_slope": 2.0, "max_cut": 3.0},
}
## Authored base (dry-weather) flow per kind, L/s — NOT physics: an order-of-
## magnitude starting point the player overrides per stream. With the derived
## catchment the rain term dominates anyway.
const KIND_BASE_LPS := {
	"river": 2000.0, "stream": 25.0, "canal": 300.0, "ditch": 3.0, "drain": 1.0,
}
const KINDS := ["stream", "river", "canal", "ditch", "drain"]
## Endpoint of one feature within this of another feature's line = it drains
## into that feature (a continuation or a tributary).
const JOIN_TOL_M := 6.0


static func kind_section(kind: String, settings: Dictionary = {}) -> Dictionary:
	var base: Dictionary = (KIND_SECTIONS.get(kind, KIND_SECTIONS["stream"]) as Dictionary).duplicate()
	var over: Variant = (settings.get("kind_sections", {}) as Dictionary).get(kind, {}) \
		if settings.get("kind_sections") is Dictionary else {}
	if over is Dictionary:
		for k in (over as Dictionary).keys():
			base[k] = float((over as Dictionary)[k])
	return base


## Section for one feature: kind default, the OSM width tag (bed width tracks
## the mapped width — a ~40 m river is not a 12 m one), then the per-feature
## override, which always wins.
static func section_for(kind: String, settings: Dictionary, osm_half_w: float,
		override_section: Dictionary) -> Dictionary:
	var sec := kind_section(kind, settings)
	if osm_half_w > 0.0:
		# The OSM ribbon is the water surface at normal flow; the bed is
		# narrower by the bank slope over the depth on each side.
		sec["bed_w"] = maxf(2.0 * osm_half_w - 2.0 * float(sec["bank_slope"]) * float(sec["depth"]),
			0.5 * float(KIND_SECTIONS.get(kind, KIND_SECTIONS["stream"])["bed_w"]))
	for k in override_section.keys():
		sec[k] = float(override_section[k])
	return sec


## Build the resolved feature list.
## `osm_water` = TerrainLoader `_water_data` OSM items (only those carrying a
## `centerline` are lines); `layer` may be null.
static func resolve(osm_water: Array, layer: WaterFeatureLayer) -> Array:
	var settings: Dictionary = layer.settings if layer != null else {}
	# "Dry between storms": a stream with no base flow of its own runs only
	# when rain reaches it (a desert wash), instead of the kind's default.
	var dry := bool(settings.get("dry_between_storms", false))
	var out: Array = []
	for item_v in osm_water:
		if not (item_v is Dictionary):
			continue
		var item: Dictionary = item_v
		if bool(item.get("user", false)):
			continue
		var cl: Variant = item.get("centerline", null)
		if not (cl is PackedVector2Array) or (cl as PackedVector2Array).size() < 2:
			continue
		var osm_id := int(item.get("osm_id", -1))
		var ov: Dictionary = layer.osm_override(osm_id) if layer != null and osm_id >= 0 else {}
		if bool(ov.get("hidden", false)):
			continue
		var kind := str(item.get("kind", "stream"))
		if not (kind in KIND_SECTIONS):
			kind = "stream"
		var pts: PackedVector2Array = ov.get("points", cl)
		var n_spans := pts.size() - 1
		var default_mode := "culvert" if bool(item.get("culvert", false)) else "surface"
		var modes: Array = ov.get("modes", []) if ov.has("modes") else []
		if modes.size() != n_spans:
			modes = []
			for _i in n_spans:
				modes.append(default_mode)
		var tags: Dictionary = item.get("tags", {})
		# Only a MAPPED width sizes the bed. The parser falls back to a render
		# default (a 10 m "stream") when OSM carries no width, and carving that
		# turned every brook into a 7 m trench with a 2 cm sheet of water in it.
		var mapped_half_w := float(item.get("half_width", 0.0)) \
			if (tags.has("width") or tags.has("waterway:width")) else 0.0
		var sec := section_for(kind, settings, mapped_half_w,
			ov.get("section", {}) if ov.get("section") is Dictionary else {})
		out.append({
			"id": "osm:%d" % osm_id if osm_id >= 0 else "osm:anon%d" % out.size(),
			"source": "osm",
			"osm_id": osm_id,
			"kind": kind,
			"name": str(ov.get("name", tags.get("name", kind.capitalize()))),
			"points": pts,
			"modes": modes,
			"section": sec,
			"carve": bool(ov.get("carve", true)),
			"base_lps": float(ov.get("base_lps", 0.0 if dry else KIND_BASE_LPS.get(kind, 25.0))),
			"covered": bool(item.get("covered", false)),
			"overridden": not ov.is_empty(),
			"own_smooth": float(ov.get("smooth", -1.0)),
			"own_meander": float(ov.get("meander", -1.0)),
			"erosion": layer.erosion_of("osm:%d" % osm_id) if layer != null else PackedFloat32Array(),
		})
	if layer != null:
		for s_v in layer.streams:
			var s: Dictionary = s_v
			var pts2: PackedVector2Array = s.get("points", PackedVector2Array())
			if pts2.size() < 2:
				continue
			var kind2 := str(s.get("kind", "stream"))
			if not (kind2 in KIND_SECTIONS):
				kind2 = "stream"
			var base_lps := float(s.get("base_lps", -1.0))
			out.append({
				"id": str(s.get("id", "")),
				"source": str(s.get("source", "user")),
				"osm_id": -1,
				"kind": kind2,
				"name": str(s.get("name", "Stream")),
				"points": pts2,
				"modes": WaterFeatureLayer._fit_modes(s.get("modes", []), pts2.size()),
				"section": section_for(kind2, settings, 0.0,
					s.get("section", {}) if s.get("section") is Dictionary else {}),
				"carve": bool(s.get("carve", true)),
				"base_lps": base_lps if base_lps >= 0.0 else (0.0 if dry else float(KIND_BASE_LPS.get(kind2, 25.0))),
				"covered": false,
				"overridden": false,
				"own_smooth": float(s.get("smooth", -1.0)),
				"own_meander": float(s.get("meander", -1.0)),
				"erosion": layer.erosion_of(str(s.get("id", ""))),
			})
	apply_curves(out, settings)
	return out


## Map-wide curve defaults (`settings` = the layer's settings).
static func curve_defaults(settings: Dictionary) -> Vector2:
	return Vector2(clampf(float(settings.get("curve_smooth", 0.0)), 0.0, 1.0),
		clampf(float(settings.get("curve_meander", 0.0)), 0.0, 1.0))


## Turn every feature's waypoints into its centreline (StreamCurve). Drainage
## links are found on the WAYPOINT lines (what the map / the player drew), the
## confluences are pinned on the channel they join so the meander passes
## through them, and each tributary's end is then snapped onto the curved
## channel it drains into, so drainage_links on the curved lines still finds
## every join.
static func apply_curves(features: Array, settings: Dictionary) -> void:
	var by_id := {}
	for f in features:
		by_id[(f as Dictionary)["id"]] = f
	var links := drainage_links(features)
	var pins := {}
	for id in links.keys():
		var into := str((links[id] as Dictionary)["into"])
		var tp: PackedVector2Array = (by_id[id] as Dictionary)["points"]
		if not pins.has(into):
			pins[into] = PackedVector2Array()
		var arr: PackedVector2Array = pins[into]
		arr.append(tp[tp.size() - 1])
		pins[into] = arr
	for f in features:
		curve_feature(f, settings, pins.get((f as Dictionary)["id"], PackedVector2Array()))
	for id in links.keys():
		var f: Dictionary = by_id[id]
		var g: Dictionary = by_id.get(str((links[id] as Dictionary)["into"]), {})
		if g.is_empty() or StreamCurve.is_identity(float(g["smooth"]), float(g["meander"])):
			continue
		var pts: PackedVector2Array = f["points"]
		var hit := nearest_on_line(g["points"], pts[pts.size() - 1])
		if float(hit["dist"]) <= 0.05:
			continue
		pts.append(hit["point"])
		f["points"] = pts
		var seg: PackedInt32Array = f["ctrl_seg"]
		seg.append(seg[seg.size() - 1] if seg.size() > 0 else 0)
		f["ctrl_seg"] = seg
		var modes: Array = f["modes"]
		modes.append(modes.back() if not modes.is_empty() else "surface")
		var vtx: PackedInt32Array = f["ctrl_vtx"]
		vtx[vtx.size() - 1] = pts.size() - 1
		f["ctrl_vtx"] = vtx


## (Re)build one feature's centreline from its waypoints. Before the first
## call `points` / `modes` ARE the waypoints; after it they live in
## ctrl_points / ctrl_modes. `pins` = confluences on this channel.
static func curve_feature(f: Dictionary, settings: Dictionary,
		pins: PackedVector2Array = PackedVector2Array()) -> void:
	if not f.has("ctrl_points"):
		f["ctrl_points"] = f["points"]
		f["ctrl_modes"] = f["modes"]
	var ctrl: PackedVector2Array = f["ctrl_points"]
	var cmodes: Array = WaterFeatureLayer._fit_modes(f["ctrl_modes"], ctrl.size())
	f["ctrl_modes"] = cmodes
	var defaults := curve_defaults(settings)
	var own_s := float(f.get("own_smooth", -1.0))
	var own_m := float(f.get("own_meander", -1.0))
	var smooth := clampf(own_s, 0.0, 1.0) if own_s >= 0.0 else defaults.x
	var meander := clampf(own_m, 0.0, 1.0) if own_m >= 0.0 else defaults.y
	f["smooth"] = smooth
	f["meander"] = meander
	f["curve_own"] = own_s >= 0.0 or own_m >= 0.0
	# Culverts, pipes and penstocks run straight (no meander across them).
	var flat: Array = []
	var run_start := -1
	for i in cmodes.size() + 1:
		var straight := i < cmodes.size() and str(cmodes[i]) != "surface"
		if straight and run_start < 0:
			run_start = i
		elif not straight and run_start >= 0:
			flat.append(Vector2i(run_start, i))
			run_start = -1
	var sec: Dictionary = f.get("section", {})
	var top_w := float(sec.get("bed_w", 2.0)) \
		+ 2.0 * float(sec.get("bank_slope", 2.0)) * float(sec.get("depth", 0.7))
	var r := StreamCurve.curve(ctrl, smooth, meander, StreamCurve.wavelength_for_width(top_w),
		hash(str(f.get("id", ""))), pins, flat)
	var seg: PackedInt32Array = r["seg"]
	var modes: Array = []
	for i in seg.size():
		modes.append(cmodes[clampi(seg[i], 0, cmodes.size() - 1)] if not cmodes.is_empty() else "surface")
	f["points"] = r["points"]
	f["modes"] = modes
	f["ctrl_seg"] = seg
	f["ctrl_vtx"] = r["vtx"]


## The waypoint span a centreline span belongs to.
static func ctrl_span_of(f: Dictionary, seg: int) -> int:
	var cs: Variant = f.get("ctrl_seg", null)
	if cs is PackedInt32Array and seg >= 0 and seg < (cs as PackedInt32Array).size():
		return (cs as PackedInt32Array)[seg]
	return seg


## The centreline between waypoints a and b (inclusive).
static func centreline_between(f: Dictionary, a: int, b: int) -> PackedVector2Array:
	var pts: PackedVector2Array = f.get("points", PackedVector2Array())
	var vtx: Variant = f.get("ctrl_vtx", null)
	if not (vtx is PackedInt32Array) or (vtx as PackedInt32Array).size() <= maxi(a, b):
		var ctrl: PackedVector2Array = f.get("ctrl_points", pts)
		return ctrl.slice(a, b + 1)
	var v: PackedInt32Array = vtx
	return pts.slice(v[a], v[b] + 1)


## For each feature, which feature its downstream END drains into and at what
## arc length on that feature: {id -> {"into": id, "at_s": float}}. A feature
## draining into nothing (an outlet, the map edge, a lake) is absent. The
## nearest line within JOIN_TOL_M wins; a feature never drains into itself.
static func drainage_links(features: Array) -> Dictionary:
	var links := {}
	for f_v in features:
		var f: Dictionary = f_v
		var pts: PackedVector2Array = f["points"]
		var end := pts[pts.size() - 1]
		var best_d := JOIN_TOL_M
		var best := {}
		for g_v in features:
			var g: Dictionary = g_v
			if g["id"] == f["id"]:
				continue
			var hit := nearest_on_line(g["points"], end)
			var d := float(hit["dist"])
			if d < best_d:
				best_d = d
				best = {"into": g["id"], "at_s": float(hit["s"])}
		if not best.is_empty():
			links[f["id"]] = best
	return links


## Process order so every feature comes AFTER the one it drains into — roots
## (outlets) first. Cycles (two features draining into each other, possible
## with hand-drawn lines) are broken by appending the leftovers in input order.
static func downstream_first_order(features: Array, links: Dictionary) -> Array:
	var by_id := {}
	for f in features:
		by_id[(f as Dictionary)["id"]] = f
	var children := {}
	var roots: Array = []
	for f in features:
		var id: String = (f as Dictionary)["id"]
		var l: Dictionary = links.get(id, {})
		var into := str(l.get("into", ""))
		if into.is_empty() or not by_id.has(into):
			roots.append(id)
		else:
			if not children.has(into):
				children[into] = []
			(children[into] as Array).append(id)
	var order: Array = []
	var seen := {}
	var queue: Array = roots.duplicate()
	while not queue.is_empty():
		var id: String = queue.pop_front()
		if seen.has(id):
			continue
		seen[id] = true
		order.append(by_id[id])
		for c in children.get(id, []):
			queue.append(c)
	for f in features:
		if not seen.has((f as Dictionary)["id"]):
			order.append(f)
	return order


## Nearest point on a polyline: {dist, s (arc length), point, seg}.
static func nearest_on_line(line: PackedVector2Array, p: Vector2) -> Dictionary:
	var best := INF
	var best_s := 0.0
	var best_pt := line[0] if line.size() > 0 else p
	var best_seg := 0
	var acc := 0.0
	for i in range(line.size() - 1):
		var a := line[i]
		var b := line[i + 1]
		var seg := b - a
		var l2 := seg.length_squared()
		var t := 0.0 if l2 < 1e-9 else clampf((p - a).dot(seg) / l2, 0.0, 1.0)
		var q := a + seg * t
		var d := q.distance_to(p)
		if d < best:
			best = d
			best_s = acc + sqrt(l2) * t
			best_pt = q
			best_seg = i
		acc += sqrt(l2)
	return {"dist": best, "s": best_s, "point": best_pt, "seg": best_seg}


static func polyline_length(line: PackedVector2Array) -> float:
	var l := 0.0
	for i in range(line.size() - 1):
		l += line[i].distance_to(line[i + 1])
	return l


## Arc-length position of each original vertex (for span lookups by s).
static func vertex_arc(line: PackedVector2Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(line.size())
	var acc := 0.0
	for i in line.size():
		if i > 0:
			acc += line[i - 1].distance_to(line[i])
		out[i] = acc
	return out


## Mode of the span containing arc length `s`.
static func mode_at(feature: Dictionary, s: float, varc: PackedFloat32Array = PackedFloat32Array()) -> String:
	var modes: Array = feature.get("modes", [])
	if modes.is_empty():
		return "surface"
	var va := varc if not varc.is_empty() else vertex_arc(feature["points"])
	for i in range(modes.size()):
		if s <= va[i + 1] + 1e-4:
			return str(modes[i])
	return str(modes.back())


## Per station (arc lengths `s`, ascending): 1 where the strip draws water —
## the station's span is open, or the span just above it is (so the strip
## reaches a culvert mouth). One forward pass: mode_at per station walks the
## span list from the start, which on a meandered 4 km wash was ~2 000 steps
## a station, twice a station, every re-mesh.
static func surface_mask(feature: Dictionary, s: PackedFloat32Array,
		varc: PackedFloat32Array = PackedFloat32Array()) -> PackedByteArray:
	var n := s.size()
	var out := PackedByteArray()
	out.resize(n)
	var modes: Array = feature.get("modes", [])
	if modes.is_empty():
		out.fill(1)
		return out
	var va := varc if not varc.is_empty() else vertex_arc(feature["points"])
	var m := modes.size()
	var ja := 0
	var jb := 0
	for i in n:
		var x := s[i]
		while ja < m - 1 and x > va[ja + 1] + 1e-4:
			ja += 1
		var surf := str(modes[ja]) == "surface"
		if not surf and i > 0:
			var xb := maxf(x - 0.01, 0.0)
			while jb < m - 1 and xb > va[jb + 1] + 1e-4:
				jb += 1
			surf = str(modes[jb]) == "surface"
		out[i] = 1 if surf else 0
	return out


## True when a line, read in its own order, mostly falls (sampled ground at the
## end below the start). Used to orient a hand-drawn stream downstream.
static func runs_downhill(line: PackedVector2Array, ground_fn: Callable) -> bool:
	if line.size() < 2:
		return true
	var a := line[0]
	var b := line[line.size() - 1]
	return float(ground_fn.call(b.x, b.y)) <= float(ground_fn.call(a.x, a.y))


static func reversed(line: PackedVector2Array) -> PackedVector2Array:
	var out := line.duplicate()
	out.reverse()
	return out
