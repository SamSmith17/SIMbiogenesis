class_name WindLabGen
extends RefCounted

## A permanent-magnet generator (or a brushed DC motor run as a dynamo) and
## what it puts into its load at a shaft speed: the back-EMF, the current,
## the power delivered, the copper loss and the torque it takes to turn.
## Pure static.
##
## AC machines (steppers, 3-phase PM): each phase is a sinusoidal EMF E (peak)
## behind its resistance R and reactance X = ωe·L (ωe = pole pairs × ω). It
## feeds a diode bridge into a fixed DC voltage Vc (the battery plus the
## diodes' drop). A bridge into a stiff DC bus puts a square wave on the
## phase; its fundamental is in phase with the current, with amplitude
##   U = (4/π)·Vc   for one phase on its own full bridge (a stepper's two
##                  phases, each rectified, outputs paralleled)
##   U = (2/π)·Vc   for one phase of a 3-phase six-pulse bridge
## (the fundamental of a square / six-step wave — Mohan, Undeland & Robbins,
## Power Electronics, ch. 8). The phasor balance E² = (U + R·I)² + (X·I)²
## gives the current peak
##   I = [−R·U + √(R²U² − Z²(U² − E²))] / Z²,  Z² = R² + X²
## and the power into the bridge n·U·I/2, the copper loss n·R·I²/2. No
## current flows until E > U: that is the generator's cut-in. Because X grows
## with speed as fast as E does, a stepper's current levels off at
## I → K/(p·L) however fast it turns — the "stepper as generator" ceiling.
##
## Stepper constants: the torque constant per phase K = T_hold / (√2·I_rated)
## (the holding torque is quoted with both phases at rated current, adding
## as two vectors 90° apart), and the back-EMF constant equals it in SI.
## 3-phase: E_peak = V_dc,oc / (3√3/π) from the rectified volts per rpm.
## DC: E = k·rpm, I = (E − Vc)/R straight through one blocking diode.
##
## Loads: "battery" (a fixed Vb), "mppt" (a controller that picks the input
## voltage giving the most power, then converts at its efficiency into the
## battery), "resistor" (a dump load: the bus settles where the bridge's
## current equals the resistor's).

const SQRT2 := 1.4142135623730951
const K_3PH := 1.6539866862653764      ## 3√3/π
const RPM_TO_RAD := TAU / 60.0

static var _tables: Dictionary = {}


static func clear_cache() -> void:
	_tables.clear()


## Per-phase EMF constant (V peak per rad/s) and the machine's phase count.
static func emf_constant(gen: Dictionary) -> float:
	match str(gen["kind"]):
		"stepper":
			return float(gen["hold_nm"]) / (SQRT2 * float(gen["amps"]))
		"ac3":
			return float(gen["v_per_rpm"]) / K_3PH / RPM_TO_RAD
		"dc":
			return float(gen["v_per_rpm"]) / RPM_TO_RAD
	return 0.01


static func phases(gen: Dictionary) -> int:
	match str(gen["kind"]):
		"stepper":
			return 2
		"ac3":
			return 3
	return 1


## Open-circuit DC volts at a speed (what a meter on the rectifier output
## reads with nothing connected, before the diodes).
static func open_circuit_v(gen: Dictionary, rpm: float) -> float:
	var e := emf_constant(gen) * rpm * RPM_TO_RAD
	match str(gen["kind"]):
		"ac3":
			return e * K_3PH
	return e


## The electrical side at a fixed DC clamp voltage vc (the bridge's DC side).
## Returns {i_ph (peak), p_bridge (W into the bridge, all phases), p_cu,
## i_dc}.
static func at_clamp(gen: Dictionary, rpm: float, vc: float) -> Dictionary:
	var w := rpm * RPM_TO_RAD
	var kind := str(gen["kind"])
	var R := float(gen["ohm"])
	if kind == "dc":
		var e := emf_constant(gen) * w
		var v_in := vc + float(gen.get("brush_v", 1.0))
		var i := maxf((e - v_in) / maxf(R, 1e-4), 0.0)
		return {"i_ph": i, "p_bridge": i * vc, "p_cu": i * i * R + i * float(gen.get("brush_v", 1.0)), "i_dc": i,
			"p_em": e * i}
	var n := phases(gen)
	var e_pk := emf_constant(gen) * w
	var u := (4.0 / PI if kind == "stepper" else 2.0 / PI) * vc
	if e_pk <= u or w <= 0.0:
		return {"i_ph": 0.0, "p_bridge": 0.0, "p_cu": 0.0, "i_dc": 0.0, "p_em": 0.0}
	var x := w * float(gen.get("pole_pairs", 1)) * float(gen.get("mh", 0.0)) * 0.001
	var z2 := R * R + x * x
	var disc := R * R * u * u - z2 * (u * u - e_pk * e_pk)
	var ip := (-R * u + sqrt(maxf(disc, 0.0))) / maxf(z2, 1e-9)
	ip = maxf(ip, 0.0)
	var pb := float(n) * u * ip * 0.5
	var pcu := float(n) * R * ip * ip * 0.5
	return {"i_ph": ip, "p_bridge": pb, "p_cu": pcu, "i_dc": pb / maxf(vc, 1e-6), "p_em": pb + pcu}


## The whole generator into its load at a shaft speed. count = generators
## on one shaft (each takes the same speed). Returns {p_load (W into the
## battery / resistor), p_em (W the magnets take from the shaft), torque_nm
## (all of it: electromagnetic + friction), v_dc (the bridge's DC side),
## i_dc, i_ph, e_oc (open-circuit DC volts), freq_hz, eff}.
static func operate(gen: Dictionary, load: Dictionary, rpm: float, count: int = 1) -> Dictionary:
	var w := rpm * RPM_TO_RAD
	var kind := str(gen["kind"])
	var vd := float(WindLabParts.DIODES.get(str(load.get("diode", "schottky")), WindLabParts.DIODES["schottky"])["v"])
	var drops := 2.0 * vd if kind != "dc" else vd
	var lt := str(load.get("type", "battery"))
	var r: Dictionary = {}
	var vc := 0.0
	var p_load := 0.0
	match lt:
		"battery":
			vc = float(load["battery_v"]) + drops
			r = at_clamp(gen, rpm, vc)
			p_load = float(r["i_dc"]) * float(load["battery_v"])
		"mppt":
			var hi := open_circuit_v(gen, rpm)
			var lo := float(load["mppt_min_v"]) + drops
			if hi <= lo:
				r = at_clamp(gen, rpm, hi + 1.0)
				vc = hi
			else:
				# Golden-section search for the input voltage giving the most
				# power (the controller's tracking).
				var a := lo
				var b := hi
				var gr := 0.6180339887
				var c1 := b - gr * (b - a)
				var c2 := a + gr * (b - a)
				var f1 := _mppt_p(gen, rpm, c1, drops)
				var f2 := _mppt_p(gen, rpm, c2, drops)
				for _i in 14:
					if f1 < f2:
						a = c1
						c1 = c2
						f1 = f2
						c2 = a + gr * (b - a)
						f2 = _mppt_p(gen, rpm, c2, drops)
					else:
						b = c2
						c2 = c1
						f2 = f1
						c1 = b - gr * (b - a)
						f1 = _mppt_p(gen, rpm, c1, drops)
				vc = (a + b) * 0.5
				r = at_clamp(gen, rpm, vc)
			p_load = float(r["i_dc"]) * maxf(vc - drops, 0.0) * float(load["mppt_eff"])
		"resistor":
			var rl := float(load["resistor_ohm"]) / float(maxi(count, 1))
			var lo2 := drops
			var hi2 := open_circuit_v(gen, rpm) + drops
			# The bus voltage where the bridge's current equals the resistor's:
			# the bridge's falls as the voltage rises, the resistor's grows.
			for _i in 40:
				var mid := (lo2 + hi2) * 0.5
				var ib := float(at_clamp(gen, rpm, mid)["i_dc"])
				if ib > (mid - drops) / rl:
					lo2 = mid
				else:
					hi2 = mid
			vc = (lo2 + hi2) * 0.5
			r = at_clamp(gen, rpm, vc)
			p_load = float(r["i_dc"]) * maxf(vc - drops, 0.0)
	var cnt := float(maxi(count, 1))
	var p_em := float(r["p_em"]) * cnt
	var fr := float(gen["friction_nm"]) * cnt if w > 0.0 else 0.0
	var torque := (p_em / w if w > 1e-6 else 0.0) + fr
	var p_shaft := torque * w
	var pl := p_load * cnt
	return {"p_load": pl, "p_em": p_em, "torque_nm": torque, "v_dc": vc, "i_dc": float(r["i_dc"]) * cnt,
		"i_ph": float(r["i_ph"]), "e_oc": open_circuit_v(gen, rpm), "freq_hz": rpm / 60.0 * float(gen.get("pole_pairs", 1)),
		"eff": pl / p_shaft if p_shaft > 1e-6 else 0.0, "p_shaft": p_shaft}


static func _mppt_p(gen: Dictionary, rpm: float, vc: float, drops: float) -> float:
	var r := at_clamp(gen, rpm, vc)
	return float(r["i_dc"]) * maxf(vc - drops, 0.0)


## The current a stepper's phases level off at however fast it turns (A
## peak): K / (p·L). 0 for machines without it.
static func current_ceiling(gen: Dictionary) -> float:
	var l := float(gen.get("mh", 0.0)) * 0.001
	var p := float(gen.get("pole_pairs", 0))
	if l <= 0.0 or p <= 0.0:
		return 0.0
	return emf_constant(gen) / (p * l)


## An MPPT controller holding the shaft at a chosen load: the magnets take
## p_em (W, all generators) at this speed; the current that needs (in phase
## with the EMF — the controller's job), its copper loss, the bridge's DC
## voltage and the controller's efficiency give the power into the battery.
## Below the controller's input window it delivers nothing.
## {p_load, i_ph, v_dc, ok}.
static func mppt_from_em(gen: Dictionary, load: Dictionary, rpm: float, p_em: float, count: int = 1) -> Dictionary:
	var cnt := float(maxi(count, 1))
	var pe := p_em / cnt
	var w := rpm * RPM_TO_RAD
	var vd := float(WindLabParts.DIODES.get(str(load.get("diode", "schottky")), WindLabParts.DIODES["schottky"])["v"])
	var kind := str(gen["kind"])
	var e := emf_constant(gen) * w
	var R := float(gen["ohm"])
	if pe <= 0.0 or e <= 1e-6:
		return {"p_load": 0.0, "i_ph": 0.0, "v_dc": 0.0, "ok": false}
	var i := 0.0
	var pcu := 0.0
	var vc := 0.0
	var drops := 0.0
	if kind == "dc":
		i = pe / e
		var brush := float(gen.get("brush_v", 1.0))
		pcu = i * i * R + i * brush
		vc = e - i * R - brush
		drops = vd
	else:
		var n := float(phases(gen))
		i = 2.0 * pe / (n * e)
		pcu = n * R * i * i * 0.5
		var u := maxf(e - R * i, 0.0)
		vc = u * (PI / 4.0 if kind == "stepper" else PI / 2.0)
		drops = 2.0 * vd
	if vc < float(load["mppt_min_v"]) + drops:
		return {"p_load": 0.0, "i_ph": i, "v_dc": vc, "ok": false}
	var pb := maxf(pe - pcu, 0.0)
	var pl := pb * (vc - drops) / maxf(vc, 1e-6) * float(load["mppt_eff"])
	return {"p_load": pl * cnt, "i_ph": i, "v_dc": vc, "ok": true}


## A cached speed → {torque, p_load, ...} table for one generator and load,
## so the operating-point search reads it instead of solving the circuit.
## The speed grid is QUADRATIC (dense near standstill, where small turbines
## live) up to four times the generator's top speed, the same for every
## drive ratio so the ratio search reuses it. For an MPPT load the torque
## column is the friction alone and p_em_max is the most the magnets can take
## at the controller's lowest input voltage (the operating point is chosen by
## the controller, not by a fixed voltage).
const TABLE_N := 160


static func table_top_rpm(gen: Dictionary) -> float:
	return maxf(float(gen["max_rpm"]) * 4.0, 2000.0)


static func table(gen_id: String, load: Dictionary, count: int) -> Dictionary:
	var key := "%s|%s|%d" % [gen_id, var_to_str(load), count]
	if _tables.has(key):
		return _tables[key]
	if _tables.size() > 64:
		_tables.clear()
	var gen := WindLabParts.generator(gen_id)
	var top := table_top_rpm(gen)
	var mppt := str(load.get("type", "")) == "mppt"
	var vd := float(WindLabParts.DIODES.get(str(load.get("diode", "schottky")), WindLabParts.DIODES["schottky"])["v"])
	var drops := 2.0 * vd if str(gen["kind"]) != "dc" else vd
	var rpm := PackedFloat64Array()
	var tq := PackedFloat64Array()
	var pl := PackedFloat64Array()
	var vdc := PackedFloat64Array()
	var idc := PackedFloat64Array()
	var iph := PackedFloat64Array()
	var pmax := PackedFloat64Array()
	for i in TABLE_N:
		var u := float(i) / float(TABLE_N - 1)
		var n := top * u * u
		rpm.append(n)
		if mppt:
			var w := n * RPM_TO_RAD
			tq.append(float(gen["friction_nm"]) * float(maxi(count, 1)) if w > 0.0 else 0.0)
			var lim := at_clamp(gen, n, float(load["mppt_min_v"]) + drops)
			pmax.append(float(lim["p_em"]) * float(maxi(count, 1)))
			pl.append(0.0)
			vdc.append(open_circuit_v(gen, n))
			idc.append(0.0)
			iph.append(0.0)
		else:
			var o := operate(gen, load, n, count)
			tq.append(float(o["torque_nm"]))
			pl.append(float(o["p_load"]))
			vdc.append(float(o["v_dc"]))
			idc.append(float(o["i_dc"]))
			iph.append(float(o["i_ph"]))
			pmax.append(float(o["p_em"]))
	var t := {"rpm": rpm, "torque": tq, "p_load": pl, "v_dc": vdc, "i_dc": idc, "i_ph": iph, "p_em_max": pmax,
		"top": top, "mppt": mppt, "gen": gen, "load": load, "count": count}
	_tables[key] = t
	return t


## Read the table at a speed (linear between rows on the quadratic grid;
## past the top it is held, which the design's checks call out as over-speed).
static func lookup(t: Dictionary, rpm: float, field: String) -> float:
	var top := float(t["top"])
	var arr: PackedFloat64Array = t[field]
	if rpm <= 0.0:
		return arr[0] if field != "torque" else 0.0
	var x := sqrt(clampf(rpm / maxf(top, 1e-6), 0.0, 1.0)) * float(TABLE_N - 1)
	var i := mini(int(floor(x)), TABLE_N - 2)
	var u := x - float(i)
	return lerpf(arr[i], arr[i + 1], u)
