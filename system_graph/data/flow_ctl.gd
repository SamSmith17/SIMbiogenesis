class_name FlowCtl
extends RefCounted
## Valves and pumps on the graph (plans/SCADA_PROCESS_PLAN.md, Phase 3, the
## graph tier of the process physics).
##
## A flow control is a `processor` with `role: "flowctl"` standing IN LINE
## between two stores of one kind:  store → [valve | pump] → store.  It turns
## nothing into anything; it decides HOW FAST the line carries:
##
##   rate = max_rate × open        (open 0..1; a plain valve is 0 or 1)
##
## and the flow engine's ordinary machine step does the rest (the upstream
## store must have some, the downstream store must have room, mass exact).
## The run switch (`requested_state`) is the valve's open / closed or the
## pump's on / off, so every rule, tag and faceplate that switches a machine
## switches these.
##
##   valve   no power. Flows DOWNHILL only: when both stores know their
##           height and the target is higher, nothing moves ("needs a pump").
##   check   a valve that is always open and never commanded.
##   pump    needs AC (watts while it moves water) and lifts up to
##           `max_lift_m`; past that nothing moves.
##
## Why a machine and not a wire flag: the engine's machines already draw from
## stores, block on a full target, bill power and carry a run switch. A line
## straight from a store into a MACHINE is shut with the store's own outlet
## valve (`output_valve_open`).
##
## Pure and autoload-free.

const ROLE := "flowctl"
const KIND_VALVE := "valve"
const KIND_CHECK := "check"
const KIND_PUMP := "pump"
const KINDS := [KIND_VALVE, KIND_CHECK, KIND_PUMP]

## Why nothing moves (stamped on the node as `ctl_block`).
const BLOCK_NONE := ""
const BLOCK_UPHILL := "uphill"
const BLOCK_LIFT := "lift"

## Unknown heights within this of level count as level (the engine's own
## gravity tolerance).
const LEVEL_TOL_M := 0.05


static func is_flowctl(specs: Dictionary) -> bool:
	return str(specs.get("role", "")) == ROLE


static func kind_of(specs: Dictionary) -> String:
	var k := str(specs.get("ctl_kind", KIND_VALVE))
	return k if k in KINDS else KIND_VALVE


## 0..1. A valve or pump with no `open` key is fully open; `throttle` false
## (the default for on / off valves) snaps anything above zero to 1.
static func opening(specs: Dictionary) -> float:
	var o := clampf(float(specs.get("open", 1.0)), 0.0, 1.0)
	if not bool(specs.get("throttle", false)):
		return 1.0 if o > 0.0 else 0.0
	return o


static func is_on(specs: Dictionary) -> bool:
	if kind_of(specs) == KIND_CHECK:
		return true
	return str(specs.get("requested_state", specs.get("current_state", "on"))).to_lower() == "on"


## What the line carries at this setting, per hour, in the resource's unit
## (0 when shut / off).
static func rate(specs: Dictionary) -> float:
	if not is_on(specs):
		return 0.0
	return maxf(float(specs.get("max_rate", 0.0)), 0.0) * opening(specs)


## Whether the height difference lets it move. `delta_m` = source height −
## target height (NAN = unknown: allowed). → "" | "uphill" | "lift".
static func block_for(specs: Dictionary, delta_m: float) -> String:
	if is_nan(delta_m) or delta_m >= -LEVEL_TOL_M:
		return BLOCK_NONE
	if kind_of(specs) != KIND_PUMP:
		return BLOCK_UPHILL
	var lift := float(specs.get("max_lift_m", 0.0))
	if lift > 0.0 and -delta_m > lift:
		return BLOCK_LIFT
	return BLOCK_NONE


## The specs the engine steps with: one input and one output of the line's
## kind at `r` per hour; a valve draws no power. Mutates and returns `specs`.
static func apply_rate(specs: Dictionary, r: float) -> Dictionary:
	var kind := ResourceKinds.normalize_kind(str(specs.get("ctl_resource", "water")))
	var unit := ResourceKinds.default_unit(kind)
	specs["inputs"] = [{"kind": kind, "rate": r, "unit": "%s/h" % unit}]
	specs["outputs"] = [{"kind": kind, "rate": r, "unit": "%s/h" % unit}]
	specs["efficiency"] = 1.0
	specs["io_absolute"] = false
	if kind_of(specs) != KIND_PUMP:
		specs["watts"] = 0.0
		specs["energy_source"] = ""
	return specs


## Preset specs for a new valve / pump on a line of `resource`.
static func make_specs(name: String, kind: String, resource: String, max_rate: float, opts: Dictionary = {}) -> Dictionary:
	var s := {
		"name": name, "role": ROLE, "ctl_kind": kind if kind in KINDS else KIND_VALVE,
		"ctl_resource": resource, "max_rate": max_rate, "open": 1.0,
		"throttle": bool(opts.get("throttle", false)),
		"requested_state": str(opts.get("state", "on")),
		"cost": float(opts.get("cost", 0.0)), "unit_ops": [],
		"watts": 0.0, "energy_source": "", "efficiency": 1.0,
	}
	if s["ctl_kind"] == KIND_PUMP:
		s["watts"] = float(opts.get("watts", 100.0))
		s["energy_source"] = "ac"
		s["max_lift_m"] = float(opts.get("max_lift_m", 10.0))
		s["unit_ops"] = ["pumping"]
	return apply_rate(s, max_rate if is_on(s) else 0.0)


## The state in a player's words: "Open" / "Closed" / "60 % open" for valves,
## "Running" / "Off" for a pump, with the reason when it cannot move anything.
static func state_words(specs: Dictionary) -> String:
	var kind := kind_of(specs)
	var blk := str(specs.get("ctl_block", ""))
	if kind == KIND_PUMP:
		if not is_on(specs):
			return "Off"
		if blk == BLOCK_LIFT:
			return "Too high to lift"
		var st := str(specs.get("node_state", ""))
		if st == "running":
			return "Running"
		if st == "blocked":
			return "On, but it cannot run"
		return "On, nothing to move" if not st.is_empty() else "On"
	if not is_on(specs) or opening(specs) <= 0.0:
		return "Closed"
	if blk == BLOCK_UPHILL:
		return "Open, but uphill: needs a pump"
	var o := opening(specs)
	return "Open" if o >= 0.999 else "%d %% open" % int(round(o * 100.0))


## [on word, off word, do-on word, do-off word] for buttons and faceplates.
static func verbs(specs: Dictionary) -> Array:
	if kind_of(specs) == KIND_PUMP:
		return ["On", "Off", "Switch on", "Switch off"]
	return ["Open", "Closed", "Open it", "Close it"]
