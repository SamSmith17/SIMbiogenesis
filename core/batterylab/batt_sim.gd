class_name BattSim
extends RefCounted

## The Battery Lab's test bench: one designed pack, cell by cell, through a
## scenario (charge it, run a load, charge it on a frozen morning, short it,
## a weak cell, balancing a spread, a lead-acid charger's stages), with its
## BMS (BattBmsLogic) deciding what may flow.
##
## The model, per cell: open-circuit voltage from its state of charge
## (BattChem.ocv), a series resistance (the data sheet's AC figure ×
## `DC_IR_FACTOR`; rises in the cold), a lumped temperature (I²R heat in, a
## loss to the air round it out) and a small manufacturing spread in capacity
## and resistance, seeded so a run is repeatable. Cells in one parallel group
## share a voltage, so their currents split by their resistances:
##   V_g = (I + Σ ocv_k / r_k) / Σ 1 / r_k,   i_k = (V_g − ocv_k) / r_k.
## The groups are in series; the links, cables and contacts add the design's
## own resistance. A charger runs constant current then constant voltage
## (lead-acid: bulk, absorb, float); a load draws constant current, or a
## resistance for the short.
##
## `run` steps the whole scenario at once and returns frames (sampled for the
## chart and the scrub), the events and an energy ledger; the lab then only
## reads them. Pure: no scene, no clock.

## Data-sheet internal resistance is AC (1 kHz); DC resistance under load is
## higher. An estimate across LFP / NMC / lead sheets.
const DC_IR_FACTOR := 1.5
## Resistance rises in the cold, about 2 %/°C below 25 °C (an estimate).
const IR_COLD_PER_C := 0.02
## Specific heat of a cell, J/(kg·K): lithium ~1000, lead-acid ~800 (estimates).
const CP_LITHIUM := 1000.0
const CP_LEAD := 800.0
## Heat lost to the air round a cell packed in a case, W/(m²·K) (an estimate:
## natural convection ~5–10, and most of each cell's face is against its
## neighbours).
const H_CELL := 3.0
## Manufacturing spread (one standard deviation): capacity and resistance.
const CAP_SPREAD := 0.006
const IR_SPREAD := 0.05
## Width of the knees at full and empty (share of capacity). Lead-acid's
## charging voltage climbs from ~80 % (gassing, polarisation), so its knee is
## wider: absorb then starts where a real charger's does.
const KNEE_W := 0.012
const KNEE_W_LEAD := 0.08
## How far past full / empty a cell's state may be pushed (the knee stops it).
const SOC_OVER := 0.03
## "Full" as a starting point: just under the top knee, as a cell rests
## after its charger stops.
const FULL := 0.99
## Most frames a run keeps.
const MAX_FRAMES := 720

const SCENARIOS: Array = [
	{"id": "charge", "label": "Charge to full", "who": "any",
		"blurb": "From 20 % at half its rated current, constant current then constant voltage until the current tapers off."},
	{"id": "discharge", "label": "Run a load to empty", "who": "any",
		"blurb": "From full at half its rated current until the BMS (or, on lead-acid, the inverter's low-voltage cutoff) stops it."},
	{"id": "cold", "label": "Charge on a frozen morning", "who": "lithium",
		"blurb": "−5 °C at dawn warming to 12 °C: lithium must not be charged below freezing, so the BMS holds the charge off until the cells warm up."},
	{"id": "overload", "label": "Too big a load", "who": "lithium",
		"blurb": "130 % of the BMS's rating: it allows it for its delay, opens the discharge switch, then retries."},
	{"id": "short", "label": "Short circuit (slow motion)", "who": "any",
		"blurb": "A spanner across the terminals: thousands of amps in a millisecond. Lithium: the BMS opens in 0.3 ms. Lead-acid: only a fuse saves it."},
	{"id": "weak", "label": "One weak cell", "who": "any",
		"blurb": "One cell with 80 % of the capacity and twice the resistance: it reaches empty first and full first, and the whole pack stops with it."},
	{"id": "balance", "label": "Balancing a spread", "who": "lithium",
		"blurb": "Groups 2 % apart, charged and held at full: the balancer bleeds the high ones (passive) or moves charge from high to low (active)."},
]


static func scenarios_for(lithium: bool) -> Array:
	var out: Array = []
	for s in SCENARIOS:
		var who := str((s as Dictionary)["who"])
		if who == "any" or (who == "lithium") == lithium:
			out.append(s)
	return out


static func scenario(id: String) -> Dictionary:
	for s in SCENARIOS:
		if str((s as Dictionary)["id"]) == id:
			return s
	return {}


## Repeatable pseudo-random in [−1, 1] (two summed uniforms: a rough bell).
static func _spread(k: int, salt: float) -> float:
	var a := fposmod(sin(float(k) * 12.9898 + salt * 78.233) * 43758.5453, 1.0)
	var b := fposmod(sin(float(k) * 39.346 + salt * 11.135) * 24634.6345, 1.0)
	return a + b - 1.0


## The scenario's plan: duration, step, start SOC and temperature, charger
## and load. `opts` may override `soc0`, `amb_c`, `i_a`, `hours`.
static func plan(d: Dictionary, id: String, opts: Dictionary = {}) -> Dictionary:
	var e: Dictionary = d["electrical"]
	var ah := float(e["ah"])
	var lithium := bool(d["lithium"])
	var protected := bool(d["protected"])
	var bms: Dictionary = d["bms"]
	var rate := 0.5 * ah
	if protected:
		rate = minf(rate, float(bms["cont_a"]) * 0.9)
	rate = minf(rate, float(e["cont_charge_a"]))
	var pl := {"id": id, "soc0": 0.5, "amb_c": 25.0, "amb_to_c": 25.0, "dt": 5.0, "hours": 4.0,
		"charge_a": 0.0, "load_a": 0.0, "short_ohm": 0.0, "short_at": 0.0, "cv": "", "hold": false,
		"spread": 0.0, "weak": false, "stop_on_full": true, "stop_on_empty": true, "lvd_v": 0.0}
	match id:
		"charge":
			pl.merge({"soc0": 0.2, "charge_a": rate, "cv": "absorb", "hours": 2.6 / 0.5 + 0.5, "dt": 10.0}, true)
		"discharge":
			pl.merge({"soc0": FULL, "load_a": minf(0.5 * ah, float(e["cont_discharge_a"]) * 0.9),
				"hours": 2.5, "dt": 10.0}, true)
		"cold":
			pl.merge({"soc0": 0.3, "amb_c": -5.0, "amb_to_c": 15.0, "charge_a": 0.3 * ah, "cv": "absorb",
				"hours": 8.0, "dt": 10.0}, true)
			pl["charge_a"] = minf(float(pl["charge_a"]), rate)
		"overload":
			pl.merge({"soc0": 0.9, "load_a": 1.3 * float(bms.get("cont_a", e["cont_discharge_a"])),
				"hours": 150.0 / 3600.0, "dt": 0.25, "stop_on_empty": false}, true)
		"short":
			pl.merge({"soc0": 0.8, "short_ohm": 0.002, "short_at": 0.001, "hours": 0.004 / 3600.0,
				"dt": 0.00001, "stop_on_empty": false}, true)
		"weak":
			pl.merge({"soc0": FULL, "load_a": minf(0.5 * ah, float(e["cont_discharge_a"]) * 0.9),
				"weak": true, "hours": 2.5, "dt": 10.0}, true)
		"balance":
			pl.merge({"soc0": 0.85, "charge_a": rate * 0.5, "cv": "absorb", "hold": true, "spread": 0.02,
				"hours": 10.0, "dt": 10.0, "stop_on_full": false}, true)
			# A spread the balancer can work off in about six hours.
			var ba := float(BattBms.balance_for(str(d["bms_id"]), str(d["chem"])).get("a", 0.0))
			pl["spread"] = clampf(ba * 6.0 / maxf(ah, 1e-6), 0.002, 0.02)
	if not lithium:
		pl["cv"] = "lead" if float(pl["charge_a"]) > 0.0 else ""
		pl["charge_a"] = minf(float(pl["charge_a"]), 0.2 * ah)
		if id == "charge":
			pl["hours"] = 12.0
			pl["dt"] = 20.0
		if float(pl["load_a"]) > 0.0:
			# An inverter's low-voltage cutoff: 1.75 V a cell (10.5 V on 12 V).
			pl["lvd_v"] = float(e["cells_series"]) * 1.75
			pl["load_a"] = minf(float(pl["load_a"]), 0.2 * ah)
			pl["hours"] = 6.0
	for k in opts:
		pl[k] = opts[k]
	return pl


static func run(d: Dictionary, id: String, opts: Dictionary = {}) -> Dictionary:
	var pl := plan(d, id, opts)
	var e: Dictionary = d["electrical"]
	var cell: Dictionary = d["cell"]
	var chem := str(d["chem"])
	var row: Dictionary = d["chem_row"]
	var lithium := bool(d["lithium"])
	var protected := bool(d["protected"])
	var bms: Dictionary = d["bms"]
	var p: Dictionary = d["bms_params"] if protected else {}
	var bal := BattBms.balance_for(str(d["bms_id"]), chem) if protected else {}
	var inside := BattCells.cells_inside(cell)
	var S := int(e["cells_series"])
	var P := int((d["spec"] as Dictionary)["parallel"])
	var n := S * P
	var ocv_t: Array = row.get("ocv", [])
	var cap0 := float(cell["ah"])
	var r0 := float(cell["ir_mohm"]) * 0.001 * DC_IR_FACTOR / float(inside)
	var m_cell := float(cell["mass_kg"]) / float(inside)
	var b := BattCells.box_mm(cell)
	var area := 2.0 * (b.x * b.y + b.y * b.z + b.x * b.z) * 1e-6 / float(inside)
	var cp := CP_LITHIUM if lithium else CP_LEAD
	var c_th := m_cell * cp
	var ha := H_CELL * area
	var r_ext := maxf(0.0, float(e["r_ohm"]) - float(e["r_cells"]))
	var v_abs := float(row["cell_absorb_v"])
	var knee_w := KNEE_W if lithium else KNEE_W_LEAD
	var top_k := 0.0
	var bot_k := 0.0
	if ocv_t.size() >= 2:
		top_k = maxf(0.05, float(row["cell_max_v"]) + 0.1 - float(ocv_t[-1]))
		bot_k = maxf(0.05, float(ocv_t[0]) - float(row["cell_min_v"]) + 0.1)
	var v_flt := float(row["cell_float_v"])
	# Cells.
	var cap := PackedFloat64Array()
	var r25 := PackedFloat64Array()
	var soc := PackedFloat64Array()
	var temp := PackedFloat64Array()
	cap.resize(n)
	r25.resize(n)
	soc.resize(n)
	temp.resize(n)
	var amb := float(pl["amb_c"])
	for k in n:
		var g := k / P
		cap[k] = cap0 * (1.0 + CAP_SPREAD * _spread(k, 1.0))
		r25[k] = r0 * (1.0 + IR_SPREAD * _spread(k, 2.0))
		var s0 := float(pl["soc0"]) + float(pl["spread"]) * (float(g) / float(maxi(S - 1, 1)) - 0.5)
		soc[k] = clampf(s0, 0.0, 1.0)
		temp[k] = amb
	if bool(pl["weak"]):
		var wk := (S / 2) * P
		cap[wk] *= 0.8
		r25[wk] *= 2.0
	var st := BattBmsLogic.new_state(float(pl["soc0"]))
	var dt := float(pl["dt"])
	var dur_s := float(pl["hours"]) * 3600.0
	var steps := int(ceilf(dur_s / dt))
	var every := maxi(1, int(ceilf(float(steps) / float(MAX_FRAMES))))
	var frames: Array = []
	var events: Array = []
	var stage := "bulk" if str(pl["cv"]) != "" else ""
	var charger_on := float(pl["charge_a"]) > 0.0
	var stop_t := -1.0
	var abs_since := -1.0
	var led := {"in_wh": 0.0, "out_wh": 0.0, "stored_wh": 0.0, "heat_wh": 0.0, "bleed_wh": 0.0,
		"in_ah": 0.0, "out_ah": 0.0}
	var ocv_k := PackedFloat64Array()
	var r_k := PackedFloat64Array()
	ocv_k.resize(n)
	r_k.resize(n)
	var gv := PackedFloat64Array()
	gv.resize(S)
	var g_ocv := PackedFloat64Array()
	var g_r := PackedFloat64Array()
	g_ocv.resize(S)
	g_r.resize(S)
	var t_max := -INF
	var v_hi := -INF
	var v_lo := INF
	var full_at := -1.0
	var tail_a := 0.05 * float(e["ah"]) if lithium else 0.02 * float(e["ah"])
	var i_pack := 0.0
	var i_peak := 0.0
	var short_said := false
	var bleed := PackedFloat64Array()
	bleed.resize(S)
	for step_i in steps + 1:
		var t := float(step_i) * dt
		# Ambient follows the scenario (a morning warming up).
		amb = lerpf(float(pl["amb_c"]), float(pl["amb_to_c"]), clampf(t / maxf(dur_s, 1.0), 0.0, 1.0))
		# Cell OCV and resistance now; group Thevenin.
		var v0 := 0.0
		var rp := r_ext
		for g in S:
			var sg := 0.0
			var sy := 0.0
			for j in P:
				var k := g * P + j
				var o := _ocv(ocv_t, soc[k], float(cell["nominal_v"]) / float(inside), top_k, bot_k, knee_w)
				var rr := r25[k] * (1.0 + IR_COLD_PER_C * maxf(0.0, 25.0 - temp[k]))
				ocv_k[k] = o
				r_k[k] = rr
				sg += 1.0 / rr
				sy += o / rr
			g_ocv[g] = sy / sg
			g_r[g] = 1.0 / sg
			v0 += g_ocv[g]
			rp += g_r[g]
		# What is asked of the pack.
		var want := 0.0
		if charger_on:
			want = float(pl["charge_a"])
			var vcv := 0.0
			match str(pl["cv"]):
				"absorb":
					vcv = float(S) * v_abs
				"lead":
					vcv = float(S) * (BattChem.charge_v(chem, "float", temp[0]) if stage == "float"
						else BattChem.charge_v(chem, "absorb", temp[0]))
			if vcv > 0.0:
				var i_cv := (vcv - v0) / rp
				if i_cv < want:
					want = maxf(i_cv, 0.0)
					if stage == "bulk":
						stage = "absorb"
						abs_since = t
						events.append({"t": t, "key": "charger", "what": "stage",
							"text": "Charger: constant current done, holding %.1f V (absorb)" % vcv})
		if float(pl["load_a"]) > 0.0 and stop_t < 0.0:
			want -= float(pl["load_a"])
		if float(pl["short_ohm"]) > 0.0 and t >= float(pl["short_at"]):
			want = -v0 / (rp + float(pl["short_ohm"]))
		i_pack = BattBmsLogic.allowed_current(st, want) if protected else want
		# Group voltages under this current (what the BMS reads).
		for g in S:
			gv[g] = g_ocv[g] + i_pack * g_r[g]
		var tmax_c := -INF
		var tmin_c := INF
		for k in n:
			tmax_c = maxf(tmax_c, temp[k])
			tmin_c = minf(tmin_c, temp[k])
		if protected:
			var evs := BattBmsLogic.step(st, p, bms, {"cell_v": gv, "i_a": i_pack, "t_max": tmax_c,
				"t_min": tmin_c, "cap_ah": float(e["ah"])}, dt, t)
			for ev in evs:
				ev["t"] = t
				events.append(ev)
			# A switch that just opened takes effect this step.
			var i2 := BattBmsLogic.allowed_current(st, want)
			if i2 != i_pack:
				i_pack = i2
				for g in S:
					gv[g] = g_ocv[g] + i_pack * g_r[g]
			bleed = BattBmsLogic.balance(bal, gv, i_pack)
		var v_pack := v0 + i_pack * rp
		if absf(i_pack) > absf(i_peak):
			i_peak = i_pack
		if not protected and not short_said and float(pl["short_ohm"]) > 0.0 and t >= float(pl["short_at"]):
			short_said = true
			events.append({"t": t, "key": "short", "what": "trip",
				"text": "Shorted: %s A flows and nothing in the battery stops it; only a fuse or breaker would" % UiText.thousands(int(-i_pack))})
		# Lead-acid: the inverter's low-voltage cutoff.
		if float(pl["lvd_v"]) > 0.0 and stop_t < 0.0 and float(pl["load_a"]) > 0.0 and v_pack <= float(pl["lvd_v"]):
			stop_t = t
			events.append({"t": t, "key": "lvd", "what": "trip",
				"text": "The inverter's low-voltage cutoff stopped the load at %.1f V: nothing in the battery would have" % v_pack})
		# Advance the cells.
		var stored := 0.0
		var heat := 0.0
		var bleed_w := 0.0
		for g in S:
			for j in P:
				var k := g * P + j
				var ik := (gv[g] - ocv_k[k]) / r_k[k]
				var ib := bleed[g] / float(P)
				var dq := (ik - ib) * dt / 3600.0
				soc[k] = clampf(soc[k] + dq / cap[k], -SOC_OVER, 1.0 + SOC_OVER)
				stored += ocv_k[k] * (ik - ib) * dt
				var q := ik * ik * r_k[k]
				heat += q * dt
				var qb := ib * ocv_k[k] if ib > 0.0 else 0.0
				bleed_w += ib * ocv_k[k] * dt
				temp[k] += ((q + qb) - ha * (temp[k] - amb)) * dt / c_th
				t_max = maxf(t_max, temp[k])
		var link_heat := i_pack * i_pack * r_ext * dt
		if i_pack > 0.0:
			led["in_wh"] += v_pack * i_pack * dt / 3600.0
			led["in_ah"] += i_pack * dt / 3600.0
		else:
			led["out_wh"] += -v_pack * i_pack * dt / 3600.0
			led["out_ah"] += -i_pack * dt / 3600.0
		led["stored_wh"] += stored / 3600.0
		led["heat_wh"] += (heat + link_heat) / 3600.0
		led["bleed_wh"] += bleed_w / 3600.0
		for g in S:
			v_hi = maxf(v_hi, gv[g])
			v_lo = minf(v_lo, gv[g])
		# The charger's end.
		if charger_on and stage == "absorb" and want < tail_a and t - abs_since > (60.0 if lithium else 3600.0) and not bool(pl["hold"]):
			if lithium:
				charger_on = false
				full_at = t
				st["soc_est"] = 1.0
				events.append({"t": t, "key": "charger", "what": "done",
					"text": "Charger: current tapered below %.1f A, it is full and the charger stops" % tail_a})
			else:
				stage = "float"
				full_at = t
				events.append({"t": t, "key": "charger", "what": "stage",
					"text": "Charger: absorb done, dropping to float (%.2f V a cell)" % v_flt})
		if protected and charger_on and not bool(st["chg"]) and bool(st["trips"]["cell_ov"]) and full_at < 0.0:
			full_at = t
		if step_i % every == 0 or step_i == steps:
			var gs := PackedFloat64Array()
			var gt := PackedFloat64Array()
			gs.resize(S)
			gt.resize(S)
			for g in S:
				var a := 0.0
				var tt := -INF
				for j in P:
					a += soc[g * P + j]
					tt = maxf(tt, temp[g * P + j])
				gs[g] = a / float(P)
				gt[g] = tt
			frames.append({"t": t, "v": v_pack, "i": i_pack, "w": v_pack * i_pack,
				"soc": _mean(soc), "soc_est": float(st["soc_est"]) if protected else _mean(soc),
				"chg": bool(st["chg"]) if protected else true, "dsg": bool(st["dsg"]) if protected else true,
				"cell_v": gv.duplicate(), "cell_soc": gs, "cell_t": gt, "bal": bleed.duplicate(),
				"amb": amb, "stage": stage if charger_on else ("" if lithium else "off")})
		# Stop rules (a little rest after, so the chart shows the recovery).
		if stop_t < 0.0:
			var full_stop := bool(pl["stop_on_full"]) and full_at >= 0.0 and float(pl["charge_a"]) > 0.0 and lithium
			var empty_stop := bool(pl["stop_on_empty"]) and protected and float(pl["load_a"]) > 0.0 and not bool(st["dsg"])
			if full_stop or empty_stop:
				stop_t = t
		if stop_t >= 0.0 and t - stop_t >= 600.0 and float(pl["hours"]) * 3600.0 > 1800.0:
			if step_i % every != 0:
				frames.append(frames[-1].duplicate())
				frames[-1]["t"] = t
			break
	var spread_mv := (_max(frames[-1]["cell_v"]) - _min(frames[-1]["cell_v"])) * 1000.0 if not frames.is_empty() else 0.0
	return {"plan": pl, "frames": frames, "events": events, "ledger": led,
		"duration_s": float(frames[-1]["t"]) if not frames.is_empty() else 0.0,
		"series": S, "parallel": P, "t_max": t_max, "v_hi": v_hi, "v_lo": v_lo,
		"spread_mv": spread_mv, "full_at": full_at, "i_peak": i_peak,
		"v_ov": float((p.get("cell_ov", {}) as Dictionary).get("trip", float(row["cell_max_v"]))),
		"v_uv": float((p.get("cell_uv", {}) as Dictionary).get("trip", float(row["cell_min_v"]))),
		"summary": _summary(id, d, led, events, frames, spread_mv, t_max)}


## Open-circuit voltage at a state of charge, with the steep knees at the
## ends a real cell has: the table's 0 % and 100 % points are resting
## voltages, but a cell being pushed past them rises to its maximum (or falls
## to its minimum) within the last ~1 % (`KNEE_W`).
static func _ocv(t: Array, s: float, nominal: float, top_k: float = 0.0, bot_k: float = 0.0,
		w: float = KNEE_W) -> float:
	if t.size() < 2:
		return nominal
	var u := clampf(s, 0.0, 1.0) / BattChem.OCV_STEP
	var i := mini(int(floorf(u)), t.size() - 2)
	var v := lerpf(float(t[i]), float(t[i + 1]), u - float(i))
	v += top_k * exp((s - 1.0) / w) - bot_k * exp(-s / w)
	return v


static func _mean(a: PackedFloat64Array) -> float:
	var s := 0.0
	for v in a:
		s += v
	return s / maxf(float(a.size()), 1.0)


static func _max(a: PackedFloat64Array) -> float:
	var m := -INF
	for v in a:
		m = maxf(m, v)
	return m


static func _min(a: PackedFloat64Array) -> float:
	var m := INF
	for v in a:
		m = minf(m, v)
	return m


## The frame at or before `t` (seconds), for the scrub.
static func frame_at(res: Dictionary, t: float) -> Dictionary:
	var fr: Array = res.get("frames", [])
	if fr.is_empty():
		return {}
	var lo := 0
	var hi := fr.size() - 1
	while lo < hi:
		var mid := (lo + hi + 1) / 2
		if float(fr[mid]["t"]) <= t:
			lo = mid
		else:
			hi = mid - 1
	return fr[lo]


## Time in words for the chart and the log: "3 h 12 min", "45 s", "0.30 ms".
static func time_words(s: float) -> String:
	if s <= 0.0:
		return "0 s"
	if s < 0.1:
		return "%.2f ms" % (s * 1000.0)
	if s < 120.0:
		return "%.0f s" % s
	if s < 7200.0:
		return "%.0f min" % (s / 60.0)
	return "%d h %02d min" % [int(s / 3600.0), int(fposmod(s, 3600.0) / 60.0)]


static func _summary(id: String, d: Dictionary, led: Dictionary, events: Array, frames: Array,
		spread_mv: float, t_max: float) -> String:
	var parts: Array = []
	if float(led["in_wh"]) > 0.5:
		parts.append("%.2f kWh in (%.0f Ah)" % [float(led["in_wh"]) * 0.001, float(led["in_ah"])])
	if float(led["out_wh"]) > 0.5:
		parts.append("%.2f kWh out (%.0f Ah)" % [float(led["out_wh"]) * 0.001, float(led["out_ah"])])
	var trips: Array = []
	for ev in events:
		if str(ev["what"]) == "trip":
			trips.append(str(ev["text"]))
	if not trips.is_empty():
		parts.append(str(trips[0]) + " at " + time_words(float(_first_trip(events))))
	if id == "short":
		var ip := 0.0
		for f in frames:
			ip = maxf(ip, -float(f["i"]))
		parts.append("peak %s A" % UiText.thousands(int(ip)))
	parts.append("hottest cell %.0f °C" % t_max)
	if id == "balance":
		parts.append("spread at the end %.0f mV" % spread_mv)
	return "; ".join(PackedStringArray(parts)) + "."


static func _first_trip(events: Array) -> float:
	for ev in events:
		if str(ev["what"]) == "trip":
			return float(ev["t"])
	return 0.0
