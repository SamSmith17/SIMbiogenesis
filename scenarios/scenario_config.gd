class_name ScenarioConfig
extends Resource

## Map/build intent: feature flags and optional data for crisis setup.
## Assign on `main.gd` as an @export; leave unassigned to use `main.gd` exports as fallback.

@export var display_name: String = "Default Scenario"

@export var solar_enabled: bool = true
@export var survival_enabled: bool = true
@export var health_enabled: bool = true
@export var hydration_enabled: bool = true
@export var fall_damage_enabled: bool = true
@export var death_zones_enabled: bool = true
@export var fire_damage_enabled: bool = true
@export var crisis_events_enabled: bool = false
@export var random_crises_enabled: bool = false
@export var fire_tools_enabled: bool = false
@export var show_survival_ui: bool = true

## Node paths from map root (`Main`) for burnable scans, e.g. `"LinkageLab_Export2"`.
@export var burnable_scan_node_paths: PackedStringArray = []

## Pickups: each dict should have `"position"` (Vector3) and optional `"name"` (String).
@export var extinguisher_pickups: Array[Dictionary] = []
