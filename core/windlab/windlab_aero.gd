class_name WindLabAero
extends RefCounted

## The rotor: how much of the wind each type turns into shaft power at each
## tip speed ratio, and the blade shapes (cross-sections for the vertical
## axis rotors, the twisted, tapered blade for a propeller). Pure static.
##
## Definitions (as the literature uses them):
##   λ   = ω·R / v                 tip speed ratio
##   Cp  = P / (½·ρ·A·v³)          power coefficient
##   Cq  = T / (½·ρ·A·v²·R) = Cp/λ torque coefficient
##   A   = D·H for a vertical axis rotor, π·R² for a propeller.
##
## THE CURVES. Drag and hybrid rotors (Savonius, Ugrinsky, Lenz2, multi-blade)
## follow a straight torque line Cq(λ) = Cq0·(1 − λ/λr): the torque falls as
## the blades run away from the wind, to nothing at the runaway speed λr.
## Then Cp = λ·Cq peaks at λr/2 — so λr = 2·λopt and Cq0 = 2·Cp_max/λopt.
## Measured Savonius curves are close to this (Blackwell, Sheldahl & Feltz,
## "Wind tunnel performance data for two- and three-bucket Savonius rotors",
## Sandia SAND76-0131, 1977). Lift rotors (propeller, Darrieus, helical)
## follow Cp = Cp_max·x·(2 − x) with x = λ/λopt, and a Darrieus makes almost
## nothing below ~a third of its best speed (the dead band that stops it
## starting on its own — Paraschivoiu, Wind Turbine Design with Emphasis on
## Darrieus Concept, 2002).
##
## THE PEAKS. Each type's Cp_max and λopt, and the penalties for leaving its
## best proportions, are cited below; the penalty SIZES are this game's
## estimates centred on the published optimum — they say "this is worse",
## they are not a lab measurement.

## A two-bucket Savonius at its best (overlap ~0.15 of the bucket chord, end
## plates 1.1 D, aspect ratio ≥ 1): Blackwell et al. (1977) and the review by
## Akwa, Vielmo & Petry ("A review on the performance of Savonius wind
## turbines", Renew. Sust. Energy Rev. 16, 2012) put real rotors at 0.15–0.25
## near λ = 0.8–1.0. The middle of the band.
const SAV_CP := 0.19
const SAV_LAM := 0.85

## Ugrinsky: Sakamoto, Fukui & Morinishi, "Numerical study on the performance
## of 2-D Ugrinsky wind turbine model", WIT Trans. Ecol. Env. 254 (2021).
## Their 2-D lattice-Boltzmann runs at Re 1000 put the original Ugrinsky
## (S = 0.40 D, L = 1.0 R) at Cp 0.170 against a Savonius at 0.110 in the
## same model, "43 % higher", and tabulate the optimisation of the semicircle
## (S, table 2) and the tail arc (L, table 3). A 2-D, low-Re model is not a
## real rotor, so the game takes the paper's RELATIVE gain onto the measured
## Savonius above: Cp = SAV_CP × 1.43 × Cp_paper(S, L) / 0.170.
const UGR_GAIN := 1.43
const UGR_REF_CP := 0.170
## Table 2 (L = 1.0 R): S/D → [max Cp, λ at it].
const UGR_S_TABLE := [[0.25, 0.153, 0.6], [0.30, 0.173, 0.7], [0.35, 0.181, 0.5], [0.40, 0.182, 0.5], [0.45, 0.123, 0.5]]
## Table 3 (S = 0.35 D): L/R → [max Cp, λ at it].
const UGR_L_TABLE := [[0.9, 0.179, 0.6], [1.0, 0.181, 0.5], [1.1, 0.181, 0.7], [1.2, 0.178, 0.7], [1.3, 0.185, 0.6]]

## Lenz2: Ed Lenz (windstuffnow.com) claims Cp ≈ 0.38 at λ ≈ 0.8; model tests
## put its best λ at 0.8–1.2 (Bielecki et al., "Model tests of wind turbine
## with a vertical axis"), and small (300 mm) rotors measured as low as 0.06–
## 0.09 (Institut Teknologi Sepuluh Nopember, chord / blade-number study).
## The game uses a hybrid scoop between the two, for open wings on arms (the
## way Lenz builds it — end plates are not part of the design).
const LENZ_CP := 0.19
const LENZ_LAM := 0.85

## Darrieus H-rotor: Cp ≈ 0.30–0.40 for well-built rotors near solidity
## N·c/D ≈ 0.25–0.3 (Paraschivoiu 2002); best λ falls as solidity rises.
const DAR_CP := 0.34
const DAR_SIGMA := 0.28

## Multi-blade farm windmill: Cp ≈ 0.3 near λ ≈ 1 (Manwell, McGowan & Rogers,
## Wind Energy Explained, 2nd ed., 2009, the Cp–λ chart of rotor types).
const MULTI_CP := 0.28
const MULTI_LAM := 1.0

const BETZ := 16.0 / 27.0


# ---------------------------------------------------------------------------
# The curve
# ---------------------------------------------------------------------------

## {family, cp_max, lam_opt, lam_run, cq0 (the torque line's start), cq_start
## (the WORST static torque over a turn — what decides self-starting),
## dead_lo / dead_hi (lift rotors' dead band as fractions of λopt), notes,
## factors: [{label, value}]}.
static func cp_model(s: Dictionary, design_v: float = 6.0) -> Dictionary:
	var t := str(s["type"])
	var r: Dictionary = s["rotor"]
	var notes: Array = []
	var factors: Array = []
	var m := {"family": str(WindLabParts.type_info(t)["family"]), "dead_lo": 0.0, "dead_hi": 0.0}
	var cp := 0.0
	var lam := 1.0
	var cq_start := 0.0
	var hub_style := str((r["hub"] as Dictionary)["style"])
	var ar := float(r["h_mm"]) / maxf(float(r["d_mm"]), 1.0)
	match t:
		"savonius":
			cp = SAV_CP
			lam = SAV_LAM
			var ov := float(r["overlap"])
			var f_ov := maxf(1.0 - pow((ov - 0.15) / 0.40, 2.0), 0.5)
			factors.append({"label": "Overlap %.2f (best ~0.15)" % ov, "value": f_ov})
			cp *= f_ov
			if int(r["blades"]) == 3:
				cp *= 0.82
				lam *= 0.9
				factors.append({"label": "Three buckets (smoother, less power)", "value": 0.82})
			if int(r["stages"]) == 2:
				cp *= 0.96
				factors.append({"label": "Two stages (smoother torque)", "value": 0.96})
			var tw := float(r["twist_deg"])
			if tw > 0.0:
				var f_tw := 1.0 - 0.0006 * tw
				cp *= f_tw
				factors.append({"label": "Twisted %.0f°" % tw, "value": f_tw})
			# The worst static torque: a single two-bucket stage has angles it
			# will not start from; two stages, three buckets or a ≥ 90° twist
			# are positive all the way round (Blackwell et al. 1977).
			cq_start = 0.05
			if int(r["blades"]) == 3 or int(r["stages"]) == 2 or tw >= 90.0:
				cq_start = 0.2
			elif tw > 0.0:
				cq_start = lerpf(0.05, 0.2, tw / 90.0)
		"ugrinsky":
			var sr := float(r["s_ratio"])
			var lr := float(r["l_ratio"])
			var ts := _interp_table(UGR_S_TABLE, sr)
			var tl := _interp_table(UGR_L_TABLE, lr)
			# The two optimisations combined about their shared point (S = 0.35 D,
			# L = 1.0 R, Cp 0.181).
			var cp_paper := float(ts[0]) * float(tl[0]) / 0.181
			cp = SAV_CP * UGR_GAIN * cp_paper / UGR_REF_CP
			lam = clampf(float(ts[1]) + (float(tl[1]) - 0.5), 0.4, 0.9)
			factors.append({"label": "Semicircle S = %.2f D, tail L = %.2f R (paper Cp %.3f)" % [sr, lr, cp_paper], "value": cp_paper / UGR_REF_CP})
			var out_s := maxf(maxf(0.25 - sr, sr - 0.45), 0.0)
			var out_l := maxf(maxf(0.9 - lr, lr - 1.3), 0.0)
			if out_s > 0.0 or out_l > 0.0:
				var f_out := clampf(1.0 - 1.5 * (out_s + out_l * 0.5), 0.6, 1.0)
				cp *= f_out
				factors.append({"label": "Outside the studied range", "value": f_out})
				notes.append("S/D 0.25–0.45 and L/R 0.9–1.3 were simulated; this rotor is outside that, so its number is extrapolated.")
			# The paper's rotor has positive torque at every angle (at λ 0.5).
			cq_start = 0.15
		"lenz2":
			cp = LENZ_CP
			lam = LENZ_LAM
			var cf := float(r["chord_frac"])
			var f_c := maxf(1.0 - pow((cf - 0.30) / 0.25, 2.0), 0.5)
			factors.append({"label": "Wing chord %.2f D (best ~0.30)" % cf, "value": f_c})
			cp *= f_c
			var sd := float(r["set_deg"])
			var f_s := maxf(1.0 - pow((sd - 15.0) / 30.0, 2.0), 0.5)
			factors.append({"label": "Wing set %.0f° (best ~15°)" % sd, "value": f_s})
			cp *= f_s
			var nb := int(r["blades"])
			if nb != 3:
				var f_b := 0.9 if nb == 2 else 0.95
				cp *= f_b
				factors.append({"label": "%d wings (3 is the design)" % nb, "value": f_b})
			cq_start = 0.12 if nb >= 3 else 0.06
			notes.append("Lenz claims Cp 0.38; small-rotor tests found 0.06–0.09. The designer uses %.2f." % LENZ_CP)
		"darrieus_h", "helical":
			var nb2 := int(r["blades"])
			var c := float(r["chord_mm"])
			var sigma := float(nb2) * c / maxf(float(r["d_mm"]), 1.0)
			lam = clampf(1.5 / sqrt(maxf(sigma, 0.02)), 1.6, 7.0)
			var f_sig := maxf(1.0 - 2.5 * pow(sigma - DAR_SIGMA, 2.0), 0.4)
			cp = DAR_CP * f_sig
			factors.append({"label": "Solidity N·c/D = %.2f (best ~%.2f)" % [sigma, DAR_SIGMA], "value": f_sig})
			var af := WindLabParts.airfoil(str(r["airfoil"]))
			var re := lam * design_v * c * 0.001 / WindLabParts.AIR_NU
			var f_re := clampf(0.55 + 0.45 * log(maxf(re, 1.0) / 3.0e4) / log(10.0), 0.35, 1.05)
			cp *= f_re
			factors.append({"label": "Blade Reynolds number %s" % _fmt_re(re), "value": f_re})
			var f_ld := clampf(pow(float(af["ld"]) / 30.0, 0.15), 0.7, 1.08)
			cp *= f_ld
			factors.append({"label": str(af["label"]), "value": f_ld})
			var bar := float(r["h_mm"]) / maxf(c, 1.0)
			var f_tip := clampf(1.0 - 1.2 / maxf(bar, 1.0), 0.6, 1.0)
			cp *= f_tip
			factors.append({"label": "Blade aspect H/c = %.1f (tip losses)" % bar, "value": f_tip})
			m["sigma"] = sigma
			m["re"] = re
			if t == "helical":
				cp *= 0.93
				factors.append({"label": "Helical twist (smoother, a little less)", "value": 0.93})
				m["dead_lo"] = 0.08
				m["dead_hi"] = 0.4
				cq_start = 0.012 + 0.02 * clampf(float(r["helix_deg"]) / 120.0, 0.0, 1.0)
			else:
				m["dead_lo"] = 0.22
				m["dead_hi"] = 0.6
				cq_start = 0.003
				notes.append("A straight-bladed Darrieus barely starts by itself: give it a push, a small Savonius on the shaft, or let the generator motor it up.")
		"hawt":
			var hm := hawt_cp(s, design_v)
			cp = float(hm["cp"])
			lam = float(r["tsr"])
			for f in hm["factors"]:
				factors.append(f)
			m["re"] = hm["re"]
			m["ld_eff"] = hm["ld_eff"]
			var pitch := float(r["pitch_deg"])
			if absf(pitch) > 0.01:
				var f_p := maxf(1.0 - pow(pitch / 25.0, 2.0), 0.2)
				cp *= f_p
				lam *= clampf(1.0 - pitch * 0.025, 0.4, 1.5)
				factors.append({"label": "Pitched %+.0f°" % pitch, "value": f_p})
			# A twisted blade's root runs at a steep angle, so the standing rotor
			# makes a little torque (small 3-blade turbines start ~2.5–3.5 m/s).
			cq_start = 0.03 * float(r["blades"]) / 3.0 * (1.0 + maxf(pitch, 0.0) / 8.0)
		"multiblade":
			cp = MULTI_CP
			lam = MULTI_LAM
			var nb3 := int(r["blades"])
			var f_n := clampf(1.0 - absf(float(nb3) - 15.0) * 0.012, 0.8, 1.0)
			cp *= f_n
			factors.append({"label": "%d blades" % nb3, "value": f_n})
			cq_start = 0.45
	# End plates / hub and aspect ratio for the drag rotors.
	if t in ["savonius", "ugrinsky", "lenz2"]:
		if hub_style != "end_plates" and t != "lenz2":
			var f_ep := 0.78
			cp *= f_ep
			factors.append({"label": "No end plates (air spills off the blade ends)", "value": f_ep})
		if ar < 1.0:
			var f_ar := clampf(0.7 + 0.3 * ar, 0.7, 1.0)
			cp *= f_ar
			factors.append({"label": "Squat rotor H/D %.2f" % ar, "value": f_ar})
	cp = clampf(cp, 0.005, BETZ)
	m["cp_max"] = cp
	m["lam_opt"] = lam
	m["lam_run"] = lam * 2.0
	m["cq0"] = 2.0 * cp / maxf(lam, 0.05)
	m["cq_start"] = cq_start
	m["notes"] = notes
	m["factors"] = factors
	return m


## Cp at a tip speed ratio.
static func cp_at(m: Dictionary, lam: float) -> float:
	if lam <= 0.0:
		return 0.0
	var lo := float(m["lam_opt"])
	if str(m["family"]) == "lift":
		var x := lam / maxf(lo, 1e-6)
		if x >= 2.0:
			return 0.0
		var g := 1.0
		var dh := float(m["dead_hi"])
		var stat := 0.0
		if dh > 0.0:
			g = smoothstep(float(m["dead_lo"]), dh, x)
			# Below the dead band the blades still feel the standing torque
			# (the start-up torque fading as they begin to run): continuous from
			# Cq_start at rest to the lift curve.
			stat = float(m["cq_start"]) * maxf(1.0 - x / dh, 0.0) * lam
		return maxf(float(m["cp_max"]) * x * (2.0 - x) * g + stat, 0.0)
	var lr := float(m["lam_run"])
	if lam >= lr:
		return 0.0
	return float(m["cq0"]) * lam * (1.0 - lam / lr)


## Cq at a tip speed ratio (λ → 0: the torque line's start, or the worst
## static torque for a lift rotor whose curve goes to zero there).
static func cq_at(m: Dictionary, lam: float) -> float:
	if lam <= 1e-4:
		if str(m["family"]) == "lift":
			return float(m["cq_start"])
		return float(m["cq0"])
	return cp_at(m, lam) / lam


static func _interp_table(tab: Array, x: float) -> Array:
	if x <= float(tab[0][0]):
		return [float(tab[0][1]), float(tab[0][2])]
	for i in range(1, tab.size()):
		if x <= float(tab[i][0]):
			var a: Array = tab[i - 1]
			var b: Array = tab[i]
			var u := (x - float(a[0])) / (float(b[0]) - float(a[0]))
			return [lerpf(float(a[1]), float(b[1]), u), lerpf(float(a[2]), float(b[2]), u)]
	var last: Array = tab[tab.size() - 1]
	return [float(last[1]), float(last[2])]


static func _fmt_re(re: float) -> String:
	if re >= 1.0e6:
		return "%.1f M" % (re / 1.0e6)
	return "%.0f k" % (re / 1000.0)


## Swept area (m²) and radius (m).
static func area_m2(s: Dictionary) -> float:
	var r: Dictionary = s["rotor"]
	var d := float(r["d_mm"]) * 0.001
	if WindLabParts.is_vawt(s["type"]):
		return d * float(r["h_mm"]) * 0.001
	return PI * d * d * 0.25


static func radius_m(s: Dictionary) -> float:
	return float(s["rotor"]["d_mm"]) * 0.0005


# ---------------------------------------------------------------------------
# Propeller (HAWT)
# ---------------------------------------------------------------------------

## The best a propeller can do at its design tip speed ratio with B blades
## and an airfoil of lift/drag L/D (Wilson, Lissaman & Walker 1976, the fit
## quoted in Manwell et al. 2009 §3.11):
##   Cp,max = (16/27)·λ·[λ + (1.32 + ((λ − 8)/20)²)/B^(2/3)]⁻¹
##            − 0.57·λ² / [(L/D)·(λ + 1/(2B))]
## (fitted for 4 ≤ λ ≤ 20; used below that with the result kept positive).
## L/D is taken at the blade's own Reynolds number at 75 % span: small
## blades in light wind run at Re ~ 30–100 k where sections lose much of
## their lift/drag (L/D ∝ Re^0.35 here, an estimate).
static func hawt_cp(s: Dictionary, design_v: float) -> Dictionary:
	var r: Dictionary = s["rotor"]
	var b := float(r["blades"])
	var lam := float(r["tsr"])
	var af := WindLabParts.airfoil(_hawt_airfoil_id(s))
	var stations := hawt_blade(s)
	var c75 := 0.05
	var R := radius_m(s)
	for st in stations:
		if float(st["r_m"]) >= 0.75 * R:
			c75 = float(st["c_m"])
			break
	var w75 := design_v * sqrt(1.0 + pow(lam * 0.75, 2.0))
	var re := w75 * c75 / WindLabParts.AIR_NU
	var ld := float(af["ld"]) * clampf(pow(re / WindLabParts.RE_REF, 0.35), 0.35, 1.3)
	var t1 := BETZ * lam / (lam + (1.32 + pow((lam - 8.0) / 20.0, 2.0)) / pow(b, 2.0 / 3.0))
	var t2 := 0.57 * lam * lam / (ld * (lam + 1.0 / (2.0 * b)))
	var cp := maxf(t1 - t2, 0.02)
	var factors := [
		{"label": "%d blades at λ %.1f (ideal with tip losses %.3f)" % [int(b), lam, t1], "value": t1 / BETZ},
		{"label": "%s at Re %s: L/D %.0f (drag costs %.3f)" % [str(af["label"]), _fmt_re(re), ld, t2], "value": cp / maxf(t1, 1e-6)},
	]
	if str(r["construction"]) == "pvc_pipe":
		factors.append({"label": "Cut from %s pipe: a curved plate section" % fmt_pipe(float(r["pipe_d_mm"])), "value": 1.0})
	return {"cp": cp, "re": re, "ld_eff": ld, "factors": factors}


static func fmt_pipe(d_mm: float) -> String:
	return "%.0f mm" % d_mm


static func _hawt_airfoil_id(s: Dictionary) -> String:
	if str(s["rotor"]["construction"]) == "pvc_pipe":
		return "curved_plate"
	return str(s["rotor"]["airfoil"])


static func hawt_airfoil(s: Dictionary) -> Dictionary:
	return WindLabParts.airfoil(_hawt_airfoil_id(s))


## The blade, designed for the optimum rotor with wake rotation (Schmitz;
## Gasch & Twele, Wind Power Plants, 2nd ed., 2012, §5; the same as Manwell
## et al. eq. 3.105–3.106): at radius r with local speed ratio λr = λ·r/R
##   φ = (2/3)·atan(1/λr)                 the inflow angle
##   c = (16π·r / (B·Cl))·sin²(φ/2)       the chord
##   θ = φ − α + pitch                    the twist (blade angle to the plane)
## Stations from the hub to the tip; the root chord is capped at 0.25 R so
## the blade stays buildable. [{r_m, c_m, twist_deg, phi_deg}]
static func hawt_blade(s: Dictionary, n: int = 13) -> Array:
	var r: Dictionary = s["rotor"]
	var R := radius_m(s)
	var b := float(r["blades"])
	var lam := float(r["tsr"])
	var af := hawt_airfoil(s)
	var cl := float(af["cl"])
	var a := float(af["alpha_deg"])
	var r0 := float(r["hub_frac"]) * R
	var out: Array = []
	for i in n:
		var u := float(i) / float(n - 1)
		var rr := lerpf(r0, R, u)
		var lr := lam * rr / R
		var phi := (2.0 / 3.0) * atan(1.0 / maxf(lr, 1e-4))
		var c := 16.0 * PI * rr / (b * cl) * pow(sin(phi * 0.5), 2.0)
		c = minf(c, 0.25 * R)
		if i == n - 1:
			c = maxf(c * 0.7, 0.01 * R)   # a rounded-off tip, not a point
		out.append({"r_m": rr, "c_m": c, "twist_deg": rad_to_deg(phi) - a + float(r["pitch_deg"]),
			"phi_deg": rad_to_deg(phi)})
	return out


## NACA 4-digit-style section, closed, leading edge at x = 0, chord 1, upper
## surface then lower back round (n points per side). y up = suction side.
static func airfoil_points(af: Dictionary, n: int = 20) -> PackedVector2Array:
	var mc := float(af["m"])
	var p := clampf(float(af["p"]), 0.05, 0.95)
	var t := float(af["t"])
	var upper := PackedVector2Array()
	var lower := PackedVector2Array()
	for i in n + 1:
		var beta := PI * float(i) / float(n)
		var x := 0.5 * (1.0 - cos(beta))      # cosine spacing: dense at the edges
		var yt := 5.0 * t * (0.2969 * sqrt(x) - 0.126 * x - 0.3516 * x * x + 0.2843 * x * x * x - 0.1036 * x * x * x * x)
		var yc := 0.0
		var dyc := 0.0
		if mc > 0.0:
			if x < p:
				yc = mc / (p * p) * (2.0 * p * x - x * x)
				dyc = 2.0 * mc / (p * p) * (p - x)
			else:
				yc = mc / pow(1.0 - p, 2.0) * ((1.0 - 2.0 * p) + 2.0 * p * x - x * x)
				dyc = 2.0 * mc / pow(1.0 - p, 2.0) * (p - x)
		var th := atan(dyc)
		upper.append(Vector2(x - yt * sin(th), yc + yt * cos(th)))
		lower.append(Vector2(x + yt * sin(th), yc - yt * cos(th)))
	var out := PackedVector2Array()
	for i in range(upper.size() - 1, -1, -1):
		out.append(upper[i])
	for i in range(1, lower.size()):
		out.append(lower[i])
	return out


# ---------------------------------------------------------------------------
# Vertical axis cross-sections (mm, the rotor's plane, origin on the axis)
# ---------------------------------------------------------------------------

## Blade CENTRELINES in the rotor plane, blade 0 first, each an open
## PackedVector2Array (mm) plus its segments for the flat pattern:
## [{pts, segs: [{kind "arc"|"line", r_mm (arc radius), len_mm, a0, a1}]}].
## Rotor frame: x, y in the plane (y is the model's −Z), the rotor turns
## counter-clockwise seen from above.
static func vawt_blades(s: Dictionary) -> Array:
	match str(s["type"]):
		"ugrinsky":
			return _ugrinsky(s)
		"savonius":
			return _savonius(s)
		"lenz2":
			return _lenz2(s)
	return []


## Ugrinsky blade (after the shape in the lawn-sign build, which measures
## S = 0.36 D, L = 0.84 R, a 72° tail): a semicircle of diameter S laid
## radially from the rim inward, its inner end at e = R − S from the axis;
## from there a tail arc of radius L, tangent to the semicircle (an S-bend:
## its centre on the far side of the axis, L − e out), running `sweep`
## degrees round. The second blade is the first turned half a turn.
static func ugrinsky_geom(s: Dictionary) -> Dictionary:
	var r: Dictionary = s["rotor"]
	var R := float(r["d_mm"]) * 0.5
	var S := float(r["s_ratio"]) * float(r["d_mm"])
	var L := float(r["l_ratio"]) * R
	var e := R - S
	var sw := deg_to_rad(float(r["sweep_deg"]))
	var cs := Vector2((R + e) * 0.5, 0.0)
	var ct := Vector2(e - L, 0.0)
	var tip := ct + L * Vector2(cos(-sw), sin(-sw))
	return {"R": R, "S": S, "L": L, "e": e, "sweep": sw, "c_semi": cs, "c_tail": ct, "tip": tip,
		"tip_r": tip.length(), "dev_mm": PI * S * 0.5 + L * sw}


static func _ugrinsky(s: Dictionary) -> Array:
	var g := ugrinsky_geom(s)
	var R := float(g["R"])
	var S := float(g["S"])
	var L := float(g["L"])
	var e := float(g["e"])
	var sw := float(g["sweep"])
	var cs: Vector2 = g["c_semi"]
	var ct: Vector2 = g["c_tail"]
	var pts := PackedVector2Array()
	var n1 := 24
	# Semicircle from the rim (angle 0 about cs) over the +y side to the
	# junction (angle π).
	for i in n1 + 1:
		var a := PI * float(i) / float(n1)
		pts.append(cs + (S * 0.5) * Vector2(cos(a), sin(a)))
	var n2 := maxi(int(ceil(rad_to_deg(sw) / 5.0)), 4)
	for i in range(1, n2 + 1):
		var a2 := -sw * float(i) / float(n2)
		pts.append(ct + L * Vector2(cos(a2), sin(a2)))
	var segs := [
		{"kind": "arc", "r_mm": S * 0.5, "len_mm": PI * S * 0.5, "a0": 0.0, "a1": PI},
		{"kind": "arc", "r_mm": L, "len_mm": L * sw, "a0": 0.0, "a1": -sw},
	]
	var out: Array = []
	var nb := int(s["rotor"]["blades"])
	for k in nb:
		out.append({"pts": _rot(pts, TAU * float(k) / float(nb)), "segs": segs})
	return out


## Savonius buckets: semicircles of chord d with an overlap e = β·d through
## the middle; two buckets give D = 2d − e (Blackwell et al. 1977).
## Three buckets are laid at 120°, sized so their tips reach the rim.
static func _savonius(s: Dictionary) -> Array:
	var r: Dictionary = s["rotor"]
	var R := float(r["d_mm"]) * 0.5
	var beta := float(r["overlap"])
	var nb := int(r["blades"])
	var d := 1.0
	var e := beta * d
	var pts := PackedVector2Array()
	var cx := (d - e) * 0.5
	for i in 25:
		var a := PI * float(i) / 24.0
		# From the outer tip (x = cx + d/2) under the −y side to the inner tip.
		pts.append(Vector2(cx + 0.5 * d * cos(a), -0.5 * d * sin(a)))
	var scale_k := R / maxf(_max_r(pts), 1e-6)
	var p2 := PackedVector2Array()
	for p in pts:
		p2.append(p * scale_k)
	var dd := d * scale_k
	var segs := [{"kind": "arc", "r_mm": dd * 0.5, "len_mm": PI * dd * 0.5, "a0": 0.0, "a1": -PI}]
	var out: Array = []
	for k in nb:
		out.append({"pts": _rot(p2, TAU * float(k) / float(nb)), "segs": segs, "bucket_d_mm": dd})
	return out


## Lenz2 wings: a circular-arc wing of chord c = chord_frac·D and depth
## camber_frac·c, its trailing edge on the rim, the chord set `set_deg`
## inward from the tangent there; a rolled leading edge (drawn by the
## builder) on the inner end.
static func _lenz2(s: Dictionary) -> Array:
	var r: Dictionary = s["rotor"]
	var R := float(r["d_mm"]) * 0.5
	var c := float(r["chord_frac"]) * float(r["d_mm"])
	var h := float(r["camber_frac"]) * c
	var te := Vector2(R, 0.0)
	# The tangent at the TE pointing against the rotation (the wing's chord
	# runs from its leading edge, ahead in the turn, back to the TE).
	var ang := deg_to_rad(90.0 + 35.0 + float(r["set_deg"]))
	var le := te + c * Vector2(cos(ang), sin(ang))
	if le.length() > R * 0.98:
		le = le.normalized() * R * 0.98
	var pts := _arc_through(le, te, h, 16)
	var rr := (c * c / (8.0 * h) + h * 0.5)
	var segs := [{"kind": "arc", "r_mm": rr, "len_mm": _poly_len(pts), "a0": 0.0, "a1": 0.0}]
	var out: Array = []
	var nb := int(r["blades"])
	for k in nb:
		out.append({"pts": _rot(pts, TAU * float(k) / float(nb)), "segs": segs})
	return out


## Points on the circular arc from a to b bulging h to the LEFT of a → b.
static func _arc_through(a: Vector2, b: Vector2, h: float, n: int) -> PackedVector2Array:
	var mid := (a + b) * 0.5
	var ab := b - a
	var c := ab.length()
	var left := Vector2(-ab.y, ab.x).normalized()
	var top := mid + left * h
	var rr := c * c / (8.0 * h) + h * 0.5
	var centre := top - left * rr
	var a0 := (a - centre).angle()
	var a1 := (b - centre).angle()
	var da := wrapf(a1 - a0, -PI, PI)
	var out := PackedVector2Array()
	for i in n + 1:
		out.append(centre + rr * Vector2.from_angle(a0 + da * float(i) / float(n)))
	return out


static func _rot(pts: PackedVector2Array, a: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in pts:
		out.append(p.rotated(a))
	return out


static func _max_r(pts: PackedVector2Array) -> float:
	var m := 0.0
	for p in pts:
		m = maxf(m, p.length())
	return m


static func _poly_len(pts: PackedVector2Array) -> float:
	var l := 0.0
	for i in range(1, pts.size()):
		l += pts[i].distance_to(pts[i - 1])
	return l


static func poly_len(pts: PackedVector2Array) -> float:
	return _poly_len(pts)


## Do any two blade centrelines cross (sampled)? Within `gap` mm counts.
static func blades_clash(blades: Array, gap: float) -> bool:
	for i in blades.size():
		for j in range(i + 1, blades.size()):
			var a: PackedVector2Array = blades[i]["pts"]
			var b: PackedVector2Array = blades[j]["pts"]
			for k in range(1, a.size()):
				for l in range(1, b.size()):
					if _seg_dist(a[k - 1], a[k], b[l - 1], b[l]) < gap:
						return true
	return false


static func _seg_dist(a0: Vector2, a1: Vector2, b0: Vector2, b1: Vector2) -> float:
	if Geometry2D.segment_intersects_segment(a0, a1, b0, b1) != null:
		return 0.0
	var d := INF
	for p in [[a0, b0, b1], [a1, b0, b1], [b0, a0, a1], [b1, a0, a1]]:
		var q := Geometry2D.get_closest_point_to_segment(p[0], p[1], p[2])
		d = minf(d, (p[0] as Vector2).distance_to(q))
	return d
