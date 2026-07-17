class_name ComponentPresets
extends RefCounted
## Static catalogue of component presets ported from the LinkageLab webapp.
## All values are in SI units (W, V, A, kWh).  Costs are in USD.
## Node type strings must match GraphCanvas.HANDLES / NODE_SIZES keys.

const _GraphCanvas := preload("res://system_graph/graph_canvas.gd")


## Canonical library-spawn footprint from NODE_SIZES (Phase 4).
static func spawn_dimensions(preset: Dictionary) -> Vector2:
	var t := str(preset.get("type", ""))
	return Vector2(_GraphCanvas.default_width(t), _GraphCanvas.default_height(t))

# ---------------------------------------------------------------------------
# Solar Panels  (type = "panel")
# ---------------------------------------------------------------------------
const PANELS: Array = [
	{
		"type": "panel", "label": "Generic 250W", "icon": "☀",
		"width": 120.0, "height": 100.0,
		"specs": { "name": "Generic 250W",         "wmp": 250.0, "voc": 37.5, "vmp": 30.5, "isc": 8.80, "imp": 8.20, "cost": 120.0 },
	},
	{
		"type": "panel", "label": "Alrska Flex 100W", "icon": "☀",
		"width": 120.0, "height": 100.0,
		"specs": { "name": "Alrska Flexible 100W", "wmp": 100.0, "voc": 21.6, "vmp": 18.0, "isc": 6.10, "imp": 5.56, "cost":  80.0 },
	},
	{
		"type": "panel", "label": "EcoFlow 400W Rigid", "icon": "☀",
		"width": 120.0, "height": 100.0,
		"specs": { "name": "EcoFlow 400W Rigid",   "wmp": 400.0, "voc": 48.0, "vmp": 41.0, "isc":11.00, "imp": 9.76, "cost": 300.0 },
	},
	{
		"type": "panel", "label": "REC Alpha 410W", "icon": "☀",
		"width": 120.0, "height": 100.0,
		"specs": { "name": "REC Alpha Pure 410W",  "wmp": 410.0, "voc": 40.5, "vmp": 34.2, "isc":12.70, "imp":12.00, "cost": 350.0 },
	},
	{
		"type": "panel", "label": "SunPower Maxeon 430W", "icon": "☀",
		"width": 120.0, "height": 100.0,
		"specs": { "name": "SunPower Maxeon 430W", "wmp": 430.0, "voc": 47.6, "vmp": 39.8, "isc":11.50, "imp":10.81, "cost": 450.0 },
	},
	{
		"type": "panel", "label": "BougeRV CIGS 200W", "icon": "☀",
		"width": 120.0, "height": 100.0,
		"specs": { "name": "BougeRV CIGS 200W",    "wmp": 200.0, "voc": 34.0, "vmp": 28.0, "isc": 7.50, "imp": 7.14, "cost": 280.0 },
	},
]

# ---------------------------------------------------------------------------
# Batteries  (type = "battery")
# ---------------------------------------------------------------------------
const BATTERIES: Array = [
	{
		"type": "battery", "label": "12V 100Ah LiFePO4", "icon": "🔋",
		"width": 110.0, "height": 80.0,
		"specs": { "name": "12V 100Ah LiFePO4",      "voltage": 12.8, "ah": 100.0, "kwh": 1.28, "soc": 0.80, "cost":  400.0 },
	},
	{
		"type": "battery", "label": "12V 200Ah LiFePO4", "icon": "🔋",
		"width": 110.0, "height": 80.0,
		"specs": { "name": "12V 200Ah LiFePO4",      "voltage": 12.8, "ah": 200.0, "kwh": 2.56, "soc": 0.80, "cost":  700.0 },
	},
	{
		"type": "battery", "label": "12V 100Ah AGM", "icon": "🔋",
		"width": 110.0, "height": 80.0,
		"specs": { "name": "12V 100Ah AGM",           "voltage": 12.0, "ah": 100.0, "kwh": 1.20, "soc": 0.50, "cost":  200.0 },
	},
	{
		"type": "battery", "label": "48V 50Ah LiFePO4", "icon": "🔋",
		"width": 100.0, "height": 136.0,
		"specs": { "name": "48V 50Ah LiFePO4",       "voltage": 51.2, "ah": 50.0, "kwh": 2.56, "soc": 0.80, "cost": 650.0 },
	},
	{
		"type": "battery", "label": "48V 100Ah LiFePO4", "icon": "🔋",
		"width": 110.0, "height": 80.0,
		"specs": { "name": "48V 100Ah LiFePO4",      "voltage": 51.2, "ah": 100.0, "kwh": 5.12, "soc": 0.80, "cost": 1500.0 },
	},
	{
		"type": "battery", "label": "EG4 48V 200Ah", "icon": "🔋",
		"width": 110.0, "height": 80.0,
		"specs": { "name": "EG4 48V 200Ah LiFePO4",  "voltage": 51.2, "ah": 200.0, "kwh":10.24, "soc": 0.80, "cost": 2600.0 },
	},
	{
		"type": "battery", "label": "Server Rack 48V 100Ah", "icon": "🔋",
		"width": 110.0, "height": 80.0,
		"specs": { "name": "Server Rack 48V 100Ah",  "voltage": 51.2, "ah": 100.0, "kwh": 5.12, "soc": 0.80, "cost": 1200.0 },
	},
]

# ---------------------------------------------------------------------------
# Charge Controllers / Inverters  (type = "controller")
# ---------------------------------------------------------------------------
const CONTROLLERS: Array = [
	{
		"type": "controller", "label": "EcoWorthy SL3500", "icon": "🎛",
		"width": 140.0, "height": 120.0,
		"specs": {
			"name": "EcoWorthy SL3500 Hybrid", "max_voc": 450.0, "max_charge_amps": 80.0,
			"max_pv_watts": 3500.0, "cost": 900.0, "overload_watts": 3500.0,
			"overload_duration_s": 10.0, "overload_lockout_s": 30.0,
		},
	},
	{
		"type": "controller", "label": "Generic MPPT 150/50", "icon": "🎛",
		"width": 140.0, "height": 120.0,
		"specs": { "name": "Generic MPPT 150/50",       "max_voc": 150.0, "max_charge_amps": 50.0, "max_pv_watts": 2400.0, "cost": 250.0 },
	},
	{
		"type": "controller", "label": "Victron 150/35", "icon": "🎛",
		"width": 140.0, "height": 120.0,
		"specs": { "name": "Victron SmartSolar 150/35", "max_voc": 150.0, "max_charge_amps": 35.0, "max_pv_watts": 2000.0, "cost": 380.0 },
	},
	{
		"type": "controller", "label": "Victron 100/20", "icon": "🎛",
		"width": 140.0, "height": 120.0,
		"specs": { "name": "Victron SmartSolar 100/20", "max_voc": 100.0, "max_charge_amps": 20.0, "max_pv_watts":  580.0, "cost": 150.0 },
	},
	{
		"type": "controller", "label": "Renogy Rover 40A", "icon": "🎛",
		"width": 140.0, "height": 120.0,
		"specs": { "name": "Renogy Rover 40A MPPT",     "max_voc": 100.0, "max_charge_amps": 40.0, "max_pv_watts": 1040.0, "cost": 160.0 },
	},
	{
		"type": "controller", "label": "PowMR 5000W Hybrid", "icon": "🎛",
		"width": 140.0, "height": 120.0,
		"specs": { "name": "PowMR 5000W Hybrid Inv.",   "max_voc": 500.0, "max_charge_amps": 80.0, "max_pv_watts": 5500.0, "cost": 650.0 },
	},
	{
		"type": "controller", "label": "EcoFlow DELTA Pro", "icon": "🎛",
		"width": 140.0, "height": 120.0,
		"specs": { "name": "EcoFlow DELTA Pro",         "max_voc": 150.0, "max_charge_amps": 15.0, "max_pv_watts": 1600.0, "cost":3000.0 },
	},
	{
		"type": "controller", "label": "EG4 6000XP", "icon": "🎛",
		"width": 140.0, "height": 120.0,
		"specs": { "name": "EG4 6000XP Hybrid",         "max_voc": 500.0, "max_charge_amps":120.0, "max_pv_watts": 8000.0, "cost":1450.0 },
	},
]

# ---------------------------------------------------------------------------
# Appliances & Loads  (type = "appliance")
# ---------------------------------------------------------------------------
const APPLIANCES: Array = [
	{
		"type": "appliance", "label": "Custom Load",     "icon": "⚡",
		"width": 160.0, "height": 104.0,
		"specs": { "name": "Custom Load",         "max_watts": 100.0, "avg_watts":   50.0 },
	},
	{
		"type": "appliance", "label": "LED Light",       "icon": "💡",
		"width": 160.0, "height": 104.0,
		"specs": { "name": "LED Light",           "max_watts":  15.0, "avg_watts":   10.0 },
	},
	{
		"type": "appliance", "label": "Laptop",          "icon": "💻",
		"width": 160.0, "height": 104.0,
		"specs": { "name": "Laptop",              "max_watts":  65.0, "avg_watts":   45.0 },
	},
	{
		"type": "appliance", "label": "Desktop PC",      "icon": "🖥",
		"width": 160.0, "height": 104.0,
		"specs": { "name": "Desktop PC",          "max_watts": 500.0, "avg_watts":  200.0 },
	},
	{
		"type": "appliance", "label": "TV (LED 55\")",   "icon": "📺",
		"width": 160.0, "height": 104.0,
		"specs": { "name": "TV (LED 55\")",       "max_watts": 120.0, "avg_watts":   80.0 },
	},
	{
		"type": "appliance", "label": "Refrigerator",    "icon": "🧊",
		"width": 160.0, "height": 104.0,
		"specs": { "name": "Refrigerator",        "max_watts": 400.0, "avg_watts":  150.0 },
	},
	{
		"type": "appliance", "label": "Space Heater",    "icon": "🔥",
		"width": 160.0, "height": 104.0,
		"specs": { "name": "Space Heater",        "max_watts":1500.0, "avg_watts": 1500.0 },
	},
	{
		"type": "appliance", "label": "Window AC",       "icon": "❄",
		"width": 160.0, "height": 104.0,
		"specs": { "name": "Window AC",           "max_watts":1400.0, "avg_watts": 1000.0 },
	},
	{
		"type": "appliance", "label": "EUC/Ebike Charger","icon": "🛴",
		"width": 160.0, "height": 104.0,
		"specs": { "name": "EUC/Ebike Charger",   "max_watts": 300.0, "avg_watts":  250.0 },
	},
	{
		"type": "appliance", "label": "Phone Charger",   "icon": "📱",
		"width": 160.0, "height": 104.0,
		"specs": { "name": "Phone Charger",       "max_watts":  20.0, "avg_watts":   15.0 },
	},
	# Wave 8 lights-as-wires: the AC wire INTO these loads renders in 3D as the
	# light string itself (ConduitKinds light kinds — bulbs along a catenary).
	# `light_conduit` auto-sets conduit_type on connect (GraphModel.add_connection);
	# `watts_per_m` scales the draw with the routed 3D length (GraphAcLoad).
	{
		"type": "appliance", "label": "Patio String Lights", "icon": "🌃",
		"width": 160.0, "height": 104.0,
		"specs": { "name": "Patio String Lights", "max_watts": 50.0, "avg_watts": 33.0,
			"watts_per_m": 3.3, "light_conduit": "led_patio" },
	},
	{
		"type": "appliance", "label": "LED Strip (12 V)", "icon": "🟨",
		"width": 160.0, "height": 104.0,
		"specs": { "name": "LED Strip (12 V)",    "max_watts": 90.0, "avg_watts": 70.0,
			"watts_per_m": 14.0, "light_conduit": "led_strip" },
	},
	{
		"type": "appliance", "label": "Fairy Lights",     "icon": "✨",
		"width": 160.0, "height": 104.0,
		"specs": { "name": "Fairy Lights",        "max_watts": 12.0, "avg_watts": 6.0,
			"watts_per_m": 0.6, "light_conduit": "led_fairy" },
	},
]

# ---------------------------------------------------------------------------
# Processors  (type = "processor")
# Energy via power_in (AC, top port) or energy_in (other kinds, top port).
# Resource I/O on left (in) / right (out).
# ---------------------------------------------------------------------------
const PROCESSORS: Array = [
	{
		"type": "processor", "label": "Water Pump",    "icon": "💧",
		"width": 130.0, "height": 120.0,
		"specs": {
			"name": "Water Pump", "watts": 500.0, "cost": 80.0,
			"energy_source": "ac",
			"efficiency": 0.92, "energy_wh_per_unit": 10.0,
			"inputs": [],
			"outputs": [{"kind": "water", "rate": 50.0, "unit": "L/h"}],
			"output_rate": "50 L/h",
		},
	},
	{
		"type": "processor", "label": "Plastic Shredder", "icon": "✂",
		"width": 140.0, "height": 130.0,
		"specs": {
			"name": "Plastic Shredder", "watts": 800.0, "cost": 450.0,
			"energy_source": "ac",
			"efficiency": 0.95, "energy_wh_per_unit": 16.0,
			"inputs": [{"kind": "plastic_waste", "rate": 5.0, "unit": "kg/h"}],
			"outputs": [{"kind": "plastic_shred", "rate": 4.8, "unit": "kg/h"}],
		},
	},
	{
		"type": "processor", "label": "Biochar Reactor", "icon": "🔥",
		"width": 150.0, "height": 140.0,
		"specs": {
			"name": "Biochar Reactor", "watts": 1200.0, "cost": 2200.0,
			"energy_source": "ac",
			"efficiency": 0.88, "energy_wh_per_unit": 240.0,
			"inputs": [{"kind": "biomass", "rate": 8.0, "unit": "kg/h"}],
			"outputs": [
				{"kind": "biochar", "rate": 2.5, "unit": "kg/h"},
				{"kind": "hot_water", "rate": 30.0, "unit": "L/h"},
				{"kind": "woodgas", "rate": 4.0, "unit": "m³/h"},
			],
		},
	},
	{
		"type": "processor", "label": "Well Pump",     "icon": "🏗",
		"width": 130.0, "height": 120.0,
		"specs": {
			"name": "Well Pump", "watts": 1500.0, "cost": 350.0,
			"energy_source": "ac",
			"efficiency": 0.90, "energy_wh_per_unit": 10.0,
			"inputs": [],
			"outputs": [{"kind": "water", "rate": 150.0, "unit": "L/h"}],
			"output_rate": "150 L/h",
		},
	},
	{
		"type": "processor", "label": "Mini-Split AC", "icon": "❄",
		"width": 130.0, "height": 120.0,
		"specs": {
			"name": "Mini-Split AC", "watts": 900.0, "cost": 700.0,
			"energy_source": "ac",
			"efficiency": 1.0, "energy_wh_per_unit": 0.1,
			"inputs": [],
			"outputs": [{"kind": "thermal", "rate": 9000.0, "unit": "BTU/h"}],
			"output_rate": "9000 BTU/h",
		},
	},
	{
		"type": "processor", "label": "Water Heater",  "icon": "🔥",
		"width": 130.0, "height": 120.0,
		"specs": {
			"name": "Electric Water Heater", "watts": 4500.0, "cost": 500.0,
			"energy_source": "ac",
			"efficiency": 0.98, "energy_wh_per_unit": 112.5,
			"inputs": [{"kind": "water", "rate": 40.0, "unit": "L/h"}],
			"outputs": [{"kind": "hot_water", "rate": 40.0, "unit": "L/h"}],
			"output_rate": "40 gal",
		},
	},
	{
		"type": "processor", "label": "EV Charger L2",  "icon": "🚗",
		"width": 130.0, "height": 120.0,
		"specs": {
			"name": "EV Charger (Level 2)", "watts": 7200.0, "cost": 500.0,
			"energy_source": "ac",
			"efficiency": 0.95, "energy_wh_per_unit": 288.0,
			"inputs": [],
			"outputs": [{"kind": "electric", "rate": 25.0, "unit": "kWh/h"}],
			"output_rate": "25 mi/h",
		},
	},
	{
		"type": "processor", "label": "Greywater Filter", "icon": "🚿",
		"width": 140.0, "height": 130.0,
		"specs": {
			"name": "Greywater Filter", "watts": 40.0, "cost": 180.0,
			"energy_source": "ac",
			"efficiency": 0.85, "energy_wh_per_unit": 0.8,
			"inputs": [{"kind": "greywater", "rate": 20.0, "unit": "L/h"}],
			"outputs": [{"kind": "water", "rate": 17.0, "unit": "L/h"}],
		},
	},
	{
		"type": "processor", "label": "Compost Digester", "icon": "🌱",
		"width": 140.0, "height": 130.0,
		"specs": {
			"name": "Compost Digester", "watts": 0.0, "cost": 120.0,
			"energy_source": "",
			"efficiency": 0.70, "energy_wh_per_unit": 0.0,
			"inputs": [
				{"kind": "biomass", "rate": 2.0, "unit": "kg/h"},
				{"kind": "blackwater", "rate": 1.0, "unit": "L/h"},
			],
			"outputs": [{"kind": "nutrients", "rate": 1.5, "unit": "kg/h"}],
		},
	},
	{
		"type": "processor", "label": "IBC Biodigester", "icon": "♻",
		"width": 160.0, "height": 150.0,
		"specs": {
			"name": "Solar Citi3s IBC Biodigester", "watts": 12.5, "cost": 950.0,
			"energy_source": "ac",
			"efficiency": 0.85, "energy_wh_per_unit": 15.0,
			"processor_template": "ibc_biodigester",
			"daily_note": "5 gal blackwater + 1 kg scraps + 300 Wh → 5 gal effluent + 1 m³ biogas",
			"inputs": [
				{"kind": "blackwater", "rate": 0.7886, "unit": "L/h"},
				{"kind": "biomass", "rate": 0.04167, "unit": "kg/h"},
			],
			"outputs": [
				{"kind": "liquid_fertilizer", "rate": 0.7886, "unit": "L/h"},
				{"kind": "biogas", "rate": 0.04167, "unit": "m³/h"},
			],
		},
	},
	{
		# Woodgas/syngas → 48VDC generator: its "dc_electricity" output entry
		# gets a +/- port pair (see graph_port_service.gd) that wires straight
		# into a battery's positive/negative ports, or a controller's
		# pvPositive/pvNegative — no separate controller node needed. DC
		# output is derived each tick from actual fuel throughput ×
		# energy_wh_per_unit × efficiency (ResourceFlowEngine._process_processor),
		# not a flat number — the fuel tank running dry throttles it for real.
		"type": "processor", "label": "Woodgas DC Generator", "icon": "⚡",
		"width": 150.0, "height": 140.0,
		"specs": {
			"name": "Woodgas DC Generator", "watts": 0.0, "cost": 1800.0,
			"energy_source": "",
			"efficiency": 0.85,
			# Wh of DC electricity produced per m³ of woodgas consumed
			# (producer-gas LHV ballpark ~1-1.7 kWh/m³); 1000 Wh/m³ keeps peak
			# output at the default 3.0 m³/h fuel rate (~2.55 kW) matching the
			# old flat-48VDC-generator's 3.0kW*0.85 peak.
			"energy_wh_per_unit": 1000.0,
			"current_output_kw": 0.0,
			"daily_note": "DC output scales with fuel throughput — wire the +/- ports straight to a battery's +/-, or a controller's pvPositive/pvNegative.",
			"inputs": [{"kind": "woodgas", "rate": 3.0, "unit": "m³/h"}],
			"outputs": [{"kind": "dc_electricity", "rate": 3.0, "unit": "kW"}],
			# Default automation: run only while fuel is connected/available
			# (enforced by the normal empty-input block, not by a condition
			# here) AND the battery needs it.
			"graph_automations": [
				{
					"alias": "On below 20% battery",
					"triggers": [{"kind": "numeric", "entity_id": "sensor.battery_level", "below": 20.0}],
					"conditions": [],
					"actions": [{"kind": "scene_node", "command": "turn_on"}],
				},
				{
					"alias": "Off above 80% battery",
					"triggers": [{"kind": "numeric", "entity_id": "sensor.battery_level", "above": 80.0}],
					"conditions": [],
					"actions": [{"kind": "scene_node", "command": "turn_off"}],
				},
			],
		},
	},
	# Boundary imports — infinite supply that counts AGAINST closure score.
	# Earth play allows partial openness; Moon/Mars challenges forbid these.
	{
		"type": "processor", "label": "Grid Import", "icon": "🔌",
		"width": 130.0, "height": 110.0,
		"specs": {
			"name": "Grid Import", "role": "import",
			"counts_as_import": true,
			"watts": 0.0, "cost": 0.0,
			"energy_source": "",
			"efficiency": 1.0, "energy_wh_per_unit": 0.0,
			"inputs": [],
			"outputs": [{"kind": "electric", "rate": 5.0, "unit": "kWh/h"}],
		},
	},
	{
		"type": "processor", "label": "Water Truck", "icon": "🚚",
		"width": 130.0, "height": 110.0,
		"specs": {
			"name": "Water Truck", "role": "import",
			"counts_as_import": true,
			"watts": 0.0, "cost": 0.0,
			"energy_source": "",
			"efficiency": 1.0, "energy_wh_per_unit": 0.0,
			"inputs": [],
			"outputs": [{"kind": "water", "rate": 200.0, "unit": "L/h"}],
		},
	},
	{
		"type": "processor", "label": "Food Delivery", "icon": "📦",
		"width": 130.0, "height": 110.0,
		"specs": {
			"name": "Food Delivery", "role": "import",
			"counts_as_import": true,
			"watts": 0.0, "cost": 0.0,
			"energy_source": "",
			"efficiency": 1.0, "energy_wh_per_unit": 0.0,
			"inputs": [],
			"outputs": [{"kind": "food", "rate": 2.0, "unit": "kg/h"}],
		},
	},
]

# ---------------------------------------------------------------------------
# Habitats  (type = "processor", specs.role = "habitat")
# Mouths to feed. Rates are per-occupant; ResourceFlowEngine multiplies by
# specs.occupants. Water split: ~80% greywater / ~20% blackwater (WHO/UNEP
# domestic wastewater fractions). Food scraps ~20% of intake as wet biomass.
# ---------------------------------------------------------------------------
const HABITATS: Array = [
	{
		"type": "processor", "label": "Population", "icon": "🏠",
		"width": 150.0, "height": 150.0,
		"specs": {
			"name": "Population", "role": "habitat", "occupants": 1,
			"watts": 0.0, "cost": 0.0,
			"energy_source": "",
			"efficiency": 1.0, "energy_wh_per_unit": 0.0,
			"inputs": [
				{"kind": "water", "rate": 2.083, "unit": "L/h"},
				{"kind": "food", "rate": 0.0625, "unit": "kg/h"},
			],
			"outputs": [
				{"kind": "greywater", "rate": 1.666, "unit": "L/h"},
				{"kind": "blackwater", "rate": 0.417, "unit": "L/h"},
				{"kind": "biomass", "rate": 0.0125, "unit": "kg/h"},
			],
		},
	},
]

# ---------------------------------------------------------------------------
# Resource containers  (type = "resource")
# Stores a non-electrical resource; level driven by ResourceFlowEngine timeline.
# Handles: input (resource, left) | output (resource, right)
# ---------------------------------------------------------------------------
const RESOURCES: Array = [
	{
		"type": "resource", "label": "Water Tank (50 gal)",  "icon": "🪣",
		"width": 90.0, "height": 100.0,
		"specs": {
			"name": "Water Tank", "resource_kind": "water",
			"capacity": "50 gal", "capacity_qty": 189.0, "capacity_unit": "L",
			"level": 0.5, "cost": 60.0,
		},
	},
	{
		"type": "resource", "label": "Water Tank (250 gal)", "icon": "🪣",
		"width": 90.0, "height": 100.0,
		"specs": {
			"name": "Water Tank 250", "resource_kind": "water",
			"capacity": "250 gal", "capacity_qty": 946.0, "capacity_unit": "L",
			"level": 0.5, "cost": 200.0,
		},
	},
	{
		"type": "resource", "label": "Waste Plastic Bin", "icon": "♻",
		"width": 90.0, "height": 100.0,
		"specs": {
			"name": "Waste Plastic Bin", "resource_kind": "plastic_waste",
			"capacity": "200 kg", "capacity_qty": 200.0, "capacity_unit": "kg",
			"level": 0.3, "cost": 40.0,
		},
	},
	{
		"type": "resource", "label": "Shredded Plastic", "icon": "✂",
		"width": 90.0, "height": 100.0,
		"specs": {
			"name": "Shredded Plastic Store", "resource_kind": "plastic_shred",
			"capacity": "100 kg", "capacity_qty": 100.0, "capacity_unit": "kg",
			"level": 0.0, "cost": 80.0,
		},
	},
	{
		"type": "resource", "label": "Biomass Store", "icon": "🌿",
		"width": 90.0, "height": 100.0,
		"specs": {
			"name": "Biomass Store", "resource_kind": "biomass",
			"capacity": "500 kg", "capacity_qty": 500.0, "capacity_unit": "kg",
			"level": 0.6, "cost": 120.0,
		},
	},
	{
		"type": "resource", "label": "Biochar Store", "icon": "🔥",
		"width": 90.0, "height": 100.0,
		"specs": {
			"name": "Biochar Store", "resource_kind": "biochar",
			"capacity": "150 kg", "capacity_qty": 150.0, "capacity_unit": "kg",
			"level": 0.0, "cost": 90.0,
		},
	},
	{
		"type": "resource", "label": "Propane Tank (100 lb)","icon": "🛢",
		"width": 90.0, "height": 100.0,
		"specs": {
			"name": "Propane Tank", "resource_kind": "propane",
			"capacity": "100 lb", "capacity_qty": 45.0, "capacity_unit": "kg",
			"level": 0.7, "cost": 120.0,
		},
	},
	{
		"type": "resource", "label": "Thermal Storage",      "icon": "♨",
		"width": 90.0, "height": 100.0,
		"specs": {
			"name": "Thermal Buffer", "resource_kind": "thermal",
			"capacity": "80 gal", "capacity_qty": 302.0, "capacity_unit": "L",
			"level": 0.5, "cost": 350.0,
		},
	},
	{
		"type": "resource", "label": "Steam Buffer", "icon": "💨",
		"width": 90.0, "height": 100.0,
		"specs": {
			"name": "Steam Buffer", "resource_kind": "steam",
			"capacity": "50 kg", "capacity_qty": 50.0, "capacity_unit": "kg",
			"level": 0.0, "cost": 200.0,
		},
	},
	{
		"type": "resource", "label": "Food Store (50 kg)", "icon": "🍎",
		"width": 90.0, "height": 100.0,
		"specs": {
			"name": "Food Store", "resource_kind": "food",
			"capacity": "50 kg", "capacity_qty": 50.0, "capacity_unit": "kg",
			"level": 0.8, "cost": 40.0,
		},
	},
	{
		"type": "resource", "label": "Greywater Tank", "icon": "🚿",
		"width": 90.0, "height": 100.0,
		"specs": {
			"name": "Greywater Tank", "resource_kind": "greywater",
			"capacity": "200 L", "capacity_qty": 200.0, "capacity_unit": "L",
			"level": 0.0, "cost": 80.0,
		},
	},
	{
		"type": "resource", "label": "Blackwater Tank", "icon": "🚽",
		"width": 90.0, "height": 100.0,
		"specs": {
			"name": "Blackwater Tank", "resource_kind": "blackwater",
			"capacity": "100 L", "capacity_qty": 100.0, "capacity_unit": "L",
			"level": 0.0, "cost": 90.0,
		},
	},
	{
		"type": "resource", "label": "Nutrient Store", "icon": "🌱",
		"width": 90.0, "height": 100.0,
		"specs": {
			"name": "Nutrient Store", "resource_kind": "nutrients",
			"capacity": "100 kg", "capacity_qty": 100.0, "capacity_unit": "kg",
			"level": 0.0, "cost": 50.0,
		},
	},
	{
		"type": "resource", "label": "Liquid Fertilizer Tank", "icon": "🧪",
		"width": 90.0, "height": 100.0,
		"specs": {
			"name": "Liquid Fertilizer Tank", "resource_kind": "liquid_fertilizer",
			"capacity": "200 L", "capacity_qty": 200.0, "capacity_unit": "L",
			"level": 0.0, "cost": 75.0,
		},
	},
	{
		"type": "resource", "label": "Biogas Store", "icon": "💨",
		"width": 90.0, "height": 100.0,
		"specs": {
			"name": "Biogas Store", "resource_kind": "biogas",
			"capacity": "10 m³", "capacity_qty": 10.0, "capacity_unit": "m³",
			"level": 0.0, "cost": 120.0,
		},
	},
]

# ---------------------------------------------------------------------------
# Planetary Basic Income (type = "pbi") — fundamental SoI sources.
# Always present on the graph; locked / non-removable.
# ---------------------------------------------------------------------------
const PBIS: Array = [
	{
		"type": "pbi", "label": "Sunlight", "icon": "☀",
		"width": 128.0, "height": 128.0, "locked": true,
		"specs": {
			"name": "Sunlight", "resource_kind": "sunlight",
			"fundamental": true, "locked": true,
		},
	},
	{
		"type": "pbi", "label": "Rain", "icon": "🌧",
		"width": 128.0, "height": 128.0, "locked": true,
		"specs": {
			"name": "Rain", "resource_kind": "water",
			"fundamental": true, "locked": true,
		},
	},
	{
		"type": "pbi", "label": "Wind", "icon": "🌬",
		"width": 128.0, "height": 128.0, "locked": true,
		"specs": {
			"name": "Wind", "resource_kind": "wind",
			"fundamental": true, "locked": true,
		},
	},
]

# ---------------------------------------------------------------------------
# Rain catchment sources  (type = "catchment")
# Credits captured rainwater into connected water tanks via ResourceFlowEngine.
# ---------------------------------------------------------------------------
const CATCHMENTS: Array = [
	{
		"type": "catchment", "label": "SoI Rain Catchment", "icon": "🌧",
		"width": 110.0, "height": 90.0,
		"specs": {
			"name": "SoI Rain Catchment", "catchment_kind": "rain",
			"use_soi_area": true, "area_m2": 50.0, "runoff_coeff": 0.75, "cost": 0.0,
		},
	},
	{
		"type": "catchment", "label": "Roof Catchment (50 m²)", "icon": "🌧",
		"width": 110.0, "height": 90.0,
		"specs": {
			"name": "Roof Catchment", "area_m2": 50.0, "runoff_coeff": 0.85, "cost": 0.0,
		},
	},
	{
		"type": "catchment", "label": "Ground Catchment (200 m²)", "icon": "🌧",
		"width": 110.0, "height": 90.0,
		"specs": {
			"name": "Ground Catchment", "area_m2": 200.0, "runoff_coeff": 0.70, "cost": 0.0,
		},
	},
]

# ---------------------------------------------------------------------------
# Grow beds / plants  (type = "plant")
# Monteith LUE: ambient PAR × area × LUE → biomass; water required, nutrients
# optional. Sunlight is non-blocking (no radiant wire needed).
# ---------------------------------------------------------------------------
const PLANTS: Array = [
	{
		"type": "plant", "label": "Grow Bed (10 m²)", "icon": "🌱",
		"width": 160.0, "height": 130.0,
		"specs": {
			"name": "Grow Bed", "area_m2": 10.0, "use_soi_area": false,
			"lue_g_per_mj": 2.0, "water_l_per_kg": 50.0, "nutrient_kg_per_kg": 0.02,
			"sunlight_factor": 1.0, "cost": 200.0,
			# 3D link: Place in world → procedural grow bed + bound graph node.
			"model_id": "grow_bed",
		},
	},
	{
		"type": "plant", "label": "Garden Plot (50 m²)", "icon": "🌱",
		"width": 160.0, "height": 130.0,
		"specs": {
			"name": "Garden Plot", "area_m2": 50.0, "use_soi_area": false,
			"lue_g_per_mj": 2.0, "water_l_per_kg": 50.0, "nutrient_kg_per_kg": 0.02,
			"sunlight_factor": 1.0, "cost": 500.0,
			"model_id": "grow_bed",
		},
	},
	{
		"type": "plant", "label": "SoI Canopy Bed", "icon": "🌳",
		"width": 160.0, "height": 130.0,
		"specs": {
			"name": "SoI Canopy Bed", "area_m2": 100.0, "use_soi_area": true,
			"lue_g_per_mj": 1.5, "water_l_per_kg": 40.0, "nutrient_kg_per_kg": 0.015,
			"sunlight_factor": 1.0, "cost": 0.0,
		},
	},
]

# ---------------------------------------------------------------------------
# Smart Circuit Monitors / AC distribution  (shelly4pm, spiderbox, breaker_panel)
#
# AC passthrough model (used by GraphAcLoad):
#   AC feed → ac_in → N switched circuit_* outlets.
#   When channel cN_on is false, loads wired to circuit_N are unreachable and
#   draw 0 W (they do not contribute to the AC bus balance).
# ---------------------------------------------------------------------------
const SHELLY4PM: Array = [
	{
		"type": "shelly4pm", "label": "Shelly Pro 4PM", "icon": "📊",
		"width": 164.0, "height": 130.0,
		"specs": {
			"name": "Shelly Pro 4PM",
			"passthrough": true,
			"channel_count": 4,
			"max_amps_per_circuit": 16.0,
			# Start ON in SIM so wired loads energize until the player toggles.
			"c0_name": "Circuit 0", "c0_power_w": 0.0, "c0_on": true,
			"c1_name": "Circuit 1", "c1_power_w": 0.0, "c1_on": true,
			"c2_name": "Circuit 2", "c2_power_w": 0.0, "c2_on": true,
			"c3_name": "Circuit 3", "c3_power_w": 0.0, "c3_on": true,
			# Pre-linked HA entities — subscribed automatically on load.
			"ha_links": {
				"c0_power":  "sensor.shellypro4pm_ece334ed2e80_output_0_power",
				"c0_switch": "switch.shellypro4pm_ece334ed2e80_output_0",
				"c0_energy": "sensor.shellypro4pm_ece334ed2e80_output_0_energy",
				"c1_power":  "sensor.shellypro4pm_ece334ed2e80_output_1_power",
				"c1_switch": "switch.shellypro4pm_ece334ed2e80_output_1",
				"c1_energy": "sensor.shellypro4pm_ece334ed2e80_output_1_energy",
				"c2_power":  "sensor.shellypro4pm_ece334ed2e80_output_2_power",
				"c2_switch": "switch.shellypro4pm_ece334ed2e80_output_2",
				"c2_energy": "sensor.shellypro4pm_ece334ed2e80_output_2_energy",
				"c3_power":  "sensor.shellypro4pm_ece334ed2e80_output_3_power",
				"c3_switch": "switch.shellypro4pm_ece334ed2e80_output_3",
				"c3_energy": "sensor.shellypro4pm_ece334ed2e80_output_3_energy",
			},
		},
	},
]

const SPIDERBOX: Array = [
	{
		"type": "spiderbox", "label": "Spiderbox 6-way", "icon": "🕷",
		"width": 180.0, "height": 140.0,
		"specs": {
			"name": "Spiderbox 6-way",
			"passthrough": true,
			"channel_count": 6,
			"max_amps_per_circuit": 20.0,
			"c0_name": "Outlet A", "c0_power_w": 0.0, "c0_on": true,
			"c1_name": "Outlet B", "c1_power_w": 0.0, "c1_on": true,
			"c2_name": "Outlet C", "c2_power_w": 0.0, "c2_on": true,
			"c3_name": "Outlet D", "c3_power_w": 0.0, "c3_on": true,
			"c4_name": "Outlet E", "c4_power_w": 0.0, "c4_on": true,
			"c5_name": "Outlet F", "c5_power_w": 0.0, "c5_on": true,
			"cost": 180.0,
		},
	},
]

const BREAKER_PANELS: Array = [
	{
		"type": "breaker_panel", "label": "Breaker Panel 4-ckt", "icon": "🔌",
		"width": 170.0, "height": 150.0,
		"specs": {
			"name": "Breaker Panel",
			"passthrough": true,
			"channel_count": 4,
			"main_on": true,
			"main_amps": 100.0,
			"max_amps_per_circuit": 20.0,
			"c0_name": "Branch 1", "c0_power_w": 0.0, "c0_on": true,
			"c1_name": "Branch 2", "c1_power_w": 0.0, "c1_on": true,
			"c2_name": "Branch 3", "c2_power_w": 0.0, "c2_on": true,
			"c3_name": "Branch 4", "c3_power_w": 0.0, "c3_on": true,
			"cost": 320.0,
		},
	},
	{
		"type": "breaker_panel", "label": "Breaker Panel 8-ckt", "icon": "🔌",
		"width": 190.0, "height": 170.0,
		"specs": {
			"name": "Breaker Panel 8",
			"passthrough": true,
			"channel_count": 8,
			"main_on": true,
			"main_amps": 200.0,
			"max_amps_per_circuit": 20.0,
			"c0_name": "Branch 1", "c0_on": true, "c0_power_w": 0.0,
			"c1_name": "Branch 2", "c1_on": true, "c1_power_w": 0.0,
			"c2_name": "Branch 3", "c2_on": true, "c2_power_w": 0.0,
			"c3_name": "Branch 4", "c3_on": true, "c3_power_w": 0.0,
			"c4_name": "Branch 5", "c4_on": true, "c4_power_w": 0.0,
			"c5_name": "Branch 6", "c5_on": true, "c5_power_w": 0.0,
			"c6_name": "Branch 7", "c6_on": true, "c6_power_w": 0.0,
			"c7_name": "Branch 8", "c7_on": true, "c7_power_w": 0.0,
			"cost": 480.0,
		},
	},
]

# ---------------------------------------------------------------------------
# Wind Turbines  (type = "wind")
# Physics: power_kw_from_graph_specs in wind_turbine_source.gd
# (P = ½ρACpv³, Betz cap, log-law shear; see that file for references).
# All parameters below are editable per-item in the inspector.
# ---------------------------------------------------------------------------
const WIND_TURBINES: Array = [
	{
		"type": "wind", "label": "Small HAWT 1kW", "icon": "🌬",
		"width": 124.0, "height": 112.0,
		"specs": {
			"name": "Small HAWT 1kW", "kind": "hawt",
			"rated_w": 1000.0, "rotor_diameter_m": 2.1, "cp_peak": 0.42,
			"cut_in_ms": 3.0, "rated_ms": 11.0, "cut_out_ms": 20.0,
			"hub_height_m": 10.0, "anemometer_height_m": 10.0,
			"surface_roughness_m": 0.03, "site_altitude_m": 0.0,
			"site_mean_wind_ms": 6.0, "generator_efficiency": 0.90,
			"current_output_kw": 0.0, "cost": 1800.0,
		},
	},
	{
		"type": "wind", "label": "VAWT 400W", "icon": "🌪",
		"width": 124.0, "height": 112.0,
		"specs": {
			"name": "VAWT 400W", "kind": "vawt",
			"rated_w": 400.0, "rotor_diameter_m": 1.4, "cp_peak": 0.32,
			"cut_in_ms": 3.5, "rated_ms": 12.0, "cut_out_ms": 25.0,
			"hub_height_m": 6.0, "anemometer_height_m": 10.0,
			"surface_roughness_m": 0.03, "site_altitude_m": 0.0,
			"site_mean_wind_ms": 6.0, "generator_efficiency": 0.90,
			"current_output_kw": 0.0, "cost": 900.0,
		},
	},
	# 3D-linked VAWT: has a `model_id` so the library shows a "Place Model" button
	# that drops the GLB into the world (ghost placement) and binds this node to it.
	# Geometry matches the shipped VAWT.glb (rotor ≈ 2 m dia × 5 m tall on a 6.4 m
	# mast → ~9 m hub). Rotor swept area ≈ D·H drives a ~1.2 kW class output.
	{
		"type": "wind", "label": "VAWT 1.2kW (3D)", "icon": "🌀",
		"width": 124.0, "height": 112.0,
		"specs": {
			"name": "VAWT 1.2kW", "kind": "vawt",
			"rated_w": 1200.0, "rotor_diameter_m": 2.0, "cp_peak": 0.35,
			"cut_in_ms": 3.0, "rated_ms": 12.0, "cut_out_ms": 25.0,
			"hub_height_m": 9.0, "anemometer_height_m": 10.0,
			"surface_roughness_m": 0.03, "site_altitude_m": 0.0,
			"site_mean_wind_ms": 6.0, "generator_efficiency": 0.90,
			"current_output_kw": 0.0, "cost": 1500.0,
			# 3D link: placed via ModelCatalog + WindTurbineSpin animation.
			"model_id": "vawt", "turbine_node": "Component#2",
			"tip_speed_ratio": 2.6, "rotor_radius_m": 1.0,
		},
	},
]

# ---------------------------------------------------------------------------
# Hydro Turbines  (type = "hydro")
# Physics: power_kw_from_graph_specs in hydro_source.gd
# (P = ρgQh_netη with Darcy-Weisbach penstock losses; see references there).
# Flow in L/s and pipe sizes in mm for inspector friendliness.
# ---------------------------------------------------------------------------
const HYDRO_TURBINES: Array = [
	{
		"type": "hydro", "label": "Pelton 500W", "icon": "💧",
		"width": 124.0, "height": 112.0,
		"specs": {
			"name": "Pelton 500W", "kind": "pelton",
			"gross_head_m": 25.0, "design_flow_lps": 3.0,
			"penstock_length_m": 60.0, "penstock_diameter_mm": 63.0,
			"pipe_roughness_mm": 0.0015,
			"turbine_efficiency": 0.0, "generator_efficiency": 0.85,
			"current_output_kw": 0.0, "cost": 1200.0,
		},
	},
	{
		"type": "hydro", "label": "Turgo 1kW", "icon": "💧",
		"width": 124.0, "height": 112.0,
		"specs": {
			"name": "Turgo 1kW", "kind": "turgo",
			"gross_head_m": 15.0, "design_flow_lps": 10.0,
			"penstock_length_m": 40.0, "penstock_diameter_mm": 90.0,
			"pipe_roughness_mm": 0.0015,
			"turbine_efficiency": 0.0, "generator_efficiency": 0.85,
			"current_output_kw": 0.0, "cost": 2200.0,
		},
	},
	{
		"type": "hydro", "label": "Run-of-River 300W", "icon": "🌊",
		"width": 124.0, "height": 112.0,
		"specs": {
			"name": "Run-of-River 300W", "kind": "run_of_river",
			"gross_head_m": 3.0, "design_flow_lps": 20.0,
			"penstock_length_m": 10.0, "penstock_diameter_mm": 160.0,
			"pipe_roughness_mm": 0.0015,
			"turbine_efficiency": 0.0, "generator_efficiency": 0.85,
			"current_output_kw": 0.0, "cost": 800.0,
		},
	},
]

# ---------------------------------------------------------------------------
# Solar Concentrators (type = "processor", specs.role = "csp_concentrator")
# Physics: power_system/sources/csp_trough_source.gd (single-axis N-S
# horizontal tracking, Duffie & Beckman end losses, water→steam boil-off).
# `model_id` gives the library a "Place Model" button (see library_panel.gd)
# that drops the linked GLB and binds this node to it — same VAWT pattern.
# ---------------------------------------------------------------------------
const CSP_CONCENTRATORS: Array = [
	{
		"type": "processor", "label": "Parabolic Trough CSP", "icon": "🛰",
		"width": 150.0, "height": 130.0,
		"specs": {
			"name": "Parabolic Trough CSP", "role": "csp_concentrator",
			"kind": "csp_trough", "cost": 4500.0,
			"energy_source": "", "efficiency": 1.0, "energy_wh_per_unit": 0.0,
			"aperture_width_m": 5.0, "module_length_m": 12.0,
			"focal_length_m": 1.7, "optical_efficiency": 0.75,
			"thermal_efficiency": 0.85, "feedwater_temp_c": 20.0,
			"max_tracking_angle_deg": 110.0,
			"tracking_angle_deg": 0.0, "dni_wm2": 0.0, "cos_incidence": 0.0,
			"end_loss_frac": 0.0, "thermal_output_kw": 0.0, "steam_kg_h": 0.0,
			"daily_note": "Water in -> steam out; thermal output scales with live DNI x tracking cosine x aperture area, minus end losses.",
			"inputs": [{"kind": "water", "rate": 0.0, "unit": "L/h"}],
			"outputs": [{"kind": "steam", "rate": 0.0, "unit": "kg/h"}],
			# 3D link: placed via ModelCatalog + CspTroughTracker (auto south
			# alignment + live sun tracking; see gameplay/csp_trough_tracker.gd).
			"model_id": "csp_trough",
			"csp_base_node": "Component#452", "csp_concentrator_node": "Component#453",
		},
	},
]

# ---------------------------------------------------------------------------
# Category list consumed by LibraryPanel to build the UI
# ---------------------------------------------------------------------------
const CATEGORIES: Array = [
	{ "id": "pbis",        "label": "Planetary Basic Income", "icon": "🌍", "presets": PBIS },
	{ "id": "panels",      "label": "Solar Panels",         "icon": "☀",  "presets": PANELS      },
	{ "id": "wind",        "label": "Wind Turbines",        "icon": "🌬", "presets": WIND_TURBINES },
	{ "id": "hydro",       "label": "Hydro Turbines",       "icon": "💧", "presets": HYDRO_TURBINES },
	{ "id": "batteries",   "label": "Batteries",            "icon": "🔋", "presets": BATTERIES   },
	{ "id": "controllers", "label": "Controllers",          "icon": "🎛", "presets": CONTROLLERS },
	{ "id": "appliances",  "label": "Appliances & Loads",   "icon": "🏠", "presets": APPLIANCES  },
	{ "id": "habitats",    "label": "Population",             "icon": "🏠", "presets": HABITATS    },
	{ "id": "processors",  "label": "Processors",           "icon": "🌀", "presets": PROCESSORS  },
	{ "id": "csp",         "label": "Solar Concentrators",  "icon": "🛰", "presets": CSP_CONCENTRATORS },
	{ "id": "resources",   "label": "Resource Containers",  "icon": "🪣", "presets": RESOURCES   },
	{ "id": "catchments",  "label": "Rain Catchment",       "icon": "🌧", "presets": CATCHMENTS  },
	{ "id": "plants",      "label": "Grow Beds",            "icon": "🌱", "presets": PLANTS      },
	{ "id": "monitors",    "label": "Circuit Monitors",     "icon": "📊", "presets": SHELLY4PM   },
	{ "id": "spiderbox",   "label": "Spiderbox",            "icon": "🕷", "presets": SPIDERBOX },
	{ "id": "breakers",    "label": "Breaker Panels",       "icon": "🔌", "presets": BREAKER_PANELS },
]


## User-authored/edited presets, keyed by category id. Kept OUT of CATEGORIES
## (whose "presets" arrays are `const` literals — Godot marks those read-only
## at runtime, so mutating them in place throws "Array is in read-only state").
## presets_for_category() merges this on top of the built-ins for display.
static var _user_overrides: Dictionary = {}


static func load_user_presets() -> void:
	_user_overrides.clear()
	if not FileAccess.file_exists("user://user_presets.json"):
		return
	var file := FileAccess.open("user://user_presets.json", FileAccess.READ)
	if file == null:
		return
	var text := file.get_as_text()
	file.close()
	var json = JSON.new()
	if json.parse(text) != OK:
		return
	var data = json.get_data()
	if not (data is Dictionary):
		return

	for cat_id: String in data.keys():
		if data[cat_id] is Array:
			_user_overrides[cat_id] = (data[cat_id] as Array).duplicate(true)


## Built-in presets for a category with any user overrides/additions merged
## on top (matched by label). Always returns a fresh, mutable Array.
static func presets_for_category(cat_id: String) -> Array:
	var out: Array = []
	for cat in CATEGORIES:
		if cat.get("id", "") == cat_id:
			out = (cat.get("presets", []) as Array).duplicate(true)
			break
	var overrides: Array = _user_overrides.get(cat_id, []) as Array
	for up: Variant in overrides:
		if not (up is Dictionary):
			continue
		var up_dict := up as Dictionary
		var label: String = up_dict.get("label", "")
		var found_idx := -1
		for pi in out.size():
			if (out[pi] as Dictionary).get("label", "") == label:
				found_idx = pi
				break
		if found_idx >= 0:
			out[found_idx] = up_dict
		else:
			out.append(up_dict)
	return out


static func save_user_preset(cat_id: String, preset: Dictionary) -> void:
	var data := {}
	if FileAccess.file_exists("user://user_presets.json"):
		var file := FileAccess.open("user://user_presets.json", FileAccess.READ)
		if file != null:
			var text := file.get_as_text()
			file.close()
			var json = JSON.new()
			if json.parse(text) == OK:
				var parsed = json.get_data()
				if parsed is Dictionary:
					data = parsed
	
	if not data.has(cat_id):
		data[cat_id] = []
	var list: Array = data[cat_id] as Array
	
	var label: String = preset.get("label", "")
	var found_idx := -1
	for i in list.size():
		var p = list[i]
		if p is Dictionary and p.get("label", "") == label:
			found_idx = i
			break
	if found_idx >= 0:
		list[found_idx] = preset
	else:
		list.append(preset)
	
	var file_w := FileAccess.open("user://user_presets.json", FileAccess.WRITE)
	if file_w != null:
		file_w.store_string(JSON.stringify(data, "\t"))
		file_w.close()

	if not _user_overrides.has(cat_id):
		_user_overrides[cat_id] = []
	var mem_list: Array = _user_overrides[cat_id] as Array
	var mem_idx := -1
	for pi in mem_list.size():
		if (mem_list[pi] as Dictionary).get("label", "") == label:
			mem_idx = pi
			break
	if mem_idx >= 0:
		mem_list[mem_idx] = preset
	else:
		mem_list.append(preset)


static func create_default_preset(itype: String, name_val: String) -> Dictionary:
	var preset := {
		"type": itype,
		"label": name_val,
		"icon": _preset_icon_for_type(itype),
		"width": 120.0,
		"height": 100.0,
		"specs": {
			"name": name_val,
			"cost": 100.0
		}
	}
	
	match itype:
		"panel":
			preset.specs.merge({
				"wmp": 250.0, "voc": 37.5, "vmp": 30.5, "isc": 8.80, "imp": 8.20
			})
		"wind":
			preset.specs.merge({
				"kind": "hawt", "rated_w": 1000.0, "rotor_diameter_m": 2.1,
				"cp_peak": 0.42, "generator_efficiency": 0.90,
				"cut_in_ms": 3.0, "rated_ms": 11.0, "cut_out_ms": 20.0,
				"hub_height_m": 10.0, "site_mean_wind_ms": 6.0,
				"surface_roughness_m": 0.03, "site_altitude_m": 0.0
			})
		"hydro":
			preset.specs.merge({
				"kind": "pelton", "turbine_efficiency": 0.0, "generator_efficiency": 0.85,
				"gross_head_m": 25.0, "design_flow_lps": 3.0,
				"penstock_length_m": 60.0, "penstock_diameter_mm": 63.0,
				"pipe_roughness_mm": 0.0015
			})
		"battery", "smartbattery":
			preset.specs.merge({
				"voltage": 12.0, "ah": 100.0, "kwh": 1.2, "soc": 0.8,
				"soc_shutdown_pct": 10.0, "soc_resume_pct": 20.0, "alert_threshold_pct": 95.0
			})
		"controller":
			preset.specs.merge({
				"max_charge_amps": 30.0, "max_load_amps": 30.0, "system_voltage": 12.0
			})
		"appliance", "acload":
			preset.specs.merge({
				"avg_watts": 100.0, "max_watts": 120.0, "pf": 0.95
			})
		"population", "habitat":
			preset.type = "habitat"
			preset.specs.merge({
				"population": 1.0,
				"inputs": [{"kind": "water", "rate": 5.0, "unit": "L/d/p"}, {"kind": "oxygen", "rate": 840.0, "unit": "g/d/p"}],
				"outputs": [{"kind": "co2", "rate": 1000.0, "unit": "g/d/p"}, {"kind": "urine", "rate": 1.5, "unit": "L/d/p"}]
			})
		"processor":
			preset.specs.merge({
				"watts": 500.0, "efficiency": 0.90, "energy_source": "ac",
				"inputs": [{"kind": "water", "rate": 10.0, "unit": "L/h"}],
				"outputs": [{"kind": "urine", "rate": 5.0, "unit": "L/h"}]
			})
		"resource":
			preset.specs.merge({
				"resource_kind": "water", "capacity_qty": 100.0, "capacity_unit": "L", "level": 0.5, "alert_threshold_pct": 95.0
			})
		"catchment":
			preset.specs.merge({
				"catchment_kind": "rain", "use_soi_area": false, "area_m2": 10.0, "runoff_coeff": 0.85
			})
		"plant":
			preset.specs.merge({
				"area_m2": 10.0, "use_soi_area": false,
				"lue_g_per_mj": 2.0, "water_l_per_kg": 50.0, "nutrient_kg_per_kg": 0.02,
				"sunlight_factor": 1.0,
			})
		"shelly4pm":
			preset.specs.merge({
				"passthrough": true, "channel_count": 4,
				"max_amps_per_circuit": 16.0,
				"c0_name": "Circuit 0", "c0_on": true,
				"c1_name": "Circuit 1", "c1_on": true,
				"c2_name": "Circuit 2", "c2_on": true,
				"c3_name": "Circuit 3", "c3_on": true,
			})
		"spiderbox":
			preset.specs.merge({
				"passthrough": true, "channel_count": 6,
				"max_amps_per_circuit": 20.0,
				"c0_name": "Outlet A", "c0_on": true,
				"c1_name": "Outlet B", "c1_on": true,
				"c2_name": "Outlet C", "c2_on": true,
				"c3_name": "Outlet D", "c3_on": true,
				"c4_name": "Outlet E", "c4_on": true,
				"c5_name": "Outlet F", "c5_on": true,
			})
		"breaker_panel":
			preset.specs.merge({
				"passthrough": true, "channel_count": 4, "main_on": true,
				"main_amps": 100.0, "max_amps_per_circuit": 20.0,
				"c0_name": "Branch 1", "c0_on": true,
				"c1_name": "Branch 2", "c1_on": true,
				"c2_name": "Branch 3", "c2_on": true,
				"c3_name": "Branch 4", "c3_on": true,
			})
			
	return preset


static func _preset_icon_for_type(itype: String) -> String:
	match itype:
		"panel": return "☀"
		"wind": return "🌬"
		"hydro": return "💧"
		"battery", "smartbattery": return "🔋"
		"controller": return "🎛"
		"appliance", "acload": return "🏠"
		"population", "habitat": return "🏠"
		"processor": return "🌀"
		"resource": return "🪣"
		"catchment": return "🌧"
		"plant": return "🌱"
		"shelly4pm": return "📊"
		"spiderbox": return "🕷"
		"breaker_panel": return "🔌"
		_: return "📦"


static func _category_id_for_type_static(itype: String) -> String:
	match itype:
		"panel": return "panels"
		"wind": return "wind"
		"hydro": return "hydro"
		"battery", "smartbattery": return "batteries"
		"controller": return "controllers"
		"appliance", "acload": return "appliances"
		"population", "habitat": return "habitats"
		"processor": return "processors"
		"resource": return "resources"
		"catchment": return "catchments"
		"plant": return "plants"
		"shelly4pm": return "monitors"
		"spiderbox": return "spiderbox"
		"breaker_panel": return "breakers"
		_: return ""
