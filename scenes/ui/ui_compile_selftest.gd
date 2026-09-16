extends SceneTree

## Offline compile smoke + duck-typing contract guard for every script under
## res://scenes/ui/.
##
## Run: Godot.exe.exe --headless --path . --script scenes/ui/ui_compile_selftest.gd
##
## Why this exists: scenes/ui/ is ~45k lines across 60+ files and had ZERO test
## coverage, because almost none of these scripts declare a `class_name` — so
## Godot never parses them at import, and a GDScript error in one surfaces only
## when a player opens that panel. Two existing selftests already hand-rolled
## this check for a single file each (core/report/site_report_selftest.gd's
## _test_ui_scripts_compile, core/linkage/linkage_selftest.gd's
## _test_modal_script_compiles); this generalises it to the whole directory.
##
## What it catches: parse errors, unresolved identifiers, bad `const` preloads,
## missing autoload names, wrong `extends`, and renamed methods that other
## subsystems call by string.
## What it does NOT catch: node-path misses, signal wiring, or layout. Those
## still need the windowed --capture harnesses.
##
## Methods are read off the Script rather than by instantiating, so nothing here
## runs a UI's _init side effects.

## Methods other subsystems call on these panels BY STRING. Renaming one is a
## silent breakage at best — and `_exit_mode` is called from
## core/terrain/terrain_loader.gd at ~10 sites with NO has_method() guard
## (unlike toggle_mode/is_panel_open, which are guarded), so a rename there is a
## hard runtime error, not a no-op. That asymmetry is why this table exists.
## A contract target need NOT live under SCAN_DIRS — _test_contracts loads any
## path it doesn't already have. system_graph_view.gd is the case in point: the
## timeline's Projects chip and the Routines panel both reach it by string.
const CONTRACTS: Dictionary = {
	"res://scenes/ui/terrain_edit_ui.gd": ["toggle_mode", "_exit_mode"],
	# The unified edit toolbar — terrain_loader reaches all four by string
	# (dispatch re-route + _close_edit_toolbar force-close).
	"res://scenes/ui/toolbar/edit_toolbar_ui.gd": [
		"toggle_mode", "_exit_mode", "is_panel_open", "open_with_section",
		"toggle_section"],
	"res://scenes/ui/vegetation_edit_ui.gd": ["toggle_mode", "_exit_mode"],
	"res://scenes/ui/camp_scatter_ui.gd": ["toggle_mode", "_exit_mode"],
	"res://scenes/ui/space_edit_ui.gd": ["toggle_mode", "_exit_mode", "is_panel_open"],
	"res://scenes/ui/placed_props_ui.gd": ["toggle_mode", "_exit_mode", "is_panel_open"],
	"res://system_graph/system_graph_view.gd": [
		"open_site_projects", "open_npc_routines", "npc_population_bridge",
		# Called by string from graph_dashboard_panel's Settlement card.
		"npc_dot_summary",
		# The Hydro Lab hands the section CT's slot to the turbine close-up by name.
		"set_lab_section_ct_visible"],
	# The Hydro Lab drives the close-up entirely by string (it is instantiated
	# from a preloaded script, not typed), so a rename here is a silent no-op that
	# leaves the tab showing an empty rect.
	"res://scenes/ui/hydro_turbine_closeup.gd": [
		"set_state", "set_display_mode", "set_active"],
}

## Directories to sweep. All of these share the same exposure: their scripts
## mostly have NO class_name, so Godot does not parse them at import and
## `--import` reports nothing — a parse error surfaces only when the scene
## actually loads.
##
## scenes/gameplay/ and gameplay/ were added after a bad automated edit left
## `tree.ServiceLocator.graph()` in conduit_route_controller.gd: `--import` was
## silent, this selftest did not cover that directory, and the failure only
## appeared as "Failed to load script … Parse error" when booting a map.
const SCAN_DIRS: Array[String] = [
	"res://scenes/ui",
	"res://scenes/gameplay",
	"res://scenes/settlement",
	"res://gameplay",
	"res://crisis_events",
	"res://location_picker",
]

var _fails := 0
var _checks := 0


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [name, detail])


# _initialize (not _init): runs after autoloads register, so scripts that
# resolve autoload identifiers at parse time (CursorController, UITheme, …)
# compile here the same way they do in game. See linkage_selftest.gd:17.
func _initialize() -> void:
	var scripts: Array[String] = []
	for dir: String in SCAN_DIRS:
		_collect(dir, scripts)
	scripts.sort()

	_check("found UI scripts to check", scripts.size() > 0)

	var loaded: Dictionary = {}   # path -> Script
	for path: String in scripts:
		var s: Variant = load(path)
		var ok := s is Script
		_check("compiles: %s" % path, ok,
			"load() returned null — parse error, bad preload, or unresolved identifier")
		if ok:
			loaded[path] = s as Script
			_check("instantiable: %s" % path, (s as Script).can_instantiate())

	_test_contracts(loaded)
	_test_view_mode_menu_ids()
	_test_dashboard_store_rows()

	if _fails == 0:
		print("UI COMPILE SELFTEST PASS  (%d checks, %d scripts)" % [_checks, scripts.size()])
	else:
		print("UI COMPILE SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(1 if _fails > 0 else 0)


func _collect(dir_path: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var entry := d.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = d.get_next()
			continue
		var full := dir_path.path_join(entry)
		if d.current_is_dir():
			_collect(full, out)
		elif entry.ends_with(".gd") and not entry.ends_with("_selftest.gd"):
			out.append(full)
		entry = d.get_next()
	d.list_dir_end()


## Assert the string-called method surface still exists. Read from the Script's
## own method list (plus its base chain) rather than instantiating, so no UI
## _init runs and nothing touches the scene tree.
func _test_contracts(loaded: Dictionary) -> void:
	for path: String in CONTRACTS.keys():
		# Targets outside SCAN_DIRS are loaded on demand, so the table can pin
		# any string-called surface — not only the swept UI scripts.
		var s: Script = loaded.get(path)
		if s == null:
			var direct: Variant = load(path)
			if direct is Script:
				s = direct as Script
		_check("contract target loaded: %s" % path, s != null,
			"CONTRACTS names a script that did not load or no longer exists")
		if s == null:
			continue
		var have: Dictionary = {}
		var cur: Script = s
		while cur != null:
			for m: Dictionary in cur.get_script_method_list():
				have[str(m.get("name", ""))] = true
			cur = cur.get_base_script()
		for method: Variant in CONTRACTS[path]:
			_check("%s defines %s()" % [path.get_file(), method],
				have.has(str(method)),
				"called by string from another subsystem — renaming it breaks that caller")


## The system-graph "View options ▾" popup keys every item off a
## `const VIEW_MODE_* := <int>` in system_graph_view.gd, and a duplicated id is
## a SILENT bug: PopupMenu happily adds both items, the handler's first match
## arm wins, and the second item toggles the wrong feature (151 was
## double-booked by SITE_PORTS and EMBODY_TWINS for a while — "Embody missing
## Site twins…" silently toggled Site ports). Menu wiring is runtime-only, so
## the uniqueness is asserted at the text level.
func _test_view_mode_menu_ids() -> void:
	var path := "res://system_graph/system_graph_view.gd"
	var f := FileAccess.open(path, FileAccess.READ)
	_check("view-mode id sweep: source readable", f != null)
	if f == null:
		return
	var text := f.get_as_text()
	var re := RegEx.create_from_string("const\\s+(VIEW_MODE_\\w+)\\s*:=\\s*(\\d+)")
	var seen: Dictionary = {}
	var count := 0
	for m: RegExMatch in re.search_all(text):
		count += 1
		var id := int(m.get_string(2))
		var cname := m.get_string(1)
		_check("view-mode id unique: %s = %d" % [cname, id],
			not seen.has(id),
			"already used by %s — the first match arm wins and this item goes dead"
				% str(seen.get(id, "")))
		seen[id] = cname
	_check("view-mode id sweep found consts (got %d)" % count, count >= 20)


## The left-sidebar RESOURCE STORES row model (GraphDashboardPanel.store_rows,
## pure static). Pinned because it once had NO filtering: the ∞ "Culvert
## Outlet" sink rendered as a 0% water store, a habitat's auto-spawned ghost
## containers rendered as human-looking in/out stores, and first-item-of-kind
## naming let the water row wear the outlet's name.
func _test_dashboard_store_rows() -> void:
	var s: Variant = load("res://system_graph/graph_dashboard_panel.gd")
	_check("dashboard panel script loads", s is Script)
	if not (s is Script):
		return
	var items: Array = [
		# The ∞ culvert outlet — must never be a store row (and it comes FIRST,
		# which is exactly the first-item-wins naming trap).
		{"type": "resource", "specs": {"name": "Culvert Outlet",
			"resource_kind": "water", "capacity_qty": 1.0e12, "level": 0.0,
			"unlimited_capacity": true, "outlet_sink": true}},
		# A processor ghost container (item- AND specs-level is_ghost).
		{"type": "resource", "is_ghost": true, "specs": {"name": "Greywater",
			"resource_kind": "greywater", "capacity_qty": 100.0, "level": 0.5,
			"is_ghost": true}},
		# A virtual (solar-bridge style) item.
		{"type": "resource", "is_virtual": true, "specs": {"name": "Virtual",
			"resource_kind": "water", "capacity_qty": 50.0, "level": 1.0}},
		# Two real water tanks — the LARGER names the row, stocks aggregate.
		{"type": "resource", "specs": {"name": "Rain Barrel",
			"resource_kind": "water", "capacity_qty": 200.0, "level": 0.5,
			"capacity_unit": "L"}},
		{"type": "resource", "specs": {"name": "Cistern",
			"resource_kind": "water", "capacity_qty": 1000.0, "level": 0.25,
			"capacity_unit": "L"}},
		# A non-resource item and a kindless resource — both ignored.
		{"type": "battery", "specs": {"resource_kind": "water"}},
		{"type": "resource", "specs": {"name": "Mystery"}},
		# One food tank to prove per-kind separation.
		{"type": "resource", "specs": {"name": "Pantry",
			"resource_kind": "biomass", "capacity_qty": 60.0, "level": 1.0,
			"capacity_unit": "kg"}},
	]
	var rows: Array = (s as Script).call("store_rows", items)
	_check("store_rows: two kinds survive filtering (got %d)" % rows.size(),
		rows.size() == 2)
	if rows.size() != 2:
		return
	var water: Dictionary = rows[0]
	var food: Dictionary = rows[1]
	_check("store_rows: water row first (model order)", str(water.get("kind")) == "water")
	_check("store_rows: water row named after the LARGEST tank, not the outlet",
		str(water.get("name")) == "Cistern", "got %s" % str(water.get("name")))
	_check("store_rows: water stock aggregates (100 + 250)",
		absf(float(water.get("stock")) - 350.0) < 0.01)
	_check("store_rows: water capacity aggregates (200 + 1000)",
		absf(float(water.get("cap")) - 1200.0) < 0.01)
	_check("store_rows: water counts both tanks", int(water.get("count")) == 2)
	var wtanks: Array = water.get("tanks", [])
	_check("store_rows: water carries per-tank breakdown (got %d)" % wtanks.size(),
		wtanks.size() == 2)
	if wtanks.size() == 2:
		_check("store_rows: tank rows keep model order",
			str((wtanks[0] as Dictionary).get("name")) == "Rain Barrel"
			and str((wtanks[1] as Dictionary).get("name")) == "Cistern")
	_check("store_rows: biomass row intact",
		str(food.get("kind")) == "biomass" and str(food.get("name")) == "Pantry"
		and int(food.get("count")) == 1)
