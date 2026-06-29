class_name CrisisEvent
extends RefCounted

## Base class for all crisis events (fire, dust storm, rain, etc.)
## Each event type inherits from this and implements the required methods

enum EventState {
	PENDING,    # Event is queued but not started
	ACTIVE,     # Event is currently happening
	RESOLVED,   # Event was successfully handled by player
	FAILED      # Event reached failure condition (e.g., structure burned down)
}

enum EventSeverity {
	LOW,        # Minor event, slow spread/damage
	MEDIUM,     # Moderate event
	HIGH        # Severe event, fast spread/damage
}

## Unique identifier for this event instance
var event_id: String = ""

## Human-readable name
var event_name: String = "Crisis Event"

## Current state of the event
var state: EventState = EventState.PENDING

## Severity level (affects spread rate, damage, etc.)
var severity: EventSeverity = EventSeverity.MEDIUM

## Time when event started
var start_time: float = 0.0

## Whether this event is currently active
var is_active: bool = false

## Check if this event can trigger right now
## Override in subclasses to add conditions (e.g., "only during day", "only if structures exist")
func can_trigger(context: Dictionary) -> bool:
	return state == EventState.PENDING

## Start the event
## Override in subclasses to spawn effects, set up timers, etc.
func start_event(context: Dictionary) -> bool:
	if state != EventState.PENDING:
		return false
	
	state = EventState.ACTIVE
	is_active = true
	start_time = Time.get_ticks_msec() / 1000.0
	return true

## Update the event each frame
## Override in subclasses to handle spread, damage, etc.
func update_event(delta: float, context: Dictionary) -> void:
	if state != EventState.ACTIVE:
		return

## End the event (successfully resolved)
func resolve_event() -> void:
	if state == EventState.ACTIVE:
		state = EventState.RESOLVED
		is_active = false
		cleanup()

## End the event (failure condition reached)
func fail_event() -> void:
	if state == EventState.ACTIVE:
		state = EventState.FAILED
		is_active = false
		cleanup()

## Cleanup resources when event ends
## Override in subclasses to remove particles, lights, etc.
func cleanup() -> void:
	pass

## Get a description of the current event state for UI
func get_status_description() -> String:
	match state:
		EventState.PENDING:
			return "Event pending"
		EventState.ACTIVE:
			return "%s in progress" % event_name
		EventState.RESOLVED:
			return "%s resolved" % event_name
		EventState.FAILED:
			return "%s failed" % event_name
	return "Unknown state"




