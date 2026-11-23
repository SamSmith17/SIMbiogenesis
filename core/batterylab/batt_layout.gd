class_name BattLayout
extends RefCounted

## Where every part of a pack sits, in millimetres. Pack frame: +Y up, the
## origin on the floor under the middle of the enclosure, the FRONT (panel,
## terminals, breaker) facing +Z.
##
## Cells are grouped in P-groups (P cells in parallel); the S groups are
## joined in series along a serpentine: along a row, back along the next row,
## then up a layer. Every second group is turned round, so a group's negative
## sits beside the next group's positive and one busbar (or one nickel plate,
## for cylinders) joins them. Group 0's negative is the pack's negative and
## balance tap B0; the joint between group k−1 and group k is tap Bk; the last
## group's positive is B_S.
##
## While placing, x is the PRIMARY axis (the cells' thin axis, along which a
## group and a row run) and z the secondary; `face` "z" turns the result a
## quarter turn so rows run along x instead.
##
## `spec["nudge"]` = {part id: [x, y, z] mm} is a drag in the FINISHED pack
## (after the face turn and the centering shift). Cells, the BMS, sensors
## and fittings move by it; links, balance leads and main leads are drawn
## again so they still land on them. The case stays on the automatic layout.

const CELL_GAP_BOX := 1.0     # insulating sheet between prismatic cells
const ROW_GAP_BOX := 12.0
const CYL_GAP := 1.0          # holder wall between cylinders
const HOLDER_T := 7.0
const TRAY_T := 4.0
const LAYER_CLEAR := 40.0     # room for busbars and wiring above a lower layer
const AISLE_SIDE := 30.0      # between laid-down rows facing each other (busbars)
const PLATE_T := 10.0         # compression end plate (aluminium)
const ROD_D := 8.0            # M8 threaded rod
const STUD_H := 4.0
const HARNESS_UP := 22.0      # the BMS shelf's clearance over the busbars
const HARNESS_Y := 4.0        # the balance wires run this far over the bars
const LEAD_UP := 12.0
const LEAD_STACK_GAP := 3.0   # between the − lead's plane and the + lead's
## Leads whose ends are closer than this (in plan) hop across at their own
## height.
const LEAD_HOP_MM := 160.0
const BMS_LIFT := 8.0
const WALL_T := {"steel": 1.5, "aluminium": 2.0, "abs": 3.0}
const MARGIN := {"side": 12.0, "back": 12.0, "bottom": 6.0, "top": 15.0}
const FRONT_MARGIN := {"automotive": 10.0, "rack": 60.0, "wall": 50.0, "rolling": 50.0, "diy": 40.0}
const RACK_W := 440.0         # 19" equipment body
const RACK_EAR_W := 21.3      # (482.6 − 440) / 2
const WHEEL_H := 70.0


## Unit geometry of one cell for the layout. `orient` "up" stands a box
## cell on its base, terminals up; "side" lays it on its long edge with its
## terminals facing along z (how rack packs fit 4U), never a monoblock.
static func unit(cell: Dictionary, staggered: bool, orient: String = "up") -> Dictionary:
	if str(cell.get("format", "")) == "cylindrical":
		var d := float(cell.get("d_mm", 18.0))
		var h := float(cell.get("h_mm", 65.0))
		var pitch := d + CYL_GAP
		return {"cyl": true, "orient": "up", "d": d, "h": h, "pitch": pitch,
			"sp": pitch * (0.866 if staggered else 1.0), "stagger": staggered, "y_h": h + 4.0}
	var b := BattCells.box_mm(cell)
	var side := orient == "side" and str(cell.get("format", "")) != "monoblock"
	var tp := float((cell.get("terminals", {}) as Dictionary).get("pitch_mm", b.x * 0.7))
	var v := b.x if side else b.y
	return {"cyl": false, "orient": "side" if side else "up", "T": b.z, "V": v,
		"D": b.y if side else b.x, "pitch": b.z + CELL_GAP_BOX, "tp": tp, "y_h": v}


static func is_side(u: Dictionary) -> bool:
	return str(u.get("orient", "up")) == "side"


static func layer_pitch(u: Dictionary) -> float:
	if is_side(u):
		return float(u["y_h"]) + 10.0 + TRAY_T
	return float(u["y_h"]) + STUD_H + LAYER_CLEAR + TRAY_T


## Front z of row r (box cells). Laid-down rows pair up face to face across
## an aisle that holds their busbars.
static func row_z(u: Dictionary, r: int) -> float:
	if is_side(u):
		var z := float(r) * float(u["D"])
		for i in r:
			z += AISLE_SIDE if i % 2 == 0 else 5.0
		return z
	return float(r) * (float(u["D"]) + ROW_GAP_BOX)


## Size of the cell block (cells, holders, end plates, busbars, BMS above),
## [x, y, z] mm, before the face turn.
static func extent(u: Dictionary, p: int, gr: int, cols: int, rows: int, layers: int,
		plates: bool, top_stack: float) -> Vector3:
	var x := 0.0
	var z := 0.0
	if bool(u["cyl"]):
		var gp := int(ceil(float(p) / float(gr)))
		var np := cols * gp
		var ns := rows * gr
		x = float(np) * float(u["pitch"]) + (float(u["pitch"]) * 0.5 if bool(u["stagger"]) and ns > 1 else 0.0)
		z = float(ns - 1) * float(u["sp"]) + float(u["pitch"])
	else:
		x = float(cols * p) * float(u["pitch"]) - CELL_GAP_BOX
		if plates:
			x += 2.0 * (PLATE_T + 2.0)
		z = row_z(u, rows - 1) + float(u["D"])
		if plates:
			z += 16.0   # the end plates stand proud of the cells
		if is_side(u) and rows == 1:
			z += STUD_H + 12.0
	var extra_top := 0.0 if is_side(u) else STUD_H
	var y := float(layers - 1) * layer_pitch(u) + float(u["y_h"]) + extra_top + top_stack
	return Vector3(x, y, z)


## The arrangement for a form: {cols, rows, layers, group_rows, face, orient}.
## Any value the spec fixes (> 0, or a face / orient) is kept; the rest are
## searched.
static func choose(spec: Dictionary, cell: Dictionary, plates: bool) -> Dictionary:
	var ar: Dictionary = spec["arrange"]
	var s := int(spec["series"])
	var p := int(spec["parallel"])
	var form := str(spec["form"])
	var stag := bool(ar.get("staggered", false))
	var cyl := str(cell.get("format", "")) == "cylindrical"
	var faces: Array = ["x", "z"] if str(ar["face"]) == "auto" else [str(ar["face"])]
	if cyl and str(ar["face"]) == "auto":
		faces = ["x"]
	var orients: Array = ["up"]
	var o_fixed := str(ar.get("orient", "auto"))
	if o_fixed != "auto":
		orients = [o_fixed]
	elif not cyl and str(cell.get("format", "")) != "monoblock" and form != "automotive":
		orients = ["up", "side"]
	var lay_opts: Array = range(1, 4) if int(ar["layers"]) <= 0 else [int(ar["layers"])]
	var gr_opts: Array = [1]
	if cyl:
		gr_opts = range(1, mini(p, 20) + 1) if int(ar["group_rows"]) <= 0 else [mini(int(ar["group_rows"]), p)]
	var ts := 10.0 if form == "automotive" or form == "rack" else 40.0
	var best := {}
	var best_score := INF
	for orient in orients:
		var u := unit(cell, stag, str(orient))
		for face in faces:
			for layers in lay_opts:
				var per_layer := int(ceil(float(s) / float(layers)))
				var row_opts: Array = range(1, mini(per_layer, 24) + 1) if int(ar["rows"]) <= 0 else [int(ar["rows"])]
				for rows in row_opts:
					if is_side(u) and int(rows) > 2:
						continue
					var cols := int(ceil(float(per_layer) / float(rows)))
					if int(ar["cols"]) > 0:
						cols = int(ar["cols"])
					if cols * rows * int(layers) < s:
						continue
					# Skip arrangements with a whole empty row or layer.
					if int(ar["cols"]) <= 0 and (cols * (rows - 1) * int(layers) >= s or cols * rows * (int(layers) - 1) >= s):
						continue
					for gr in gr_opts:
						var gp := int(ceil(float(p) / float(gr)))
						if gp * int(gr) - p >= gp and int(ar["group_rows"]) <= 0:
							continue
						var ext := extent(u, p, int(gr), cols, rows, int(layers), plates, ts)
						if str(face) == "z":
							ext = Vector3(ext.z, ext.y, ext.x)
						if form == "automotive":
							ext.x += 45.0   # the BMS stands beside the cells
						elif form == "rack":
							ext.z += 35.0   # the BMS stands behind the front panel
						var score := _score(form, spec, ext, int(layers))
						score += float(cols * rows * int(layers) - s) * 5.0
						score += float(gp * int(gr) - p) * 2.0
						if is_side(u) and form == "diy":
							score += 300.0
						# A prismatic DIY box is the YIXIANG V3: cells upright
						# in two rows, the panel on the short end.
						if form == "diy" and not cyl:
							# One layer, two rows: the V3 box, not a stack of layers.
							if int(layers) != 1:
								score += 900.0
							if int(rows) != 2:
								score += 150.0
							if str(face) != "z":
								score += 60.0
						if score < best_score:
							best_score = score
							best = {"cols": cols, "rows": rows, "layers": int(layers),
								"group_rows": int(gr), "face": str(face), "orient": str(orient)}
	if best.is_empty():
		best = {"cols": s, "rows": 1, "layers": 1, "group_rows": 1, "face": "x", "orient": "up"}
	return best


static func _score(form: String, spec: Dictionary, ext: Vector3, layers: int) -> float:
	var en: Dictionary = spec["enclosure"]
	var wall := wall_t(spec)
	match form:
		"automotive":
			var g: Array = BattSpec.BCI_GROUPS[str(en["group"])]
			var inner := Vector3(float(g[0]), float(g[1]), float(g[2])) - Vector3.ONE * (2.0 * wall + 6.0)
			var over := maxf(0.0, ext.x - inner.x) + maxf(0.0, ext.y - inner.y) + maxf(0.0, ext.z - inner.z)
			return over * 1000.0 + float(layers) * 10.0
		"rack":
			var over_w := maxf(0.0, ext.x + 2.0 * MARGIN["side"] - (RACK_W - 2.0 * wall))
			var u := ceilf((ext.y + MARGIN["bottom"] + MARGIN["top"] + 2.0 * wall) / BattSpec.RACK_U_MM)
			# Racks are rarely deeper than ~650 mm of battery.
			return over_w * 1000.0 + u * 1000.0 + ext.z + maxf(0.0, ext.z - 650.0) * 20.0
		"wall":
			return ext.z * 4.0 + ext.x + absf(ext.y - 1.4 * ext.x) * 0.3
		"rolling":
			return ext.x + ext.z + maxf(0.0, ext.y - 800.0) * 4.0 + float(layers) * 30.0
	return 2.0 * (ext.x + ext.z) + float(layers - 1) * 400.0


static func wall_t(spec: Dictionary) -> float:
	var m := str((spec["enclosure"] as Dictionary).get("material", ""))
	if m.is_empty():
		m = default_material(str(spec["form"]))
	return float(WALL_T.get(m, 1.5))


static func default_material(form: String) -> String:
	return "abs" if form == "automotive" or form == "diy" else "steel"


# ---------------------------------------------------------------------------
# Placement
# ---------------------------------------------------------------------------

## The whole layout. `ar` is the arrangement (from `choose`), `ic` the
## interconnect ("busbar" | "nickel" | "link"), `bus` {material, w, t} or
## nickel {strips}, `bms` the BMS row ({} for none), `amps` the pack's
## design current (sizes leads and links).
static func place(spec: Dictionary, cell: Dictionary, ar: Dictionary, ic: String,
		bus: Dictionary, bms: Dictionary, amps: float, plates: bool) -> Dictionary:
	var s := int(spec["series"])
	var p := int(spec["parallel"])
	var u := unit(cell, bool((spec["arrange"] as Dictionary).get("staggered", false)),
		str(ar.get("orient", "up")))
	var cyl := bool(u["cyl"])
	var side_o := is_side(u)
	var cols := int(ar["cols"])
	var rows := int(ar["rows"])
	var gr := int(ar["group_rows"]) if cyl else 1
	var gp := int(ceil(float(p) / float(gr))) if cyl else p
	var lp := layer_pitch(u)
	var cells: Array = []
	var groups: Array = []
	for k in s:
		var per_layer := cols * rows
		var l := k / per_layer
		var m := k % per_layer
		var r := m / cols
		var c := m % cols
		if r % 2 == 1:
			c = cols - 1 - c
		if l % 2 == 1:
			r = rows - 1 - r
			c = cols - 1 - c if (rows % 2 == 1) else c
		var flip := k % 2 == 1
		var sgn := -1.0 if flip else 1.0
		var yb := float(l) * lp
		var g_cells: Array = []
		for i in p:
			var a := i % gp
			var b := i / gp
			var ce := {"cyl": cyl, "group": k, "flip": flip, "layer": l, "row": r,
				"id": "cell_%d_%d" % [k, i]}
			if cyl:
				var ip := c * gp + a
				var is_ := r * gr + b
				var x := float(ip) * float(u["pitch"]) + float(u["pitch"]) * 0.5
				if bool(u["stagger"]) and is_ % 2 == 1:
					x += float(u["pitch"]) * 0.5
				var z := float(is_) * float(u["sp"]) + float(u["pitch"]) * 0.5
				var h := float(u["h"])
				var pos := Vector3(x, yb + 2.0 + h * 0.5, z)
				ce["c"] = pos
				ce["s"] = Vector3(float(u["d"]), h, float(u["d"]))
				var top := pos + Vector3(0, h * 0.5, 0)
				var bot := pos - Vector3(0, h * 0.5, 0)
				ce["term_p"] = bot if flip else top
				ce["term_n"] = top if flip else bot
				ce["term_d"] = Vector3(0, sgn, 0)
			else:
				var x0 := (PLATE_T + 2.0) if plates else 0.0
				var x := x0 + float(c * gp + a) * float(u["pitch"]) + float(u["T"]) * 0.5
				var z := row_z(u, r) + float(u["D"]) * 0.5
				var pos := Vector3(x, yb + float(u["V"]) * 0.5, z)
				ce["c"] = pos
				ce["s"] = Vector3(float(u["T"]), float(u["V"]), float(u["D"]))
				var half := float(u["tp"]) * 0.5
				if side_o:
					var f := 1.0 if r % 2 == 0 else -1.0
					var fz := z + f * (float(u["D"]) * 0.5 + STUD_H)
					ce["term_p"] = Vector3(x, pos.y + sgn * half, fz)
					ce["term_n"] = Vector3(x, pos.y - sgn * half, fz)
					ce["term_d"] = Vector3(0, 0, f)
				else:
					var ty := pos.y + float(u["V"]) * 0.5 + STUD_H
					ce["term_p"] = Vector3(x, ty, z + sgn * half)
					ce["term_n"] = Vector3(x, ty, z - sgn * half)
					ce["term_d"] = Vector3(0, 1, 0)
			cells.append(ce)
			g_cells.append(ce)
		groups.append(_group_regions(k, g_cells, u, l))
	# Links between groups, the pack ends.
	var links: Array = []
	var leads: Array = []
	var cells_box := _aabb_of(cells)
	for k in range(s - 1):
		var gn: Dictionary = groups[k]
		var gpos: Dictionary = groups[k + 1]
		var a: AABB = gn["neg"]
		var b: AABB = gpos["pos"]
		if int(gn["layer"]) != int(gpos["layer"]):
			leads.append(_cross_layer_cable(k, a, b, cells_box, amps))
			links.append({"id": "link_%d" % k, "kind": "cable", "from": k, "to": k + 1,
				"tap": a.get_center(), "len_mm": _poly_len((leads[leads.size() - 1] as Dictionary)["pts"]),
				"area_mm2": float((leads[leads.size() - 1] as Dictionary)["mm2"]), "material": "copper"})
			continue
		links.append(_link(k, gn, gpos, ic, bus, u, amps, p))
	var ends: Array = []
	ends.append(_end_bar("neg", groups[0]["neg"], groups[0]["n_neg"], ic, bus, u))
	ends.append(_end_bar("pos", groups[s - 1]["pos"], groups[s - 1]["n_pos"], ic, bus, u))
	# Taps (lithium only; the caller passes bms = {} or a monitor for lead).
	var taps: Array = []
	var protected := not bms.is_empty() and bool(bms.get("protection", false))
	if protected:
		taps.append({"i": 0, "pos": (ends[0] as Dictionary)["tap"]})
		for k in range(1, s):
			taps.append({"i": k, "pos": (links[k - 1] as Dictionary)["tap"]})
		taps.append({"i": s, "pos": (ends[1] as Dictionary)["tap"]})
	var holders: Array = []
	if cyl and bool(spec.get("holders", true)):
		for l in range(_layers_used(groups)):
			var lc: Array = cells.filter(func(ce): return int(ce["layer"]) == l)
			var bx := _aabb_of(lc)
			var yb2 := float(l) * lp + 2.0
			holders.append({"id": "holder_bottom_%d" % l, "kind": "holder",
				"c": Vector3(bx.get_center().x, yb2 + HOLDER_T * 0.5, bx.get_center().z),
				"s": Vector3(bx.size.x + 4.0, HOLDER_T, bx.size.z + 4.0), "explode": Vector3(0, -0.15, 0)})
			holders.append({"id": "holder_top_%d" % l, "kind": "holder",
				"c": Vector3(bx.get_center().x, yb2 + float(u["h"]) - HOLDER_T * 0.5, bx.get_center().z),
				"s": Vector3(bx.size.x + 4.0, HOLDER_T, bx.size.z + 4.0),
				"explode": Vector3(0, 0.2 + 0.12 * float(l), 0)})
	var trays: Array = []
	for l in range(1, _layers_used(groups)):
		var lc: Array = cells.filter(func(ce): return int(ce["layer"]) == l)
		var bx := _aabb_of(lc)
		trays.append({"id": "tray_%d" % l, "kind": "tray",
			"c": Vector3(bx.get_center().x, float(l) * lp - TRAY_T * 0.5, bx.get_center().z),
			"s": Vector3(bx.size.x + 10.0, TRAY_T, bx.size.z + 10.0),
			"explode": Vector3(0, 0.12 * float(l), 0)})
	var comp := _compression(cells, groups, u, plates, spec, lp)
	var out := {"unit": u, "arrange": ar, "cells": cells, "groups": groups, "links": links,
		"ends": ends, "taps": taps, "leads": leads, "holders": holders, "trays": trays,
		"plates": comp["plates"], "rods": comp["rods"], "interconnect": ic}
	if str(ar["face"]) == "z":
		_turn(out)
	_finish(out, spec, cell, bms, amps)
	_apply_nudges(out, spec, cell, bms, amps, bus)
	return out


static func _layers_used(groups: Array) -> int:
	var n := 0
	for g in groups:
		n = maxi(n, int((g as Dictionary)["layer"]) + 1)
	return n


## A group's positive and negative terminal regions (thin AABBs) and the
## way each faces (n_pos / n_neg).
static func _group_regions(k: int, g_cells: Array, u: Dictionary, layer: int) -> Dictionary:
	var box := _aabb_of(g_cells)
	var first: Dictionary = g_cells[0]
	var pos := AABB(first["term_p"], Vector3.ZERO)
	var neg := AABB(first["term_n"], Vector3.ZERO)
	for ce in g_cells:
		pos = pos.expand(ce["term_p"])
		neg = neg.expand(ce["term_n"])
	var td: Vector3 = first["term_d"]
	if bool(u["cyl"]):
		# The whole face of the block, not just the cell centres.
		var r := float(u["d"]) * 0.5
		pos = AABB(pos.position - Vector3(r, 0, r), pos.size + Vector3(2.0 * r, 0, 2.0 * r))
		neg = AABB(neg.position - Vector3(r, 0, r), neg.size + Vector3(2.0 * r, 0, 2.0 * r))
		return {"k": k, "box": box, "pos": pos, "neg": neg, "layer": layer,
			"n_pos": td, "n_neg": -td}
	return {"k": k, "box": box, "pos": pos, "neg": neg, "layer": layer, "n_pos": td, "n_neg": td}


static func _aabb_of(cells: Array) -> AABB:
	var out := AABB()
	var first := true
	for ce in cells:
		var c: Vector3 = (ce as Dictionary)["c"]
		var sz: Vector3 = (ce as Dictionary)["s"]
		var b := AABB(c - sz * 0.5, sz)
		out = b if first else out.merge(b)
		first = false
	return out


static func _axis_of(n: Vector3) -> int:
	if absf(n.y) > 0.5:
		return 1
	if absf(n.z) > 0.5:
		return 2
	return 0


## The joint between group k's negative region and group k+1's positive
## region: a busbar, a nickel plate or a cable link. A bar lies flat on the
## terminals it joins (its thickness along their facing); a bar between rows
## that face each other across an aisle fills the aisle.
static func _link(k: int, gn: Dictionary, gpos: Dictionary, ic: String, bus: Dictionary,
		u: Dictionary, amps: float, p: int) -> Dictionary:
	var a: AABB = gn["neg"]
	var b: AABB = gpos["pos"]
	var na: Vector3 = gn["n_neg"]
	var nb: Vector3 = gpos["n_pos"]
	var m := a.merge(b)
	var ca := a.get_center()
	var cb := b.get_center()
	var dir := cb - ca
	var len_mm := maxf(dir.length(), 1.0)
	if ic == "link":
		var up := 40.0
		var pts: Array = [ca, ca + na * up, cb + nb * up, cb]
		var wl := BattElectrical.wire_for(amps)
		return {"id": "link_%d" % k, "kind": "link", "from": k, "to": k + 1,
			"tap": (ca + cb) * 0.5 + na * up, "pts": pts, "len_mm": _poly_len(pts),
			"area_mm2": float(wl["mm2"]), "wire": str(wl["name"]), "material": "copper",
			"amps": float(wl["amps"])}
	var t := float(bus["t"])
	var w := float(bus["w"])
	var size := m.size
	var c := m.get_center()
	var ax := _axis_of(na)
	var same := na.dot(nb) > 0.5
	var plane: Array = []
	for i in 3:
		if i != ax:
			plane.append(i)
	if bool(u["cyl"]):
		size.x += 2.0
		size.z += 2.0
	else:
		size.x += 12.0
		var perp := 2 if ax == 1 else 1
		size[perp] = maxf(size[perp], w)
	if same:
		size[ax] = t
		c[ax] += na[ax] * t * 0.5
	else:
		size[ax] = maxf(size[ax], t)
	# Current crosses the bar along ca→cb; the cross-section is its
	# thickness times its extent across that line.
	var p0 := int(plane[0])
	var p1 := int(plane[1])
	var across_i := p1 if absf(dir[p0]) >= absf(dir[p1]) else p0
	var across := size[across_i]
	var area := t * across
	var material := str(bus.get("material", "copper"))
	var amps_cap := 0.0
	if ic == "nickel":
		material = "nickel"
		# Every cell of the group passes its share through its own strips.
		area = float(BattElectrical.STRIP[0]) * float(BattElectrical.STRIP[1]) * float(bus.get("strips", 1)) * float(p)
		amps_cap = area * BattElectrical.NICKEL_A_PER_MM2
	else:
		amps_cap = BattElectrical.busbar_amps(w, t, material) * maxf(1.0, across / w)
	var tap := (c + na * t * 0.5) if same else c
	return {"id": "link_%d" % k, "kind": ic, "from": k, "to": k + 1, "c": c, "s": size,
		"tap": tap, "len_mm": len_mm, "area_mm2": area, "material": material, "amps": amps_cap,
		"bottom": na.y < -0.5, "n": na, "explode": na * 0.3}


static func _end_bar(which: String, reg: AABB, n: Vector3, ic: String, bus: Dictionary,
		u: Dictionary) -> Dictionary:
	var t := float(bus["t"])
	var w := float(bus["w"])
	var c := reg.get_center()
	if ic == "link":
		return {"id": "end_%s" % which, "which": which, "kind": "none", "c": c, "s": Vector3.ZERO,
			"tap": c, "n": n, "explode": Vector3.ZERO}
	var size := reg.size
	var ax := _axis_of(n)
	if bool(u["cyl"]):
		size.x += 2.0
		size.z += 2.0
	else:
		size.x += 12.0
		var perp := 2 if ax == 1 else 1
		size[perp] = maxf(size[perp] + 2.0, w)
	size[ax] = t
	var cc := c + n * t * 0.5
	return {"id": "end_%s" % which, "which": which, "kind": ic, "c": cc, "s": size,
		"tap": cc + n * t * 0.5, "bottom": n.y < -0.5, "n": n, "explode": n * 0.3}


static func _cross_layer_cable(k: int, a: AABB, b: AABB, box: AABB, amps: float) -> Dictionary:
	var ca := a.get_center()
	var cb := b.get_center()
	var out_z := box.end.z + 15.0
	var pts: Array = [ca, Vector3(ca.x, ca.y + 10.0, ca.z), Vector3(ca.x, ca.y + 10.0, out_z),
		Vector3(cb.x, cb.y + 10.0, out_z), Vector3(cb.x, cb.y + 10.0, cb.z), cb]
	var w := BattElectrical.wire_for(amps)
	return {"id": "layer_cable_%d" % k, "kind": "series", "pts": pts, "mm2": float(w["mm2"]),
		"wire": str(w["name"]), "len_mm": _poly_len(pts), "color": "red",
		"explode": Vector3(0, 0.35, 0)}


static func _compression(cells: Array, _groups: Array, u: Dictionary, plates: bool,
		_spec: Dictionary, _lp: float) -> Dictionary:
	var out := {"plates": [], "rods": []}
	if not plates or bool(u["cyl"]):
		return out
	# One fixture per row of each layer: plates at both ends, four rods.
	var rows := {}
	for ce in cells:
		var key := "%d_%d" % [int(ce["layer"]), int(roundf(float((ce["c"] as Vector3).z)))]
		if not rows.has(key):
			rows[key] = []
		(rows[key] as Array).append(ce)
	var n := 0
	for key in rows:
		var bx := _aabb_of(rows[key])
		var h := bx.size.y
		var w := bx.size.z
		for side in [-1.0, 1.0]:
			var x := (bx.position.x - PLATE_T * 0.5 - 1.0) if side < 0.0 else (bx.end.x + PLATE_T * 0.5 + 1.0)
			(out["plates"] as Array).append({"id": "plate_%d_%d" % [n, int(side)], "kind": "plate",
				"c": Vector3(x, bx.get_center().y - h * 0.05, bx.get_center().z),
				"s": Vector3(PLATE_T, h * 0.85, w + 16.0), "explode": Vector3(side * 0.35, 0, 0)})
		for yy in [0.2, 0.7]:
			for zz in [-1.0, 1.0]:
				var y := bx.position.y + h * float(yy)
				var z := bx.get_center().z + float(zz) * (w * 0.5 + 5.0)
				(out["rods"] as Array).append({"id": "rod_%d_%d_%d" % [n, int(yy * 10.0), int(zz)],
					"a": Vector3(bx.position.x - PLATE_T - 14.0, y, z),
					"b": Vector3(bx.end.x + PLATE_T + 14.0, y, z), "d": ROD_D,
					"explode": Vector3(0, 0.05, zz * 0.3)})
		n += 1
	return out


static func _poly_len(pts: Array) -> float:
	var l := 0.0
	for i in range(1, pts.size()):
		l += (pts[i] as Vector3).distance_to(pts[i - 1] as Vector3)
	return l


# ---------------------------------------------------------------------------
# Turning, BMS, harness, leads, enclosure
# ---------------------------------------------------------------------------

static func _sw(v: Vector3) -> Vector3:
	return Vector3(v.z, v.y, v.x)


static func _sw_aabb(b: AABB) -> AABB:
	return AABB(_sw(b.position), _sw(b.size))


## Swap x and z everywhere (rows then run along x).
static func _turn(L: Dictionary) -> void:
	for key in ["cells", "links", "ends", "holders", "trays", "plates"]:
		for e in (L[key] as Array):
			for f in ["c", "s", "tap", "explode", "n", "term_p", "term_n", "term_d"]:
				if (e as Dictionary).has(f):
					e[f] = _sw(e[f])
			if (e as Dictionary).has("pts"):
				e["pts"] = (e["pts"] as Array).map(func(v): return _sw(v))
	for e in (L["leads"] as Array):
		e["pts"] = (e["pts"] as Array).map(func(v): return _sw(v))
		e["explode"] = _sw(e["explode"])
	for e in (L["rods"] as Array):
		for f in ["a", "b", "explode"]:
			e[f] = _sw(e[f])
	for t in (L["taps"] as Array):
		t["pos"] = _sw(t["pos"])
	for g in (L["groups"] as Array):
		for f in ["box", "pos", "neg"]:
			g[f] = _sw_aabb(g[f])
		for f in ["n_pos", "n_neg"]:
			g[f] = _sw(g[f])


## Everything placed after the cells, in final axes: content box, BMS,
## harness, temperature sensors, enclosure and its fittings, main leads; then
## the whole layout moved so the enclosure stands on the origin.
static func _finish(L: Dictionary, spec: Dictionary, cell: Dictionary, bms: Dictionary,
		amps: float) -> void:
	var form := str(spec["form"])
	var yixiang := form == "diy" and not bool((L["unit"] as Dictionary)["cyl"])
	var en: Dictionary = spec["enclosure"]
	var cells_box := _aabb_of(L["cells"])
	var content := cells_box
	for key in ["links", "ends", "holders", "plates", "trays"]:
		for e in (L[key] as Array):
			if (e as Dictionary).has("s") and (e["s"] as Vector3) != Vector3.ZERO:
				content = content.merge(AABB((e["c"] as Vector3) - (e["s"] as Vector3) * 0.5, e["s"]))
	var top := content.end.y
	var protected := not bms.is_empty() and bool(bms.get("protection", false))
	var monitor := not bms.is_empty() and not protected
	var single_block := str(cell.get("format", "")) == "monoblock" and int(spec["series"]) * int(spec["parallel"]) == 1
	# BMS on a shelf above the cells at the front end.
	var bms_box := {}
	if protected:
		var ca := float(bms.get("cont_a", 100.0))
		var bs := Vector3(clampf(120.0 + ca * 0.35, 120.0, 260.0), clampf(18.0 + ca * 0.04, 18.0, 40.0),
			clampf(70.0 + ca * 0.15, 70.0, 140.0))
		if bs.x > cells_box.size.x and cells_box.size.z > bs.x:
			bs = Vector3(bs.z, bs.y, bs.x)
		if form == "automotive":
			# A drop-in has no room above its cells: the board stands on edge
			# beside them, like the real ones.
			var st := Vector3(bs.y, minf(bs.x, cells_box.size.y), minf(bs.z, cells_box.size.z))
			var c2 := Vector3(cells_box.end.x + 10.0 + st.x * 0.5,
				cells_box.position.y + st.y * 0.5, cells_box.get_center().z)
			bms_box = {"id": "bms", "kind": "bms", "c": c2, "s": st, "explode": Vector3(0.9, 0.3, 0),
				"conn": Vector3(c2.x, c2.y + st.y * 0.5, c2.z - st.z * 0.25),
				"b_neg": Vector3(c2.x, c2.y + st.y * 0.5, c2.z + st.z * 0.15),
				"p_neg": Vector3(c2.x, c2.y + st.y * 0.5, c2.z + st.z * 0.35)}
		elif form == "rack" or yixiang:
			# Behind the front panel, on edge. The YIXIANG kit clamps its
			# BMS in that bay too, rather than on a shelf over the cells.
			var st := Vector3(minf(bs.x, cells_box.size.x), minf(bs.z, cells_box.size.y), bs.y)
			var c3 := Vector3(cells_box.get_center().x, cells_box.position.y + st.y * 0.5,
				content.end.z + 8.0 + st.z * 0.5)
			bms_box = {"id": "bms", "kind": "bms", "c": c3, "s": st, "explode": Vector3(0, 0.2, 0.9),
				"conn": Vector3(c3.x - st.x * 0.25, c3.y + st.y * 0.5, c3.z),
				"b_neg": Vector3(c3.x - st.x * 0.5, c3.y + st.y * 0.3, c3.z),
				"p_neg": Vector3(c3.x + st.x * 0.5, c3.y + st.y * 0.3, c3.z)}
		else:
			var c := Vector3(cells_box.get_center().x, top + HARNESS_UP + BMS_LIFT + bs.y * 0.5,
				cells_box.end.z - bs.z * 0.5)
			bms_box = {"id": "bms", "kind": "bms", "c": c, "s": bs, "explode": Vector3(0, 0.75, 0),
				"conn": Vector3(c.x - bs.x * 0.25, c.y - bs.y * 0.5, c.z - bs.z * 0.5 + 8.0),
				"b_neg": Vector3(c.x - bs.x * 0.5, c.y, c.z + bs.z * 0.2),
				"p_neg": Vector3(c.x + bs.x * 0.5, c.y, c.z + bs.z * 0.2)}
		var bs2: Vector3 = bms_box["s"]
		var bc: Vector3 = bms_box["c"]
		content = content.merge(AABB(bc - bs2 * 0.5, bs2))
	# Harness: each tap up to the harness plane, along to the connector.
	var harness: Array = []
	if protected:
		var yh := top + HARNESS_Y
		var conn: Vector3 = bms_box["conn"]
		for t in (L["taps"] as Array):
			var a: Vector3 = t["pos"]
			var pts: Array = [a]
			if a.y < cells_box.position.y + 5.0:
				var ex := cells_box.end.x + 6.0
				pts.append(Vector3(ex, a.y, a.z))
				a = Vector3(ex, a.y, a.z)
			pts.append(Vector3(a.x, yh, a.z))
			pts.append(Vector3(a.x, yh, conn.z))
			pts.append(Vector3(conn.x + float(int(t["i"])) * 1.6, yh, conn.z))
			pts.append(Vector3(conn.x + float(int(t["i"])) * 1.6, conn.y, conn.z))
			harness.append({"id": "tap_B%d" % int(t["i"]), "i": int(t["i"]), "pts": pts,
				"len_mm": _poly_len(pts), "mm2": BattElectrical.BALANCE_MM2,
				"explode": Vector3(0, 0.5, 0)})
	# Temperature sensors on the cells.
	var sensors: Array = []
	if protected:
		var n := clampi(int(bms.get("temp_sensors", 1)), 1, 8)
		var gs: Array = L["groups"]
		for i in n:
			var gi := 0 if n == 1 else int(roundf(float(i) * float(gs.size() - 1) / float(n - 1)))
			var gb: AABB = (gs[gi] as Dictionary)["box"]
			sensors.append({"id": "ntc_%d" % i, "kind": "sensor",
				"c": Vector3(gb.get_center().x, gb.end.y + 2.0, gb.get_center().z + gb.size.z * 0.25),
				"s": Vector3(8.0, 3.0, 12.0), "explode": Vector3(0, 0.45, 0)})
	# The main leads run over the bars: the lid must clear the higher one.
	var lw := BattElectrical.wire_for(amps)
	if not single_block and form != "automotive":
		var lead_top := lead_plane(top, lw, true) + lead_thickness(lw) * 0.5 + 4.0
		if lead_top > content.end.y:
			content = content.merge(AABB(Vector3(cells_box.position.x, lead_top - 1.0, cells_box.position.z),
				Vector3(cells_box.size.x, 1.0, cells_box.size.z)))
	# Enclosure.
	var wall := wall_t(spec)
	var material := str(en.get("material", ""))
	if material.is_empty():
		material = default_material(form)
	var encl := {}
	var front_m := float(FRONT_MARGIN.get(form, 40.0))
	if not single_block:
		var inner_min := content.position - Vector3(MARGIN["side"], MARGIN["bottom"], MARGIN["back"])
		var inner_max := content.end + Vector3(MARGIN["side"], MARGIN["top"], front_m)
		var outer := AABB(inner_min - Vector3.ONE * wall, (inner_max - inner_min) + Vector3.ONE * 2.0 * wall)
		var fixed := Vector3.ZERO
		if form == "automotive":
			var g: Array = BattSpec.BCI_GROUPS[str(en["group"])]
			fixed = Vector3(float(g[0]), float(g[1]), float(g[2]))
		elif form == "rack":
			var u := int(en.get("u", 0))
			if u <= 0:
				u = int(ceilf(outer.size.y / BattSpec.RACK_U_MM - 1e-6))
			fixed = Vector3(RACK_W, float(u) * BattSpec.RACK_U_MM - 0.8, 0.0)
		for i in 3:
			var typed := float(en.get(["w_mm", "h_mm", "d_mm"][i], 0.0))
			if typed > 0.0:
				fixed[i] = typed
		var fits := true
		for i in 3:
			if fixed[i] > 0.0:
				if fixed[i] + 0.5 < outer.size[i]:
					fits = false
				var grow := fixed[i] - outer.size[i]
				# Grow evenly round the content (y: grow upward; z: at the front).
				if i == 1:
					outer.size.y = fixed[i]
				elif i == 2:
					outer.size.z = fixed[i]
				else:
					outer.position.x -= grow * 0.5
					outer.size.x = fixed[i]
		var rack_u := int(roundf((outer.size.y + 0.8) / BattSpec.RACK_U_MM)) if form == "rack" else 0
		encl = {"outer": outer, "wall": wall, "material": material, "fits": fits,
			"rack_u": rack_u, "panels": _panels(outer, wall)}
	# Lift a rolling unit onto its wheels, a YIXIANG box onto its feet.
	var lift := 0.0
	if form == "rolling" and not encl.is_empty():
		lift = WHEEL_H
	elif yixiang and not encl.is_empty():
		lift = 12.0
	# Front fittings: terminals, breaker, display, ports, handles, ears.
	var fittings: Array = []
	var term := {}
	if not encl.is_empty():
		var o: AABB = encl["outer"]
		term = _fittings(fittings, form, o, en, bms, protected, amps, yixiang)
	else:
		# The block's own posts.
		var cb: AABB = cells_box
		var tp := float((cell.get("terminals", {}) as Dictionary).get("pitch_mm", cb.size.x * 0.7))
		term = {"pos": Vector3(cb.get_center().x + tp * 0.5, cb.end.y, cb.get_center().z),
			"neg": Vector3(cb.get_center().x - tp * 0.5, cb.end.y, cb.get_center().z),
			"axis": "y", "n_out": Vector3.UP, "out_kind": "stud", "stud": 8.0}
		term["pos_out"] = term["pos"]
		term["neg_out"] = term["neg"]
	# Main leads.
	var leads: Array = L["leads"]
	var ends: Array = L["ends"]
	var neg_tap: Vector3 = (ends[0] as Dictionary)["tap"]
	var pos_tap: Vector3 = (ends[1] as Dictionary)["tap"]
	# The − lead runs clear of the harness, the + lead a cable higher, so the
	# two never share a plane and cross through each other.
	var via_y := lead_plane(top, lw, false)
	var via_pos := lead_plane(top, lw, true)
	if not single_block:
		var tneg: Vector3 = term["neg"]
		var tpos: Vector3 = term["pos"]
		if protected:
			leads.append(_lead("lead_b_neg", neg_tap, bms_box["b_neg"], via_y, lw, "black"))
			leads.append(_lead("lead_p_neg", bms_box["p_neg"], tneg, via_y, lw, "black"))
		elif monitor:
			var sh := Vector3(lerpf(neg_tap.x, tneg.x, 0.5), via_y, lerpf(neg_tap.z, tneg.z, 0.5))
			fittings.append({"id": "shunt", "kind": "shunt", "c": sh + Vector3(0, 10, 0),
				"s": Vector3(90.0, 25.0, 40.0), "explode": Vector3(0, 0.6, 0),
				"moves": ["shunt"]})
			term["shunt"] = sh
			leads.append(_lead("lead_neg_shunt", neg_tap, sh, via_y, lw, "black"))
			leads.append(_lead("lead_shunt_term", sh, tneg, via_y, lw, "black"))
		else:
			leads.append(_lead("lead_neg", neg_tap, tneg, via_y, lw, "black"))
		if term.has("breaker_in"):
			leads.append(_lead("lead_pos_breaker", pos_tap, term["breaker_in"], via_pos, lw, "red"))
			leads.append(_lead("lead_breaker_term", term["breaker_out"], tpos, via_pos, lw, "red"))
		else:
			leads.append(_lead("lead_pos", pos_tap, tpos, via_pos, lw, "red"))
	L["bms"] = bms_box
	L["harness"] = harness
	L["sensors"] = sensors
	L["enclosure"] = encl
	L["fittings"] = fittings
	L["terminals"] = term
	L["leads"] = leads
	L["single_block"] = single_block
	L["lead_wire"] = lw
	# Move so the enclosure (or the block) stands on the origin.
	var base := (encl["outer"] as AABB) if not encl.is_empty() else content
	var shift := Vector3(-base.get_center().x, -base.position.y + lift, -base.get_center().z)
	_shift(L, shift)
	if lift > 0.0 and form == "rolling":
		var o: AABB = encl["outer"]
		for sx in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				fittings.append({"id": "wheel_%d_%d" % [int(sx), int(sz)], "kind": "wheel",
					"c": Vector3(sx * (o.size.x * 0.5 - 40.0), WHEEL_H * 0.5, sz * (o.size.z * 0.5 - 40.0)),
					"s": Vector3(24.0, WHEEL_H, WHEEL_H), "explode": Vector3(0, -0.2, 0)})
	elif lift > 0.0 and yixiang:
		var o: AABB = encl["outer"]
		for sx in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				fittings.append({"id": "foot_%d_%d" % [int(sx), int(sz)], "kind": "foot",
					"c": Vector3(sx * (o.size.x * 0.5 - 36.0), 6.0, sz * (o.size.z * 0.5 - 46.0)),
					"s": Vector3(28.0, 12.0, 42.0), "explode": Vector3(0, -0.15, 0)})
	var b2 := (encl["outer"] as AABB) if not encl.is_empty() else AABB(content.position + shift, content.size)
	L["bounds"] = b2 if lift <= 0.0 else AABB(Vector3(b2.position.x, 0.0, b2.position.z), b2.size + Vector3(0, lift, 0))
	L["cells_box"] = _aabb_of(L["cells"])
	# The harness and main-lead plane, in the finished frame (top + the shift).
	L["wire_y"] = top + shift.y


## The height a main lead runs at over the top of the cells and bars: the −
## lead clear of the balance wires by its own radius, the + lead one cable
## (and a gap) above it.
static func lead_plane(top: float, w: Dictionary, positive: bool) -> float:
	var th := lead_thickness(w)
	var y := top + HARNESS_Y + 2.0 + th * 0.5
	return y + th + LEAD_STACK_GAP if positive else y


## How tall a main lead is where it runs flat: a round cable's diameter, a
## flexible busbar's (the builder draws leads of 21 mm² and up as flat
## braid) thickness.
static func lead_thickness(w: Dictionary) -> float:
	var mm2 := float(w.get("mm2", 0.0))
	if mm2 >= 21.0:
		return float(BattWire.flex_stack(mm2)["th"])
	return BattWire.od_mm(str(w.get("name", "")), mm2)


static func _lead(id: String, a: Vector3, b: Vector3, via_y: float, w: Dictionary, color: String) -> Dictionary:
	# Two ends close together (a breaker beside its terminal): a short hop at
	# their own height, not up over the cells and back.
	if Vector2(a.x - b.x, a.z - b.z).length() < LEAD_HOP_MM:
		via_y = maxf(a.y, b.y) + 30.0
	var pts: Array = [a, Vector3(a.x, via_y, a.z), Vector3(b.x, via_y, a.z), Vector3(b.x, via_y, b.z), b]
	var clean: Array = [pts[0]]
	for i in range(1, pts.size()):
		if (pts[i] as Vector3).distance_to(clean[clean.size() - 1]) > 0.5:
			clean.append(pts[i])
	return {"id": id, "kind": "main", "pts": clean, "len_mm": _poly_len(clean),
		"mm2": float(w["mm2"]), "wire": str(w["name"]), "color": color, "explode": Vector3(0, 0.55, 0)}


static func _panels(o: AABB, w: float) -> Array:
	var c := o.get_center()
	var sz := o.size
	return [
		{"id": "case_bottom", "kind": "panel", "c": Vector3(c.x, o.position.y + w * 0.5, c.z),
			"s": Vector3(sz.x, w, sz.z), "explode": Vector3(0, -0.05, 0)},
		{"id": "case_lid", "kind": "lid", "c": Vector3(c.x, o.end.y - w * 0.5, c.z),
			"s": Vector3(sz.x, w, sz.z), "explode": Vector3(0, 1.1, 0)},
		{"id": "case_left", "kind": "panel", "c": Vector3(o.position.x + w * 0.5, c.y, c.z),
			"s": Vector3(w, sz.y - 2.0 * w, sz.z), "explode": Vector3(-0.8, 0, 0)},
		{"id": "case_right", "kind": "panel", "c": Vector3(o.end.x - w * 0.5, c.y, c.z),
			"s": Vector3(w, sz.y - 2.0 * w, sz.z), "explode": Vector3(0.8, 0, 0)},
		{"id": "case_back", "kind": "panel", "c": Vector3(c.x, c.y, o.position.z + w * 0.5),
			"s": Vector3(sz.x - 2.0 * w, sz.y - 2.0 * w, w), "explode": Vector3(0, 0, -0.8)},
		{"id": "case_front", "kind": "front", "c": Vector3(c.x, c.y, o.end.z - w * 0.5),
			"s": Vector3(sz.x - 2.0 * w, sz.y - 2.0 * w, w), "explode": Vector3(0, 0, 0.8)},
	]


## The YIXIANG V3 face: a white breaker on the left, a pair of posts for
## each pole (P+ red, P− black) with the lead on the inner stud, the screen
## between them, recessed handles on the long sides and a latch.
static func _yixiang_panel(out: Array, o: AABB, en: Dictionary, bms: Dictionary,
		protected: bool, amps: float) -> Dictionary:
	var fz := o.end.z
	var cx := o.get_center().x
	var w := o.size.x
	var h := o.size.y
	var ex := Vector3(0, 0, 0.8)
	var term := {}
	var py := o.position.y + h * 0.66
	if protected:
		var ba := float(en.get("breaker_a", 0.0))
		if ba <= 0.0:
			ba = BattElectrical.breaker_for(amps)
		var bx := o.position.x + minf(52.0, w * 0.16)
		var by := o.position.y + h * 0.46
		out.append({"id": "breaker", "kind": "breaker", "look": "yixiang",
			"c": Vector3(bx, by, fz + 9.0), "s": Vector3(28.0, minf(72.0, h * 0.5), 16.0),
			"explode": ex, "amps": ba, "moves": ["breaker_in", "breaker_out"]})
		term["breaker_in"] = Vector3(bx, by - 8.0, fz - 22.0)
		term["breaker_out"] = Vector3(bx, by + 8.0, fz - 22.0)
		term["breaker_a"] = ba
	var gap := 28.0
	var px := cx - w * 0.12
	var nx := cx + w * 0.22
	for pole in [["pos", px], ["neg", nx]]:
		var which := str(pole[0])
		var x0 := float(pole[1])
		var kind := "term_%s" % which
		var inner_i := 1 if which == "pos" else 0
		for i in 2:
			var x := x0 + (float(i) - 0.5) * gap
			var moves: Array = [which, which + "_out"] if i == inner_i else [which + "_twin"]
			out.append({"id": "%s_%d" % [kind, i], "kind": kind,
				"c": Vector3(x, py, fz + 12.0), "s": Vector3(20.0, 20.0, 22.0), "explode": ex,
				"moves": moves})
			out.append({"id": "cover_%s_%d" % [which, i], "kind": "cover",
				"c": Vector3(x, py, fz + 22.0), "s": Vector3(26.0, 26.0, 14.0), "explode": ex})
		var inner := x0 + (0.5 if which == "pos" else -0.5) * gap
		var outer := x0 + (-0.5 if which == "pos" else 0.5) * gap
		term[which] = Vector3(inner, py, fz - 14.0)
		term[which + "_out"] = Vector3(inner, py, fz + 13.5)
		term[which + "_twin"] = Vector3(outer, py, fz - 14.0)
	term["axis"] = "z"
	term["n_out"] = Vector3(0, 0, 1)
	term["out_kind"] = "stud"
	term["stud"] = 8.0
	if protected and bool(en.get("display", true)):
		out.append({"id": "display", "kind": "display",
			"c": Vector3(cx + w * 0.02, o.position.y + h * 0.40, fz + 2.0),
			"s": Vector3(minf(78.0, w * 0.22), minf(50.0, h * 0.26), 3.0), "explode": ex})
		out.append({"id": "power", "kind": "button",
			"c": Vector3(cx - w * 0.30, o.position.y + h * 0.80, fz + 2.5),
			"s": Vector3(14.0, 14.0, 6.0), "explode": ex})
		var listed: Array = []
		for cm in (bms.get("comms", []) as Array):
			if str(cm) in ["CAN", "RS485"]:
				listed.append(str(cm))
		if listed.is_empty():
			listed = ["RS485", "CAN"]
		for i in listed.size():
			out.append({"id": "port_%s" % listed[i], "kind": "port",
				"c": Vector3(cx - 16.0 + float(i) * 20.0, o.position.y + maxf(28.0, h * 0.16), fz + 1.5),
				"s": Vector3(12.0, 10.0, 4.0), "explode": ex, "label": str(listed[i])})
	for sx in [-1.0, 1.0]:
		var x := o.position.x if sx < 0.0 else o.end.x
		x += sx
		out.append({"id": "recess_%d" % int(sx), "kind": "recess",
			"c": Vector3(x, o.get_center().y, o.get_center().z - o.size.z * 0.06),
			"s": Vector3(6.0, 46.0, minf(120.0, o.size.z * 0.26)),
			"explode": Vector3(sx * 0.8, 0, 0)})
	out.append({"id": "latch", "kind": "latch",
		"c": Vector3(o.position.x - 3.0, o.end.y - 34.0, fz - 64.0),
		"s": Vector3(8.0, 16.0, 32.0), "explode": Vector3(-0.4, 0, 0)})
	return term


## Front-panel and case fittings; returns the terminal points (and the
## breaker's, when there is one).
static func _fittings(out: Array, form: String, o: AABB, en: Dictionary, bms: Dictionary,
		protected: bool, amps: float, yixiang: bool = false) -> Dictionary:
	if yixiang:
		return _yixiang_panel(out, o, en, bms, protected, amps)
	var fz := o.end.z
	var cx := o.get_center().x
	var w := o.size.x
	var h := o.size.y
	var ex := Vector3(0, 0, 0.8)
	var term := {}
	if form == "automotive":
		var py := o.end.y
		var pz := o.position.z + minf(35.0, o.size.z * 0.25)
		for e in [["pos", 1.0], ["neg", -1.0]]:
			var x := cx + float(e[1]) * (w * 0.5 - 45.0)
			out.append({"id": "post_%s" % e[0], "kind": "post_%s" % e[0],
				"c": Vector3(x, py + 10.0, pz), "s": Vector3(18.0, 20.0, 18.0),
				"explode": Vector3(0, 1.1, 0), "moves": [str(e[0]), str(e[0]) + "_out"]})
			term[str(e[0])] = Vector3(x, py - 15.0, pz)
			# Outside: a clamp round the post's middle.
			term[str(e[0]) + "_out"] = Vector3(x, py + 9.0, pz)
		out.append({"id": "handle", "kind": "handle", "c": Vector3(cx, py + 6.0, o.get_center().z),
			"s": Vector3(w * 0.45, 8.0, 22.0), "explode": Vector3(0, 1.2, 0)})
		term["axis"] = "y"
		term["n_out"] = Vector3.UP
		term["out_kind"] = "post"
		term["stud"] = 8.0
		return term
	var ty := o.position.y + minf(h * 0.5, 55.0)
	for e in [["pos", 1.0], ["neg", -1.0]]:
		var x := cx + float(e[1]) * (w * 0.5 - 45.0)
		out.append({"id": "term_%s" % e[0], "kind": "term_%s" % e[0],
			"c": Vector3(x, ty, fz + 12.0), "s": Vector3(22.0, 22.0, 24.0), "explode": ex,
			"moves": [str(e[0]), str(e[0]) + "_out"]})
		term[str(e[0])] = Vector3(x, ty, fz - 15.0)
		# Outside: where a lug sits on the M8 stud (on the brass, under the nut).
		term[str(e[0]) + "_out"] = Vector3(x, ty, fz + 13.5)
	term["axis"] = "z"
	term["n_out"] = Vector3(0, 0, 1)
	term["out_kind"] = "stud"
	term["stud"] = 8.0
	if protected:
		var ba := float(en.get("breaker_a", 0.0))
		if ba <= 0.0:
			ba = BattElectrical.breaker_for(amps)
		var bx := cx + w * 0.5 - 110.0
		var by := o.position.y + minf(h * 0.5, 60.0)
		out.append({"id": "breaker", "kind": "breaker", "c": Vector3(bx, by, fz + 10.0),
			"s": Vector3(36.0, minf(80.0, h * 0.7), 20.0), "explode": ex, "amps": ba,
			"moves": ["breaker_in", "breaker_out"]})
		term["breaker_in"] = Vector3(bx, by, fz - 25.0)
		term["breaker_out"] = Vector3(bx + 10.0, by, fz - 25.0)
		term["breaker_a"] = ba
		if bool(en.get("display", true)):
			out.append({"id": "display", "kind": "display",
				"c": Vector3(cx, o.position.y + h * 0.6, fz + 1.5),
				"s": Vector3(72.0, minf(42.0, h * 0.45), 3.0), "explode": ex})
		var comms: Array = bms.get("comms", [])
		var i := 0
		for cm in comms:
			if str(cm) in ["CAN", "RS485"]:
				out.append({"id": "port_%s" % cm, "kind": "port",
					"c": Vector3(cx - w * 0.5 + 100.0 + float(i) * 22.0, o.position.y + minf(h * 0.35, 30.0), fz + 1.0),
					"s": Vector3(16.0, 14.0, 4.0), "explode": ex, "label": str(cm)})
				i += 1
	if form == "rack":
		if bool(en.get("ears", true)):
			for sx in [-1.0, 1.0]:
				out.append({"id": "ear_%d" % int(sx), "kind": "ear",
					"c": Vector3(cx + sx * (w * 0.5 + RACK_EAR_W * 0.5), o.get_center().y, fz - 1.5),
					"s": Vector3(RACK_EAR_W, h, 3.0), "explode": ex})
		if bool(en.get("handles", true)):
			for sx in [-1.0, 1.0]:
				out.append({"id": "handle_%d" % int(sx), "kind": "handle",
					"c": Vector3(cx + sx * (w * 0.5 - 18.0), o.get_center().y, fz + 18.0),
					"s": Vector3(12.0, h * 0.6, 30.0), "explode": ex})
	elif form == "wall":
		out.append({"id": "bracket", "kind": "bracket",
			"c": Vector3(cx, o.end.y - 60.0, o.position.z - 4.0), "s": Vector3(w * 0.8, 60.0, 6.0),
			"explode": Vector3(0, 0, -0.9)})
	elif form == "rolling":
		out.append({"id": "handle", "kind": "handle", "c": Vector3(cx, o.end.y + 28.0, o.position.z + 30.0),
			"s": Vector3(w * 0.6, 56.0, 16.0), "explode": Vector3(0, 1.2, 0)})
	elif form == "diy" and bool(en.get("handles", true)):
		for sx in [-1.0, 1.0]:
			out.append({"id": "handle_%d" % int(sx), "kind": "handle",
				"c": Vector3(cx + sx * (w * 0.5 + 8.0), o.end.y - 40.0, o.get_center().z),
				"s": Vector3(14.0, 20.0, minf(110.0, o.size.z * 0.4)),
				"explode": Vector3(sx * 0.8, 0, 0)})
	return term


static func _shift(L: Dictionary, d: Vector3) -> void:
	for key in ["cells", "links", "ends", "holders", "trays", "plates", "sensors", "fittings"]:
		for e in (L[key] as Array):
			for f in ["c", "tap", "term_p", "term_n"]:
				if (e as Dictionary).has(f):
					e[f] = (e[f] as Vector3) + d
			if (e as Dictionary).has("pts"):
				e["pts"] = (e["pts"] as Array).map(func(v): return (v as Vector3) + d)
	for key in ["leads", "harness"]:
		for e in (L[key] as Array):
			e["pts"] = (e["pts"] as Array).map(func(v): return (v as Vector3) + d)
	for e in (L["rods"] as Array):
		e["a"] = (e["a"] as Vector3) + d
		e["b"] = (e["b"] as Vector3) + d
	for t in (L["taps"] as Array):
		t["pos"] = (t["pos"] as Vector3) + d
	for g in (L["groups"] as Array):
		for f in ["box", "pos", "neg"]:
			var b: AABB = g[f]
			b.position += d
			g[f] = b
	if not (L["bms"] as Dictionary).is_empty():
		for f in ["c", "conn", "b_neg", "p_neg"]:
			L["bms"][f] = (L["bms"][f] as Vector3) + d
	if not (L["enclosure"] as Dictionary).is_empty():
		var o: AABB = L["enclosure"]["outer"]
		o.position += d
		L["enclosure"]["outer"] = o
		for pn in (L["enclosure"]["panels"] as Array):
			pn["c"] = (pn["c"] as Vector3) + d
	for f in ["pos", "neg", "pos_out", "neg_out", "breaker_in", "breaker_out", "shunt"]:
		if (L["terminals"] as Dictionary).has(f):
			L["terminals"][f] = (L["terminals"][f] as Vector3) + d


# ---------------------------------------------------------------------------
# Drag nudges (the designer's "pick a part and drag it")
# ---------------------------------------------------------------------------

const NUDGE_LIMIT := 2000.0
## Parts a drag in the pack view can move. Case panels, busbars, leads and
## holders are drawn from the cells and the case, so they are not grabbed.
const DRAG_KINDS := ["cell", "bms", "sensor", "breaker", "display", "button", "port",
	"handle", "shunt", "cover", "latch", "ear", "bracket", "recess", "wheel", "foot"]


static func can_drag(kind: String) -> bool:
	return kind in DRAG_KINDS or kind.begins_with("term_") or kind.begins_with("post_")


## The stored nudge for `id`, in millimetres. Zero when it has none.
static func nudge_of(spec: Dictionary, id: String) -> Vector3:
	var all: Variant = spec.get("nudge", {})
	if not (all is Dictionary) or not (all as Dictionary).has(id):
		return Vector3.ZERO
	return _as_vec((all as Dictionary)[id])


## Where a drag lets go: the nudge at the press plus how far the pointer
## moved on the part's plane. `step` 0 keeps the fraction; 5 snaps to 5 mm.
static func drag_nudge(n0: Vector3, hit0: Vector3, hit: Vector3, step: float) -> Vector3:
	var s := n0 + (hit - hit0)
	if step > 0.0:
		s = Vector3(snappedf(s.x, step), snappedf(s.y, step), snappedf(s.z, step))
	return s.clamp(Vector3.ONE * -NUDGE_LIMIT, Vector3.ONE * NUDGE_LIMIT)


## Write `v` onto `spec` (0.1 mm), dropping a nudge shorter than 0.5 mm and
## the whole key when nothing is left. Mutates `spec`.
static func write_nudge(spec: Dictionary, id: String, v: Vector3) -> void:
	var s := Vector3(snappedf(v.x, 0.1), snappedf(v.y, 0.1), snappedf(v.z, 0.1))
	s = s.clamp(Vector3.ONE * -NUDGE_LIMIT, Vector3.ONE * NUDGE_LIMIT)
	var all: Dictionary = spec["nudge"] if spec.get("nudge") is Dictionary else {}
	if s.length() < 0.5:
		all.erase(id)
	else:
		all[id] = [s.x, s.y, s.z]
	if all.is_empty():
		spec.erase("nudge")
	else:
		spec["nudge"] = all


static func _as_vec(v: Variant) -> Vector3:
	if v is Vector3:
		return v
	if v is Array and (v as Array).size() >= 3:
		return Vector3(float((v as Array)[0]), float((v as Array)[1]), float((v as Array)[2]))
	return Vector3.ZERO


static func _has_nudge(spec: Dictionary) -> bool:
	var all: Variant = spec.get("nudge", {})
	return all is Dictionary and not (all as Dictionary).is_empty()


## Move the named parts by their nudges, then redraw whatever was reaching
## them. No nudge: the layout is left exactly as `_finish` built it.
static func _apply_nudges(L: Dictionary, spec: Dictionary, _cell: Dictionary, bms: Dictionary,
		amps: float, bus: Dictionary) -> void:
	if not _has_nudge(spec):
		return
	var moved_cell := false
	for ce in (L["cells"] as Array):
		var n := nudge_of(spec, str(ce["id"]))
		if n == Vector3.ZERO:
			continue
		moved_cell = true
		ce["c"] = (ce["c"] as Vector3) + n
		ce["term_p"] = (ce["term_p"] as Vector3) + n
		ce["term_n"] = (ce["term_n"] as Vector3) + n
	if moved_cell:
		_relink(L, spec, bus, amps)
	var moved_bms := false
	if not (L["bms"] as Dictionary).is_empty():
		var nb := nudge_of(spec, "bms")
		if nb != Vector3.ZERO:
			moved_bms = true
			for f in ["c", "conn", "b_neg", "p_neg"]:
				L["bms"][f] = (L["bms"][f] as Vector3) + nb
	if moved_cell or moved_bms:
		_rebuild_harness(L)
	for sn in (L["sensors"] as Array):
		var ns := nudge_of(spec, str(sn["id"]))
		if ns != Vector3.ZERO:
			sn["c"] = (sn["c"] as Vector3) + ns
	var moved_fit := _nudge_fittings(L, spec)
	if moved_cell or moved_bms or moved_fit:
		_rebuild_main_leads(L, bms, amps)
	_grow_bounds(L, spec)


## Links, end bars and balance taps from the cells as they sit now.
static func _relink(L: Dictionary, spec: Dictionary, bus: Dictionary, amps: float) -> void:
	var u: Dictionary = L["unit"]
	var ic := str(L["interconnect"])
	var p := int(spec["parallel"])
	var cells: Array = L["cells"]
	var by := {}
	for ce in cells:
		var k := int((ce as Dictionary)["group"])
		if not by.has(k):
			by[k] = []
		(by[k] as Array).append(ce)
	var s := by.size()
	var groups: Array = []
	for k in s:
		var g: Array = by[k]
		groups.append(_group_regions(k, g, u, int((g[0] as Dictionary)["layer"])))
	var links: Array = []
	var leads: Array = []
	var cells_box := _aabb_of(cells)
	for k in range(s - 1):
		var gn: Dictionary = groups[k]
		var gpos: Dictionary = groups[k + 1]
		var a: AABB = gn["neg"]
		var b: AABB = gpos["pos"]
		if int(gn["layer"]) != int(gpos["layer"]):
			leads.append(_cross_layer_cable(k, a, b, cells_box, amps))
			var last: Dictionary = leads[leads.size() - 1]
			links.append({"id": "link_%d" % k, "kind": "cable", "from": k, "to": k + 1,
				"tap": a.get_center(), "len_mm": _poly_len(last["pts"]),
				"area_mm2": float(last["mm2"]), "material": "copper"})
			continue
		links.append(_link(k, gn, gpos, ic, bus, u, amps, p))
	var ends: Array = []
	ends.append(_end_bar("neg", (groups[0] as Dictionary)["neg"], (groups[0] as Dictionary)["n_neg"], ic, bus, u))
	ends.append(_end_bar("pos", (groups[s - 1] as Dictionary)["pos"], (groups[s - 1] as Dictionary)["n_pos"], ic, bus, u))
	var taps: Array = []
	if not (L["bms"] as Dictionary).is_empty():
		taps.append({"i": 0, "pos": (ends[0] as Dictionary)["tap"]})
		for k in range(1, s):
			taps.append({"i": k, "pos": (links[k - 1] as Dictionary)["tap"]})
		taps.append({"i": s, "pos": (ends[1] as Dictionary)["tap"]})
	L["groups"] = groups
	L["links"] = links
	L["ends"] = ends
	L["taps"] = taps
	L["leads"] = leads
	L["cells_box"] = cells_box


static func _rebuild_harness(L: Dictionary) -> void:
	if (L["bms"] as Dictionary).is_empty() or (L["taps"] as Array).is_empty():
		return
	var yh := float(L["wire_y"]) + HARNESS_UP * 0.6
	var conn: Vector3 = (L["bms"] as Dictionary)["conn"]
	var cells_box: AABB = L["cells_box"]
	var harness: Array = []
	for t in (L["taps"] as Array):
		var a: Vector3 = t["pos"]
		var pts: Array = [a]
		if a.y < cells_box.position.y + 5.0:
			var ex := cells_box.end.x + 6.0
			pts.append(Vector3(ex, a.y, a.z))
			a = Vector3(ex, a.y, a.z)
		pts.append(Vector3(a.x, yh, a.z))
		pts.append(Vector3(a.x, yh, conn.z))
		pts.append(Vector3(conn.x + float(int(t["i"])) * 1.6, yh, conn.z))
		pts.append(Vector3(conn.x + float(int(t["i"])) * 1.6, conn.y, conn.z))
		harness.append({"id": "tap_B%d" % int(t["i"]), "i": int(t["i"]), "pts": pts,
			"len_mm": _poly_len(pts), "mm2": BattElectrical.BALANCE_MM2,
			"explode": Vector3(0, 0.5, 0)})
	L["harness"] = harness


## Drop the old main leads and draw them to the terminals as they sit now.
static func _rebuild_main_leads(L: Dictionary, bms_row: Dictionary, amps: float) -> void:
	if bool(L.get("single_block", false)):
		return
	var leads: Array = []
	for ld in (L["leads"] as Array):
		if str((ld as Dictionary).get("kind", "")) != "main":
			leads.append(ld)
	var term: Dictionary = L["terminals"]
	var ends: Array = L["ends"]
	if not term.has("pos") or not term.has("neg") or ends.size() < 2:
		L["leads"] = leads
		return
	var lw := BattElectrical.wire_for(amps)
	var neg_tap: Vector3 = (ends[0] as Dictionary)["tap"]
	var pos_tap: Vector3 = (ends[1] as Dictionary)["tap"]
	var via_y := lead_plane(float(L["wire_y"]), lw, false)
	var via_pos := lead_plane(float(L["wire_y"]), lw, true)
	var tneg: Vector3 = term["neg"]
	var tpos: Vector3 = term["pos"]
	var protected := not (L["bms"] as Dictionary).is_empty()
	var monitor := not protected and not bms_row.is_empty()
	if protected:
		leads.append(_lead("lead_b_neg", neg_tap, (L["bms"] as Dictionary)["b_neg"], via_y, lw, "black"))
		leads.append(_lead("lead_p_neg", (L["bms"] as Dictionary)["p_neg"], tneg, via_y, lw, "black"))
	elif monitor:
		var sh: Vector3 = term["shunt"] if term.get("shunt") is Vector3 else Vector3(
			lerpf(neg_tap.x, tneg.x, 0.5), via_y, lerpf(neg_tap.z, tneg.z, 0.5))
		leads.append(_lead("lead_neg_shunt", neg_tap, sh, via_y, lw, "black"))
		leads.append(_lead("lead_shunt_term", sh, tneg, via_y, lw, "black"))
	else:
		leads.append(_lead("lead_neg", neg_tap, tneg, via_y, lw, "black"))
	if term.has("breaker_in"):
		leads.append(_lead("lead_pos_breaker", pos_tap, term["breaker_in"], via_pos, lw, "red"))
		leads.append(_lead("lead_breaker_term", term["breaker_out"], tpos, via_pos, lw, "red"))
	else:
		leads.append(_lead("lead_pos", pos_tap, tpos, via_pos, lw, "red"))
	L["leads"] = leads
	L["lead_wire"] = lw


## Move each fitting, and the terminal point it owns, by its nudge.
static func _nudge_fittings(L: Dictionary, spec: Dictionary) -> bool:
	var moved := false
	var term: Dictionary = L["terminals"]
	for f in (L["fittings"] as Array):
		var n := nudge_of(spec, str(f["id"]))
		if n == Vector3.ZERO:
			continue
		moved = true
		f["c"] = (f["c"] as Vector3) + n
		for key in (f.get("moves", []) as Array):
			if term.get(key) is Vector3:
				term[key] = (term[key] as Vector3) + n
	return moved


static func _grow_bounds(L: Dictionary, spec: Dictionary) -> void:
	var bounds: AABB = L["bounds"]
	var grew := false
	for ce in (L["cells"] as Array):
		if nudge_of(spec, str(ce["id"])) == Vector3.ZERO:
			continue
		grew = true
		var c: Vector3 = ce["c"]
		var s: Vector3 = ce["s"]
		bounds = bounds.merge(AABB(c - s * 0.5, s))
	for f in (L["fittings"] as Array):
		if nudge_of(spec, str(f["id"])) == Vector3.ZERO:
			continue
		grew = true
		var c2: Vector3 = f["c"]
		var s2: Vector3 = f["s"]
		bounds = bounds.merge(AABB(c2 - s2 * 0.5, s2))
	if not (L["bms"] as Dictionary).is_empty() and nudge_of(spec, "bms") != Vector3.ZERO:
		grew = true
		var bc: Vector3 = L["bms"]["c"]
		var bs: Vector3 = L["bms"]["s"]
		bounds = bounds.merge(AABB(bc - bs * 0.5, bs))
	if grew:
		L["bounds"] = bounds
