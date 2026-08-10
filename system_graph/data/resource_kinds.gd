class_name ResourceKinds
extends RefCounted

## Registry of trackable physical resource kinds for the graph editor.
## Each kind maps to display metadata, wire/port color, and default unit.
## User extensions load from user://resource_kinds.cfg (never committed).

const CONFIG_PATH := "user://resource_kinds.cfg"

const BUILTIN: Dictionary = {
	"electric": {
		"display": "Electricity",
		"color": Color(0.941, 0.820, 0.282, 1.0),
		"unit": "kWh",
		"abbrev": "âš¡",
		"flow_ref_rate": 3500.0,
	},
	"dc_electricity": {
		"display": "DC Electricity",
		"color": Color(0.847, 0.329, 0.329, 1.0),
		"unit": "kW",
		"abbrev": "ðŸ”Œ",
		"flow_ref_rate": 3.0,
	},
	"water": {
		"display": "Potable Water",
		"color": Color(0.231, 0.510, 0.965, 1.0),
		"unit": "L",
		"abbrev": "ðŸ’§",
		"flow_ref_rate": 120.0,
		"aliases": ["potable_water"],
	},
	"greywater": {
		"display": "Greywater",
		"color": Color(0.420, 0.620, 0.780, 1.0),
		"unit": "L",
		"abbrev": "ðŸš¿",
		"flow_ref_rate": 80.0,
	},
	"blackwater": {
		"display": "Blackwater",
		"color": Color(0.420, 0.320, 0.220, 1.0),
		"unit": "L",
		"abbrev": "ðŸš½",
		"flow_ref_rate": 50.0,
	},
	"biomass": {
		"display": "Biomass",
		"color": Color(0.545, 0.353, 0.176, 1.0),
		"unit": "kg",
		"abbrev": "ðŸŒ¿",
		"flow_ref_rate": 25.0,
	},
	"food_waste": {
		# Kitchen / food scraps for digesters (HomeBiogas datasheet is in liters;
		# wet scraps ≈ 1 kg/L so volume and mass rates are interchangeable here).
		"display": "Food Waste",
		"color": Color(0.620, 0.480, 0.220, 1.0),
		"unit": "L",
		"abbrev": "FW",
		"flow_ref_rate": 6.0,
		"aliases": ["kitchen_waste", "organic_waste", "food_scraps"],
	},
	"manure": {
		"display": "Animal Manure",
		"color": Color(0.480, 0.360, 0.200, 1.0),
		"unit": "L",
		"abbrev": "MN",
		"flow_ref_rate": 15.0,
		"aliases": ["animal_manure", "dung"],
	},
	"plastic_waste": {
		"display": "Plastic Waste",
		"color": Color(0.580, 0.639, 0.722, 1.0),
		"unit": "kg",
		"abbrev": "â™»",
		"flow_ref_rate": 12.0,
	},
	"plastic_shred": {
		"display": "Shredded Plastic",
		"color": Color(0.392, 0.710, 0.965, 1.0),
		"unit": "kg",
		"abbrev": "âœ‚",
		"flow_ref_rate": 15.0,
	},
	"plastic_flake": {
		"display": "Plastic Flake",
		"color": Color(0.298, 0.788, 0.741, 1.0),
		"unit": "kg",
		"abbrev": "🫧",
		"flow_ref_rate": 10.0,
	},
	"plastic_sheet": {
		"display": "Recycled Plastic Sheet",
		"color": Color(0.450, 0.720, 0.820, 1.0),
		"unit": "sheets",
		"abbrev": "▭",
		"flow_ref_rate": 2.0,
	},
	"finished_part": {
		"display": "Finished Parts",
		"color": Color(0.741, 0.678, 0.949, 1.0),
		"unit": "units",
		"abbrev": "🧩",
		"flow_ref_rate": 5.0,
	},
	"mud": {
		"display": "Mud / Clay / Concrete",
		"color": Color(0.545, 0.435, 0.302, 1.0),
		"unit": "L",
		"abbrev": "🪣",
		"flow_ref_rate": 50.0,
	},
	"biochar": {
		"display": "Biochar",
		"color": Color(0.180, 0.180, 0.180, 1.0),
		"unit": "kg",
		"abbrev": "ðŸ”¥",
		"flow_ref_rate": 8.0,
	},
	"hot_water": {
		"display": "Hot Water",
		"color": Color(0.937, 0.420, 0.420, 1.0),
		"unit": "L",
		"abbrev": "â™¨",
		"flow_ref_rate": 60.0,
	},
	"steam": {
		"display": "Steam",
		"color": Color(0.870, 0.870, 0.900, 1.0),
		"unit": "kg",
		"abbrev": "â™¨",
		"flow_ref_rate": 40.0,
	},
	"woodgas": {
		"display": "Syngas / Woodgas",
		"color": Color(0.706, 0.627, 0.353, 1.0),
		"unit": "mÂ³",
		"abbrev": "ðŸ’¨",
		"flow_ref_rate": 6.0,
		"aliases": ["syngas"],
	},
	"food": {
		"display": "Food",
		"color": Color(0.063, 0.722, 0.506, 1.0),
		"unit": "kg",
		"abbrev": "ðŸŽ",
		"flow_ref_rate": 10.0,
	},
	"meal": {
		# Prepared meals out of a Kitchen processor (meal_prep recipe). One
		# meal ~ 0.5 kg of raw food — the same sitting the eating activity
		# used to draw as `food 1.0 kg/h x 0.5 h`. Counted in MEALS, not kg:
		# a meal is a discrete serving, and the habitat's meal-first draw is
		# 2 meals/h over the same half-hour sitting.
		"display": "Prepared Meals",
		"color": Color(0.980, 0.702, 0.302, 1.0),
		"unit": "meals",
		"abbrev": "ML",
		"flow_ref_rate": 4.0,
		"aliases": ["meals", "prepared_meal", "prepared_meals"],
	},
	"packaging_waste": {
		# Wrappers, sacks, cans — the dry side of a kitchen's waste stream
		# (food_waste is the wet side). Feeds the waste bins / plastic loop.
		"display": "Packaging Waste",
		"color": Color(0.760, 0.700, 0.560, 1.0),
		"unit": "kg",
		"abbrev": "PW",
		"flow_ref_rate": 2.0,
		"aliases": ["packaging"],
	},
	"nutrients": {
		"display": "Nutrients",
		"color": Color(0.820, 0.720, 0.180, 1.0),
		"unit": "kg",
		"abbrev": "ðŸŒ±",
		"flow_ref_rate": 8.0,
	},
	"liquid_fertilizer": {
		"display": "Liquid Fertilizer",
		"color": Color(0.420, 0.720, 0.280, 1.0),
		"unit": "L",
		"abbrev": "ðŸ§ª",
		"flow_ref_rate": 40.0,
		"aliases": ["fertilizer_effluent"],
	},
	"biogas": {
		"display": "Biogas",
		"color": Color(0.820, 0.580, 0.220, 1.0),
		"unit": "mÂ³",
		"abbrev": "ðŸ’¨",
		"flow_ref_rate": 2.0,
	},
	"propane": {
		"display": "Propane",
		"color": Color(0.961, 0.620, 0.043, 1.0),
		"unit": "kg",
		"abbrev": "ðŸ›¢",
		"flow_ref_rate": 5.0,
	},
	"thermal": {
		"display": "Heat",
		"color": Color(0.847, 0.329, 0.329, 1.0),
		"unit": "kWh",
		"abbrev": "â™¨",
		"flow_ref_rate": 15.0,
	},
	"sunlight": {
		# Wire quantity is the SoI-wide flux (kW = irradiance × SoI area,
		# matching how the Rain PBI wire carries total L/h rather than mm/h) —
		# NOT the per-m² irradiance shown on the PBI node's own readout.
		"display": "Sunlight",
		"color": Color(1.0, 0.85, 0.3, 1.0),
		"unit": "kW",
		"abbrev": "☀",
		"flow_ref_rate": 75000.0,
		"aliases": ["solar", "radiation"],
	},
	"wind": {
		# Atmosphere PBI — wire quantity is SoI kinetic flux (kW, ½ρAv³ slab).
		# Node readout shows wind / temp / RH; turbines use WeatherService ambiently.
		"display": "Wind",
		"color": Color(0.55, 0.78, 0.92, 1.0),
		"unit": "kW",
		"abbrev": "🌬",
		"flow_ref_rate": 50000.0,
		"aliases": ["atmosphere", "air", "mechanical"],
	},
	"money": {
		"display": "Money",
		"color": Color(0.294, 0.686, 0.314, 1.0),
		"unit": "$",
		"abbrev": "ðŸ’µ",
		"flow_ref_rate": 100.0,
	},
	"chore_hours": {
		"display": "Chore Hours",
		"color": Color(0.702, 0.443, 0.812, 1.0),
		"unit": "h",
		"abbrev": "ðŸ§¹",
		"flow_ref_rate": 8.0,
	},
}

static var _extra: Dictionary = {}
static var _loaded: bool = false


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_extra.clear()
	if not FileAccess.file_exists(CONFIG_PATH):
		return
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return
	for section in cfg.get_sections():
		if section == "meta":
			continue
		var display: String = str(cfg.get_value(section, "display", section.capitalize()))
		var unit: String = str(cfg.get_value(section, "unit", "unit"))
		var abbrev: String = str(cfg.get_value(section, "abbrev", "â€¢"))
		var cr: float = float(cfg.get_value(section, "color_r", 0.58))
		var cg: float = float(cfg.get_value(section, "color_g", 0.64))
		var cb: float = float(cfg.get_value(section, "color_b", 0.72))
		var entry: Dictionary = {
			"display": display,
			"color": Color(cr, cg, cb, 1.0),
			"unit": unit,
			"abbrev": abbrev,
			"flow_ref_rate": float(cfg.get_value(section, "flow_ref_rate", 10.0)),
		}
		_extra[section] = entry


## Turn an arbitrary label into a stable snake_case id (letters/digits/underscore).
static func slugify(text: String) -> String:
	var s := text.strip_edges().to_lower()
	var out := ""
	for i in s.length():
		var c := s[i]
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9"):
			out += c
		elif c == " " or c == "-" or c == "_" or c == "/":
			out += "_"
	while out.contains("__"):
		out = out.replace("__", "_")
	out = out.strip_edges().lstrip("_").rstrip("_")
	return out


## Create or update a user-defined resource kind and persist it to
## user://resource_kinds.cfg (never committed). Returns the resolved id, or ""
## if the label was empty or collides with a builtin id. Safe to call at runtime;
## updates the in-memory registry immediately so pickers refresh on rebuild.
static func add_custom_kind(display: String, unit: String, abbrev: String,
		color: Color, id: String = "") -> String:
	_ensure_loaded()
	var kid := id.strip_edges()
	if kid.is_empty():
		kid = slugify(display)
	else:
		kid = slugify(kid)
	if kid.is_empty():
		return ""
	# Never shadow a builtin kind's id.
	if BUILTIN.has(kid):
		return ""
	var disp := display.strip_edges()
	if disp.is_empty():
		disp = kid.capitalize()
	var entry := {
		"display": disp,
		"color": color,
		"unit": unit.strip_edges() if not unit.strip_edges().is_empty() else "unit",
		"abbrev": abbrev.strip_edges() if not abbrev.strip_edges().is_empty() else "â€¢",
		"flow_ref_rate": 10.0,
	}
	_extra[kid] = entry

	var cfg := ConfigFile.new()
	if FileAccess.file_exists(CONFIG_PATH):
		cfg.load(CONFIG_PATH)   # keep existing user kinds
	cfg.set_value(kid, "display", entry["display"])
	cfg.set_value(kid, "unit", entry["unit"])
	cfg.set_value(kid, "abbrev", entry["abbrev"])
	cfg.set_value(kid, "color_r", color.r)
	cfg.set_value(kid, "color_g", color.g)
	cfg.set_value(kid, "color_b", color.b)
	cfg.set_value(kid, "flow_ref_rate", 10.0)
	cfg.save(CONFIG_PATH)
	return kid


## Remove a user-defined resource kind (builtins can't be removed).
static func remove_custom_kind(kind_id: String) -> bool:
	_ensure_loaded()
	if BUILTIN.has(kind_id) or not _extra.has(kind_id):
		return false
	_extra.erase(kind_id)
	if FileAccess.file_exists(CONFIG_PATH):
		var cfg := ConfigFile.new()
		if cfg.load(CONFIG_PATH) == OK and cfg.has_section(kind_id):
			cfg.erase_section(kind_id)
			cfg.save(CONFIG_PATH)
	return true


## True when a kind is user-defined (removable / editable), not a builtin.
static func is_custom_kind(kind_id: String) -> bool:
	_ensure_loaded()
	return _extra.has(kind_id) and not BUILTIN.has(kind_id)


static func all_kinds() -> Array:
	_ensure_loaded()
	var keys: Array = BUILTIN.keys()
	for k: String in _extra.keys():
		if not keys.has(k):
			keys.append(k)
	keys.sort()
	return keys


static func has_kind(kind_id: String) -> bool:
	_ensure_loaded()
	return BUILTIN.has(kind_id) or _extra.has(kind_id)


static func kind_meta(kind_id: String) -> Dictionary:
	_ensure_loaded()
	if BUILTIN.has(kind_id):
		return (BUILTIN[kind_id] as Dictionary).duplicate(true)
	if _extra.has(kind_id):
		return (_extra[kind_id] as Dictionary).duplicate(true)
	return {
		"display": kind_id.capitalize(),
		"color": Color(0.580, 0.639, 0.722, 1.0),
		"unit": "unit",
		"abbrev": "â€¢",
	}


static func wire_color(kind_id: String) -> Color:
	if kind_id.is_empty():
		return Color(0.580, 0.639, 0.722, 1.0)
	return kind_meta(kind_id).get("color", Color(0.580, 0.639, 0.722, 1.0)) as Color


static func display_name(kind_id: String) -> String:
	return str(kind_meta(kind_id).get("display", kind_id))


static func default_unit(kind_id: String) -> String:
	return str(kind_meta(kind_id).get("unit", "unit"))


static func flow_ref_rate(kind_id: String) -> float:
	return float(kind_meta(kind_id).get("flow_ref_rate", 10.0))


## Canonical id for compatibility checks (water â†” potable_water via aliases).
static func normalize_kind(kind_id: String) -> String:
	var k := kind_id.strip_edges()
	if k.is_empty():
		return ""
	_ensure_loaded()
	for canon: String in BUILTIN.keys():
		var aliases: Array = (BUILTIN[canon] as Dictionary).get("aliases", []) as Array
		if aliases.has(k):
			return canon
	for canon: String in _extra.keys():
		var aliases2: Array = (_extra[canon] as Dictionary).get("aliases", []) as Array
		if aliases2.has(k):
			return canon
	if BUILTIN.has(k) or _extra.has(k):
		return k
	return k


## True when two resource port kinds may be wired together.
static func kinds_compatible(src_kind: String, tgt_kind: String) -> bool:
	var a := normalize_kind(src_kind)
	var b := normalize_kind(tgt_kind)
	if a.is_empty() or b.is_empty():
		return false
	return a == b


## Maps a unit string to its fundamental measure so kinds with different
## units (e.g. "L" vs "mÂ³") aren't treated as the same dimension by mistake,
## while unit variants of the same measure (mass/volume/energy/â€¦) group together.
const UNIT_DIMENSION: Dictionary = {
	"kg": "mass",
	"lb": "mass",
	"L": "volume",
	"gal": "volume",
	"mÂ³": "volume",
	"kWh": "energy",
	"Wh": "energy",
	"BTU": "energy",
	"kW": "power",
	"$": "currency",
	"h": "time",
}


## Fundamental measure (mass/volume/energy/currency/time/â€¦) for a resource kind,
## derived from its default unit. Unknown units fall back to the unit string
## itself so at least identical-unit kinds still match.
static func dimension_for_kind(kind_id: String) -> String:
	var unit := default_unit(kind_id)
	return str(UNIT_DIMENSION.get(unit, unit))


## True when two resource kinds mismatch by kind but share the same
## fundamental unit of measure (mass/volume/energy/â€¦) â€” used to let a user
## deliberately override the strict port-type check.
static func dimensions_compatible(src_kind: String, tgt_kind: String) -> bool:
	var a := normalize_kind(src_kind)
	var b := normalize_kind(tgt_kind)
	if a.is_empty() or b.is_empty():
		return false
	return dimension_for_kind(a) == dimension_for_kind(b)


## True when a resource connection between these kinds is allowed at all â€”
## either an exact kind match, or a user override via matching fundamental units.
static func connection_allowed(src_kind: String, tgt_kind: String) -> bool:
	return kinds_compatible(src_kind, tgt_kind) or dimensions_compatible(src_kind, tgt_kind)


## Resource kinds for graph legend (excludes electrical â€” use PORT_COLORS for that).
static func legend_entries(include_electric: bool = false) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var alias_ids: Dictionary = {}
	for k: String in all_kinds():
		for alias: Variant in kind_meta(k).get("aliases", []):
			alias_ids[str(alias)] = true
	if include_electric:
		out.append({
			"label": "Electricity",
			"color": wire_color("electric"),
			"kind": "electric",
		})
	for k: String in all_kinds():
		if alias_ids.has(k):
			continue
		if k == "electric" and not include_electric:
			continue
		if k == "dc_electricity":
			continue
		out.append({
			"label": display_name(k),
			"color": wire_color(k),
			"kind": k,
		})
	return out


## Human-readable rejection when resource kinds mismatch.
static func mismatch_message(src_kind: String, tgt_kind: String) -> String:
	var a := display_name(normalize_kind(src_kind) if not src_kind.is_empty() else src_kind)
	var b := display_name(normalize_kind(tgt_kind) if not tgt_kind.is_empty() else tgt_kind)
	if src_kind.is_empty() or tgt_kind.is_empty():
		return "Resource port missing a type â€” assign input/output kinds in the inspector"
	if dimensions_compatible(src_kind, tgt_kind):
		return "%s does not normally connect to %s (allowed â€” same unit of measure)" % [a, b]
	return "%s cannot connect to %s" % [a, b]


## Parse legacy free-text capacity strings like "50 gal" or "100 lb".
static func parse_capacity_text(text: String) -> Dictionary:
	var t := text.strip_edges()
	if t.is_empty():
		return {"qty": 100.0, "unit": "L"}
	var parts := t.split(" ", false)
	if parts.size() >= 2:
		var qty := float(parts[0])
		var unit := parts[1]
		return {"qty": qty, "unit": unit}
	return {"qty": 100.0, "unit": t}


## Infer resource kind from a container preset name.
static func infer_kind_from_name(name: String) -> String:
	var n := name.to_lower()
	if "grey" in n:
		return "greywater"
	if "black" in n and "water" in n:
		return "blackwater"
	if "syngas" in n or "woodgas" in n:
		return "woodgas"
	if "nutrient" in n or "fertil" in n:
		if "liquid" in n or "effluent" in n:
			return "liquid_fertilizer"
		return "nutrients"
	if "biogas" in n or "methane" in n:
		return "biogas"
	if "water" in n or "tank" in n and "propane" not in n:
		return "water"
	if "propane" in n:
		return "propane"
	if "thermal" in n or "heat" in n:
		return "thermal"
	if "ev" in n or "battery" in n:
		return "electric"
	if "plastic" in n and "flake" in n:
		return "plastic_flake"
	if "plastic" in n and "shred" in n:
		return "plastic_shred"
	if "plastic" in n:
		return "plastic_waste"
	if "biochar" in n:
		return "biochar"
	if "biomass" in n:
		return "biomass"
	if "manure" in n or "dung" in n:
		return "manure"
	if ("food" in n and ("waste" in n or "scrap" in n)) or "kitchen" in n:
		return "food_waste"
	if "packaging" in n or "wrapper" in n:
		return "packaging_waste"
	if "meal" in n:
		return "meal"
	if "food" in n:
		return "food"
	if "money" in n or "cash" in n:
		return "money"
	if "chore" in n or "work" in n or "labor" in n or "labour" in n:
		return "chore_hours"
	return "water"


## Parse legacy output_rate like "50 L/h" into a structured output entry.
static func parse_rate_text(rate_text: String) -> Dictionary:
	var t := rate_text.strip_edges()
	if t.is_empty():
		return {"kind": "water", "rate": 0.0, "unit": "L/h"}
	var parts := t.split(" ", false)
	var qty := 0.0
	var unit := "L/h"
	if parts.size() >= 1:
		qty = float(parts[0]) if parts[0].is_valid_float() else 0.0
	if parts.size() >= 2:
		unit = parts[1]
		if not unit.ends_with("/h"):
			unit = unit + "/h"
	var kind := "water"
	var ul := unit.to_lower()
	if "btu" in ul:
		kind = "thermal"
	elif "gal" in ul:
		kind = "water"
	elif "mi" in ul:
		kind = "electric"
	return {"kind": kind, "rate": qty, "unit": unit}


## Ensure processor specs carry structured inputs[] / outputs[].
func migrate_processor_specs(specs: Dictionary) -> void:
	if not specs.has("batch_mode"):
		specs["batch_mode"] = false
		specs["batch_time_hrs"] = 1.0
		specs["batch_failure_mode"] = "pause_and_resume"
		specs["batch_failure_penalty_qty"] = 0.0

	if not specs.has("energy_source"):
		specs["energy_source"] = "ac" if float(specs.get("watts", 0.0)) > 0.0 else ""
	# Power supply is AC-only now (or "" = passive). A processor that instead
	# CONSUMES DC power (as opposed to producing it â€” see the dc_electricity
	# output migration below) would need its own energy_source value; not
	# built yet. The old confusing thermal/mechanical energy types are
	# retired â€” migrate them to passive.
	var es := str(specs.get("energy_source", ""))
	if es == "thermal" or es == "mechanical":
		specs["energy_source"] = ""

	if not specs.has("inputs"):
		specs["inputs"] = []
	if not specs.has("outputs"):
		if specs.has("output_rate"):
			specs["outputs"] = [parse_rate_text(str(specs.get("output_rate", "")))]
		else:
			specs["outputs"] = []  # New processors start with no I/Os; user adds them via inspector

	# One-time migration: the old dc_direct_charge flat-kW mechanism
	# (dc_direct_charge/dc_output_kw + dcPositive/dcNegative ports) is
	# replaced by a dc_electricity-kind output entry (positive/negative
	# ports, kW derived from fuel throughput each tick â€” see
	# ResourceFlowEngine._process_processor). Convert existing saves so the
	# engine/port resolver only need to know the new path.
	if bool(specs.get("dc_direct_charge", false)):
		var dc_outs: Array = specs.get("outputs", []) as Array
		var dc_already_migrated := false
		for dc_o: Variant in dc_outs:
			if dc_o is Dictionary and str((dc_o as Dictionary).get("kind", "")) == "dc_electricity":
				dc_already_migrated = true
				break
		if not dc_already_migrated:
			var legacy_kw := float(specs.get("dc_output_kw", 0.0))
			dc_outs.append({"kind": "dc_electricity", "rate": legacy_kw, "unit": "kW"})
			specs["outputs"] = dc_outs
			# Preserve the exact old peak (dc_output_kw*efficiency): the new
			# formula is throughput_post_efficiency * energy_wh_per_unit/1000,
			# and throughput_post_efficiency == fuel_rate*efficiency for a
			# single-fuel-input generator, so back-derive:
			#   energy_wh_per_unit = legacy_kw * 1000 / fuel_rate
			var dc_fuel_rate := 0.0
			for dc_inp: Variant in (specs.get("inputs", []) as Array):
				if dc_inp is Dictionary and str((dc_inp as Dictionary).get("kind", "")) != "electric":
					dc_fuel_rate = float((dc_inp as Dictionary).get("rate", 0.0))
					break
			if dc_fuel_rate > 0.0:
				specs["energy_wh_per_unit"] = legacy_kw * 1000.0 / dc_fuel_rate
		specs["dc_direct_charge"] = false
		specs.erase("dc_output_kw")

	if not specs.has("efficiency"):
		specs["efficiency"] = 1.0
	if not specs.has("energy_wh_per_unit"):
		var watts: float = float(specs.get("watts", 0.0))
		var outs: Array = specs.get("outputs", []) as Array
		var rate: float = float(outs[0].get("rate", 0.0)) if outs.size() > 0 else 0.0
		specs["energy_wh_per_unit"] = (watts / rate) if rate > 0.0 else 0.0

	# AC power is modeled by `watts` + `energy_source` + the `power_in` handle â€”
	# NOT by a resource input. A previous migration auto-inserted an "electric"
	# resource input (unit "W") for every powered processor, which created a
	# phantom "Electricity" input port and shifted the real resource ports (so a
	# biomass wire landed on the electric port). Strip those auto-inserted entries
	# so existing saves self-heal; leave any other inputs untouched.
	var ins: Array = specs.get("inputs", []) as Array
	for i in range(ins.size() - 1, -1, -1):
		var inpd := ins[i] as Dictionary
		if str(inpd.get("kind", "")) == "electric" and str(inpd.get("unit", "")) == "W":
			ins.remove_at(i)


## Ensure resource tank specs carry resource_kind + numeric capacity.
func migrate_resource_specs(specs: Dictionary) -> void:
	if not specs.has("resource_kind"):
		specs["resource_kind"] = infer_kind_from_name(str(specs.get("name", "")))
	if not specs.has("capacity_qty"):
		var parsed := parse_capacity_text(str(specs.get("capacity", "")))
		specs["capacity_qty"] = float(parsed.get("qty", 100.0))
		specs["capacity_unit"] = str(parsed.get("unit", default_unit(str(specs.get("resource_kind", "water")))))
	if not specs.has("level"):
		specs["level"] = 0.5
	if not specs.has("inflow_rate"):
		specs["inflow_rate"] = 0.0
	if not specs.has("outflow_rate"):
		specs["outflow_rate"] = 0.0
	if not specs.has("unlimited_capacity"):
		specs["unlimited_capacity"] = false
	if not specs.has("allow_negative"):
		specs["allow_negative"] = false
	if not specs.has("scale_with_fill"):
		specs["scale_with_fill"] = true
	if not specs.has("jit_outflow"):
		specs["jit_outflow"] = false


## Absolute stock in capacity_unit. Deficit tanks use level × capacity_qty
## (level may be < 0 or > 1). Unlimited timeline tanks use level × 1e12.
const UNLIMITED_CAPACITY_QTY := 1.0e12


static func tank_stock_qty(specs: Dictionary) -> float:
	# Culvert ∞ outlet: cumulative discharge is the meaningful stock.
	if bool(specs.get("outlet_sink", false)):
		return maxf(float(specs.get("cumulative_l", specs.get("stock_l", 0.0))), 0.0)
	var level := float(specs.get("level", 0.0))
	if bool(specs.get("allow_negative", false)):
		return level * maxf(float(specs.get("capacity_qty", 100.0)), 0.001)
	if bool(specs.get("unlimited_capacity", false)):
		return level * UNLIMITED_CAPACITY_QTY
	return clampf(level, 0.0, 1.0) * maxf(float(specs.get("capacity_qty", 100.0)), 0.0)


static func format_tank_stock(specs: Dictionary) -> String:
	var unit := str(specs.get("capacity_unit",
		default_unit(str(specs.get("resource_kind", "water")))))
	if bool(specs.get("outlet_sink", false)):
		var cum := maxf(float(specs.get("cumulative_l", specs.get("stock_l", 0.0))), 0.0)
		var lps := float(specs.get("live_in_lps", 0.0))
		if lps > 1e-4:
			return "%s %s · %.1f L/s" % [format_qty(cum), unit, lps]
		return "%s %s out" % [format_qty(cum), unit]
	# Pond twin with runaway capacity (legacy 1e12) — don't show scientific junk.
	var cap_raw := float(specs.get("capacity_qty", 100.0))
	if bool(specs.get("pond_storage", false)) and not bool(specs.get("unlimited_capacity", false)) \
			and (is_nan(cap_raw) or cap_raw >= 1.0e10):
		var level := clampf(float(specs.get("level", 0.0)), 0.0, 1.0)
		return "level %.0f%% (capacity pending heal)" % [level * 100.0]
	var stock := tank_stock_qty(specs)
	var qty := format_qty(stock)
	if bool(specs.get("allow_negative", false)) \
			or bool(specs.get("unlimited_capacity", false)):
		return "%s %s" % [qty, unit]
	var cap := maxf(cap_raw, 0.0)
	return "%s / %s %s" % [format_qty(stock), format_qty(cap), unit]


static func format_qty(q: float) -> String:
	var a := absf(q)
	if a >= 1.0e7:
		# Godot's String.sprintf has NO `%e`/`%g` conversion — using it threw
		# "unsupported format character" once per drawn tank ≥10M. Build the
		# scientific form by hand from mantissa + exponent instead.
		var expo := int(floor(log(a) / log(10.0)))
		var mant := q / pow(10.0, expo)
		if absf(mant) >= 9.995:  # rounding 9.999→10.00 rolls into the next decade
			mant /= 10.0
			expo += 1
		return "%.2fe%d" % [mant, expo]
	if a >= 100.0:
		return "%.0f" % q
	if a >= 10.0:
		return "%.1f" % q
	return "%.2f" % q
