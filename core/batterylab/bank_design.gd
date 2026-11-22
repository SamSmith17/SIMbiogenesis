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
## Bus hardware, mm (proportions of maker drawings: estimates). Studs on
## the distributor are this far apart; the − bar stands this much further
## out than the + so − cables pass in front of the + bar; standoff
## insulators hold the bars off their board; bars run this far past the
## outermost landing; the take-off sits this far past the last landing.
const STUD_PITCH_MM := 50.0
## How far past the + bar a bus-mounted fuse holder reaches.
const FUSE_REACH_MM := 170.0
const NEG_STEP_MM := 40.0
const STANDOFF_MM := 30.0
const BAR_OVERHANG_MM := 60.0
const TAKE_OUT_MM := 25.0
const BAR_STUD_MM := 10.0
const MRBF_STUD_MM := 10.0
## SAE post (J537): a clamp's ring round its middle, radius ≈ 8.75 mm.
const POST_R_MM := 8.75
## A rotary battery disconnect switch: its body length along the bar and
## how far its output stud stands off.
const DISCONNECT_W_MM := 110.0
const DISCONNECT_H_MM := 55.0
## Points along each cable curve.
const CURVE_SAMPLES := 24
## Fuse bodies: stud pitch (input to output), height off the face, stud Ø,
## width (Class T holder, ANL holder, MRBF terminal block, MEGA fuse).
const FUSE_DIMS := {
	"class_t": {"pitch": 125.0, "h": 45.0, "stud": 10.0, "w": 55.0},
	"anl": {"pitch": 95.0, "h": 35.0, "stud": 8.0, "w": 42.0},
	"mrbf": {"pitch": 32.0, "h": 23.0, "stud": 10.0, "w": 30.0},
	"mega": {"pitch": 60.0, "h": 18.0, "stud": 8.0, "w": 20.0},
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
	var t_pos: Vector3 = term.get("pos_out", term.get("pos", Vector3(pw * 0.3, ph, 0)))
	var t_neg: Vector3 = term.get("neg_out", term.get("neg", Vector3(-pw * 0.3, ph, 0)))
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
			"term_neg": Vector3(x, y, 0.0) + t_neg, "out_pos": Vector3(x, y, 0.0) + t_pos,
			"out_neg": Vector3(x, y, 0.0) + t_neg})
	# A drag stores bank["nudge"]["pack_k"] in the same millimetres. Cables
	# are routed from the terminals after this, so they follow the pack.
	var pack_nudged := false
	for p in packs:
		var n := BattLayout.nudge_of(b, str(p["id"]))
		if n == Vector3.ZERO:
			continue
		pack_nudged = true
		for key in ["pos", "term_pos", "term_neg", "out_pos", "out_neg"]:
			p[key] = (p[key] as Vector3) + n
	var span_x := float(cols - 1) * step_x + pw
	var top_y := y0 + float(levels - 1) * step_y + ph
	var front_z := pb.end.z
	# Bus: two bars (or a distributor) the strings land on. Cables are sized
	# first: how tightly they can bend sets how far out the bus stands.
	var i_string := float(pe["cont_discharge_a"])
	var i_bank := i_string * float(M)
	var w_str := BattElectrical.wire_for(i_string * 1.25)
	var w_main := BattElectrical.wire_for(i_bank * 1.25)
	var r_str := BattWire.bend_r_mm(BattWire.od_mm(str(w_str["name"]), float(w_str["mm2"])), "battery")
	var bars: Dictionary = {}
	var bus_axis := "y" if mount == "cabinet" else "x"
	var chan_z := front_z + maxf(70.0, r_str * 1.5)
	var bus_pos_line := 0.0
	var bus_neg_line := 0.0
	var bar_lo := 0.0
	var bar_hi := 0.0
	var bus_pick := bus_bar_for(b, i_bank)
	var bw := float(bus_pick["w"])
	var tn := float(bus_pick["t"]) * float(bus_pick["n"])
	var sp := maxf(50.0, bw + 30.0)
	# The − bar stands nearer the packs, the + bar outside it with its fuse
	# holders reaching away from the packs.
	if mount == "cabinet":
		bus_neg_line = span_x * 0.5 + 45.0 + bw * 0.5
		bus_pos_line = bus_neg_line + sp
		bar_lo = y0
		bar_hi = top_y
	else:
		var below := y0 - 60.0 - bw * 0.5
		if on_top or mount == "floor" or mount == "cart" or below - sp - bw * 0.5 - FUSE_REACH_MM < 40.0:
			bus_neg_line = top_y + 90.0 + bw * 0.5
			bus_pos_line = bus_neg_line + sp
		else:
			bus_neg_line = below
			bus_pos_line = below - sp
		bar_lo = -span_x * 0.5
		bar_hi = span_x * 0.5
	var bus_right := span_x * 0.5
	if bus == "distributor":
		# A box at the right-hand end: a stud pair per string and one for the
		# main cables, string fuses between the rows, room for the switch.
		var slots := M + 1
		var wd := float(slots) * STUD_PITCH_MM + 80.0 + (DISCONNECT_W_MM if bool(b["disconnect"]) else 0.0)
		var bx := span_x * 0.5 + 80.0 + wd * 0.5
		var box := AABB(Vector3(bx - wd * 0.5, y0, front_z - 60.0), Vector3(wd, 220.0, 120.0))
		var ps: Array = []
		var ns: Array = []
		for k in slots:
			var sx := box.position.x + 40.0 + STUD_PITCH_MM * (float(k) + 0.5)
			ps.append(Vector3(sx, y0 + 175.0, box.end.z))
			ns.append(Vector3(sx, y0 + 45.0, box.end.z))
		bars = {"kind": "distributor", "box": box, "pos_studs": ps, "neg_studs": ns, "n_face": Vector3(0, 0, 1),
			"pos": ps[M], "neg": ns[M]}
		bus_right = box.end.x
	else:
		bars = {"kind": "busbar", "axis": bus_axis, "w": bw, "t": float(bus_pick["t"]),
			"n": int(bus_pick["n"]), "amps": float(bus_pick["amps"]), "auto": bool(bus_pick["auto"]),
			"pos_line": bus_pos_line, "neg_line": bus_neg_line, "lo": bar_lo, "hi": bar_hi, "z": chan_z,
			"z_neg": chan_z, "z_pos": chan_z + tn + NEG_STEP_MM, "tn": tn}
		bars["face_pos"] = chan_z + tn * 0.5
		bars["face_neg"] = float(bars["z_neg"]) + tn * 0.5
		# The board stands flush with the packs' fronts, so every cable runs in
		# front of it; the standoffs make up the depth.
		bars["board_z"] = minf(front_z, chan_z - tn * 0.5 - STANDOFF_MM)
		if mount == "cabinet":
			bus_right = bus_pos_line + bw * 0.5 + (FUSE_REACH_MM if not fuse_guess_none(b) else 0.0)
	# The string ends: + at its first pack, − at its last (series joins between).
	var cables: Array = []
	var strings: Array = []
	var r_pack := float(pe["r_ohm"])
	var v_bank := float(pe["v_nom"]) * float(N)
	var term_kind := str(term.get("out_kind", "stud"))
	var term_n: Vector3 = term.get("n_out", Vector3(0, 0, 1))
	var term_stud := float(term.get("stud", 8.0))
	var fuse := _pick_fuse(str(b["fuse"]), float(pe["v_max"]) * float(N), 0.0, 1.0, i_string, bool(pd["lithium"]))
	# Take-offs to the inverter: diagonal = + at the bar's high end, − at the low.
	var take_pos := bar_hi + TAKE_OUT_MM
	var take_neg := (bar_lo - TAKE_OUT_MM) if str(b["wiring"]) == "diagonal" else (bar_hi + TAKE_OUT_MM)
	var fuses: Array = []
	for j in M:
		var first: Dictionary = packs[j * N]
		var last: Dictionary = packs[j * N + N - 1]
		var rs := r_pack * float(N)
		# Series jumpers inside the string.
		for s in range(N - 1):
			var a: Dictionary = packs[j * N + s]
			var c2: Dictionary = packs[j * N + s + 1]
			var cb := _cable("series_%d_%d" % [j, s], "series",
				_end(term_kind, a["out_neg"], term_n, term_stud), _end(term_kind, c2["out_pos"], term_n, term_stud),
				w_str, i_string, "black", "%s − to %s +" % [_pname(a), _pname(c2)])
			_size_for_drop(cb, v_bank)
			cables.append(cb)
			rs += float(cb["r_ohm"])
		var land_p := _landing(bars, first["out_pos"], "pos", j)
		var land_n := _landing(bars, last["out_neg"], "neg", j)
		var nf := _face_n(bars)
		# The + end of the string cable: the pack's stud, or a terminal fuse on it.
		var pa := _end(term_kind, first["out_pos"], term_n, term_stud)
		var pb_end := _end("stud", land_p, nf, BAR_STUD_MM)
		if not fuse.is_empty():
			var fz := _place_fuse(j, fuse, bars, first["out_pos"], term_n, term_kind, land_p, nf)
			fuses.append(fz)
			if str(fz["mount"]) == "terminal":
				pa = _end("stud", fz["in"], term_n, MRBF_STUD_MM)
			elif str(fz["mount"]) == "bar":
				pb_end = _end("stud", fz["in"], nf, float(fz["stud"]))
		var cp := _cable("str_pos_%d" % j, "pos", pa, pb_end, w_str, i_string,
			"red", "String %d + to the %s" % [j + 1, "distributor" if bus == "distributor" else "positive bar"])
		var cn := _cable("str_neg_%d" % j, "neg", _end(term_kind, last["out_neg"], term_n, term_stud),
			_end("stud", land_n, nf, BAR_STUD_MM), w_str, i_string,
			"black", "String %d − to the %s" % [j + 1, "distributor" if bus == "distributor" else "negative bar"])
		_size_for_drop(cp, v_bank)
		_size_for_drop(cn, v_bank)
		cables.append(cp)
		cables.append(cn)
		strings.append({"j": j, "r_base": rs, "fuse": "fuse_%d" % j, "cp": cp, "cn": cn,
			"land_p": land_p, "land_n": land_n})
	if str(b["wiring"]) == "equal_len":
		_equal_lengths(strings)
	var g_sum := _string_shares(strings, bars, bus, take_pos, take_neg)
	# The fault current: the bank shorted at its bus.
	var r_par := 1.0 / g_sum
	var i_sc := v_bank / maxf(r_par, 1e-6)
	var fuse2 := _pick_fuse(str(b["fuse"]), float(pe["v_max"]) * float(N), i_sc / float(M), i_sc, i_string,
		bool(pd["lithium"]))
	if str(fuse2.get("type", "")) != str(fuse.get("type", "")):
		# The fault current changed the fuse family: redo the + ends with it.
		fuse = fuse2
		fuses = []
		for j in M:
			var first2: Dictionary = packs[j * N]
			var lp2 := _landing(bars, first2["out_pos"], "pos", j)
			var nf2 := _face_n(bars)
			var ea := _end(term_kind, first2["out_pos"], term_n, term_stud)
			var eb := _end("stud", lp2, nf2, BAR_STUD_MM)
			if not fuse.is_empty():
				var fz2 := _place_fuse(j, fuse, bars, first2["out_pos"], term_n, term_kind, lp2, nf2)
				fuses.append(fz2)
				if str(fz2["mount"]) == "terminal":
					ea = _end("stud", fz2["in"], term_n, MRBF_STUD_MM)
				elif str(fz2["mount"]) == "bar":
					eb = _end("stud", fz2["in"], nf2, float(fz2["stud"]))
			var cp2: Dictionary = (strings[j] as Dictionary)["cp"]
			cp2["ends"] = [ea, eb]
			_route_cable(cp2)
			_size_for_drop(cp2, v_bank)
		if str(b["wiring"]) == "equal_len":
			_equal_lengths(strings)
		g_sum = _string_shares(strings, bars, bus, take_pos, take_neg)
		r_par = 1.0 / g_sum
		i_sc = v_bank / maxf(r_par, 1e-6)
	else:
		fuse = fuse2
	var max_share := 0.0
	var min_share := 1.0
	for st in strings:
		max_share = maxf(max_share, float(st["share"]))
		min_share = minf(min_share, float(st["share"]))
		st.erase("cp")
		st.erase("cn")
		st.erase("land_p")
		st.erase("land_n")
		st.erase("r_base")
	# Main cables to the inverter (the run the player typed, or as routed in 3D).
	var routed := float(b.get("main_routed_m", -1.0)) > 0.0
	var run := (float(b["main_routed_m"]) if routed else float(b["main_run_m"])) * 1000.0
	var out_p := _take_point(bars, "pos", take_pos)
	var out_n := _take_point(bars, "neg", take_neg)
	var nfm := _face_n(bars)
	var away := _bar_dir(bars)
	var away_n := -away if str(b["wiring"]) == "diagonal" and bus == "busbar" else away
	var disc: Dictionary = {}
	var main_a := _end("stud", out_p, nfm, BAR_STUD_MM, away)
	if bool(b["disconnect"]):
		disc = {"id": "disconnect", "a": out_p, "n": nfm, "axis": away,
			"b": out_p + away * DISCONNECT_W_MM + nfm * DISCONNECT_H_MM,
			"c": out_p + away * DISCONNECT_W_MM * 0.5 + nfm * DISCONNECT_H_MM * 0.5,
			"amps": maxf(i_bank, 1.0)}
		main_a = _end("stud", disc["b"], nfm, BAR_STUD_MM, away)
		bus_right = maxf(bus_right, (disc["c"] as Vector3).x + DISCONNECT_W_MM)
	var mp := _main_cable("main_pos", main_a, run, routed, w_main, i_bank, "red", "Main + to the inverter")
	var mn := _main_cable("main_neg", _end("stud", out_n, nfm, BAR_STUD_MM, away_n), run, routed, w_main, i_bank,
		"black", "Main − to the inverter")
	_size_for_drop(mp, v_bank)
	_size_for_drop(mn, v_bank)
	cables.append(mp)
	cables.append(mn)
	var r_bank := r_par + float(mp["r_ohm"]) + float(mn["r_ohm"])
	# Comms: a patch cable pack to pack (out of one port, into the next pack's
	# first), the first pack's other port to the inverter, a terminator on the last.
	var comms: Array = []
	var talks: Array = (pd["bms"] as Dictionary).get("comms", [])
	var has_comms := bool(b["comms"]) and count > 1 and (talks.has("CAN") or talks.has("RS485"))
	var ports: Array = []
	for f in (pd["layout"]["fittings"] as Array):
		if str(f["kind"]) == "port":
			ports.append((f["c"] as Vector3) + Vector3(0, 0, (f["s"] as Vector3).z * 0.5))
	if ports.is_empty():
		ports = [Vector3(-pw * 0.3, ph * 0.5, pb.end.z)]
	var p_in: Vector3 = ports[0]
	var p_out: Vector3 = ports[1] if ports.size() > 1 else ports[0] + Vector3(24, 0, 0)
	if has_comms:
		for k in range(count - 1):
			var pa2: Vector3 = (packs[k]["pos"] as Vector3) + p_out
			var pc: Vector3 = (packs[k + 1]["pos"] as Vector3) + p_in
			var path := _patch_path(pa2, pc)
			comms.append({"id": "comms_%d" % k, "a": pa2, "b": pc, "pts": path,
				"len_mm": maxf(500.0, BattWire.length(path) + 60.0), "addr": k + 1})
		var p0: Vector3 = (packs[0]["pos"] as Vector3) + p_in
		var tail := _patch_path(p0, p0 + Vector3(0, -120.0, 260.0))
		comms.append({"id": "comms_inverter", "a": p0, "b": p0 + Vector3(0, -120.0, 260.0), "pts": tail,
			"len_mm": 2000.0, "addr": 0, "to_inverter": true})
	# Frame parts for the builder and the BOM.
	var frame := _frame(mount, span_x, top_y, pb, y0, count, ph, bus_right)
	var outer := AABB(Vector3(-span_x * 0.5, 0.0, pb.position.z), Vector3(span_x, top_y, pdp))
	for f in (frame["boxes"] as Array):
		outer = outer.merge(f["box"] as AABB)
	if bus == "distributor":
		outer = outer.merge(bars["box"] as AABB)
	else:
		outer = outer.merge(_bars_box(bars))
	for cb3 in cables:
		if str(cb3["kind"]) != "main":
			outer = outer.merge(_pts_box(cb3["pts"]))
	if pack_nudged:
		for p2 in packs:
			outer = outer.merge(AABB(pb.position + (p2["pos"] as Vector3), pb.size))
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
		"withstand": withstand, "main_routed": routed, "disconnect": disc,
		"strings": strings, "fuse": fuse, "fuses": fuses, "comms": comms, "frame": frame,
		"bounds": outer, "electrical": e, "on_top": on_top, "series": N, "parallel": M,
		"wire_string": w_str, "wire_main": w_main, "term_kind": term_kind}
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


## One end of a cable: a ring lug on a stud ("stud"), a clamp round an SAE
## post ("post") or a loose end ("free"), at `p` on a face with normal `n`;
## `t` = which way the cable leaves it (in the face plane), else toward the
## other end.
static func _end(kind: String, p: Vector3, n: Vector3, stud: float, t: Vector3 = Vector3.ZERO) -> Dictionary:
	return {"kind": kind, "p": p, "n": n.normalized(), "stud": stud, "t_hint": t}


## A cable from end a to end b: sized, routed, measured.
static func _cable(id: String, kind: String, a: Dictionary, b: Dictionary, wire: Dictionary, amps: float,
		color: String, label: String) -> Dictionary:
	var cb := {"id": id, "kind": kind, "ends": [a, b], "gauge": str(wire["name"]), "mm2": float(wire["mm2"]),
		"amps": amps, "color": color, "label": label, "drop_pct": 0.0}
	_route_cable(cb)
	return cb


## Where a cable leaves an end: the lug's barrel (or the clamp's ear), and
## the direction it heads off in. Fills e["t"], e["s"], e["lug"], e["reach"].
static func _exit(e: Dictionary, mm2: float, toward: Vector3) -> void:
	var p: Vector3 = e["p"]
	var n: Vector3 = e["n"]
	var hint: Vector3 = e.get("t_hint", Vector3.ZERO)
	var t := hint - n * hint.dot(n)
	if t.length() < 1e-3:
		var v := toward - p
		t = v - n * v.dot(n)
		# Side by side on one face: leave upward, an arch over what is between.
		if t.length() > 1e-3 and absf(n.y) < 0.5 and absf(t.normalized().y) < 0.3:
			t = Vector3.UP
	if t.length() < 1e-3:
		t = BattParts.frame(n)[0]
	t = t.normalized()
	e["t"] = t
	match str(e["kind"]):
		"stud":
			var lg := BattWire.lug(mm2, float(e["stud"]))
			e["lug"] = lg
			var lift := float(lg["tongue_t"]) * 0.5 + float(lg["barrel_od"]) * 0.5
			e["s"] = p + n * lift + t * float(lg["reach"])
			e["reach"] = float(lg["reach"])
		"post":
			e["lug"] = {}
			e["reach"] = POST_R_MM + 16.0
			e["s"] = p + t * float(e["reach"])
		_:
			e["lug"] = {}
			e["reach"] = 0.0
			e["s"] = p


## Route a cable between its two ends: out of each barrel along its
## direction, one smooth curve between (a cubic whose handles are as long as
## it takes to keep every bend at or above the cable's minimum radius).
## Sets pts, od, r_bend, min_r, tight, len_mm, r_ohm.
static func _route_cable(cb: Dictionary) -> void:
	var mm2 := float(cb["mm2"])
	var od := BattWire.od_mm(str(cb["gauge"]), mm2)
	var r := BattWire.bend_r_mm(od, "battery")
	var ea: Dictionary = cb["ends"][0]
	var eb: Dictionary = cb["ends"][1]
	_exit(ea, mm2, eb["p"])
	_exit(eb, mm2, ea["p"])
	var res := _route_try(ea, eb, r, float(cb.get("stretch_k", 0.0)))
	if float(res["min_r"]) < r * 0.97 and float(cb.get("stretch_k", 0.0)) <= 0.0:
		# Too tight the obvious way: try the lugs turned the other ways on
		# their faces and keep the gentlest.
		var opts_a := _lug_turns(ea)
		var opts_b := _lug_turns(eb)
		var best_ta: Vector3 = ea["t"]
		var best_tb: Vector3 = eb["t"]
		for ta in opts_a:
			for tb in opts_b:
				_set_lug_dir(ea, ta, mm2)
				_set_lug_dir(eb, tb, mm2)
				var rr := _route_try(ea, eb, r, 0.0)
				if float(rr["min_r"]) > float(res["min_r"]) + 0.5:
					res = rr
					best_ta = ta
					best_tb = tb
				if float(res["min_r"]) >= r:
					break
			if float(res["min_r"]) >= r:
				break
		_set_lug_dir(ea, best_ta, mm2)
		_set_lug_dir(eb, best_tb, mm2)
	cb["pts"] = res["pts"]
	cb["od"] = od
	cb["r_bend"] = r
	cb["min_r"] = res["min_r"]
	cb["tight"] = float(res["min_r"]) < r * 0.97
	cb["k"] = res["k"]
	cb["len_mm"] = BattWire.length(PackedVector3Array(cb["pts"])) + float(ea["reach"]) + float(eb["reach"])
	cb["r_ohm"] = BattElectrical.resistance("copper", float(cb["len_mm"]), mm2)


static func _route_try(ea: Dictionary, eb: Dictionary, r: float, force_k: float) -> Dictionary:
	# Off a top post the cable rises out of its lug rather than lying on the
	# lid (the kink is under the heat-shrink).
	var ta: Vector3 = ea["t"]
	var tb: Vector3 = eb["t"]
	if (ea["n"] as Vector3).y > 0.5:
		ta = (ta + Vector3.UP * 0.7).normalized()
	if (eb["n"] as Vector3).y > 0.5:
		tb = (tb + Vector3.UP * 0.7).normalized()
	return _curve(ea["s"], ta, eb["s"], tb, r, force_k)


## The ways a lug can point on its face: its own way first, then the other
## three right angles (a lug's hint, if any, is kept).
static func _lug_turns(e: Dictionary) -> Array:
	var t: Vector3 = e["t"]
	if (e.get("t_hint", Vector3.ZERO) as Vector3).length() > 1e-3 or str(e["kind"]) == "free":
		return [t]
	var n: Vector3 = e["n"]
	var s := n.cross(t).normalized()
	return [t, s, -s, -t]


static func _set_lug_dir(e: Dictionary, t: Vector3, mm2: float) -> void:
	e["t_hint"] = t
	_exit(e, mm2, e["p"])
	e["t_hint"] = Vector3.ZERO


## A cubic from s (heading ts) to e (arriving against te): the shortest
## handle length that bends no tighter than r, else the gentlest one.
## `force_k` > 0 uses that handle length as given.
static func _curve(s: Vector3, ts: Vector3, e: Vector3, te: Vector3, r: float, force_k: float = 0.0) -> Dictionary:
	var dist := maxf(s.distance_to(e), 1.0)
	var ks: Array = []
	if force_k > 0.0:
		ks = [force_k]
	else:
		for f in [0.25, 0.35, 0.5, 0.65, 0.85, 1.1, 1.4]:
			ks.append(maxf(dist * float(f), r * 0.9))
		# Close ends: a wider loop is the way to a gentle bend.
		for f in [1.2, 1.6, 2.2, 3.0]:
			if r * float(f) > float(ks[-1]):
				ks.append(r * float(f))
	var best := {}
	for k in ks:
		var pts := _bez(s, s + ts * float(k), e + te * float(k), e, CURVE_SAMPLES)
		var mr := BattWire.min_radius(PackedVector3Array(pts))
		if best.is_empty() or mr > float(best["min_r"]):
			best = {"pts": pts, "min_r": mr, "k": float(k)}
		if mr >= r:
			return {"pts": pts, "min_r": mr, "k": float(k)}
	return best


static func _bez(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, n: int) -> Array:
	var out: Array = []
	for i in n + 1:
		var u := float(i) / float(n)
		var v := 1.0 - u
		out.append(p0 * (v * v * v) + p1 * (3.0 * v * v * u) + p2 * (3.0 * v * u * u) + p3 * (u * u * u))
	return out


## Lengthen a cable to `target` mm by giving it longer handles (a bigger,
## gentler loop): how cables cut to one length lie in a real bank. Flags
## it "coiled" when even long handles fall short.
static func _stretch_to(cb: Dictionary, target: float) -> void:
	if float(cb["len_mm"]) >= target - 1.0:
		return
	var lo := float(cb["k"])
	var hi := lo * 6.0 + 400.0
	for i in 22:
		var mid := (lo + hi) * 0.5
		cb["stretch_k"] = mid
		_route_cable(cb)
		if float(cb["len_mm"]) < target:
			lo = mid
		else:
			hi = mid
	cb["stretch_k"] = hi
	_route_cable(cb)
	cb["coiled"] = float(cb["len_mm"]) < target - 5.0


static func _equal_lengths(strings: Array) -> void:
	var longest := 0.0
	for st in strings:
		longest = maxf(longest, maxf(float(st["cp"]["len_mm"]), float(st["cn"]["len_mm"])))
	for st in strings:
		for cbx in [st["cp"], st["cn"]]:
			_stretch_to(cbx, longest)
			cbx["len_mm"] = longest
			cbx["r_ohm"] = BattElectrical.resistance("copper", longest, float(cbx["mm2"]))


## Each string's resistance (packs + jumpers + its two cables + the bar to
## the take-off) and its share of the current. Returns the summed conductance.
static func _string_shares(strings: Array, bars: Dictionary, bus: String, take_pos: float, take_neg: float) -> float:
	for st in strings:
		var r_s := float(st["r_base"]) + float(st["cp"]["r_ohm"]) + float(st["cn"]["r_ohm"])
		if bus == "busbar":
			var area := float(bars["w"]) * float(bars["t"]) * float(bars["n"])
			var lp := absf(_along(bars, st["land_p"]) - take_pos)
			var ln := absf(_along(bars, st["land_n"]) - take_neg)
			r_s += BattElectrical.resistance("copper", lp, area) + BattElectrical.resistance("copper", ln, area)
		st["r_ohm"] = r_s
	var g_sum := 0.0
	for st in strings:
		g_sum += 1.0 / float(st["r_ohm"])
	for st in strings:
		st["share"] = (1.0 / float(st["r_ohm"])) / g_sum
	return g_sum


## A main cable: a lug on the bus (or the switch), a bend out toward the
## inverter, then straight. The bank draws `run` of it, or only a stub when
## the conduit system draws the routed run in 3D.
static func _main_cable(id: String, a: Dictionary, run: float, routed: bool, wire: Dictionary, amps: float,
		color: String, label: String) -> Dictionary:
	var cb := {"id": id, "kind": "main", "ends": [a, {}], "gauge": str(wire["name"]), "mm2": float(wire["mm2"]),
		"amps": amps, "color": color, "label": label + (" (routed in 3D)" if routed else ""), "drop_pct": 0.0,
		"routed": routed, "run": run}
	_route_main(cb)
	return cb


static func _route_main(cb: Dictionary) -> void:
	var mm2 := float(cb["mm2"])
	var od := BattWire.od_mm(str(cb["gauge"]), mm2)
	var r := BattWire.bend_r_mm(od, "battery")
	var ea: Dictionary = cb["ends"][0]
	var n: Vector3 = ea["n"]
	_exit(ea, mm2, (ea["p"] as Vector3) + n * 1000.0)
	var s: Vector3 = ea["s"]
	var ts: Vector3 = ea["t"]
	# Out of the barrel, round toward +Z (to the inverter), then straight.
	var q := s + ts * r * 1.8 + Vector3(0, 0, r * 3.2)
	var res := _curve(s, ts, q, Vector3(0, 0, -1), r)
	var pts: Array = res["pts"]
	var run := float(cb["run"])
	var draw := minf(run, ROUTED_STUB_MM) if bool(cb["routed"]) else run
	var curve_len := BattWire.length(PackedVector3Array(pts))
	pts.append(q + Vector3(0, 0, maxf(draw - curve_len, 20.0)))
	cb["pts"] = pts
	cb["ends"] = [ea, {"kind": "free", "p": pts[-1], "n": Vector3(0, 0, 1), "t": Vector3(0, 0, -1), "s": pts[-1],
		"lug": {}, "reach": 0.0, "stud": 0.0}]
	cb["od"] = od
	cb["r_bend"] = r
	cb["min_r"] = res["min_r"]
	cb["tight"] = float(res["min_r"]) < r * 0.97
	cb["len_mm"] = run + LUG_SLACK_MM
	cb["r_ohm"] = BattElectrical.resistance("copper", float(cb["len_mm"]), mm2)


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
		cb["upsized"] = true
		# A thicker cable bends wider: route it again.
		if str(cb["kind"]) == "main":
			_route_main(cb)
		else:
			_route_cable(cb)


static func _next_wire(mm2: float) -> Array:
	for w in BattElectrical.WIRES:
		if float(w[1]) > mm2 + 1e-6:
			return w
	return []


## Where string j's + or − lands: on the bar's front face level with the
## pack's terminal (clamped onto the bar), or on its stud of the distributor.
static func _landing(bars: Dictionary, t: Vector3, pole: String, j: int = 0) -> Vector3:
	if str(bars["kind"]) == "distributor":
		var studs: Array = bars["%s_studs" % pole]
		return studs[clampi(j, 0, studs.size() - 1)]
	var line := float(bars["%s_line" % pole])
	var fz := float(bars["face_%s" % pole])
	if str(bars["axis"]) == "y":
		return Vector3(line, clampf(t.y, float(bars["lo"]), float(bars["hi"])), fz)
	return Vector3(clampf(t.x, float(bars["lo"]), float(bars["hi"])), line, fz)


static func fuse_guess_none(b: Dictionary) -> bool:
	return str(b.get("fuse", "auto")) == "none"


static func _face_n(_bars: Dictionary) -> Vector3:
	return Vector3(0, 0, 1)


## Along the bar, away from the packs' middle (the high end).
static func _bar_dir(bars: Dictionary) -> Vector3:
	if str(bars["kind"]) == "distributor":
		return Vector3(1, 0, 0)
	return Vector3(0, 1, 0) if str(bars["axis"]) == "y" else Vector3(1, 0, 0)


static func _along(bars: Dictionary, p: Vector3) -> float:
	return p.y if str(bars["axis"]) == "y" else p.x


static func _take_point(bars: Dictionary, pole: String, at: float) -> Vector3:
	if str(bars["kind"]) == "distributor":
		return bars[pole]
	var line := float(bars["%s_line" % pole])
	var fz := float(bars["face_%s" % pole])
	if str(bars["axis"]) == "y":
		return Vector3(line, at, fz)
	return Vector3(at, line, fz)


## Where string j's fuse sits and what it joins:
##  - MRBF: a terminal fuse block on the pack's + stud; the cable lands on
##    its output stud (`in`, beside the pack stud, the block's height out).
##  - Class T / ANL on a busbar: a holder bolted to the + bar at the landing,
##    reaching back toward the packs; the cable lands on its far stud.
##  - On a distributor: a MEGA-style fuse inside, under the string's stud.
static func _place_fuse(j: int, fuse: Dictionary, bars: Dictionary, pack_pos: Vector3, term_n: Vector3,
		term_kind: String, land: Vector3, nf: Vector3) -> Dictionary:
	var type := str(fuse["type"])
	var dims: Dictionary = FUSE_DIMS.get(type, FUSE_DIMS["class_t"])
	var out := {"id": "fuse_%d" % j, "type": type, "amps": float(fuse["amps"]), "stud": float(dims["stud"])}
	if str(bars["kind"]) == "distributor":
		out["mount"] = "distributor"
		out["a"] = land
		out["in"] = land
		out["n"] = nf
		out["axis"] = Vector3(0, -1, 0)
		out["pos"] = land + Vector3(0, -65.0, 0) + nf * 8.0
		out["type"] = "mega"
		return out
	if type == "mrbf" and term_kind == "stud":
		var up := Vector3.UP if absf(term_n.y) < 0.5 else Vector3.RIGHT
		out["mount"] = "terminal"
		out["a"] = pack_pos
		out["n"] = term_n
		out["axis"] = up
		out["in"] = pack_pos + term_n * float(dims["h"]) + up * float(dims["pitch"])
		out["pos"] = pack_pos + term_n * float(dims["h"]) * 0.5 + up * float(dims["pitch"]) * 0.5
		return out
	# Bus-mounted holder on the outer + bar, reaching away from the packs.
	var perp := Vector3(1, 0, 0) if str(bars["axis"]) == "y" else Vector3(0, 1, 0)
	if (pack_pos - land).dot(perp) > 0.0:
		perp = -perp
	out["mount"] = "bar"
	out["a"] = land
	out["n"] = nf
	out["axis"] = perp
	out["in"] = land + perp * float(dims["pitch"]) + nf * float(dims["h"])
	out["pos"] = land + perp * float(dims["pitch"]) * 0.5 + nf * float(dims["h"]) * 0.5
	return out


## A patch cable from port a to port b: out of each plug, a loop that sags.
static func _patch_path(a: Vector3, b: Vector3) -> Array:
	var z := Vector3(0, 0, 1)
	var pts := _bez(a + z * 30.0, a + z * 90.0, b + z * 90.0, b + z * 30.0, 16)
	var sag := clampf(a.distance_to(b) * 0.12, 15.0, 80.0)
	for i in pts.size():
		var u := float(i) / float(pts.size() - 1)
		pts[i] = (pts[i] as Vector3) + Vector3(0, -sag * sin(PI * u), 0)
	pts.push_front(a)
	pts.append(b)
	return pts


static func _bars_box(bars: Dictionary) -> AABB:
	var w := float(bars["w"])
	var b0: AABB
	for pole in ["pos", "neg"]:
		var line := float(bars["%s_line" % pole])
		var z := float(bars["z_%s" % pole])
		var lo := float(bars["lo"]) - BAR_OVERHANG_MM
		var hi := float(bars["hi"]) + BAR_OVERHANG_MM
		var bb: AABB
		if str(bars["axis"]) == "y":
			bb = AABB(Vector3(line - w * 0.5, lo, z - 40.0), Vector3(w, hi - lo, 80.0))
		else:
			bb = AABB(Vector3(lo, line - w * 0.5, z - 40.0), Vector3(hi - lo, w, 80.0))
		b0 = bb if pole == "pos" else b0.merge(bb)
	return b0


static func _pts_box(pts: Array) -> AABB:
	var b := AABB(pts[0], Vector3.ZERO)
	for p in pts:
		b = b.expand(p)
	return b.grow(10.0)


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
		ph: float, bus_right: float = 0.0) -> Dictionary:
	var boxes: Array = []
	var front := pb.end.z
	var back := pb.position.z
	var u := 0
	match mount:
		"cabinet":
			u = int(ceil((top_y - y0) / 44.45)) + 4
			var h := y0 + float(u) * 44.45 + 60.0
			var w := maxf(CABINET_W, 2.0 * (bus_right + 40.0))
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
	var tight: Array = []
	for cb in (d["cables"] as Array):
		if bool(cb.get("tight", false)):
			tight.append(str(cb["id"]))
	if not tight.is_empty():
		var c0: Dictionary = {}
		for cb in (d["cables"] as Array):
			if str(cb["id"]) == tight[0]:
				c0 = cb
		out.append({"level": "warn", "text": "%s bent tighter than %s cable should go." % [UiText.count(tight.size(), "cable"), str(c0.get("gauge", ""))],
			"why": "Fine-strand battery cable wants a bend of about 5 × its diameter (%.0f mm for %s); bent tighter, the strands and the jacket are strained at the lug. Space the packs or the bus further apart, or use a smaller cable per string." % [float(c0.get("r_bend", 0.0)), str(c0.get("gauge", ""))],
			"ids": tight})
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
