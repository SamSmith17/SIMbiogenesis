class_name PackedSpec
extends RefCounted
## Packed ("shipping") dimensions + mass for anything that occupies physical
## space — PACKING_PLAN.md Phase 0. The packed spec answers: how big and how
## heavy is this thing in its most-compact transportable form (folded,
## disassembled, stacked, crated)?
##
## One schema, three producers, one resolver:
##   1. CURATED — real product shipping specs (table below, or a `packed`
##      dict on a ModelCatalog entry / preset `specs`). Strongest.
##   2. COMPUTED — procedural builders derive it from their own parameters
##      (LinkageStructureBuilder.packed_spec_for solves at the effective
##      minimum fold angle — see PACKING_PLAN.md Phase 0.5).
##   3. ESTIMATED — heuristics from the deployed envelope or type specs.
##      Weakest, marked so UI can show "(est.)". Guarantees 100% coverage.
##
## Dims are METRES internally (project convention); display goes through
## format_dims() in feet/inches (the audience packs U-Hauls, not TEUs).
## Unless `this_side_up`, dims are canonicalized w >= d >= h ("lying flat" —
## packed units are orientation-free until a constraint says otherwise).
## `mass_kg` is first-class from Phase 0 (decided 2026-08-03); -1.0 is the
## JSON-safe "unknown" sentinel (NAN does not survive JSON round-trips).

const MASS_UNKNOWN := -1.0

## Mass/volume heuristic constants — cited, not invented:
## SPF construction lumber ~450-500 kg/m³ at 12% MC (USDA FPL Wood Handbook,
## spruce-pine-fir SG ~0.42).
const WOOD_KG_M3 := 470.0
## Rigid glass Si PV module: ~19 W/kg, ~205 W/m² (e.g. REC Alpha 410W:
## 1.95 m², 21.5 kg — datasheet).
const PANEL_RIGID_W_PER_KG := 19.0
const PANEL_W_PER_M2 := 205.0
const PANEL_ASPECT := 1.6          # long/short edge, typical 60/72-cell
const PANEL_PACKED_THICK_M := 0.045  # module + packaging
## Flexible / CIGS module: ~45 W/kg (e.g. 100 W flex ≈ 2.2 kg — datasheet).
const PANEL_FLEX_W_PER_KG := 45.0
## Pack-level energy density (commercial, not cell-level):
## LiFePO4 ~90 Wh/kg / ~110 Wh/L; AGM/SLA ~40 Wh/kg / ~80 Wh/L.
const LFP_WH_PER_KG := 90.0
const LFP_WH_PER_L := 110.0
const SLA_WH_PER_KG := 40.0
const SLA_WH_PER_L := 80.0
## Boxed power electronics bulk density (controller in carton) ~250 kg/m³.
const ELECTRONICS_KG_M3 := 250.0
## Rotomolded HDPE tank: ~0.07 kg per litre of capacity (250 gal ≈ 65 kg).
const TANK_KG_PER_L := 0.07

const FORMS := ["crate", "bundle", "roll", "pallet", "panel_stack", "folded",
	"tank", "loose", "container"]

## Curated packed specs for shipped ModelCatalog ids. `source: "curated"` =
## a real product's published shipping spec; `"estimated"` = a considered
## guess pending measurement. Every structures/tools model MUST appear here,
## in DYNAMIC_MODELS, or in NON_PACKABLE — packing_selftest enforces it, so
## adding a model forces a packing decision.
const CURATED_MODELS := {
	# Shiftpod 2: carry bag ~52x33x26", ship weight ~75 lb.
	"shiftpod": {"w_m": 1.32, "d_m": 0.84, "h_m": 0.66, "mass_kg": 34.0,
		"form": "bundle", "source": "curated"},
	# 10x20 carport kit: frame-tube bundles + canopy cartons.
	"carport": {"w_m": 1.95, "d_m": 0.35, "h_m": 0.30, "mass_kg": 60.0,
		"form": "bundle", "source": "estimated"},
	# 10x10 EZ-UP in roller bag: ~63x12x12", ~60 lb.
	"ez_up": {"w_m": 1.60, "d_m": 0.30, "h_m": 0.30, "mass_kg": 27.0,
		"form": "bundle", "source": "curated"},
	# Static StarShade GLB exports: folded scissor + hardware on a 4'x8'
	# footprint. Live Linkage Lab designs compute theirs instead (see
	# DYNAMIC_MODELS); these statics get the family-typical envelope.
	"starshade": {"w_m": 2.44, "d_m": 1.22, "h_m": 0.61, "mass_kg": 200.0,
		"form": "folded", "source": "estimated"},
	"starshade_center_camp": {"w_m": 2.44, "d_m": 1.22, "h_m": 0.90,
		"mass_kg": 400.0, "form": "folded", "source": "estimated"},
	"starshade_man_effigy": {"w_m": 2.44, "d_m": 1.22, "h_m": 0.75,
		"mass_kg": 300.0, "form": "folded", "source": "estimated"},
	# Pallet racking knocks down flat: upright frames + beam bundle + plywood
	# stack. TODO(Phase 2): compute from the rack_spec part counts instead.
	"pallet_rack": {"w_m": 2.70, "d_m": 1.00, "h_m": 0.75, "mass_kg": 350.0,
		"form": "bundle", "source": "estimated"},
	"grow_bed": {"w_m": 1.25, "d_m": 0.65, "h_m": 0.35, "mass_kg": 30.0,
		"form": "crate", "source": "estimated"},
	# Single bed knocks down: frame flat-pack + rolled mattress.
	"bed": {"w_m": 2.05, "d_m": 0.95, "h_m": 0.35, "mass_kg": 32.0,
		"form": "bundle", "source": "estimated"},
	# 1 kW-class VAWT: mast sections + rotor blades + genny, disassembled.
	"vawt": {"w_m": 3.20, "d_m": 0.80, "h_m": 0.80, "mass_kg": 220.0,
		"form": "bundle", "source": "estimated"},
	# ~12 m trough module: mirror segments + frame on a long pallet.
	"csp_trough": {"w_m": 4.00, "d_m": 1.30, "h_m": 1.10, "mass_kg": 750.0,
		"form": "pallet", "source": "estimated"},
	# Air 30-class turbine (~6 kg boxed) + 9 m mast kit bundle.
	"small_hawt": {"w_m": 2.90, "d_m": 0.40, "h_m": 0.35, "mass_kg": 55.0,
		"form": "bundle", "source": "estimated"},
	"hydroturbine": {"w_m": 1.20, "d_m": 0.60, "h_m": 0.60, "mass_kg": 45.0,
		"form": "crate", "source": "estimated"},
	# PowerSpout PLT: a pico-hydro unit ships as one ~20 kg carton (the machine
	# itself measures ~0.35 × 0.38 × 0.59 m — see the ModelCatalog entry).
	"powerspout_plt": {"w_m": 0.62, "d_m": 0.42, "h_m": 0.42, "mass_kg": 20.0,
		"form": "crate", "source": "estimated"},
	# AliExpress micro Pelton: a 0.25 m plate + housing with a Nema 34 stepper
	# (~5 kg on its own) hung underneath; ships boxed at ~8 kg.
	"ali_pelton": {"w_m": 0.32, "d_m": 0.32, "h_m": 0.24, "mass_kg": 8.0,
		"form": "crate", "source": "estimated"},
	# Firepit: a 1.1 m steel ring, ~35 kg, ships as itself (logs not included).
	"firepit": {"w_m": 1.12, "d_m": 1.12, "h_m": 0.38, "mass_kg": 35.0,
		"form": "crate", "source": "estimated"},
	# Stream intake sump: a small precast/HDPE box with a screen. Ships as one
	# awkward-but-light unit (~0.7 × 0.5 × 0.42 m body).
	"stream_intake": {"w_m": 0.74, "d_m": 0.56, "h_m": 0.46, "mass_kg": 28.0,
		"form": "crate", "source": "estimated"},
	# ~5 m dish heliostat: petals + mast + drives, palletized.
	"heliostat": {"w_m": 2.60, "d_m": 1.60, "h_m": 0.90, "mass_kg": 420.0,
		"form": "pallet", "source": "estimated"},
	# HomeBiogas 2.0 ships folded in cartons, ~37 kg total (manufacturer).
	"home_biogas_2": {"w_m": 1.20, "d_m": 0.42, "h_m": 0.42, "mass_kg": 37.0,
		"form": "crate", "source": "curated"},
	"cnc_router": {"w_m": 1.60, "d_m": 1.40, "h_m": 0.55, "mass_kg": 180.0,
		"form": "pallet", "source": "estimated"},
	"trash_printer": {"w_m": 1.10, "d_m": 0.80, "h_m": 0.60, "mass_kg": 80.0,
		"form": "crate", "source": "estimated"},
	# Gantry mud printer disassembles into rails + gantry + pump skid.
	"mud_printer": {"w_m": 3.90, "d_m": 1.20, "h_m": 0.90, "mass_kg": 600.0,
		"form": "bundle", "source": "estimated"},
	# Precious Plastic machines: heavy welded frames, ship on pallets.
	"pp_shredder": {"w_m": 0.90, "d_m": 0.60, "h_m": 0.70, "mass_kg": 95.0,
		"form": "pallet", "source": "estimated"},
	"pp_beam_extruder": {"w_m": 1.60, "d_m": 0.60, "h_m": 0.80,
		"mass_kg": 160.0, "form": "pallet", "source": "estimated"},
	"pp_sheet_press": {"w_m": 1.30, "d_m": 1.10, "h_m": 0.90,
		"mass_kg": 250.0, "form": "pallet", "source": "estimated"},
	# Dome kit = strut bundle + hub bag + skin roll.
	"geodesic_dome": {"w_m": 2.20, "d_m": 0.50, "h_m": 0.50, "mass_kg": 120.0,
		"form": "bundle", "source": "estimated"},
}

## Models whose packed spec is COMPUTED from live parameters — resolve via the
## owning builder, not this table (for_model returns its catalog fallback only
## when no live spec is available).
const DYNAMIC_MODELS := {
	# A palletised module stack + racking for the default 9-module array
	# (1.77 × 1.05 m modules, ~21 kg each, plus ~60 kg of rails and legs).
	"pv_array": {"w_m": 1.80, "d_m": 1.10, "h_m": 0.55,
		"mass_kg": 250.0, "form": "panel_stack", "source": "estimated"},
	"linkage_structure": {"w_m": 2.44, "d_m": 1.22, "h_m": 0.45,
		"mass_kg": 150.0, "form": "folded", "source": "estimated"},
	# Slotted plywood furniture packs as a flat stack of its parts; the real
	# spec is FlatpackDesign.packed_spec (the record's flatpack_spec). This
	# fallback is the default sofa: 12 parts of 1/2" ply, ~62 kg.
	"flatpack_furniture": {"w_m": 2.44, "d_m": 0.90, "h_m": 0.15,
		"mass_kg": 62.0, "form": "panel_stack", "source": "estimated"},
	# Real spec comes from ContainerCatalog.packed_spec_for(container_id)
	# (the drawer resolves the record's container_spec); this fallback is the
	# 20' box (ISO 668 exterior + tare).
	"cargo_container": {"w_m": 6.058, "d_m": 2.438, "h_m": 2.591,
		"mass_kg": 2300.0, "form": "container", "source": "curated",
		"this_side_up": true},
}

## Physical-but-not-packable, with the reason (surfaced in UI/selftest).
const NON_PACKABLE := {
	"pine_1": "living tree",
	"generic_box": "abstract placeholder — the graph node's preset packs",
	"generic_tank": "abstract placeholder — the graph node's preset packs",
	"mud_building": "built in place from site material",
}


static func defaults() -> Dictionary:
	return {
		"w_m": 0.0, "d_m": 0.0, "h_m": 0.0,
		"form": "crate",
		"mass_kg": MASS_UNKNOWN,
		"stackable": true,
		"max_stack_kg": MASS_UNKNOWN,
		"this_side_up": false,
		"count": 1,
		"source": "estimated",
		"contains": [],
	}


## Merge over defaults, clamp, and (unless this_side_up) canonicalize dims
## w >= d >= h. Returns {} for an empty/degenerate input.
static func normalize(raw: Dictionary) -> Dictionary:
	if raw.is_empty():
		return {}
	var out := defaults()
	for k in raw:
		out[k] = raw[k]
	var dims := [maxf(float(out["w_m"]), 0.0), maxf(float(out["d_m"]), 0.0),
		maxf(float(out["h_m"]), 0.0)]
	if float(dims[0]) <= 0.0 or float(dims[1]) <= 0.0 or float(dims[2]) <= 0.0:
		return {}
	if not bool(out["this_side_up"]):
		dims.sort()
		dims.reverse()
	out["w_m"] = float(dims[0])
	out["d_m"] = float(dims[1])
	out["h_m"] = float(dims[2])
	if not FORMS.has(str(out["form"])):
		out["form"] = "crate"
	out["count"] = maxi(int(out["count"]), 1)
	var m := float(out["mass_kg"])
	out["mass_kg"] = m if m > 0.0 else MASS_UNKNOWN
	return out


## Packed spec for a ModelCatalog id. Order: `packed` dict on the catalog
## entry (user curation) > CURATED_MODELS > DYNAMIC_MODELS fallback >
## estimate from a caller-supplied deployed AABB size > {} (unknown).
## NON_PACKABLE ids always return {}.
static func for_model(model_id: String, deployed_size: Vector3 = Vector3.ZERO) -> Dictionary:
	if model_id.is_empty() or NON_PACKABLE.has(model_id):
		return {}
	var entry := ModelCatalog.find(model_id)
	var curated = entry.get("packed")
	if curated is Dictionary and not (curated as Dictionary).is_empty():
		var c := (curated as Dictionary).duplicate()
		if not c.has("source"):
			c["source"] = "curated"
		return normalize(c)
	if CURATED_MODELS.has(model_id):
		return normalize((CURATED_MODELS[model_id] as Dictionary).duplicate())
	if DYNAMIC_MODELS.has(model_id):
		return normalize((DYNAMIC_MODELS[model_id] as Dictionary).duplicate())
	if deployed_size != Vector3.ZERO:
		return estimate_from_deployed(deployed_size)
	return {}


## True when a catalog id has a declared packing story (curated, dynamic, or
## explicitly non-packable). The selftest sweeps structures/tools models
## through this so a new model cannot ship without a packing decision.
static func model_packing_known(model_id: String) -> bool:
	return CURATED_MODELS.has(model_id) or DYNAMIC_MODELS.has(model_id) \
		or NON_PACKABLE.has(model_id)


## Packed spec for a graph component preset (type + specs), the second
## producer: curated `packed` block on specs wins, then per-type derivation.
## Abstract types (pbi/catchment/compound/plant/...) return {} — a compound's
## packed form is the sum of its children (PACKING_PLAN.md Phase 3).
static func for_preset_specs(type: String, specs: Dictionary) -> Dictionary:
	var curated = specs.get("packed")
	if curated is Dictionary and not (curated as Dictionary).is_empty():
		var c := (curated as Dictionary).duplicate()
		if not c.has("source"):
			c["source"] = "curated"
		return normalize(c)
	match type:
		"panel":
			return _derive_panel(specs)
		"battery", "smartbattery":
			return _derive_battery(specs)
		"controller":
			return _derive_controller(specs)
		"appliance", "acload":
			return _derive_appliance(specs)
		"processor":
			return _derive_processor(specs)
		"resource":
			return _derive_resource(specs)
		"wind":
			return _derive_wind(specs)
		"hydro":
			return normalize({"w_m": 0.80, "d_m": 0.50, "h_m": 0.50,
				"mass_kg": 40.0, "form": "crate", "source": "estimated"})
		"shelly4pm":
			return normalize({"w_m": 0.12, "d_m": 0.10, "h_m": 0.05,
				"mass_kg": 0.4, "form": "crate", "source": "estimated"})
	return {}


## Estimate a packed envelope from a deployed AABB size. Form hints:
## "rigid" — ships at deployed size (appliances, tanks, machines);
## "frame" — pole/frame structure that knocks down to a bundle;
## default — generic disassembly shrink.
static func estimate_from_deployed(size: Vector3, form_hint: String = "") -> Dictionary:
	var dims := [absf(size.x), absf(size.y), absf(size.z)]
	dims.sort()
	dims.reverse()
	var lmax := maxf(float(dims[0]), 0.05)
	var lmid := maxf(float(dims[1]), 0.05)
	var lmin := maxf(float(dims[2]), 0.05)
	match form_hint:
		"rigid":
			return normalize({"w_m": lmax, "d_m": lmid, "h_m": lmin,
				"form": "crate", "source": "estimated"})
		"frame":
			return normalize({
				"w_m": maxf(lmax * 0.6, 0.3),
				"d_m": maxf(lmid * 0.2, 0.15),
				"h_m": maxf(lmin * 0.2, 0.15),
				"form": "bundle", "source": "estimated"})
	return normalize({"w_m": maxf(lmax * 0.7, 0.2), "d_m": maxf(lmid * 0.7, 0.2),
		"h_m": maxf(lmin * 0.7, 0.2), "form": "crate", "source": "estimated"})


static func volume_m3(spec: Dictionary) -> float:
	if spec.is_empty():
		return 0.0
	return float(spec.get("w_m", 0.0)) * float(spec.get("d_m", 0.0)) \
		* float(spec.get("h_m", 0.0))


static func has_mass(spec: Dictionary) -> bool:
	return float(spec.get("mass_kg", MASS_UNKNOWN)) > 0.0


## Display: ft/in (the audience packs box trucks), metric in parens.
## e.g. `8' × 4' × 18" (2.44 × 1.22 × 0.46 m)`.
static func format_dims(spec: Dictionary) -> String:
	if spec.is_empty():
		return "—"
	var w := float(spec.get("w_m", 0.0))
	var d := float(spec.get("d_m", 0.0))
	var h := float(spec.get("h_m", 0.0))
	return "%s × %s × %s (%.2f × %.2f × %.2f m)" % [
		_ft_in(w), _ft_in(d), _ft_in(h), w, d, h]


## Compact ft/in-only form for narrow value columns (inspector rows clip the
## full metric-parens string): e.g. `8' × 4' × 18"`.
static func format_dims_short(spec: Dictionary) -> String:
	if spec.is_empty():
		return "—"
	return "%s × %s × %s" % [_ft_in(float(spec.get("w_m", 0.0))),
		_ft_in(float(spec.get("d_m", 0.0))), _ft_in(float(spec.get("h_m", 0.0)))]


static func format_mass(spec: Dictionary) -> String:
	var m := float(spec.get("mass_kg", MASS_UNKNOWN))
	if m <= 0.0:
		return "—"
	return "%.0f kg (%.0f lb)" % [m, m * 2.20462]


static func _ft_in(metres: float) -> String:
	var inches := metres / 0.0254
	if metres < 0.9144:  # under 3 ft reads better in inches
		return "%.0f\"" % inches
	var feet := inches / 12.0
	if absf(feet - roundf(feet)) < 0.05:
		return "%.0f'" % roundf(feet)
	return "%.1f'" % feet


# ---------------------------------------------------------------------------
# Per-type derivations (all `source: "estimated"`)
# ---------------------------------------------------------------------------

static func _derive_panel(specs: Dictionary) -> Dictionary:
	var w := maxf(float(specs.get("wmp", 0.0)), 1.0)
	var name := (str(specs.get("name", "")) + " ").to_lower()
	var flexible := name.contains("flex") or name.contains("cigs")
	var area := w / PANEL_W_PER_M2
	var long_edge := sqrt(area * PANEL_ASPECT)
	var short_edge := area / long_edge
	var mass := w / (PANEL_FLEX_W_PER_KG if flexible else PANEL_RIGID_W_PER_KG)
	var thick := 0.02 if flexible else PANEL_PACKED_THICK_M
	return normalize({"w_m": long_edge, "d_m": short_edge, "h_m": thick,
		"mass_kg": mass, "form": "panel_stack", "source": "estimated",
		# A glass module survives stacking flat but never point loads.
		"stackable": true, "this_side_up": false})


static func _derive_battery(specs: Dictionary) -> Dictionary:
	var kwh := maxf(float(specs.get("kwh", 0.0)), 0.05)
	var wh := kwh * 1000.0
	var lfp := str(specs.get("chemistry", "LFP")).to_upper() != "SLA"
	var mass := wh / (LFP_WH_PER_KG if lfp else SLA_WH_PER_KG)
	var vol_l := wh / (LFP_WH_PER_L if lfp else SLA_WH_PER_L)
	# Box aspect ~1.5 : 1.1 : 1 (typical 12 V case), scaled to volume.
	var unit := pow(vol_l / 1000.0 / (1.5 * 1.1), 1.0 / 3.0)
	return normalize({"w_m": 1.5 * unit, "d_m": 1.1 * unit, "h_m": unit,
		"mass_kg": mass, "form": "crate", "source": "estimated",
		"this_side_up": true, "max_stack_kg": mass * 2.0})


static func _derive_controller(specs: Dictionary) -> Dictionary:
	var name := str(specs.get("name", "")).to_lower()
	var pv_w := float(specs.get("max_pv_watts", 0.0))
	var amps := float(specs.get("max_charge_amps", 0.0))
	var hybrid := name.contains("hybrid") or name.contains("inverter") \
		or specs.has("overload_watts") or pv_w >= 3000.0
	# Hybrid all-in-one ~4 kg + 4 g/W of PV; bare MPPT ~0.5 kg + 35 g/A
	# (Victron 150/35 → ~1.7 kg; EcoWorthy 3.5 kW hybrid → ~18 kg).
	var mass := (4.0 + pv_w * 0.004) if hybrid else (0.5 + amps * 0.035)
	var vol := mass / ELECTRONICS_KG_M3
	var unit := pow(vol / (1.6 * 1.1), 1.0 / 3.0)
	return normalize({"w_m": 1.6 * unit, "d_m": 1.1 * unit, "h_m": unit,
		"mass_kg": mass, "form": "crate", "source": "estimated"})


static func _derive_appliance(specs: Dictionary) -> Dictionary:
	var box = specs.get("box_spec")
	var watts := float(specs.get("watts", 100.0))
	var mass := clampf(2.0 + watts * 0.02, 1.0, 80.0)
	if box is Dictionary:
		var b := box as Dictionary
		var est := estimate_from_deployed(Vector3(float(b.get("w_m", 0.4)),
			float(b.get("h_m", 0.4)), float(b.get("d_m", 0.4))), "rigid")
		est["mass_kg"] = mass
		return normalize(est)
	return normalize({"w_m": 0.45, "d_m": 0.40, "h_m": 0.35, "mass_kg": mass,
		"form": "crate", "source": "estimated"})


static func _derive_processor(specs: Dictionary) -> Dictionary:
	# Machines with a real 3D twin defer to the model's curated entry.
	var model_id := str(specs.get("model_id", ""))
	if not model_id.is_empty():
		var m := for_model(model_id)
		if not m.is_empty():
			return m
	var watts := float(specs.get("watts", 300.0))
	var mass := clampf(20.0 + watts * 0.03, 10.0, 800.0)
	var box = specs.get("box_spec")
	if box is Dictionary:
		var b := box as Dictionary
		var est := estimate_from_deployed(Vector3(float(b.get("w_m", 0.8)),
			float(b.get("h_m", 0.8)), float(b.get("d_m", 0.8))), "rigid")
		est["mass_kg"] = mass
		return normalize(est)
	return normalize({"w_m": 0.80, "d_m": 0.60, "h_m": 0.60, "mass_kg": mass,
		"form": "crate", "source": "estimated"})


static func _derive_resource(specs: Dictionary) -> Dictionary:
	var qty := maxf(float(specs.get("capacity_qty", 0.0)), 1.0)
	var unit := str(specs.get("capacity_unit", "L")).to_lower()
	if unit == "l":
		# Empty HDPE tank shipped upright: cylinder h = 1.2 d sized to capacity.
		var vol_m3 := qty / 1000.0
		var d := pow(4.0 * vol_m3 / (1.2 * PI), 1.0 / 3.0)
		return normalize({"w_m": d, "d_m": d, "h_m": 1.2 * d,
			"mass_kg": 1.5 + qty * TANK_KG_PER_L, "form": "tank",
			"source": "estimated", "this_side_up": true, "stackable": false})
	# kg / m³ stores: an empty bin/bag sized to hold the rated mass at a
	# ~150 kg/m³ loose bulk density.
	var bin_m3 := maxf(qty / 150.0, 0.02)
	var edge := pow(bin_m3, 1.0 / 3.0)
	return normalize({"w_m": edge * 1.2, "d_m": edge, "h_m": edge * 0.9,
		"mass_kg": clampf(2.0 + qty * 0.02, 1.0, 60.0), "form": "crate",
		"source": "estimated"})


static func _derive_wind(specs: Dictionary) -> Dictionary:
	var rated_w := maxf(float(specs.get("rated_watts",
		specs.get("watts", 500.0))), 100.0)
	# Turbine + mast bundle: ~20 kg base + 80 g/W (1 kW class ≈ 100 kg).
	return normalize({"w_m": clampf(rated_w / 300.0, 1.5, 6.0), "d_m": 0.5,
		"h_m": 0.5, "mass_kg": 20.0 + rated_w * 0.08, "form": "bundle",
		"source": "estimated"})
