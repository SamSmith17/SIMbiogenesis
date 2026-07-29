class_name GraphNodeState
extends RefCounted

## Unified node-state vocabulary for the systems graph.
##
## One authoritative per-item state (stored on `specs["node_state"]`, with a
## `specs["node_state_reason"]` and optional `specs["node_state_kinds"]`) drives
## both the sim's blocked/idle logic and the canvas's bold visual feedback. This
## replaces the old scattered special cases (`is_starved` habitats-only,
## `batch_error` batch-only, `destroyed` controllers-only), so every simulated
## node reports its state through one channel.
##
## Colors mirror closure_metrics.gd / UITheme (one red, one green, one amber).

# --- States (lowercase strings persisted on specs["node_state"]) ---
const RUNNING := "running"    # switched on + powered + fed → actively running
const IDLE := "idle"          # switched off and not provisioned (nothing to do)
const READY := "ready"        # powered + fed but switched off ("plugged in, ready")
const BLOCKED := "blocked"    # switched on but can't run (missing input/power/output)
const STARVED := "starved"    # habitat missing one or more input channels
const OVERFLOW := "overflow"  # tank full and losing inflow
const FAULT := "fault"        # hardware fault (over-voltage, destroyed, …)

# --- Reason codes (persisted on specs["node_state_reason"]) ---
const REASON_NONE := ""
const REASON_NO_POWER := "no_power"
const REASON_EMPTY_INPUT := "empty_input"
const REASON_OUTPUT_FULL := "output_full"
const REASON_OUTPUT_UNWIRED := "output_unwired"
const REASON_TANK_FULL := "tank_full"
const REASON_OVERVOLTAGE := "overvoltage"
const REASON_SHORT_CIRCUIT := "short_circuit"
const REASON_BATTERY_OVERVOLTAGE := "battery_overvoltage"

const C_RUNNING := Color(0.27, 0.90, 0.42)
const C_ALERT := Color(0.92, 0.30, 0.28)
const C_OVERFLOW := Color(0.95, 0.72, 0.20)
const C_IDLE := Color(0.55, 0.58, 0.65)
const C_READY := Color(0.45, 0.72, 0.95)  # calm blue — "plugged in, ready", no alarm


## Non-nominal states that warrant a bold red/amber overlay + pulse.
static func is_alert(state: String) -> bool:
	return state == BLOCKED or state == STARVED or state == OVERFLOW or state == FAULT


## READY is nominal — no highlight halo (contrast with RUNNING's green ring).
static func is_ready(state: String) -> bool:
	return state == READY


## Blocked/starved/fault (the "can't run" family) — used for the red pulse+jitter.
static func is_blocked_family(state: String) -> bool:
	return state == BLOCKED or state == STARVED or state == FAULT


static func state_color(state: String) -> Color:
	match state:
		RUNNING:
			return C_RUNNING
		READY:
			return C_READY
		OVERFLOW:
			return C_OVERFLOW
		BLOCKED, STARVED, FAULT:
			return C_ALERT
		_:
			return C_IDLE


static func state_label(state: String) -> String:
	match state:
		RUNNING: return "RUNNING"
		READY: return "READY"
		IDLE: return "IDLE"
		BLOCKED: return "BLOCKED"
		STARVED: return "STARVED"
		OVERFLOW: return "OVERFLOW"
		FAULT: return "FAULT"
	return "—"


## A short emoji glyph for the state chip.
static func state_icon(state: String) -> String:
	match state:
		RUNNING: return "▶"
		READY: return "⚡"
		OVERFLOW: return "⚠"
		BLOCKED, STARVED: return "⛔"
		FAULT: return "💥"
	return ""


## Short, player-facing chip text for (state, reason, kinds). `kinds` is an
## Array of resource-kind ids used to name the missing/blocking resource.
static func chip_text(state: String, reason: String = "", kinds: Array = []) -> String:
	var kind_name := ""
	if not kinds.is_empty():
		kind_name = ResourceKinds.display_name(str(kinds[0]))
	match state:
		READY:
			return "Ready"
		FAULT:
			if reason == REASON_OVERVOLTAGE:
				return "Over-voltage"
			if reason == REASON_SHORT_CIRCUIT:
				return "Short circuit!"
			if reason == REASON_BATTERY_OVERVOLTAGE:
				return "Overcharged"
			return "Fault"
		OVERFLOW:
			return "Overflow"
		STARVED:
			if kind_name.is_empty():
				return "Starved"
			return "No %s" % kind_name
		BLOCKED:
			match reason:
				REASON_NO_POWER:
					return "No power"
				REASON_EMPTY_INPUT:
					return "No %s" % kind_name if not kind_name.is_empty() else "No input"
				REASON_OUTPUT_FULL:
					return "%s full" % kind_name if not kind_name.is_empty() else "Output full"
				REASON_OUTPUT_UNWIRED:
					return "Unwired"
				_:
					return "Blocked"
	return ""
