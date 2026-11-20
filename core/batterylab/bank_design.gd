class_name BankDesign
extends RefCounted

## A battery bank laid out and worked out: every pack's place, the bus, every
## cable measured along its route (out of the terminal, along a channel, to
## its landing) with its gauge, current and voltage drop, the fuses, the
## comms chain, how evenly the strings share the current, the bank's numbers,
## its bill of materials and its checks. Millimetres in a bank frame: +Y up,
## origin on the floor under the middle, the packs' fronts toward +Z.
##
## Cable sizing: NEC 310.16 75 °C ampacity at 125 % of the continuous current
## (NEC 690.8 / 480 practice for battery circuits), then up a size while the
## drop at that current is over `DROP_MAX` (1 %, a common battery-cable
## target). Fuses: one per string at its positive, sized at 125 % of the
## string's current, of a type whose interrupting rating covers the fault
## current the bank can deliver (bank voltage ÷ the strings' resistance) and
## whose voltage rating covers the bank's charged voltage: Class T (20 kA,
## 160 V DC), MRBF (10 kA, 58 V DC), ANL (6 kA, 32 V DC) — maker data sheets
## as remembered, flagged as estimates. Costs and some masses are estimates.

const DROP_MAX := 0.01
## A distributor box's own bus rating (A): a Lynx-class distributor is sold
## as a 1000 A bus (maker data, transcribed, not verified).
const DIST_RATING_A := 1000.0
## A main cable routed in 3D is drawn by the conduit system; the bank's own
## model shows only this much of it, out of the bus.
const ROUTED_STUB_MM := 350.0
## Laid-together bars of one size carry less than n × one bar (they heat each
## other): DIN 43671's factors for spaced flat bars, approximately (an
## ESTIMATE for DC).
const STACK_FACTOR := [0.0, 1.0, 1.7, 2.3, 2.8]
## Adiabatic short-circuit withstand, S ≥ I·√t / k (IEC 60364-5-54, IEC
## 60949): k = 143 A·√s/mm² for copper cable with XLPE / EPR insulation
## (90 °C to 250 °C), 159 for a bare copper bar (to 200 °C).
const K_CABLE := 143.0
const K_BAR := 159.0
## Fuse blow time t = k_blow / (x² − 1.21)² at x times its rating (x > 1.1):
## ~5 ms at 10 × for Class T, ~10 ms for MRBF, ~50 ms for ANL, and seconds
## near 2 ×, and never faster than the fuse's own clearing time (`t_min`:
## the arc inside takes a millisecond or more to put out). A fit to the shape
## of maker time-current curves, an ESTIMATE.
const LUG_SLACK_MM := 100.0
const STUB_MM := 45.0
const PLINTH_MM := 100.0
const RACK_GAP_MM := 8.0
const ROW_GAP_MM := 50.0
const WALL_Y_MM := 450.0
const SHELF_STEP_MM := 160.0
const CART_DECK_MM := 180.0
const PER_ROW := 4
const CABINET_W := 600.0
## Fuse families: interrupt kA, voltage rating V DC, sizes A, $ fuse, $ holder.
const FUSE_TYPES := {
	"class_t": {"label": "Class T", "ka": 20.0, "v": 160.0, "k_blow": 49.0, "t_min": 0.001,
		"sizes": [70, 80, 100, 110, 125, 150, 175, 200, 225, 250, 300, 350, 400], "usd": 85.0, "holder_usd": 45.0},
	"mrbf": {"label": "MRBF", "ka": 10.0, "v": 58.0, "k_blow": 98.0, "t_min": 0.003,
		"sizes": [30, 40, 50, 60, 70, 80, 100, 125, 150, 175, 200, 225, 250, 300], "usd": 18.0, "holder_usd": 14.0},
	"anl": {"label": "ANL", "ka": 6.0, "v": 32.0, "k_blow": 490.0, "t_min": 0.01,
		"sizes": [35, 40, 50, 60, 80, 100, 130, 150, 175, 200, 225, 250, 300, 325, 350, 400, 500], "usd": 12.0, "holder_usd": 18.0},
}
## Copper cable: $ per metre per mm² (an estimate, welding / battery cable).
const CABLE_USD_PER_M_MM2 := 0.22

static var _cache: Dictionary = {}
static var _order: Array = []


static func solve(bank: Dictionary) -> Dictionary:
	var key := BankSpec.key_of(bank)
	if _cache.has(key):
		return _cache[key]
	var d := _solve(BankSpec.resolve(bank))
	_cache[key] = d
	_order.append(key)
	if _order.size() > 24:
		_cache.erase(_order.pop_front())
	return d


static func auto_mount(form: String) -> String:
	return {"rack": "cabinet", "wall": "wall", "rolling": "floor", "automotive": "shelf", "diy": "floor"}.get(form, "floor")


static func _solve(b: Dictionary) -> Dictionary:
	var pd := BattDesign.solve(b["pack"])
	var pe: Dictionary = pd["electrical"]
	var N := int(b["series"])
	var M := int(b["parallel"])
	var form := str((b["pack"] as Dictionary)["form"])
	var mount := str(b["mount"]) if str(b["mount"]) != "auto" else auto_mount(form)
	var bus := str(b["bus"])
	if bus == "auto":
		bus = "busbar" if mount == "cabinet" or M > 4 else "distributor"
	var pb: AABB = pd["layout"]["bounds"]
	var pw := pb.size.x
	var ph := pb.size.y
	var pdp := pb.size.z
	var term: Dictionary = pd["layout"]["terminals"]
	var t_pos: Vector3 = term.get("pos", Vector3(pw * 0.3, ph, 0))
	var t_neg: Vector3 = term.get("neg", Vector3(-pw * 0.3, ph, 0))
	var on_top := t_pos.y > ph * 0.85
	var gap := float(b["gap_mm"])
	# Packs: string j, place s in it; k = j * N + s is the order they stand in.
	var packs: Array = []
	var count := N * M
	var cols := count
	var levels := 1
	var step_x := pw + maxf(gap, ROW_GAP_MM)
	var step_y := ph + RACK_GAP_MM + gap
	var y0 := 0.0
	match mount:
		"cabinet":
			cols = 1
			levels = count
			y0 = PLINTH_MM
		"shelf":
			cols = mini(count, PER_ROW)
			levels = ceili(float(count) / float(cols))
			step_y = ph + SHELF_STEP_MM + gap
			y0 = 120.0
		"wall":
			cols = mini(count, 6)
			levels = ceili(float(count) / float(cols))
			step_y = ph + 220.0 + gap
			y0 = WALL_Y_MM
		"cart":
			cols = mini(count, 3)
			levels = ceili(float(count) / float(cols))
			step_y = ph + 60.0 + gap
			y0 = CART_DECK_MM
		_:
			cols = mini(count, 8)
			levels = ceili(float(count) / float(cols))
			step_y = ph + 30.0 + gap
	for k in count:
		var c := k % cols
		var lv := k / cols
		var x := (float(c) - float(cols - 1) * 0.5) * step_x
		var y := y0 + float(lv) * step_y
		packs.append({"id": "pack_%d" % k, "k": k, "string": k / N, "place": k % N,
			"pos": Vector3(x, y, 0.0), "term_pos": Vector3(x, y, 0.0) + t_pos,
			"term_neg": Vector3(x, y, 0.0) + t_neg})
	var span_x := float(cols - 1) * step_x + pw
	var top_y := y0 + float(levels - 1) * step_y + ph
	var front_z := pb.end.z
	# Bus: two bars (or a distributor) the strings land on.
	var i_string := float(pe["cont_discharge_a"])
	var i_bank := i_string * float(M)
	var bars: Dictionary = {}
	var bus_axis := "y" if mount == "cabinet" else "x"
	var chan_z := front_z + 70.0
	var bus_pos_line := 0.0
	var bus_neg_line := 0.0
	var bar_lo := 0.0
	var bar_hi := 0.0
	var bus_pick := bus_bar_for(b, i_bank)
	if mount == "cabinet":
		bus_pos_line = span_x * 0.5 + 70.0
		bus_neg_line = span_x * 0.5 + 120.0
		bar_lo = y0
		bar_hi = top_y
	else:
		bus_pos_line = (y0 - 90.0) if not on_top else (top_y + 120.0)
		bus_neg_line = bus_pos_line - 50.0 if not on_top else bus_pos_line + 50.0
		if mount == "floor" or mount == "cart":
			bus_pos_line = top_y + 120.0
			bus_neg_line = top_y + 170.0
		bar_lo = -span_x * 0.5
		bar_hi = span_x * 0.5
	if bus == "distributor":
		# A box at the right-hand end: everything lands on its short bars.
		var bx := span_x * 0.5 + 180.0
		bars = {"kind": "distributor", "box": AABB(Vector3(bx - 90.0, y0, front_z - 60.0), Vector3(180.0, 220.0, 120.0)),
			"pos": Vector3(bx, y0 + 160.0, front_z + 10.0), "neg": Vector3(bx, y0 + 60.0, front_z + 10.0)}
	else:
		bars = {"kind": "busbar", "axis": bus_axis, "w": float(bus_pick["w"]), "t": float(bus_pick["t"]),
			"n": int(bus_pick["n"]), "amps": float(bus_pick["amps"]), "auto": bool(bus_pick["auto"]),
			"pos_line": bus_pos_line, "neg_line": bus_neg_line, "lo": bar_lo, "hi": bar_hi, "z": chan_z}
	# The string ends: + at its first pack, − at its last (series joins between).
	var cables: Array = []
	var strings: Array = []
	var w_str := BattElectrical.wire_for(i_string * 1.25)
	var w_main := BattElectrical.wire_for(i_bank * 1.25)
	var r_pack := float(pe["r_ohm"])
	var v_bank := float(pe["v_nom"]) * float(N)
	# Take-offs to the inverter: diagonal = + at the bar's high end, − at the low.
	var take_pos := bar_hi
	var take_neg := bar_lo if str(b["wiring"]) == "diagonal" else bar_hi
	for j in M:
		var first: Dictionary = packs[j * N]
		var last: Dictionary = packs[j * N + N - 1]
		var r_str := r_pack * float(N)
		# Series jumpers inside the string.
		for s in range(N - 1):
			var a: Dictionary = packs[j * N + s]
			var c2: Dictionary = packs[j * N + s + 1]
			var cb := _cable("series_%d_%d" % [j, s], "series", a["term_neg"], c2["term_pos"], on_top, chan_z,
				w_str, i_string, "black", "%s − to %s +" % [_pname(a), _pname(c2)])
			_size_for_drop(cb, v_bank)
			cables.append(cb)
			r_str += float(cb["r_ohm"])
		var land_p := _landing(bars, first["term_pos"], "pos")
		var land_n := _landing(bars, last["term_neg"], "neg")
		var cp := _cable("str_pos_%d" % j, "pos", first["term_pos"], land_p, on_top, chan_z, w_str, i_string,
			"red", "String %d + to the %s" % [j + 1, "distributor" if bus == "distributor" else "positive bar"])
		var cn := _cable("str_neg_%d" % j, "neg", last["term_neg"], land_n, on_top, chan_z, w_str, i_string,
			"black", "String %d − to the %s" % [j + 1, "distributor" if bus == "distributor" else "negative bar"])
		_size_for_drop(cp, v_bank)
		_size_for_drop(cn, v_bank)
		cables.append(cp)
		cables.append(cn)
		strings.append({"j": j, "r_ohm": r_str, "fuse": "fuse_%d" % j, "cp": cp, "cn": cn,
			"land_p": land_p, "land_n": land_n})
	if str(b["wiring"]) == "equal_len":
		var longest := 0.0
		for st0 in strings:
			longest = maxf(longest, maxf(float(st0["cp"]["len_mm"]), float(st0["cn"]["len_mm"])))
		for st0 in strings:
			for cbx in [st0["cp"], st0["cn"]]:
				cbx["len_mm"] = longest
				cbx["r_ohm"] = BattElectrical.resistance("copper", longest, float(cbx["mm2"]))
				cbx["coiled"] = true
	for st1 in strings:
		var j := int(st1["j"])
		var r_str := float(st1["r_ohm"]) + float(st1["cp"]["r_ohm"]) + float(st1["cn"]["r_ohm"])
		var land_p: Vector3 = st1["land_p"]
		var land_n: Vector3 = st1["land_n"]
		# The bar between the landing and the take-off.
		if bus == "busbar":
			var area := float(bars["w"]) * float(bars["t"]) * float(bars["n"])
			var lp := absf(_along(bars, land_p) - take_pos)
			var ln := absf(_along(bars, land_n) - take_neg)
			r_str += BattElectrical.resistance("copper", lp, area) + BattElectrical.resistance("copper", ln, area)
		st1["r_ohm"] = r_str
		st1.erase("cp")
		st1.erase("cn")
		st1.erase("land_p")
		st1.erase("land_n")
	var g_sum := 0.0
	for st in strings:
		g_sum += 1.0 / float(st["r_ohm"])
	var max_share := 0.0
	var min_share := 1.0
	for st in strings:
		st["share"] = (1.0 / float(st["r_ohm"])) / g_sum
		max_share = maxf(max_share, float(st["share"]))
		min_share = minf(min_share, float(st["share"]))
	# Main cables to the inverter (the run the player typed).
	var routed := float(b.get("main_routed_m", -1.0)) > 0.0
	var run := (float(b["main_routed_m"]) if routed else float(b["main_run_m"])) * 1000.0
	var out_p := _take_point(bars, "pos", take_pos)
	var out_n := _take_point(bars, "neg", take_neg)
	var mp := _cable("main_pos", "main", out_p, out_p + Vector3(0, 0, run), false, chan_z, w_main, i_bank,
		"red", "Main + to the inverter")
	var mn := _cable("main_neg", "main", out_n, out_n + Vector3(0, 0, run), false, chan_z, w_main, i_bank,
		"black", "Main − to the inverter")
	# A straight run out: the length as typed, or as routed in 3D to the
	# placed inverter (the run's real path is drawn by the conduit system).
	for mc in [mp, mn]:
		mc["routed"] = routed
		if routed:
			mc["label"] = str(mc["label"]) + " (routed in 3D)"
			# The conduit system draws the run; the bank draws its first stretch.
			var p0: Vector3 = (mc["pts"] as Array)[0]
			mc["pts"] = [p0, p0 + Vector3(0, 0, minf(run, ROUTED_STUB_MM))]
		mc["len_mm"] = run + LUG_SLACK_MM
		mc["r_ohm"] = BattElectrical.resistance("copper", float(mc["len_mm"]), float(mc["mm2"]))
		mc["drop_pct"] = float(mc["r_ohm"]) * i_bank / maxf(float(pe["v_nom"]) * float(N), 1.0) * 100.0
	cables.append(mp)
	cables.append(mn)
	# Voltage-drop pass on the main run (the strings were sized as they were made).
	_size_for_drop(mp, v_bank)
	_size_for_drop(mn, v_bank)
	# The fault current: the bank shorted at its terminals.
	var r_par := 1.0 / g_sum
	var r_bank := r_par + float(mp["r_ohm"]) + float(mn["r_ohm"])
	var i_sc := v_bank / maxf(r_par, 1e-6)
	var fuse := _pick_fuse(str(b["fuse"]), float(pe["v_max"]) * float(N), i_sc / float(M), i_sc, i_string,
		bool(pd["lithium"]))
	var fuses: Array = []
	if not fuse.is_empty():
		for j in M:
			var fp: Vector3 = (packs[j * N] as Dictionary)["term_pos"]
			fuses.append({"id": "fuse_%d" % j, "pos": fp + (Vector3(0, 60, 40) if on_top else Vector3(60, 0, 50)),
				"amps": float(fuse["amps"]), "type": str(fuse["type"])})
	# Comms: a patch cable pack to pack, then to the inverter, terminator at the end.
	var comms: Array = []
	var talks: Array = (pd["bms"] as Dictionary).get("comms", [])
	var has_comms := bool(b["comms"]) and count > 1 and (talks.has("CAN") or talks.has("RS485"))
	if has_comms:
		for k in range(count - 1):
			var a2: Dictionary = packs[k]
			var c3: Dictionary = packs[k + 1]
			var pa: Vector3 = (a2["pos"] as Vector3) + Vector3(-pw * 0.3, ph * 0.5, pb.end.z)
			var pc: Vector3 = (c3["pos"] as Vector3) + Vector3(-pw * 0.3, ph * 0.5, pb.end.z)
			comms.append({"id": "comms_%d" % k, "a": pa, "b": pc,
				"len_mm": maxf(500.0, pa.distance_to(pc) + 200.0), "addr": k + 1})
	# Frame parts for the builder and the BOM.
	var frame := _frame(mount, span_x, top_y, pb, y0, count, ph)
	var outer := AABB(Vector3(-span_x * 0.5, 0.0, pb.position.z), Vector3(span_x, top_y, pdp))
	for f in (frame["boxes"] as Array):
		outer = outer.merge(f["box"] as AABB)
	if bus == "distributor":
		outer = outer.merge(bars["box"] as AABB)
	var cont_bank := i_string / maxf(max_share, 1e-9)
	var e := {
		"v_nom": v_bank, "v_max": float(pe["v_max"]) * float(N), "v_min": float(pe["v_min"]) * float(N),
		"v_absorb": float(pe["v_absorb"]) * float(N), "v_float": float(pe["v_float"]) * float(N),
		"ah": float(pe["ah"]) * float(M), "wh": float(pe["wh"]) * float(count),
		"usable_wh": float(pe["usable_wh"]) * float(count),
		"cont_discharge_a": minf(cont_bank, i_bank), "cont_charge_a": minf(float(pe["cont_charge_a"]) / maxf(max_share, 1e-9), float(pe["cont_charge_a"]) * float(M)),
		"string_a": i_string, "r_ohm": r_bank, "i_sc": i_sc, "max_share": max_share, "min_share": min_share,
		"packs": count,
	}
	var withstand := _withstand(cables, bars, fuse, i_sc, M, bus)
	var d := {"spec": b, "pack": pd, "mount": mount, "bus": bus, "bars": bars, "packs": packs, "cables": cables,
		"withstand": withstand, "main_routed": routed,
		"strings": strings, "fuse": fuse, "fuses": fuses, "comms": comms, "frame": frame,
		"bounds": outer, "electrical": e, "on_top": on_top, "series": N, "parallel": M,
		"wire_string": w_str, "wire_main": w_main}
	var bom := BattBom.bank(d)
	d["bom"] = bom
	d["cost_usd"] = float(bom["total_usd"])
	d["mass_kg"] = float(bom["mass_kg"])
	d["checks"] = _checks(d)
	return d


## The bus bar for a bank current: the player's size (or the smallest that
## carries it), laid `bus_stack` together (or as many as it takes, ≤ 4).
## {w, t, n, amps (what they carry together), auto}.
static func bus_bar_for(b: Dictionary, i_bank: float) -> Dictionary:
	var pick := str(b.get("bus_bar", "auto"))
	# Battery circuits are sized at 125 % of the continuous current.
	var i_size := i_bank * 1.25
	var want_n := int(b.get("bus_stack", 0))
	var size: Array = []
	if pick != "auto":
		size = [float(pick.get_slice("x", 0)), float(pick.get_slice("x", 1))]
	var n := maxi(1, want_n)
	if size.is_empty():
		if want_n > 0:
			# The smallest bar that, n together, carries it.
			for bb in BattElectrical.BUSBARS:
				size = bb
				if BattElectrical.busbar_amps(float(bb[0]), float(bb[1])) * float(STACK_FACTOR[n]) >= i_size:
					break
		else:
			n = 1
			size = BattElectrical.busbar_for(i_size)
			while BattElectrical.busbar_amps(float(size[0]), float(size[1])) * float(STACK_FACTOR[n]) < i_size \
					and n < BankSpec.MAX_STACK:
				n += 1
	elif want_n == 0:
		n = 1
		while BattElectrical.busbar_amps(float(size[0]), float(size[1])) * float(STACK_FACTOR[n]) < i_size \
				and n < BankSpec.MAX_STACK:
			n += 1
	var amps := BattElectrical.busbar_amps(float(size[0]), float(size[1])) * float(STACK_FACTOR[n])
	return {"w": float(size[0]), "t": float(size[1]), "n": n, "amps": amps, "auto": pick == "auto"}


## How long a fuse of `type` takes to blow at `x` times its rating (s); INF
## at or below 1.1 ×.
static func fuse_blow_s(type: String, x: float) -> float:
	if x <= 1.1:
		return INF
	var k := float((FUSE_TYPES.get(type, FUSE_TYPES["class_t"]) as Dictionary)["k_blow"])
	var ft: Dictionary = FUSE_TYPES.get(type, FUSE_TYPES["class_t"])
	var d := x * x - 1.21
	return maxf(k / (d * d), float(ft.get("t_min", 0.001)))


## Short-circuit withstand: a short on the bus is fed by every string through
## its own fuse; the bus carries the whole fault current until the fuses
## blow, each string cable its share. S_min = I·√t / k (adiabatic).
static func _withstand(cables: Array, bars: Dictionary, fuse: Dictionary, i_sc: float, m: int,
		bus: String) -> Dictionary:
	if fuse.is_empty():
		return {"t_clear": INF, "ok": false, "worst": "", "need_mm2": 0.0, "have_mm2": 0.0}
	var i_str := i_sc / float(maxi(m, 1))
	var t := fuse_blow_s(str(fuse["type"]), i_str / float(fuse["amps"]))
	var out := {"t_clear": t, "ok": true, "worst": "", "need_mm2": 0.0, "have_mm2": 0.0, "i_string": i_str}
	var worst_ratio := 0.0
	for cb in cables:
		if str(cb["kind"]) not in ["pos", "neg"]:
			continue
		var need := i_str * sqrt(t) / K_CABLE
		var ratio := need / maxf(float(cb["mm2"]), 1e-9)
		if ratio > worst_ratio:
			worst_ratio = ratio
			out["worst"] = str(cb["id"])
			out["need_mm2"] = need
			out["have_mm2"] = float(cb["mm2"])
	if bus == "busbar":
		var need_b := i_sc * sqrt(t) / K_BAR
		var have_b := float(bars["w"]) * float(bars["t"]) * float(bars["n"])
		out["bar_need_mm2"] = need_b
		out["bar_have_mm2"] = have_b
		if need_b / have_b > worst_ratio:
			worst_ratio = need_b / have_b
			out["worst"] = "bar_pos"
			out["need_mm2"] = need_b
			out["have_mm2"] = have_b
	out["ok"] = worst_ratio <= 1.0
	return out


static func _pname(p: Dictionary) -> String:
	return "pack %d" % (int(p["k"]) + 1)


## A Manhattan route out of a terminal (up if on top, else forward), along
## the channel, to the landing; its length with lug allowances.
static func _cable(id: String, kind: String, a: Vector3, b: Vector3, on_top: bool, chan_z: float,
		wire: Dictionary, amps: float, color: String, label: String) -> Dictionary:
	var pts: Array = [a]
	var out := a + (Vector3(0, STUB_MM, 0) if on_top else Vector3(0, 0, STUB_MM))
	pts.append(out)
	if on_top:
		pts.append(Vector3(b.x, out.y, out.z))
		pts.append(Vector3(b.x, out.y, b.z))
	else:
		var cz := maxf(out.z, chan_z if kind != "series" else out.z)
		pts.append(Vector3(out.x, out.y, cz))
		pts.append(Vector3(b.x, out.y, cz))
		pts.append(Vector3(b.x, b.y, cz))
	pts.append(b)
	var clean: Array = [pts[0]]
	for p in pts.slice(1):
		if (p as Vector3).distance_to(clean[-1]) > 0.5:
			clean.append(p)
	var L := 0.0
	for i in range(1, clean.size()):
		L += (clean[i] as Vector3).distance_to(clean[i - 1])
	L += LUG_SLACK_MM
	var r := BattElectrical.resistance("copper", L, float(wire["mm2"]))
	return {"id": id, "kind": kind, "pts": clean, "len_mm": L, "gauge": str(wire["name"]), "mm2": float(wire["mm2"]),
		"amps": amps, "r_ohm": r, "color": color, "label": label, "drop_pct": 0.0}


static func _size_for_drop(cb: Dictionary, v: float) -> void:
	for i in 20:
		var drop := float(cb["amps"]) * float(cb["r_ohm"]) / maxf(v, 1.0)
		cb["drop_pct"] = drop * 100.0
		if drop <= DROP_MAX:
			return
		var nxt := _next_wire(float(cb["mm2"]))
		if nxt.is_empty():
			return
		cb["gauge"] = str(nxt[0])
		cb["mm2"] = float(nxt[1])
		cb["r_ohm"] = BattElectrical.resistance("copper", float(cb["len_mm"]), float(cb["mm2"]))
		cb["upsized"] = true


static func _next_wire(mm2: float) -> Array:
	for w in BattElectrical.WIRES:
		if float(w[1]) > mm2 + 1e-6:
			return w
	return []


static func _landing(bars: Dictionary, t: Vector3, pole: String) -> Vector3:
	if str(bars["kind"]) == "distributor":
		return bars[pole]
	var line := float(bars["%s_line" % pole])
	if str(bars["axis"]) == "y":
		return Vector3(line, t.y, float(bars["z"]))
	return Vector3(clampf(t.x, float(bars["lo"]), float(bars["hi"])), line, float(bars["z"]))


static func _along(bars: Dictionary, p: Vector3) -> float:
	return p.y if str(bars["axis"]) == "y" else p.x


static func _take_point(bars: Dictionary, pole: String, at: float) -> Vector3:
	if str(bars["kind"]) == "distributor":
		return (bars[pole] as Vector3) + Vector3(0, 0, 30)
	var line := float(bars["%s_line" % pole])
	if str(bars["axis"]) == "y":
		return Vector3(line, at, float(bars["z"]))
	return Vector3(at, line, float(bars["z"]))


static func _pick_fuse(want: String, v_max: float, _i_sc_string: float, i_sc: float, i_string: float,
		lithium: bool) -> Dictionary:
	if want == "none":
		return {}
	var t := want
	if t == "auto":
		t = "class_t"
		if v_max <= 58.0 and i_sc <= 10000.0:
			t = "mrbf"
		if not lithium and v_max <= 32.0 and i_sc <= 6000.0:
			t = "anl"
	var ft: Dictionary = FUSE_TYPES[t]
	var need := i_string * 1.25
	var amps := float((ft["sizes"] as Array)[-1])
	for a in (ft["sizes"] as Array):
		if float(a) >= need:
			amps = float(a)
			break
	return {"type": t, "label": str(ft["label"]), "amps": amps, "ka": float(ft["ka"]), "v": float(ft["v"]),
		"usd": float(ft["usd"]), "holder_usd": float(ft["holder_usd"])}


## The structure the packs stand in: boxes {id, kind, box, label}.
static func _frame(mount: String, span_x: float, top_y: float, pb: AABB, y0: float, count: int,
		ph: float) -> Dictionary:
	var boxes: Array = []
	var front := pb.end.z
	var back := pb.position.z
	var u := 0
	match mount:
		"cabinet":
			u = int(ceil((top_y - y0) / 44.45)) + 4
			var h := y0 + float(u) * 44.45 + 60.0
			var w := CABINET_W
			var dp := maxf(800.0, (front - back) + 250.0)
			var zc := (front + back) * 0.5 - 20.0
			var t := 18.0
			for side in [-1.0, 1.0]:
				boxes.append({"id": "cab_side_%d" % int(side), "kind": "cabinet", "label": "Cabinet side",
					"box": AABB(Vector3(side * w * 0.5 - (t if side > 0 else 0.0), 0, zc - dp * 0.5), Vector3(t, h, dp))})
			boxes.append({"id": "cab_top", "kind": "cabinet", "label": "Cabinet top",
				"box": AABB(Vector3(-w * 0.5, h - t, zc - dp * 0.5), Vector3(w, t, dp))})
			boxes.append({"id": "cab_base", "kind": "cabinet", "label": "Cabinet plinth",
				"box": AABB(Vector3(-w * 0.5, 0, zc - dp * 0.5), Vector3(w, 60.0, dp))})
			boxes.append({"id": "cab_back", "kind": "cabinet", "label": "Cabinet back",
				"box": AABB(Vector3(-w * 0.5, 0, zc - dp * 0.5), Vector3(w, h, 4.0))})
			for side in [-1.0, 1.0]:
				boxes.append({"id": "rail_%d" % int(side), "kind": "rail", "label": "19\" rail",
					"box": AABB(Vector3(side * 241.3 - 8.0, 60.0, front - 6.0), Vector3(16.0, h - 80.0, 4.0))})
		"wall":
			boxes.append({"id": "wall", "kind": "wall", "label": "The wall",
				"box": AABB(Vector3(-span_x * 0.5 - 400.0, 0, back - 120.0), Vector3(span_x + 800.0, top_y + 600.0, 100.0))})
		"shelf":
			var levels := ceili(float(count) / float(mini(count, PER_ROW)))
			for lv in levels:
				var y := y0 + float(lv) * (ph + SHELF_STEP_MM) - 30.0
				boxes.append({"id": "shelf_%d" % lv, "kind": "shelf", "label": "Shelf",
					"box": AABB(Vector3(-span_x * 0.5 - 40.0, y, back - 30.0), Vector3(span_x + 80.0, 30.0, front - back + 60.0))})
			for cx in [-1.0, 1.0]:
				for cz in [-1.0, 1.0]:
					boxes.append({"id": "post_%d_%d" % [int(cx), int(cz)], "kind": "shelf", "label": "Shelf upright",
						"box": AABB(Vector3(cx * (span_x * 0.5 + 40.0) - 20.0, 0, (front if cz > 0 else back) + (0.0 if cz > 0 else -30.0)),
							Vector3(40.0, top_y + 60.0, 30.0))})
		"cart":
			boxes.append({"id": "cart_deck", "kind": "cart", "label": "Cart deck",
				"box": AABB(Vector3(-span_x * 0.5 - 60.0, CART_DECK_MM - 30.0, back - 60.0), Vector3(span_x + 120.0, 30.0, front - back + 120.0))})
			boxes.append({"id": "cart_handle", "kind": "cart", "label": "Handle",
				"box": AABB(Vector3(span_x * 0.5 + 60.0, CART_DECK_MM, back - 60.0), Vector3(30.0, 900.0, 30.0))})
		_:
			boxes.append({"id": "mat", "kind": "floor", "label": "Rubber mat",
				"box": AABB(Vector3(-span_x * 0.5 - 60.0, 0, back - 60.0), Vector3(span_x + 120.0, 6.0, front - back + 120.0))})
	return {"boxes": boxes, "u": u, "mount": mount}


static func _checks(d: Dictionary) -> Array:
	var out: Array = []
	var b: Dictionary = d["spec"]
	var pd: Dictionary = d["pack"]
	var e: Dictionary = d["electrical"]
	var N := int(d["series"])
	var M := int(d["parallel"])
	var bms: Dictionary = pd["bms"]
	if N > 1 and bool(pd["lithium"]) and str(bms.get("switch", "fet")) != "contactor":
		out.append({"level": "error", "text": "These packs can't go in series.",
			"why": "Their BMS switches are rated for one pack's voltage: in series, a pack that trips has the whole string's voltage across its FETs. Put them in parallel, or build one higher-voltage pack (or use a contactor BMS).",
			"ids": ["series_0_0"]})
	if M > 1 and e["max_share"] / maxf(float(e["min_share"]), 1e-9) > 1.05:
		var worst := 0
		for st in (d["strings"] as Array):
			if float(st["share"]) > float((d["strings"] as Array)[worst]["share"]):
				worst = int(st["j"])
		out.append({"level": "warn", "text": "The strings don't share evenly: %.0f %% to %.0f %% of the current." % [
			float(e["min_share"]) * 100.0, float(e["max_share"]) * 100.0],
			"why": ("Current takes the path of least resistance. String %d's cables are shortest, so it works hardest and wears first. " % (worst + 1)) + ("Cut every string's cables to the same length (Wiring: same length)." if str(d["bus"]) == "distributor" else "Take the + off one end of the bus and the − off the other (Wiring: diagonal), or cut every string's cables to the same length."),
			"ids": ["str_pos_%d" % worst]})
	var fuse: Dictionary = d["fuse"]
	if fuse.is_empty():
		out.append({"level": "error" if bool(pd["lithium"]) else "warn", "text": "No fuse on the strings.",
			"why": "A shorted cable can draw thousands of amps from a bank (%s A here) and start a fire before anything else reacts. Fit a fuse at each string's positive." % UiText.thousands(int(e["i_sc"])), "ids": []})
	else:
		if float(fuse["ka"]) * 1000.0 < float(e["i_sc"]):
			if str(fuse["type"]) == "class_t":
				out.append({"level": "warn", "text": "The bank's fault current (%s A) is above even a Class T fuse's 20 kA." % UiText.thousands(int(e["i_sc"])),
					"why": "A short on the bus is fed by every string at once. Split the bank into two banks with their own main fuse, or use a DC breaker rated for this fault current at the bus.",
					"ids": ["fuse_0"]})
			else:
				out.append({"level": "error", "text": "The %s fuses can't interrupt this bank's fault current." % fuse["label"],
					"why": "The bank can push about %s A into a short; a %s fuse is rated to break %.0f kA. Above that it can arc on and not clear. Use Class T." % [UiText.thousands(int(e["i_sc"])), fuse["label"], float(fuse["ka"])],
					"ids": ["fuse_0"]})
		if float(fuse["v"]) < float(e["v_max"]):
			out.append({"level": "error", "text": "The %s fuses are rated for %.0f V DC; the bank charges to %.1f V." % [fuse["label"], float(fuse["v"]), float(e["v_max"])],
				"why": "A fuse used above its voltage rating may not put out the arc when it blows.", "ids": ["fuse_0"]})
	# The bus: does it carry the bank's current?
	var bars: Dictionary = d["bars"]
	var i_need := maxf(float(e["cont_discharge_a"]), float(e["cont_charge_a"]))
	if str(bars["kind"]) == "distributor":
		if i_need > DIST_RATING_A:
			out.append({"level": "error", "text": "The distributor's %.0f A bus can't carry this bank's %.0f A." % [DIST_RATING_A, i_need],
				"why": "A distributor box is sold with a current rating for its own bars. Use a busbar pair sized for the bank, or split the bank.",
				"ids": ["distributor"]})
	else:
		var ba := float(bars["amps"])
		var bar_words := "%s%.0f × %.0f mm" % [("%d × " % int(bars["n"])) if int(bars["n"]) > 1 else "", float(bars["w"]), float(bars["t"])]
		if ba < i_need:
			out.append({"level": "error", "text": "The busbars (%s) carry about %.0f A; the bank can push %.0f A." % [bar_words, ba, i_need],
				"why": "Near the take-off every string's current is on the bar at once. A bar run past its rating gets hot (DIN 43671 rates bars for a 30 K rise). Use a bigger bar, or more bars laid together.",
				"ids": ["bar_pos"]})
		elif ba < i_need * 1.25:
			out.append({"level": "warn", "text": "The busbars (%s) have little margin: %.0f A for a %.0f A bank." % [bar_words, ba, i_need],
				"why": "Battery circuits are sized at 125 % of the continuous current (NEC 690.8 practice). A size up gives the bus that margin.",
				"ids": ["bar_pos"]})
		if int(bars["n"]) >= BankSpec.MAX_STACK and ba < i_need:
			out.append({"level": "info", "text": "Even four of the biggest bars are short of this bank's current.",
				"why": "Split the bank into two banks, each with its own bus and main cables.", "ids": []})
	var ws: Dictionary = d.get("withstand", {})
	if not fuse.is_empty() and not ws.is_empty() and not bool(ws["ok"]):
		var on_bar := str(ws["worst"]).begins_with("bar")
		out.append({"level": "warn", "text": "A short on the bus would overheat the %s before the fuses blow." % ("busbars" if on_bar else "string cables"),
			"why": "Each %s fuse sees %s A and takes about %s to blow; that needs %.0f mm² of copper and the %s has %.0f mm² (S = I√t / k, IEC 60364-5-54). Faster fuses (Class T) or a heavier %s." % [
				fuse["label"], UiText.thousands(int(ws.get("i_string", 0.0))), BattSim.time_words(float(ws["t_clear"])),
				float(ws["need_mm2"]), "bar" if on_bar else "cable", float(ws["have_mm2"]), "bar" if on_bar else "cable"],
			"ids": [str(ws["worst"])]})
	for cb in (d["cables"] as Array):
		if float(cb["drop_pct"]) > DROP_MAX * 100.0 + 0.05 and str(cb["kind"]) == "main":
			out.append({"level": "warn", "text": "The run to the inverter loses %.1f %% at full current." % float(cb["drop_pct"]),
				"why": "Even the biggest cable in the table drops more than 1 %% over %.1f m: move the bank closer to the inverter." % (float(cb["len_mm"]) * 0.001),
				"ids": [str(cb["id"])]})
			break
	var mount := str(d["mount"])
	var pm := float(pd["mass_kg"])
	if mount == "wall" and pm > 70.0:
		out.append({"level": "warn", "text": "Each pack weighs %.0f kg: heavy for wall brackets." % pm,
			"why": "Wall brackets lag-bolted into two studs are commonly good for 70–90 kg (an estimate). Stand heavier packs on the floor or a stand.", "ids": []})
	if mount == "cabinet" and int(d["frame"]["u"]) > 42:
		out.append({"level": "error", "text": "%d packs don't fit one 42U cabinet." % int(e["packs"]),
			"why": "Split them into two cabinets, or use bigger packs.", "ids": []})
	if not bool(pd["lithium"]):
		var cells := int(pd["electrical"]["cells_series"]) * int(e["packs"])
		out.append({"level": "info", "text": "Ventilate: %.2f m³/h of air while charging." % BattChem.ventilation_m3h(
			str(pd["chem"]), cells, float(pd["electrical"]["ah"]), "boost"),
			"why": "Lead-acid gives off hydrogen near full charge (IEC 62485-2). Keep the space vented and sparks away.", "ids": []})
	if float(e["v_max"]) > 60.0:
		out.append({"level": "info", "text": "Above 60 V DC: treat it as a shock hazard.",
			"why": "Below 60 V DC is usually counted as safe to touch; above it, cover the terminals and the bus.", "ids": []})
	var mass := float(d["mass_kg"])
	var fp: AABB = d["bounds"]
	var area := maxf(fp.size.x * fp.size.z * 1e-6, 0.05)
	if mass / area > 1200.0:
		out.append({"level": "info", "text": "%.0f kg on %.2f m² (%.0f kg/m²): check the floor." % [mass, area, mass / area],
			"why": "A typical home floor is designed for about 200 kg/m² spread out (an estimate); a heavy bank on a small footprint may need a slab.", "ids": []})
	return out


## The bank as one graph battery's specs.
static func graph_specs(d: Dictionary) -> Dictionary:
	var e: Dictionary = d["electrical"]
	var pd: Dictionary = d["pack"]
	var g := BattDesign.graph_specs(pd)
	g["name"] = str((d["spec"] as Dictionary)["name"])
	g["voltage"] = snappedf(float(e["v_nom"]), 0.01)
	g["ah"] = snappedf(float(e["ah"]), 0.01)
	g["kwh"] = snappedf(float(e["wh"]) * 0.001, 0.001)
	g["max_charge_a"] = snappedf(float(e["cont_charge_a"]), 0.1)
	g["max_discharge_a"] = snappedf(float(e["cont_discharge_a"]), 0.1)
	g["cost"] = snappedf(float(d["cost_usd"]), 1.0)
	g["bank_series"] = int(d["series"])
	g["bank_parallel"] = int(d["parallel"])
	return g


static func packed_spec(d: Dictionary) -> Dictionary:
	var p := BattDesign.packed_spec(d["pack"])
	p["count"] = int(d["electrical"]["packs"])
	return p
