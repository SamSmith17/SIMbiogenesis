extends Node

## Central manager for crisis events (fire, dust storms, rain, etc.)
## Handles random event triggering, lifecycle management, and coordination
## NOTE: Crisis events (especially fire) are DISABLED when time is sped up beyond 1x realtime
## to save GPU resources. They only run at 1x realtime speed.

signal event_started(event: CrisisEvent)
signal event_updated(event: CrisisEvent)
signal event_resolved(event: CrisisEvent)
signal event_failed(event: CrisisEvent)

## How often to check for new events (in seconds)
@export var check_interval: float = 30.0

## Base probability per check interval (0.0 to 1.0)
## Actual probability is modified by event-specific weights
@export var base_event_probability: float = 0.1

## Minimum time between events (in seconds)
@export var min_time_between_events: float = 60.0

## Maximum number of simultaneous events
@export var max_concurrent_events: int = 1

## List of available event types with their weights
## Higher weight = more likely to trigger
var available_events: Array[Dictionary] = []

## Currently active events
var active_events: Dictionary = {}  # event_id -> CrisisEvent

## Time of last event trigger
var last_event_time: float = 0.0

## Timer for checking events
var check_timer: float = 0.0

## Reference to main scene for context
var main_node: Node = null

## Realtime scale constant (1 second real = 1 second game time)
## Crisis events only run when time_scale equals this value (1x realtime)
const REALTIME_SCALE: float = 1.0 / 3600.0

## Whether crisis events are currently paused due to time speedup
var events_paused: bool = false

## `GameplayRules.is_crisis_events_enabled()` changes rarely — avoid tree walk every frame when crises are off.
const _CRISIS_RULES_POLL_SEC: float = 0.25
var _crisis_rules_poll_left: float = 0.0
var _crisis_system_enabled_cached: bool = false

func _ready() -> void:
	# Register available event types
	_register_event_types()
	
	# Find main node for context
	call_deferred("_find_main_node")

func _process(delta: float) -> void:
	_crisis_rules_poll_left -= delta
	if _crisis_rules_poll_left <= 0.0:
		_crisis_rules_poll_left = _CRISIS_RULES_POLL_SEC
		var gr_poll := GameplayRulesImpl.from_node(self)
		_crisis_system_enabled_cached = gr_poll != null and gr_poll.is_crisis_events_enabled()
	
	# `events_paused` is a *visual* / GPU-savings pause. It triggers ONLY when
	# time is sped up beyond realtime — particles for many fires get expensive,
	# so we hide them and re-show on return to realtime.
	# It is NOT tied to survival mode or `gameplay_mechanics_paused`: a manually
	# triggered fire (F key) must stay visible and burn even when survival is off.
	var current_time_scale := REALTIME_SCALE
	if main_node != null and is_instance_valid(main_node) and "time_scale" in main_node:
		current_time_scale = float(main_node.time_scale)
	var is_realtime := absf(current_time_scale - REALTIME_SCALE) < (REALTIME_SCALE * 0.01)
	var should_pause := not is_realtime
	
	if should_pause and not events_paused:
		events_paused = true
		_pause_all_events()
	elif not should_pause and events_paused:
		events_paused = false
		_resume_all_events()
	
	# Always update active events (independent of survival / random gates), so
	# manually-triggered fires keep spreading and growing.
	_update_active_events(delta)
	
	# Random event roll: gated on survival mode being ACTIVE (enabled + not paused)
	# via `is_random_crises_enabled()`, plus the visual pause above.
	if not _crisis_system_enabled_cached or events_paused:
		return
	
	check_timer += delta
	if check_timer >= check_interval:
		check_timer = 0.0
		_try_trigger_event()

func _register_event_types() -> void:
	# Fire event (will be registered when FireEvent is created)
	# Registration happens in main.gd after scene loads
	pass

func _find_main_node() -> void:
	var tree := get_tree()
	if tree == null:
		return
	
	var root := tree.root
	if root == null:
		return
	
	# Look for main scene node
	for child in root.get_children():
		if "day_time" in child:
			main_node = child
			return
	
	# Fallback: check current scene
	var current_scene := tree.current_scene
	if current_scene and "day_time" in current_scene:
		main_node = current_scene

func _try_trigger_event() -> void:
	var gr := GameplayRulesImpl.from_node(self)
	if gr == null or not gr.is_random_crises_enabled():
		return
	
	if active_events.size() >= max_concurrent_events:
		return
	
	# Don't trigger if too soon since last event
	var current_time := Time.get_ticks_msec() / 1000.0
	if current_time - last_event_time < min_time_between_events:
		return
	
	# Check if any event can trigger
	var context := _build_context()
	
	for event_data in available_events:
		var event_script: GDScript = event_data.get("type")
		var weight: float = event_data.get("weight", 1.0)
		
		if event_script == null:
			continue
		
		# Create event instance to check if it can trigger
		var event = event_script.new()
		if event == null or not event.has_method("can_trigger"):
			continue
		
		if not event.can_trigger(context):
			continue
		
		# Calculate probability (base * weight)
		var probability := base_event_probability * weight
		if randf() < probability:
			_trigger_event(event, context)
			return

func _trigger_event(event, context: Dictionary) -> void:
	var started: bool = event.start_event(context)
	if started:
		active_events[event.event_id] = event
		last_event_time = Time.get_ticks_msec() / 1000.0
		event_started.emit(event)
	else:
		pass

func _update_active_events(delta: float) -> void:
	var context := _build_context()
	var to_remove: Array[String] = []
	
	for event_id in active_events:
		var event = active_events[event_id]
		
		if event == null:
			to_remove.append(event_id)
			continue
		
		# Check if event ended FIRST (before checking is_active)
		# EventState.RESOLVED = 2, EventState.FAILED = 3 (from CrisisEvent enum)
		if event.state == 2:  # RESOLVED
			event_resolved.emit(event)
			to_remove.append(event_id)
			continue
		elif event.state == 3:  # FAILED
			event_failed.emit(event)
			to_remove.append(event_id)
			continue
		
		# Skip inactive events
		if not event.is_active:
			to_remove.append(event_id)
			continue
		
		# Update the event
		event.update_event(delta, context)
		event_updated.emit(event)
	
	# Remove ended events
	for event_id in to_remove:
		active_events.erase(event_id)

func _build_context() -> Dictionary:
	var context := {}
	
	# Add scene tree
	context["scene_tree"] = get_tree()
	
	# Add time data from main node
	if main_node != null and is_instance_valid(main_node):
		if "day_time" in main_node:
			context["day_time"] = float(main_node.day_time)
		if "day" in main_node:
			context["day"] = int(main_node.day)
		if "time_scale" in main_node:
			context["time_scale"] = float(main_node.time_scale)
	
	# Add player reference
	var player := get_tree().get_first_node_in_group("player")
	if player != null:
		context["player"] = player
	
	# Add structure reference (for finding burnables)
	if main_node != null and is_instance_valid(main_node):
		if "structure" in main_node:
			var structure = main_node.get("structure")
			if structure != null and is_instance_valid(structure):
				context["structure"] = structure
		
		# Also try to find Mars Aerial scene if structure not found
		if "structure" not in context or context["structure"] == null:
			var mars_aerial := main_node.get_node_or_null("Mars 2026 - Aerial Located")
			if mars_aerial != null:
				context["structure"] = mars_aerial
			else:
				# Try LinkageLab_Export as fallback
				var linkage_lab := main_node.get_node_or_null("LinkageLab_Export")
				if linkage_lab != null:
					context["structure"] = linkage_lab
	
	return context

## Register a new event type
func register_event_type(event_script: GDScript, weight: float = 1.0, name: String = "") -> void:
	available_events.append({
		"type": event_script,
		"weight": weight,
		"name": name
	})

## Get all active events
func get_active_events() -> Array[CrisisEvent]:
	var result: Array[CrisisEvent] = []
	for event in active_events.values():
		if event != null:
			result.append(event)
	return result

## Manually trigger an event (for testing / debug — e.g. the F key).
## Bypasses survival and pause gates entirely. The event is added to active_events
## and will start updating immediately on the next _process tick.
## Returns true if the event successfully started, false otherwise.
## Optionally accepts a context dictionary to override the default context.
func trigger_event_manual(event, custom_context: Dictionary = {}) -> bool:
	if event == null:
		return false
	
	var context := _build_context()
	for key in custom_context:
		context[key] = custom_context[key]
	
	var before := active_events.size()
	_trigger_event(event, context)
	return active_events.size() > before

## Pause all active events (called when time is sped up)
func _pause_all_events() -> void:
	for event_id in active_events:
		var event = active_events[event_id]
		if event != null and event.has_method("pause_event"):
			event.pause_event()
		elif event != null:
			# Fallback: just hide fire effects by calling stop on any fire nodes
			_pause_fire_effects(event)

## Resume all paused events (called when back to realtime)
func _resume_all_events() -> void:
	for event_id in active_events:
		var event = active_events[event_id]
		if event != null and event.has_method("resume_event"):
			event.resume_event()
		elif event != null:
			# Fallback: resume fire effects
			_resume_fire_effects(event)

## Pause fire visual effects to save GPU
func _pause_fire_effects(event) -> void:
	if event == null:
		return
	# Check if event has fire_nodes (fire events have this)
	if "fire_nodes" in event:
		for fire_node in event.fire_nodes:
			if fire_node != null and is_instance_valid(fire_node):
				fire_node.visible = false
				# Stop particle emission
				if fire_node.has_method("set_emitting"):
					fire_node.set_emitting(false)

## Resume fire visual effects
func _resume_fire_effects(event) -> void:
	if event == null:
		return
	# Check if event has fire_nodes (fire events have this)
	if "fire_nodes" in event:
		for fire_node in event.fire_nodes:
			if fire_node != null and is_instance_valid(fire_node):
				fire_node.visible = true
				# Resume particle emission
				if fire_node.has_method("set_emitting"):
					fire_node.set_emitting(true)

## Check if crisis events are currently active (not paused)
func is_crisis_system_active() -> bool:
	return not events_paused

