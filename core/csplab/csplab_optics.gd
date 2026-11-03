class_name CspLabOptics
extends RefCounted

## The concentrator designer's ray tracer: a Monte Carlo trace of sunlight
## through one design, the same code for the efficiency numbers, the 3D rays
## and the 2D section.
##
## A ray is born on the optic (sampled uniformly over the aperture's
## projection — or over a mirror strip / heliostat face for the ground-fixed
## fields) carrying a weight = the cosine of its incidence, so the weights sum
## to the beam power the aperture intercepts per unit DNI. It carries one
## spectral band (CspLabParts.BANDS), so dispersion and absorption are per
## band. It is drawn from the sun's disc (a pillbox of `sun_half` rad,
## Rabl 1985 §2) plus the tracking error, then:
##   - shaded: blocked on its way in (the receiver, a neighbouring mirror,
##     the tower);
##   - reflected (mirror, specular reflectance ρ, the surface normal tilted by
##     a Gaussian slope error) or refracted (Snell, unpolarised Fresnel
##     reflection lost at every interface, Beer–Lambert absorption inside);
##   - blocked on its way out (a neighbouring mirror), attenuated by air
##     (tower: Schmitz et al. 2006), and finally
##   - captured by the receiver, or spilled past it, or off the END of a line
##     receiver (the end loss appears by itself when the sun is off-axis).
## Every weight it loses is booked to that cause, so the losses and the
## captured fraction add up to exactly 1 (the reference is DNI × aperture
## area, the aperture area being the mirror / lens area normal to its axis).
##
## Frames: see CspLabSpec. Everything here is in the optic frame; the sun
## vector `s` points TOWARD the sun.

const AIR_N := 1.0
## Clear-day atmospheric attenuation between heliostat and receiver
## (Schmitz, Schwarzbözl, Buck & Pitz-Paal 2006, after Vittitoe & Biggs
## 1978): η = 0.99321 − 0.0001176·d + 1.97e-8·d², d in m, d ≤ 1000 m.
const ATT_A := 0.99321
const ATT_B := 0.0001176
const ATT_C := 1.97e-8
const LOSS_KEYS := ["shading", "reflect", "fresnel", "absorb", "grooves", "glazing", "blocking",
	"attenuation", "spill", "end"]
const LOSS_LABELS := {
	"cosine": "Cosine (sun off the aperture's axis)",
	"shading": "Shading (receiver, neighbours, tower)",
	"reflect": "Mirror reflectance",
	"fresnel": "Surface reflections (Fresnel)",
	"absorb": "Absorbed in the lens / water",
	"grooves": "Groove tips and draft faces",
	"glazing": "Glazing (envelope, films)",
	"blocking": "Blocking (reflected into a neighbour)",
	"attenuation": "Air between mirror and receiver",
	"spill": "Spilled past the receiver",
	"end": "Off the end of the receiver",
}

static var _last_t := 1.0


class Acc:
	var n := 0
	var cosine := 0.0
	var loss := {}
	var captured := 0.0
	var flux := PackedFloat64Array()
	var nu := 12
	var nv := 12
	var u0 := -1.0
	var u1 := 1.0
	var v0 := -1.0
	var v1 := 1.0
	var band_cap := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
	var paths: Array = []
	var max_paths := 0
	var every := 1
	var record := false
	var ideal := false
	var cur := PackedVector3Array()
	var cur_band := 0

	func _init() -> void:
		for k in CspLabOptics.LOSS_KEYS:
			loss[k] = 0.0
		flux.resize(nu * nv)

	func set_bins(a0: float, a1: float, b0: float, b1: float, cu: int, cv: int) -> void:
		u0 = a0
		u1 = a1
		v0 = b0
		v1 = b1
		nu = cu
		nv = cv
		flux.resize(nu * nv)
		flux.fill(0.0)

	func lose(key: String, w: float) -> void:
		loss[key] = float(loss[key]) + w

	func bin(u: float, v: float, w: float) -> void:
		var i := clampi(int((u - u0) / maxf(u1 - u0, 1e-9) * nu), 0, nu - 1)
		var j := clampi(int((v - v0) / maxf(v1 - v0, 1e-9) * nv), 0, nv - 1)
		flux[j * nu + i] += w

	func pt(p: Vector3) -> void:
		if record:
			cur.append(p)

	func finish(fate: String) -> void:
		if record and cur.size() >= 2:
			paths.append({"pts": cur, "fate": fate, "band": cur_band})
		cur = PackedVector3Array()
		record = false


# ---------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------

## Everything the tracer and the builder need, derived once from a resolved
## spec. `lat_deg` places a tower's field poleward of it.
static func geometry(spec: Dictionary) -> Dictionary:
	var t := str(spec["type"])
	var o: Dictionary = spec["optic"]
	var rc: Dictionary = spec["receiver"]
	var tc: Dictionary = spec["trace"]
	var focus := str(CspLabSpec.FOCUS[t])
	var g := {"type": t, "focus": focus, "optic_kind": str(CspLabSpec.OPTIC[t])}
	g["slope_err"] = float(tc["slope_err_mrad"]) * 0.001
	g["sun_half"] = float(tc["sun_half_mrad"]) * 0.001
	g["track_err"] = float((spec["tracking"] as Dictionary)["error_mrad"]) * 0.001
	var kind := str(rc["kind"])
	if kind == "tube" and focus == "point" and t != "tower":
		kind = "flat"
	g["rec_kind"] = kind
	var size := float(rc["size_m"])
	var off := float(rc["offset_m"])
	var coat := CspLabParts.coating(str(rc["coating"]))
	var alpha := float(coat["alpha"])
	var eps := float(coat["eps"])
	if kind == "cavity":
		# A cavity behind an aperture traps what its walls reflect: apparent
		# absorptance / emittance with an aperture-to-wall area ratio of 0.2
		# (Duffie & Beckman 2013 §7.10, the uniform-cavity estimate).
		var ar := 0.2
		alpha = alpha / (alpha + (1.0 - alpha) * ar)
		eps = eps / (eps + (1.0 - eps) * ar)
	g["alpha"] = alpha
	g["eps"] = eps
	g["h_conv"] = float(rc["h_conv"])
	g["rho"] = float(CspLabParts.reflector(str(o["reflector"]))["rho"]) if g["optic_kind"] == "mirror" else 1.0
	g["size"] = size
	var length := float(o["length_m"])
	g["length"] = length
	match t:
		"parabolic_dish":
			var a := float(o["aperture_m"]) * 0.5
			var f := float(o["focal_m"])
			g["a"] = a
			g["f"] = f
			g["rec_y"] = f - off
			g["rec_r"] = size * 0.5
			g["house_r"] = size * 0.5 * (1.6 if kind == "cavity" else 1.15) + 0.01
			g["A_ap"] = PI * a * a
			g["depth"] = a * a / (4.0 * f)
			g["rim_deg"] = rad_to_deg(2.0 * atan(a / (2.0 * f)))
			g["A_rec"] = PI * g["rec_r"] * g["rec_r"]
			g["A_loss"] = g["A_rec"]
			g["pivot"] = Vector3(0, g["depth"] * 0.6, 0)
			g["bins"] = [-g["rec_r"], g["rec_r"], -g["rec_r"], g["rec_r"], 13, 13]
			g["l_in"] = maxf(f * 1.4, 0.8)
		"parabolic_trough":
			var a := float(o["aperture_m"]) * 0.5
			var f := float(o["focal_m"])
			g["a"] = a
			g["f"] = f
			g["rec_y"] = f - off
			g["rec_r"] = size * 0.5
			var env := bool(rc["envelope"]) and kind == "tube"
			g["envelope"] = env
			g["env_r"] = size * 0.5 * (1.8 if env else 1.0)
			g["env_tau"] = 0.96 if env else 1.0
			g["A_ap"] = 2.0 * a * length
			g["depth"] = a * a / (4.0 * f)
			g["rim_deg"] = rad_to_deg(2.0 * atan(a / (2.0 * f)))
			if kind == "tube":
				g["A_rec"] = PI * size * length
			else:
				g["A_rec"] = size * length
			g["A_loss"] = g["A_rec"]
			if kind == "tube":
				g["bins"] = [-PI, PI, -length * 0.5, length * 0.5, 16, 10]
			else:
				g["bins"] = [-size * 0.5, size * 0.5, -length * 0.5, length * 0.5, 12, 10]
			g["pivot"] = Vector3(0, g["depth"] * 0.5, 0)
			g["l_in"] = maxf(f * 1.6, 0.8)
			g["rib_pts"] = [Vector2(-a, a * a / (4.0 * f)), Vector2(-a * 0.5, a * a / (16.0 * f)),
				Vector2(a * 0.5, a * a / (16.0 * f)), Vector2(a, a * a / (4.0 * f))]
			g["profile"] = "parabola"
			var prof := CspLabSpec.profile_of(spec)
			if prof != "parabola":
				_cpc_geometry(g, spec, prof)
		"linear_fresnel":
			var rows := int(o["rows"])
			var w := float(o["mirror_w_m"])
			var gap := float(o["gap_m"])
			var total := rows * w + (rows - 1) * gap
			var xs := PackedFloat64Array()
			for i in rows:
				xs.append(-total * 0.5 + w * 0.5 + i * (w + gap))
			g["xs"] = xs
			g["rows"] = rows
			g["w"] = w
			g["gap"] = gap
			g["total"] = total
			g["H"] = float(o["recv_height_m"])
			g["rec_y"] = g["H"]
			g["rec_r"] = size * 0.5
			g["curved"] = bool(o["curved"])
			var env2 := bool(rc["envelope"]) and kind == "tube"
			g["envelope"] = env2
			g["env_tau"] = 0.96 if env2 else 1.0
			g["A_ap"] = rows * w * length
			if kind == "tube":
				g["A_rec"] = PI * size * length
				g["bins"] = [-PI, PI, -length * 0.5, length * 0.5, 16, 10]
			else:
				g["A_rec"] = size * length
				g["bins"] = [-size * 0.5, size * 0.5, -length * 0.5, length * 0.5, 12, 10]
			g["A_loss"] = g["A_rec"]
			g["l_in"] = maxf(g["H"] * 0.6, 1.0)
		"tower":
			_tower_field(g, spec)
		"lens":
			var a := float(o["aperture_m"]) * 0.5
			var mat := str(o["material"])
			var nv := CspLabParts.n_of(mat, 0)
			var f := float(o["focal_m"])
			var r_want := f * (nv - 1.0)
			var r := maxf(r_want, a * 1.02)
			g["too_fast"] = r_want < a * 1.02
			var sag := r - sqrt(r * r - a * a)
			var te := float(o["thickness_mm"]) * 0.001
			var tcen := te + sag
			var f_eff := r / (nv - 1.0)
			var bfl := f_eff - tcen / nv
			g["a"] = a
			g["R"] = r
			g["sag"] = sag
			g["tc"] = tcen
			g["te"] = te
			g["material"] = mat
			g["f"] = f_eff
			g["bfl"] = bfl
			g["y_flat"] = bfl
			g["yc"] = bfl + tcen - r
			g["rec_y"] = off
			g["rec_r"] = size * 0.5
			g["A_ap"] = PI * a * a
			g["A_rec"] = PI * g["rec_r"] * g["rec_r"]
			g["A_loss"] = g["A_rec"]
			g["volume"] = PI * a * a * te + PI * sag * sag * (3.0 * r - sag) / 3.0
			g["pivot"] = Vector3(0, bfl + tcen * 0.5, 0)
			g["bins"] = [-g["rec_r"], g["rec_r"], -g["rec_r"], g["rec_r"], 13, 13]
			g["l_in"] = maxf(bfl * 0.5, 0.3)
		"ball_lens":
			var r := float(o["aperture_m"]) * 0.5
			var mat := str(o["material"])
			var nv := CspLabParts.n_of(mat, 0)
			var f_c := nv * r / (2.0 * (nv - 1.0))
			var bfl := f_c - r
			g["R"] = r
			g["a"] = r
			g["material"] = mat
			g["f"] = f_c
			g["bfl"] = bfl
			g["yc"] = bfl + r
			g["rec_y"] = off
			g["rec_r"] = size * 0.5
			g["A_ap"] = PI * r * r
			g["A_rec"] = PI * g["rec_r"] * g["rec_r"]
			g["A_loss"] = g["A_rec"]
			g["volume"] = 4.0 / 3.0 * PI * r * r * r
			g["pivot"] = Vector3(0, g["yc"], 0)
			g["bins"] = [-g["rec_r"], g["rec_r"], -g["rec_r"], g["rec_r"], 13, 13]
			g["l_in"] = maxf(r * 1.5, 0.3)
		"water_lens":
			var a := float(o["aperture_m"]) * 0.5
			var nv := CspLabParts.n_of("water", 0)
			var f := float(o["focal_m"])
			var r_want := f * (nv - 1.0)
			var r := maxf(r_want, a * 1.02)
			g["too_fast"] = r_want < a * 1.02
			var sag := r - sqrt(r * r - a * a)
			var base := float(o["base_mm"]) * 0.001
			var f_eff := r / (nv - 1.0)
			g["a"] = a
			g["R"] = r
			g["sag"] = sag
			g["base"] = base
			g["material"] = "water"
			g["f"] = f_eff
			g["bfl"] = f_eff
			g["y_bot"] = f_eff
			g["yc"] = f_eff + r
			g["y_top"] = f_eff + sag + base
			g["film_tau"] = float(o["film_tau"])
			g["rec_y"] = off
			g["rec_r"] = size * 0.5
			g["A_ap"] = PI * a * a
			g["A_rec"] = PI * g["rec_r"] * g["rec_r"]
			g["A_loss"] = g["A_rec"]
			g["volume"] = PI * sag * sag * (3.0 * r - sag) / 3.0 + PI * a * a * base
			g["pivot"] = Vector3(0, f_eff + sag * 0.5, 0)
			g["bins"] = [-g["rec_r"], g["rec_r"], -g["rec_r"], g["rec_r"], 13, 13]
			g["l_in"] = maxf(f_eff * 0.35, 0.4)
		"fresnel_lens":
			var side := float(o["aperture_m"])
			var a := side * 0.5
			var mat := str(o["material"])
			var f := float(o["focal_m"])
			var th := float(o["thickness_mm"]) * 0.001
			g["a"] = a
			g["square"] = bool(o["square"])
			g["material"] = mat
			g["n_design"] = CspLabParts.n_of(mat, 0)
			g["f"] = f
			g["bfl"] = f
			g["th"] = th
			g["y_groove"] = f
			g["y_top"] = f + th
			g["pitch"] = float(o["pitch_mm"]) * 0.001
			g["tip"] = float(o["tip_um"]) * 1e-6
			g["rec_y"] = off
			g["rec_r"] = size * 0.5
			g["A_ap"] = side * side if g["square"] else PI * a * a
			g["A_rec"] = PI * g["rec_r"] * g["rec_r"]
			g["A_loss"] = g["A_rec"]
			g["volume"] = g["A_ap"] * th
			g["pivot"] = Vector3(0, f * 0.8, 0)
			g["bins"] = [-g["rec_r"], g["rec_r"], -g["rec_r"], g["rec_r"], 13, 13]
			g["l_in"] = maxf(f * 0.4, 0.3)
	g["C_g"] = float(g["A_ap"]) / maxf(float(g["A_rec"]), 1e-9)
	var sh := maxf(float(g["sun_half"]), 1e-4)
	# The thermodynamic limit of concentration for a source of half-angle θs:
	# 1/sin θs (2D, line focus) and 1/sin²θs (3D, point focus) — Rabl 1976,
	# Winston, Miñano & Benítez 2005 ch. 2.
	g["C_limit"] = 1.0 / sin(sh) if focus == "line" else 1.0 / (sin(sh) * sin(sh))
	return g


## A compound parabolic trough (CspLabCpc): its wall replaces the parabola.
## The tube CPC is drawn round the tube plus the gap (the mirror's circle),
## its cusp at y = 0 and the tube centred above it; the flat CPC's absorber
## lies at y = 0 facing up.
static func _cpc_geometry(g: Dictionary, spec: Dictionary, prof: String) -> void:
	var o: Dictionary = spec["optic"]
	var rc: Dictionary = spec["receiver"]
	var ta := deg_to_rad(float(o["accept_deg"]) * 0.5)
	var trunc := float(o["truncate"])
	var length := float(g["length"])
	var size := float(g["size"])
	var p: Dictionary
	g["profile"] = prof
	g["cpc"] = true
	g["theta_a"] = ta
	if prof == "cpc_tube":
		var r_real := size * 0.5
		var r_m := r_real + float(rc.get("gap_mm", 0.0)) * 0.001
		p = CspLabCpc.tube_profile(r_m, ta, trunc)
		g["rec_y"] = r_m
		g["rec_r"] = r_real
		g["r_mirror"] = r_m
		g["envelope"] = false
		g["env_tau"] = 1.0
		g["A_rec"] = PI * size * length
		g["bins"] = [-PI, PI, -length * 0.5, length * 0.5, 16, 10]
	else:
		p = CspLabCpc.flat_profile(size * 0.5, ta, trunc)
		g["rec_y"] = 0.0
		g["rec_r"] = size * 0.5
		g["A_rec"] = size * length
		g["bins"] = [-size * 0.5, size * 0.5, -length * 0.5, length * 0.5, 12, 10]
	g["A_loss"] = g["A_rec"]
	g["cpc_prof"] = p
	g["cpc_segs"] = CspLabCpc.segments(p)
	var a := float(p["aperture_half"])
	g["a"] = a
	g["y_top"] = float(p["top_y"])
	g["depth"] = float(p["top_y"])
	g["A_ap"] = 2.0 * a * length
	g["C_ideal"] = 1.0 / sin(ta)
	g["rim_deg"] = 0.0
	g["f"] = maxf(float(p["height"]), 0.05)
	g["pivot"] = Vector3(0, float(p["top_y"]) * 0.35, 0)
	g["l_in"] = maxf(float(p["height"]) * 1.2, 0.5)
	var right: PackedVector2Array = p["right"]
	var mid := right[right.size() / 2]
	var top := right[right.size() - 1]
	g["rib_pts"] = [Vector2(-top.x, top.y), Vector2(-mid.x, mid.y), Vector2(mid.x, mid.y), top]


## A radial-staggered heliostat field (rows of heliostats round the tower,
## poleward of it or all round), the tower and its receiver.
static func _tower_field(g: Dictionary, spec: Dictionary) -> void:
	var o: Dictionary = spec["optic"]
	var rc: Dictionary = spec["receiver"]
	var lat := float((spec["site"] as Dictionary).get("lat_deg", 35.0))
	var n := int(o["heliostats"])
	var w := float(o["helio_w_m"])
	var h := float(o["helio_h_m"])
	var H := float(o["tower_h_m"])
	var ped := float(o["helio_ped_m"])
	var diag := sqrt(w * w + h * h)
	var surround := str(o["field"]) == "surround"
	# Poleward: north (-Z) in the northern hemisphere, south (+Z) below it.
	var pole_az := 0.0 if lat >= 0.0 else PI
	var span := TAU if surround else deg_to_rad(130.0)
	var r := maxf(float(o["first_row_m"]), diag)
	var dr := float(o["row_spacing"]) * h
	var cs: Array = []
	var row := 0
	while cs.size() < n and row < 200:
		var arc := r * span
		var count := maxi(int(arc / (diag * 1.12)), 1)
		var step := span / float(count)
		var start := pole_az - span * 0.5 + step * (0.5 if row % 2 == 0 else 1.0)
		if surround:
			start = pole_az + (step * 0.5 if row % 2 == 1 else 0.0)
			count = maxi(int(TAU * r / (diag * 1.12)), 1)
			step = TAU / float(count)
		for k in count:
			if cs.size() >= n:
				break
			var az := start + k * step
			if not surround and k * step >= span - step * 0.25 and row % 2 == 1:
				break
			cs.append(Vector3(sin(az) * r, ped, -cos(az) * r))
		r += dr
		row += 1
	var centres := PackedVector3Array()
	for c in cs:
		centres.append(c as Vector3)
	# Neighbours for shading / blocking (within three diagonals).
	var nbs: Array = []
	var lim := (diag * 3.2) * (diag * 3.2)
	for i in centres.size():
		var lst := PackedInt32Array()
		for j in centres.size():
			if j != i and centres[i].distance_squared_to(centres[j]) < lim:
				lst.append(j)
		nbs.append(lst)
	var cen := Vector3.ZERO
	for c in centres:
		cen += c
	cen /= maxf(float(centres.size()), 1.0)
	var aim := Vector3(0, H, 0)
	var kind := str(g["rec_kind"])
	g["centres"] = centres
	g["neighbours"] = nbs
	g["hw"] = w
	g["hh"] = h
	g["H"] = H
	g["ped"] = ped
	g["aim"] = aim
	# An external cylinder is aimed at its skin facing each heliostat, not at
	# its axis (aimed at the axis a fat receiver's beams strike low and pass
	# under it).
	g["aim_r"] = float(g["size"]) * 0.5 if kind == "tube" else 0.0
	g["rec_y"] = H
	g["curved"] = bool(o["curved"])
	g["pole"] = Vector3(sin(pole_az), 0, -cos(pole_az))
	g["field_centre"] = cen
	g["surround"] = surround
	g["tower_r"] = maxf(float((spec["structure"] as Dictionary)["member_mm"]) * 0.001 * 0.5, H / 40.0)
	var pw := float(g["size"])
	var ph := float(rc["height_m"])
	g["panel_w"] = pw
	g["panel_h"] = ph
	if kind == "tube":
		g["A_rec"] = PI * pw * ph
		g["bins"] = [-PI, PI, H - ph * 0.5, H + ph * 0.5, 16, 8]
	else:
		var nr := (cen - aim)
		if surround or nr.length() < 0.01:
			nr = Vector3(0, -1, 0)
		nr = nr.normalized()
		var ur := Vector3.UP.cross(nr)
		if ur.length() < 0.01:
			ur = Vector3.RIGHT
		ur = ur.normalized()
		g["panel_n"] = nr
		g["panel_u"] = ur
		g["panel_v"] = nr.cross(ur).normalized()
		g["A_rec"] = pw * ph
		g["bins"] = [-pw * 0.5, pw * 0.5, -ph * 0.5, ph * 0.5, 12, 12]
	g["A_loss"] = g["A_rec"]
	g["A_ap"] = centres.size() * w * h
	g["count"] = centres.size()
	var far := 0.0
	for c in centres:
		far = maxf(far, Vector2(c.x, c.z).length())
	g["field_r"] = far
	g["l_in"] = maxf(H * 0.35, 3.0)


## Heliostat / mirror-row orientations for a sun direction: each one's
## normal bisects the sun and its aim (tower) or does so in the transverse
## plane (linear Fresnel rows turn about their own long axis).
static func field_pose(g: Dictionary, s: Vector3) -> Dictionary:
	var out := {}
	if str(g["type"]) == "tower":
		var cs: PackedVector3Array = g["centres"]
		var aim0: Vector3 = g["aim"]
		var aim_r := float(g.get("aim_r", 0.0))
		var ns := PackedVector3Array()
		var us := PackedVector3Array()
		var vs := PackedVector3Array()
		var rcs := PackedFloat64Array()
		var aims := PackedVector3Array()
		for c in cs:
			var aim := aim0
			if aim_r > 0.0:
				var hz := Vector3(c.x, 0.0, c.z)
				if hz.length() > 1e-6:
					aim += hz.normalized() * aim_r
			aims.append(aim)
			var to_rec := (aim - c)
			var dist := to_rec.length()
			var n := (s + to_rec / maxf(dist, 1e-6)).normalized()
			if n.y < 0.05:
				n = Vector3.UP
			var u := Vector3.UP.cross(n)
			if u.length() < 1e-4:
				u = Vector3.RIGHT
			u = u.normalized()
			ns.append(n)
			us.append(u)
			vs.append(n.cross(u).normalized())
			rcs.append(dist * 2.0)
		out["n"] = ns
		out["u"] = us
		out["v"] = vs
		out["rc"] = rcs
		out["aim"] = aims
	elif str(g["type"]) == "linear_fresnel":
		var xs: PackedFloat64Array = g["xs"]
		var H := float(g["H"])
		var st := Vector3(s.x, s.y, 0.0)
		st = st.normalized() if st.length() > 1e-6 else Vector3.UP
		var ns := PackedVector3Array()
		var us := PackedVector3Array()
		var rcs := PackedFloat64Array()
		for x in xs:
			var to_rec := Vector3(-x, H, 0.0)
			var dist := to_rec.length()
			var n := (st + to_rec / dist).normalized()
			ns.append(n)
			us.append(Vector3(n.y, -n.x, 0.0))
			rcs.append(dist * 2.0)
		out["n"] = ns
		out["u"] = us
		out["rc"] = rcs
	return out


# ---------------------------------------------------------------------------
# Trace
# ---------------------------------------------------------------------------

## Trace `n` rays for the sun direction `sun_local` (toward the sun, in the
## optic frame). opts: seed, max_paths (rays kept as polylines), ideal (no
## sun disc, no errors — the clean section view).
static func trace(g: Dictionary, sun_local: Vector3, n: int, opts: Dictionary = {}) -> Dictionary:
	var acc := Acc.new()
	var b: Array = g["bins"] as Array
	acc.set_bins(float(b[0]), float(b[1]), float(b[2]), float(b[3]), int(b[4]), int(b[5]))
	acc.max_paths = int(opts.get("max_paths", 0))
	acc.every = maxi(1, n / maxi(acc.max_paths * 2, 1))
	acc.ideal = bool(opts.get("ideal", false))
	var rng := RandomNumberGenerator.new()
	rng.seed = int(opts.get("seed", 7))
	var s0 := sun_local.normalized()
	if s0.y <= 0.0005 and str(g["type"]) != "tower" and str(g["type"]) != "linear_fresnel":
		return _result(g, acc, 0)
	if (str(g["type"]) == "tower" or str(g["type"]) == "linear_fresnel") and s0.y <= 0.0005:
		return _result(g, acc, 0)
	var e1 := s0.cross(Vector3.FORWARD if absf(s0.z) < 0.9 else Vector3.RIGHT).normalized()
	var e2 := s0.cross(e1).normalized()
	var pose := field_pose(g, s0)
	var t := str(g["type"])
	for i in n:
		var band := _pick_band(rng)
		var s := _sample_sun(s0, e1, e2, float(g["sun_half"]), float(g["track_err"]), rng, acc.ideal)
		acc.record = acc.paths.size() < acc.max_paths and i % acc.every == 0
		acc.cur_band = band
		_one(t, g, pose, s, band, rng, acc, NAN, -1)
	acc.n = n
	return _result(g, acc, n)


## The clean section: `count` rays across the aperture in the plane z = 0
## (tower: the vertical plane through the tower along the pole), with no
## sun disc and no errors unless `spread` (then each sample also sends the
## sun's two edge rays) or `errors` (random rays with every error on).
static func trace_section(g: Dictionary, sun_local: Vector3, count: int, opts: Dictionary = {}) -> Array:
	var acc := Acc.new()
	var b: Array = g["bins"] as Array
	acc.set_bins(float(b[0]), float(b[1]), float(b[2]), float(b[3]), int(b[4]), int(b[5]))
	acc.max_paths = 100000
	acc.ideal = not bool(opts.get("errors", false))
	var rng := RandomNumberGenerator.new()
	rng.seed = int(opts.get("seed", 11))
	var s0 := sun_local.normalized()
	if s0.y <= 0.0005:
		return []
	var e1 := s0.cross(Vector3.FORWARD if absf(s0.z) < 0.9 else Vector3.RIGHT).normalized()
	var e2 := s0.cross(e1).normalized()
	var pose := field_pose(g, s0)
	var t := str(g["type"])
	var bands: Array = opts.get("bands", [0]) as Array
	var spread := bool(opts.get("spread", false))
	var half := float(g["sun_half"])
	# The in-plane sun-disc edges: rotate s0 about the section normal.
	var sec_n := Vector3.BACK
	if t == "tower":
		sec_n = (g["pole"] as Vector3).cross(Vector3.UP).normalized()
	var suns: Array = [s0]
	if spread:
		suns.append(s0.rotated(sec_n, half))
		suns.append(s0.rotated(sec_n, -half))
	var targets: Array = []
	if t == "tower":
		var cs: PackedVector3Array = g["centres"]
		var east := sec_n
		var diag := sqrt(float(g["hw"]) * float(g["hw"]) + float(g["hh"]) * float(g["hh"]))
		for i in cs.size():
			if absf(cs[i].dot(east)) < diag * 0.8:
				targets.append(i)
	elif t == "linear_fresnel":
		for i in int(g["rows"]):
			targets.append(i)
	else:
		targets.append(-1)
	var per := maxi(count / maxi(targets.size(), 1), 3)
	for ti in targets:
		for k in per:
			var fx := -1.0 + 2.0 * (float(k) + 0.5) / float(per)
			for sv in suns:
				for bv in bands:
					var s: Vector3 = sv
					if not acc.ideal:
						s = _sample_sun(s0, e1, e2, half, float(g["track_err"]), rng, false)
					acc.record = true
					acc.cur_band = int(bv)
					_one(t, g, pose, s, int(bv), rng, acc, fx, int(ti))
	return acc.paths


static func _one(t: String, g: Dictionary, pose: Dictionary, s: Vector3, band: int,
		rng: RandomNumberGenerator, acc: Acc, fx: float, fi: int) -> void:
	match t:
		"parabolic_dish":
			_ray_dish(g, s, rng, acc, fx)
		"parabolic_trough":
			if bool(g.get("cpc", false)):
				_ray_cpc(g, s, rng, acc, fx)
			else:
				_ray_trough(g, s, rng, acc, fx)
		"linear_fresnel":
			_ray_lfr(g, pose, s, rng, acc, fx, fi)
		"tower":
			_ray_tower(g, pose, s, rng, acc, fx, fi)
		"lens":
			_ray_lens(g, s, band, rng, acc, fx)
		"ball_lens":
			_ray_ball(g, s, band, rng, acc, fx)
		"water_lens":
			_ray_water(g, s, band, rng, acc, fx)
		"fresnel_lens":
			_ray_fresnel(g, s, band, rng, acc, fx)


static func _result(g: Dictionary, acc: Acc, n: int) -> Dictionary:
	var inv := 1.0 / maxf(float(n), 1.0)
	var losses := {"cosine": acc.cosine * inv}
	for k in LOSS_KEYS:
		losses[k] = float(acc.loss[k]) * inv
	var cap := acc.captured * inv
	# Flux: the captured weight per bin → suns (W/m² per W/m² of DNI).
	var a_ap := float(g["A_ap"])
	var du := (acc.u1 - acc.u0) / float(acc.nu)
	var dv := (acc.v1 - acc.v0) / float(acc.nv)
	var bin_area := du * dv
	if str(g["rec_kind"]) == "tube":
		bin_area = du * float(g["size"]) * 0.5 * dv
	var suns := PackedFloat64Array()
	suns.resize(acc.nu * acc.nv)
	for i in suns.size():
		suns[i] = acc.flux[i] * inv * a_ap / maxf(bin_area, 1e-12)
	# Peak: the hottest 3×3 neighbourhood (one bin is noise at a few
	# thousand rays).
	var peak := 0.0
	for j in acc.nv:
		for i in acc.nu:
			var sum := 0.0
			var cnt := 0
			for dj in range(-1, 2):
				for di in range(-1, 2):
					var ii := i + di
					var jj := j + dj
					if ii < 0 or jj < 0 or ii >= acc.nu or jj >= acc.nv:
						continue
					sum += suns[jj * acc.nu + ii]
					cnt += 1
			peak = maxf(peak, sum / maxf(float(cnt), 1.0))
	var leaving := cap + float(losses["spill"]) + float(losses["end"])
	var bands := PackedFloat64Array()
	for k in 4:
		bands.append(acc.band_cap[k] * inv)
	return {
		"rays": n,
		"captured": cap,
		"losses": losses,
		"intercept": cap / leaving if leaving > 1e-9 else 0.0,
		"flux": suns,
		"flux_dims": Vector2i(acc.nu, acc.nv),
		"flux_bounds": [acc.u0, acc.u1, acc.v0, acc.v1],
		"peak_suns": peak,
		"mean_suns": cap * a_ap / maxf(float(g["A_rec"]), 1e-9),
		"band_captured": bands,
		"paths": acc.paths,
	}


# ---------------------------------------------------------------------------
# Vector optics
# ---------------------------------------------------------------------------

static func _pick_band(rng: RandomNumberGenerator) -> int:
	var u := rng.randf()
	var c := 0.0
	for i in CspLabParts.BANDS.size():
		c += float((CspLabParts.BANDS[i] as Dictionary)["w"])
		if u <= c:
			return i
	return CspLabParts.BANDS.size() - 1


static func _sample_sun(s0: Vector3, e1: Vector3, e2: Vector3, half: float, track: float,
		rng: RandomNumberGenerator, ideal: bool) -> Vector3:
	if ideal:
		return s0
	var r := half * sqrt(rng.randf())
	var ph := rng.randf() * TAU
	var dx := r * cos(ph)
	var dy := r * sin(ph)
	if track > 0.0:
		dx += rng.randfn(0.0, track)
		dy += rng.randfn(0.0, track)
	return (s0 + e1 * dx + e2 * dy).normalized()


static func reflect(d: Vector3, n: Vector3) -> Vector3:
	return d - 2.0 * d.dot(n) * n


## Snell refraction of the unit direction `d` across a surface of unit
## normal `n` from index `n1` into `n2`. Returns the new direction, or
## Vector3.ZERO on total internal reflection; `_last_t` holds the
## unpolarised Fresnel transmittance (Hecht 2017 §4.6).
static func refract(d: Vector3, n: Vector3, n1: float, n2: float) -> Vector3:
	var nn := n
	if nn.dot(d) > 0.0:
		nn = -nn
	var eta := n1 / n2
	var cosi := -nn.dot(d)
	var k := 1.0 - eta * eta * (1.0 - cosi * cosi)
	if k < 0.0:
		_last_t = 0.0
		return Vector3.ZERO
	var cost := sqrt(k)
	_last_t = 1.0 - fresnel_r(cosi, cost, n1, n2)
	return (d * eta + nn * (eta * cosi - cost)).normalized()


## Unpolarised Fresnel reflectance: the mean of the s and p reflectances.
static func fresnel_r(cosi: float, cost: float, n1: float, n2: float) -> float:
	var rs := (n1 * cosi - n2 * cost) / (n1 * cosi + n2 * cost)
	var rp := (n1 * cost - n2 * cosi) / (n1 * cost + n2 * cosi)
	return 0.5 * (rs * rs + rp * rp)


## A surface normal tilted by a Gaussian slope error (σ per axis).
static func perturb(n: Vector3, sigma: float, rng: RandomNumberGenerator, ideal: bool) -> Vector3:
	if ideal or sigma <= 0.0:
		return n
	var t1 := n.cross(Vector3.RIGHT if absf(n.x) < 0.9 else Vector3.FORWARD).normalized()
	var t2 := n.cross(t1)
	return (n + t1 * rng.randfn(0.0, sigma) + t2 * rng.randfn(0.0, sigma)).normalized()


## Smallest t > eps where the ray hits the sphere (centre c, radius r);
## `far` takes the larger root (leaving the sphere from inside).
static func hit_sphere(o: Vector3, d: Vector3, c: Vector3, r: float, far: bool = false) -> float:
	var oc := o - c
	var b := oc.dot(d)
	var cc := oc.dot(oc) - r * r
	var disc := b * b - cc
	if disc < 0.0:
		return -1.0
	var sq := sqrt(disc)
	var t1 := -b - sq
	var t2 := -b + sq
	if far:
		return t2 if t2 > 1e-7 else -1.0
	if t1 > 1e-7:
		return t1
	return t2 if t2 > 1e-7 else -1.0


## A ray against the infinite cylinder of radius r along Z through (0, yc).
static func hit_cyl_z(o: Vector3, d: Vector3, yc: float, r: float) -> float:
	var a := d.x * d.x + d.y * d.y
	if a < 1e-12:
		return -1.0
	var ox := o.x
	var oy := o.y - yc
	var b := 2.0 * (ox * d.x + oy * d.y)
	var c := ox * ox + oy * oy - r * r
	var disc := b * b - 4.0 * a * c
	if disc < 0.0:
		return -1.0
	var sq := sqrt(disc)
	var t1 := (-b - sq) / (2.0 * a)
	var t2 := (-b + sq) / (2.0 * a)
	if t1 > 1e-7:
		return t1
	return t2 if t2 > 1e-7 else -1.0


## A ray against the vertical cylinder of radius r about the Y axis.
static func hit_cyl_y(o: Vector3, d: Vector3, r: float) -> float:
	var a := d.x * d.x + d.z * d.z
	if a < 1e-12:
		return -1.0
	var b := 2.0 * (o.x * d.x + o.z * d.z)
	var c := o.x * o.x + o.z * o.z - r * r
	var disc := b * b - 4.0 * a * c
	if disc < 0.0:
		return -1.0
	var sq := sqrt(disc)
	var t1 := (-b - sq) / (2.0 * a)
	var t2 := (-b + sq) / (2.0 * a)
	if t1 > 1e-7:
		return t1
	return t2 if t2 > 1e-7 else -1.0


## A ray against a rectangle (centre c, normal n, half sizes hu along u and
## hv along v). Returns t, or -1.
static func hit_rect(o: Vector3, d: Vector3, c: Vector3, n: Vector3, u: Vector3, v: Vector3,
		hu: float, hv: float) -> float:
	var dn := d.dot(n)
	if absf(dn) < 1e-9:
		return -1.0
	var t := (c - o).dot(n) / dn
	if t <= 1e-6:
		return -1.0
	var q := o + d * t - c
	if absf(q.dot(u)) > hu or absf(q.dot(v)) > hv:
		return -1.0
	return t


static func _band_absorb(material: String, band: int, path_m: float) -> float:
	return exp(-CspLabParts.alpha_of(material, band) * path_m * 100.0)


# ---------------------------------------------------------------------------
# Per type
# ---------------------------------------------------------------------------

## Sample the aperture disc (radius a) or square (half side a).
static func _sample_xz(a: float, square: bool, rng: RandomNumberGenerator, fx: float) -> Vector2:
	if not is_nan(fx):
		return Vector2(fx * a * 0.999, 0.0)
	if square:
		return Vector2((rng.randf() * 2.0 - 1.0) * a, (rng.randf() * 2.0 - 1.0) * a)
	var r := a * sqrt(rng.randf())
	var ph := rng.randf() * TAU
	return Vector2(r * cos(ph), r * sin(ph))


static func _ray_dish(g: Dictionary, s: Vector3, rng: RandomNumberGenerator, acc: Acc, fx: float) -> void:
	var a := float(g["a"])
	var f := float(g["f"])
	var yr := float(g["rec_y"])
	var p2 := _sample_xz(a, false, rng, fx)
	var p := Vector3(p2.x, (p2.x * p2.x + p2.y * p2.y) / (4.0 * f), p2.y)
	var w := s.y
	acc.cosine += 1.0 - w
	if w <= 0.0:
		acc.finish("cosine")
		return
	acc.pt(p + s * float(g["l_in"]))
	# Shaded by the receiver housing?
	if s.y > 1e-6:
		var tq := (yr - p.y) / s.y
		if tq > 0.0:
			var q := p + s * tq
			var hr := float(g["house_r"])
			if q.x * q.x + q.z * q.z < hr * hr:
				acc.lose("shading", w)
				acc.pt(q)
				acc.finish("shaded")
				return
	acc.pt(p)
	var n := perturb(Vector3(-p.x, 2.0 * f, -p.z).normalized(), float(g["slope_err"]), rng, acc.ideal)
	var r := reflect(-s, n)
	var rho := float(g["rho"])
	acc.lose("reflect", w * (1.0 - rho))
	w *= rho
	if r.y <= 1e-6:
		acc.lose("spill", w)
		acc.pt(p + r * f)
		acc.finish("spill")
		return
	var t := (yr - p.y) / r.y
	var hit := p + r * t
	var rr := float(g["rec_r"])
	if t > 0.0 and hit.x * hit.x + hit.z * hit.z <= rr * rr:
		_capture(acc, w, hit.x, hit.z)
		acc.pt(hit)
		acc.finish("captured")
	else:
		acc.lose("spill", w)
		acc.pt(p + r * maxf(t * 1.3, 0.3))
		acc.finish("spill")


static func _ray_trough(g: Dictionary, s: Vector3, rng: RandomNumberGenerator, acc: Acc, fx: float) -> void:
	var a := float(g["a"])
	var f := float(g["f"])
	var L := float(g["length"])
	var yr := float(g["rec_y"])
	var x := fx * a * 0.999 if not is_nan(fx) else (rng.randf() * 2.0 - 1.0) * a
	var z := 0.0 if not is_nan(fx) else (rng.randf() - 0.5) * L
	var p := Vector3(x, x * x / (4.0 * f), z)
	var w := s.y
	acc.cosine += 1.0 - w
	if w <= 0.0:
		acc.finish("cosine")
		return
	acc.pt(p + s * float(g["l_in"]))
	var tube := str(g["rec_kind"]) == "tube"
	# Shaded by the receiver (tube / envelope or the flat strip)?
	if tube:
		var ts := hit_cyl_z(p, s, yr, float(g["env_r"]))
		if ts > 0.0:
			acc.lose("shading", w)
			acc.pt(p + s * ts)
			acc.finish("shaded")
			return
	elif s.y > 1e-6:
		var tq := (yr - p.y) / s.y
		if tq > 0.0 and absf(p.x + s.x * tq) < float(g["size"]) * 0.55:
			acc.lose("shading", w)
			acc.pt(p + s * tq)
			acc.finish("shaded")
			return
	acc.pt(p)
	var n := perturb(Vector3(-p.x, 2.0 * f, 0.0).normalized(), float(g["slope_err"]), rng, acc.ideal)
	var r := reflect(-s, n)
	var rho := float(g["rho"])
	acc.lose("reflect", w * (1.0 - rho))
	w *= rho
	_line_receiver(g, acc, p, r, w, yr, L, f)


## A ray through a compound parabolic trough. It enters through the
## aperture (sampled across the top opening, weight = its cosine there) and
## may reflect several times off the walls before it reaches the absorber or
## turns back out through the aperture (the light beyond the acceptance
## angle). The walls are extruded along Z, so each step is a 2D intersection
## with the profile's segments; Z only decides the end loss.
static func _ray_cpc(g: Dictionary, s: Vector3, rng: RandomNumberGenerator, acc: Acc, fx: float) -> void:
	var a := float(g["a"])
	var L := float(g["length"])
	var yt := float(g["y_top"])
	var x := fx * a * 0.999 if not is_nan(fx) else (rng.randf() * 2.0 - 1.0) * a
	var z := 0.0 if not is_nan(fx) else (rng.randf() - 0.5) * L
	var p := Vector3(x, yt, z)
	var w := s.y
	acc.cosine += 1.0 - maxf(w, 0.0)
	if w <= 0.0:
		acc.finish("cosine")
		return
	acc.pt(p + s * float(g["l_in"]))
	acc.pt(p)
	var d := -s
	var tube := str(g["profile"]) == "cpc_tube"
	var segs: Dictionary = g["cpc_segs"]
	var ns: PackedVector2Array = segs["n"]
	var rho := float(g["rho"])
	var yc := float(g["rec_y"])
	var rr := float(g["rec_r"])
	for _bounce in 16:
		var t_abs := -1.0
		if tube:
			t_abs = hit_cyl_z(p, d, yc, rr)
		elif d.y < -1e-9:
			var tf := -p.y / d.y
			if tf > 1e-7 and absf(p.x + d.x * tf) <= rr:
				t_abs = tf
		var hm := CspLabCpc.hit(segs, Vector2(p.x, p.y), Vector2(d.x, d.y))
		var t_m := hm.x
		if t_abs > 0.0 and (t_m <= 0.0 or t_abs < t_m):
			var q := p + d * t_abs
			if absf(q.z) > L * 0.5:
				acc.lose("end", w)
				acc.pt(q)
				acc.finish("end")
				return
			if tube:
				_capture(acc, w, atan2(q.x, q.y - yc), q.z)
			else:
				_capture(acc, w, q.x, q.z)
			acc.pt(q)
			acc.finish("captured")
			return
		if t_m <= 0.0:
			# Back out through the aperture (or past a truncated wall).
			acc.lose("spill", w)
			acc.pt(p + d * maxf(float(g["l_in"]) * 0.6, 0.2))
			acc.finish("spill")
			return
		var q2 := p + d * t_m
		if absf(q2.z) > L * 0.5:
			acc.lose("end", w)
			acc.pt(q2)
			acc.finish("end")
			return
		var n2 := ns[int(hm.y)]
		var n3 := perturb(Vector3(n2.x, n2.y, 0.0), float(g["slope_err"]), rng, acc.ideal)
		d = reflect(d, n3)
		acc.lose("reflect", w * (1.0 - rho))
		w *= rho
		acc.pt(q2)
		p = q2 + d * 1e-6
	acc.lose("spill", w)
	acc.finish("spill")


## The end of a line-focus ray: a tube (with its envelope) or a flat strip
## facing down at height `yr`, `L` long.
static func _line_receiver(g: Dictionary, acc: Acc, p: Vector3, r: Vector3, w_in: float,
		yr: float, L: float, show_len: float) -> void:
	var w := w_in
	if str(g["rec_kind"]) == "tube":
		var t := hit_cyl_z(p, r, yr, float(g["rec_r"]))
		if t <= 0.0:
			acc.lose("spill", w)
			acc.pt(p + r * maxf(show_len * 1.4, 0.5))
			acc.finish("spill")
			return
		var hit := p + r * t
		if absf(hit.z) > L * 0.5:
			acc.lose("end", w)
			acc.pt(hit)
			acc.finish("end")
			return
		var tau := float(g.get("env_tau", 1.0))
		acc.lose("glazing", w * (1.0 - tau))
		w *= tau
		_capture(acc, w, atan2(hit.x, hit.y - yr), hit.z)
		acc.pt(hit)
		acc.finish("captured")
		return
	if r.y <= 1e-6:
		acc.lose("spill", w)
		acc.pt(p + r * maxf(show_len, 0.5))
		acc.finish("spill")
		return
	var t2 := (yr - p.y) / r.y
	var q := p + r * t2
	var half := float(g["size"]) * 0.5
	if t2 > 0.0 and absf(q.x) <= half:
		if absf(q.z) > L * 0.5:
			acc.lose("end", w)
			acc.pt(q)
			acc.finish("end")
			return
		var tau2 := float(g.get("env_tau", 1.0))
		acc.lose("glazing", w * (1.0 - tau2))
		w *= tau2
		_capture(acc, w, q.x, q.z)
		acc.pt(q)
		acc.finish("captured")
	else:
		acc.lose("spill", w)
		acc.pt(p + r * maxf(t2 * 1.25, 0.5))
		acc.finish("spill")


static func _ray_lfr(g: Dictionary, pose: Dictionary, s: Vector3, rng: RandomNumberGenerator,
		acc: Acc, fx: float, fi: int) -> void:
	var rows := int(g["rows"])
	var xs: PackedFloat64Array = g["xs"]
	var ns: PackedVector3Array = pose["n"]
	var us: PackedVector3Array = pose["u"]
	var rcs: PackedFloat64Array = pose["rc"]
	var w0 := float(g["w"])
	var L := float(g["length"])
	var H := float(g["H"])
	var i := fi if fi >= 0 else rng.randi() % rows
	var u := fx * w0 * 0.5 * 0.999 if not is_nan(fx) else (rng.randf() - 0.5) * w0
	var z := 0.0 if not is_nan(fx) else (rng.randf() - 0.5) * L
	var c := Vector3(xs[i], 0.0, 0.0)
	var p := c + us[i] * u + Vector3(0, 0, z)
	var n0 := ns[i]
	if bool(g["curved"]):
		n0 = (n0 - us[i] * (u / rcs[i])).normalized()
	var w := s.dot(n0)
	acc.cosine += 1.0 - maxf(w, 0.0)
	if w <= 0.0:
		acc.finish("cosine")
		return
	acc.pt(p + s * float(g["l_in"]))
	# Shading: the receiver strip, then the neighbouring rows.
	if s.y > 1e-6:
		var tq := (H - p.y) / s.y
		var q := p + s * tq
		if tq > 0.0 and absf(q.x) < float(g["size"]) * 0.55 + 0.05:
			acc.lose("shading", w)
			acc.pt(q)
			acc.finish("shaded")
			return
	for j in range(maxi(i - 3, 0), mini(i + 4, rows)):
		if j == i:
			continue
		var cj := Vector3(xs[j], 0.0, 0.0)
		var tj := hit_rect(p, s, cj, ns[j], us[j], Vector3.BACK, w0 * 0.5, L * 0.5)
		if tj > 0.0:
			acc.lose("shading", w)
			acc.pt(p + s * tj)
			acc.finish("shaded")
			return
	acc.pt(p)
	var n := perturb(n0, float(g["slope_err"]), rng, acc.ideal)
	var r := reflect(-s, n)
	var rho := float(g["rho"])
	acc.lose("reflect", w * (1.0 - rho))
	w *= rho
	for j in range(maxi(i - 3, 0), mini(i + 4, rows)):
		if j == i:
			continue
		var cj2 := Vector3(xs[j], 0.0, 0.0)
		var tb := hit_rect(p, r, cj2, ns[j], us[j], Vector3.BACK, w0 * 0.5, L * 0.5)
		if tb > 0.0:
			acc.lose("blocking", w)
			acc.pt(p + r * tb)
			acc.finish("blocked")
			return
	_line_receiver(g, acc, p, r, w, H, L, H)


static func _ray_tower(g: Dictionary, pose: Dictionary, s: Vector3, rng: RandomNumberGenerator,
		acc: Acc, fx: float, fi: int) -> void:
	var cs: PackedVector3Array = g["centres"]
	var cnt := cs.size()
	if cnt == 0:
		return
	var ns: PackedVector3Array = pose["n"]
	var us: PackedVector3Array = pose["u"]
	var vs: PackedVector3Array = pose["v"]
	var rcs: PackedFloat64Array = pose["rc"]
	var nbs: Array = g["neighbours"]
	var hw := float(g["hw"]) * 0.5
	var hh := float(g["hh"]) * 0.5
	var i := fi if fi >= 0 else rng.randi() % cnt
	var uu := 0.0 if not is_nan(fx) else (rng.randf() * 2.0 - 1.0) * hw
	var vv := fx * hh * 0.999 if not is_nan(fx) else (rng.randf() * 2.0 - 1.0) * hh
	var p := cs[i] + us[i] * uu + vs[i] * vv
	var n0 := ns[i]
	if bool(g["curved"]):
		n0 = (n0 - us[i] * (uu / rcs[i]) - vs[i] * (vv / rcs[i])).normalized()
	var w := s.dot(n0)
	acc.cosine += 1.0 - maxf(w, 0.0)
	if w <= 0.0:
		acc.finish("cosine")
		return
	acc.pt(p + s * float(g["l_in"]))
	var nb: PackedInt32Array = nbs[i]
	for j in nb:
		var tj := hit_rect(p, s, cs[j], ns[j], us[j], vs[j], hw, hh)
		if tj > 0.0:
			acc.lose("shading", w)
			acc.pt(p + s * tj)
			acc.finish("shaded")
			return
	# The tower's shadow.
	var tt := hit_cyl_y(p, s, float(g["tower_r"]))
	if tt > 0.0 and (p + s * tt).y < float(g["H"]) - float(g["panel_h"]) * 0.5:
		acc.lose("shading", w)
		acc.pt(p + s * tt)
		acc.finish("shaded")
		return
	acc.pt(p)
	var n := perturb(n0, float(g["slope_err"]), rng, acc.ideal)
	var r := reflect(-s, n)
	var rho := float(g["rho"])
	acc.lose("reflect", w * (1.0 - rho))
	w *= rho
	var aim: Vector3 = g["aim"]
	var dist := p.distance_to((pose["aim"] as PackedVector3Array)[i])
	for j in nb:
		var tb := hit_rect(p, r, cs[j], ns[j], us[j], vs[j], hw, hh)
		if tb > 0.0 and tb < dist:
			acc.lose("blocking", w)
			acc.pt(p + r * tb)
			acc.finish("blocked")
			return
	var att := clampf(ATT_A - ATT_B * dist + ATT_C * dist * dist, 0.0, 1.0) if dist <= 1000.0 \
		else exp(-0.0001106 * dist)
	acc.lose("attenuation", w * (1.0 - att))
	w *= att
	if str(g["rec_kind"]) == "tube":
		var rc := float(g["panel_w"]) * 0.5
		var tc := hit_cyl_y(p, r, rc)
		var H := float(g["H"])
		var ph := float(g["panel_h"]) * 0.5
		if tc > 0.0:
			var q := p + r * tc
			if absf(q.y - H) <= ph:
				_capture(acc, w, atan2(q.x, -q.z), q.y)
				acc.pt(q)
				acc.finish("captured")
				return
		acc.lose("spill", w)
		acc.pt(p + r * dist * 1.15)
		acc.finish("spill")
		return
	var pn: Vector3 = g["panel_n"]
	var pu: Vector3 = g["panel_u"]
	var pv: Vector3 = g["panel_v"]
	var tp := hit_rect(p, r, aim, pn, pu, pv, float(g["panel_w"]) * 0.5, float(g["panel_h"]) * 0.5)
	if tp > 0.0 and r.dot(pn) < 0.0:
		var q2 := p + r * tp
		_capture(acc, w, (q2 - aim).dot(pu), (q2 - aim).dot(pv))
		acc.pt(q2)
		acc.finish("captured")
	else:
		acc.lose("spill", w)
		acc.pt(p + r * dist * 1.15)
		acc.finish("spill")


## The lens types' receiver: a disc facing up at y = rec_y.
static func _lens_receiver(g: Dictionary, acc: Acc, p: Vector3, d: Vector3, w: float) -> void:
	var yr := float(g["rec_y"])
	if d.y >= -1e-6:
		acc.lose("spill", w)
		acc.pt(p + d * 0.3)
		acc.finish("spill")
		return
	var t := (yr - p.y) / d.y
	var q := p + d * t
	var rr := float(g["rec_r"])
	if t > 0.0 and q.x * q.x + q.z * q.z <= rr * rr:
		_capture(acc, w, q.x, q.z)
		acc.pt(q)
		acc.finish("captured")
	else:
		acc.lose("spill", w)
		acc.pt(p + d * maxf(t * 1.25, 0.2))
		acc.finish("spill")


static func _capture(acc: Acc, w: float, u: float, v: float) -> void:
	acc.captured += w
	acc.bin(u, v, w)
	acc.band_cap[acc.cur_band] += w


## Lose what a refraction reflected; returns the weight that went through.
static func _refr_w(acc: Acc, w: float) -> float:
	acc.lose("fresnel", w * (1.0 - _last_t))
	return w * _last_t


static func _ray_lens(g: Dictionary, s: Vector3, band: int, rng: RandomNumberGenerator, acc: Acc, fx: float) -> void:
	var a := float(g["a"])
	var R := float(g["R"])
	var yc := float(g["yc"])
	var mat := str(g["material"])
	var nl := CspLabParts.n_of(mat, band)
	var p2 := _sample_xz(a, false, rng, fx)
	var c := Vector3(0, yc, 0)
	var p := Vector3(p2.x, yc + sqrt(maxf(R * R - p2.x * p2.x - p2.y * p2.y, 0.0)), p2.y)
	var w := s.y
	acc.cosine += 1.0 - w
	if w <= 0.0:
		acc.finish("cosine")
		return
	acc.pt(p + s * float(g["l_in"]))
	acc.pt(p)
	var n1 := perturb((p - c).normalized(), float(g["slope_err"]), rng, acc.ideal)
	var d1 := refract(-s, n1, AIR_N, nl)
	w = _refr_w(acc, w)
	if d1 == Vector3.ZERO or d1.y >= 0.0:
		acc.finish("lost")
		return
	var yf := float(g["y_flat"])
	var t := (yf - p.y) / d1.y
	var q := p + d1 * t
	var at := _band_absorb(mat, band, t)
	acc.lose("absorb", w * (1.0 - at))
	w *= at
	acc.pt(q)
	if q.x * q.x + q.z * q.z > a * a:
		acc.lose("spill", w)
		acc.finish("spill")
		return
	var d2 := refract(d1, Vector3.UP, nl, AIR_N)
	if d2 == Vector3.ZERO:
		acc.lose("fresnel", w)
		acc.finish("tir")
		return
	w = _refr_w(acc, w)
	_lens_receiver(g, acc, q, d2, w)


static func _ray_ball(g: Dictionary, s: Vector3, band: int, rng: RandomNumberGenerator, acc: Acc, fx: float) -> void:
	var R := float(g["R"])
	var yc := float(g["yc"])
	var mat := str(g["material"])
	var nl := CspLabParts.n_of(mat, band)
	var c := Vector3(0, yc, 0)
	var p2 := _sample_xz(R, false, rng, fx)
	# Where the ray along -s first meets the sphere (any sun direction).
	var o := Vector3(p2.x, yc, p2.y) + s * (R * 3.0)
	var w := s.y
	if is_nan(fx):
		# A sphere looks the same from every direction: rays arrive on the
		# disc perpendicular to s, so there is no cosine loss to the sphere —
		# but the reference aperture is horizontal (π R²) like every lens.
		var e1 := s.cross(Vector3.FORWARD if absf(s.z) < 0.9 else Vector3.RIGHT).normalized()
		var e2 := s.cross(e1)
		o = c + e1 * p2.x + e2 * p2.y + s * (R * 3.0)
		w = 1.0
	acc.cosine += 1.0 - w
	var t0 := hit_sphere(o, -s, c, R)
	if t0 <= 0.0 or w <= 0.0:
		acc.finish("cosine")
		return
	var p := o - s * t0
	acc.pt(p + s * float(g["l_in"]))
	acc.pt(p)
	var n1 := perturb((p - c).normalized(), float(g["slope_err"]), rng, acc.ideal)
	var d1 := refract(-s, n1, AIR_N, nl)
	w = _refr_w(acc, w)
	if d1 == Vector3.ZERO:
		acc.finish("lost")
		return
	var t1 := hit_sphere(p + d1 * 1e-6, d1, c, R, true)
	if t1 <= 0.0:
		acc.finish("lost")
		return
	var q := p + d1 * t1
	var at := _band_absorb(mat, band, t1)
	acc.lose("absorb", w * (1.0 - at))
	w *= at
	acc.pt(q)
	var d2 := refract(d1, (q - c).normalized(), nl, AIR_N)
	if d2 == Vector3.ZERO:
		acc.lose("fresnel", w)
		acc.finish("tir")
		return
	w = _refr_w(acc, w)
	_lens_receiver(g, acc, q, d2, w)


static func _ray_water(g: Dictionary, s: Vector3, band: int, rng: RandomNumberGenerator, acc: Acc, fx: float) -> void:
	var a := float(g["a"])
	var R := float(g["R"])
	var nl := CspLabParts.n_of("water", band)
	var c := Vector3(0, float(g["yc"]), 0)
	var p2 := _sample_xz(a, false, rng, fx)
	var p := Vector3(p2.x, float(g["y_top"]), p2.y)
	var w := s.y
	acc.cosine += 1.0 - w
	if w <= 0.0:
		acc.finish("cosine")
		return
	acc.pt(p + s * float(g["l_in"]))
	acc.pt(p)
	var tau := float(g["film_tau"])
	acc.lose("glazing", w * (1.0 - tau))
	w *= tau
	var d1 := refract(-s, Vector3.UP, AIR_N, nl)
	w = _refr_w(acc, w)
	if d1 == Vector3.ZERO:
		acc.finish("lost")
		return
	var t1 := hit_sphere(p, d1, c, R, true)
	if t1 <= 0.0:
		acc.lose("spill", w)
		acc.finish("spill")
		return
	var q := p + d1 * t1
	var at := _band_absorb("water", band, t1)
	acc.lose("absorb", w * (1.0 - at))
	w *= at
	acc.pt(q)
	if q.x * q.x + q.z * q.z > a * a * 1.0001:
		acc.lose("spill", w)
		acc.finish("spill")
		return
	var n2 := perturb((q - c).normalized(), float(g["slope_err"]), rng, acc.ideal)
	var d2 := refract(d1, n2, nl, AIR_N)
	if d2 == Vector3.ZERO:
		acc.lose("fresnel", w)
		acc.finish("tir")
		return
	w = _refr_w(acc, w)
	acc.lose("glazing", w * (1.0 - tau))
	w *= tau
	_lens_receiver(g, acc, q, d2, w)


## A grooves-down Fresnel lens: flat top, prism facets underneath, each
## facet's tilt α(r) chosen so a vertical visible ray leaves toward the focus:
## tan α = sin δ / (n − cos δ), δ = atan(r / F) (from Snell at the facet).
static func facet_angle(r: float, f: float, n: float) -> float:
	var dlt := atan2(r, f)
	return atan2(sin(dlt), n - cos(dlt))


static func _ray_fresnel(g: Dictionary, s: Vector3, band: int, rng: RandomNumberGenerator, acc: Acc, fx: float) -> void:
	var a := float(g["a"])
	var mat := str(g["material"])
	var nl := CspLabParts.n_of(mat, band)
	var p2 := _sample_xz(a, bool(g["square"]), rng, fx)
	var p := Vector3(p2.x, float(g["y_top"]), p2.y)
	var w := s.y
	acc.cosine += 1.0 - w
	if w <= 0.0:
		acc.finish("cosine")
		return
	acc.pt(p + s * float(g["l_in"]))
	acc.pt(p)
	var d1 := refract(-s, Vector3.UP, AIR_N, nl)
	w = _refr_w(acc, w)
	if d1 == Vector3.ZERO or d1.y >= 0.0:
		acc.finish("lost")
		return
	var yg := float(g["y_groove"])
	var t := (yg - p.y) / d1.y
	var q := p + d1 * t
	var at := _band_absorb(mat, band, t)
	acc.lose("absorb", w * (1.0 - at))
	w *= at
	acc.pt(q)
	var r := Vector2(q.x, q.z).length()
	var f := float(g["f"])
	var al := facet_angle(r, f, float(g["n_design"]))
	var n_out := Vector3.DOWN
	if r > 1e-6:
		n_out = Vector3(sin(al) * q.x / r, -cos(al), sin(al) * q.z / r)
	n_out = perturb(n_out, float(g["slope_err"]), rng, acc.ideal)
	# Groove losses (ESTIMATE): the rounded tips and valleys scatter a band
	# 2·tip/pitch wide; the draft faces catch about 0.3·tan α·tan δ of
	# the light leaving each facet (grows toward the rim of a fast lens).
	var dlt := atan2(r, f)
	var gl := clampf(2.0 * float(g["tip"]) / maxf(float(g["pitch"]), 1e-6) + 0.3 * tan(al) * tan(dlt), 0.0, 0.9)
	acc.lose("grooves", w * gl)
	w *= 1.0 - gl
	var d2 := refract(d1, n_out, nl, AIR_N)
	if d2 == Vector3.ZERO:
		acc.lose("fresnel", w)
		acc.finish("tir")
		return
	w = _refr_w(acc, w)
	_lens_receiver(g, acc, q, d2, w)


# ---------------------------------------------------------------------------
# The 2D section's outlines
# ---------------------------------------------------------------------------

## The optic's outline in its section plane: [{kind, pts: PackedVector2Array,
## closed}], kind = mirror | lens | water | receiver | tower | ground.
## Section coordinates: (x, y) for everything but the tower, whose section is
## (distance along the pole, height).
static func section_profile(g: Dictionary, sun_local: Vector3) -> Array:
	var out: Array = []
	var t := str(g["type"])
	match t:
		"parabolic_trough" when bool(g.get("cpc", false)):
			var p: Dictionary = g["cpc_prof"]
			var pts0 := PackedVector2Array()
			var lft: PackedVector2Array = p["left"]
			for i in range(lft.size() - 1, -1, -1):
				pts0.append(lft[i])
			pts0.append_array(p["right"] as PackedVector2Array)
			out.append({"kind": "mirror", "pts": pts0})
			if str(g["profile"]) == "cpc_tube":
				var yc := float(g["rec_y"])
				var rm := float(g["r_mirror"])
				if rm > float(g["rec_r"]) + 1e-6:
					var gp := PackedVector2Array()
					for i in 32:
						var an := TAU * i / 32.0
						gp.append(Vector2(cos(an) * rm, yc + sin(an) * rm))
					out.append({"kind": "guide", "pts": gp, "closed": true})
			out.append(_rec_outline(g))
			# The string drawing's two lines: the acceptance fan through the
			# target.
			var ta := float(g["theta_a"])
			var oy := float(g["rec_y"])
			var reach := (float(g["y_top"]) - oy) / maxf(cos(ta), 0.05) * 1.05
			for sgn in [-1.0, 1.0]:
				out.append({"kind": "guide", "pts": PackedVector2Array([Vector2(0, oy),
					Vector2(sin(ta) * float(sgn) * reach, oy + cos(ta) * reach)])})
		"parabolic_dish", "parabolic_trough":
			var a := float(g["a"])
			var f := float(g["f"])
			var pts := PackedVector2Array()
			for i in 49:
				var x := -a + 2.0 * a * i / 48.0
				pts.append(Vector2(x, x * x / (4.0 * f)))
			out.append({"kind": "mirror", "pts": pts})
			out.append(_rec_outline(g))
		"linear_fresnel":
			var pose := field_pose(g, sun_local)
			var xs: PackedFloat64Array = g["xs"]
			var us: PackedVector3Array = pose["u"]
			var hw := float(g["w"]) * 0.5
			for i in xs.size():
				var c := Vector2(xs[i], 0.0)
				var u := Vector2(us[i].x, us[i].y)
				out.append({"kind": "mirror", "pts": PackedVector2Array([c - u * hw, c + u * hw])})
			out.append(_rec_outline(g))
			var tot := float(g["total"]) * 0.5 + 0.4
			out.append({"kind": "ground", "pts": PackedVector2Array([Vector2(-tot, -0.6), Vector2(tot, -0.6)])})
		"tower":
			var pose2 := field_pose(g, sun_local)
			var cs: PackedVector3Array = g["centres"]
			var vs: PackedVector3Array = pose2["v"]
			var pole: Vector3 = g["pole"]
			var east := pole.cross(Vector3.UP).normalized()
			var diag := sqrt(float(g["hw"]) * float(g["hw"]) + float(g["hh"]) * float(g["hh"]))
			var hh := float(g["hh"]) * 0.5
			var far := 0.0
			for i in cs.size():
				if absf(cs[i].dot(east)) >= diag * 0.8:
					continue
				var c2 := Vector2(cs[i].dot(pole), cs[i].y)
				var v2 := Vector2(vs[i].dot(pole), vs[i].y).normalized()
				out.append({"kind": "mirror", "pts": PackedVector2Array([c2 - v2 * hh, c2 + v2 * hh])})
				out.append({"kind": "tower", "pts": PackedVector2Array([Vector2(c2.x, 0.0), c2])})
				far = maxf(far, absf(c2.x))
			var H := float(g["H"])
			var tr := float(g["tower_r"])
			out.append({"kind": "tower", "pts": PackedVector2Array([Vector2(-tr, 0), Vector2(-tr, H), Vector2(tr, H), Vector2(tr, 0)])})
			var ph := float(g["panel_h"]) * 0.5
			var pw := float(g["panel_w"]) * 0.5
			if str(g["rec_kind"]) == "tube":
				out.append({"kind": "receiver", "pts": PackedVector2Array([Vector2(-pw, H - ph), Vector2(pw, H - ph),
					Vector2(pw, H + ph), Vector2(-pw, H + ph)]), "closed": true})
			else:
				var pn: Vector3 = g["panel_n"]
				var pv: Vector3 = g["panel_v"]
				var cc := Vector2(0, H)
				var v3 := Vector2(pv.dot(pole), pv.y).normalized()
				var n3 := Vector2(pn.dot(pole), pn.y).normalized()
				out.append({"kind": "receiver", "pts": PackedVector2Array([cc - v3 * ph, cc + v3 * ph,
					cc + v3 * ph - n3 * 0.15, cc - v3 * ph - n3 * 0.15]), "closed": true})
			out.append({"kind": "ground", "pts": PackedVector2Array([Vector2(-far - 3.0, 0), Vector2(far + 3.0, 0)])})
		"lens":
			var a2 := float(g["a"])
			var R := float(g["R"])
			var yc := float(g["yc"])
			var yf := float(g["y_flat"])
			var pts2 := PackedVector2Array()
			pts2.append(Vector2(-a2, yf))
			for i in 41:
				var x2 := -a2 + 2.0 * a2 * i / 40.0
				pts2.append(Vector2(x2, yc + sqrt(maxf(R * R - x2 * x2, 0.0))))
			pts2.append(Vector2(a2, yf))
			out.append({"kind": "lens", "pts": pts2, "closed": true})
			out.append(_rec_outline(g))
		"ball_lens":
			var R2 := float(g["R"])
			var yc2 := float(g["yc"])
			var pts3 := PackedVector2Array()
			for i in 64:
				var ang := TAU * i / 64.0
				pts3.append(Vector2(cos(ang) * R2, yc2 + sin(ang) * R2))
			out.append({"kind": "lens", "pts": pts3, "closed": true})
			out.append(_rec_outline(g))
		"water_lens":
			var a3 := float(g["a"])
			var R3 := float(g["R"])
			var yc3 := float(g["yc"])
			var yt := float(g["y_top"])
			var pts4 := PackedVector2Array()
			pts4.append(Vector2(-a3, yt))
			pts4.append(Vector2(a3, yt))
			for i in 41:
				var x3 := a3 - 2.0 * a3 * i / 40.0
				pts4.append(Vector2(x3, yc3 - sqrt(maxf(R3 * R3 - x3 * x3, 0.0))))
			out.append({"kind": "water", "pts": pts4, "closed": true})
			out.append(_rec_outline(g))
		"fresnel_lens":
			var a4 := float(g["a"])
			var yg := float(g["y_groove"])
			var yt2 := float(g["y_top"])
			var f2 := float(g["f"])
			var nd := float(g["n_design"])
			# Grooves drawn ~16 per side so they read (the real pitch is fine).
			var steps := 16
			var gh := maxf(float(g["th"]) * 0.6, a4 * 0.006)
			var pts5 := PackedVector2Array()
			pts5.append(Vector2(-a4, yt2))
			pts5.append(Vector2(a4, yt2))
			for i in range(steps, -steps - 1, -1):
				var x5 := a4 * float(i) / float(steps)
				var al := facet_angle(absf(x5), f2, nd)
				pts5.append(Vector2(x5, yg))
				if i != 0:
					var sgn := -1.0 if x5 > 0.0 else 1.0
					pts5.append(Vector2(x5 + sgn * a4 / float(steps), yg - gh * tan(al) / maxf(tan(facet_angle(a4, f2, nd)), 1e-3)))
			out.append({"kind": "lens", "pts": pts5, "closed": true})
			out.append(_rec_outline(g))
	return out


static func _rec_outline(g: Dictionary) -> Dictionary:
	var yr := float(g["rec_y"])
	var kind := str(g["rec_kind"])
	var rr := float(g["size"]) * 0.5
	if kind == "tube":
		var pts := PackedVector2Array()
		for i in 24:
			var a := TAU * i / 24.0
			pts.append(Vector2(cos(a) * rr, yr + sin(a) * rr))
		return {"kind": "receiver", "pts": pts, "closed": true}
	var th := maxf(rr * 0.25, 0.01)
	var up := 1.0 if str(g["optic_kind"]) == "mirror" else -1.0
	if bool(g.get("cpc", false)):
		up = -1.0
		th = maxf(rr * 0.15, 0.008)
	if kind == "cavity":
		th = maxf(rr * 1.2, 0.03)
	return {"kind": "receiver", "pts": PackedVector2Array([Vector2(-rr, yr), Vector2(rr, yr),
		Vector2(rr, yr + th * up), Vector2(-rr, yr + th * up)]), "closed": true}
