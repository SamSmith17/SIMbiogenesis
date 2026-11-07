class_name TcBed
extends RefCounted

## A solid charge in a vessel (TC Process Lab, Phase 2): wood chips round
## heating elements, or plastic pellets. The charge is split into one
## DOMAIN per element (equal volumes; an element on the axis gets the whole
## vessel), each an axisymmetric grid of NR rings × NZ layers round its
## element. Heat goes into the innermost ring over the element's reach,
## spreads ring to ring and layer to layer, and leaves through the outer
## ring to the vessel wall and the top layer to the headspace gas. Each cell
## dries at its boiling point (the heat above it boils the moisture off),
## then pyrolyses by its own temperature (Miller & Bellan, as
## TcReactions.wood_step) — which is what makes a drying front, then a
## pyrolysis front, grow out from each element.
##
## Effective conductivity of the packed bed: conduction 0.12 W/m·K for
## wood chips (an estimate in the 0.1–0.2 range measured for chip piles)
## plus radiation across the pores, k_r = 4·ε·σ·d·T³ (Damköhler; chip size
## d 10 mm, ε 0.85) — radiation dominates above ~400 °C, so the hot core
## spreads faster than the cold edge.
##
## Energies are sensible enthalpies relative to T0 (J); a cell's T =
## T0 + E / C. Mass leaving a cell (steam, volatiles) takes its share of
## E with it, so the sim's energy ledger closes.
##
## Cells are packed arrays per domain (the first cut kept a Dictionary per
## cell and cost ~27 µs a cell a step): a domain is {center_mm, r_out_m,
## part, reach_m, base_m, n, T, E, mw (moisture), cel, hem, lig, cel_a,
## hem_a, lig_a, char, ash, pl (plastic), v0, dried, pyro, r, ri, ro,
## a_side, a_ax} with index i = k·NR + j (layer k, ring j).

const NR := 8
const NZ := 6
const T0 := 298.15
const K_COND := 0.12
const CHIP_D := 0.010
const EPS := 0.85
const R_ELEMENT := 0.020      # the element's loop bundle radius, m (estimate)
const PARTICLE_RHO := 500.0   # chip particle density, kg/m³ (dry softwood ~450–550)
const H_CONTACT := 60.0       # element sheath → bed contact h, W/m²·K (estimate)
const H_WALL := 25.0          # bed → vessel wall contact h, W/m²·K (estimate)
const H_TOP := 8.0            # bed top → headspace gas h, W/m²·K (natural convection)
const MIN_REACT_K := 420.0    # below this pyrolysis is negligible over a batch
const H_VAP := 40660.0        # J/mol, water at 100 °C (TcSpecies)
const CP_STEAM := 35.2        # J/mol·K (TcSpecies, 500 K)
const M_W := 0.018015

const WOOD_KEYS := ["cellulose", "hemicellulose", "lignin", "cellulose_a", "hemicellulose_a", "lignin_a"]
const ARR := ["T", "E", "mw", "cel", "hem", "lig", "cel_a", "hem_a", "lig_a", "char", "ash", "pl", "v0", "dried", "pyro",
	"r", "ri", "ro", "a_side", "a_ax"]
## Virgin and active array per wood component, in TcReactions.WOOD order.
const COMP := [["cel", "cel_a", "cellulose"], ["hem", "hem_a", "hemicellulose"], ["lig", "lig_a", "lignin"]]

var domains: Array = []
var height_m := 0.0
var dz := 0.0
var feed := "wood_chips"
var plastic := ""
# An emptied cell (all its plastic cracked, no char left) still has its void
# gas and the pot wall behind it: a floor on its heat capacity, so heat that
# lands in it cannot spike it (J/K, an estimate).
const CAP_FLOOR := 5.0
# Melting points (Brandrup, Polymer Handbook: HDPE ~130 °C, isotactic PP
# ~165 °C) and the melt pool's effective conductivity / sheath coefficient —
# molten polymer conducts ~0.2 W/m·K; natural convection in the pool is
# what moves the heat (estimates, chosen to crack a retort of pellets in
# hours, as reported for small batch units).
const MELT_K := {"pe": 403.0, "pp": 438.0}
const K_MELT := 2.0
const H_MELT := 150.0
const PLASTIC_GAS_CP := 2500.0   # J/kg·K, the cracked vapours (oil / wax / C3 mix, estimate)
var solid_volume_m3 := 0.0
var initial_dry_kg := 0.0
var initial_moisture_kg := 0.0
# Volatile mass splits and molar data, cached once.
static var _gas_cp := {}


## heaters: [{part, at_mm (vessel frame), reach_mm}]; vessel: the net's
## vessel CV. charge: TcProcSpec charge block.
static func create(vessel: Dictionary, heaters: Array, charge: Dictionary) -> TcBed:
	var b := TcBed.new()
	b._setup(vessel, heaters, charge)
	return b


func _setup(vessel: Dictionary, heaters: Array, charge: Dictionary) -> void:
	feed = str(charge.get("feed", "wood_chips"))
	var fd: Dictionary = TcProcSpec.FEEDS.get(feed, TcProcSpec.FEEDS["wood_chips"])
	var solid: Dictionary = fd.get("solid", {})
	if solid.is_empty():
		return   # a liquid charge: the sim's pool, not a bed
	if solid.has("pe"):
		plastic = "pe"
	elif solid.has("pp"):
		plastic = "pp"
	var R := float(vessel.get("r_in_m", 0.15))
	var H := float(vessel.get("height_m", 0.5))
	var mass := float(charge.get("mass_kg", 10.0))
	var moist := float(charge.get("moisture", 0.2)) if plastic == "" else 0.0
	var bulk := float(charge.get("bulk_kg_m3", 0.0))
	if bulk <= 0.0:
		bulk = float(fd.get("bulk_kg_m3", 250.0))
	var vol := mass / bulk
	height_m = clampf(vol / (PI * R * R), 0.02, H)
	dz = height_m / float(NZ)
	initial_moisture_kg = mass * moist
	initial_dry_kg = mass - initial_moisture_kg
	solid_volume_m3 = minf(mass / PARTICLE_RHO, PI * R * R * height_m * 0.9)
	var n := maxi(heaters.size(), 1)
	var r_dom := R / sqrt(float(n))
	var nc := NR * NZ
	for di in n:
		var h: Dictionary = heaters[di] if di < heaters.size() else {}
		var at: Vector3 = h.get("at_mm", Vector3.ZERO)
		var dom := {"center_mm": Vector3(at.x, 0.0, at.z), "r_out_m": r_dom if heaters.size() > 1 else R,
			"part": str(h.get("part", "")), "reach_m": float(h.get("reach_mm", 0.0)) * 0.001, "base_m": maxf(at.y * 0.001, 0.0),
			"n": nc}
		if heaters.is_empty():
			dom["center_mm"] = Vector3.ZERO
		for key in ARR:
			var a := PackedFloat64Array()
			a.resize(nc)
			dom[key] = a
		var r_in := R_ELEMENT if not heaters.is_empty() else 0.0
		var r_out := float(dom["r_out_m"])
		var dr := (r_out - r_in) / float(NR)
		# The charge fills the annulus round the element: this domain's
		# share of the mass spread over that volume.
		var dom_vol := PI * (r_out * r_out - r_in * r_in) * height_m
		var rho_dom := mass / float(n) / maxf(dom_vol, 1e-9)
		for k in NZ:
			for j in NR:
				var i := k * NR + j
				var ri := r_in + dr * j
				var ro := ri + dr
				var v := PI * (ro * ro - ri * ri) * dz
				var share := v * rho_dom
				var dry := share * (1.0 - moist)
				dom["r"][i] = (ri + ro) * 0.5
				dom["ri"][i] = ri
				dom["ro"][i] = ro
				dom["a_side"][i] = 2.0 * PI * ro * dz
				dom["a_ax"][i] = PI * (ro * ro - ri * ri)
				dom["mw"][i] = share * moist
				dom["T"][i] = T0
				dom["dried"][i] = -1.0
				dom["pyro"][i] = -1.0
				dom["cel"][i] = dry * float(solid.get("cellulose", 0.0))
				dom["hem"][i] = dry * float(solid.get("hemicellulose", 0.0))
				dom["lig"][i] = dry * float(solid.get("lignin", 0.0))
				dom["ash"][i] = dry * float(solid.get("ash", 0.0))
				dom["pl"][i] = dry * (float(solid.get("pe", 0.0)) + float(solid.get("pp", 0.0)))
				dom["v0"][i] = maxf(_volatile_at(dom, i), 1e-9)
		domains.append(dom)


func is_empty() -> bool:
	return domains.is_empty()


static func _heat_capacity_at(d: Dictionary, i: int) -> float:
	var wood: float = d["cel"][i] + d["hem"][i] + d["lig"][i] + d["cel_a"][i] + d["hem_a"][i] + d["lig_a"][i]
	var cp: float = wood * 1500.0 + d["char"][i] * 1000.0 + d["ash"][i] * 800.0 + d["mw"][i] * 4186.0 + d["pl"][i] * 2100.0
	return maxf(cp, CAP_FLOOR)


## Heat capacity (J/K) of a cell's contents.
static func _cap(wood_kg: float, char_kg: float, ash_kg: float, water_kg: float, plastic_kg: float) -> float:
	return maxf(wood_kg * 1500.0 + char_kg * 1000.0 + ash_kg * 800.0 + water_kg * 4186.0 + plastic_kg * 2100.0, CAP_FLOOR)


## One wood component over dt at t (Miller & Bellan, exact first-order
## decay): [virgin', active', tar, char, gas, heat (J, + = absorbed)].
static func _mb(v: float, a: float, p: Array, t: float, dt: float) -> PackedFloat64Array:
	var k1 := TcReactions.arrhenius(float(p[0]), float(p[1]), t)
	var k2 := TcReactions.arrhenius(float(p[2]), float(p[3]), t)
	var k3 := TcReactions.arrhenius(float(p[4]), float(p[5]), t)
	var x := float(p[6])
	var dv := v * (1.0 - exp(-k1 * dt))
	var a2 := a + dv
	var ks := k2 + k3
	var da := a2 * (1.0 - exp(-ks * dt))
	var to_tar := da * k2 / maxf(ks, 1e-30)
	var to_cg := da - to_tar
	return PackedFloat64Array([v - dv, a2 - da, to_tar, to_cg * x, to_cg * (1.0 - x),
		dv * TcReactions.H_ACTIVE + to_tar * TcReactions.H_TAR + to_cg * TcReactions.H_CHAR])


static func _volatile_at(d: Dictionary, i: int) -> float:
	return d["cel"][i] + d["hem"][i] + d["lig"][i] + d["cel_a"][i] + d["hem_a"][i] + d["lig_a"][i] + d["pl"][i]


static func k_eff(t_k: float) -> float:
	return K_COND + 4.0 * EPS * TcThermo.SIGMA * CHIP_D * t_k * t_k * t_k


## Plastic pellets melt (PE ~130 °C, PP ~165 °C): the melt wets the element
## and stirs itself, so heat crosses it far faster than across packed pellets.
func _molten(t_k: float, pl_kg: float) -> bool:
	return plastic != "" and pl_kg > 1e-6 and t_k >= float(MELT_K.get(plastic, 1e9))


func _k_pair(ta: float, tb: float, pa: float, pb: float) -> float:
	if _molten(ta, pa) and _molten(tb, pb):
		return K_MELT
	return k_eff((ta + tb) * 0.5)


## Every cell to one temperature (setup).
func set_uniform_t(t_k: float) -> void:
	for d in domains:
		for i in int(d["n"]):
			d["T"][i] = t_k
			d["E"][i] = (t_k - T0) * _heat_capacity_at(d, i)


static func _cp_of(species: String) -> float:
	if not _gas_cp.has(species):
		_gas_cp[species] = float(TcSpecies.row(species).get("cp_g", 35.0)) / TcSpecies.molar_mass_kg(species)
	return float(_gas_cp[species])


## Steps the bed dt seconds. heat_w[i] = element watts into domain i;
## t_wall / t_gas the vessel wall and headspace gas (K); t_boil the
## moisture's boiling point at the vessel pressure (K).
## Returns {to_wall_j, to_gas_j, steam_mol, steam_j (its sensible enthalpy),
## volatiles: {species: kg}, volatiles_j, tar_kg, react_j, latent_j,
## formed_latent_j, element_t: [K]}.
func step(dt: float, heat_w: Array, t_wall: float, t_gas: float, t_boil: float, t_now: float) -> Dictionary:
	var out := {"to_wall_j": 0.0, "to_gas_j": 0.0, "steam_mol": 0.0, "steam_j": 0.0, "volatiles": {}, "volatiles_j": 0.0,
		"tar_kg": 0.0, "react_j": 0.0, "latent_j": 0.0, "formed_latent_j": 0.0, "element_t": []}
	var to_wall := 0.0
	var to_gas := 0.0
	var steam_out := 0.0
	var steam_j := 0.0
	var vol_j := 0.0
	var tar_tot := 0.0
	var react := 0.0
	var latent := 0.0
	var formed := 0.0
	var vol := {}
	var wood := TcReactions.WOOD
	for di in domains.size():
		var d: Dictionary = domains[di]
		var nc := int(d["n"])
		var T: PackedFloat64Array = d["T"]
		var E: PackedFloat64Array = d["E"]
		var MW: PackedFloat64Array = d["mw"]
		var CH: PackedFloat64Array = d["char"]
		var a_side: PackedFloat64Array = d["a_side"]
		var a_ax: PackedFloat64Array = d["a_ax"]
		var rr: PackedFloat64Array = d["r"]
		var q := PackedFloat64Array()
		q.resize(nc)
		# Element heat into the inner ring over its reach.
		var P := float(heat_w[di]) if di < heat_w.size() else 0.0
		var reach := float(d["reach_m"])
		var base := float(d["base_m"])
		var layers := PackedFloat64Array()
		layers.resize(NZ)
		var tot := 0.0
		for k in NZ:
			var z0 := dz * k
			var ov := clampf(minf(z0 + dz, base + reach) - maxf(z0, base), 0.0, dz) if reach > 0.0 else dz
			layers[k] = ov
			tot += ov
		var t_el := T0
		for k in NZ:
			var share := layers[k] / tot if tot > 0.0 else 0.0
			q[k * NR] += P * share * dt
			if share > 0.0:
				var tc0 := T[k * NR]
				var a := 2.0 * PI * R_ELEMENT * layers[k]
				# Contact plus radiation from the sheath to the chips round it.
				var h := H_CONTACT + 4.0 * EPS * TcThermo.SIGMA * tc0 * tc0 * tc0
				if _molten(tc0, float((d["pl"] as PackedFloat64Array)[k * NR])):
					h = maxf(h, H_MELT)
				t_el = maxf(t_el, tc0 + P * share / maxf(h * a, 1e-6))
		(out["element_t"] as Array).append(t_el)
		# Conduction, IMPLICIT (backward Euler): the hot core's cells are
		# small and dry char holds little heat, so an explicit step of
		# 30 s overshoots there. Solve (C/dt + Σg) T' = C T / dt + Σ g T'_n
		# + boundary terms by Gauss–Seidel, then take every pair's flux
		# from the solved T' and apply it to both sides — conservative by
		# construction, and bounded because T' never leaves its
		# neighbours' range.
		var Cc := PackedFloat64Array()
		var gR := PackedFloat64Array()
		var gZ := PackedFloat64Array()
		var gW := PackedFloat64Array()
		var gG := PackedFloat64Array()
		Cc.resize(nc)
		gR.resize(nc)
		gZ.resize(nc)
		gW.resize(nc)
		gG.resize(nc)
		var ASH0: PackedFloat64Array = d["ash"]
		var PL0: PackedFloat64Array = d["pl"]
		var w0: Array = [d["cel"], d["hem"], d["lig"], d["cel_a"], d["hem_a"], d["lig_a"]]
		for i in nc:
			var wk := 0.0
			for arr in w0:
				wk += (arr as PackedFloat64Array)[i]
			Cc[i] = _cap(wk, CH[i], ASH0[i], MW[i], PL0[i])
			var j := i % NR
			if j < NR - 1:
				gR[i] = _k_pair(T[i], T[i + 1], PL0[i], PL0[i + 1]) * a_side[i] / maxf(rr[i + 1] - rr[i], 1e-4)
			else:
				gW[i] += H_WALL * a_side[i]
			if i + NR < nc:
				gZ[i] = _k_pair(T[i], T[i + NR], PL0[i], PL0[i + NR]) * a_ax[i] / dz
			else:
				gG[i] = H_TOP * a_ax[i]
			if i < NR:
				gW[i] += H_WALL * a_ax[i]
		var Tn := T.duplicate()
		for _sweep in 8:
			for i in nc:
				var j := i % NR
				var cdt := Cc[i] / dt
				var num := cdt * T[i] + q[i] / dt + gW[i] * t_wall + gG[i] * t_gas
				var den := cdt + gW[i] + gG[i]
				if j < NR - 1:
					num += gR[i] * Tn[i + 1]
					den += gR[i]
				if j > 0:
					num += gR[i - 1] * Tn[i - 1]
					den += gR[i - 1]
				if i + NR < nc:
					num += gZ[i] * Tn[i + NR]
					den += gZ[i]
				if i >= NR:
					num += gZ[i - NR] * Tn[i - NR]
					den += gZ[i - NR]
				Tn[i] = num / den
		for i in nc:
			if i % NR < NR - 1:
				var f := gR[i] * (Tn[i] - Tn[i + 1]) * dt
				q[i] -= f
				q[i + 1] += f
			if i + NR < nc:
				var fu := gZ[i] * (Tn[i] - Tn[i + NR]) * dt
				q[i] -= fu
				q[i + NR] += fu
			if gW[i] > 0.0:
				var fw := gW[i] * (Tn[i] - t_wall) * dt
				q[i] -= fw
				to_wall += fw
			if gG[i] > 0.0:
				var fg := gG[i] * (Tn[i] - t_gas) * dt
				q[i] -= fg
				to_gas += fg
		# Apply heat, dry, pyrolyse — column by column from the bottom up.
		# What a cell gives off rises through the cells above it as a
		# PACKET: its steam condenses in any cell still below the boiling
		# point (the heat pipe that runs a wet bed's drying front ahead of
		# conduction), and its hot gas trades heat with each cell it passes.
		# Local copies (packed arrays are copy-on-write: a write through a
		# Dictionary lookup lands on a copy), written back after the loop.
		var CEL: PackedFloat64Array = d["cel"]
		var HEM: PackedFloat64Array = d["hem"]
		var LIG: PackedFloat64Array = d["lig"]
		var CELA: PackedFloat64Array = d["cel_a"]
		var HEMA: PackedFloat64Array = d["hem_a"]
		var LIGA: PackedFloat64Array = d["lig_a"]
		var ASH: PackedFloat64Array = d["ash"]
		var PL: PackedFloat64Array = d["pl"]
		var V0: PackedFloat64Array = d["v0"]
		var DRY: PackedFloat64Array = d["dried"]
		var PYR: PackedFloat64Array = d["pyro"]
		var pc: Array = wood["cellulose"]
		var ph: Array = wood["hemicellulose"]
		var pg: Array = wood["lignin"]
		for j in NR:
			var pk_steam := 0.0
			var pk_h := 0.0
			var pk_cp := 0.0
			var pk_gas := {}
			var pk_gas_mol := 0.0
			for k in NZ:
				var i := k * NR + j
				var e := E[i] + q[i]
				var C := _cap(CEL[i] + HEM[i] + LIG[i] + CELA[i] + HEMA[i] + LIGA[i], CH[i], ASH[i], MW[i], PL[i])
				var t := T0 + e / C
				# The packet from below.
				if pk_cp > 0.0:
					var tp := T0 + pk_h / pk_cp
					var ex := 0.8 * (tp - t) * (pk_cp * C) / (pk_cp + C)
					pk_h -= ex
					e += ex
					t = T0 + e / C
				if pk_steam > 0.0 and t < t_boil - 0.5:
					var l_kg := H_VAP / M_W
					var tpk := T0 + pk_h / maxf(pk_cp, 1e-9)
					var m_max := (t_boil - t) * C / (l_kg + CP_STEAM / M_W * maxf(tpk - t, 0.0))
					var m := minf(pk_steam * M_W * 0.6, maxf(m_max, 0.0))
					if m > 0.0:
						var mol := m / M_W
						var hs := pk_h * mol / maxf(pk_steam + pk_gas_mol, 1e-12)
						pk_h -= hs
						pk_cp -= mol * CP_STEAM
						pk_steam -= mol
						MW[i] += m
						e += mol * H_VAP + hs
						latent -= mol * H_VAP
						C += m * 4186.0
						t = T0 + e / C
				var mw := MW[i]
				if mw > 0.0 and t > t_boil:
					# Heat above the boiling point boils water off.
					var boil := minf(mw, (t - t_boil) * C / (H_VAP / M_W))
					var mol2 := boil / M_W
					e -= mol2 * H_VAP
					latent += mol2 * H_VAP
					# The steam leaves with a vapour's sensible heat at the
					# boiling point; the liquid's extra stays in the cell.
					var sens := mol2 * CP_STEAM * (t_boil - T0)
					e -= sens
					pk_steam += mol2
					pk_h += sens
					pk_cp += mol2 * CP_STEAM
					MW[i] = mw - boil
					if MW[i] <= 1e-6 and DRY[i] < 0.0:
						DRY[i] = t_now
					C -= boil * 4186.0
					t = T0 + e / C
				if t >= MIN_REACT_K and MW[i] <= 1e-6:
					var made := {}
					var q_r := 0.0
					if plastic != "":
						var ps := TcReactions.plastic_step(plastic, PL[i], t, dt)
						var dkg := float(ps["reacted_kg"])
						# Cracking takes its heat from the cell: never more than
						# the cell holds above the onset (a plastic cell burns
						# out to nothing, with no char to keep its heat).
						var per_kg := float(ps["q_j"]) / maxf(dkg, 1e-12) + PLASTIC_GAS_CP * (t - T0) - 2100.0 * (MIN_REACT_K - T0)
						var room := e - C * (MIN_REACT_K - T0)
						var f := 1.0
						if dkg > 0.0 and per_kg > 0.0 and dkg * per_kg > room:
							f = clampf(room / (dkg * per_kg), 0.0, 1.0)
						PL[i] -= dkg * f
						made = (ps["products"] as Dictionary).duplicate()
						for s4 in made.keys():
							made[s4] = float(made[s4]) * f
						q_r = float(ps["q_j"]) * f
					else:
						# Miller & Bellan, inline (TcReactions.wood_step's maths).
						var rc := _mb(CEL[i], CELA[i], pc, t, dt)
						var rh := _mb(HEM[i], HEMA[i], ph, t, dt)
						var rl := _mb(LIG[i], LIGA[i], pg, t, dt)
						CEL[i] = rc[0]
						CELA[i] = rc[1]
						HEM[i] = rh[0]
						HEMA[i] = rh[1]
						LIG[i] = rl[0]
						LIGA[i] = rl[1]
						var tar := rc[2] + rh[2] + rl[2]
						var char := rc[3] + rh[3] + rl[3]
						var gas_kg := rc[4] + rh[4] + rl[4]
						q_r = rc[5] + rh[5] + rl[5]
						CH[i] += char
						tar_tot += tar
						if gas_kg > 0.0:
							var split := TcReactions.gas_split_mass(t)
							for s in split.keys():
								made[s] = gas_kg * float(split[s])
						if tar > 0.0:
							var acid := tar * TcReactions.TAR_ACID_SHARE
							made["tar"] = tar - acid
							made["acetic"] = acid
					var hmade := 0.0
					for s2 in made.keys():
						var kg := float(made[s2])
						if kg <= 0.0:
							continue
						var cpk := _cp_of(s2)
						hmade += kg * cpk
						if s2 == "H2O":
							# Reaction water leaves as vapour: its latent heat is
							# part of the reaction's (booked as formed).
							var mol3 := kg / M_W
							pk_steam += mol3
							formed += mol3 * H_VAP
						else:
							pk_gas[s2] = float(pk_gas.get(s2, 0.0)) + kg
							pk_gas_mol += kg / TcSpecies.molar_mass_kg(s2)
						pk_cp += kg * cpk
					if hmade > 0.0:
						# The volatiles leave carrying their sensible heat at the
						# cell's temperature, so the cell does not jump.
						var sens2 := minf(hmade * (t - T0), maxf(e, 0.0))
						e -= sens2
						pk_h += sens2
						e -= q_r
						react += q_r
						var left := CEL[i] + HEM[i] + LIG[i] + CELA[i] + HEMA[i] + LIGA[i] + PL[i]
						if PYR[i] < 0.0 and 1.0 - left / maxf(V0[i], 1e-9) > 0.5:
							PYR[i] = t_now
				C = _cap(CEL[i] + HEM[i] + LIG[i] + CELA[i] + HEMA[i] + LIGA[i], CH[i], ASH[i], MW[i], PL[i])
				E[i] = e
				T[i] = T0 + e / C
			# Out of the top of the column into the headspace.
			steam_out += pk_steam
			var share_steam := pk_steam * CP_STEAM / pk_cp if pk_cp > 0.0 else 0.0
			steam_j += pk_h * share_steam
			vol_j += pk_h * (1.0 - share_steam)
			for s3 in pk_gas.keys():
				vol[s3] = float(vol.get(s3, 0.0)) + float(pk_gas[s3])
		d["T"] = T
		d["E"] = E
		d["mw"] = MW
		d["char"] = CH
		d["pl"] = PL
		d["cel"] = CEL
		d["hem"] = HEM
		d["lig"] = LIG
		d["cel_a"] = CELA
		d["hem_a"] = HEMA
		d["lig_a"] = LIGA
		d["dried"] = DRY
		d["pyro"] = PYR
	out["to_wall_j"] = to_wall
	out["to_gas_j"] = to_gas
	out["steam_mol"] = steam_out
	out["steam_j"] = steam_j
	out["volatiles"] = vol
	out["volatiles_j"] = vol_j
	out["tar_kg"] = tar_tot
	out["react_j"] = react
	out["latent_j"] = latent
	out["formed_latent_j"] = formed
	return out


## How far a cell has pyrolysed: 0 fresh … 1 all reacted (char / gone).
static func converted_at(d: Dictionary, i: int) -> float:
	return clampf(1.0 - _volatile_at(d, i) / maxf(float(d["v0"][i]), 1e-9), 0.0, 1.0)


## A cell's state for the views: 0 wet, 1 dry, 2 pyrolysing, 3 char.
static func stage_at(d: Dictionary, i: int) -> int:
	if float(d["mw"][i]) > 1e-6:
		return 0
	var cv := converted_at(d, i)
	if cv >= 0.9:
		return 3
	if cv > 0.05:
		return 2
	return 1


## Mass held in the charge (kg).
func mass_kg() -> float:
	var m := 0.0
	for d in domains:
		for i in int(d["n"]):
			m += float(d["mw"][i]) + float(d["char"][i]) + float(d["ash"][i]) + _volatile_at(d, i)
	return m


## Bed totals: {moisture_kg, wood_kg (virgin + active), char_kg, plastic_kg,
## t_max_k, t_mean_k, e_j (sensible), dry_frac, pyro_frac, cells}.
func totals() -> Dictionary:
	var mw := 0.0
	var wd := 0.0
	var ch := 0.0
	var pl := 0.0
	var tmax := 0.0
	var tsum := 0.0
	var e := 0.0
	var n := 0
	var dry_cells := 0
	var pyro_cells := 0
	for d in domains:
		for i in int(d["n"]):
			mw += float(d["mw"][i])
			wd += float(d["cel"][i]) + float(d["hem"][i]) + float(d["lig"][i]) + float(d["cel_a"][i]) + float(d["hem_a"][i]) + float(d["lig_a"][i])
			ch += float(d["char"][i])
			pl += float(d["pl"][i])
			var t := float(d["T"][i])
			tmax = maxf(tmax, t)
			tsum += t
			e += float(d["E"][i])
			n += 1
			if float(d["mw"][i]) <= 1e-6:
				dry_cells += 1
			if converted_at(d, i) > 0.5:
				pyro_cells += 1
	return {"moisture_kg": mw, "wood_kg": wd, "char_kg": ch, "plastic_kg": pl, "t_max_k": tmax,
		"t_mean_k": tsum / float(maxi(n, 1)), "e_j": e, "dry_frac": float(dry_cells) / float(maxi(n, 1)),
		"pyro_frac": float(pyro_cells) / float(maxi(n, 1)), "cells": n}


## How far out from the element each front has reached in a domain's middle
## layer (m from the element): {dry_m, pyro_m}.
func fronts(di: int = 0) -> Dictionary:
	if di >= domains.size():
		return {"dry_m": 0.0, "pyro_m": 0.0}
	var d: Dictionary = domains[di]
	var k := mini(NZ / 2, NZ - 1)
	var dry := 0.0
	var pyro := 0.0
	for j in NR:
		var i := k * NR + j
		if float(d["mw"][i]) <= 1e-6:
			dry = float(d["ro"][i]) - R_ELEMENT
		if converted_at(d, i) > 0.5:
			pyro = float(d["ro"][i]) - R_ELEMENT
	return {"dry_m": dry, "pyro_m": pyro}


func snapshot() -> Dictionary:
	return {"domains": domains.duplicate(true), "height_m": height_m, "dz": dz, "feed": feed, "plastic": plastic,
		"solid_volume_m3": solid_volume_m3, "initial_dry_kg": initial_dry_kg, "initial_moisture_kg": initial_moisture_kg}


func restore(s: Dictionary) -> void:
	domains = (s.get("domains", []) as Array).duplicate(true)
	height_m = float(s.get("height_m", 0.0))
	dz = float(s.get("dz", 0.0))
	feed = str(s.get("feed", "wood_chips"))
	plastic = str(s.get("plastic", ""))
	solid_volume_m3 = float(s.get("solid_volume_m3", 0.0))
	initial_dry_kg = float(s.get("initial_dry_kg", 0.0))
	initial_moisture_kg = float(s.get("initial_moisture_kg", 0.0))
