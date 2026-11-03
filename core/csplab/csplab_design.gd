class_name CspLabDesign
extends RefCounted

## The ONE solved concentrator: geometry, the ray trace at the design
## point, the efficiency chain, concentration, the heat it makes, the
## structure, the checks and the bill of materials. The modal, the builder,
## the placed prop and the graph node all read this, so they cannot
## disagree. Cached by the spec's key.
##
## The design point: a tracked optic at normal incidence; a ground-fixed
## field (tower, linear Fresnel) at an equinox solar noon at its latitude.
## The headline heat is quoted at the spec's design DNI and working
## temperature with clear-sky direct light only (no diffuse).

const CACHE_MAX := 24

static var _cache := {}
static var _order: Array = []


## opts: rays (override), light (skip structure / checks / BOM — the
## optimizer), max_paths (rays kept for the 3D view), no_cache.
static func solve(spec: Dictionary, opts: Dictionary = {}) -> Dictionary:
	var s := CspLabSpec.resolve(spec)
	var rays := int(opts.get("rays", int((s["trace"] as Dictionary)["rays"])))
	var light := bool(opts.get("light", false))
	var max_paths := int(opts.get("max_paths", 0))
	var key := "%s|%d|%s|%d" % [CspLabSpec.key_of(s), rays, "L" if light else "F", max_paths]
	if not bool(opts.get("no_cache", false)) and _cache.has(key):
		return _cache[key] as Dictionary
	var d := _solve(s, rays, light, max_paths)
	if not bool(opts.get("no_cache", false)):
		_cache[key] = d
		_order.append(key)
		while _order.size() > CACHE_MAX:
			_cache.erase(_order.pop_front())
	return d


static func clear_cache() -> void:
	_cache.clear()
	_order.clear()


static func lat_of(spec: Dictionary) -> float:
	return float((spec["site"] as Dictionary).get("lat_deg", 35.0))


## The sun at the design point, in the optic frame.
static func design_sun_local(spec: Dictionary) -> Vector3:
	if CspLabSite.is_field(spec):
		return CspLabSite.field_basis(spec).transposed() * CspLabSite.design_sun(lat_of(spec))
	return Vector3.UP


static func _solve(s: Dictionary, rays: int, light: bool, max_paths: int) -> Dictionary:
	var g := CspLabOptics.geometry(s)
	var d := {"spec": s, "geo": g, "eff_cache": {}, "type": str(s["type"])}
	var sl := design_sun_local(s)
	var tr := CspLabOptics.trace(g, sl, rays, {"seed": int((s["trace"] as Dictionary)["seed"]), "max_paths": max_paths})
	d["trace"] = tr
	d["design_sun_local"] = sl
	var cap := float(tr["captured"])
	var alpha := float(g["alpha"])
	d["eta_capture"] = cap
	d["eta_opt"] = cap * alpha
	d["intercept"] = float(tr["intercept"])
	var site: Dictionary = s["site"]
	var dni := float(site["dni_design"])
	d["dni"] = dni
	var a_ap := float(g["A_ap"])
	d["A_ap"] = a_ap
	d["A_rec"] = float(g["A_rec"])
	d["C_g"] = float(g["C_g"])
	d["C_limit"] = float(g["C_limit"])
	# Concentration: the flux on the receiver over the DNI (×), and the same
	# flux in suns (1 sun = 1 kW/m²) at the design DNI.
	d["C_mean"] = float(tr["mean_suns"])
	d["C_peak"] = float(tr["peak_suns"])
	d["suns_mean"] = float(tr["mean_suns"]) * dni / 1000.0
	d["suns_peak"] = float(tr["peak_suns"]) * dni / 1000.0
	var h := CspLabSite.heat_w(d, dni, 0.0, cap, float(site["ambient_c"]))
	d["q_abs_kw"] = float(h["absorbed_w"]) / 1000.0
	d["q_loss_kw"] = float(h["loss_w"]) / 1000.0
	d["q_net_kw"] = (float(h["absorbed_w"]) - float(h["loss_w"])) / 1000.0
	d["q_useful_kw"] = float(h["useful_w"]) / 1000.0
	d["q_beam_kw"] = dni * a_ap / 1000.0
	d["eta_th"] = float(h["useful_w"]) / maxf(dni * a_ap, 1e-9)
	var ta_k := float(site["ambient_c"]) + 273.15
	var h_eff := float(g["h_conv"]) * (0.05 if bool(g.get("envelope", false)) else 1.0)
	d["stagnation_c"] = HeliostatSource.stagnation_temp_k(float(h["absorbed_w"]), float(g["eps"]),
		float(g["A_loss"]), h_eff, float(g["A_loss"]), ta_k) - 273.15
	d["steam_kg_h"] = CspLabSite.steam_kg_h(d, float(d["q_useful_kw"]))
	d["optic_mass_kg"] = optic_mass(s, g)
	if light:
		return d
	d["structure"] = CspLabStructure.solve(d)
	d["checks"] = _checks(d)
	d["bom"] = _bom(d)
	return d


## The concentrating element's mass (mirror with its backing glass / sheet,
## or the lens body), kg.
static func optic_mass(s: Dictionary, g: Dictionary) -> float:
	var o: Dictionary = s["optic"]
	var t := str(s["type"])
	match t:
		"parabolic_dish":
			# Surface of a paraboloid of rim radius a and depth h:
			# S = π a / (6 h²) · ((a² + 4h²)^1.5 − a³).
			var a := float(g["a"])
			var hh := maxf(float(g["depth"]), 1e-6)
			var sa := PI * a / (6.0 * hh * hh) * (pow(a * a + 4.0 * hh * hh, 1.5) - a * a * a)
			return sa * float(CspLabParts.reflector(str(o["reflector"]))["kg_m2"])
		"parabolic_trough":
			var a2 := float(g["a"])
			var f := float(g["f"])
			var u := a2 / (2.0 * f)
			var arc := 2.0 * (a2 * sqrt(1.0 + u * u) * 0.5 + f * log(u + sqrt(1.0 + u * u)))
			return arc * float(g["length"]) * float(CspLabParts.reflector(str(o["reflector"]))["kg_m2"])
		"linear_fresnel", "tower":
			return a_mirror(g) * float(CspLabParts.reflector(str(o["reflector"]))["kg_m2"])
		"ball_lens":
			var m := float(g["volume"]) * float(CspLabParts.lens_material(str(g["material"]))["density"])
			if str(g["material"]) == "water":
				var r := float(g["R"])
				m += 4.0 * PI * r * r * 0.003 * 2500.0
			return m
		"water_lens":
			return float(g["volume"]) * 1000.0 + float(g["A_ap"]) * 0.6
		_:
			return float(g.get("volume", 0.0)) * float(CspLabParts.lens_material(str(g.get("material", "acrylic")))["density"])


static func a_mirror(g: Dictionary) -> float:
	if str(g["type"]) == "tower":
		return float(g["A_ap"])
	return float(g["A_ap"])


## The optical efficiency at a longitudinal incidence θ (one-axis optics:
## cosine, end loss, the focus smearing), cached like the site's.
static func iam(d: Dictionary, theta_deg: float) -> float:
	var key := "IAM%d" % int(roundf(theta_deg * 10.0))
	var cache: Dictionary = d["eff_cache"]
	if cache.has(key):
		return float(cache[key])
	var tr := deg_to_rad(theta_deg)
	var q := Vector3(0, cos(tr), sin(tr))
	var n := mini(int((d["spec"]["trace"] as Dictionary)["rays"]), 1500)
	var e := float(CspLabOptics.trace(d["geo"] as Dictionary, q, n, {"seed": 5})["captured"])
	cache[key] = e
	return e


## A CPC's optical efficiency with the sun tilted `deg` ACROSS the trough
## (in its transverse plane): flat inside the acceptance angle, falling away
## beyond it. Cached like the IAM.
static func across(d: Dictionary, deg: float) -> float:
	var key := "X%d" % int(roundf(deg * 10.0))
	var cache: Dictionary = d["eff_cache"]
	if cache.has(key):
		return float(cache[key])
	var tr := deg_to_rad(deg)
	var q := Vector3(sin(tr), cos(tr), 0.0)
	var n := mini(int((d["spec"]["trace"] as Dictionary)["rays"]), 1500)
	var e := float(CspLabOptics.trace(d["geo"] as Dictionary, q, n, {"seed": 5})["captured"])
	cache[key] = e
	return e


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

static func _checks(d: Dictionary) -> Array:
	var s: Dictionary = d["spec"]
	var g: Dictionary = d["geo"]
	var t := str(s["type"])
	var tr: Dictionary = d["trace"]
	var losses: Dictionary = tr["losses"]
	var mode := str((s["tracking"] as Dictionary)["mode"])
	var focus := str(g["focus"])
	var site: Dictionary = s["site"]
	var out: Array = []
	if bool(g.get("too_fast", false)):
		var nv := CspLabParts.n_of(str(g["material"]), 0)
		out.append({"level": "error", "text": "The focal length is too short for this diameter: its surface would be more than a hemisphere. The shortest is about %.2f m." % (float(g["a"]) * 1.02 / (nv - 1.0)),
			"why": "A plano-convex lens has f = R / (n − 1); the surface radius R can't be smaller than the lens's radius."})
	if focus == "point" and mode != "two_axis" and t != "ball_lens" and t != "tower":
		out.append({"level": "warn", "text": "A point focus on %s spills most of the day: the sun leaves the focus as it moves. Use two-axis tracking." % str(CspLabSpec.TRACKING_MODES[mode]).to_lower(),
			"why": "A point-focus optic only focuses light that arrives along its axis."})
	if focus == "line" and mode == "two_axis":
		out.append({"level": "info", "text": "A line focus on two axes works perfectly but costs a second drive; one horizontal axis is the usual choice.",
			"why": "Along the line the sun's angle only costs a cosine and some end loss."})
	if bool(g.get("cpc", false)):
		var ta_deg := rad_to_deg(float(g["theta_a"]))
		out.append({"level": "info", "text": "Compound parabolic: every ray within ±%.1f° across the trough reaches the absorber. Ideal concentration %.2f× (1 / sin θa, round the mirror's circle); built %.2f× on the absorber with %.0f %% cut off — %.2f m wide, %.2f m tall, %.2f m of mirror per metre of trough." % [
			ta_deg, float(g["C_ideal"]), float(g["C_g"]), float((s["optic"] as Dictionary)["truncate"]) * 100.0,
			float(g["a"]) * 2.0, float((g["cpc_prof"] as Dictionary)["height"]), float((g["cpc_prof"] as Dictionary)["arc_len"])],
			"why": "Winston's edge-ray principle: the wall sends the extreme rays (±θa) to the edge of the absorber, so everything between lands on it."})
		if mode == "fixed" and ta_deg < 23.45:
			out.append({"level": "info", "text": "Fixed, it keeps the sun inside ±%.1f° only part of the year: the sun's angle across an east–west trough swings ±23.4° with the seasons. Re-tilt it a few times a year, or widen the acceptance past 47°." % ta_deg,
				"why": "At the equinox a trough tilted to the latitude sees the sun at 0° across it all day; at the solstices it is 23.4° off."})
		elif mode != "fixed" and ta_deg >= 12.0:
			out.append({"level": "info", "text": "With ±%.1f° of acceptance it needs no daily tracking: try Tracking → Fixed (tilted to the equator, axis east–west)." % ta_deg,
				"why": "The sun moves along an east–west trough during the day, which a trough accepts; only its seasonal angle across it matters."})
		if str(g["profile"]) == "cpc_tube" and float(g.get("r_mirror", 0.0)) > float(g["rec_r"]) * 1.15:
			out.append({"level": "info", "text": "The %.0f mm gap under the pipe lets light past it: keep it small (a glass jacket needs its own radius)." % ((float(g["r_mirror"]) - float(g["rec_r"])) * 1000.0),
				"why": "The gap loss grows with gap ÷ radius (Rabl 1977)."})
	if t == "parabolic_trough" and not bool(g.get("cpc", false)):
		var rim := float(g["rim_deg"])
		if rim < 60.0 or rim > 120.0:
			out.append({"level": "info", "text": "Rim angle %.0f°: troughs are usually 80–100° (a tube receiver sees the widest mirror for the smallest spot)." % rim,
				"why": "Rabl 1985: for a tube the minimum receiver size is at ψ = 90°."})
	if t == "parabolic_dish":
		var fd := float(g["f"]) / (float(g["a"]) * 2.0)
		if fd < 0.3:
			out.append({"level": "info", "text": "f/D %.2f is a deep dish: a cavity sees rays from wide angles, but the mirror is harder to make." % fd, "why": ""})
		elif fd > 0.8:
			out.append({"level": "info", "text": "f/D %.2f is a shallow dish: the receiver stands far out on long struts." % fd, "why": ""})
	var inter := float(d["intercept"])
	if inter < 0.85 and float(tr["captured"]) > 0.0:
		out.append({"level": "warn", "text": "Only %.0f %% of the light leaving the optic lands on the receiver. Make the receiver bigger (Optimize → receiver size), refocus, or reduce the surface error." % (inter * 100.0),
			"why": "The focal spot is the sun's image blurred by every error; a receiver smaller than it spills."})
	if float(losses["shading"]) > 0.08:
		out.append({"level": "warn", "text": "%.0f %% of the aperture is shaded (by the receiver, its supports or the neighbours)." % (float(losses["shading"]) * 100.0),
			"why": "Space the rows / heliostats wider, or use a smaller receiver housing."})
	if float(losses["blocking"]) > 0.05:
		out.append({"level": "warn", "text": "%.0f %% of the reflected light is blocked by the neighbouring mirrors." % (float(losses["blocking"]) * 100.0),
			"why": "Wider spacing or a taller receiver lets each mirror see past the next."})
	if float(losses["cosine"]) > 0.25:
		out.append({"level": "info", "text": "The cosine loss is %.0f %% at the design sun." % (float(losses["cosine"]) * 100.0),
			"why": "Mirrors that bisect the sun and the receiver face the sun at an angle; poleward of the tower the angle is smallest."})
	if float(losses["absorb"]) > 0.08:
		out.append({"level": "info", "text": "%.0f %% of the sun is absorbed inside the lens (the infrared, mostly)." % (float(losses["absorb"]) * 100.0),
			"why": "Water and acrylic drink the near infrared; a thinner lens or glass absorbs less."})
	var stag := float(d["stagnation_c"])
	var op := float(site["op_temp_c"])
	if stag < op:
		out.append({"level": "error", "text": "It can't reach the working temperature: even with nothing drawn the receiver stalls at %.0f °C (working %.0f °C)." % [stag, op],
			"why": "Heat losses at the working temperature exceed what lands. Concentrate more, use a selective coating, or work cooler."})
	elif float(d["eta_th"]) < 0.25:
		out.append({"level": "warn", "text": "Only %.0f %% of the direct sun becomes useful heat at %.0f °C." % [float(d["eta_th"]) * 100.0, op],
			"why": "The receiver loses most of what lands at this temperature."})
	if t == "ball_lens":
		out.append({"level": "info", "text": "A sphere's rim rays focus much shorter than its paraxial focus (spherical aberration): try Optimize → defocus.",
			"why": "Every ray crosses a sphere at a different angle; only the central ones meet at the textbook focus."})
	if t == "water_lens":
		out.append({"level": "info", "text": "It holds %.0f kg of water: the frame and membrane carry it, and it drinks %.0f %% of the sun's infrared." % [float(g["volume"]) * 1000.0, float(losses["absorb"]) * 100.0],
			"why": ""})
	if t == "tower":
		if bool(g["surround"]) and str(g["rec_kind"]) != "tube":
			out.append({"level": "warn", "text": "A flat receiver can't face a field all round the tower; use the external cylinder.", "why": ""})
		if int(g["count"]) < int((s["optic"] as Dictionary)["heliostats"]):
			out.append({"level": "info", "text": "Only %d heliostats fitted the layout." % int(g["count"]), "why": ""})
	var cl := float(d["C_limit"])
	if float(d["C_mean"]) > 0.0:
		var frac := float(d["C_mean"]) / cl
		if frac > 0.5:
			out.append({"level": "info", "text": "Mean concentration %.0f× is %.0f %% of the thermodynamic limit (%.0f×) for this sun." % [float(d["C_mean"]), frac * 100.0, cl],
				"why": "Étendue: no optic can concentrate a source of half-angle θs beyond 1/sin θs (line) or 1/sin²θs (point)."})
	var stc: Dictionary = d["structure"]
	for c in (stc.get("checks", []) as Array):
		out.append(c)
	var order := {"error": 0, "warn": 1, "info": 2}
	out.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return int(order.get(str(x["level"]), 3)) < int(order.get(str(y["level"]), 3)))
	return out


static func check_counts(d: Dictionary) -> Dictionary:
	var e := 0
	var w := 0
	for c in (d.get("checks", []) as Array):
		var lv := str((c as Dictionary)["level"])
		if lv == "error":
			e += 1
		elif lv == "warn":
			w += 1
	return {"error": e, "warn": w}


# ---------------------------------------------------------------------------
# Bill of materials
# ---------------------------------------------------------------------------

static func _bom(d: Dictionary) -> Array:
	var s: Dictionary = d["spec"]
	var g: Dictionary = d["geo"]
	var o: Dictionary = s["optic"]
	var t := str(s["type"])
	var rows: Array = []
	match t:
		"parabolic_dish", "parabolic_trough", "linear_fresnel", "tower":
			var refl := CspLabParts.reflector(str(o["reflector"]))
			var area := float(d["optic_mass_kg"]) / maxf(float(refl["kg_m2"]), 1e-6)
			rows.append({"item": str(refl["label"]), "qty": area, "unit": "m²", "kg": float(d["optic_mass_kg"])})
			if t == "tower":
				rows.append({"item": "Heliostats %.1f × %.1f m" % [float(g["hw"]), float(g["hh"])], "qty": float(g["count"]), "unit": "", "kg": 0.0})
			if t == "linear_fresnel":
				rows.append({"item": "Mirror rows %.2f m wide" % float(g["w"]), "qty": float(g["rows"]), "unit": "", "kg": 0.0})
		"lens", "fresnel_lens", "ball_lens":
			var lm := CspLabParts.lens_material(str(g["material"]))
			rows.append({"item": "%s lens" % str(lm["label"]), "qty": float(g.get("volume", 0.0)) * 1000.0, "unit": "L", "kg": float(d["optic_mass_kg"])})
		"water_lens":
			rows.append({"item": "Water", "qty": float(g["volume"]) * 1000.0, "unit": "L", "kg": float(g["volume"]) * 1000.0})
			rows.append({"item": "Clear film (cover + membrane)", "qty": float(g["A_ap"]) * 2.4, "unit": "m²", "kg": float(g["A_ap"]) * 0.6})
	var rc: Dictionary = s["receiver"]
	rows.append({"item": "Receiver (%s, %s)" % [str(CspLabSpec.RECEIVER_KINDS.get(str(g["rec_kind"]), "")).to_lower(),
		str(CspLabParts.coating(str(rc["coating"]))["label"]).to_lower()], "qty": float(g["A_rec"]), "unit": "m²",
		"kg": 3.0 + float(g["A_rec"]) * 20.0})
	var stc: Dictionary = d["structure"]
	var mat := CspLabParts.struct_material(str((s["structure"] as Dictionary)["material"]))
	var by_label := {}
	for mv in (stc["members"] as Array):
		var m: Dictionary = mv
		if bool(m.get("box", false)):
			continue
		var lab := str(m.get("label", "Member"))
		var tp := CspLabStructure.tube_props(float(m["d"]), float(m["t"]))
		var length := (m["a"] as Vector3).distance_to(m["b"] as Vector3)
		var e: Dictionary = by_label.get(lab, {"len": 0.0, "kg": 0.0, "d": float(m["d"]), "n": 0}) as Dictionary
		e["len"] = float(e["len"]) + length
		e["kg"] = float(e["kg"]) + length * float(tp["A"]) * float(mat["density"])
		e["n"] = int(e["n"]) + 1
		by_label[lab] = e
	for lab in by_label:
		var e2: Dictionary = by_label[lab]
		rows.append({"item": "%s — %s Ø%.0f mm ×%d" % [str(lab), str(mat["label"]).to_lower(), float(e2["d"]) * 1000.0, int(e2["n"])],
			"qty": float(e2["len"]), "unit": "m", "kg": float(e2["kg"])})
	var n_conc := 0
	var n_cw := 0
	for mv2 in (stc["members"] as Array):
		var mk := str((mv2 as Dictionary).get("mat", ""))
		if mk == "concrete":
			n_conc += 1
		elif mk == "counterweight":
			n_cw += 1
	if n_conc > 0:
		rows.append({"item": "Concrete footings ×%d" % n_conc, "qty": float(stc.get("concrete_m3", 0.0)), "unit": "m³",
			"kg": float(stc.get("concrete_kg", 0.0)), "foundation": true})
	if n_cw > 0:
		rows.append({"item": "Counterweights (cast iron) ×%d" % n_cw, "qty": float(n_cw), "unit": "",
			"kg": float(stc.get("counterweight_kg", 0.0))})
	var drv: Dictionary = stc.get("drive", {}) as Dictionary
	if not drv.is_empty():
		var n_drv := 1
		var mode := str((s["tracking"] as Dictionary)["mode"])
		if t == "tower":
			n_drv = int(g["count"]) * 2
		elif t == "linear_fresnel":
			n_drv = int(g["rows"])
		elif mode == "two_axis":
			n_drv = 2
		elif mode == "fixed":
			n_drv = 0
		if n_drv > 0:
			rows.append({"item": str(drv["label"]), "qty": float(n_drv), "unit": "", "kg": float(drv["kg"]) * n_drv})
	return rows


## What it weighs to ship and lift: everything but the poured footings.
static func bom_mass(d: Dictionary) -> float:
	var m := 0.0
	for r in (d.get("bom", []) as Array):
		if bool((r as Dictionary).get("foundation", false)):
			continue
		m += float((r as Dictionary)["kg"])
	return m


## Everything worth saying about the design, as plain text.
static func summary(d: Dictionary) -> String:
	var s: Dictionary = d["spec"]
	var g: Dictionary = d["geo"]
	var lines := PackedStringArray()
	lines.append("%s — %s" % [str(s["name"]), str(CspLabSpec.TYPE_LABELS[str(s["type"])])])
	lines.append("Aperture %.2f m², receiver %.4f m², geometric concentration %.0f×" % [float(d["A_ap"]), float(d["A_rec"]), float(d["C_g"])])
	lines.append("Optical efficiency %.1f %% (captured %.1f %%, intercept %.1f %%)" % [float(d["eta_opt"]) * 100.0, float(d["eta_capture"]) * 100.0, float(d["intercept"]) * 100.0])
	lines.append("Mean flux %.0f suns (%.0f× DNI), peak %.0f suns, limit %.0f×" % [float(d["suns_mean"]), float(d["C_mean"]), float(d["suns_peak"]), float(d["C_limit"])])
	lines.append("At %.0f W/m² DNI: %.2f kW on the aperture, %.2f kW absorbed, %.2f kW useful at %.0f °C (%.0f %%), stagnation %.0f °C" % [
		float(d["dni"]), float(d["q_beam_kw"]), float(d["q_abs_kw"]), float(d["q_useful_kw"]), float((s["site"] as Dictionary)["op_temp_c"]),
		float(d["eta_th"]) * 100.0, float(d["stagnation_c"])])
	if float(d["steam_kg_h"]) > 0.0:
		lines.append("Boils %.1f kg/h of water" % float(d["steam_kg_h"]))
	var losses: Dictionary = (d["trace"] as Dictionary)["losses"]
	for k in losses:
		if float(losses[k]) > 0.0005:
			lines.append("  loss: %s %.1f %%" % [str(CspLabOptics.LOSS_LABELS.get(k, k)), float(losses[k]) * 100.0])
	var stc: Dictionary = d.get("structure", {}) as Dictionary
	if not stc.is_empty():
		lines.append("Structure %.0f kg, optic %.0f kg; drive: %s" % [float(stc["mass_kg"]), float(d["optic_mass_kg"]),
			str((stc.get("drive", {}) as Dictionary).get("label", "—"))])
	for c in (d.get("checks", []) as Array):
		lines.append("[%s] %s" % [str((c as Dictionary)["level"]), str((c as Dictionary)["text"])])
	return "\n".join(lines)


## The graph node's specs for a design (the placed concentrator's numbers).
static func graph_patch(d: Dictionary) -> Dictionary:
	return {
		"csplab_spec": CspLabSpec.to_json_safe(d["spec"] as Dictionary),
		"aperture_m2": float(d["A_ap"]),
		"concentration_x": float(d["C_mean"]),
		"rated_thermal_kw": float(d["q_useful_kw"]),
		"optical_efficiency": float(d["eta_opt"]),
		"op_temp_c": float((d["spec"]["site"] as Dictionary)["op_temp_c"]),
	}
