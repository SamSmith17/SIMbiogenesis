class_name GameplayRulesImpl
extends Node

## Autoload: runtime rules for survival/crisis toggles.
## `survival_paused` mirrors `main.gd.gameplay_mechanics_paused` for legacy UI and saves.
##
## Registered as autoload **GameplayRules** in `project.godot`. Other scripts must obtain the
## instance via `from_node` / `from_tree` — the autoload name is not always visible to the parser.

static func from_tree(tree: SceneTree) -> GameplayRulesImpl:
	if tree == null:
		return null
	return tree.root.get_node_or_null("GameplayRules") as GameplayRulesImpl


static func from_node(node: Node) -> GameplayRulesImpl:
	if node == null or not node.is_inside_tree():
		return null
	return from_tree(node.get_tree())


## Survival mode is OFF (paused) by default. The survival system itself is always
## "enabled" (the autoload exists), but it starts paused — meaning random crises
## (e.g. fires), health drain, hydration loss, etc. do NOT happen until the player
## activates the gameplay toggle in Time UI ("▶ Survival active").
## Manual debug actions (e.g. the F key for fire) always work regardless of this.
var survival_enabled: bool = true
var survival_paused: bool = true

var health_enabled: bool = true
var hydration_enabled: bool = true
var fall_damage_enabled: bool = true
var death_zones_enabled: bool = true
var fire_damage_enabled: bool = true

var crisis_events_enabled: bool = false
var random_crises_enabled: bool = false
var fire_tools_enabled: bool = false

var show_survival_ui: bool = true

## Reserved for future use; not read by systems in Phase 4.
var solar_enabled: bool = true


func is_survival_active() -> bool:
	return survival_enabled and not survival_paused


func is_health_enabled() -> bool:
	return survival_enabled and health_enabled


func is_hydration_enabled() -> bool:
	return survival_enabled and hydration_enabled


func is_fall_damage_enabled() -> bool:
	return survival_enabled and fall_damage_enabled


func is_death_zones_enabled() -> bool:
	return survival_enabled and death_zones_enabled


func is_fire_damage_enabled() -> bool:
	return survival_enabled and fire_damage_enabled


func is_crisis_events_enabled() -> bool:
	return survival_enabled and crisis_events_enabled


func is_random_crises_enabled() -> bool:
	# Random crises require survival mode to be both ENABLED and not paused.
	# Manual triggers (e.g. the F key) bypass this gate via trigger_event_manual().
	return is_survival_active() and crisis_events_enabled and random_crises_enabled


func is_fire_tools_enabled() -> bool:
	return survival_enabled and fire_tools_enabled


func should_show_survival_ui() -> bool:
	return survival_enabled and show_survival_ui


func set_survival_paused(paused: bool) -> void:
	survival_paused = paused


func sync_survival_paused_from_main(main_node: Node) -> void:
	if main_node != null and "gameplay_mechanics_paused" in main_node:
		survival_paused = bool(main_node.gameplay_mechanics_paused)


func sync_main_from_rules(main_node: Node) -> void:
	if main_node != null and "gameplay_mechanics_paused" in main_node:
		main_node.gameplay_mechanics_paused = survival_paused


func apply_scenario(config: ScenarioConfig) -> void:
	if config == null:
		return
	solar_enabled = config.solar_enabled
	survival_enabled = config.survival_enabled
	health_enabled = config.health_enabled
	hydration_enabled = config.hydration_enabled
	fall_damage_enabled = config.fall_damage_enabled
	death_zones_enabled = config.death_zones_enabled
	fire_damage_enabled = config.fire_damage_enabled
	crisis_events_enabled = config.crisis_events_enabled
	random_crises_enabled = config.random_crises_enabled
	fire_tools_enabled = config.fire_tools_enabled
	show_survival_ui = config.show_survival_ui


func apply_fallback_from_main(main_node: Node3D) -> void:
	if main_node == null:
		return
	solar_enabled = true
	# `survival_enabled` is intentionally NOT forced here — it defaults to false
	# so survival mode is OFF at play start. The player turns it on via the
	# gameplay toggle in Time UI, a scenario config, or a save file.
	health_enabled = true
	hydration_enabled = true
	fall_damage_enabled = true
	death_zones_enabled = true
	fire_damage_enabled = true
	show_survival_ui = true
	var erf: bool = false
	var sep: bool = false
	if "enable_random_fires" in main_node:
		erf = bool(main_node.enable_random_fires)
	if "spawn_extinguisher_pickups" in main_node:
		sep = bool(main_node.spawn_extinguisher_pickups)
	crisis_events_enabled = erf or sep
	random_crises_enabled = erf
	fire_tools_enabled = sep


func to_save_dict() -> Dictionary:
	return {
		"survival_enabled": survival_enabled,
		"survival_paused": survival_paused,
		"health_enabled": health_enabled,
		"hydration_enabled": hydration_enabled,
		"fall_damage_enabled": fall_damage_enabled,
		"death_zones_enabled": death_zones_enabled,
		"fire_damage_enabled": fire_damage_enabled,
		"crisis_events_enabled": crisis_events_enabled,
		"random_crises_enabled": random_crises_enabled,
		"fire_tools_enabled": fire_tools_enabled,
		"show_survival_ui": show_survival_ui,
		"solar_enabled": solar_enabled,
	}


func apply_save_state(data: Dictionary) -> void:
	if data.is_empty():
		return
	survival_enabled = bool(data.get("survival_enabled", survival_enabled))
	survival_paused = bool(data.get("survival_paused", survival_paused))
	health_enabled = bool(data.get("health_enabled", health_enabled))
	hydration_enabled = bool(data.get("hydration_enabled", hydration_enabled))
	fall_damage_enabled = bool(data.get("fall_damage_enabled", fall_damage_enabled))
	death_zones_enabled = bool(data.get("death_zones_enabled", death_zones_enabled))
	fire_damage_enabled = bool(data.get("fire_damage_enabled", fire_damage_enabled))
	crisis_events_enabled = bool(data.get("crisis_events_enabled", crisis_events_enabled))
	random_crises_enabled = bool(data.get("random_crises_enabled", random_crises_enabled))
	fire_tools_enabled = bool(data.get("fire_tools_enabled", fire_tools_enabled))
	show_survival_ui = bool(data.get("show_survival_ui", show_survival_ui))
	solar_enabled = bool(data.get("solar_enabled", solar_enabled))
