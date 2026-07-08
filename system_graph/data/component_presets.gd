class_name ComponentPresets
extends RefCounted
## Static catalogue of component presets ported from the LinkageLab webapp.
## All values are in SI units (W, V, A, kWh).  Costs are in USD.
## Node type strings must match GraphCanvas.HANDLES / NODE_SIZES keys.

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
]

# ---------------------------------------------------------------------------
# Rain catchment sources  (type = "catchment")
# Credits captured rainwater into connected water tanks via ResourceFlowEngine.
# ---------------------------------------------------------------------------
const CATCHMENTS: Array = [
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
# Smart Circuit Monitors  (type = "shelly4pm")
# Shelly Pro 4PM: one AC input, four individually metered 16 A circuit outputs.
# Handles: ac_in (ac, left) | circuit_0–3 (ac, right, evenly spaced)
# ---------------------------------------------------------------------------
const SHELLY4PM: Array = [
	{
		"type": "shelly4pm", "label": "Shelly Pro 4PM", "icon": "📊",
		"width": 164.0, "height": 130.0,
		"specs": {
			"name": "Shelly Pro 4PM",
			"max_amps_per_circuit": 16.0,
			"c0_name": "Circuit 0", "c0_power_w": 0.0, "c0_on": false,
			"c1_name": "Circuit 1", "c1_power_w": 0.0, "c1_on": false,
			"c2_name": "Circuit 2", "c2_power_w": 0.0, "c2_on": false,
			"c3_name": "Circuit 3", "c3_power_w": 0.0, "c3_on": false,
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
# Category list consumed by LibraryPanel to build the UI
# ---------------------------------------------------------------------------
const CATEGORIES: Array = [
	{ "id": "panels",      "label": "Solar Panels",         "icon": "☀",  "presets": PANELS      },
	{ "id": "wind",        "label": "Wind Turbines",        "icon": "🌬", "presets": WIND_TURBINES },
	{ "id": "hydro",       "label": "Hydro Turbines",       "icon": "💧", "presets": HYDRO_TURBINES },
	{ "id": "batteries",   "label": "Batteries",            "icon": "🔋", "presets": BATTERIES   },
	{ "id": "controllers", "label": "Controllers",          "icon": "🎛", "presets": CONTROLLERS },
	{ "id": "appliances",  "label": "Appliances & Loads",   "icon": "🏠", "presets": APPLIANCES  },
	{ "id": "processors",  "label": "Processors",           "icon": "🌀", "presets": PROCESSORS  },
	{ "id": "resources",   "label": "Resource Containers",  "icon": "🪣", "presets": RESOURCES   },
	{ "id": "catchments",  "label": "Rain Catchment",       "icon": "🌧", "presets": CATCHMENTS  },
	{ "id": "monitors",    "label": "Circuit Monitors",     "icon": "📊", "presets": SHELLY4PM   },
]
