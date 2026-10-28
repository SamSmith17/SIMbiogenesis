class_name PvLabArray
extends RefCounted

## Laying an array out and wiring its strings. Pure.
##
## Array frame (the placed prop's local frame): metres, y up from the
## mounting surface, +Z the way the array faces at yaw 0 — due SOUTH, as
## PvArrayBuilder (CelestialClock: north −Z, east +X). Fixed tables are rows
## marching north from the front (south) row; each table carries `cols`
## modules across and `stack` modules up its slope. A tracker's rows are
## spaced along X; its axis runs along Z, `cols` modules along the axis and
## `stack` across it (1P / 2P).
##
## Strings: "rows" serpentines across each table (the usual way to wire a
## rack), "cols" runs down each column, "custom" takes the player's lists.
## Panels a string does not reach are left unwired (and said so).

const ORIENTATIONS := ["portrait", "landscape"]
const STRING_MODES := ["rows", "cols", "custom"]
const STRING_MODE_LABELS := {"rows": "Along each row (serpentine)", "cols": "Down each column",
	"custom": "Painted by hand"}

## Module face above the rack plane: the rail and a clamp's lip (m) are added
## by the rail profile's height.
const CLAMP_LIFT_M := 0.004
## How far above the tube the modules sit on a tracker (m): half the tube
## plus a module clamp rail.
const TRACKER_DECK_M := 0.10

const ARRAY_DEFAULTS := {"mount": "ground", "rows": 1, "cols": 6, "stack": 2, "orientation": "portrait",
	"gap_mm": 20.0, "pitch_m": 0.0, "tilt_deg": 30.0, "clearance_m": 0.6, "site_lat": 45.0, "gcr": 0.35}
const STRING_DEFAULTS := {"mode": "rows", "size": 0, "custom": [], "inputs": 1, "groups": []}
const TARGET_DEFAULTS := {"name": "Generic MPPT 150 V", "max_voc": 150.0, "mppt_min_v": 0.0,
	"mppt_max_v": 0.0, "startup_v": 0.0, "max_isc": 0.0, "max_pv_watts": 0.0, "cold_c": -10.0, "hot_c": 40.0}


static func resolve_array(a: Dictionary) -> Dictionary:
	var out := ARRAY_DEFAULTS.duplicate()
	for k in a:
		out[k] = a[k]
	if not PvLabRack.MOUNTS.has(str(out["mount"])):
		out["mount"] = "ground"
	if not ORIENTATIONS.has(str(out["orientation"])):
		out["orientation"] = "portrait"
	out["rows"] = clampi(int(out["rows"]), 1, 40)
	out["cols"] = clampi(int(out["cols"]), 1, 80)
	out["stack"] = clampi(int(out["stack"]), 1, 6)
	if str(out["mount"]) == "pole":
		out["rows"] = 1
	out["gap_mm"] = clampf(float(out["gap_mm"]), 0.0, 500.0)
	out["pitch_m"] = clampf(float(out["pitch_m"]), 0.0, 40.0)
	out["tilt_deg"] = clampf(float(out["tilt_deg"]), 0.0, 75.0)
	out["clearance_m"] = clampf(float(out["clearance_m"]), 0.0, 6.0)
	out["site_lat"] = clampf(float(out["site_lat"]), -89.0, 89.0)
	out["gcr"] = clampf(float(out["gcr"]), 0.1, 0.9)
	return out


static func resolve_strings(st: Dictionary) -> Dictionary:
	var out := STRING_DEFAULTS.duplicate(true)
	for k in st:
		out[k] = st[k]
	if not STRING_MODES.has(str(out["mode"])):
		out["mode"] = "rows"
	out["size"] = clampi(int(out["size"]), 0, 200)
	out["inputs"] = clampi(int(out["inputs"]), 1, 8)
	var custom: Array = []
	for s in (out["custom"] as Array) if out["custom"] is Array else []:
		if s is Array:
			var ids: Array = []
			for x in s:
				ids.append(int(x))
			custom.append(ids)
	out["custom"] = custom
	var groups: Array = []
	for g in (out["groups"] as Array) if out["groups"] is Array else []:
		if g is Array:
			var ids2: Array = []
			for x in g:
				ids2.append(int(x))
			groups.append(ids2)
	out["groups"] = groups
	return out


static func resolve_target(t: Dictionary) -> Dictionary:
	var out := TARGET_DEFAULTS.duplicate()
	for k in t:
		out[k] = t[k]
	for k in ["max_voc", "mppt_min_v", "mppt_max_v", "startup_v", "max_isc", "max_pv_watts", "cold_c", "hot_c"]:
		out[k] = float(out[k])
	out["name"] = str(out["name"])
	return out


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

## The modules' sizes in the rack's terms: {across, depth} (m) — across the
## table (or along a tracker's axis) and up its slope (or across the axis).
static func module_footprint(module: Dictionary, orientation: String) -> Dictionary:
	var w := float(module["dims_mm"]["w"]) * 0.001
	var h := float(module["dims_mm"]["h"]) * 0.001
	if orientation == "landscape":
		return {"across": h, "depth": w}
	return {"across": w, "depth": h}


## Lay the array out: {mount, panels, tables, heads, module_depth_m, gcr,
## pitch_m, footprint: Rect2 (xz), height_m}. Each panel is {index, table,
## col, k (up the slope / across the axis), head, xf}: xf the module's
## transform (its face normal +Y, its own frame as PvLabModule) in the array
## frame — or, on a tracker, in its head's frame at rotation 0.
static func layout(module: Dictionary, arr: Dictionary, rack: Dictionary) -> Dictionary:
	var a := resolve_array(arr)
	var r := PvLabRack.resolve(rack)
	var mount := str(a["mount"])
	var fp := module_footprint(module, str(a["orientation"]))
	var across := float(fp["across"])
	var depth := float(fp["depth"])
	var gap := float(a["gap_mm"]) * 0.001
	var cols := int(a["cols"])
	var stack := int(a["stack"])
	var t_mod := float(module["dims_mm"]["t"]) * 0.001
	var land := str(a["orientation"]) == "landscape"
	var width := across * cols + gap * float(cols - 1)
	var length := depth * stack + gap * float(stack - 1)
	var out := {"mount": mount, "panels": [], "tables": [], "heads": [], "module_depth_m": depth,
		"across_m": across, "gcr": 0.0, "pitch_m": 0.0}
	var kit := PvLabRack.kit(str(r["material"]))
	var rail_h := 0.0 if mount == "none" else float(PvLabRack.profile(str(kit["rail"]))["h"]) * 0.001
	var purl_h := float(PvLabRack.profile(str(kit["purlin"]))["h"]) * 0.001
	var minx := INF
	var maxx := -INF
	var minz := INF
	var maxz := -INF
	var top_y := 0.0
	if mount == "tracker":
		var gcr := float(a["gcr"])
		var pitch := float(a["pitch_m"]) if float(a["pitch_m"]) > 0.0 else length / gcr
		pitch = maxf(pitch, length + 0.2)
		out["gcr"] = length / pitch
		out["pitch_m"] = pitch
		var hub_h := float(r["hub_h_m"])
		var rows := int(a["rows"])
		for ri in rows:
			var hx := (float(ri) - float(rows - 1) * 0.5) * pitch
			var head := {"pos": Vector3(hx, hub_h, 0.0), "length_m": width, "width_m": length, "floor_y": 0.0,
				"row": ri}
			(out["heads"] as Array).append(head)
			for ci in cols:
				for k in stack:
					# Along the axis (Z) by column; across it (X) by k.
					var z := -width * 0.5 + across * 0.5 + float(ci) * (across + gap)
					var x := -length * 0.5 + depth * 0.5 + float(k) * (depth + gap)
					# Portrait on a tracker: the module's length runs ACROSS the axis.
					var b := Basis(Vector3.UP, PI * 0.5) if not land else Basis.IDENTITY
					var xf := Transform3D(b, Vector3(x, TRACKER_DECK_M + t_mod * 0.5, z))
					(out["panels"] as Array).append({"index": (out["panels"] as Array).size(), "table": ri,
						"col": ci, "k": k, "head": ri, "xf": xf})
			minx = minf(minx, hx - length * 0.5)
			maxx = maxf(maxx, hx + length * 0.5)
			minz = minf(minz, -width * 0.5)
			maxz = maxf(maxz, width * 0.5)
			top_y = maxf(top_y, hub_h + length * 0.5 * sin(deg_to_rad(60.0)))
		out["footprint"] = Rect2(minx, minz, maxx - minx, maxz - minz)
		out["height_m"] = top_y
		return out
	# Fixed tables.
	var tilt_deg := float(a["tilt_deg"])
	if mount == "roof_flush" or mount == "none":
		tilt_deg = 0.0
	var tilt := deg_to_rad(tilt_deg)
	var rows2 := int(a["rows"])
	var pitch2 := float(a["pitch_m"])
	if pitch2 <= 0.0:
		pitch2 = length * cos(tilt) + PvGridSnap.shade_gap_m(length * sin(tilt), float(a["site_lat"]))
	pitch2 = maxf(pitch2, length * cos(tilt) + 0.05)
	out["pitch_m"] = pitch2
	out["gcr"] = length / pitch2 if rows2 > 1 else 0.0
	var low_y := 0.0
	match mount:
		"roof_flush":
			low_y = float(r["standoff_mm"]) * 0.001
		"none":
			low_y = 0.0
		"pole":
			low_y = float(r["pole_h_m"]) - length * 0.5 * sin(tilt) + purl_h
		_:
			low_y = float(a["clearance_m"]) + purl_h
	var slope_dir := Vector3(0.0, sin(tilt), -cos(tilt))
	var normal := Vector3(0.0, cos(tilt), sin(tilt))
	var lift := rail_h + CLAMP_LIFT_M + t_mod * 0.5 if mount != "none" else t_mod * 0.5
	for ti in rows2:
		var zc := (float(rows2 - 1) * 0.5 - float(ti)) * pitch2
		var low := Vector3(0.0, low_y, zc + length * 0.5 * cos(tilt))
		var rail_s: Array = []
		for k in stack:
			var s0 := float(k) * (depth + gap)
			if mount != "none":
				rail_s.append(s0 + depth * 0.25)
				rail_s.append(s0 + depth * 0.75)
		var tb := {"tilt_deg": tilt_deg, "low": low, "width_m": width, "length_m": length,
			"clearance_m": low_y, "floor_y": 0.0, "rail_s": rail_s, "row": ti}
		(out["tables"] as Array).append(tb)
		for k in stack:
			for ci in cols:
				var u := -width * 0.5 + across * 0.5 + float(ci) * (across + gap)
				var s := depth * 0.5 + float(k) * (depth + gap)
				var pos := low + Vector3(u, 0, 0) + slope_dir * s + normal * lift
				var b2 := Basis(Vector3.RIGHT, tilt)
				if land:
					b2 = b2 * Basis(Vector3.UP, PI * 0.5)
				(out["panels"] as Array).append({"index": (out["panels"] as Array).size(), "table": ti,
					"col": ci, "k": k, "head": -1, "xf": Transform3D(b2, pos)})
		minx = minf(minx, -width * 0.5)
		maxx = maxf(maxx, width * 0.5)
		minz = minf(minz, low.z - length * cos(tilt))
		maxz = maxf(maxz, low.z)
		top_y = maxf(top_y, low_y + length * sin(tilt) + lift + t_mod)
	out["footprint"] = Rect2(minx, minz, maxx - minx, maxz - minz)
	out["height_m"] = top_y
	return out


## A panel's transform in the ARRAY frame for tracker rotation `r_deg`
## (fixed panels ignore it). A positive rotation tips the modules toward
## local −X (west at yaw 0), as PvLabTracker.
static func panel_xf(lay: Dictionary, p: Dictionary, r_deg: float = 0.0) -> Transform3D:
	var xf: Transform3D = p["xf"]
	var hi := int(p.get("head", -1))
	if hi < 0:
		return xf
	return head_xf(lay, hi, r_deg) * xf


static func head_xf(lay: Dictionary, hi: int, r_deg: float) -> Transform3D:
	var hd: Dictionary = (lay["heads"] as Array)[hi]
	return Transform3D(Basis(Vector3(0, 0, 1), deg_to_rad(r_deg)), hd["pos"])


# ---------------------------------------------------------------------------
# Strings
# ---------------------------------------------------------------------------

## The panel order a string mode walks.
static func walk_order(lay: Dictionary, mode: String) -> Array:
	var panels: Array = lay["panels"]
	var keyed: Array = []
	for p in panels:
		var t := int(p["table"])
		var c := int(p["col"])
		var k := int(p["k"])
		var key := 0
		if mode == "cols":
			# Down each column through the tables, back up the next.
			var pos := t * 10 + k
			key = c * 100000 + (pos if c % 2 == 0 else 99999 - pos)
		else:
			# Serpentine: alternate direction each line of modules.
			var line := t * 10 + k
			key = line * 1000 + (c if line % 2 == 0 else 999 - c)
		keyed.append([key, int(p["index"])])
	keyed.sort_custom(func(x, y): return x[0] < y[0])
	var out: Array = []
	for e in keyed:
		out.append(e[1])
	return out


## The strings (lists of panel indices) for a module / layout / string spec
## / target. `size` 0 picks the longest string the target's window allows.
static func strings_for(module: Dictionary, lay: Dictionary, st: Dictionary, target: Dictionary) -> Array:
	var s := resolve_strings(st)
	var n := (lay["panels"] as Array).size()
	if str(s["mode"]) == "custom":
		var out: Array = []
		var seen := {}
		for c in s["custom"]:
			var ids: Array = []
			for x in c:
				if int(x) >= 0 and int(x) < n and not seen.has(int(x)):
					seen[int(x)] = true
					ids.append(int(x))
			if not ids.is_empty():
				out.append(ids)
		return out
	var size := int(s["size"])
	if size <= 0:
		size = auto_string_size(module, n, target)
	size = clampi(size, 1, maxi(n, 1))
	var order := walk_order(lay, str(s["mode"]))
	var out2: Array = []
	var i := 0
	while i < order.size():
		out2.append(order.slice(i, mini(i + size, order.size())))
		i += size
	return out2


## The longest series string that stays inside the target's voltage window,
## preferring one that divides the panel count evenly.
static func auto_string_size(module: Dictionary, count: int, target: Dictionary) -> int:
	var t := resolve_target(target)
	var e := PvLabModule.electrical(module)
	var best_any := 1
	var best_even := 0
	for n in range(1, maxi(count, 1) + 1):
		var w := window(e, n, t)
		if not bool(w["ok"]):
			if float(w["voc_cold"]) > float(t["max_voc"]) and float(t["max_voc"]) > 0.0:
				break
			continue
		best_any = n
		if count % n == 0:
			best_even = n
	if best_even > 0 and best_even * 2 >= best_any:
		return best_even
	return best_any


## A string of n modules against a controller window — the same rules as
## PvElectrical.string_window_report: cold-morning Voc under max_voc, STC Voc
## over the start-up voltage, hot-noon Vmp (NOCT cell) over the MPPT floor,
## STC Vmp under the MPPT ceiling.
static func window(e: Dictionary, n: int, t: Dictionary) -> Dictionary:
	var cold := float(t["cold_c"])
	var hot_cell := float(t["hot_c"]) + (float(e["noct_c"]) - 20.0) * 1000.0 / 800.0
	var voc := float(e["voc"]) * n
	var vmp := float(e["vmp"]) * n
	var voc_cold := voc * (1.0 + float(e["voc_coeff"]) / 100.0 * (cold - 25.0))
	var vmp_hot := vmp * (1.0 + float(e["vmp_coeff"]) / 100.0 * (hot_cell - 25.0))
	var issues: Array = []
	if float(t["max_voc"]) > 0.0 and voc_cold > float(t["max_voc"]):
		issues.append("cold-morning Voc %.0f V exceeds the %.0f V limit at %.0f °C" % [voc_cold, float(t["max_voc"]), cold])
	if float(t["startup_v"]) > 0.0 and voc < float(t["startup_v"]):
		issues.append("string Voc %.0f V never reaches the %.0f V start-up voltage" % [voc, float(t["startup_v"])])
	if float(t["mppt_min_v"]) > 0.0 and vmp_hot < float(t["mppt_min_v"]):
		issues.append("hot-noon Vmp %.0f V falls below the %.0f V MPPT floor" % [vmp_hot, float(t["mppt_min_v"])])
	if float(t["mppt_max_v"]) > 0.0 and vmp > float(t["mppt_max_v"]):
		issues.append("Vmp %.0f V is above the %.0f V MPPT ceiling (clips)" % [vmp, float(t["mppt_max_v"])])
	return {"n": n, "voc": voc, "vmp": vmp, "voc_cold": voc_cold, "vmp_hot": vmp_hot, "hot_cell_c": hot_cell,
		"ok": issues.is_empty(), "issues": issues, "margin_v": float(t["max_voc"]) - voc_cold}


## Which strings feed which MPPT input (output group): the player's groups,
## else the strings dealt into `inputs` equal blocks.
static func groups_for(strings: Array, st: Dictionary) -> Array:
	var s := resolve_strings(st)
	var n := strings.size()
	if not (s["groups"] as Array).is_empty():
		var out: Array = []
		var seen := {}
		for g in s["groups"]:
			var ids: Array = []
			for x in g:
				if int(x) >= 0 and int(x) < n and not seen.has(int(x)):
					seen[int(x)] = true
					ids.append(int(x))
			if not ids.is_empty():
				out.append(ids)
		var rest: Array = []
		for i in n:
			if not seen.has(i):
				rest.append(i)
		if not rest.is_empty():
			out.append(rest)
		return out
	var k := clampi(int(s["inputs"]), 1, maxi(n, 1))
	var out2: Array = []
	for gi in k:
		out2.append([])
	for i in n:
		(out2[mini(i * k / maxi(n, 1), k - 1)] as Array).append(i)
	var clean: Array = []
	for g in out2:
		if not (g as Array).is_empty():
			clean.append(g)
	return clean


## Where each module's + and − lead ends start (array frame, rotation 0).
static func lead_points(module: Dictionary, lay: Dictionary) -> Array:
	var jb := PvLabModule.jbox_points(module)
	var w := float(module["dims_mm"]["w"]) * 0.001
	var h := float(module["dims_mm"]["h"]) * 0.001
	var t := float(module["dims_mm"]["t"]) * 0.001
	var out: Array = []
	for p in lay["panels"]:
		var xf := panel_xf(lay, p)
		var pu: Vector2 = jb["plus"]
		var mu: Vector2 = jb["minus"]
		out.append({"plus": xf * Vector3(pu.x * w, -t * 0.5, pu.y * h),
			"minus": xf * Vector3(mu.x * w, -t * 0.5, mu.y * h)})
	return out


## The wiring: per string its links (+ of one module to − of the next), each
## {from, to, gap_m, reach: bool, jumper_m}, plus the string's ends and the
## home-run length to the array's combiner point (the front of row 0's
## middle, or the first tracker's middle).
static func wiring(module: Dictionary, lay: Dictionary, strings: Array) -> Dictionary:
	var leads := float(module["jbox"]["leads_mm"]) * 0.001
	var pts := lead_points(module, lay)
	var combiner := Vector3.ZERO
	if not (lay["tables"] as Array).is_empty():
		combiner = ((lay["tables"] as Array)[0] as Dictionary)["low"]
	elif not (lay["heads"] as Array).is_empty():
		var hp: Vector3 = ((lay["heads"] as Array)[0] as Dictionary)["pos"]
		combiner = Vector3(hp.x, 0.4, hp.z)
	var out_strings: Array = []
	var jumpers := 0
	var jumper_m := 0.0
	var home_m := 0.0
	for st in strings:
		var links: Array = []
		var ids: Array = st
		for i in range(ids.size() - 1):
			var a: Dictionary = pts[int(ids[i])]
			var b: Dictionary = pts[int(ids[i + 1])]
			var d := (a["plus"] as Vector3).distance_to(b["minus"])
			var reach := d <= leads * 2.0 + 0.02
			var jm := 0.0 if reach else ceilf((d - leads * 2.0 + 0.3) * 2.0) * 0.5
			if not reach:
				jumpers += 1
				jumper_m += jm
			links.append({"from": int(ids[i]), "to": int(ids[i + 1]), "gap_m": d, "reach": reach, "jumper_m": jm})
		var hr := 0.0
		if not ids.is_empty():
			var first: Dictionary = pts[int(ids[0])]
			var last: Dictionary = pts[int(ids[ids.size() - 1])]
			hr = maxf((first["minus"] as Vector3).distance_to(combiner) - leads, 0.0) \
				+ maxf((last["plus"] as Vector3).distance_to(combiner) - leads, 0.0)
		home_m += hr
		out_strings.append({"panels": ids, "links": links, "home_run_m": hr})
	return {"strings": out_strings, "jumpers": jumpers, "jumper_m": jumper_m, "home_run_m": home_m,
		"combiner": combiner, "leads": pts}


## Panels in no string.
static func unwired(lay: Dictionary, strings: Array) -> Array:
	var seen := {}
	for s in strings:
		for x in s:
			seen[int(x)] = true
	var out: Array = []
	for p in lay["panels"]:
		if not seen.has(int(p["index"])):
			out.append(int(p["index"]))
	return out


## Strings from a graph topology: given the panel item ids in panel order
## and the series links between them (id → next id), the chains. A panel
## with no series link is a string of one when `wired` holds its id.
static func strings_from_links(panel_ids: Array, next_of: Dictionary, wired: Dictionary = {}) -> Array:
	var index_of := {}
	for i in panel_ids.size():
		index_of[str(panel_ids[i])] = i
	var has_prev := {}
	for k in next_of:
		has_prev[str(next_of[k])] = true
	var out: Array = []
	var used := {}
	for i in panel_ids.size():
		var id := str(panel_ids[i])
		if has_prev.has(id) or used.has(id):
			continue
		var chain: Array = []
		var cur := id
		var guard := 0
		while not cur.is_empty() and index_of.has(cur) and not used.has(cur) and guard < 4096:
			used[cur] = true
			chain.append(int(index_of[cur]))
			cur = str(next_of.get(cur, ""))
			guard += 1
		if chain.size() > 1 or (chain.size() == 1 and (next_of.has(id) or wired.has(id))):
			out.append(chain)
	return out
