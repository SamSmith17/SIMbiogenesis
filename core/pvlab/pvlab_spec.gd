class_name PvLabSpec
extends RefCounted

## The Solar designer's whole spec — one module design on one array — as the
## placed prop stores it (record key `pvlab_spec`). Pure.
##
## {
##   version, name,
##   module:  PvLabModule spec
##   array:   PvLabArray.ARRAY_DEFAULTS — mount, rows, cols, stack,
##            orientation, gap_mm, pitch_m (0 = no winter shade), tilt_deg,
##            clearance_m, site_lat (stamped where it is placed), gcr
##   rack:    PvLabRack.DEFAULTS — material, leg_spacing_m, rail_overhang_mm,
##            design_load_kpa, brace, pole_h_m, hub_h_m, standoff_mm
##   tracker: PvLabTracker.DEFAULTS — axis_tilt_deg, max_deg, backtrack,
##            stow_deg, night_deg, stow_wind_ms
##   strings: PvLabArray.STRING_DEFAULTS — mode, size (0 = auto), custom,
##            inputs (MPPT inputs = graph array nodes), groups
##   target:  PvLabArray.TARGET_DEFAULTS — the controller the strings are
##            sized for (name, max_voc, mppt_min_v, mppt_max_v, startup_v,
##            max_isc, max_pv_watts, cold_c, hot_c)
##   colors:  {lumber, galv, alu, concrete, cable}
## }

const VERSION := 1

const COLOR_DEFAULTS := {"lumber": Color(0.72, 0.56, 0.38), "galv": Color(0.66, 0.68, 0.7),
	"alu": Color(0.78, 0.8, 0.82), "concrete": Color(0.6, 0.6, 0.58), "cable": Color(0.05, 0.05, 0.05)}


static func default_spec() -> Dictionary:
	return resolve({"name": "Solar array"})


static func resolve(spec: Dictionary) -> Dictionary:
	var s := spec.duplicate(true)
	s["version"] = VERSION
	s["name"] = str(s.get("name", "Solar array")).strip_edges()
	if str(s["name"]).is_empty():
		s["name"] = "Solar array"
	s["module"] = PvLabModule.resolve(s.get("module", {}) if s.get("module") is Dictionary else {})
	s["array"] = PvLabArray.resolve_array(s.get("array", {}) if s.get("array") is Dictionary else {})
	s["rack"] = PvLabRack.resolve(s.get("rack", {}) if s.get("rack") is Dictionary else {})
	s["tracker"] = PvLabTracker.resolve(s.get("tracker", {}) if s.get("tracker") is Dictionary else {})
	s["strings"] = PvLabArray.resolve_strings(s.get("strings", {}) if s.get("strings") is Dictionary else {})
	s["target"] = PvLabArray.resolve_target(s.get("target", {}) if s.get("target") is Dictionary else {})
	var cols := COLOR_DEFAULTS.duplicate()
	if s.get("colors") is Dictionary:
		for k in (s["colors"] as Dictionary):
			cols[k] = PvLabModule._to_color((s["colors"] as Dictionary)[k], COLOR_DEFAULTS.get(k, Color.WHITE))
	s["colors"] = cols
	return s


static func to_json_safe(spec: Dictionary) -> Dictionary:
	var s := resolve(spec)
	s["module"] = PvLabModule.to_json_safe(s["module"])
	var cols := {}
	for k in s["colors"]:
		var c: Color = s["colors"][k]
		cols[k] = [c.r, c.g, c.b, c.a]
	s["colors"] = cols
	return s


static func key_of(spec: Dictionary) -> String:
	return str(hash(var_to_str(to_json_safe(spec))))


static func describe(spec: Dictionary) -> String:
	var s := resolve(spec)
	var a: Dictionary = s["array"]
	var n := int(a["rows"]) * int(a["cols"]) * int(a["stack"])
	var e := PvLabModule.electrical(s["module"])
	return "%d × %.0f W = %.2f kW · %s" % [n, float(e["wmp"]), float(e["wmp"]) * n / 1000.0,
		str(PvLabRack.MOUNT_LABELS.get(str(a["mount"]), ""))]
