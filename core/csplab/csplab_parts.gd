class_name CspLabParts
extends RefCounted

## The tables the concentrator designer reads: lens materials (refractive
## index and absorption per solar band), reflectors, receiver coatings,
## structural materials and tracking drives. Every number carries its source
## or says it is an estimate.

## The direct solar spectrum cut into four bands. Weights are the energy
## fractions of the ASTM G173 direct + circumsolar spectrum (AM1.5D), read
## off the integrated table and rounded — estimates good to a couple of
## percent. A ray carries ONE band, so a lens's dispersion and a water
## lens's infrared absorption fall out of the trace itself.
const BANDS := [
	{"id": "vis", "label": "300–700 nm", "w": 0.43, "nm": 550.0, "color": Color(1.0, 0.86, 0.30)},
	{"id": "nir1", "label": "700–1000 nm", "w": 0.24, "nm": 850.0, "color": Color(1.0, 0.52, 0.20)},
	{"id": "nir2", "label": "1000–1400 nm", "w": 0.16, "nm": 1200.0, "color": Color(0.92, 0.28, 0.20)},
	{"id": "swir", "label": "1400–2500 nm", "w": 0.17, "nm": 1800.0, "color": Color(0.62, 0.18, 0.34)},
]

## Lens materials. `n` per band: Sellmeier / Cauchy fits at the band centre
## (soda-lime float glass: Rubin 1985; N-BK7: Schott data sheet; PMMA:
## Sultanova et al. 2009; water: Hale & Querry 1973). `alpha_cm` = the
## absorption coefficient per band in 1/cm — band averages, ESTIMATES read off
## the same sources (water's infrared absorption is the strong one: almost
## everything past 1.4 µm is gone in the first centimetre). `density` kg/m³.
const LENS_MATERIALS := {
	"low_iron_glass": {"label": "Low-iron glass", "n": [1.522, 1.512, 1.507, 1.500],
		"alpha_cm": [0.002, 0.004, 0.006, 0.02], "density": 2500.0,
		"why": "Solar glass: clear into the infrared, heavy, lasts outdoors."},
	"float_glass": {"label": "Float glass (green edge)", "n": [1.522, 1.512, 1.507, 1.500],
		"alpha_cm": [0.02, 0.06, 0.08, 0.06], "density": 2500.0,
		"why": "Window glass: its iron absorbs a few percent of the near infrared per cm."},
	"bk7": {"label": "Optical glass (BK7)", "n": [1.519, 1.510, 1.505, 1.498],
		"alpha_cm": [0.001, 0.002, 0.004, 0.02], "density": 2510.0,
		"why": "Precision optics: clear, expensive in large sizes."},
	"acrylic": {"label": "Acrylic (PMMA)", "n": [1.494, 1.485, 1.481, 1.477],
		"alpha_cm": [0.002, 0.02, 0.15, 1.5], "density": 1190.0,
		"why": "What Fresnel lenses are pressed from: light, scratches, yellows in years of UV."},
	"water": {"label": "Water", "n": [1.334, 1.329, 1.325, 1.318],
		"alpha_cm": [0.0006, 0.08, 1.2, 25.0], "density": 1000.0,
		"why": "Free and self-levelling, but it drinks the infrared: a thick water lens loses about a fifth of the sun."},
}

## Reflectors: specular reflectance (solar-weighted) and mass per m² with
## its backing. Silvered glass 0.93–0.95 (NREL SolarPACES reflectance
## guideline, 2013); polished aluminium sheet 0.85–0.88 (Alanod MIRO
## data sheet); aluminised film on a backing 0.86–0.90 (3M SMF-1100);
## mirror-polished stainless ~0.6 (estimate).
const REFLECTORS := {
	"silvered_glass": {"label": "Silvered glass mirror", "rho": 0.94, "kg_m2": 10.0,
		"why": "The utility standard: highest and steadiest reflectance, heavy."},
	"thin_glass": {"label": "Thin glass mirror (1 mm)", "rho": 0.94, "kg_m2": 3.5,
		"why": "Bends to a trough or dish; needs a stiff backing."},
	"aluminium": {"label": "Polished aluminium sheet", "rho": 0.86, "kg_m2": 2.7,
		"why": "Bendable, cheap, light; loses a few points to haze and scratches."},
	"film": {"label": "Aluminised film on a backing", "rho": 0.88, "kg_m2": 4.0,
		"why": "Mylar-style film on plywood or foam: DIY-friendly, lasts a few seasons."},
	"stainless": {"label": "Polished stainless steel", "rho": 0.62, "kg_m2": 8.0,
		"why": "Tough, but a poor mirror."},
}

## Receiver coatings: solar absorptance α and thermal emittance ε. Black
## paint (estimate); selective cermet α 0.95 / ε 0.10 near 400 °C
## (Forristall 2003, NREL/TP-550-34169); Pyromark 2500 (Ho et al. 2014);
## black enamel cookware (estimate).
const COATINGS := {
	"black_paint": {"label": "Black high-temp paint", "alpha": 0.95, "eps": 0.88},
	"selective": {"label": "Selective cermet", "alpha": 0.95, "eps": 0.10},
	"pyromark": {"label": "Pyromark 2500", "alpha": 0.95, "eps": 0.85},
	"enamel": {"label": "Black enamel (cookware)", "alpha": 0.92, "eps": 0.90},
	"bare_steel": {"label": "Bare steel", "alpha": 0.60, "eps": 0.30},
}

## Structural materials. E (Pa), design yield fy (Pa), density (kg/m³).
## S235 steel (EN 1993); 6061-T6 aluminium (ASM); softwood timber in
## bending, design value ~20 MPa (estimate after EN 338 C24 with factors).
const STRUCT_MATERIALS := {
	"steel": {"label": "Steel tube", "E": 200.0e9, "G": 79.0e9, "fy": 235.0e6, "density": 7850.0},
	"aluminium": {"label": "Aluminium 6061 tube", "E": 69.0e9, "G": 26.0e9, "fy": 240.0e6, "density": 2700.0},
	"timber": {"label": "Timber (C24)", "E": 11.0e9, "G": 0.69e9, "fy": 20.0e6, "density": 420.0},
}

## Tracking drives: output torque while turning and holding torque when
## parked (N·m), the slew drives after typical SE-series listings (Kinematics
## / H-Fang catalogues — estimates, check the real part).
const DRIVES := [
	{"id": "worm_hand", "label": "Hand-crank worm gear", "turn_nm": 120.0, "hold_nm": 400.0, "kg": 4.0, "powered": false},
	{"id": "actuator", "label": "12 V linear actuator (6 kN)", "turn_nm": 300.0, "hold_nm": 900.0, "kg": 3.0, "powered": true},
	{"id": "se3", "label": "Slew drive 3″", "turn_nm": 400.0, "hold_nm": 1600.0, "kg": 9.0, "powered": true},
	{"id": "se5", "label": "Slew drive 5″", "turn_nm": 600.0, "hold_nm": 5500.0, "kg": 16.0, "powered": true},
	{"id": "se7", "label": "Slew drive 7″", "turn_nm": 1500.0, "hold_nm": 13500.0, "kg": 28.0, "powered": true},
	{"id": "se9", "label": "Slew drive 9″", "turn_nm": 3300.0, "hold_nm": 33800.0, "kg": 50.0, "powered": true},
	{"id": "se12", "label": "Slew drive 12″", "turn_nm": 4000.0, "hold_nm": 54000.0, "kg": 72.0, "powered": true},
	{"id": "se17", "label": "Slew drive 17″", "turn_nm": 8000.0, "hold_nm": 110000.0, "kg": 140.0, "powered": true},
	{"id": "se25", "label": "Slew drive 25″", "turn_nm": 15000.0, "hold_nm": 230000.0, "kg": 290.0, "powered": true},
]


static func band(i: int) -> Dictionary:
	return BANDS[clampi(i, 0, BANDS.size() - 1)] as Dictionary


static func lens_material(id: String) -> Dictionary:
	return LENS_MATERIALS.get(id, LENS_MATERIALS["acrylic"]) as Dictionary


static func reflector(id: String) -> Dictionary:
	return REFLECTORS.get(id, REFLECTORS["silvered_glass"]) as Dictionary


static func coating(id: String) -> Dictionary:
	return COATINGS.get(id, COATINGS["black_paint"]) as Dictionary


static func struct_material(id: String) -> Dictionary:
	return STRUCT_MATERIALS.get(id, STRUCT_MATERIALS["steel"]) as Dictionary


## Index of refraction of a lens material in a band.
static func n_of(material: String, band_i: int) -> float:
	var arr: Array = lens_material(material)["n"] as Array
	return float(arr[clampi(band_i, 0, arr.size() - 1)])


static func alpha_of(material: String, band_i: int) -> float:
	var arr: Array = lens_material(material)["alpha_cm"] as Array
	return float(arr[clampi(band_i, 0, arr.size() - 1)])


## The smallest drive whose holding torque covers `hold_nm` and turning
## torque covers `turn_nm` (the last one when nothing does).
static func pick_drive(turn_nm: float, hold_nm: float) -> Dictionary:
	for dv in DRIVES:
		var d: Dictionary = dv
		if float(d["turn_nm"]) >= turn_nm and float(d["hold_nm"]) >= hold_nm:
			return d
	return DRIVES[DRIVES.size() - 1] as Dictionary


static func items(table: Dictionary) -> Array:
	var out: Array = []
	for k in table:
		out.append([k, str((table[k] as Dictionary)["label"])])
	return out
