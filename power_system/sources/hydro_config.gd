class_name HydroConfig
extends Resource

## Inspector-editable parameters for a small (micro) hydroelectric
## installation.
## Physics references:
##  - Hydro power P = ρ·g·Q·h_net·η and small-hydro turbine efficiency
##    ranges: Paish, "Small hydro power: technology and current status",
##    Renewable & Sustainable Energy Reviews 6 (2002) 537–556.
##  - Pipe friction: Darcy–Weisbach equation with the Swamee–Jain (1976)
##    explicit approximation of the Colebrook friction factor.

enum TurbineType {
	PELTON,        ## Impulse wheel — high head / low flow
	TURGO,         ## Impulse — medium head / medium flow
	RUN_OF_RIVER,  ## Propeller / crossflow — low head / high flow
}

@export var turbine_type: TurbineType = TurbineType.PELTON

## Gross (static) head: vertical drop from intake to turbine, in metres.
@export_range(0.5, 300.0, 0.5) var gross_head_m: float = 25.0

## Design flow through the turbine in m³/s (0.003 = 3 L/s).
@export_range(0.0005, 5.0, 0.0005) var design_flow_m3s: float = 0.003

## Penstock (supply pipe) length in metres.
@export_range(1.0, 2000.0, 1.0) var penstock_length_m: float = 60.0

## Penstock internal diameter in metres (0.063 = 63 mm PE pipe).
@export_range(0.02, 2.0, 0.001) var penstock_diameter_m: float = 0.063

## Absolute pipe roughness ε in metres. Typical values (Moody chart):
## PE/PVC ≈ 1.5e-6, commercial steel ≈ 4.5e-5, concrete ≈ 3e-4.
@export_range(0.0000005, 0.001, 0.0000005) var pipe_roughness_m: float = 0.0000015

## Turbine hydraulic efficiency at design flow. Leave at 0 to use the
## per-type default. Realistic small-unit ranges (Paish 2002): Pelton
## 0.70–0.90, Turgo 0.65–0.85, run-of-river propeller/crossflow 0.50–0.80.
@export_range(0.0, 0.95, 0.01) var turbine_efficiency: float = 0.0

## Generator + drive electrical efficiency applied after the turbine.
@export_range(0.5, 1.0, 0.01) var generator_efficiency: float = 0.85

## Seasonal flow variation: 12 monthly multipliers applied to design_flow
## (January first). Default is a temperate snowmelt-fed stream profile:
## spring peak, late-summer minimum.
@export var monthly_flow_multipliers: Array[float] = [
	0.8, 0.9, 1.2, 1.4, 1.3, 1.1, 0.8, 0.6, 0.6, 0.7, 0.8, 0.8,
]


## Per-type default efficiency used when turbine_efficiency is left at 0.
func effective_turbine_efficiency() -> float:
	if turbine_efficiency > 0.0:
		return turbine_efficiency
	match turbine_type:
		TurbineType.PELTON:
			return 0.85
		TurbineType.TURGO:
			return 0.80
		TurbineType.RUN_OF_RIVER:
			return 0.70
	return 0.70
