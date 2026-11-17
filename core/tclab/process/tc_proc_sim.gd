class_name TcProcSim
extends RefCounted

## The TC Process Lab's process model (Phase 2): a lumped control-volume
## simulation of a TC assembly over time. Educational, not a chemistry
## engine: it gets the theory of operation right (what happens where, in
## what order, roughly how much and how long) at a few hundred µs a step.
##
##   var sim := TcProcSim.create(TcDesign.solve(spec))
##   sim.run_for(3600.0)          # an hour, in DT_DEFAULT steps
##   sim.readings()               # temperatures, pressures, flows, products
##
## Each step (dt ≈ 5 s, every part unconditionally stable):
##  1. the charge (TcBed): element heat, conduction, drying, pyrolysis; its
##     steam and volatiles enter the vessel's gas;
##  2. liquid pools: heater into a pool when it is covered, boiling at the
##     bubble point (Raoult, Wilson γ for ethanol / water);
##  3. walls: gas ↔ wall (natural convection), wall → ambient through the
##     jacket gap / insulation, condenser wall ↔ its cooling water;
##  4. condensation / evaporation of every condensable toward the wall's
##     saturation pressure (a mass-transfer time constant);
##  5. tar cracking in hot gas;
##  6. the pressure network: p = nRT/V per CV, link flows from Δp through a
##     conductance (laminar Hagen–Poiseuille, or turbulent √Δp with Darcy f
##     and minor losses), solved IMPLICITLY by warm-started Gauss–Seidel on
##     the CV pressures; species and enthalpy advected upwind with mixing
##     cells (positive and mass-exact at any dt);
##  7. liquids drain by gravity to the lowest connected CV; drains collect;
##  8. events and keyframes.
##
## State is plain arrays so snapshot() / restore() are deep copies; the
## lab scrubs by restoring the nearest keyframe and re-stepping.
##
## Energy: gas and liquid carry sensible enthalpy relative to T0 (J); the
## latent heat of every evaporation is booked, and paid back on
## condensation, so `energy_ledger()` closes (the selftest checks it).

const T0 := 298.15
const DT_DEFAULT := 5.0
const KEYFRAME_S := 120.0
const SP := ["H2O", "CO", "CO2", "H2", "CH4", "N2", "O2", "C3H6", "tar", "acetic", "ethanol", "oil", "wax"]
const NS := 13
const I_H2O := 0
const I_CO := 1
const I_CO2 := 2
const I_H2 := 3
const I_CH4 := 4
const I_N2 := 5
const I_O2 := 6
const I_C3H6 := 7
const I_TAR := 8
const COND := [0, 8, 9, 10, 11, 12]
const STEEL_CP := 500.0          # J/kg·K, stainless
const MU_GAS := 2.5e-5           # Pa·s, steam / woodgas near 400 K (estimate)
const F_DARCY := 0.02            # smooth tube, turbulent
const K_MINOR_PER_PART := 0.4    # an elbow / tee / ferrule each (estimate)
const K_MASS := 0.01             # m/s, wall mass-transfer coefficient (estimate)
const H_GAS_WALL := 15.0         # W/m²·K, gas ↔ wall inside the pipework (estimate)
const H_COOLANT := 1200.0        # W/m²·K, wall → cooling water in the jacket (estimate: water-cooled tube-in-tube condensers run ~800–1500 overall)
const H_OUT := 9.0               # W/m²·K, outer surface → room (natural convection + radiation)
const K_AIR := 0.03              # W/m·K, still air in a jacket gap
const K_INSUL := 0.045           # W/m·K, mineral wool
const FILM_L_PER_M2 := 0.05      # liquid a wet wall holds before it runs (L/m², estimate)
const GS_SWEEPS := 6
const ELEMENT_FUSE_K := 1173.15  # an element's sheath cuts out above 900 °C (thermal fuse)
const BED_EVERY := 6             # the charge steps every 6th step (30 s; its time scale is minutes, its conduction implicit)

var net: Dictionary
var proc: Dictionary
var design_key := ""
var t_s := 0.0
var n_cv := 0
# Per CV.
var gas: Array = []        # PackedFloat64Array (mol per species)
var liq: Array = []        # PackedFloat64Array (mol per species)
var h_gas := PackedFloat64Array()   # sensible J
var h_liq := PackedFloat64Array()
var t_wall := PackedFloat64Array()
var c_wall := PackedFloat64Array()
var v_free := PackedFloat64Array()
var p_cv := PackedFloat64Array()
var t_cool := PackedFloat64Array()   # coolant CVs: water T
var flow_link := PackedFloat64Array()  # mol/s, + = a → b
var g_link := PackedFloat64Array()     # mol/s·Pa, this step
var vel_link := PackedFloat64Array()   # m/s
var cv_flow := PackedFloat64Array()    # mol/s through a CV (for views)
var react_rate := []                   # per CV: {kind: rate} this step (for the molecule lens)
var link_open: Array = []
## Per link: how far open (0..1). 1 for everything but a control valve.
var link_frac: Array = []
## Pumps (TcParts "pump"), by part id.
var pump_on: Dictionary = {}
var pump_speed: Dictionary = {}     # 0..1
var pump_lpm: Dictionary = {}       # what it moves now, L/min
var pump_kwh := 0.0
## Liquid lines between vessels: [{a, b, links, len_m, r_m, za, zb, lpm}]
## (lpm > 0 = a → b). See _lines_step.
var lines: Array = []
var _vessel_floor: Dictionary = {}  # cv → floor height, m
var _breathers: Array = []          # open-topped vessels on a line
var _pump_dst: Dictionary = {}      # pump part → the vessel it is filling
## Every heater's vessel (heater_parts lists the charge vessel's first:
## the first n_bed_heaters sit in the charge).
var heater_cv: Dictionary = {}
var n_bed_heaters := 0
## Agitators: part → {cv, w}; agit_on: part → bool.
var agit: Dictionary = {}
var agit_on: Dictionary = {}
var _agit_cv: Dictionary = {}       # cv → true while stirred this step
## A vessel's jacket fed by a medium: cv → {part, t_c, lpm, on}.
var jacket: Dictionary = {}
## Plate exchangers: process-side cv → its service-water cv.
var _plate_hx: Dictionary = {}
var relief_open: Array = []
var drain_open := {}       # boundary index → bool
var heater_w := {}         # part → watts asked
var heater_on := {}        # part → bool
var heater_fused := {}
var cool_lpm := {}         # coolant cv → L/min
var bed: TcBed = null
var vessel_cv := -1
var vessel_xf := Transform3D.IDENTITY
var heater_parts: Array = []
var _bed_acc := 0.0        # seconds since the bed last stepped
var _bed_n := 0
var _bed_rel: Dictionary = {}   # what the bed gave off, released over the next steps
var _bed_rel_left := 0.0
var element_t: Array = []
var events: Array = []
var _event_seen := {}
var keyframes: Array = []
var _next_key := 0.0
# Ledgers (J / mol / kg).
var e_in := 0.0
var e_loss := 0.0
var e_cool := 0.0
var e_react := 0.0
var e_out := 0.0
var product_mol := PackedFloat64Array()
var vented_mol := PackedFloat64Array()
var drained_mol := PackedFloat64Array()
var product_rate := PackedFloat64Array()   # mol/s this step
var drained_by := {}       # drain boundary index → kg collected there
var _mass0 := 0.0
var _order: Array = []     # CVs by height, high first (liquid draining)
var _down: Array = []      # per CV: [[link, other cv]] for gravity
var _boundary_p := {}      # boundary index → Pa
var _cv_links: Array = []  # per CV: link indices
var _is_condenser: Array = []   # per CV: a cooled condenser (streams condense through it)
var _air := PackedFloat64Array()
var _last_product_x := PackedFloat64Array()
var _cache_psat := {}
# Process units (TcUnits): gas holders, dryers, engines, flares.
var units: Array = []                   # [{cv, kind, part, ...the unit's numbers}]
var ads_mol := PackedFloat64Array()     # per CV: water held in a dryer's sorbent (mol)
var burned_mol := PackedFloat64Array()  # per species: burned in an engine / a flare (mol)
var engine_on := {}                     # part → bool
var engine_kw := {}                     # part → kW electric, this step
var engine_kwh := 0.0
var flare_kw := 0.0                     # heat released at the flares, this step
const ENGINE_MIN_PA := 2000.0           # an engine can pull its intake this far below 1 atm
const ENGINE_MIN_LHV := 2.5e6 * 0.022414  # J/mol: leaner than ~2.5 MJ/Nm³ a gas engine will not fire
const ENGINE_FEED_HOPS := 4             # how far up its line an engine "sees" the gas it will get
const SEAL_BLOW_PA := 1500.0            # an overfull bell lifts out of its water seal this far over its weight
var _eng_q := {}                        # engine CV → fuel demand this step (mol/s)
var _eng_take := PackedFloat64Array()   # per CV: gas an engine drew this step (mol)
var _eng_lhv := PackedFloat64Array()    # per CV: the heating value of what it drew (J/mol)
const HOLDER_MIN := 0.04                # an empty bell still holds this share of its volume
const SORBENT_CAPACITY := {"silica": 0.30, "carbon": 0.08}   # kg water per kg sorbent (estimates)
const SORB_MAX_K := 353.15              # sorbents stop taking water up above ~80 °C
# Control (TcProcControl): the design's sensors, actuators and automations.
var control_sensors: Array = []
var control_acts: Array = []
var automations: AutomationSim = null
## Control blocks (ScadaLogic) of the design (`process.logic`), run every
## step on the lab's clock. Tags are this design's own sensor / switch keys.
var logic_blocks: Array = []
var logic_state: Dictionary = {}
var logic_status: Dictionary = {}
var _logic_need: Dictionary = {}
var _logic_vals: Dictionary = {}
var _auto_need := {}
var _auto_acc := 0.0
var _base_lpm := 2.0
var _base_w := {}
static var CPG := PackedFloat64Array()   # J/mol·K gas
static var CPL := PackedFloat64Array()   # J/mol·K liquid
static var LAT := PackedFloat64Array()   # J/mol
static var MKG := PackedFloat64Array()   # kg/mol
static var RHOL := PackedFloat64Array()  # kg/m³
static var LHV := PackedFloat64Array()   # J/mol


static func _init_species() -> void:
	if CPG.size() == NS:
		return
	CPG.resize(NS)
	CPL.resize(NS)
	LAT.resize(NS)
	MKG.resize(NS)
	RHOL.resize(NS)
	LHV.resize(NS)
	for s in NS:
		var r := TcSpecies.row(SP[s])
		CPG[s] = float(r.get("cp_g", 30.0))
		CPL[s] = float(r.get("cp_l", 100.0))
		LAT[s] = float(r.get("h_vap", 40000.0))
		MKG[s] = float(r.get("M", 28.0)) * 0.001
		RHOL[s] = float(r.get("rho_l", 1000.0))
		LHV[s] = float(r.get("lhv", 0.0))


static func create(d: Dictionary, proc_override: Dictionary = {}) -> TcProcSim:
	var s := TcProcSim.new()
	var spec: Dictionary = d.get("spec", {})
	var pr: Dictionary = proc_override if not proc_override.is_empty() else TcProcSpec.resolve(spec.get("process", {}))
	s._setup(d, TcProcNet.build(d), pr)
	return s


func _setup(d: Dictionary, n: Dictionary, pr: Dictionary) -> void:
	_init_species()
	net = n
	proc = pr
	design_key = str(net.get("key", ""))
	var cvs: Array = net["cvs"]
	n_cv = cvs.size()
	var ta := float(proc["ambient_c"]) + 273.15
	_air = _zeros()
	_air[I_N2] = 0.7905
	_air[I_O2] = 0.2095
	_last_product_x = _air.duplicate()
	product_mol = _zeros()
	vented_mol = _zeros()
	drained_mol = _zeros()
	product_rate = _zeros()
	h_gas.resize(n_cv)
	h_liq.resize(n_cv)
	t_wall.resize(n_cv)
	c_wall.resize(n_cv)
	v_free.resize(n_cv)
	p_cv.resize(n_cv)
	t_cool.resize(n_cv)
	cv_flow.resize(n_cv)
	for i in n_cv:
		var cv: Dictionary = cvs[i]
		var g := _zeros()
		var vol := maxf(float(cv["volume_m3"]), 1e-6)
		v_free[i] = vol
		t_wall[i] = ta
		c_wall[i] = maxf(float(cv["wall_mass_kg"]), 0.05) * STEEL_CP
		t_cool[i] = float(proc["cooling"]["t_c"]) + 273.15
		gas.append(g)
		liq.append(_zeros())
		react_rate.append({})
		_cv_links.append([])
		_is_condenser.append(str(cv["role"]) == "condenser")
		if str(cv["role"]) == "vessel" and vessel_cv < 0:
			vessel_cv = i
	# The charge.
	var res: Dictionary = d.get("res", {})
	if vessel_cv >= 0:
		var vcv: Dictionary = cvs[vessel_cv]
		var vp := str(vcv.get("vessel_part", ""))
		if res.has("parts") and (res["parts"] as Dictionary).has(vp):
			vessel_xf = res["parts"][vp]["xf"]
		var heaters: Array = []
		for h in vcv["heaters"]:
			var at: Vector3 = vessel_xf.affine_inverse() * (h["at_mm"] as Vector3)
			var dir: Vector3 = (vessel_xf.basis.inverse() * (h["dir"] as Vector3)).normalized()
			var hh := {"part": str(h["part"]), "at_mm": at, "reach_mm": float(h.get("reach_mm", 300.0))}
			if absf(dir.y) < 0.7:
				# A side element lies across one layer of the charge.
				hh["at_mm"] = Vector3(0, at.y - 30.0, 0)
				hh["reach_mm"] = 60.0
			heaters.append(hh)
			heater_parts.append(str(h["part"]))
			heater_cv[str(h["part"])] = vessel_cv
			var hs := TcProcSpec.heater(proc, str(h["part"]))
			heater_w[str(h["part"])] = float(hs["w"])
			heater_on[str(h["part"])] = bool(hs["on"])
			element_t.append(ta)
		var ch: Dictionary = proc["charge"]
		var fd: Dictionary = TcProcSpec.FEEDS.get(str(ch["feed"]), {})
		if fd.has("solid"):
			bed = TcBed.create(vcv, heaters, ch)
			bed.set_uniform_t(ta)
			v_free[vessel_cv] = maxf(float(vcv["volume_m3"]) - bed.solid_volume_m3, 1e-4)
		else:
			_fill_liquid(vessel_cv, ch, fd, ta)
	n_bed_heaters = heater_parts.size()
	# Elements in the other vessels heat whatever liquid stands in them.
	for i3 in n_cv:
		if i3 == vessel_cv or str(cvs[i3]["role"]) != "vessel":
			continue
		for h3 in cvs[i3]["heaters"]:
			var hp := str(h3["part"])
			heater_parts.append(hp)
			heater_cv[hp] = i3
			var hs3 := TcProcSpec.heater(proc, hp)
			heater_w[hp] = float(hs3["w"])
			heater_on[hp] = bool(hs3["on"])
			element_t.append(ta)
	for i4 in n_cv:
		for at4 in cvs[i4].get("attach", []):
			if str(at4.get("role", "")) == "agitator":
				agit[str(at4["part"])] = {"cv": i4, "w": float(at4.get("watts", 120.0))}
				agit_on[str(at4["part"])] = bool(at4.get("start_on", false))
	var types := {}
	for sp0 in (d.get("spec", {}) as Dictionary).get("parts", []):
		types[str(sp0.get("id", ""))] = str(sp0.get("type", ""))
	for th1 in net["thermal"]:
		if str(th1["kind"]) != "condenser":
			continue
		var pc := int(th1["b"])
		for pp0 in cvs[pc].get("parts", []):
			if str(types.get(str(pp0), "")) == "plate_exchanger":
				_plate_hx[pc] = int(th1["a"])
	var jk: Variant = proc.get("jackets", {})
	if jk is Dictionary:
		for th0 in net["thermal"]:
			if str(th0["kind"]) != "jacket":
				continue
			for vi in [int(th0["a"]), int(th0["b"])]:
				if str(cvs[vi]["role"]) == "vessel" and (jk as Dictionary).has(str(cvs[vi].get("vessel_part", ""))):
					var js: Dictionary = jk[str(cvs[vi].get("vessel_part", ""))]
					jacket[vi] = {"part": str(cvs[vi].get("vessel_part", "")), "t_c": float(js.get("t_c", 60.0)),
						"lpm": float(js.get("lpm", 10.0)), "on": bool(js.get("on", false))}
	# Liquid in other vessels: process.liquids = [{part, litres, feed, t_c}].
	for lq in proc.get("liquids", []):
		if not (lq is Dictionary):
			continue
		for i in n_cv:
			if str(cvs[i]["role"]) == "vessel" and str(cvs[i].get("vessel_part", "")) == str(lq.get("part", "")):
				var lfd: Dictionary = TcProcSpec.FEEDS.get(str(lq.get("feed", "water")), {})
				_fill_liquid(i, {"mass_kg": float(lq.get("litres", 0.0))}, lfd, float(lq.get("t_c", proc.get("ambient_c", 20.0))) + 273.15)
	# Air everywhere at 1 atm; coolant circuits hold water, not gas.
	for i in n_cv:
		var role := str(cvs[i]["role"])
		var tg := ta
		var n_air := TcThermo.moles(TcSpecies.P_ATM, v_free[i], tg) if not (role in ["coolant", "jacket"]) else 0.0
		var g: PackedFloat64Array = gas[i]
		for s in NS:
			g[s] = n_air * _air[s]
		gas[i] = g
		h_gas[i] = _cp_total(g) * (tg - T0)
		p_cv[i] = TcSpecies.P_ATM if n_air > 0.0 else 0.0
	# Links.
	var links: Array = net["links"]
	flow_link.resize(links.size())
	g_link.resize(links.size())
	vel_link.resize(links.size())
	for li in links.size():
		var l: Dictionary = links[li]
		link_open.append(bool(l["open"]))
		link_frac.append(clampf(float(l.get("frac", 1.0)), 0.0, 1.0) if bool(l.get("throttle", false)) else 1.0)
		if str(l["kind"]) == "pump":
			var pm: Dictionary = l.get("pump", {})
			pump_on[str(l["part"])] = bool(pm.get("on", false))
			pump_speed[str(l["part"])] = 1.0
			pump_lpm[str(l["part"])] = 0.0
		relief_open.append(false)
		var a := int(l["a"])
		var b := int(l["b"])
		if a >= 0:
			(_cv_links[a] as Array).append(li)
		if b >= 0:
			(_cv_links[b] as Array).append(li)
	var bnds: Array = net["boundaries"]
	for bi in bnds.size():
		var bd: Dictionary = bnds[bi]
		match str(bd["role"]):
			"product":
				_boundary_p[bi] = TcSpecies.P_ATM + float(proc["back_kpa"]) * 1000.0
			"atmosphere", "outlet":
				_boundary_p[bi] = TcSpecies.P_ATM
			"drain":
				# A trap on the pipework drips into its jar; a labelled
				# liquid nozzle on a vessel stays shut until it is opened.
				var dc := int(bd["cv"])
				drain_open[bi] = dc < 0 or str(net["cvs"][dc]["role"]) != "vessel"
	for i in n_cv:
		if str(cvs[i]["role"]) == "coolant":
			cool_lpm[i] = float(proc["cooling"]["lpm"])
	# Gravity order and the ways down.
	for i in n_cv:
		_order.append(i)
		_down.append([])
	# A liquid's potential: its CV's low point, far lower where a drain is,
	# and along a LEVEL run (low points within 5 mm) one mm more per hop
	# from the nearest drain, so a level header runs to its drains.
	var pot := PackedFloat64Array()
	pot.resize(n_cv)
	for i in n_cv:
		pot[i] = float(cvs[i]["y_low_mm"])
	for bi in bnds.size():
		if str(bnds[bi]["role"]) == "drain" and int(bnds[bi]["cv"]) >= 0:
			var c := int(bnds[bi]["cv"])
			pot[c] = float(cvs[c]["y_low_mm"]) - 1000.0
	for _pass in n_cv:
		var changed := false
		for li in links.size():
			var l: Dictionary = links[li]
			var a := int(l["a"])
			var b := int(l["b"])
			if a < 0 or b < 0 or absf(float(cvs[a]["y_low_mm"]) - float(cvs[b]["y_low_mm"])) > 5.0:
				continue
			if pot[b] + 1.0 < pot[a]:
				pot[a] = pot[b] + 1.0
				changed = true
			elif pot[a] + 1.0 < pot[b]:
				pot[b] = pot[a] + 1.0
				changed = true
		if not changed:
			break
	_order.sort_custom(func(x, y): return pot[x] > pot[y])
	for li in links.size():
		var l: Dictionary = links[li]
		var a := int(l["a"])
		var b := int(l["b"])
		if a < 0 or b < 0:
			continue
		if pot[a] > pot[b] + 0.5:
			(_down[a] as Array).append([li, b])
		elif pot[b] > pot[a] + 0.5:
			(_down[b] as Array).append([li, a])
	_setup_units()
	_build_lines(d)
	_setup_control(d)
	zero_ledger()
	_mass0 = _mass_now()
	keyframes.append({"t_s": 0.0, "state": snapshot()})
	_next_key = KEYFRAME_S


func _zeros() -> PackedFloat64Array:
	var a := PackedFloat64Array()
	a.resize(NS)
	return a


func _fill_liquid(i: int, ch: Dictionary, fd: Dictionary, ta: float) -> void:
	var mass := float(ch.get("mass_kg", 10.0))
	var l: PackedFloat64Array = liq[i]
	if fd.has("liquid"):
		for k in (fd["liquid"] as Dictionary).keys():
			l[SP.find(k)] += mass * float(fd["liquid"][k]) / TcSpecies.molar_mass_kg(k)
	elif fd.has("liquid_vol"):
		var vols: Dictionary = fd["liquid_vol"]
		var tot := 0.0
		for k in vols.keys():
			tot += float(vols[k]) * float(TcSpecies.row(k)["rho_l"])
		for k in vols.keys():
			var kg := mass * float(vols[k]) * float(TcSpecies.row(k)["rho_l"]) / tot
			l[SP.find(k)] += kg / TcSpecies.molar_mass_kg(k)
	liq[i] = l
	h_liq[i] = _cp_liq_total(l) * (ta - T0)
	v_free[i] = maxf(v_free[i] - _liq_volume(l), 1e-4)


# ---------------------------------------------------------------------------
# Properties
# ---------------------------------------------------------------------------

func _cp_total(g: PackedFloat64Array) -> float:
	var c := 0.0
	for s in NS:
		if g[s] > 0.0:
			c += g[s] * CPG[s]
	return c


func _cp_mix(g: PackedFloat64Array) -> float:
	var n := _sum(g)
	return _cp_total(g) / n if n > 0.0 else 30.0


func _cp_liq_total(l: PackedFloat64Array) -> float:
	var c := 0.0
	for s in COND:
		if l[s] > 0.0:
			c += l[s] * CPL[s]
	return c


func _liq_volume(l: PackedFloat64Array) -> float:
	var v := 0.0
	for s in COND:
		if l[s] > 0.0:
			v += l[s] * MKG[s] / RHOL[s]
	return v


static func _sum(a: PackedFloat64Array) -> float:
	var s := 0.0
	for v in a:
		s += v
	return s


func gas_t(i: int) -> float:
	var c := _cp_total(gas[i])
	return T0 + h_gas[i] / c if c > 1e-9 else t_wall[i]


func liq_t(i: int) -> float:
	var c := _cp_liq_total(liq[i])
	return T0 + h_liq[i] / c if c > 1e-9 else t_wall[i]


func _psat(s: int, t_k: float) -> float:
	var key := s * 4096 + int(t_k * 4.0)
	if _cache_psat.has(key):
		return float(_cache_psat[key])
	var p := TcThermo.p_sat_pa(SP[s], t_k)
	if _cache_psat.size() > 20000:
		_cache_psat.clear()
	_cache_psat[key] = p
	return p


func _latent(s: int) -> float:
	return LAT[s]


# ---------------------------------------------------------------------------
# Actuators
# ---------------------------------------------------------------------------

## id: "heater:<part>" (watts, or bool), "valve:<part>" (0..1 / bool),
## "cooling:<cv>" or "cooling" (L/min), "drain:<ref>" (bool).
func set_actuator(id: String, value: Variant) -> void:
	var sp := id.split(":", true, 1)
	var kind := sp[0]
	var key := sp[1] if sp.size() > 1 else ""
	match kind:
		"heater":
			if value is bool:
				heater_on[key] = value
			else:
				heater_w[key] = maxf(float(value), 0.0)
				heater_on[key] = float(value) > 0.0
		"valve":
			for li in (net["links"] as Array).size():
				if str(net["links"][li]["part"]) == key:
					link_open[li] = bool(value) if value is bool else float(value) > 0.05
		"cvalve":
			# A control valve's opening, 0..100 %.
			for li in (net["links"] as Array).size():
				if str(net["links"][li]["part"]) == key:
					link_frac[li] = clampf(float(value) / 100.0, 0.0, 1.0)
					link_open[li] = float(link_frac[li]) > 0.02
		"pump":
			if pump_on.has(key):
				pump_on[key] = bool(value) if value is bool else float(value) > 0.0
		"pumpspeed":
			if pump_speed.has(key):
				pump_speed[key] = clampf(float(value) / 100.0, 0.0, 1.0)
		"agitator":
			if agit_on.has(key):
				agit_on[key] = bool(value) if value is bool else float(value) > 0.0
		"jacket", "jackett", "jacketf":
			for jc in jacket.keys():
				if str(jacket[jc]["part"]) == key:
					if kind == "jacket":
						jacket[jc]["on"] = bool(value) if value is bool else float(value) > 0.0
					elif kind == "jackett":
						jacket[jc]["t_c"] = clampf(float(value), 0.0, 99.0)
					else:
						jacket[jc]["lpm"] = clampf(float(value), 0.0, 200.0)
		"cooling":
			for i in cool_lpm.keys():
				if key == "" or str(i) == key:
					cool_lpm[i] = maxf(float(value), 0.0)
		"drain":
			for bi in drain_open.keys():
				if str(net["boundaries"][bi]["ref"]) == key or key == "":
					drain_open[bi] = bool(value)
		"engine":
			for u in units:
				if str(u["kind"]) == "engine" and (key == "" or str(u["part"]) == key):
					engine_on[str(u["part"])] = bool(value) if value is bool else float(value) > 0.0


# ---------------------------------------------------------------------------
# Stepping
# ---------------------------------------------------------------------------

func run_for(seconds: float, dt: float = DT_DEFAULT) -> void:
	var end := t_s + seconds
	while t_s < end - 1e-9:
		step(minf(dt, end - t_s))


## Steps until `until_s` or until `budget_usec` of wall time is spent.
## Returns true when it reached `until_s`.
func run_budget(until_s: float, budget_usec: int, dt: float = DT_DEFAULT) -> bool:
	var t0 := Time.get_ticks_usec()
	while t_s < until_s - 1e-9:
		step(minf(dt, until_s - t_s))
		if Time.get_ticks_usec() - t0 > budget_usec:
			return t_s >= until_s - 1e-9
	return true


func step(dt: float = DT_DEFAULT) -> void:
	var cvs: Array = net["cvs"]
	var ta := float(proc["ambient_c"]) + 273.15
	for i in n_cv:
		react_rate[i] = {}
	_prof_mark(0)
	# 1. The charge.
	if bed != null and not bed.is_empty() and vessel_cv >= 0:
		var hw: Array = []
		for k in n_bed_heaters:
			var pid: String = heater_parts[k]
			var w := float(heater_w.get(pid, 0.0)) if bool(heater_on.get(pid, true)) and not bool(heater_fused.get(pid, false)) else 0.0
			hw.append(w)
			e_in += w * dt
		_bed_acc += dt
		_bed_n += 1
		if _bed_n >= BED_EVERY or _bed_rel.is_empty():
			var pv := maxf(p_cv[vessel_cv], 1000.0)
			var tb := TcThermo.boiling_point_k("H2O", pv) if absf(pv - TcSpecies.P_ATM) > 200.0 else 373.15
			_bed_rel = bed.step(_bed_acc, hw, t_wall[vessel_cv], gas_t(vessel_cv), tb, t_s)
			_bed_rel_left = _bed_acc
			_bed_acc = 0.0
			_bed_n = 0
			element_t = _bed_rel["element_t"]
			_bed_events_due = true
		var f_rel := minf(dt / maxf(_bed_rel_left, 1e-9), 1.0)
		_bed_rel_left = maxf(_bed_rel_left - dt, 0.0)
		var r := _bed_scaled(_bed_rel, f_rel)
		_bed_rel = _bed_scaled(_bed_rel, 1.0 - f_rel)
		t_wall[vessel_cv] += float(r["to_wall_j"]) / c_wall[vessel_cv]
		h_gas[vessel_cv] += float(r["to_gas_j"])
		var g: PackedFloat64Array = gas[vessel_cv]
		var steam := float(r["steam_mol"])
		g[I_H2O] += steam
		h_gas[vessel_cv] += float(r["steam_j"]) + float(r["volatiles_j"])
		e_react += float(r["react_j"]) - float(r.get("formed_latent_j", 0.0))
		var vol: Dictionary = r["volatiles"]
		var made := 0.0
		for s in vol.keys():
			var idx := SP.find(s)
			if idx >= 0:
				var mol := float(vol[s]) / TcSpecies.molar_mass_kg(s)
				g[idx] += mol
				made += mol
				if idx in COND:
					e_react -= mol * _latent(idx)
		gas[vessel_cv] = g
		react_rate[vessel_cv] = {"drying": steam / dt, "pyrolysis": made / dt}
		for k in n_bed_heaters:
			var pid2: String = heater_parts[k]
			if k >= element_t.size():
				continue
			var te := float(element_t[k])
			if te > ELEMENT_FUSE_K and not bool(heater_fused.get(pid2, false)):
				heater_fused[pid2] = true
				_event("fuse_" + pid2, "An element's sheath passed 900 °C and its high-limit cut it out. Lower its power, or switch it with an automation.")
			elif bool(heater_fused.get(pid2, false)) and te < ELEMENT_FUSE_K - 150.0:
				heater_fused[pid2] = false
		if _bed_events_due:
			_bed_events_due = false
			_bed_events(r)
		_pool_heaters(dt, n_bed_heaters)
	else:
		_pool_heaters(dt, 0)
	# Agitators: the motor's work ends up as heat in the liquid.
	_agit_cv = {}
	for ap in agit.keys():
		if not bool(agit_on.get(ap, false)):
			continue
		var ac := int(agit[ap]["cv"])
		if _liq_volume(liq[ac]) > 0.001:
			_agit_cv[ac] = true
			var aw := float(agit[ap]["w"]) * dt
			e_in += aw
			h_liq[ac] += aw
	_prof_mark(1)
	# 2. Pools: boiling.
	for i in n_cv:
		_pool_step(i, dt)
	_prof_mark(2)
	# 3. Walls and coolant.
	for i in n_cv:
		_wall_step(i, dt, ta)
	_prof_mark(3)
	# 4. Condensation / evaporation on walls.
	for i in n_cv:
		_phase_step(i, dt)
	_prof_mark(4)
	# 5. Tar cracking.
	for i in n_cv:
		var gi: PackedFloat64Array = gas[i]
		if gi[I_TAR] <= 1e-9:
			continue
		var tg := gas_t(i)
		if tg < 650.0:
			continue
		var kg := gi[I_TAR] * TcSpecies.molar_mass_kg("tar")
		var cr := TcReactions.tar_crack(kg, tg, dt)
		var ck := float(cr["cracked_kg"])
		if ck <= 0.0:
			continue
		gi[I_TAR] -= ck / TcSpecies.molar_mass_kg("tar")
		e_react += ck / TcSpecies.molar_mass_kg("tar") * _latent(I_TAR)
		for s in (cr["gas"] as Dictionary).keys():
			var si := SP.find(s)
			var mol2 := float(cr["gas"][s]) / TcSpecies.molar_mass_kg(s)
			gi[si] += mol2
			if si in COND:
				e_react -= mol2 * _latent(si)
		gas[i] = gi
		e_react += float(cr["q_j"])
		h_gas[i] -= float(cr["q_j"])
		var rr: Dictionary = react_rate[i]
		rr["cracking"] = ck / TcSpecies.molar_mass_kg("tar") / dt
	_prof_mark(5)
	# 6. Gas flow.
	_flow_step(dt)
	_prof_mark(6)
	_unit_step(dt)
	# 7. Liquids.
	_drain_step(dt)
	if not lines.is_empty():
		_lines_step(dt)
	_prof_mark(7)
	t_s += dt
	_auto_acc += dt
	if automations != null and _auto_acc >= TcProcControl.AUTO_EVERY_S - 1e-9:
		_run_automations()
	if not logic_blocks.is_empty():
		_run_logic()
	if t_s >= _next_key:
		keyframes.append({"t_s": t_s, "state": snapshot()})
		_next_key += KEYFRAME_S
	_flow_events()


## The process units on the network's volumes.
func _setup_units() -> void:
	units = []
	ads_mol = PackedFloat64Array()
	ads_mol.resize(n_cv)
	burned_mol = _zeros()
	var cvs: Array = net["cvs"]
	var eng: Dictionary = (proc.get("engines", {}) as Dictionary)
	for i in n_cv:
		var u: Dictionary = (cvs[i] as Dictionary).get("unit", {})
		if u.is_empty():
			continue
		var e := u.duplicate(true)
		e["cv"] = i
		var kind := str(u.get("kind", ""))
		match kind:
			"holder":
				var cap := float(u.get("cap_l", 100.0)) * 0.001
				e["cap_m3"] = cap
				e["hold_pa"] = TcSpecies.P_ATM + float(u.get("hold_kpa", 0.8)) * 1000.0
				# An empty bell, with the air under it.
				v_free[i] = cap * HOLDER_MIN
				var ta := float(proc["ambient_c"]) + 273.15
				var n_air := TcThermo.moles(TcSpecies.P_ATM, v_free[i], ta)
				var g := _zeros()
				for sp in NS:
					g[sp] = n_air * _air[sp]
				gas[i] = g
				h_gas[i] = _cp_total(g) * (ta - T0)
			"dryer":
				e["cap_mol"] = float(u.get("sorbent_kg", 0.5)) * float(SORBENT_CAPACITY.get(str(u.get("packing", "silica")), 0.2)) / MKG[I_H2O]
			"engine":
				var pid := str(u.get("part", ""))
				engine_on[pid] = bool((eng.get(pid, {}) as Dictionary).get("on", false))
				engine_kw[pid] = 0.0
		units.append(e)


## A bell holder's volume follows its gas at the bell's pressure, between
## empty and full (then it is a rigid tank and the pressure rises).
func _holder_volumes() -> void:
	for u in units:
		if str(u["kind"]) != "holder":
			continue
		var i := int(u["cv"])
		var n := _sum(gas[i])
		var v := n * TcSpecies.R * maxf(gas_t(i), 200.0) / float(u["hold_pa"])
		var cap := float(u["cap_m3"])
		v_free[i] = clampf(v, cap * HOLDER_MIN, cap)


## What a running engine is asked for (kW electric). A set with a floor
## (`min_kw`, the small generator's 350 W) is governed by the gas in hand:
## its floor while the holder is low, full output once it is well up
## (GOVERNOR_LOW..GOVERNOR_HIGH of the holder's fill). With no holder on the
## line, or no floor, it runs at full output.
const GOVERNOR_LOW := 0.2
const GOVERNOR_HIGH := 0.7


func engine_setpoint_kw(u: Dictionary) -> float:
	var full := float(u.get("rated_kw", 2.5))
	var lo := float(u.get("min_kw", 0.0))
	if lo <= 0.0 or lo >= full:
		return full
	var fill := -1.0
	for h in units:
		if str(h["kind"]) == "holder":
			fill = maxf(fill, holder_fill(h))
	if fill < 0.0:
		return full
	return lerpf(lo, full, clampf((fill - GOVERNOR_LOW) / (GOVERNOR_HIGH - GOVERNOR_LOW), 0.0, 1.0))


## The fill of a holder (0..1).
func holder_fill(u: Dictionary) -> float:
	var cap := float(u["cap_m3"])
	return clampf((v_free[int(u["cv"])] - cap * HOLDER_MIN) / (cap * (1.0 - HOLDER_MIN)), 0.0, 1.0)


## Engines burn the gas at their rating while they run, flares burn what
## reaches them, dryers take the water out of the gas.
func _unit_step(dt: float) -> void:
	flare_kw = 0.0
	for u in units:
		var i := int(u["cv"])
		var g: PackedFloat64Array = gas[i]
		var n := _sum(g)
		match str(u["kind"]):
			"engine":
				var pid := str(u["part"])
				engine_kw[pid] = 0.0
				if not bool(engine_on.get(pid, false)):
					continue
				if not _eng_q.has(i):
					_event("engine_lean_%s" % pid, "The genset will not fire: the gas reaching it is too lean (under 2.5 MJ/Nm³).")
					continue
				var took := _eng_take[i] if i < _eng_take.size() else 0.0
				engine_kw[pid] = took / dt * _eng_lhv[i] * float(u.get("efficiency", 0.22)) / 1000.0
				engine_kwh += float(engine_kw[pid]) * dt / 3600.0
				if took < float(_eng_q[i]) * dt * 0.8:
					_event("engine_starved_%s" % pid, "The genset is short of gas: it is drawing its intake below 1 atm.")
				else:
					_event("engine_%s" % pid, "The genset is running on the gas.")
			"holder":
				# Full and still filling: the bell lifts out of its seal and
				# the gas blows off to air.
				var top := float(u["hold_pa"]) + SEAL_BLOW_PA
				if v_free[i] < float(u["cap_m3"]) * 0.999 or n <= 0.0:
					continue
				var keep_h := top * v_free[i] / (TcSpecies.R * maxf(gas_t(i), 200.0))
				if n <= keep_h:
					continue
				var share_h := (n - keep_h) / n
				var h_out := h_gas[i] * share_h
				e_out += h_out + _latent_of(g, share_h)
				h_gas[i] -= h_out
				for sp3 in NS:
					var mv := g[sp3] * share_h
					vented_mol[sp3] += mv
					g[sp3] -= mv
				gas[i] = g
				_event("bell_blow_%d" % i, "The gas holder is full: gas is blowing off through its water seal.")
			"flare":
				if n <= 0.0:
					continue
				var keep := (TcSpecies.P_ATM + 200.0) * v_free[i] / (TcSpecies.R * maxf(gas_t(i), 200.0))
				var ex := n - keep
				if ex <= 0.0:
					continue
				var lhv2 := 0.0
				for sp2 in NS:
					lhv2 += g[sp2] / n * LHV[sp2]
				_burn(i, ex / n)
				flare_kw += ex / dt * lhv2 / 1000.0
				if lhv2 > 1.0e3:
					_event("flare_%d" % i, "The flare is burning gas off.")
			"dryer":
				if gas_t(i) > SORB_MAX_K:
					continue
				var room := float(u["cap_mol"]) - ads_mol[i]
				var take2 := minf(g[I_H2O] * 0.85, maxf(room, 0.0))
				if take2 <= 0.0:
					if room <= 0.0:
						_event("dryer_full_%d" % i, "The gas dryer is spent: its sorbent holds all the water it can.")
					continue
				g[I_H2O] -= take2
				gas[i] = g
				ads_mol[i] += take2
				# The water's latent heat stays in the gas (adsorption gives off
				# about as much as condensing).
				h_gas[i] += take2 * LAT[I_H2O]


## A gas's lower heating value per mole (J/mol).
func _lhv_of(g: PackedFloat64Array) -> float:
	var n := 0.0
	var h := 0.0
	for sp in NS:
		n += g[sp]
		h += g[sp] * LHV[sp]
	return h / n if n > 0.0 else 0.0


## Burn a share of a volume's gas (engine / flare): it leaves the model, its
## heat and latent with it.
func _burn(i: int, share: float) -> void:
	var g: PackedFloat64Array = gas[i]
	var h_out := h_gas[i] * share
	e_out += h_out + _latent_of(g, share)
	h_gas[i] -= h_out
	for sp in NS:
		var m := g[sp] * share
		burned_mol[sp] += m
		g[sp] -= m
	gas[i] = g


## The design's sensors / actuators, and its automations in the model.
func _setup_control(d: Dictionary) -> void:
	control_sensors = TcProcControl.sensors(self, d, proc)
	control_acts = TcProcControl.actuators(self, d, proc)
	_base_lpm = float((proc.get("cooling", {}) as Dictionary).get("lpm", 2.0))
	_base_w = {}
	for pid in heater_parts:
		_base_w[str(pid)] = maxf(float(TcProcSpec.heater(proc, str(pid))["w"]), 1.0)
	var autos: Array = proc.get("automations", [])
	automations = null
	if not autos.is_empty():
		automations = AutomationSim.from_specs(autos, TcProcControl.ITEM)
		automations.rich_commands = true
		if automations.is_empty():
			automations = null
	_auto_need = TcProcControl.needed(autos)
	logic_blocks = []
	for b in proc.get("logic", []):
		if b is Dictionary and str((b as Dictionary).get("kind", "")) in ScadaLogic.KINDS:
			logic_blocks.append((b as Dictionary).duplicate(true))
	logic_state = {}
	logic_status = {}
	_logic_need = {}
	for b in logic_blocks:
		for t in ScadaLogic.tags_used(b)["reads"]:
			_logic_need[str(t)] = true


## The rules over the last AUTO_EVERY_S, on the lab's clock (absolute hours
## from its start hour, so a time rule fires at that clock time).
func _run_automations() -> void:
	var h0 := float(proc.get("start_hour", 8.0))
	var t1 := h0 + t_s / 3600.0
	var t0 := t1 - _auto_acc / 3600.0
	_auto_acc = 0.0
	var ctx := {"numeric": TcProcControl.read_all(self, control_sensors, _auto_need),
		"states": TcProcControl.states(self, control_acts), "sun": Vector2(6.5, 19.0), "weekday": -1}
	var n0 := automations.log.size()
	automations.step(t0, t1, ctx, func(_item: String, cmd: Variant) -> void:
		var done := TcProcControl.apply(self, control_acts, cmd, _base_lpm, _base_w)
		_pending_auto_text.append(done if done != "" else "nothing here to switch"))
	var lg: Array = automations.log
	for k in range(n0, lg.size()):
		var e: Dictionary = lg[k]
		var txt := str(_pending_auto_text[k - n0]) if k - n0 < _pending_auto_text.size() else str(e.get("command", ""))
		events.append({"t_s": t_s, "id": "auto", "text": "Automation “%s”: %s." % [str(e.get("alias", "")), txt]})
	_pending_auto_text = []


var _pending_auto_text: Array = []


## The control blocks at this instant (every model step: a PID needs it).
func _run_logic() -> void:
	_logic_vals = TcProcControl.read_all(self, control_sensors, _logic_need) if not _logic_need.is_empty() else {}
	var r := ScadaLogic.step(logic_blocks, logic_state, _logic_read, float(proc.get("start_hour", 8.0)) + t_s / 3600.0)
	logic_state = r["state"]
	logic_status = r["status"]
	var writes: Dictionary = r["writes"]
	for tag in writes:
		_logic_write(str(tag), float(writes[tag]))


func _logic_act(tag: String) -> Dictionary:
	for a in control_acts:
		if str(a["key"]) == tag:
			return a
	return {}


func _logic_read(tag: String) -> float:
	if tag.begins_with("logic."):
		for r in ScadaLogic.tags(logic_blocks, logic_status):
			if str(r["id"]) == tag:
				return float(r["value"])
		return NAN
	if _logic_vals.has(tag):
		return float(_logic_vals[tag])
	var a := _logic_act(tag)
	if a.is_empty():
		return NAN
	if str(a["kind"]) == "switch":
		return 1.0 if TcProcControl.is_on(self, str(a["act"])) else 0.0
	return logic_percent(a)


## A number actuator as the 0..100 % a PID drives: an element's share of its
## rated watts, cooling water's share of the actuator's top flow.
func logic_percent(a: Dictionary) -> float:
	return 100.0 * TcProcControl.value_of(self, a) / maxf(_logic_full(a), 1e-6)


func _logic_full(a: Dictionary) -> float:
	var act := str(a["act"])
	if act.begins_with("heater:"):
		return float(_base_w.get(act.substr(7), 600.0))
	return float(a.get("max", 100.0))


func _logic_write(tag: String, value: float) -> void:
	var a := _logic_act(tag)
	if a.is_empty():
		return
	if str(a["kind"]) == "switch":
		var want := value >= 0.5
		if TcProcControl.is_on(self, str(a["act"])) == want:
			return
		TcProcControl._switch(self, str(a["act"]), want, _base_lpm, _base_w)
		events.append({"t_s": t_s, "id": "auto", "text": "Logic: %s %s." % [str(a["label"]), "on" if want else "off"]})
		return
	var v := _logic_full(a) * clampf(value, 0.0, 100.0) / 100.0
	if absf(TcProcControl.value_of(self, a) - v) > 1e-3 * _logic_full(a):
		set_actuator(str(a["act"]), v)


## Section timing (µs, summed): prof[k] = time from mark k to mark k + 1.
static var prof := PackedInt64Array([0, 0, 0, 0, 0, 0, 0, 0])
var _prof_t := 0
var _prof_k := -1


func _prof_mark(k: int) -> void:
	var t := Time.get_ticks_usec()
	if _prof_k >= 0 and k > _prof_k:
		prof[_prof_k] += t - _prof_t
	_prof_t = t
	_prof_k = k if k < 7 else -1


var _bed_events_due := false


## A share of the bed step's output (the extensive numbers scale; the
## element temperatures do not).
## Heaters in a pool (or dry-firing into the vessel's wall), from the k-th.
func _pool_heaters(dt: float, from_k: int) -> void:
	for k in range(from_k, heater_parts.size()):
		var pid: String = heater_parts[k]
		var hc := int(heater_cv.get(pid, vessel_cv))
		if hc < 0:
			continue
		var w2 := float(heater_w.get(pid, 0.0)) if bool(heater_on.get(pid, true)) else 0.0
		e_in += w2 * dt
		if _liq_volume(liq[hc]) > 0.002:
			h_liq[hc] += w2 * dt
		elif w2 > 0.0:
			t_wall[hc] += w2 * dt / c_wall[hc]
			_event("dry_fire", "An element is heating an empty vessel (dry firing).")
		if from_k > 0 or hc != vessel_cv:
			# No charge round it: the sheath runs a little over the liquid.
			if element_t.size() <= k:
				element_t.resize(k + 1)
			element_t[k] = (liq_t(hc) if _liq_volume(liq[hc]) > 0.002 else t_wall[hc]) + w2 / 60.0


static func _bed_scaled(r: Dictionary, f: float) -> Dictionary:
	if r.is_empty():
		return {"to_wall_j": 0.0, "to_gas_j": 0.0, "steam_mol": 0.0, "steam_j": 0.0, "volatiles": {}, "volatiles_j": 0.0,
			"tar_kg": 0.0, "react_j": 0.0, "latent_j": 0.0, "formed_latent_j": 0.0, "element_t": []}
	var o := {}
	for k in r.keys():
		var v: Variant = r[k]
		if v is float:
			o[k] = float(v) * f
		elif v is Dictionary:
			var dd := {}
			for s in (v as Dictionary).keys():
				dd[s] = float(v[s]) * f
			o[k] = dd
		else:
			o[k] = v
	return o


func _pool_step(i: int, dt: float) -> void:
	var l: PackedFloat64Array = liq[i]
	if _sum(l) <= 1e-9:
		return
	var p := maxf(p_cv[i], 2000.0)
	var tl := liq_t(i)
	# Nothing the lab carries boils below ~340 K at a near-atmospheric
	# pressure (ethanol's 351 K, its azeotrope 351.3 K): skip the search.
	if tl < 340.0 * pow(p / TcSpecies.P_ATM, 0.05):
		return
	var bub := _bubble(l, p)
	var tb := float(bub["t_k"])
	if tl <= tb:
		return
	# Heat above the bubble point boils the pool: vapour of composition y.
	var cpl := _cp_liq_total(l)
	var excess := (tl - tb) * cpl
	var y: Dictionary = bub["y"]
	var hmix := 0.0
	for s in y.keys():
		hmix += float(y[s]) * _latent(int(s))
	if hmix <= 0.0:
		return
	var nv := excess / hmix
	var g: PackedFloat64Array = gas[i]
	var boiled := 0.0
	for s in y.keys():
		var si := int(s)
		var take := minf(nv * float(y[s]), l[si])
		l[si] -= take
		g[si] += take
		boiled += take
		var hv := take * CPG[si] * (tb - T0)
		var hl := take * CPL[si] * (tl - T0)
		h_liq[i] -= hl + take * _latent(si)
		h_gas[i] += hv
		t_wall[i] += (hl - hv) / c_wall[i]
	liq[i] = l
	gas[i] = g
	(react_rate[i] as Dictionary)["boiling"] = boiled / dt
	if boiled > 0.0 and str(net["cvs"][i]["role"]) == "vessel":
		_event("boil_%d" % i, "%s is boiling." % str(net["cvs"][i]["label"]))


## Bubble point of a liquid mixture at p: {t_k, y: {species index: mole frac}}.
func _bubble(l: PackedFloat64Array, p: float) -> Dictionary:
	var n := 0.0
	for s in COND:
		n += l[s]
	var x := {}
	for s in COND:
		if l[s] > 0.0:
			x[s] = l[s] / n
	var lo := 250.0
	var hi := 800.0
	var y := {}
	for _it in 36:
		var t := (lo + hi) * 0.5
		var tot := 0.0
		y = {}
		var g := [1.0, 1.0]
		if x.has(10) and x.has(0):
			var xe := float(x[10]) / (float(x[10]) + float(x[0]))
			g = TcThermo.wilson_gamma(xe, t)
		for s in x.keys():
			var gam := 1.0
			if s == 10:
				gam = float(g[0])
			elif s == 0:
				gam = float(g[1])
			var ps := float(x[s]) * gam * _psat(int(s), t)
			y[s] = ps
			tot += ps
		if tot < p:
			lo = t
		else:
			hi = t
	var tot2 := 0.0
	for s in y.keys():
		tot2 += float(y[s])
	for s in y.keys():
		y[s] = float(y[s]) / maxf(tot2, 1e-12)
	return {"t_k": (lo + hi) * 0.5, "y": y}


func _wall_step(i: int, dt: float, ta: float) -> void:
	var cv: Dictionary = net["cvs"][i]
	var role := str(cv["role"])
	if role == "jacket":
		return
	var area := maxf(float(cv["wall_area_m2"]), 1e-4)
	if role == "coolant":
		# Water through the jacket: it takes the heat the condenser walls
		# give it and carries it out.
		var m := maxf(float(cv["volume_m3"]) * 1000.0, 0.01)
		var lpm := float(cool_lpm.get(i, 0.0))
		var mdot := lpm / 60.0
		var tin := float(proc["cooling"]["t_c"]) + 273.15
		var a := mdot * 4186.0 / (m * 4186.0)
		var tw := t_cool[i]
		var tw_new := tin + (tw - tin) * exp(-a * dt) if a > 0.0 else tw
		var carried := m * 4186.0 * (tw - tw_new)
		e_cool += carried
		t_cool[i] = tw_new
		return
	# Gas ↔ wall.
	var cg := _cp_total(gas[i])
	if cg > 1e-9:
		var tg := gas_t(i)
		var ua := H_GAS_WALL * area * (1.0 if role != "vessel" else 0.5)
		var tau := ua * dt * (1.0 / cg + 1.0 / c_wall[i])
		var dtg := (tg - t_wall[i]) * (1.0 - exp(-tau))
		var q := dtg / (1.0 / cg + 1.0 / c_wall[i])
		h_gas[i] -= q
		t_wall[i] += q / c_wall[i]
	# A pool ↔ wall (the vessel's floor and sides it covers).
	var cl := _cp_liq_total(liq[i])
	if cl > 1e-9:
		var tl := liq_t(i)
		var ual := 300.0 * area * 0.3 * (AGIT_H_GAIN if _agit_cv.has(i) else 1.0)
		var tau2 := ual * dt * (1.0 / cl + 1.0 / c_wall[i])
		var d2 := (tl - t_wall[i]) * (1.0 - exp(-tau2))
		var q2 := d2 / (1.0 / cl + 1.0 / c_wall[i])
		h_liq[i] -= q2
		t_wall[i] += q2 / c_wall[i]
	# Condenser wall → its cooling water.
	for th in net["thermal"]:
		if str(th["kind"]) == "condenser" and int(th["b"]) == i:
			var w := int(th["a"])
			var mw := maxf(float(net["cvs"][w]["volume_m3"]) * 1000.0, 0.01) * 4186.0
			var ua2 := H_COOLANT * float(th["area_m2"])
			var tau3 := ua2 * dt * (1.0 / c_wall[i] + 1.0 / mw)
			var d3 := (t_wall[i] - t_cool[w]) * (1.0 - exp(-tau3))
			var q3 := d3 / (1.0 / c_wall[i] + 1.0 / mw)
			t_wall[i] -= q3 / c_wall[i]
			t_cool[w] += q3 / mw
			return
	# A jacket fed by a medium (hot or cold water round the vessel): the wall
	# trades heat with the stream (effectiveness of a one-stream exchanger)
	# and the room no longer sees the wall.
	if role == "vessel" and jacket.has(i) and bool(jacket[i]["on"]) and float(jacket[i]["lpm"]) > 0.0:
		var cm := float(jacket[i]["lpm"]) / 60.0 * 4186.0
		var eff := 1.0 - exp(-H_JACKET * area * 0.7 / cm)
		var qj := eff * cm * (float(jacket[i]["t_c"]) + 273.15 - t_wall[i]) * dt
		var cap := absf(float(jacket[i]["t_c"]) + 273.15 - t_wall[i]) * c_wall[i]
		qj = clampf(qj, -cap, cap)
		t_wall[i] += qj / c_wall[i]
		e_cool -= qj
		return
	# Wall → room (through a jacket gap and insulation on a vessel).
	var u := H_OUT
	if role == "vessel":
		var r_tot := 1.0 / H_OUT + float(cv.get("insulation_mm", 0.0)) * 0.001 / K_INSUL
		for th2 in net["thermal"]:
			if str(th2["kind"]) == "jacket" and int(th2["a"]) == i or (str(th2["kind"]) == "jacket" and int(th2["b"]) == i):
				# An empty jacket is an air gap (~26 mm): conduction plus
				# radiation across it (ε 0.3 for dull stainless).
				var gap := 0.026
				var tm := t_wall[i]
				var h_gap := K_AIR / gap + 4.0 * 0.3 * TcThermo.SIGMA * pow(tm, 3.0)
				if str(proc.get("jacket_fill", "air")) == "insulation":
					h_gap = K_INSUL / gap
				r_tot += 1.0 / h_gap
		u = 1.0 / r_tot
	else:
		u = H_OUT + 4.0 * 0.4 * TcThermo.SIGMA * pow(t_wall[i], 3.0) * 0.5
	var ql := u * area * 1.1 * (t_wall[i] - ta) * dt
	ql = clampf(ql, -absf(t_wall[i] - ta) * c_wall[i], absf(t_wall[i] - ta) * c_wall[i])
	t_wall[i] -= ql / c_wall[i]
	e_loss += ql


func _phase_step(i: int, dt: float) -> void:
	var cv: Dictionary = net["cvs"][i]
	var role := str(cv["role"])
	if role in ["coolant", "jacket"]:
		return
	var g: PackedFloat64Array = gas[i]
	var l: PackedFloat64Array = liq[i]
	var n := _sum(g)
	if n <= 1e-12:
		return
	var tg := gas_t(i)
	var tw := t_wall[i]
	var area := maxf(float(cv["wall_area_m2"]), 1e-4)
	var v := v_free[i]
	var frac := 1.0 - exp(-K_MASS * area / maxf(v, 1e-6) * dt)
	var nl := 0.0
	for s in COND:
		nl += l[s]
	var condensed := 0.0
	var tl := liq_t(i)
	for s in COND:
		var ps_wall := _psat(s, tw)
		if nl > 1e-9 and l[s] > 0.0:
			ps_wall *= l[s] / nl   # Raoult on the wet wall
		var n_eq := ps_wall * v / (TcSpecies.R * maxf(tg, 200.0))
		var d := (g[s] - n_eq) * frac
		if d > 0.0:
			# Condense onto the wall: its latent heat goes into the wall.
			g[s] -= d
			l[s] += d
			var cpg := CPG[s]
			var cpl := CPL[s]
			var hg := d * cpg * (tg - T0)
			h_gas[i] -= hg
			h_liq[i] += d * cpl * (tw - T0)
			t_wall[i] += (hg - d * cpl * (tw - T0) + d * _latent(s)) / c_wall[i]
			condensed += d
		elif d < 0.0 and l[s] > 0.0:
			# Evaporate off a wet wall, taking the latent heat from it.
			var e := minf(-d, l[s])
			var cpl2 := CPL[s]
			var cpg2 := CPG[s]
			l[s] -= e
			g[s] += e
			h_liq[i] -= e * cpl2 * (tl - T0)
			h_gas[i] += e * cpg2 * (tw - T0)
			t_wall[i] += (e * cpl2 * (tl - T0) - e * cpg2 * (tw - T0) - e * _latent(s)) / c_wall[i]
	gas[i] = g
	liq[i] = l
	_settle_empty(i)
	if condensed > 0.0:
		(react_rate[i] as Dictionary)["condensing"] = condensed / dt


## Condense a gas stream passing a condenser's wall: each condensable
## heads for the wall's saturation (Raoult on the film), by a transfer
## efficiency 1 − exp(−NTU), NTU = K_MASS · A · dt / (the stream's volume).
## The liquid joins the CV's film; the latent heat goes into the wall.
## Returns [mixed, h_all].
func _condense_stream(i: int, mixed: PackedFloat64Array, h_all: float, p_pa: float, dt: float) -> Array:
	var n := _sum(mixed)
	var cp := _cp_total(mixed)
	if n <= 1e-12 or cp <= 1e-9:
		return [mixed, h_all]
	var tg := T0 + h_all / cp
	var tw := t_wall[i]
	if tg <= tw:
		return [mixed, h_all]
	var pp := maxf(p_pa, 1000.0)
	var v_stream := n * TcSpecies.R * maxf(tg, 200.0) / pp
	var area := maxf(float(net["cvs"][i]["wall_area_m2"]), 1e-4)
	# Vapour diffusing to the wall through air is slow (K_MASS); nearly pure
	# vapour condenses as fast as the wall takes the heat (the classic
	# non-condensable effect): the coefficient rises as the air share falls.
	var x_inert := 1.0
	for s0 in COND:
		x_inert -= mixed[s0] / n
	var k_eff := minf(K_MASS / maxf(x_inert, 0.01), 1.0)
	var eff := 1.0 - exp(-k_eff * area * dt / maxf(v_stream, 1e-9))
	var l: PackedFloat64Array = liq[i]
	var nl := 0.0
	for s in COND:
		nl += l[s]
	# What can stay vapour at the wall is set by the gas that does not
	# condense: y_s = p_s/p in the leaving gas, so n_s = n_inert · y_s / (1 − Σy).
	var n_inert := n
	var ys := {}
	var y_tot := 0.0
	for s in COND:
		n_inert -= mixed[s]
		if mixed[s] <= 0.0:
			continue
		var ps := _psat(s, tw)
		if nl > 1e-9 and l[s] > 0.0:
			ps *= l[s] / nl
		ys[s] = ps / pp
		y_tot += ps / pp
	if y_tot >= 1.0:
		return [mixed, h_all]   # the wall is above the stream's dew point
	n_inert = maxf(n_inert, 0.0)
	for s in COND:
		if not ys.has(s):
			continue
		var n_eq := n_inert * float(ys[s]) / (1.0 - y_tot)
		var d := (mixed[s] - n_eq) * eff
		if d <= 0.0:
			continue
		d = minf(d, mixed[s])
		mixed[s] -= d
		l[s] += d
		var hg := d * CPG[s] * (tg - T0)
		h_all -= hg
		h_liq[i] += d * CPL[s] * (tw - T0)
		t_wall[i] += (hg - d * CPL[s] * (tw - T0) + d * _latent(s)) / c_wall[i]
		(react_rate[i] as Dictionary)["condensing"] = float((react_rate[i] as Dictionary).get("condensing", 0.0)) + d / dt
	liq[i] = l
	return [mixed, h_all]


## A phase whose moles are all gone hands its leftover sensible heat to
## the wall (conserving it), so a vanished pool cannot keep a temperature.
func _settle_empty(i: int) -> void:
	if _sum(liq[i]) < 1e-9 and h_liq[i] != 0.0:
		if str(net["cvs"][i]["role"]) != "coolant":
			t_wall[i] += h_liq[i] / c_wall[i]
		h_liq[i] = 0.0
	if _sum(gas[i]) < 1e-12 and h_gas[i] != 0.0:
		t_wall[i] += h_gas[i] / c_wall[i]
		h_gas[i] = 0.0


## The conductance of a link (mol/s per Pa) at the current Δp.
func _conductance(li: int, dp: float, c_mol: float, rho: float) -> float:
	var l: Dictionary = net["links"][li]
	var r := maxf(float(l["r_in_m"]), 0.002)
	var cvs: Array = net["cvs"]
	var L := 0.0
	var parts := 0
	for e in [int(l["a"]), int(l["b"])]:
		if e >= 0:
			var cv: Dictionary = cvs[e]
			if str(cv["role"]) != "vessel":
				L += float(cv["length_m"]) * 0.5
				parts += (cv["parts"] as Array).size()
	L = maxf(L, 0.05)
	var A := PI * r * r
	var g_lam := PI * pow(r, 4.0) / (8.0 * MU_GAS * L) * c_mol
	var K := F_DARCY * L / (2.0 * r) + 0.5 + K_MINOR_PER_PART * float(parts) * 0.5
	var adp := maxf(absf(dp), 1e-3)
	var mdot := A * sqrt(2.0 * maxf(rho, 1e-3) * adp / K)
	var mm := rho / maxf(c_mol, 1e-9)
	var g_turb := mdot / maxf(mm, 1e-6) / adp
	return minf(g_lam, g_turb)


func _flow_step(dt: float) -> void:
	var links: Array = net["links"]
	var nl := links.size()
	if nl == 0:
		return
	var cvs: Array = net["cvs"]
	var bnds: Array = net["boundaries"]
	# CV gas constants c_i = R T / V and current pressures.
	_holder_volumes()
	var cc := PackedFloat64Array()
	cc.resize(n_cv)
	var n_tot := PackedFloat64Array()
	n_tot.resize(n_cv)
	var mmix := PackedFloat64Array()
	mmix.resize(n_cv)
	for i in n_cv:
		var g0: PackedFloat64Array = gas[i]
		var n := 0.0
		var mm := 0.0
		for s in NS:
			n += g0[s]
			mm += g0[s] * MKG[s]
		n_tot[i] = n
		mmix[i] = mm / n if n > 0.0 else 0.029
		var tg := gas_t(i)
		cc[i] = TcSpecies.R * maxf(tg, 200.0) / maxf(v_free[i], 1e-7)
		p_cv[i] = n * cc[i]
	# Each running engine's fuel demand at its intake's heating value.
	_eng_q = {}
	_eng_take = PackedFloat64Array()
	_eng_take.resize(n_cv)
	_eng_lhv = PackedFloat64Array()
	_eng_lhv.resize(n_cv)
	for u in units:
		if str(u["kind"]) != "engine" or not bool(engine_on.get(str(u["part"]), false)):
			continue
		var ei := int(u["cv"])
		# It fires on the gas it is fed: its own intake, or what comes to it
		# (a fresh intake is full of air until the engine draws it through).
		var lhv := _lhv_of(gas[ei])
		var seen := {ei: true}
		var ring: Array = [ei]
		for hop in ENGINE_FEED_HOPS:
			var nxt: Array = []
			for c0 in ring:
				for li0 in _cv_links[int(c0)]:
					var l0: Dictionary = links[li0]
					var o0 := int(l0["b"]) if int(l0["a"]) == int(c0) else int(l0["a"])
					if o0 >= 0 and bool(link_open[li0]) and not seen.has(o0):
						seen[o0] = true
						nxt.append(o0)
						lhv = maxf(lhv, _lhv_of(gas[o0]))
			ring = nxt
		if lhv >= ENGINE_MIN_LHV:
			_eng_q[ei] = engine_setpoint_kw(u) * 1000.0 / float(u.get("efficiency", 0.22)) / lhv
	# Link conductances at the current state.
	var G := PackedFloat64Array()
	G.resize(nl)
	var pb := PackedFloat64Array()   # the far side's pressure for boundary links
	pb.resize(nl)
	for li in nl:
		var l: Dictionary = links[li]
		var a := int(l["a"])
		var b := int(l["b"])
		G[li] = 0.0
		if a < 0 or str(cvs[a]["role"]) in ["coolant", "jacket"]:
			continue
		if not bool(link_open[li]):
			continue
		var pa := p_cv[a]
		var pbv := 0.0
		if b >= 0:
			pbv = p_cv[b]
		else:
			var bi := int(l["boundary"])
			if bi < 0 or not _boundary_p.has(bi):
				continue   # a feed / drain / plug: closed to gas
			pbv = float(_boundary_p[bi])
		pb[li] = pbv
		var kind := str(l["kind"])
		if kind in ["check", "pump"] and pa < pbv:
			continue
		if kind == "relief":
			var gauge := pa - TcSpecies.P_ATM
			var set_pa := float(l.get("set_bar", proc["relief_bar"])) * 1e5
			if relief_open[li]:
				if gauge < set_pa * 0.9:
					relief_open[li] = false
			elif gauge > set_pa:
				relief_open[li] = true
				_event("relief_%d" % li, "The relief valve lifted at %.2f bar." % (gauge / 1e5))
			if not relief_open[li]:
				continue
		var c_mol := maxf(p_cv[a], 1000.0) / (TcSpecies.R * maxf(gas_t(a), 200.0))
		var rho := c_mol * mmix[a]
		G[li] = _conductance(li, pa - pbv, c_mol, rho)
	g_link = G.duplicate()
	# Implicit pressure solve, exactly: p_i/c_i + dt Σ G (p_i − p_j) = n_i
	# (+ dt G p_b for a boundary). The pipe volumes are tiny next to their
	# conductances, so the system is stiff and an iterative sweep does not
	# settle it; a dense elimination over the gas CVs (an M-matrix, no
	# pivoting) is a few thousand multiplies at this size.
	var p := p_cv.duplicate()
	var idx := PackedInt32Array()
	idx.resize(n_cv)
	var gcv: Array = []
	for i in n_cv:
		idx[i] = -1
		if cc[i] > 0.0 and not (str(cvs[i]["role"]) in ["coolant", "jacket"]):
			idx[i] = gcv.size()
			gcv.append(i)
	var m := gcv.size()
	if m > 0:
		var A := PackedFloat64Array()
		A.resize(m * m)
		var rhs := PackedFloat64Array()
		rhs.resize(m)
		for r in m:
			var i: int = gcv[r]
			A[r * m + r] = 1.0 / cc[i]
			rhs[r] = n_tot[i]
		for li in nl:
			var g := G[li] * dt
			if g <= 0.0:
				continue
			var l: Dictionary = links[li]
			var a := int(l["a"])
			var b := int(l["b"])
			var ra := idx[a] if a >= 0 else -1
			var rb := idx[b] if b >= 0 else -1
			if ra < 0:
				continue
			A[ra * m + ra] += g
			if rb >= 0:
				A[rb * m + rb] += g
				A[ra * m + rb] -= g
				A[rb * m + ra] -= g
			else:
				rhs[ra] += g * pb[li]
		# A bell between empty and full holds its weight's pressure whatever
		# flows: its row pinned there (its volume follows next step).
		for u in units:
			if str(u["kind"]) != "holder":
				continue
			var hi := int(u["cv"])
			var cap_h := float(u["cap_m3"])
			if idx[hi] < 0 or v_free[hi] <= cap_h * HOLDER_MIN * 1.001 or v_free[hi] >= cap_h * 0.999:
				continue
			var rh := idx[hi]
			for c in m:
				A[rh * m + c] = 0.0
			A[rh * m + rh] = 1.0
			rhs[rh] = float(u["hold_pa"])
		for ei in _eng_q.keys():
			if idx[int(ei)] >= 0:
				rhs[idx[int(ei)]] -= float(_eng_q[ei]) * dt
		var A0 := A.duplicate() if not _eng_q.is_empty() else A
		var rhs0 := rhs.duplicate() if not _eng_q.is_empty() else rhs
		var sol := _solve_dense(A, rhs, m)
		# An engine that would pull its intake below its floor gets what
		# comes to it at the floor (the row pinned there).
		var capped := false
		for ei2 in _eng_q.keys():
			var r2 := idx[int(ei2)]
			if r2 >= 0 and sol[r2] < TcSpecies.P_ATM - ENGINE_MIN_PA:
				capped = true
				for c in m:
					A0[r2 * m + c] = 0.0
				A0[r2 * m + r2] = 1.0
				rhs0[r2] = TcSpecies.P_ATM - ENGINE_MIN_PA
		if capped:
			sol = _solve_dense(A0, rhs0, m)
		for r in m:
			p[gcv[r]] = maxf(sol[r], 0.0)
	# Flows from the solved pressures; mix species and enthalpy upwind,
	# donors first (high pressure to low), as mixing cells.
	for li in nl:
		var l: Dictionary = links[li]
		var a := int(l["a"])
		var b := int(l["b"])
		var pa := p[a] if a >= 0 else 0.0
		var pbv := p[b] if b >= 0 else pb[li]
		flow_link[li] = G[li] * (pa - pbv)
	for ei3 in _eng_q.keys():
		var e := int(ei3)
		var net_in := 0.0
		for li in _cv_links[e]:
			var l: Dictionary = links[li]
			var f := flow_link[li]
			net_in += -f * dt if int(l["a"]) == e else f * dt
		_eng_take[e] = maxf(n_tot[e] + net_in - p[e] / cc[e], 0.0)
	var order: Array = range(n_cv)
	order.sort_custom(func(x, y): return p[x] > p[y])
	var inflow: Array = []
	var in_h := PackedFloat64Array()
	in_h.resize(n_cv)
	var out_mol := PackedFloat64Array()
	out_mol.resize(n_cv)
	for i in n_cv:
		inflow.append(_zeros())
	for i in n_cv:
		cv_flow[i] = 0.0
	for li in nl:
		vel_link[li] = 0.0
	product_rate = _zeros()
	for i in order:
		# Out of i: every link whose flow leaves i.
		var g: PackedFloat64Array = gas[i]
		var n0 := n_tot[i]
		var add: PackedFloat64Array = inflow[i]
		var avail := n0 + _sum(add)
		var out := 0.0
		for li in _cv_links[i]:
			var l: Dictionary = links[li]
			var f := flow_link[li]
			var leaving: bool = (f > 0.0 and int(l["a"]) == i) or (f < 0.0 and int(l["b"]) == i)
			if leaving:
				out += absf(f) * dt
		var burn := _eng_take[i]
		out = minf(out + burn, avail * 0.999)
		if avail <= 1e-15:
			continue
		var keep := (avail - out) / avail
		# The mixed composition leaving.
		var mixed := _zeros()
		for s in NS:
			mixed[s] = g[s] + add[s]
		var h_all := h_gas[i] + in_h[i]
		if _is_condenser[i] and _sum(add) > 0.0:
			# What flows through a cold condenser condenses on the way, not
			# only what stands in it between steps (a 2 kW boil passes
			# through in a fraction of a step).
			var cr := _condense_stream(i, mixed, h_all, p[i], dt)
			mixed = cr[0]
			h_all = float(cr[1])
			var left := _sum(mixed)
			out = minf(out, left * 0.999)
			avail = left
			if avail <= 1e-15:
				gas[i] = mixed
				h_gas[i] = h_all
				continue
			keep = (avail - out) / avail
		var scale := 1.0
		var want := burn
		for li in _cv_links[i]:
			var l: Dictionary = links[li]
			var f := flow_link[li]
			if (f > 0.0 and int(l["a"]) == i) or (f < 0.0 and int(l["b"]) == i):
				want += absf(f) * dt
		if want > 0.0:
			scale = out / want
		for li in _cv_links[i]:
			var l: Dictionary = links[li]
			var f := flow_link[li]
			var leaving: bool = (f > 0.0 and int(l["a"]) == i) or (f < 0.0 and int(l["b"]) == i)
			if not leaving:
				continue
			var mol := absf(f) * dt * scale
			var share := mol / avail
			var other := int(l["b"]) if int(l["a"]) == i else int(l["a"])
			if other >= 0:
				var dest: PackedFloat64Array = inflow[other]
				for s in NS:
					dest[s] += mixed[s] * share
				inflow[other] = dest
				in_h[other] += h_all * share
			else:
				# Out through a boundary.
				var bi := int(l["boundary"])
				var role := str(bnds[bi]["role"]) if bi >= 0 else "atmosphere"
				var tgt: PackedFloat64Array = product_mol if role == "product" else vented_mol
				for s in NS:
					tgt[s] += mixed[s] * share
					if role == "product":
						product_rate[s] += mixed[s] * share / dt
				if role == "product":
					product_mol = tgt
					var tot := _sum(mixed)
					if tot > 0.0:
						for s in NS:
							_last_product_x[s] = mixed[s] / tot
				else:
					vented_mol = tgt
				e_out += h_all * share + _latent_of(mixed, share)
			cv_flow[i] += mol / dt
			vel_link[li] = mol / dt / maxf(p[i] / (TcSpecies.R * maxf(gas_t(i), 200.0)), 1e-6) / (PI * pow(maxf(float(l["r_in_m"]), 0.002), 2.0))
		if burn > 0.0:
			# Into the engine: burned, its heat and latent leaving the model.
			var bshare := burn * scale / avail
			_eng_take[i] = burn * scale
			_eng_lhv[i] = _lhv_of(mixed)
			for s in NS:
				burned_mol[s] += mixed[s] * bshare
			e_out += h_all * bshare + _latent_of(mixed, bshare)
		for s in NS:
			g[s] = mixed[s] * keep
		gas[i] = g
		h_gas[i] = h_all * keep
	# Inflow from boundaries (air back in through an open end, or product
	# gas drawn back when the reactor cools).
	for li in nl:
		var l: Dictionary = links[li]
		if int(l["b"]) >= 0 or flow_link[li] >= 0.0:
			continue
		var a := int(l["a"])
		var bi := int(l["boundary"])
		var role := str(bnds[bi]["role"]) if bi >= 0 else "atmosphere"
		var src := _last_product_x if role == "product" else _air
		var mol := -flow_link[li] * dt
		var g2: PackedFloat64Array = gas[a]
		for s in NS:
			g2[s] += src[s] * mol
			_mass_in += src[s] * mol * MKG[s]
		gas[a] = g2
		var t_in := float(proc["ambient_c"]) + 273.15
		h_gas[a] += mol * 30.0 * (t_in - T0)
		e_out -= mol * 30.0 * (t_in - T0)
		vel_link[li] = -mol / dt
	# Flow runs from high pressure to low, so every donor was processed
	# before the CVs it feeds (the sweep order), and nothing is left over.
	for i in n_cv:
		var n := _sum(gas[i])
		p_cv[i] = n * cc[i]
	# A bell takes up its new gas at its own pressure (its volume moves).
	if not units.is_empty():
		_holder_volumes()
		for u in units:
			if str(u["kind"]) == "holder":
				var hi := int(u["cv"])
				p_cv[hi] = _sum(gas[hi]) * TcSpecies.R * maxf(gas_t(hi), 200.0) / maxf(v_free[hi], 1e-7)


## Gaussian elimination without pivoting (the pressure matrix is
## diagonally dominant). A is row-major m × m; both are consumed.
static func _solve_dense(A: PackedFloat64Array, b: PackedFloat64Array, m: int) -> PackedFloat64Array:
	for k in m:
		var piv := A[k * m + k]
		if absf(piv) < 1e-30:
			continue
		for r in range(k + 1, m):
			var f := A[r * m + k]
			if f == 0.0:
				continue
			f /= piv
			for c in range(k, m):
				A[r * m + c] -= f * A[k * m + c]
			b[r] -= f * b[k]
	var x := PackedFloat64Array()
	x.resize(m)
	for k in range(m - 1, -1, -1):
		var s := b[k]
		for c in range(k + 1, m):
			s -= A[k * m + c] * x[c]
		var piv2 := A[k * m + k]
		x[k] = s / piv2 if absf(piv2) > 1e-30 else 0.0
	return x


func _latent_of(mixed: PackedFloat64Array, share: float) -> float:
	var e := 0.0
	for s in COND:
		e += mixed[s] * share * _latent(s)
	return e


func _dict(g: PackedFloat64Array) -> Dictionary:
	var d := {}
	for s in NS:
		if g[s] > 0.0:
			d[SP[s]] = g[s]
	return d


func _drain_step(_dt: float) -> void:
	var cvs: Array = net["cvs"]
	var bnds: Array = net["boundaries"]
	for i in _order:
		var l: PackedFloat64Array = liq[i]
		var vol := _liq_volume(l)
		if vol <= 1e-9:
			continue
		var cv: Dictionary = cvs[i]
		var role := str(cv["role"])
		# Out through an open drain on this CV.
		var drained := false
		for li in _cv_links[i]:
			var lk: Dictionary = net["links"][li]
			if int(lk["b"]) >= 0 or not bool(link_open[li]):
				continue
			var bi := int(lk["boundary"])
			var brole := str(bnds[bi]["role"]) if bi >= 0 else ""
			# A drain runs out when open; an outlet lets the liquid that
			# reaches it out of the pipework (the distillate) — never a
			# vessel's contents through a labelled nozzle on it.
			if bi >= 0 and ((brole == "drain" and bool(drain_open.get(bi, false))) or (brole in ["outlet", "product"] and role != "vessel")):
				var kg := 0.0
				for s in COND:
					drained_mol[s] += l[s]
					kg += l[s] * MKG[s]
					l[s] = 0.0
				drained_by[bi] = float(drained_by.get(bi, 0.0)) + kg
				e_out += h_liq[i]
				h_liq[i] = 0.0
				liq[i] = l
				drained = true
				var where := str(bnds[bi]["text"]) if str(bnds[bi]["text"]) != "" else ("a drain" if brole == "drain" else "the outlet")
				_event("drain_%d" % bi, ("Condensate is running out of %s." if brole == "drain" else "Liquid is running out of %s: the distillate.") % where)
				break
		if drained or role == "vessel":
			continue
		# What a wet wall holds stays; the rest runs down.
		var hold := FILM_L_PER_M2 * float(cv["wall_area_m2"]) * 0.001
		if role in ["junction", "sight", "filter"]:
			hold = maxf(hold, float(cv["volume_m3"]) * 0.6)   # a trap fills before it overflows
		if vol <= hold:
			continue
		var downs: Array = []
		for dw in _down[i]:
			if bool(link_open[int(dw[0])]):
				downs.append(int(dw[1]))
		if downs.is_empty():
			continue
		var frac := (vol - hold) / vol
		var h_move := h_liq[i] * frac
		var per := 1.0 / float(downs.size())
		for j in downs:
			var lj: PackedFloat64Array = liq[j]
			for s in COND:
				lj[s] += l[s] * frac * per
			liq[j] = lj
			h_liq[j] += h_move * per
		for s in COND:
			l[s] *= (1.0 - frac)
		h_liq[i] -= h_move
		liq[i] = l


# ---------------------------------------------------------------------------
# Liquid lines between vessels (pumps, control valves, gravity)
# ---------------------------------------------------------------------------
#
# A LINE is the pipework from one vessel's nozzle to another's with no branch
# on the way. Each step the flow along it is the one that balances
#     static head + pump head = friction
# where
#   static head  = the source's liquid surface above the far end (the other
#                  vessel's surface, or its nozzle when that is above its
#                  liquid: a free fall into the vessel);
#   pump head    = H0 (1 − (Q / Qmax)²) for a running centrifugal pump at
#                  speed n (H0 ∝ n², Qmax ∝ n: the affinity laws); a positive-
#                  displacement pump gives its rated flow × n up to its head;
#   friction     = K Q² / (2 g A²), K = entrance + exit (1.5) + Darcy f L / D
#                  (f = 0.03, a constant) + each valve (0.3 / open²: a full
#                  bore open, ∝ 1 / open² as it shuts, an inherent-linear
#                  trim) + a stopped centrifugal pump (4).
# The source's nozzle must be under its liquid (a flooded suction); a check
# valve and a pump pass one way only; a stopped positive-displacement pump
# passes nothing. The pipes' own hold-up is ignored: liquid leaves one vessel
# and arrives in the other in the same step.
#
# K values after Crane TP-410 (entrance 0.5, exit 1.0, full-bore valve
# ~0.2–0.3); the 1 / open² law and the stopped-pump K are estimates.

const LINE_F := 0.03
## Liquid pumped through an exchanger ↔ its wall, W/m²·K (plate exchangers
## run 2–6 kW/m²·K water to water; the wall then gives it to the service
## side at H_COOLANT, so this is one film of two).
const H_LIQ_WALL := 2500.0
## A stirred vessel's wall film against a still one's (estimate; Perry's
## gives 3–5× for a paddle in water).
const AGIT_H_GAIN := 3.0
## A brazed plate exchanger's overall coefficient, water to water, W/m²·K
## (makers quote 3–7 kW/m²·K; the low end, for a small pump's flow).
const U_PLATE := 3000.0
## A water jacket ↔ the vessel wall, W/m²·K (estimate).
const H_JACKET := 600.0
const LINE_K_ENDS := 1.5
const LINE_K_VALVE := 0.3
const LINE_K_PUMP_OFF := 4.0
const GRAV := 9.80665


func _build_lines(d: Dictionary) -> void:
	lines = []
	_vessel_floor = {}
	_breathers = []
	var cvs: Array = net["cvs"]
	var parts: Dictionary = (d.get("res", {}) as Dictionary).get("parts", {}) as Dictionary
	var vessels: Array = []
	for i in n_cv:
		if str(cvs[i]["role"]) == "vessel":
			vessels.append(i)
			var vp := str(cvs[i].get("vessel_part", ""))
			var fy := float(cvs[i].get("y_low_mm", 0.0)) * 0.001
			if parts.has(vp):
				fy = ((parts[vp]["xf"] as Transform3D).origin.y) * 0.001
			_vessel_floor[i] = fy
	if vessels.size() < 2:
		return
	# Every simple path from one vessel to another through the pipework
	# (tees included). Paths that share a pipe each count its friction on
	# their own: an approximation, exact when the valves pick one route.
	for a in vessels:
		_walk_line(a, a, -1, [], [], [], 0.0, INF, {})
	# A tank with no lid breathes: its gas stays at the room's pressure as
	# its level moves (a lidded one is the gas model's business).
	for ln2 in lines:
		for v in [int(ln2["a"]), int(ln2["b"])]:
			if not bool(cvs[v].get("has_lid", false)) and not _breathers.has(v):
				_breathers.append(v)


const MAX_LINES := 64

func _walk_line(a: int, cur: int, prev: int, path: Array, signs: Array, through: Array, length: float, r_min: float, seen: Dictionary) -> void:
	if lines.size() >= MAX_LINES or path.size() > 80:
		return
	var links: Array = net["links"]
	var cvs: Array = net["cvs"]
	for lj in _cv_links[cur]:
		var li := int(lj)
		if li == prev:
			continue
		var l: Dictionary = links[li]
		if int(l["b"]) < 0:
			continue
		var nxt := int(l["b"]) if int(l["a"]) == cur else int(l["a"])
		if seen.has(nxt) or nxt == a:
			continue
		var p2: Array = path.duplicate()
		p2.append(li)
		var s2: Array = signs.duplicate()
		s2.append(1.0 if int(l["a"]) == cur else -1.0)
		var rm := minf(r_min, float(l.get("r_in_m", 0.02)))
		if str(cvs[nxt]["role"]) == "vessel":
			if nxt > a:
				lines.append({"a": a, "b": nxt, "links": p2, "signs": s2, "cvs": through.duplicate(), "len_m": length,
					"r_m": maxf(rm, 0.003),
					"za": float((links[p2[0]]["at_mm"] as Vector3).y) * 0.001,
					"zb": float((links[li]["at_mm"] as Vector3).y) * 0.001, "lpm": 0.0})
			continue
		var r_cv := maxf(float(cvs[nxt].get("r_in_m", 0.02)), 0.002)
		var t2: Array = through.duplicate()
		t2.append(nxt)
		var sn: Dictionary = seen.duplicate()
		sn[nxt] = true
		_walk_line(a, nxt, li, p2, s2, t2, length + float(cvs[nxt]["volume_m3"]) / (PI * r_cv * r_cv), minf(rm, r_cv), sn)


func _vessel_area(i: int) -> float:
	var r := maxf(float(net["cvs"][i].get("r_in_m", 0.15)), 0.01)
	return PI * r * r


## A vessel's liquid surface, m (world height).
func liquid_surface_m(i: int) -> float:
	return float(_vessel_floor.get(i, 0.0)) + _liq_volume(liq[i]) / _vessel_area(i)


func _lines_step(dt: float) -> void:
	var links: Array = net["links"]
	var cvs: Array = net["cvs"]
	for k in pump_lpm.keys():
		pump_lpm[k] = 0.0
	for ln in lines:
		ln["lpm"] = 0.0
		var a := int(ln["a"])
		var b := int(ln["b"])
		var area := PI * float(ln["r_m"]) * float(ln["r_m"])
		# What stands in the line, as seen walking a → b.
		var k_fwd := LINE_K_ENDS + LINE_F * float(ln["len_m"]) / (2.0 * float(ln["r_m"]))
		var blocked := false
		var fwd_ok := true
		var rev_ok := true
		var pumps: Array = []      # [part, forward: bool, spec]
		var enter := a
		for li in ln["links"]:
			var l: Dictionary = links[li]
			var other := int(l["b"]) if int(l["a"]) == enter else int(l["a"])
			var kind := str(l["kind"])
			if not bool(link_open[li]):
				blocked = true
			if kind == "valve":
				var f := float(link_frac[li])
				if f < 0.02:
					blocked = true
				else:
					k_fwd += LINE_K_VALVE / (f * f)
			elif kind == "check":
				if int(l.get("from", -1)) == enter:
					rev_ok = false
				else:
					fwd_ok = false
			elif kind == "pump":
				var fw := int(l.get("from", -1)) == enter
				pumps.append([str(l["part"]), fw, l.get("pump", {})])
			enter = other
		if blocked:
			continue
		var sa := liquid_surface_m(a)
		var sb := liquid_surface_m(b)
		var za := float(ln["za"])
		var zb := float(ln["zb"])
		for dirn in [1, -1]:
			if (dirn == 1 and not fwd_ok) or (dirn == -1 and not rev_ok):
				continue
			var src := a if dirn == 1 else b
			var dst := b if dirn == 1 else a
			var s_src := sa if dirn == 1 else sb
			var s_dst := sb if dirn == 1 else sa
			var z_src := za if dirn == 1 else zb
			var z_dst := zb if dirn == 1 else za
			if s_src <= z_src + 0.003:
				continue   # the suction is dry
			var dz := s_src - maxf(s_dst, z_dst)
			var kq := k_fwd
			var h0 := 0.0
			var qm := INF
			var pd_q := -1.0
			var stop := false
			var running: Array = []
			for pw in pumps:
				var part := str(pw[0])
				var with_flow: bool = bool(pw[1]) == (dirn == 1)
				var sp: Dictionary = pw[2]
				var on := bool(pump_on.get(part, false)) and float(pump_speed.get(part, 1.0)) > 0.01
				var n := float(pump_speed.get(part, 1.0))
				var positive := str(sp.get("kind", "centrifugal")) == "positive"
				if not with_flow:
					# Against a pump: a running one, or any positive one, passes nothing.
					if on or positive:
						stop = true
					else:
						kq += LINE_K_PUMP_OFF
					continue
				if not on:
					if positive:
						stop = true
					else:
						kq += LINE_K_PUMP_OFF
					continue
				running.append(part)
				if positive:
					if dz + float(sp.get("head_m", 8.0)) > 0.0:
						pd_q = float(sp.get("flow_lpm", 40.0)) / 60000.0 * n
					else:
						stop = true
				else:
					h0 += float(sp.get("head_m", 8.0)) * n * n
					qm = minf(qm, float(sp.get("flow_lpm", 40.0)) / 60000.0 * n)
			if stop:
				continue
			var q := 0.0
			var kk := kq / (2.0 * GRAV * area * area)
			if pd_q >= 0.0:
				q = pd_q
			elif h0 > 0.0:
				if dz + h0 <= 0.0:
					continue
				q = sqrt((dz + h0) / (kk + h0 / (qm * qm)))
			else:
				if dz <= 1e-5:
					continue
				q = sqrt(dz / kk)
			var dv := q * dt
			# No more than stands above the nozzle, than the far vessel has
			# room for, or (with no pump) than half-way to level surfaces.
			dv = minf(dv, (s_src - z_src) * _vessel_area(src))
			dv = minf(dv, maxf(float(cvs[dst]["volume_m3"]) - _liq_volume(liq[dst]), 0.0))
			if running.is_empty() and s_dst > z_dst:
				dv = minf(dv, 0.5 * (s_src - s_dst) / (1.0 / _vessel_area(src) + 1.0 / _vessel_area(dst)))
			if dv <= 1e-12:
				continue
			# Through an exchanger on the way: the slug gives heat to (or
			# takes it from) each exchanger's wall.
			var q_hx := 0.0
			var vol_src := _liq_volume(liq[src])
			var c_stream := dv / maxf(vol_src, 1e-12) * _cp_liq_total(liq[src])
			if c_stream > 1e-9:
				var t_stream := liq_t(src)
				for cq0 in ln["cvs"]:
					var hx := int(cq0)
					if not _is_condenser[hx]:
						continue
					if _plate_hx.has(hx) and float(cool_lpm.get(int(_plate_hx[hx]), 0.0)) > 0.0:
						# A plate pack runs counter-flow: the stream trades
						# heat with the service water straight through the
						# plates (effectiveness–NTU; Incropera 11.4).
						var wcv := int(_plate_hx[hx])
						var c_h := c_stream / dt
						var c_c := float(cool_lpm[wcv]) / 60.0 * 4186.0
						var c_min := minf(c_h, c_c)
						var cr := c_min / maxf(c_h, c_c)
						var ntu := U_PLATE * maxf(float(cvs[hx]["wall_area_m2"]), 1e-4) / c_min
						var ef := ntu / (1.0 + ntu) if cr > 0.999 else (1.0 - exp(-ntu * (1.0 - cr))) / (1.0 - cr * exp(-ntu * (1.0 - cr)))
						var qp := ef * c_min * (t_stream - (float(proc["cooling"]["t_c"]) + 273.15)) * dt
						t_cool[wcv] += qp / (maxf(float(cvs[wcv]["volume_m3"]) * 1000.0, 0.01) * 4186.0)
						t_stream -= qp / c_stream
						q_hx += qp
						continue
					var ua := H_LIQ_WALL * maxf(float(cvs[hx]["wall_area_m2"]), 1e-4) * dt
					var qx := (1.0 - exp(-ua / c_stream)) * c_stream * (t_stream - t_wall[hx])
					var qmax := (t_stream - t_wall[hx]) / (1.0 / c_stream + 1.0 / c_wall[hx])
					if absf(qx) > absf(qmax):
						qx = qmax
					t_wall[hx] += qx / c_wall[hx]
					t_stream -= qx / c_stream
					q_hx += qx
			_move_liquid(src, dst, dv)
			h_liq[dst] -= q_hx
			var lpm := dv / dt * 60000.0
			ln["lpm"] = lpm * float(dirn)
			# For the views: the liquid as a molar flow along the line
			# (water's 55.5 kmol/m³; the gas step wrote these arrays first).
			var mol_s := dv / dt * 55500.0 * float(dirn)
			for qi in (ln["links"] as Array).size():
				flow_link[int(ln["links"][qi])] += mol_s * float(ln["signs"][qi])
			for cq in ln["cvs"]:
				cv_flow[int(cq)] += absf(mol_s)
			for part2 in running:
				pump_lpm[part2] = float(pump_lpm.get(part2, 0.0)) + lpm
				_pump_dst[part2] = dst
			break
	for bv in _breathers:
		_breathe(int(bv))
	# What the motors draw (a centrifugal pump's power falls with the cube of
	# its speed: a nameplate figure). It ends up as heat: in the liquid it
	# is moving, or lost to the room when it moves none.
	for li2 in links.size():
		var l2: Dictionary = links[li2]
		if str(l2["kind"]) != "pump":
			continue
		var p2 := str(l2["part"])
		if bool(pump_on.get(p2, false)):
			var n2 := float(pump_speed.get(p2, 1.0))
			var pj := float((l2.get("pump", {}) as Dictionary).get("watts", 250.0)) * n2 * n2 * n2 * dt
			pump_kwh += pj / 3.6e6
			e_in += pj
			if float(pump_lpm.get(p2, 0.0)) > 0.0 and _pump_dst.has(p2):
				h_liq[int(_pump_dst[p2])] += pj
			else:
				e_loss += pj


## An open tank's gas back to the room's pressure: air in as the level falls,
## its gas out (counted as vented) as it rises.
func _breathe(i: int) -> void:
	var t := maxf(gas_t(i), 200.0)
	var want := TcSpecies.P_ATM * maxf(v_free[i], 1e-7) / (TcSpecies.R * t)
	var g: PackedFloat64Array = gas[i]
	var n := _sum(g)
	if n > want and n > 1e-12:
		var keep := want / n
		for s in NS:
			vented_mol[s] += g[s] * (1.0 - keep)
			g[s] *= keep
		var h_out := h_gas[i] * (1.0 - keep)
		h_gas[i] -= h_out
		# The vapour that leaves takes its latent heat with it.
		e_out += h_out + _latent_of(g, (1.0 - keep) / maxf(keep, 1e-9))
	elif want > n:
		var mol := want - n
		for s2 in NS:
			g[s2] += _air[s2] * mol
			_mass_in += _air[s2] * mol * MKG[s2]
		var t_in := float(proc["ambient_c"]) + 273.15
		h_gas[i] += mol * 30.0 * (t_in - T0)
		e_out -= mol * 30.0 * (t_in - T0)
	gas[i] = g
	p_cv[i] = TcSpecies.P_ATM


## `dv` m³ of liquid from one volume to another, with its heat.
func _move_liquid(src: int, dst: int, dv: float) -> void:
	var l: PackedFloat64Array = liq[src]
	var vol := _liq_volume(l)
	if vol <= 1e-12:
		return
	var f := clampf(dv / vol, 0.0, 1.0)
	var lj: PackedFloat64Array = liq[dst]
	for sidx in COND:
		lj[sidx] += l[sidx] * f
		l[sidx] *= (1.0 - f)
	liq[src] = l
	liq[dst] = lj
	var hm := h_liq[src] * f
	h_liq[src] -= hm
	h_liq[dst] += hm
	var moved := vol * f
	v_free[src] += moved
	v_free[dst] = maxf(v_free[dst] - moved, 1e-4)


# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------

func _event(id: String, text: String) -> void:
	if _event_seen.has(id):
		return
	_event_seen[id] = true
	events.append({"t_s": t_s, "id": id, "text": text})


func _bed_events(r: Dictionary) -> void:
	if float(r["steam_mol"]) > 1e-4:
		_event("drying", "The charge next to the elements reached 100 °C: its water is boiling off.")
	var tot := bed.totals()
	if bed.plastic != "":
		if float(tot["t_max_k"]) >= float(TcBed.MELT_K.get(bed.plastic, 1e9)):
			_event("melt", "The plastic next to the elements has melted: the melt carries the heat out into the charge.")
		if float(tot["pyro_frac"]) > 0.0:
			_event("pyrolysis", "Cracking has begun next to the elements: the long plastic chains are breaking into oil, wax and gas.")
		if float(tot["pyro_frac"]) > 0.95:
			_event("done", "Almost all the plastic has cracked: the batch is done.")
		return
	if float(tot["pyro_frac"]) > 0.0:
		_event("pyrolysis", "Pyrolysis has begun next to the elements: the wood is turning to char, tar and gas.")
	if float(tot["moisture_kg"]) < bed.initial_moisture_kg * 0.02 and bed.initial_moisture_kg > 0.0:
		_event("dry", "The whole charge is dry.")
	if float(tot["pyro_frac"]) > 0.95:
		_event("done", "The charge is almost all char: the batch is done.")


func _flow_events() -> void:
	var n := _sum(product_rate)
	if n <= 0.0:
		return
	var fuel := product_rate[I_CO] + product_rate[I_H2] + product_rate[I_CH4] + product_rate[I_C3H6]
	if product_rate[I_H2O] / n > 0.5:
		_event("steam_out", "Steam is reaching the gas outlet.")
	if fuel / n > 0.25:
		_event("gas_out", "Burnable gas is reaching the outlet.")


# ---------------------------------------------------------------------------
# Readings
# ---------------------------------------------------------------------------

## Mole fractions of a CV's gas.
func composition(i: int) -> Dictionary:
	var g: PackedFloat64Array = gas[i]
	var n := _sum(g)
	var out := {}
	if n <= 0.0:
		return out
	for s in NS:
		if g[s] > 0.0:
			out[SP[s]] = g[s] / n
	return out


func cv_state(i: int) -> Dictionary:
	var l: PackedFloat64Array = liq[i]
	var lk := {}
	for s in COND:
		if l[s] > 0.0:
			lk[SP[s]] = l[s] * TcSpecies.molar_mass_kg(SP[s])
	var role := str(net["cvs"][i]["role"])
	return {"t_gas_c": gas_t(i) - 273.15, "t_wall_c": t_wall[i] - 273.15, "p_kpa_g": (p_cv[i] - TcSpecies.P_ATM) * 0.001 if role != "coolant" else 0.0,
		"composition": composition(i), "liquid_l": _liq_volume(l) * 1000.0, "liquid_kg": lk,
		"flow_mol_s": cv_flow[i], "t_cool_c": t_cool[i] - 273.15 if role == "coolant" else NAN,
		"reactions": react_rate[i]}


## Everything the lab shows, at the current time.
func readings() -> Dictionary:
	var r := {"t_s": t_s, "energy_in_kwh": e_in / 3.6e6}
	if vessel_cv >= 0:
		var vs := cv_state(vessel_cv)
		r["vessel_t_c"] = vs["t_gas_c"]
		r["vessel_p_kpa_g"] = vs["p_kpa_g"]
		r["vessel_wall_c"] = vs["t_wall_c"]
	if bed != null and not bed.is_empty():
		var bt := bed.totals()
		r["bed_t_max_c"] = float(bt["t_max_k"]) - 273.15
		r["bed_t_mean_c"] = float(bt["t_mean_k"]) - 273.15
		r["moisture_kg"] = bt["moisture_kg"]
		r["char_kg"] = bt["char_kg"]
		r["wood_kg"] = bt["wood_kg"]
		r["plastic_kg"] = bt["plastic_kg"]
		r["dry_frac"] = bt["dry_frac"]
		r["pyro_frac"] = bt["pyro_frac"]
		var fr := bed.fronts(0)
		r["dry_front_mm"] = float(fr["dry_m"]) * 1000.0
		r["pyro_front_mm"] = float(fr["pyro_m"]) * 1000.0
		var et: Array = []
		for t in element_t:
			et.append(float(t) - 273.15)
		r["element_t_c"] = et
	var pr := _sum(product_rate)
	r["gas_out_l_min"] = pr * 0.022414 * 1000.0 * 60.0
	var dry := 0.0
	var e := 0.0
	for s in NS:
		if s != I_H2O and not (s in COND):
			dry += product_rate[s]
		e += product_rate[s] * TcSpecies.lhv_j_per_mol(SP[s])
	r["gas_out_dry_l_min"] = dry * 0.022414 * 1000.0 * 60.0
	r["gas_out_w"] = e
	var px := {}
	for s in NS:
		if pr > 0.0 and product_rate[s] > 0.0:
			px[SP[s]] = product_rate[s] / pr
	r["gas_out_composition"] = px
	r["gas_lhv_mj_nm3"] = TcThermo.lhv_mj_per_nm3(_dict(product_rate)) if pr > 0.0 else 0.0
	r["product_total"] = _named_kg(product_mol)
	r["condensate_total"] = _named_kg(drained_mol)
	var held := _zeros()
	for i in n_cv:
		var l: PackedFloat64Array = liq[i]
		for s in COND:
			held[s] += l[s]
	r["condensate_held"] = _named_kg(held)
	var cools: Array = []
	for i in cool_lpm.keys():
		cools.append(t_cool[i] - 273.15)
	r["coolant_out_c"] = cools
	var hold := -1.0
	var ekw := 0.0
	var dry_pct := -1.0
	for u in units:
		match str(u["kind"]):
			"holder":
				hold = maxf(hold, holder_fill(u) * 100.0)
			"engine":
				ekw += float(engine_kw.get(str(u["part"]), 0.0))
			"dryer":
				dry_pct = maxf(dry_pct, ads_mol[int(u["cv"])] / maxf(float(u["cap_mol"]), 1e-12) * 100.0)
	if hold >= 0.0:
		r["holder_pct"] = hold
	r["engine_kw"] = ekw
	r["engine_kwh"] = engine_kwh
	r["flare_kw"] = flare_kw
	if dry_pct >= 0.0:
		r["dryer_pct"] = dry_pct
	return r


## Carbon in slow-pyrolysis wood char made at 450–600 °C: 75–85 % by mass
## (Lehmann & Joseph, Biochar for Environmental Management, 2015, ch. 5).
const CHAR_C_FRAC := 0.80
## The share of that carbon still in the soil after 100 years for char made
## at 450–600 °C (IPCC 2019 Refinement, Vol. 4 Ch. 2 Appendix 4, F_perm).
const CHAR_PERM := 0.80
const CO2_PER_C := 44.01 / 12.011
const GAS_MADE_SPECIES := ["CO", "CO2", "H2", "CH4", "C3H6"]


## What the batch has made and used so far (a function of the state: it
## scrubs): the char and the carbon locked in it, the CO2 that keeps out of
## the air, the gas made (wherever it went: out, burned, vented, held), the
## electricity in and out, the liquids collected.
func batch_stats() -> Dictionary:
	var s := {"heat_kwh": e_in / 3.6e6, "gen_kwh": engine_kwh, "has_bed": false, "wood": false}
	var char_kg := 0.0
	if bed != null and not bed.is_empty():
		var bt := bed.totals()
		char_kg = float(bt["char_kg"])
		s["has_bed"] = true
		s["wood"] = float(bt["plastic_kg"]) <= 0.0 and (float(bt["wood_kg"]) > 0.0 or char_kg > 0.0)
		s["feed_dry_kg"] = bed.initial_dry_kg
		s["feed_kg"] = bed.initial_dry_kg + bed.initial_moisture_kg
		s["done_pct"] = float(bt["pyro_frac"]) * 100.0
		s["charge_kg"] = bed.mass_kg()
		s["volume_frac"] = bed.volume_frac()
	s["char_kg"] = char_kg
	s["carbon_kg"] = char_kg * CHAR_C_FRAC
	s["co2e_kg"] = char_kg * CHAR_C_FRAC * CHAR_PERM * CO2_PER_C
	var mol := 0.0
	var joule := 0.0
	for name in GAS_MADE_SPECIES:
		var k := SP.find(name)
		var m := product_mol[k] + burned_mol[k] + vented_mol[k]
		for i in n_cv:
			if not (str(net["cvs"][i]["role"]) in ["coolant", "jacket"]):
				m += (gas[i] as PackedFloat64Array)[k]
		mol += m
		joule += m * TcSpecies.lhv_j_per_mol(name)
	s["gas_nl"] = mol * 22.414
	s["gas_mj"] = joule * 1e-6
	var vin := 0.0
	var tar := 0.0
	for k2 in COND:
		var kg := drained_mol[k2] * MKG[k2]
		if SP[k2] in ["H2O", "acetic", "ethanol"]:
			vin += kg
		else:
			tar += kg
	s["vinegar_kg"] = vin
	s["tar_kg"] = tar
	return s


func _named_kg(a: PackedFloat64Array) -> Dictionary:
	var d := {}
	for s in NS:
		if a[s] > 0.0:
			d[SP[s]] = a[s] * TcSpecies.molar_mass_kg(SP[s])
	return d


## Every kilogram: what is in the assembly now plus what left it, against
## what it started with: {start_kg, now_kg, out_kg, error_kg}.
func mass_ledger() -> Dictionary:
	var held := _mass_now()
	var out := 0.0
	for s in NS:
		out += (product_mol[s] + vented_mol[s] + drained_mol[s] + burned_mol[s]) * MKG[s]
	return {"start_kg": _mass0, "now_kg": held, "out_kg": out, "error_kg": held + out - _mass0 - _mass_in}


var _mass_in := 0.0   # gas drawn in through open ends (kg)


func _mass_now() -> float:
	var m := 0.0
	for i in n_cv:
		var g: PackedFloat64Array = gas[i]
		var l: PackedFloat64Array = liq[i]
		for s in NS:
			m += (g[s] + l[s]) * MKG[s]
	if bed != null:
		m += bed.mass_kg()
	for i in ads_mol.size():
		m += ads_mol[i] * MKG[I_H2O]
	return m


## Every joule: in = stored (sensible + latent) + losses + carried out.
func energy_ledger() -> Dictionary:
	return {"in": e_in, "stored": _stored_raw() - _stored0, "loss": e_loss, "coolant": e_cool,
		"reaction": e_react, "out": e_out}


var _stored0 := 0.0


## Call once after setup so the ledger measures changes from the start.
func zero_ledger() -> void:
	_stored0 = _stored_raw()


func _stored_raw() -> float:
	var sens := 0.0
	var latent := 0.0
	for i in n_cv:
		sens += h_gas[i] + h_liq[i]
		var role := str(net["cvs"][i]["role"])
		if role != "jacket":
			sens += (t_wall[i] - (float(proc["ambient_c"]) + 273.15)) * c_wall[i]
		if role == "coolant":
			var m := maxf(float(net["cvs"][i]["volume_m3"]) * 1000.0, 0.01)
			sens += (t_cool[i] - (float(proc["cooling"]["t_c"]) + 273.15)) * m * 4186.0
		var g: PackedFloat64Array = gas[i]
		for s in COND:
			latent += g[s] * _latent(s)
	if bed != null:
		sens += float(bed.totals()["e_j"])
	return sens + latent


# ---------------------------------------------------------------------------
# Snapshots
# ---------------------------------------------------------------------------

func snapshot() -> Dictionary:
	var g: Array = []
	var l: Array = []
	for i in n_cv:
		g.append((gas[i] as PackedFloat64Array).duplicate())
		l.append((liq[i] as PackedFloat64Array).duplicate())
	return {"t_s": t_s, "gas": g, "liq": l, "h_gas": h_gas.duplicate(), "h_liq": h_liq.duplicate(),
		"t_wall": t_wall.duplicate(), "v_free": v_free.duplicate(), "p_cv": p_cv.duplicate(), "t_cool": t_cool.duplicate(),
		"link_open": link_open.duplicate(), "relief_open": relief_open.duplicate(), "drain_open": drain_open.duplicate(),
		"heater_w": heater_w.duplicate(), "heater_on": heater_on.duplicate(), "heater_fused": heater_fused.duplicate(),
		"cool_lpm": cool_lpm.duplicate(), "bed": bed.snapshot() if bed != null else {},
		"element_t": element_t.duplicate(), "events": events.duplicate(true), "seen": _event_seen.duplicate(),
		"ledger": [e_in, e_loss, e_cool, e_react, e_out], "product_mol": product_mol.duplicate(),
		"vented_mol": vented_mol.duplicate(), "drained_mol": drained_mol.duplicate(),
		"last_x": _last_product_x.duplicate(), "stored0": _stored0, "mass0": _mass0, "mass_in": _mass_in,
		"drained_by": drained_by.duplicate(), "bed_acc": _bed_acc, "bed_n": _bed_n, "bed_rel": _bed_rel.duplicate(true),
		"bed_rel_left": _bed_rel_left, "bed_events_due": _bed_events_due,
		"auto": automations.snapshot() if automations != null else {}, "auto_acc": _auto_acc,
		"logic": logic_state.duplicate(true), "logic_status": logic_status.duplicate(true),
		"link_frac": link_frac.duplicate(), "pump_on": pump_on.duplicate(), "pump_speed": pump_speed.duplicate(),
		"pump_kwh": pump_kwh, "v_free_l": v_free.duplicate(),
		"agit_on": agit_on.duplicate(), "jacket": jacket.duplicate(true),
		"ads": ads_mol.duplicate(), "burned": burned_mol.duplicate(), "engine_on": engine_on.duplicate(),
		"engine_kwh": engine_kwh}


func restore(s: Dictionary) -> void:
	t_s = float(s["t_s"])
	gas = []
	liq = []
	for a in s["gas"]:
		gas.append((a as PackedFloat64Array).duplicate())
	for a in s["liq"]:
		liq.append((a as PackedFloat64Array).duplicate())
	h_gas = (s["h_gas"] as PackedFloat64Array).duplicate()
	h_liq = (s["h_liq"] as PackedFloat64Array).duplicate()
	t_wall = (s["t_wall"] as PackedFloat64Array).duplicate()
	v_free = (s["v_free"] as PackedFloat64Array).duplicate()
	p_cv = (s["p_cv"] as PackedFloat64Array).duplicate()
	t_cool = (s["t_cool"] as PackedFloat64Array).duplicate()
	link_open = (s["link_open"] as Array).duplicate()
	relief_open = (s["relief_open"] as Array).duplicate()
	drain_open = (s["drain_open"] as Dictionary).duplicate()
	heater_w = (s["heater_w"] as Dictionary).duplicate()
	heater_on = (s["heater_on"] as Dictionary).duplicate()
	heater_fused = (s["heater_fused"] as Dictionary).duplicate()
	cool_lpm = (s["cool_lpm"] as Dictionary).duplicate()
	if bed != null and not (s["bed"] as Dictionary).is_empty():
		bed.restore(s["bed"])
	element_t = (s["element_t"] as Array).duplicate()
	events = (s["events"] as Array).duplicate(true)
	_event_seen = (s["seen"] as Dictionary).duplicate()
	var lg: Array = s["ledger"]
	e_in = float(lg[0])
	e_loss = float(lg[1])
	e_cool = float(lg[2])
	e_react = float(lg[3])
	e_out = float(lg[4])
	product_mol = (s["product_mol"] as PackedFloat64Array).duplicate()
	vented_mol = (s["vented_mol"] as PackedFloat64Array).duplicate()
	drained_mol = (s["drained_mol"] as PackedFloat64Array).duplicate()
	_last_product_x = (s["last_x"] as PackedFloat64Array).duplicate()
	_stored0 = float(s.get("stored0", _stored0))
	_mass0 = float(s.get("mass0", _mass0))
	_mass_in = float(s.get("mass_in", 0.0))
	drained_by = (s.get("drained_by", {}) as Dictionary).duplicate()
	_bed_acc = float(s.get("bed_acc", 0.0))
	_bed_n = int(s.get("bed_n", 0))
	_bed_rel = (s.get("bed_rel", {}) as Dictionary).duplicate(true)
	_bed_rel_left = float(s.get("bed_rel_left", 0.0))
	_bed_events_due = bool(s.get("bed_events_due", false))
	if automations != null:
		automations.restore(s.get("auto", {}))
	_auto_acc = float(s.get("auto_acc", 0.0))
	logic_state = (s.get("logic", {}) as Dictionary).duplicate(true)
	if s.has("link_frac"):
		link_frac = (s["link_frac"] as Array).duplicate()
		pump_on = (s["pump_on"] as Dictionary).duplicate()
		pump_speed = (s["pump_speed"] as Dictionary).duplicate()
		pump_kwh = float(s.get("pump_kwh", 0.0))
	if s.has("agit_on"):
		agit_on = (s["agit_on"] as Dictionary).duplicate()
		jacket = (s["jacket"] as Dictionary).duplicate(true)
	logic_status = (s.get("logic_status", {}) as Dictionary).duplicate(true)
	if s.has("ads"):
		ads_mol = (s["ads"] as PackedFloat64Array).duplicate()
		burned_mol = (s["burned"] as PackedFloat64Array).duplicate()
		engine_on = (s["engine_on"] as Dictionary).duplicate()
		engine_kwh = float(s["engine_kwh"])
	for k in engine_kw.keys():
		engine_kw[k] = 0.0
	flare_kw = 0.0
	product_rate = _zeros()


## Go to time t: restore the latest keyframe at or before it and step on.
func seek(t: float) -> void:
	var best: Dictionary = keyframes[0]
	for k in keyframes:
		if float(k["t_s"]) <= t + 1e-6:
			best = k
	restore(best["state"])
	run_for(maxf(t - t_s, 0.0))
