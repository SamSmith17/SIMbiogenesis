class_name ChallengeDef
extends RefCounted

## Declarative challenge definition for the playable puzzle loop.

var id: String = ""
var title: String = ""
var description: String = ""
var duration_hours: float = 72.0
## Start at current playhead (ignore start_month/day).
var use_current_date: bool = true
## Jump to driest 7-day precip window in the cached weather year.
var use_driest_week: bool = false
var start_month: int = 0
var start_day: int = 0
var occupants: int = 1
## Immediate fail if habitat starved_kinds intersects these (or any if fail_on_starvation).
var fail_on_kinds: Array = []
var fail_on_starvation: bool = true
## Also require no starvation at the win check (end of window).
var require_no_starvation: bool = true
## Track SolarUI AC availability; fail if down longer than max_ac_down_hours.
var track_ac_availability: bool = false
var max_ac_down_hours: float = -1.0
## Win thresholds (0 = ignore).
var min_mean_closure_pct: float = 0.0
var min_water_closure_pct: float = 0.0
var min_autonomy_days: float = 0.0
## "realtime" (default — the classic 1 Hz live run) or "prebake" (the
## ChallengeBakeEngine computes the whole span in seconds, plays it back, and
## replays the SAME segment on retry).
var run_mode: String = "realtime"
## Prebake span preset: "" (use duration_hours) | "day" | "month" | "year".
var span: String = ""
## Prebake fail conditions.
var fail_on_power_failure: bool = false
var fail_on_collapse: bool = false
## Win threshold on PV utilization (∫delivered / ∫potential solar), 0 = ignore.
var min_pv_utilization_pct: float = 0.0


func is_prebake() -> bool:
	return run_mode == "prebake"


## duration_hours with the span preset applied.
func resolved_duration_hours() -> float:
	match span:
		"day":
			return 24.0
		"month":
			return 720.0
		"year":
			return 8760.0
	return duration_hours


static func from_dict(d: Dictionary) -> ChallengeDef:
	var c := ChallengeDef.new()
	c.id = str(d.get("id", ""))
	c.title = str(d.get("title", c.id))
	c.description = str(d.get("description", ""))
	c.duration_hours = float(d.get("duration_hours", 72.0))
	c.use_current_date = bool(d.get("use_current_date", true))
	c.use_driest_week = bool(d.get("use_driest_week", false))
	c.start_month = int(d.get("start_month", 0))
	c.start_day = int(d.get("start_day", 0))
	c.occupants = maxi(int(d.get("occupants", 1)), 1)
	c.fail_on_kinds = (d.get("fail_on_kinds", []) as Array).duplicate()
	c.fail_on_starvation = bool(d.get("fail_on_starvation", true))
	c.require_no_starvation = bool(d.get("require_no_starvation", true))
	c.track_ac_availability = bool(d.get("track_ac_availability", false))
	c.max_ac_down_hours = float(d.get("max_ac_down_hours", -1.0))
	c.min_mean_closure_pct = float(d.get("min_mean_closure_pct", 0.0))
	c.min_water_closure_pct = float(d.get("min_water_closure_pct", 0.0))
	c.min_autonomy_days = float(d.get("min_autonomy_days", 0.0))
	c.run_mode = str(d.get("run_mode", "realtime"))
	c.span = str(d.get("span", ""))
	c.fail_on_power_failure = bool(d.get("fail_on_power_failure", false))
	c.fail_on_collapse = bool(d.get("fail_on_collapse", false))
	c.min_pv_utilization_pct = float(d.get("min_pv_utilization_pct", 0.0))
	return c


static func reason_label(reason: String) -> String:
	match reason:
		"starvation":
			return "A habitat need was not met in time."
		"power_failure":
			return "Total power failure — the battery hit its floor with loads unserved."
		"colony_collapsed":
			return "The colony collapsed — too many people gave up and left."
		"pv_utilization_low":
			return "Too much solar potential went unharvested."
		"ac_down":
			return "AC power was unavailable for too long."
		"closure_low":
			return "Overall resource closure was below the win target."
		"water_closure_low":
			return "Water loop closure stayed below 60%."
		"autonomy_low":
			return "On-site resource autonomy was too low."
		"no_main":
			return "Could not start — world not ready."
		_:
			if reason.begins_with("stockout_"):
				return "%s supply ran out." % reason.substr(9).capitalize()
			return reason if not reason.is_empty() else "Mission requirements not met."


func to_dict() -> Dictionary:
	return {
		"id": id,
		"title": title,
		"description": description,
		"duration_hours": duration_hours,
		"use_current_date": use_current_date,
		"use_driest_week": use_driest_week,
		"start_month": start_month,
		"start_day": start_day,
		"occupants": occupants,
		"fail_on_kinds": fail_on_kinds.duplicate(),
		"fail_on_starvation": fail_on_starvation,
		"require_no_starvation": require_no_starvation,
		"track_ac_availability": track_ac_availability,
		"max_ac_down_hours": max_ac_down_hours,
		"min_mean_closure_pct": min_mean_closure_pct,
		"min_water_closure_pct": min_water_closure_pct,
		"min_autonomy_days": min_autonomy_days,
		"run_mode": run_mode,
		"span": span,
		"fail_on_power_failure": fail_on_power_failure,
		"fail_on_collapse": fail_on_collapse,
		"min_pv_utilization_pct": min_pv_utilization_pct,
	}
