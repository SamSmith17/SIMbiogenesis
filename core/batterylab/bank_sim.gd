class_name BankSim
extends RefCounted

## The whole bank on a test bench: every pack with its own BMS, every string
## with its fuse, the strings in parallel on the bus. What a pack's bench
## (BattSim) cannot show: how the strings share the current, what happens to
## the others when one string's BMS opens (a cascade), the current that flows
## between strings at different charge, one string in the cold, and a short
## on the bus.
##
## The model, per step:
##  - each pack: open-circuit voltage = cells in series × the cell's OCV at
##    its charge (BattSim._ocv, with its knees), resistance = its cells' DC
##    resistance (data sheet × BattSim.DC_IR_FACTOR, more in the cold) plus
##    its links and leads; a lumped temperature (I²R in, h·A·ΔT out);
##  - each string: its packs in series plus its cables and its share of the
##    bus (BankDesign's string resistance);
##  - the bus voltage V solves Σ (V − OCV_j)/R_j = charger − load − V/R_short
##    over the strings that can pass current that way: a string with any
##    pack's discharge switch open passes no discharge current (its charge
##    switch's body diode still lets charge in), and the other way round;
##  - a charger is constant current up to its voltage (absorb, or lead-acid
##    absorb then float), as on the pack bench;
##  - each pack's BMS reads its cells (the pack voltage split evenly over its
##    cells: a pack-level model) and steps BattBmsLogic;
##  - each fuse adds up dt / t_blow(I / rating) (BankDesign.fuse_blow_s,
##    Miner's rule) and opens at 1.
## An estimate in the same sense as the pack bench: real packs share the
## current through their own cells' spread too, which this leaves out.

const MAX_FRAMES := 720
const MAX_WORK := 400000.0  # pack-steps a run may take; dt grows past it
const FULL := BattSim.FULL
const WEAK_CELL := 0.67
## The inverter / charger hears the BMSs over the comms chain and keeps its
## charge current to what the strings that can take charge are rated for.
const COMMS_CHARGE_SHARE := 0.95

const SCENARIOS: Array = [
	{"id": "share", "label": "Share the load", "lead": true,
		"blurb": "The bank runs a steady load from full: watch how the strings share it, and which empties first."},
	{"id": "weak", "label": "One weak pack (cascade)", "lead": true,
		"blurb": "One cell in one pack has lost a third of its capacity. That pack's BMS opens first, on its weak cell; the other strings take its share, over their rating, and trip in turn."},
	{"id": "unequal", "label": "Strings at different charge", "lead": true,
		"blurb": "One string was left at 15 % and the rest at 90 %, then joined: current flows from string to string with no load at all."},
	{"id": "cold", "label": "One string in the cold", "lead": false,
		"blurb": "One string sits by a cold wall at −5 °C while charging. Its BMS refuses the charge; the rest take its share."},
	{"id": "charge", "label": "Charge from 20 %", "lead": true,
		"blurb": "The charger fills the bank: constant current, then holding the voltage."},
	{"id": "short", "label": "A short on the bus", "lead": true,
		"blurb": "A spanner across the bus bars, in slow motion: every string feeds it at once until the BMSs or the fuses open."},
]


static func scenarios_for(lithium: bool) -> Array:
	var out: Array = []
	for s in SCENARIOS:
		if lithium or bool(s["lead"]):
			out.append(s)
	return out


static func scenario(id: String) -> Dictionary:
	for s in SCENARIOS:
		if str(s["id"]) == id:
			return s
	return SCENARIOS[0]


## The scenario's settings for this bank.
static func plan(d: Dictionary, id: String, opts: Dictionary = {}) -> Dictionary:
	var e: Dictionary = d["electrical"]
	var pd: Dictionary = d["pack"]
	var lithium := bool(pd["lithium"])
	var ah := float(e["ah"])
	var dis := float(e["cont_discharge_a"])
	var chg := float(e["cont_charge_a"])
	var pl := {"id": id, "soc0": 0.5, "amb_c": 25.0, "amb_to_c": 25.0, "cold_string": -1, "cold_c": -5.0,
		"cold_to_c": 10.0, "dt": 10.0, "hours": 2.5, "charge_a": 0.0, "load_a": 0.0, "short_ohm": 0.0,
		"short_at": 0.0, "weak": false, "soc_low": -1.0, "stop_on_down": true, "stop_on_full": true, "lvd_v": 0.0}
	match id:
		"share":
			pl.merge({"soc0": FULL, "load_a": minf(0.5 * ah, 0.9 * dis)}, true)
		"weak":
			pl.merge({"soc0": FULL, "load_a": minf(0.85 * ah, 0.8 * dis), "weak": true, "hours": 2.0}, true)
		"unequal":
			pl.merge({"soc0": 0.9, "soc_low": 0.15, "hours": 1.0, "dt": 2.0, "stop_on_down": false}, true)
		"cold":
			pl.merge({"soc0": 0.3, "amb_c": 15.0, "amb_to_c": 18.0, "cold_string": 0,
				"charge_a": 0.8 * chg, "hours": 3.0}, true)
		"charge":
			pl.merge({"soc0": 0.2, "charge_a": minf(0.5 * ah, 0.9 * chg), "hours": 3.5}, true)
		"short":
			pl.merge({"soc0": 0.8, "short_ohm": 0.0005, "short_at": 0.001, "hours": 0.02 / 3600.0,
				"dt": 0.00001, "stop_on_down": false}, true)
	if not lithium:
		pl["charge_a"] = minf(float(pl["charge_a"]), 0.2 * ah)
		if float(pl["load_a"]) > 0.0:
			pl["load_a"] = minf(float(pl["load_a"]), 0.2 * ah)
			pl["lvd_v"] = float(pd["electrical"]["cells_series"]) * float(d["series"]) * 1.75
			pl["hours"] = 6.0 if id != "weak" else 5.0
			pl["dt"] = 20.0
		if id == "charge":
			pl["hours"] = 10.0
			pl["dt"] = 20.0
	for k in opts:
		pl[k] = opts[k]
	return pl


static func run(d: Dictionary, id: String, opts: Dictionary = {}) -> Dictionary:
	var pl := plan(d, id, opts)
	var pd: Dictionary = d["pack"]
	var pe: Dictionary = pd["electrical"]
	var cell: Dictionary = pd["cell"]
	var chem := str(pd["chem"])
	var row: Dictionary = pd["chem_row"]
	var lithium := bool(pd["lithium"])
	var protected := bool(pd["protected"])
	var bms: Dictionary = pd["bms"]
	var bp: Dictionary = pd["bms_params"] if protected else {}
	var N := int(d["series"])
	var M := int(d["parallel"])
	var n := N * M
	var S := int(pe["cells_series"])
	var inside := BattCells.cells_inside(cell)
	var ocv_t: Array = row.get("ocv", [])
	var knee := BattSim.KNEE_W if lithium else BattSim.KNEE_W_LEAD
	var top_k := 0.0
	var bot_k := 0.0
	if ocv_t.size() >= 2:
		top_k = maxf(0.05, float(row["cell_max_v"]) + 0.1 - float(ocv_t[-1]))
		bot_k = maxf(0.05, float(ocv_t[0]) - float(row["cell_min_v"]) + 0.1)
	var v_cell_nom := float(cell["nominal_v"]) / float(inside)
	var r_cells := float(pe["r_cells"]) * BattSim.DC_IR_FACTOR
	var r_other := maxf(0.0, float(pe["r_ohm"]) - float(pe["r_cells"]))
	var cap0 := float(pe["ah"])
	var lb: AABB = pd["layout"]["bounds"]
	var area := 2.0 * (lb.size.x * lb.size.y + lb.size.y * lb.size.z + lb.size.x * lb.size.z) * 1e-6
	var c_th := float(pd["mass_kg"]) * (BattSim.CP_LITHIUM if lithium else BattSim.CP_LEAD)
	var ha := BattSim.H_CELL * area
	var fuse: Dictionary = d["fuse"]
	var fuse_a := float(fuse.get("amps", 0.0))
	var fuse_t := str(fuse.get("type", ""))
	# Each string's wiring (cables + bus) apart from its packs.
	var r_wire := PackedFloat64Array()
	r_wire.resize(M)
	for st in (d["strings"] as Array):
		r_wire[int(st["j"])] = maxf(0.0, float(st["r_ohm"]) - float(N) * float(pe["r_ohm"]))
	# Packs.
	var cap := PackedFloat64Array()
	var rmul := PackedFloat64Array()
	var soc := PackedFloat64Array()
	var temp := PackedFloat64Array()
	var amb_off := PackedFloat64Array()
	cap.resize(n)
	rmul.resize(n)
	soc.resize(n)
	temp.resize(n)
	amb_off.resize(n)
	var states: Array = []
	for k in n:
		var j := k / N
		cap[k] = cap0 * (1.0 + 0.004 * BattSim._spread(k, 3.0))
		rmul[k] = 1.0 + 0.03 * BattSim._spread(k, 4.0)
		var s0 := float(pl["soc0"])
		if float(pl["soc_low"]) >= 0.0 and j == 0:
			s0 = float(pl["soc_low"])
		soc[k] = s0
		temp[k] = float(pl["cold_c"]) if j == int(pl["cold_string"]) else float(pl["amb_c"])
		states.append(BattBmsLogic.new_state(s0))
	# A weak pack: one of its cells has lost a third of its capacity. The
	# pack's voltage hardly shows it; its BMS, reading that cell, does.
	var weak := bool(pl["weak"])
	var wsoc := float(pl["soc0"])
	var wcap := cap0 * WEAK_CELL
	var dt := float(pl["dt"])
	var dur_s := float(pl["hours"]) * 3600.0
	var steps := int(ceilf(dur_s / dt))
	if float(steps) * float(n) > MAX_WORK:
		dt *= float(steps) * float(n) / MAX_WORK
		steps = int(ceilf(dur_s / dt))
	var every := maxi(1, int(ceilf(float(steps) / float(MAX_FRAMES))))
	var blown := PackedByteArray()
	var fheat := PackedFloat64Array()
	blown.resize(M)
	fheat.resize(M)
	var ocv_j := PackedFloat64Array()
	var r_j := PackedFloat64Array()
	var i_j := PackedFloat64Array()
	var chg_ok := PackedByteArray()
	var dsg_ok := PackedByteArray()
	ocv_j.resize(M)
	r_j.resize(M)
	i_j.resize(M)
	chg_ok.resize(M)
	dsg_ok.resize(M)
	var p_ocv := PackedFloat64Array()
	var p_r := PackedFloat64Array()
	p_ocv.resize(n)
	p_r.resize(n)
	var frames: Array = []
	var events: Array = []
	var led := {"in_wh": 0.0, "out_wh": 0.0, "short_wh": 0.0, "stored_wh": 0.0, "heat_wh": 0.0}
	var charger_on := float(pl["charge_a"]) > 0.0
	var stage := "bulk" if charger_on else ""
	var abs_since := -1.0
	var down := false
	var down_t := -1.0
	var stop_t := -1.0
	var full_at := -1.0
	var i_peak := 0.0
	var share_max := 0.0
	var v_abs := float(row["cell_absorb_v"]) * float(S * N)
	var tail_a := (0.05 if lithium else 0.02) * float(pe["ah"]) * float(M)
	var amb := float(pl["amb_c"])
	var cell_v := PackedFloat64Array()
	cell_v.resize(S)
	var comms := bool((d["spec"] as Dictionary).get("comms", true)) and N * M > 1
	var i_str_peak := 0.0
	for step_i in steps + 1:
		var t := float(step_i) * dt
		var f := clampf(t / maxf(dur_s, 1.0), 0.0, 1.0)
		amb = lerpf(float(pl["amb_c"]), float(pl["amb_to_c"]), f)
		var amb_cold := lerpf(float(pl["cold_c"]), float(pl["cold_to_c"]), f)
		# Each pack's OCV and resistance; each string's sum.
		for j in M:
			var so := 0.0
			var sr := r_wire[j]
			var cok := true
			var dok := true
			for s in N:
				var k := j * N + s
				var o := BattSim._ocv(ocv_t, soc[k], v_cell_nom, top_k, bot_k, knee) * float(S)
				if weak and k == 0:
					o += BattSim._ocv(ocv_t, wsoc, v_cell_nom, top_k, bot_k, knee) - o / float(S)
				var r := (r_cells * (1.0 + BattSim.IR_COLD_PER_C * maxf(0.0, 25.0 - temp[k])) + r_other) * rmul[k]
				p_ocv[k] = o
				p_r[k] = r
				so += o
				sr += r
				if protected:
					cok = cok and bool(states[k]["chg"])
					dok = dok and bool(states[k]["dsg"])
			ocv_j[j] = so
			r_j[j] = sr
			chg_ok[j] = 1 if cok and blown[j] == 0 else 0
			dsg_ok[j] = 1 if dok and blown[j] == 0 else 0
		# What is asked of the bank.
		var load := float(pl["load_a"]) if stop_t < 0.0 and not down else 0.0
		var g_short := 1.0 / float(pl["short_ohm"]) if float(pl["short_ohm"]) > 0.0 and t >= float(pl["short_at"]) else 0.0
		var i_ch := float(pl["charge_a"]) if charger_on else 0.0
		if charger_on and comms and protected:
			var takers := 0
			for j in M:
				if chg_ok[j] != 0:
					takers += 1
			i_ch = minf(i_ch, COMMS_CHARGE_SHARE * float(takers) * float(pe["cont_charge_a"]))
		var v_cv := 0.0
		if charger_on:
			if lithium:
				v_cv = v_abs
			else:
				v_cv = float(S * N) * BattChem.charge_v(chem, "float" if stage == "float" else "absorb", temp[0])
		var res := _solve(ocv_j, r_j, chg_ok, dsg_ok, blown, i_ch, v_cv, load, g_short)
		var v: float = res["v"]
		for j in M:
			i_j[j] = float((res["i"] as PackedFloat64Array)[j])
		var i_bank: float = res["i_bank"]
		var i_charger: float = res["i_charger"]
		if charger_on and float(res["clamped"]) > 0.5 and stage == "bulk":
			stage = "absorb"
			abs_since = t
			events.append({"t": t, "key": "charger", "what": "stage", "where": "",
				"text": "Charger: constant current done, holding %.1f V" % v_cv})
		# BMSs.
		var any_trip := false
		if protected:
			for j in M:
				for s in N:
					var k := j * N + s
					var vp := p_ocv[k] + i_j[j] * p_r[k]
					for c in S:
						cell_v[c] = vp / float(S)
					if weak and k == 0:
						var wv := BattSim._ocv(ocv_t, wsoc, v_cell_nom, top_k, bot_k, knee) + i_j[j] * p_r[k] / float(S)
						var rest := (vp - wv) / float(maxi(S - 1, 1))
						for c in S:
							cell_v[c] = rest
						cell_v[0] = wv
					var evs := BattBmsLogic.step(states[k], bp, bms, {"cell_v": cell_v, "i_a": i_j[j],
						"t_max": temp[k], "t_min": temp[k], "cap_ah": cap[k]}, dt, t)
					for ev in evs:
						ev["t"] = t
						ev["where"] = "pack_%d" % k
						ev["text"] = "String %d, pack %d — %s" % [j + 1, s + 1, ev["text"]]
						events.append(ev)
						if str(ev["what"]) == "trip":
							any_trip = true
		# A switch that just opened takes effect this step.
		if any_trip:
			for j in M:
				var cok := blown[j] == 0
				var dok := blown[j] == 0
				for s in N:
					cok = cok and bool(states[j * N + s]["chg"])
					dok = dok and bool(states[j * N + s]["dsg"])
				chg_ok[j] = 1 if cok else 0
				dsg_ok[j] = 1 if dok else 0
			res = _solve(ocv_j, r_j, chg_ok, dsg_ok, blown, i_ch, v_cv, load, g_short)
			v = res["v"]
			for j in M:
				i_j[j] = float((res["i"] as PackedFloat64Array)[j])
			i_bank = res["i_bank"]
			i_charger = res["i_charger"]
		# Fuses.
		if fuse_a > 0.0:
			for j in M:
				if blown[j] != 0:
					continue
				var x := absf(i_j[j]) / fuse_a
				var tb := BankDesign.fuse_blow_s(fuse_t, x)
				if tb < INF:
					fheat[j] += dt / tb
				else:
					fheat[j] = maxf(0.0, fheat[j] - dt / 600.0)
				if fheat[j] >= 1.0:
					blown[j] = 1
					events.append({"t": t, "key": "fuse", "what": "trip", "where": "fuse_%d" % j,
						"text": "String %d's %s %.0f A fuse blew at %s A" % [j + 1, fuse.get("label", ""), fuse_a, UiText.thousands(int(absf(i_j[j])))]})
		if absf(i_bank) > absf(i_peak):
			i_peak = i_bank
		for j in M:
			if absf(i_j[j]) > absf(i_str_peak):
				i_str_peak = i_j[j]
		# Bank down: a load and nothing can feed it.
		if load > 0.0 and not down:
			var any_d := false
			for j in M:
				if dsg_ok[j] != 0:
					any_d = true
			if not any_d or absf(float(res["unserved"])) > 0.01 * load:
				down = true
				down_t = t
				events.append({"t": t, "key": "bank_down", "what": "trip", "where": "",
					"text": "Bank down: no string can feed the load, the inverter loses power"})
		if float(pl["lvd_v"]) > 0.0 and stop_t < 0.0 and load > 0.0 and v <= float(pl["lvd_v"]):
			stop_t = t
			events.append({"t": t, "key": "lvd", "what": "trip", "where": "",
				"text": "The inverter's low-voltage cutoff stopped the load at %.1f V" % v})
		# Advance the packs.
		var stored := 0.0
		var heat := 0.0
		var gas := 0.0
		for j in M:
			var a := 0.0 if blown[j] != 0 else i_j[j]
			if M > 1 and absf(i_bank) > 1.0 and blown[j] == 0:
				share_max = maxf(share_max, absf(a) / absf(i_bank))
			heat += a * a * r_wire[j] * dt
			for s in N:
				var k := j * N + s
				var s_old := soc[k]
				soc[k] = clampf(soc[k] + a * dt / 3600.0 / cap[k], -BattSim.SOC_OVER, 1.0 + BattSim.SOC_OVER)
				# Charge past full goes to gassing (lead) or the knee: as heat.
				var took := (soc[k] - s_old) * cap[k] * 3600.0
				stored += p_ocv[k] * took
				gas += p_ocv[k] * (a * dt - took)
				if weak and k == 0:
					wsoc = clampf(wsoc + a * dt / 3600.0 / wcap, -BattSim.SOC_OVER, 1.0 + BattSim.SOC_OVER)
				var q := a * a * p_r[k]
				heat += q * dt
				var ak := amb_cold if j == int(pl["cold_string"]) else amb
				temp[k] += (q - ha * (temp[k] - ak)) * dt / maxf(c_th, 1e-6)
		if i_charger > 0.0:
			led["in_wh"] += v * i_charger * dt / 3600.0
		led["out_wh"] += v * load * dt / 3600.0 if not down else 0.0
		led["short_wh"] += v * v * g_short * dt / 3600.0
		led["stored_wh"] += stored / 3600.0
		led["heat_wh"] += (heat + gas) / 3600.0
		# The charger's end.
		if charger_on and stage == "absorb" and i_charger < tail_a and t - abs_since > (60.0 if lithium else 3600.0):
			full_at = t
			if lithium:
				charger_on = false
				events.append({"t": t, "key": "charger", "what": "done", "where": "",
					"text": "Charger: current tapered below %.0f A, the bank is full" % tail_a})
			else:
				stage = "float"
				events.append({"t": t, "key": "charger", "what": "stage", "where": "",
					"text": "Charger: absorb done, dropping to float"})
		if step_i % every == 0 or step_i == steps:
			frames.append(_frame(t, v, i_bank, load, i_charger, i_j, soc, temp, states, blown, chg_ok, dsg_ok,
				N, M, protected, stage if charger_on else ""))
		# Stop: the bank down (or full) and ten minutes after, for the recovery.
		if stop_t < 0.0:
			if (bool(pl["stop_on_down"]) and down) or (bool(pl["stop_on_full"]) and full_at >= 0.0 and lithium):
				stop_t = t
		if stop_t >= 0.0 and t - stop_t >= 600.0 and dur_s > 1800.0:
			if step_i % every != 0:
				frames.append(_frame(t, v, i_bank, load, i_charger, i_j, soc, temp, states, blown, chg_ok, dsg_ok,
					N, M, protected, stage if charger_on else ""))
			break
	return {"plan": pl, "frames": frames, "events": events, "ledger": led,
		"duration_s": float(frames[-1]["t"]) if not frames.is_empty() else 0.0,
		"series": N, "parallel": M, "i_peak": i_peak, "i_string_peak": i_str_peak, "down_t": down_t,
		"full_at": full_at, "share_max": share_max, "comms": comms,
		"summary": _summary(id, d, led, events, frames, maxf(absf(i_peak), absf(i_str_peak)))}


## The bus voltage and every string's current (+ = into the string).
static func _solve(ocv: PackedFloat64Array, r: PackedFloat64Array, chg_ok: PackedByteArray,
		dsg_ok: PackedByteArray, blown: PackedByteArray, i_ch: float, v_cv: float, load: float,
		g_short: float) -> Dictionary:
	var m := ocv.size()
	var on := PackedByteArray()
	on.resize(m)
	for j in m:
		on[j] = 0 if blown[j] != 0 or (chg_ok[j] == 0 and dsg_ok[j] == 0) else 1
	var v := 0.0
	var clamped := false
	var cur := PackedFloat64Array()
	cur.resize(m)
	for _iter in m + 1:
		var g := g_short
		var y := 0.0
		for j in m:
			if on[j] != 0:
				g += 1.0 / r[j]
				y += ocv[j] / r[j]
		clamped = false
		if g <= 0.0:
			v = 0.0
		else:
			v = (y + i_ch - load) / g
			if i_ch > 0.0 and v_cv > 0.0 and v > v_cv:
				v = v_cv
				clamped = true
		var changed := false
		for j in m:
			cur[j] = 0.0
			if on[j] == 0:
				continue
			var a := (v - ocv[j]) / r[j]
			if (a > 0.0 and chg_ok[j] == 0) or (a < 0.0 and dsg_ok[j] == 0):
				on[j] = 0
				changed = true
			else:
				cur[j] = a
		if not changed:
			break
	var i_bank := 0.0
	for j in m:
		i_bank += cur[j]
	# A charger holding a voltage below the bank's own takes no current back:
	# then the bank simply floats with the charger idle.
	if clamped and i_bank + load + v * g_short < 0.0:
		return _solve(ocv, r, chg_ok, dsg_ok, blown, 0.0, 0.0, load, g_short)
	# What the charger actually gives: what the strings take, the load and the short.
	var i_charger := 0.0
	var unserved := 0.0
	if i_ch > 0.0:
		i_charger = clampf(i_bank + load + v * g_short, 0.0, i_ch)
	var any := false
	for j in m:
		if on[j] != 0:
			any = true
	if load > 0.0 and not any and i_ch <= 0.0:
		unserved = load
	return {"v": v, "i": cur, "i_bank": i_bank, "i_charger": i_charger, "clamped": 1.0 if clamped else 0.0,
		"unserved": unserved}


## One frame: per string its current, mean charge and state code (0 fine,
## 1 charge blocked, 2 discharge blocked, 3 both, 4 fuse blown); per pack its
## charge, temperature and whether its BMS has anything tripped.
static func _frame(t: float, v: float, i_bank: float, load: float, i_charger: float, i_j: PackedFloat64Array,
		soc: PackedFloat64Array, temp: PackedFloat64Array, states: Array, blown: PackedByteArray,
		chg_ok: PackedByteArray, dsg_ok: PackedByteArray, N: int, M: int, protected: bool, stage: String) -> Dictionary:
	var ss := PackedFloat64Array()
	var sc := PackedInt32Array()
	var ps := PackedInt32Array()
	ss.resize(M)
	sc.resize(M)
	ps.resize(N * M)
	var tmax := -INF
	for j in M:
		var a := 0.0
		for s in N:
			var k := j * N + s
			a += soc[k]
			tmax = maxf(tmax, temp[k])
			var tripped := false
			if protected:
				for key in (states[k]["trips"] as Dictionary):
					if bool(states[k]["trips"][key]):
						tripped = true
			ps[k] = 1 if tripped else 0
		ss[j] = a / float(N)
		if blown[j] != 0:
			sc[j] = 4
		else:
			sc[j] = (0 if chg_ok[j] != 0 else 1) + (0 if dsg_ok[j] != 0 else 2)
	var bank_soc := 0.0
	for x in soc:
		bank_soc += x
	return {"t": t, "v": v, "i": i_bank, "load": load, "charger": i_charger, "i_str": i_j.duplicate(),
		"soc_str": ss, "state_str": sc, "pack_state": ps, "pack_soc": soc.duplicate(),
		"soc": bank_soc / float(maxi(soc.size(), 1)), "t_max": tmax, "stage": stage}


static func frame_at(res: Dictionary, t: float) -> Dictionary:
	return BattSim.frame_at(res, t)


## A state code in words.
static func state_words(code: int) -> String:
	match code:
		0:
			return "on"
		1:
			return "charge blocked"
		2:
			return "discharge blocked"
		3:
			return "off (BMS)"
		4:
			return "fuse blown"
	return ""


static func _summary(id: String, d: Dictionary, led: Dictionary, events: Array, frames: Array, i_peak: float) -> String:
	var parts: Array = []
	if float(led["in_wh"]) > 0.5:
		parts.append("%.1f kWh in" % (float(led["in_wh"]) * 0.001))
	if float(led["out_wh"]) > 0.5:
		parts.append("%.1f kWh to the load" % (float(led["out_wh"]) * 0.001))
	var trips := 0
	var first := ""
	var first_t := 0.0
	var fuses := 0
	for ev in events:
		if str(ev["what"]) == "trip":
			if str(ev["key"]) == "fuse":
				fuses += 1
			trips += 1
			if first.is_empty():
				first = str(ev["text"])
				first_t = float(ev["t"])
	if not first.is_empty():
		parts.append("first: %s at %s" % [first, BattSim.time_words(first_t)])
	if trips > 1:
		parts.append("%d trips in all" % trips)
	if fuses > 0:
		parts.append(UiText.count(fuses, "fuse") + " blown")
	if id == "short" or id == "unequal":
		parts.append("peak %s A" % UiText.thousands(int(absf(i_peak))))
	if parts.is_empty():
		parts.append("Nothing tripped")
	return "; ".join(PackedStringArray(parts)) + "."
