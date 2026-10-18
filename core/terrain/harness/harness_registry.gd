class_name HarnessRegistry
extends RefCounted

## Every windowed `--capture=<mode>` in ONE table. It replaces the three
## hand-kept dispatch chains in playtest_harness.gd (the no-map branch, the
## generated-map launch and the direct-scene launch had drifted apart, so a
## mode worked from one launch path and silently shot nothing from another).
##
## Each entry: {fn: harness method name, world: the default WORLD alias it runs
## on when no map is named, timeout_s: the watchdog's budget, loader: whether it
## needs a TerrainLoader map}. Every default world is Mount Vernon or Walton —
## the user's real generated sites. The built-in SOAK / Mars scenes are imported
## meshes with no TerrainLoader and are NOT harness targets unless the user asks
## (`--scene=… --allow-builtin-scene`).
##
## Pure static data + pure lookups so the offline selftest can pin it.

const DEFAULT_TIMEOUT_S := 900.0
## Built-in scenes the harness refuses without --allow-builtin-scene.
const BUILTIN_SCENES := [
	"res://scenes/maps/soak_festival_2026.tscn",
	"res://scenes/maps/mars_aerial.tscn",
	"res://main.tscn",
]

## World aliases → label needles, earliest needle wins; among the worlds a
## needle matches, the most recently played one.
const WORLD_ALIASES := {
	"mtvernon": ["mount vernon", "mt. vernon", "mt vernon", "mcmurray"],
	"walton": ["pataha creek", "walton"],
}
const ALIAS_SYNONYMS := {
	"mt_vernon": "mtvernon", "mt-vernon": "mtvernon", "mountvernon": "mtvernon",
	"mount_vernon": "mtvernon", "mount-vernon": "mtvernon",
	"walton_or": "walton", "walton-or": "walton", "pataha": "walton",
}

## kind "scene" = the classic orbit/street/hero sets driven by _await_and_run;
## kind "menu" = no world is launched, the capture starts on the launch hub.
const CAPTURES := {
	"look":         {"fn": "_run_look_capture",            "world": "mtvernon", "timeout_s": 600.0},
	"script":       {"fn": "_run_fix_script",              "world": "mtvernon", "timeout_s": 900.0},
	"orbit":        {"fn": "_await_and_run",               "world": "mtvernon", "timeout_s": 1500.0, "kind": "scene"},
	"street":       {"fn": "_await_and_run",               "world": "mtvernon", "timeout_s": 1500.0, "kind": "scene"},
	"hero":         {"fn": "_await_and_run",               "world": "mtvernon", "timeout_s": 1500.0, "kind": "scene"},
	"both":         {"fn": "_await_and_run",               "world": "mtvernon", "timeout_s": 1500.0, "kind": "scene"},
	"worlds":       {"fn": "_run_worlds_capture",          "world": "walton",   "timeout_s": 1500.0},
	"graph":        {"fn": "_run_graph_capture",           "world": "mtvernon", "timeout_s": 900.0},
	"siphon":       {"fn": "_run_siphon_lab_capture",      "world": "mtvernon", "timeout_s": 1200.0},
	"site-review":  {"fn": "_run_site_review",             "world": "mtvernon", "timeout_s": 1800.0},
	"ambient":      {"fn": "_run_ambient_flow_verify",     "world": "mtvernon", "timeout_s": 600.0},
	"population":   {"fn": "_run_population_verify",       "world": "mtvernon", "timeout_s": 1200.0},
	"project":      {"fn": "_run_project_verify",          "world": "mtvernon", "timeout_s": 1500.0},
	"settlement":   {"fn": "_run_settlement_capture",      "world": "mtvernon", "timeout_s": 900.0},
	"labour":       {"fn": "_run_labour_capture",          "world": "mtvernon", "timeout_s": 900.0},
	"npcpose":      {"fn": "_run_npc_pose_capture",        "world": "mtvernon", "timeout_s": 600.0},
	"workui":       {"fn": "_run_workui_capture",          "world": "mtvernon", "timeout_s": 900.0},
	"npc-anim":     {"fn": "_run_npc_anim_verify",         "world": "walton",   "timeout_s": 900.0},
	"autobind":     {"fn": "_run_autobind_verify",         "world": "mtvernon", "timeout_s": 600.0},
	"poi":          {"fn": "_run_poi_verify",              "world": "mtvernon", "timeout_s": 600.0},
	"penstock":     {"fn": "_run_penstock_verify",         "world": "mtvernon", "timeout_s": 1200.0},
	"hydroload":    {"fn": "_run_hydro_load_verify",       "world": "mtvernon", "timeout_s": 900.0},
	"sitebalance":  {"fn": "_run_site_balance_verify",     "world": "mtvernon", "timeout_s": 600.0},
	"pondid":       {"fn": "_run_pond_id_verify",          "world": "mtvernon", "timeout_s": 600.0},
	"culvert":      {"fn": "_run_culvert_downhill_verify", "world": "mtvernon", "timeout_s": 600.0},
	"water":        {"fn": "_run_water_verify",            "world": "mtvernon", "timeout_s": 1200.0},
	"veg":          {"fn": "_run_veg_capture",             "world": "mtvernon", "timeout_s": 1200.0},
	"areafill":     {"fn": "_run_area_fill_verify",        "world": "mtvernon", "timeout_s": 1200.0},
	"camps":        {"fn": "_run_camp_capture",            "world": "mtvernon", "timeout_s": 1200.0},
	"vegdock":      {"fn": "_run_veg_dock_capture",        "world": "mtvernon", "timeout_s": 900.0},
	"foodforest":   {"fn": "_run_food_forest_verify",      "world": "mtvernon", "timeout_s": 600.0},
	"tree":         {"fn": "_run_tree_portrait_capture",   "world": "mtvernon", "timeout_s": 900.0},
	"growth":       {"fn": "_run_growth_capture",          "world": "mtvernon", "timeout_s": 1200.0},
	"packing":      {"fn": "_run_packing_capture",         "world": "mtvernon", "timeout_s": 600.0},
	"hardware":     {"fn": "_run_hardware_capture",        "world": "mtvernon", "timeout_s": 600.0},
	"animeditor":   {"fn": "_run_animeditor_capture",      "world": "mtvernon", "timeout_s": 420.0},
	"fabswarm":     {"fn": "_run_fabswarm_capture",        "world": "mtvernon", "timeout_s": 600.0},
	"buildsteps":   {"fn": "_run_buildsteps_capture",      "world": "mtvernon", "timeout_s": 420.0},
	"fabcrew":      {"fn": "_run_fabcrew_capture",         "world": "mtvernon", "timeout_s": 900.0},
	"weather":      {"fn": "_run_extreme_weather_capture", "world": "mtvernon", "timeout_s": 900.0},
	"stars":        {"fn": "_run_star_capture",            "world": "mtvernon", "timeout_s": 900.0},
	"lights":       {"fn": "_run_lights_capture",          "world": "walton",   "timeout_s": 900.0},
	"propedit":     {"fn": "_run_prop_edit_capture",       "world": "mtvernon", "timeout_s": 900.0},
	"vehicles":     {"fn": "_run_vehicle_capture",         "world": "walton",   "timeout_s": 900.0},
	"dawn":         {"fn": "_run_dawn_capture",            "world": "mtvernon", "timeout_s": 900.0},
	"microclimate": {"fn": "_run_microclimate_capture",    "world": "walton",   "timeout_s": 900.0},
	"windowwall":   {"fn": "_run_window_wall_capture",     "world": "mtvernon", "timeout_s": 600.0},
	"crowdbench":   {"fn": "_run_crowd_bench",             "world": "walton",   "timeout_s": 1200.0},
	"festival":     {"fn": "_run_festival_capture",        "world": "walton",   "timeout_s": 1500.0},
	"festivalmode": {"fn": "_run_festival_mode_capture",   "world": "walton",   "timeout_s": 1800.0},
	"popin":        {"fn": "_run_popin_capture",           "world": "walton",   "timeout_s": 900.0},
	"tour":         {"fn": "_run_tour_capture",            "world": "mtvernon", "timeout_s": 2400.0},
	"modals":       {"fn": "_run_modals_capture",          "world": "mtvernon", "timeout_s": 600.0},
	"bootcamp":     {"fn": "_run_bootcamp_capture",        "world": "mtvernon", "timeout_s": 900.0},
	"timeline":     {"fn": "_run_timeline_capture",        "world": "mtvernon", "timeout_s": 600.0},
	"assetpack":    {"fn": "_run_assetpack_capture",       "world": "mtvernon", "timeout_s": 1200.0},
	# kind "menu": runs on the launch hub with no world loaded (the "friend"
	# who has nothing yet — tools\harness.ps1 -EmptyUser); `world` is unused.
	"assetpack-import": {"fn": "_run_assetpack_import_capture", "world": "mtvernon", "timeout_s": 1500.0, "kind": "menu"},
	# Settings from the launch hub (the gear): the Main-free pages audited.
	"hubsettings":  {"fn": "_run_hub_settings_capture",    "world": "mtvernon", "timeout_s": 300.0, "kind": "menu"},
	"graphtools":   {"fn": "_run_graph_tools_capture",     "world": "mtvernon", "timeout_s": 600.0},
	"pvsnap":       {"fn": "_run_pv_snap_capture",         "world": "mtvernon", "timeout_s": 600.0},
	"conduits":     {"fn": "_run_conduits_capture",        "world": "mtvernon", "timeout_s": 600.0},
}


static func has_mode(mode: String) -> bool:
	return CAPTURES.has(mode)


static func entry(mode: String) -> Dictionary:
	return (CAPTURES.get(mode, {}) as Dictionary).duplicate()


static func modes() -> Array:
	var out: Array = CAPTURES.keys()
	out.sort()
	return out


static func timeout_for(modes_list: PackedStringArray) -> float:
	var t := 0.0
	for m in modes_list:
		t += float(entry(m).get("timeout_s", DEFAULT_TIMEOUT_S))
	return t if t > 0.0 else DEFAULT_TIMEOUT_S


static func is_builtin_scene(path: String) -> bool:
	return path.strip_edges() in BUILTIN_SCENES


## "mt_vernon" → "mtvernon"; unknown aliases come back unchanged.
static func canonical_alias(alias: String) -> String:
	var k := alias.strip_edges().to_lower()
	if k.ends_with(".tres"):
		k = k.get_basename()
	return str(ALIAS_SYNONYMS.get(k, k))


## Pick the world an alias / id / name means, from WorldStore.list()-shaped
## records (newest first). Returns {} when nothing matches.
static func pick_world(alias: String, records: Array) -> Dictionary:
	var raw := alias.strip_edges()
	if raw.is_empty():
		return {}
	for r in records:
		if str((r as Dictionary).get("id", "")) == raw:
			return r
	var key := canonical_alias(raw)
	var needles: Array = WORLD_ALIASES.get(key, [raw.to_lower()])
	for n in needles:
		var best := {}
		var best_t := -INF
		for r in records:
			var rec: Dictionary = r
			if bool(rec.get("scratch", false)):
				continue
			var map: Dictionary = rec.get("map", {}) if rec.get("map", {}) is Dictionary else {}
			var hay := ("%s | %s" % [str(rec.get("name", "")), str(map.get("label", ""))]).to_lower()
			if hay.find(str(n)) < 0:
				continue
			var t := float(rec.get("last_played_unix", 0.0))
			if t > best_t:
				best_t = t
				best = rec
		if not best.is_empty():
			return best
	return {}
