class_name MultiMonitorCatalog
extends RefCounted

## Catalog of views and dashboards that can run on secondary monitors.
##
## Every entry is pure metadata so `MultiMonitorPrefs`, the settings tab, and
## offline selftests can validate view IDs and inspect GPU/3D traits without
## instantiating any UI scenes.

const VIEW_SYSTEM_GRAPH        := "system_graph"
const VIEW_SYSTEM_GRAPH_SITE   := "system_graph_site"
const VIEW_SYSTEM_GRAPH_SCADA  := "system_graph_scada"
const VIEW_TCLAB_BIOCHAR       := "tclab_biochar"
const VIEW_TCLAB_GENSET        := "tclab_genset"
const VIEW_TCLAB_DESIGNER      := "tclab_designer"
const VIEW_BATTERYLAB          := "batterylab"
const VIEW_PVLAB               := "pvlab"
const VIEW_CTRLLAB             := "ctrllab"
const VIEW_ESPLAB              := "esplab"
const VIEW_SITE_REPORT         := "site_report"
const VIEW_COMMUNITY_SCHEDULE  := "community_schedule"
const VIEW_COMPARE_VIEW        := "compare_view"
const VIEW_SOLAR_DASHBOARD     := "solar_dashboard"
const VIEW_OVERHEAD_3D         := "overhead_3d"
const VIEW_WINDOW_WALL_SLOT    := "window_wall_slot"
const VIEW_PROJECTION_CANVAS   := "projection_canvas"
const VIEW_WINDLAB             := "windlab"
const VIEW_PELTONLAB           := "peltonlab"
const VIEW_CSPLAB              := "csplab"
const VIEW_GANTRYLAB           := "gantrylab"
const VIEW_DOMELAB             := "domelab"
const VIEW_VEHICLELAB          := "vehiclelab"
const VIEW_EARTHSHIPLAB        := "earthshiplab"
const VIEW_FLATPACK            := "flatpack"

const DEFAULT_VIEW := VIEW_SYSTEM_GRAPH

const GROUPS := [
	"Systems & Dashboards",
	"Process & Hardware Labs",
	"3D World Views",
	"Additional Designers",
]

static var _entries: Array[Dictionary] = []
static var _by_id: Dictionary = {}


static func entries() -> Array[Dictionary]:
	_ensure()
	return _entries


static func has_view(view_id: String) -> bool:
	_ensure()
	return _by_id.has(view_id)


static func entry(view_id: String) -> Dictionary:
	_ensure()
	if _by_id.has(view_id):
		return (_by_id[view_id] as Dictionary).duplicate(true)
	return (_by_id[DEFAULT_VIEW] as Dictionary).duplicate(true)


static func label_of(view_id: String) -> String:
	return str(entry(view_id).get("label", view_id))


static func short_label_of(view_id: String) -> String:
	return str(entry(view_id).get("short", label_of(view_id)))


static func shares_world_3d(view_id: String) -> bool:
	return bool(entry(view_id).get("shares_world_3d", false))


static func is_singleton_reparent(view_id: String) -> bool:
	return bool(entry(view_id).get("singleton_reparent", false))


static func is_system_graph_variant(view_id: String) -> bool:
	return view_id == VIEW_SYSTEM_GRAPH \
		or view_id == VIEW_SYSTEM_GRAPH_SITE \
		or view_id == VIEW_SYSTEM_GRAPH_SCADA


static func entries_in_group(group_name: String) -> Array[Dictionary]:
	_ensure()
	var out: Array[Dictionary] = []
	for e in _entries:
		if str(e.get("group", "")) == group_name:
			out.append(e)
	return out


static func _ensure() -> void:
	if not _entries.is_empty():
		return
	_entries = [
		# --- Systems & Dashboards ---
		{
			"id": VIEW_SYSTEM_GRAPH,
			"label": "Systems Graph — Schematic & Flow",
			"short": "Systems Graph",
			"group": "Systems & Dashboards",
			"icon": "git-branch",
			"shares_world_3d": false,
			"singleton_reparent": true,
			"portrait_friendly": true,
			"touch_friendly": true,
			"blurb": "Live interactive schematic of resource, power, water, and biomass flows. Great for a touchscreen.",
		},
		{
			"id": VIEW_SYSTEM_GRAPH_SITE,
			"label": "Systems Graph — Site Plan",
			"short": "Site Plan",
			"group": "Systems & Dashboards",
			"icon": "map",
			"shares_world_3d": false,
			"singleton_reparent": true,
			"portrait_friendly": true,
			"touch_friendly": true,
			"blurb": "Opens the Systems Graph directly in the spatial Site Plan lens.",
		},
		{
			"id": VIEW_SYSTEM_GRAPH_SCADA,
			"label": "Systems Graph — SCADA Operator Mode",
			"short": "SCADA Operator",
			"group": "Systems & Dashboards",
			"icon": "gauge",
			"shares_world_3d": false,
			"singleton_reparent": true,
			"portrait_friendly": true,
			"touch_friendly": true,
			"blurb": "Full-bleed process control mimic with touch-sized faceplates and locked graph layout.",
		},
		{
			"id": VIEW_SITE_REPORT,
			"label": "Site Report & Climate Infographic",
			"short": "Site Report",
			"group": "Systems & Dashboards",
			"icon": "bar-chart-2",
			"shares_world_3d": false,
			"singleton_reparent": false,
			"portrait_friendly": true,
			"touch_friendly": true,
			"blurb": "Year-round solar, PV, wind rose, precipitation, hydro, and crew time-use cards.",
		},
		{
			"id": VIEW_COMMUNITY_SCHEDULE,
			"label": "Community Schedule & Crew Rota",
			"short": "Community Schedule",
			"group": "Systems & Dashboards",
			"icon": "calendar",
			"shares_world_3d": false,
			"singleton_reparent": false,
			"portrait_friendly": true,
			"touch_friendly": true,
			"blurb": "Day, Week, Person, Work, and Balance timelines for settlement operations.",
		},
		{
			"id": VIEW_COMPARE_VIEW,
			"label": "Digital Twin vs. Home Assistant Compare",
			"short": "HA Compare",
			"group": "Systems & Dashboards",
			"icon": "git-compare",
			"shares_world_3d": false,
			"singleton_reparent": false,
			"portrait_friendly": true,
			"touch_friendly": true,
			"blurb": "Side-by-side comparison of simulated telemetry against recorded or live Home Assistant history.",
		},
		{
			"id": VIEW_SOLAR_DASHBOARD,
			"label": "Solar, Battery & Inverter Telemetry",
			"short": "Solar Telemetry",
			"group": "Systems & Dashboards",
			"icon": "sun",
			"shares_world_3d": false,
			"singleton_reparent": false,
			"portrait_friendly": true,
			"touch_friendly": true,
			"blurb": "Live PV input, battery state of charge, inverter load, and energy curves.",
		},

		# --- Process & Hardware Labs ---
		{
			"id": VIEW_TCLAB_BIOCHAR,
			"label": "Biochar Reactor + Condenser (Process Lab)",
			"short": "Biochar Reactor",
			"group": "Process & Hardware Labs",
			"icon": "flame",
			"shares_world_3d": false,
			"singleton_reparent": false,
			"portrait_friendly": true,
			"touch_friendly": true,
			"preset": "biochar_reactor",
			"process_mode": true,
			"blurb": "3D jacketed pyrolysis boiler + 3-column condenser in live Process Mode. Stacks vertically on Portrait screens.",
		},
		{
			"id": VIEW_TCLAB_GENSET,
			"label": "Biochar → Genset Chain (Process Lab)",
			"short": "Biochar → Genset",
			"group": "Process & Hardware Labs",
			"icon": "zap",
			"shares_world_3d": false,
			"singleton_reparent": false,
			"portrait_friendly": true,
			"touch_friendly": true,
			"preset": "biochar_genset",
			"process_mode": true,
			"blurb": "Biochar reactor feeding the barrel gasometer, dryer, and 48 V woodgas generator.",
		},
		{
			"id": VIEW_TCLAB_DESIGNER,
			"label": "Tri-Clamp Sanitary Process Designer",
			"short": "TC Process Lab",
			"group": "Process & Hardware Labs",
			"icon": "workflow",
			"shares_world_3d": false,
			"singleton_reparent": false,
			"portrait_friendly": true,
			"touch_friendly": false,
			"blurb": "Build and run custom vessels, condensers, stills, brewhouses, and filter trains.",
		},
		{
			"id": VIEW_BATTERYLAB,
			"label": "Battery Pack, BMS & Bank Lab",
			"short": "Battery Lab",
			"group": "Process & Hardware Labs",
			"icon": "battery-charging",
			"shares_world_3d": false,
			"singleton_reparent": false,
			"portrait_friendly": true,
			"touch_friendly": true,
			"blurb": "Cell chemistry, BMS trip curves, fault simulation, and parallel bank bench.",
		},
		{
			"id": VIEW_PVLAB,
			"label": "Solar Array & MPPT String Designer",
			"short": "PV Solar Lab",
			"group": "Process & Hardware Labs",
			"icon": "sun",
			"shares_world_3d": false,
			"singleton_reparent": false,
			"portrait_friendly": true,
			"touch_friendly": false,
			"blurb": "I-V / P-V curves, bypass-diode shading, string sizing, and racking studio.",
		},
		{
			"id": VIEW_CTRLLAB,
			"label": "Controller & Inverter Lab",
			"short": "Controller Lab",
			"group": "Process & Hardware Labs",
			"icon": "cpu",
			"shares_world_3d": false,
			"singleton_reparent": false,
			"portrait_friendly": true,
			"touch_friendly": false,
			"blurb": "Inverter/MPPT enclosure ports, breaker bay, and terminal wiring sheets.",
		},
		{
			"id": VIEW_ESPLAB,
			"label": "ESPHome Board & Sensor Twin Lab",
			"short": "ESPHome Lab",
			"group": "Process & Hardware Labs",
			"icon": "cpu",
			"shares_world_3d": false,
			"singleton_reparent": false,
			"portrait_friendly": true,
			"touch_friendly": false,
			"blurb": "Microcontroller GPIO solver, live sensor digital twin, and ESPHome YAML.",
		},

		# --- 3D World Views ---
		{
			"id": VIEW_OVERHEAD_3D,
			"label": "3D Site Overhead / Drone Camera",
			"short": "3D Overhead Cam",
			"group": "3D World Views",
			"icon": "video",
			"shares_world_3d": true,
			"singleton_reparent": false,
			"portrait_friendly": true,
			"touch_friendly": true,
			"blurb": "Live 3D camera watching the site from above (orbit/pan/zoom independently of the player).",
		},
		{
			"id": VIEW_WINDOW_WALL_SLOT,
			"label": "Window Wall Panoramic Panel",
			"short": "Window Wall Panel",
			"group": "3D World Views",
			"icon": "monitor",
			"shares_world_3d": true,
			"singleton_reparent": false,
			"portrait_friendly": true,
			"touch_friendly": false,
			"blurb": "Participates in the bezel-aligned off-axis frustum Window Wall (configure geometry below).",
		},
		{
			"id": VIEW_PROJECTION_CANVAS,
			"label": "Projection & Live Camera Feed",
			"short": "Projection Feed",
			"group": "3D World Views",
			"icon": "video",
			"shares_world_3d": true,
			"singleton_reparent": true,
			"portrait_friendly": false,
			"touch_friendly": false,
			"blurb": "Side-by-side simulated camera + live webcam / synced timelapse feed with corner-pin warp.",
		},

		# --- Additional Designers ---
		{
			"id": VIEW_WINDLAB,
			"label": "Wind Turbine Designer",
			"short": "Wind Lab",
			"group": "Additional Designers",
			"icon": "wind",
			"shares_world_3d": false,
			"singleton_reparent": false,
			"portrait_friendly": true,
			"touch_friendly": false,
			"blurb": "Blade aerodynamics, Cp curves, stepper/PM generator matching, and annual yield.",
		},
		{
			"id": VIEW_PELTONLAB,
			"label": "Pelton Hydro Wheel Designer",
			"short": "Pelton Lab",
			"group": "Additional Designers",
			"icon": "droplets",
			"shares_world_3d": false,
			"singleton_reparent": false,
			"portrait_friendly": true,
			"touch_friendly": false,
			"blurb": "Runner PCD, nozzle jet sizing, bucket count, and turbine efficiency curves.",
		},
		{
			"id": VIEW_CSPLAB,
			"label": "Solar Concentrator Designer",
			"short": "CSP Lab",
			"group": "Additional Designers",
			"icon": "sun",
			"shares_world_3d": false,
			"singleton_reparent": false,
			"portrait_friendly": true,
			"touch_friendly": false,
			"blurb": "Parabolic dish, trough, CPC, Fresnel lens, and heliostat ray-traced optics.",
		},
		{
			"id": VIEW_GANTRYLAB,
			"label": "CNC & Gantry Machine Designer",
			"short": "Gantry Lab",
			"group": "Additional Designers",
			"icon": "box",
			"shares_world_3d": false,
			"singleton_reparent": false,
			"portrait_friendly": true,
			"touch_friendly": false,
			"blurb": "CoreXY, Cartesian, and Delta kinematics, G-code toolpath planner, and V-slot mates.",
		},
		{
			"id": VIEW_DOMELAB,
			"label": "Geodesic Dome & Zome Designer",
			"short": "Dome Lab",
			"group": "Additional Designers",
			"icon": "tent",
			"shares_world_3d": false,
			"singleton_reparent": false,
			"portrait_friendly": true,
			"touch_friendly": false,
			"blurb": "Goldberg-Coxeter domes, polar zonohedra, nexorades, and folded plate schedules.",
		},
		{
			"id": VIEW_VEHICLELAB,
			"label": "Living Vehicle & Camper Designer",
			"short": "Vehicle Lab",
			"group": "Additional Designers",
			"icon": "truck",
			"shares_world_3d": false,
			"singleton_reparent": false,
			"portrait_friendly": true,
			"touch_friendly": false,
			"blurb": "Vans, skoolies, box trucks, and trailers with axle weights, solar roof, and floorplan.",
		},
		{
			"id": VIEW_EARTHSHIPLAB,
			"label": "Earthship Passive-Solar Designer",
			"short": "Earthship Lab",
			"group": "Additional Designers",
			"icon": "home",
			"shares_world_3d": false,
			"singleton_reparent": false,
			"portrait_friendly": true,
			"touch_friendly": false,
			"blurb": "Tire-berm thermal mass rooms, south greenhouse glazing, cisterns, and earthworks.",
		},
		{
			"id": VIEW_FLATPACK,
			"label": "Flat-Pack CNC Furniture Designer",
			"short": "Flat-Pack Lab",
			"group": "Additional Designers",
			"icon": "layers",
			"shares_world_3d": false,
			"singleton_reparent": false,
			"portrait_friendly": true,
			"touch_friendly": false,
			"blurb": "Slot-together plywood furniture with cross-lap joints, sheet nesting, and DXF export.",
		},
	]
	_by_id.clear()
	for e in _entries:
		_by_id[str(e["id"])] = e
