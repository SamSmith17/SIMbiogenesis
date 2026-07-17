class_name ConduitLoss
extends RefCounted

## Pure connector loss physics (Wave 8). No scene access — headless-testable.
##
## Electrical: series resistive loss on a two-conductor run.
##   I = P_delivered / V_load            (load current)
##   P_loss = I^2 * R_loop               (Joule heating, R_loop = ohm_per_m * L)
##   V_drop = I * R_loop; drop_pct = V_drop / V_nominal
##   Source: any circuits text; ohm/m values from NEC Ch.9 Table 8.
##
## Hydraulic: Hazen-Williams head loss for water in pressure conduits.
##   h_f = 10.67 * L * Q^1.852 / (C^1.852 * D^4.87)   [SI: m head, Q m^3/s, D m]
##   Source: Mays, "Water Distribution Systems Handbook" (2000), Eq. 2.31.
##   Valid for water near 20 C — fine for the game's irrigation/plumbing scale.

const HW_COEFF := 10.67          ## SI Hazen-Williams constant
const PSI_PER_M_HEAD := 1.42233  ## 1 m H2O = 1.42233 psi
const LPM_TO_M3S := 1.0 / 60000.0


## Resistive loss for delivering `delivered_w` at the far end of a run.
## Returns {loss_w, drop_pct, amps}. Zero-length or unpowered runs lose nothing.
static func electrical_loss(delivered_w: float, volts: float, length_m: float,
		ohm_per_m: float) -> Dictionary:
	if delivered_w <= 0.0 or volts <= 0.0 or length_m <= 0.0 or ohm_per_m <= 0.0:
		return {"loss_w": 0.0, "drop_pct": 0.0, "amps": 0.0}
	var amps: float = delivered_w / volts
	var r_loop: float = ohm_per_m * length_m
	var loss_w: float = amps * amps * r_loop
	var drop_pct: float = (amps * r_loop) / volts
	return {"loss_w": loss_w, "drop_pct": drop_pct, "amps": amps}


## Hazen-Williams pressure drop for a flow through a pipe/hose run.
## Returns {drop_psi, derate_frac} where derate_frac (0..1) scales deliverable
## flow: the fraction of a nominal supply head (default 40 psi ~ household
## hose bib) remaining after friction. derate_frac=1 → no loss.
static func hydraulic_drop(flow_lpm: float, length_m: float, inner_d_m: float,
		hw_c: float, supply_psi: float = 40.0) -> Dictionary:
	if flow_lpm <= 0.0 or length_m <= 0.0 or inner_d_m <= 0.0 or hw_c <= 0.0:
		return {"drop_psi": 0.0, "derate_frac": 1.0}
	var q_m3s: float = flow_lpm * LPM_TO_M3S
	var head_m: float = HW_COEFF * length_m * pow(q_m3s, 1.852) \
			/ (pow(hw_c, 1.852) * pow(inner_d_m, 4.87))
	var drop_psi: float = head_m * PSI_PER_M_HEAD
	var frac: float = 1.0
	if supply_psi > 0.0:
		frac = clampf(1.0 - drop_psi / supply_psi, 0.0, 1.0)
	return {"drop_psi": drop_psi, "derate_frac": frac}


## Overload ratio for an electrical run: carried current vs ampacity.
## >1.0 means the conductor is over its continuous rating.
static func electrical_overload_ratio(amps: float, ampacity_a: float) -> float:
	if ampacity_a <= 0.0:
		return 0.0
	return maxf(amps, 0.0) / ampacity_a

## Overload ratio for a fluid run: worst of flow vs rating and pressure vs burst.
static func fluid_overload_ratio(flow_lpm: float, max_flow_lpm: float,
		pressure_psi: float = 0.0, burst_psi: float = 0.0) -> float:
	var r := 0.0
	if max_flow_lpm > 0.0:
		r = maxf(r, maxf(flow_lpm, 0.0) / max_flow_lpm)
	if burst_psi > 0.0:
		r = maxf(r, maxf(pressure_psi, 0.0) / burst_psi)
	return r


## ---------------------------------------------------------------------------
## Overload → burnout accumulator (pure; ticked by SystemGraphView).
## Models a thermal fuse: excess-over-rating integrates as "heat seconds"
## ((ratio - 1) × dt), cooling at COOL_RATE when back under rating. Reaching
## BURNOUT_HEAT_S severs the connector: 2× rating burns out in ~5 s of sim
## tick time, 1.2× in ~25 s (I²t fuse curve first-order approximation).
## ---------------------------------------------------------------------------

const BURNOUT_HEAT_S := 5.0
const COOL_RATE := 0.5  ## heat-seconds shed per second under rating


static func step_overload_heat(heat: float, overload_ratio: float,
		dt_s: float) -> float:
	if dt_s <= 0.0:
		return heat
	if overload_ratio > 1.0:
		return heat + (overload_ratio - 1.0) * dt_s
	return maxf(heat - COOL_RATE * dt_s, 0.0)


static func is_burned_out(heat: float) -> bool:
	return heat >= BURNOUT_HEAT_S


## Convenience: full electrical report for a connection dict + conduit meta.
## delivered_w = downstream draw. Uses route_length_m (fallback estimated_length).
static func electrical_report_for_connection(conn: Dictionary, meta: Dictionary,
		delivered_w: float) -> Dictionary:
	var length_m: float = maxf(
		float(conn.get("route_length_m", 0.0)),
		float(conn.get("estimated_length", 0.0)))
	var volts: float = float(meta.get("nominal_volts", 120.0))
	var ohm_per_m: float = float(meta.get("resistance_ohm_per_m", 0.0))
	var res := electrical_loss(delivered_w, volts, length_m, ohm_per_m)
	res["overload_ratio"] = electrical_overload_ratio(
		float(res.get("amps", 0.0)), float(meta.get("ampacity_a", 0.0)))
	res["length_m"] = length_m
	return res


## Convenience: full hydraulic report for a connection dict + conduit meta.
## flow_lpm = commanded transfer rate through the conduit.
static func hydraulic_report_for_connection(conn: Dictionary, meta: Dictionary,
		flow_lpm: float) -> Dictionary:
	var length_m: float = maxf(
		float(conn.get("route_length_m", 0.0)),
		float(conn.get("estimated_length", 0.0)))
	var inner_d: float = float(meta.get("inner_diameter_m", 0.0))
	var hw_c: float = float(meta.get("hw_c", 150.0))
	var supply_psi: float = float(conn.get("supply_pressure_psi", 40.0))
	if supply_psi <= 0.0:
		supply_psi = 40.0
	var res := hydraulic_drop(flow_lpm, length_m, inner_d, hw_c, supply_psi)
	res["overload_ratio"] = fluid_overload_ratio(
		flow_lpm, float(meta.get("max_flow_lpm", 0.0)),
		float(res.get("drop_psi", 0.0)), float(meta.get("burst_pressure_psi", 0.0)))
	res["length_m"] = length_m
	return res
