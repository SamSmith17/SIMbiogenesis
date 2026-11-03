class_name CspLabSpec
extends RefCounted

## A concentrating solar design as one Dictionary: what concentrates the
## sun (a lens or a mirror), where it puts it (the receiver), how it follows
## the sun, what holds it up, how the rays are traced and what the site asks
## of it. Every key exists for every type (`resolve` fills defaults); the
## ones a type does not use are hidden in the modal (`FIELDS[*].types`).
##
## Frames. A design lives in its OPTIC frame: +Y is the optical axis (the
## direction the optic faces the sun at normal incidence), +Z is the length
## axis of a line focus (a trough, a linear Fresnel field). Mirrors sit at
## the bottom with the receiver above them; lenses sit above the receiver,
## which is at the origin. A tower field's optic frame is the ground: +Y up,
## -Z north, +X east (the project's world convention).

const TYPES := ["lens", "ball_lens", "fresnel_lens", "water_lens",
	"parabolic_trough", "parabolic_dish", "linear_fresnel", "tower"]

const TYPE_LABELS := {
	"lens": "Glass lens",
	"ball_lens": "Spherical (ball) lens",
	"fresnel_lens": "Fresnel lens",
	"water_lens": "Water lens",
	"parabolic_trough": "Parabolic trough",
	"parabolic_dish": "Parabolic dish",
	"linear_fresnel": "Linear Fresnel reflector",
	"tower": "Power tower (heliostats)",
}

const TYPE_WHY := {
	"lens": "A plano-convex lens: simple and exact near the axis, but heavy — a 50 cm glass lens is ~20 kg and its rim focuses short (spherical aberration).",
	"ball_lens": "A glass or water-filled sphere: focuses from any direction (no tracking for a coarse spot), but blurs badly — the edge rays cross far before the paraxial focus.",
	"fresnel_lens": "A lens collapsed into flat grooves: light and cheap, a few percent lost on the groove tips and draft faces, and colours split (the focus is a rainbow).",
	"water_lens": "Water lying on a sagging clear membrane: almost free to build, but water absorbs the infrared (a fifth of the sun is lost in 15 cm) and the frame must carry the water.",
	"parabolic_trough": "A curved mirror strip that focuses on a tube along its length; one tracking axis. The workhorse of solar thermal plants (C ≈ 20–80).",
	"parabolic_dish": "A mirror bowl that focuses to a point; two-axis tracking. The highest concentration of any practical collector (C ≈ 1000–4000).",
	"linear_fresnel": "Flat mirror strips near the ground, each turned to bounce the sun onto one fixed receiver above them. Cheap and wind-light; loses to cosine and row shading at low sun.",
	"tower": "A field of two-axis heliostats aiming at a receiver on a tower. Scales to megawatts; each heliostat pays a cosine loss that depends on where it stands.",
}

## Point focus or line focus.
const FOCUS := {
	"lens": "point", "ball_lens": "point", "fresnel_lens": "point", "water_lens": "point",
	"parabolic_trough": "line", "parabolic_dish": "point", "linear_fresnel": "line", "tower": "point",
}

## Refractive (lens) or reflective (mirror).
const OPTIC := {
	"lens": "lens", "ball_lens": "lens", "fresnel_lens": "lens", "water_lens": "lens",
	"parabolic_trough": "mirror", "parabolic_dish": "mirror", "linear_fresnel": "mirror", "tower": "mirror",
}

const TRACKING_MODES := {
	"two_axis": "Two-axis (always faces the sun)",
	"ns_horizontal": "One-axis, horizontal N–S axis",
	"ew_horizontal": "One-axis, horizontal E–W axis",
	"polar": "One-axis, polar (axis at latitude)",
	"fixed": "Fixed (tilted to the equator)",
}

const MOUNTS := {
	"pedestal_azel": "Pedestal, azimuth + elevation",
	"polar_mount": "Polar (equatorial) mount",
	"torque_tube": "Torque tube on pylons",
	"row_frame": "Mirror rows on a frame + receiver mast",
	"lattice_tower": "Lattice tower + heliostat pedestals",
	"monopole": "Monopole tower + heliostat pedestals",
}

## A trough's cross-section: the classic parabola (sun must stay on its
## axis), or a compound parabolic concentrator (CspLabCpc) that accepts a
## ±θa fan onto a round tube (the "W") or a flat absorber.
const TROUGH_PROFILES := {
	"parabola": "Parabola (focal line)",
	"cpc_tube": "Compound parabolic — round tube (W)",
	"cpc_flat": "Compound parabolic — flat absorber",
}

const RECEIVER_KINDS := {
	"flat": "Flat absorber",
	"tube": "Absorber tube",
	"cavity": "Cavity (insulated box)",
}

const OBJECTIVES := {
	"net_kw": "Useful heat (kW at the working temperature)",
	"optical": "Optical efficiency",
	"suns": "Mean concentration on the receiver",
	"kw_per_m2": "Useful heat per m² of aperture",
}

## What the optimizer may vary per type: [group, key, min, max].
const OPT_PARAMS := {
	"lens": [["optic", "focal_m", 0.2, 3.0], ["receiver", "size_m", 0.005, 0.3], ["receiver", "offset_m", -0.2, 0.2]],
	"ball_lens": [["receiver", "offset_m", -0.3, 0.3], ["receiver", "size_m", 0.005, 0.3]],
	"fresnel_lens": [["optic", "focal_m", 0.3, 3.0], ["receiver", "size_m", 0.005, 0.4], ["receiver", "offset_m", -0.2, 0.2]],
	"water_lens": [["optic", "focal_m", 1.0, 8.0], ["receiver", "size_m", 0.01, 0.5], ["receiver", "offset_m", -0.5, 0.5]],
	"parabolic_trough": [["optic", "focal_m", 0.15, 2.5], ["receiver", "size_m", 0.01, 0.15]],
	"parabolic_dish": [["optic", "focal_m", 0.2, 6.0], ["receiver", "size_m", 0.01, 0.8], ["receiver", "offset_m", -0.2, 0.2]],
	"linear_fresnel": [["optic", "recv_height_m", 1.0, 12.0], ["optic", "gap_m", 0.0, 0.5], ["receiver", "size_m", 0.05, 1.0]],
	"tower": [["optic", "tower_h_m", 5.0, 80.0], ["optic", "row_spacing", 1.1, 3.0], ["receiver", "size_m", 0.3, 6.0]],
}

## The settings rows: {g, k, label, kind (spin|option|check), min, max,
## step, unit, types ([] = all), tip, items (option: table name)}.
const FIELDS := [
	# Optic
	{"g": "optic", "k": "aperture_m", "label": "Diameter", "kind": "spin", "min": 0.05, "max": 20.0, "step": 0.01, "unit": "m",
		"types": ["lens", "ball_lens", "water_lens", "parabolic_dish"], "tip": "Clear aperture across"},
	{"g": "optic", "k": "aperture_m", "label": "Side", "kind": "spin", "min": 0.1, "max": 5.0, "step": 0.01, "unit": "m",
		"types": ["fresnel_lens"], "tip": "Side of the lens sheet (square) or its diameter (round)"},
	{"g": "optic", "k": "square", "label": "Shape", "kind": "check", "text": "Square sheet", "types": ["fresnel_lens"],
		"tip": "A square sheet catches more than the circle inside it; its corners focus worst"},
	{"g": "optic", "k": "profile", "label": "Profile", "kind": "option", "items": "trough_profiles",
		"types": ["parabolic_trough"],
		"tip": "A parabola focuses a sun on its axis to a line; a compound parabolic (CPC) wall accepts every ray within ±half the acceptance angle onto a real-sized tube or flat absorber — little or no tracking, and part of a cloudy sky"},
	{"g": "optic", "k": "aperture_m", "label": "Aperture width", "kind": "spin", "min": 0.2, "max": 10.0, "step": 0.01, "unit": "m",
		"types": ["parabolic_trough"], "profiles": ["parabola"], "tip": "Mirror width across the trough, edge to edge"},
	{"g": "optic", "k": "accept_deg", "label": "Acceptance angle", "kind": "spin", "min": 4.0, "max": 120.0, "step": 0.5, "unit": "°",
		"types": ["parabolic_trough"], "profiles": ["cpc_tube", "cpc_flat"],
		"tip": "The full angle between the two lines of the string drawing: any light within ±half of it lands on the absorber. 20–40° is the rule of thumb — narrower concentrates more for direct sun, wider takes more cloudy sky and needs less re-aiming. Ideal concentration = 1 / sin(half)"},
	{"g": "optic", "k": "truncate", "label": "Truncation", "kind": "spin", "min": 0.0, "max": 0.9, "step": 0.01, "unit": "",
		"types": ["parabolic_trough"], "profiles": ["cpc_tube", "cpc_flat"],
		"tip": "The share of the full height cut off the top. A full CPC is very tall for its last few percent: cutting 40–60 % off saves most of the mirror and loses little light"},
	{"g": "optic", "k": "length_m", "label": "Length", "kind": "spin", "min": 0.5, "max": 150.0, "step": 0.1, "unit": "m",
		"types": ["parabolic_trough", "linear_fresnel"], "tip": "Along the focal line; the ends lose light when the sun is off-axis"},
	{"g": "optic", "k": "focal_m", "label": "Focal length", "kind": "spin", "min": 0.05, "max": 12.0, "step": 0.005, "unit": "m",
		"types": ["lens", "fresnel_lens", "water_lens", "parabolic_trough", "parabolic_dish"], "profiles": ["parabola"],
		"tip": "Mirror: vertex to focus. Lens: the thin-lens focal length at visible light"},
	{"g": "optic", "k": "material", "label": "Material", "kind": "option", "items": "lens_materials",
		"types": ["lens", "ball_lens", "fresnel_lens"], "tip": "Index of refraction and absorption per band"},
	{"g": "optic", "k": "thickness_mm", "label": "Edge thickness", "kind": "spin", "min": 1.0, "max": 60.0, "step": 0.5, "unit": "mm",
		"types": ["lens"], "tip": "The lens's thickness at its rim (the centre adds the sag)"},
	{"g": "optic", "k": "thickness_mm", "label": "Sheet thickness", "kind": "spin", "min": 0.5, "max": 10.0, "step": 0.1, "unit": "mm",
		"types": ["fresnel_lens"]},
	{"g": "optic", "k": "pitch_mm", "label": "Groove pitch", "kind": "spin", "min": 0.1, "max": 5.0, "step": 0.05, "unit": "mm",
		"types": ["fresnel_lens"], "tip": "Finer grooves: thinner sheet, more tips to lose light on"},
	{"g": "optic", "k": "tip_um", "label": "Tip rounding", "kind": "spin", "min": 0.0, "max": 200.0, "step": 1.0, "unit": "µm",
		"types": ["fresnel_lens"], "tip": "Pressed grooves are rounded at tip and valley; that band scatters"},
	{"g": "optic", "k": "base_mm", "label": "Water over the rim", "kind": "spin", "min": 0.0, "max": 200.0, "step": 1.0, "unit": "mm",
		"types": ["water_lens"], "tip": "Depth of water above the membrane's rim (the centre adds the sag)"},
	{"g": "optic", "k": "film_tau", "label": "Film transmittance", "kind": "spin", "min": 0.5, "max": 1.0, "step": 0.01, "unit": "",
		"types": ["water_lens"], "tip": "Each clear sheet the light crosses (cover + membrane)"},
	{"g": "optic", "k": "reflector", "label": "Reflector", "kind": "option", "items": "reflectors",
		"types": ["parabolic_trough", "parabolic_dish", "linear_fresnel", "tower"]},
	{"g": "optic", "k": "rows", "label": "Mirror rows", "kind": "spin", "min": 2, "max": 40, "step": 1, "unit": "",
		"types": ["linear_fresnel"]},
	{"g": "optic", "k": "mirror_w_m", "label": "Row width", "kind": "spin", "min": 0.05, "max": 2.0, "step": 0.01, "unit": "m",
		"types": ["linear_fresnel"]},
	{"g": "optic", "k": "gap_m", "label": "Gap between rows", "kind": "spin", "min": 0.0, "max": 1.0, "step": 0.01, "unit": "m",
		"types": ["linear_fresnel"], "tip": "Wider gaps shade less at low sun but need more ground"},
	{"g": "optic", "k": "curved", "label": "Mirrors", "kind": "check", "text": "Bent to focus", "types": ["linear_fresnel", "tower"],
		"tip": "Each row / heliostat bent (or its facets canted) to a radius twice its distance to the receiver"},
	{"g": "optic", "k": "recv_height_m", "label": "Receiver height", "kind": "spin", "min": 0.5, "max": 20.0, "step": 0.05, "unit": "m",
		"types": ["linear_fresnel"], "tip": "Above the mirror pivots"},
	{"g": "optic", "k": "heliostats", "label": "Heliostats", "kind": "spin", "min": 1, "max": 400, "step": 1, "unit": "",
		"types": ["tower"]},
	{"g": "optic", "k": "helio_w_m", "label": "Heliostat width", "kind": "spin", "min": 0.3, "max": 12.0, "step": 0.05, "unit": "m",
		"types": ["tower"]},
	{"g": "optic", "k": "helio_h_m", "label": "Heliostat height", "kind": "spin", "min": 0.3, "max": 12.0, "step": 0.05, "unit": "m",
		"types": ["tower"]},
	{"g": "optic", "k": "tower_h_m", "label": "Tower height", "kind": "spin", "min": 2.0, "max": 200.0, "step": 0.5, "unit": "m",
		"types": ["tower"], "tip": "Receiver centre above the ground"},
	{"g": "optic", "k": "field", "label": "Field", "kind": "option", "items": "fields", "types": ["tower"],
		"tip": "Poleward of the tower the heliostats face the sun across the tower — the best cosine"},
	{"g": "optic", "k": "first_row_m", "label": "First row radius", "kind": "spin", "min": 1.0, "max": 200.0, "step": 0.5, "unit": "m",
		"types": ["tower"]},
	{"g": "optic", "k": "row_spacing", "label": "Row spacing", "kind": "spin", "min": 1.05, "max": 4.0, "step": 0.05, "unit": "× height",
		"types": ["tower"], "tip": "Radial distance between the staggered rows, in heliostat heights; tighter shades and blocks more"},
	{"g": "optic", "k": "helio_ped_m", "label": "Pivot height", "kind": "spin", "min": 0.5, "max": 8.0, "step": 0.1, "unit": "m",
		"types": ["tower"]},
	# Receiver
	{"g": "receiver", "k": "kind", "label": "Receiver", "kind": "option", "items": "receiver_kinds"},
	{"g": "receiver", "k": "size_m", "label": "Receiver size", "kind": "spin", "min": 0.002, "max": 10.0, "step": 0.001, "unit": "m",
		"tip": "Tube or disc diameter; flat strip / panel width; cavity aperture"},
	{"g": "receiver", "k": "height_m", "label": "Panel height", "kind": "spin", "min": 0.1, "max": 10.0, "step": 0.05, "unit": "m",
		"types": ["tower"]},
	{"g": "receiver", "k": "gap_mm", "label": "Gap to the mirror", "kind": "spin", "min": 0.0, "max": 60.0, "step": 0.5, "unit": "mm",
		"types": ["parabolic_trough"], "profiles": ["cpc_tube"],
		"tip": "The mirror's cusp can't touch a hot pipe (or its glass jacket): the wall is drawn round a circle this much bigger, and light that slips through the gap under the pipe is lost"},
	{"g": "receiver", "k": "offset_m", "label": "Defocus", "kind": "spin", "min": -2.0, "max": 2.0, "step": 0.001, "unit": "m",
		"types": ["lens", "ball_lens", "fresnel_lens", "water_lens", "parabolic_trough", "parabolic_dish"], "profiles": ["parabola"],
		"tip": "Moves the receiver along the optical axis from the design focus (+ toward the optic)"},
	{"g": "receiver", "k": "coating", "label": "Coating", "kind": "option", "items": "coatings",
		"tip": "Absorptance α of sunlight and emittance ε of heat"},
	{"g": "receiver", "k": "envelope", "label": "Glass envelope", "kind": "check", "text": "Evacuated tube",
		"types": ["parabolic_trough", "linear_fresnel"], "tip": "A vacuum jacket: ~4 % of the light, almost no convection"},
	{"g": "receiver", "k": "h_conv", "label": "Convection", "kind": "spin", "min": 0.0, "max": 60.0, "step": 0.5, "unit": "W/m²K",
		"tip": "Heat carried off by the air (≈5 still, 15–30 in wind)"},
	# Tracking
	{"g": "tracking", "k": "mode", "label": "Tracking", "kind": "option", "items": "tracking_modes",
		"types": ["lens", "ball_lens", "fresnel_lens", "water_lens", "parabolic_trough", "parabolic_dish", "linear_fresnel"]},
	{"g": "tracking", "k": "error_mrad", "label": "Tracking error", "kind": "spin", "min": 0.0, "max": 20.0, "step": 0.1, "unit": "mrad",
		"tip": "RMS pointing error of the drive and its sensor"},
	{"g": "tracking", "k": "fixed_tilt_deg", "label": "Fixed tilt", "kind": "spin", "min": 0.0, "max": 90.0, "step": 1.0, "unit": "°",
		"tip": "For a fixed mount; −1 = the latitude"},
	# Structure
	{"g": "structure", "k": "mount", "label": "Mount", "kind": "option", "items": "mounts"},
	{"g": "structure", "k": "material", "label": "Material", "kind": "option", "items": "struct_materials"},
	{"g": "structure", "k": "member_mm", "label": "Main member Ø", "kind": "spin", "min": 20.0, "max": 1500.0, "step": 1.0, "unit": "mm",
		"tip": "Pedestal, torque tube or tower leg outside diameter"},
	{"g": "structure", "k": "wall_mm", "label": "Wall", "kind": "spin", "min": 1.0, "max": 40.0, "step": 0.1, "unit": "mm"},
	{"g": "structure", "k": "pedestal_h_m", "label": "Axis height", "kind": "spin", "min": 0.3, "max": 20.0, "step": 0.05, "unit": "m",
		"types": ["lens", "ball_lens", "fresnel_lens", "water_lens", "parabolic_trough", "parabolic_dish"],
		"tip": "Ground to the tracking axis"},
	{"g": "structure", "k": "pylon_spacing_m", "label": "Pylon spacing", "kind": "spin", "min": 1.0, "max": 20.0, "step": 0.1, "unit": "m",
		"types": ["parabolic_trough", "linear_fresnel"]},
	{"g": "structure", "k": "drive", "label": "Drive", "kind": "option", "items": "drives"},
	{"g": "structure", "k": "wind_op_ms", "label": "Tracking wind", "kind": "spin", "min": 2.0, "max": 30.0, "step": 0.5, "unit": "m/s",
		"tip": "The highest wind it keeps tracking in"},
	{"g": "structure", "k": "wind_survival_ms", "label": "Survival wind", "kind": "spin", "min": 10.0, "max": 70.0, "step": 0.5, "unit": "m/s",
		"tip": "The gust it must survive parked (stowed face-up)"},
	# Trace
	{"g": "trace", "k": "rays", "label": "Rays traced", "kind": "spin", "min": 200, "max": 40000, "step": 100, "unit": "",
		"tip": "More rays: smoother numbers, slower"},
	{"g": "trace", "k": "slope_err_mrad", "label": "Surface error", "kind": "spin", "min": 0.0, "max": 30.0, "step": 0.1, "unit": "mrad",
		"tip": "RMS slope error of the mirror or lens surface (a good mirror 2–3, DIY 6–15)"},
	{"g": "trace", "k": "sun_half_mrad", "label": "Sun half-angle", "kind": "spin", "min": 0.0, "max": 30.0, "step": 0.05, "unit": "mrad",
		"tip": "4.65 mrad: the sun's disc. Raise it to stand in for haze and circumsolar light"},
	# Site
	{"g": "site", "k": "dni_design", "label": "Design DNI", "kind": "spin", "min": 100.0, "max": 1100.0, "step": 10.0, "unit": "W/m²",
		"tip": "Direct normal irradiance the headline numbers are quoted at"},
	{"g": "site", "k": "op_temp_c", "label": "Working temperature", "kind": "spin", "min": 30.0, "max": 1200.0, "step": 5.0, "unit": "°C",
		"tip": "The receiver's temperature while delivering heat (cooking 150, steam 120–250, oil 390)"},
	{"g": "site", "k": "ambient_c", "label": "Air temperature", "kind": "spin", "min": -30.0, "max": 55.0, "step": 1.0, "unit": "°C"},
]


static func default_spec(type: String = "parabolic_dish") -> Dictionary:
	var t := type if TYPES.has(type) else "parabolic_dish"
	var s := {
		"name": str(TYPE_LABELS[t]),
		"type": t,
		"optic": {"aperture_m": 2.0, "length_m": 4.0, "focal_m": 0.9, "material": "low_iron_glass",
			"thickness_mm": 4.0, "pitch_mm": 0.5, "tip_um": 8.0, "square": true,
			"base_mm": 20.0, "film_tau": 0.92, "reflector": "silvered_glass",
			"rows": 10, "mirror_w_m": 0.3, "gap_m": 0.05, "curved": true, "recv_height_m": 3.0,
			"heliostats": 60, "helio_w_m": 2.0, "helio_h_m": 2.0, "tower_h_m": 15.0,
			"field": "poleward", "first_row_m": 8.0, "row_spacing": 1.6, "helio_ped_m": 1.6,
			"profile": "parabola", "accept_deg": 30.0, "truncate": 0.4},
		"receiver": {"kind": "cavity", "size_m": 0.12, "height_m": 1.6, "offset_m": 0.0, "gap_mm": 3.0,
			"coating": "black_paint", "envelope": false, "h_conv": 10.0},
		"tracking": {"mode": "two_axis", "error_mrad": 1.0, "fixed_tilt_deg": -1.0},
		"structure": {"mount": "pedestal_azel", "material": "steel", "member_mm": 114.3, "wall_mm": 4.0,
			"pedestal_h_m": 1.8, "pylon_spacing_m": 4.0, "drive": "auto",
			"wind_op_ms": 12.0, "wind_survival_ms": 35.0},
		"trace": {"rays": 4000, "slope_err_mrad": 3.0, "sun_half_mrad": 4.65, "seed": 7},
		"site": {"dni_design": 900.0, "op_temp_c": 250.0, "ambient_c": 25.0, "lat_deg": 35.0, "lon_deg": -115.0},
	}
	var o: Dictionary = s["optic"]
	var r: Dictionary = s["receiver"]
	var tr: Dictionary = s["tracking"]
	var st: Dictionary = s["structure"]
	var tc: Dictionary = s["trace"]
	var si: Dictionary = s["site"]
	match t:
		"lens":
			o["aperture_m"] = 0.5
			o["focal_m"] = 0.8
			o["material"] = "low_iron_glass"
			o["thickness_mm"] = 4.0
			r["kind"] = "flat"
			r["size_m"] = 0.05
			tc["slope_err_mrad"] = 1.0
			st["member_mm"] = 60.3
			st["wall_mm"] = 3.0
			st["pedestal_h_m"] = 1.4
			si["op_temp_c"] = 150.0
		"ball_lens":
			o["aperture_m"] = 0.3
			o["material"] = "water"
			r["kind"] = "flat"
			r["size_m"] = 0.03
			tc["slope_err_mrad"] = 0.5
			st["member_mm"] = 48.3
			st["wall_mm"] = 3.0
			st["pedestal_h_m"] = 1.1
			si["op_temp_c"] = 120.0
		"fresnel_lens":
			o["aperture_m"] = 1.0
			o["focal_m"] = 1.0
			o["material"] = "acrylic"
			o["thickness_mm"] = 3.0
			r["kind"] = "flat"
			r["size_m"] = 0.05
			tc["slope_err_mrad"] = 2.0
			st["member_mm"] = 76.1
			st["wall_mm"] = 3.0
			st["pedestal_h_m"] = 1.4
			si["op_temp_c"] = 200.0
		"water_lens":
			o["aperture_m"] = 1.0
			o["focal_m"] = 3.0
			r["kind"] = "flat"
			r["size_m"] = 0.1
			tc["slope_err_mrad"] = 4.0
			st["member_mm"] = 114.3
			st["wall_mm"] = 4.0
			st["pedestal_h_m"] = 3.4
			si["op_temp_c"] = 120.0
		"parabolic_trough":
			o["aperture_m"] = 1.5
			o["length_m"] = 4.0
			o["focal_m"] = 0.4
			o["reflector"] = "aluminium"
			r["kind"] = "tube"
			r["size_m"] = 0.035
			r["coating"] = "selective"
			r["envelope"] = true
			tr["mode"] = "ns_horizontal"
			st["mount"] = "torque_tube"
			st["member_mm"] = 88.9
			st["wall_mm"] = 3.2
			st["pedestal_h_m"] = 1.3
			st["pylon_spacing_m"] = 4.0
			tc["slope_err_mrad"] = 4.0
			si["op_temp_c"] = 200.0
		"parabolic_dish":
			pass
		"linear_fresnel":
			o["length_m"] = 8.0
			o["reflector"] = "silvered_glass"
			r["kind"] = "flat"
			r["size_m"] = 0.25
			r["coating"] = "selective"
			r["envelope"] = false
			tr["mode"] = "ew_horizontal"
			st["mount"] = "row_frame"
			st["member_mm"] = 76.1
			st["wall_mm"] = 3.2
			st["pylon_spacing_m"] = 3.0
			tc["slope_err_mrad"] = 3.0
			si["op_temp_c"] = 200.0
		"tower":
			r["kind"] = "flat"
			r["size_m"] = 2.0
			r["height_m"] = 2.0
			r["coating"] = "pyromark"
			tr["mode"] = "two_axis"
			st["mount"] = "lattice_tower"
			st["member_mm"] = 168.3
			st["wall_mm"] = 6.0
			tc["slope_err_mrad"] = 2.5
			tc["rays"] = 6000
			si["op_temp_c"] = 500.0
	return s


## Fill every missing key from the type's defaults and clamp what must be
## sane. Unknown keys are kept.
static func resolve(spec: Dictionary) -> Dictionary:
	var t := str(spec.get("type", "parabolic_dish"))
	if not TYPES.has(t):
		t = "parabolic_dish"
	var base := default_spec(t)
	var out := base.duplicate(true)
	for k in spec:
		var v: Variant = spec[k]
		if v is Dictionary and out.get(k) is Dictionary:
			var dst: Dictionary = out[k]
			for kk in (v as Dictionary):
				dst[kk] = (v as Dictionary)[kk]
		else:
			out[k] = v
	out["type"] = t
	var o: Dictionary = out["optic"]
	o["rows"] = clampi(int(o["rows"]), 1, 60)
	o["heliostats"] = clampi(int(o["heliostats"]), 1, 600)
	o["aperture_m"] = maxf(float(o["aperture_m"]), 0.02)
	o["focal_m"] = maxf(float(o["focal_m"]), 0.02)
	var r: Dictionary = out["receiver"]
	r["size_m"] = maxf(float(r["size_m"]), 0.001)
	var tr: Dictionary = out["trace"]
	tr["rays"] = clampi(int(tr["rays"]), 50, 60000)
	tr["seed"] = int(tr.get("seed", 7))
	# A tower field tracks per heliostat; a linear Fresnel field turns its
	# rows about one horizontal axis.
	if t == "parabolic_trough":
		var prof := str(o.get("profile", "parabola"))
		if not TROUGH_PROFILES.has(prof):
			prof = "parabola"
			o["profile"] = prof
		if prof == "cpc_tube":
			r["kind"] = "tube"
		elif prof == "cpc_flat":
			r["kind"] = "flat"
		o["accept_deg"] = clampf(float(o.get("accept_deg", 30.0)), 2.0, 170.0)
		o["truncate"] = clampf(float(o.get("truncate", 0.0)), 0.0, 0.95)
	var tk: Dictionary = out["tracking"]
	if t == "tower":
		tk["mode"] = "two_axis"
	elif t == "linear_fresnel" and not ["ns_horizontal", "ew_horizontal"].has(str(tk["mode"])):
		tk["mode"] = "ns_horizontal"
	return out


## Rows that apply to a type.
static func field_shown(f: Dictionary, type: String, spec: Dictionary = {}) -> bool:
	var ts: Array = f.get("types", []) as Array
	if not ts.is_empty() and not ts.has(type):
		return false
	var ps: Array = f.get("profiles", []) as Array
	if ps.is_empty() or spec.is_empty():
		return true
	return ps.has(profile_of(spec))


## A trough's profile ("parabola" for every other type).
static func profile_of(spec: Dictionary) -> String:
	if str(spec.get("type", "")) != "parabolic_trough":
		return "parabola"
	return str((spec.get("optic", {}) as Dictionary).get("profile", "parabola"))


## The optimizer's parameters for a design (a CPC varies its acceptance and
## truncation instead of a focal length).
static func opt_params(spec: Dictionary) -> Array:
	var t := str(spec.get("type", ""))
	var prof := profile_of(spec)
	if prof == "cpc_tube":
		return [["optic", "accept_deg", 8.0, 90.0], ["optic", "truncate", 0.0, 0.8], ["receiver", "gap_mm", 0.0, 20.0]]
	if prof == "cpc_flat":
		return [["optic", "accept_deg", 8.0, 90.0], ["optic", "truncate", 0.0, 0.8]]
	return OPT_PARAMS.get(t, []) as Array


## The option items a field draws from: [[meta, label], …].
static func items_for(table: String, type: String) -> Array:
	match table:
		"lens_materials":
			return CspLabParts.items(CspLabParts.LENS_MATERIALS)
		"reflectors":
			return CspLabParts.items(CspLabParts.REFLECTORS)
		"coatings":
			return CspLabParts.items(CspLabParts.COATINGS)
		"struct_materials":
			return CspLabParts.items(CspLabParts.STRUCT_MATERIALS)
		"receiver_kinds":
			var out: Array = []
			for k in RECEIVER_KINDS:
				if k == "tube" and FOCUS[type] != "line" and type != "tower":
					continue
				out.append([k, "External cylinder" if (k == "tube" and type == "tower") else str(RECEIVER_KINDS[k])])
			return out
		"tracking_modes":
			var out: Array = []
			for k in TRACKING_MODES:
				if type == "linear_fresnel" and not ["ns_horizontal", "ew_horizontal"].has(k):
					continue
				out.append([k, str(TRACKING_MODES[k])])
			return out
		"mounts":
			var allowed := mounts_for(type)
			var out: Array = []
			for k in allowed:
				out.append([k, str(MOUNTS[k])])
			return out
		"drives":
			var out: Array = [["auto", "Smallest that holds"]]
			for dv in CspLabParts.DRIVES:
				out.append([str((dv as Dictionary)["id"]), str((dv as Dictionary)["label"])])
			return out
		"fields":
			return [["poleward", "Poleward of the tower"], ["surround", "All round"]]
		"trough_profiles":
			var out2: Array = []
			for k in TROUGH_PROFILES:
				out2.append([k, str(TROUGH_PROFILES[k])])
			return out2
	return []


static func mounts_for(type: String) -> Array:
	match type:
		"parabolic_trough":
			return ["torque_tube"]
		"linear_fresnel":
			return ["row_frame"]
		"tower":
			return ["lattice_tower", "monopole"]
	return ["pedestal_azel", "polar_mount"]


## A stable key for caches: rounded numbers, JSON (a float that went
## through a save comes back as 609.5999999 and must not miss the cache).
static func key_of(spec: Dictionary) -> String:
	return JSON.stringify(_rounded(spec), "", true)


static func _rounded(v: Variant) -> Variant:
	if v is Dictionary:
		var out := {}
		for k in (v as Dictionary):
			out[k] = _rounded((v as Dictionary)[k])
		return out
	if v is Array:
		var out: Array = []
		for x in (v as Array):
			out.append(_rounded(x))
		return out
	if v is float:
		var f := snappedf(float(v), 0.00001)
		return int(f) if is_equal_approx(f, roundf(f)) and absf(f) < 1e12 else f
	return v


static func to_json_safe(spec: Dictionary) -> Dictionary:
	return _rounded(resolve(spec)) as Dictionary
