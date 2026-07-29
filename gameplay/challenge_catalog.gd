class_name ChallengeCatalog
extends RefCounted

## Built-in challenge definitions for the playable puzzle loop.


static func all_challenges() -> Array:
	return [
		keep_the_lights_on(),
		keep_the_lights_on_prebake("day"),
		keep_the_lights_on_prebake("month"),
		dry_week(),
		close_the_loop(),
		close_the_loop_prebake(),
	]


static func by_id(challenge_id: String) -> ChallengeDef:
	for d: ChallengeDef in all_challenges():
		if d.id == challenge_id:
			return d
	return null


static func keep_the_lights_on() -> ChallengeDef:
	return ChallengeDef.from_dict({
		"id": "keep_lights_on",
		"title": "Keep the Lights On",
		"description": "Survive 72 hours on local solar + battery. Fail if AC is unavailable for more than 30 minutes while the habitat needs power.",
		"duration_hours": 72.0,
		"occupants": 1,
		"use_current_date": true,
		"fail_on_starvation": false,
		"require_no_starvation": false,
		"track_ac_availability": true,
		"max_ac_down_hours": 0.5,
		"fail_on_kinds": [],
	})


## Pre-baked variant: the whole span is computed in seconds, played back, and
## on failure the SAME segment replays after the player fixes the system.
static func keep_the_lights_on_prebake(span: String) -> ChallengeDef:
	var span_label: String = str({"day": "1 Day", "month": "1 Month", "year": "1 Year"}.get(span, span))
	return ChallengeDef.from_dict({
		"id": "keep_lights_on_%s" % span,
		"title": "Keep the Lights On — %s ⚡instant" % span_label,
		"description": ("Design a system that powers the habitat for %s with no " +
			"total power failure. The run is pre-computed instantly and played " +
			"back — when it fails, the timeline parks at the breakpoint; fix " +
			"your system and replay the same %s until it survives.") % [span_label.to_lower(), span_label.to_lower()],
		"run_mode": "prebake",
		"span": span,
		"occupants": 1,
		"use_current_date": true,
		"fail_on_power_failure": true,
		"fail_on_starvation": false,
		"require_no_starvation": false,
		"fail_on_collapse": true,
		"fail_on_kinds": [],
	})


static func close_the_loop_prebake() -> ChallengeDef:
	return ChallengeDef.from_dict({
		"id": "close_the_loop_month",
		"title": "Close the Loop — 1 Month ⚡instant",
		"description": ("A month of habitat water/waste flows, pre-computed and " +
			"played back. No power failures, no water stockouts, colony holds. " +
			"Failures park the timeline at the breakpoint for a same-month replay."),
		"run_mode": "prebake",
		"span": "month",
		"occupants": 1,
		"use_current_date": true,
		"fail_on_power_failure": true,
		"fail_on_starvation": true,
		"require_no_starvation": true,
		"fail_on_collapse": true,
		"fail_on_kinds": ["water"],
	})


static func dry_week() -> ChallengeDef:
	return ChallengeDef.from_dict({
		"id": "dry_week",
		"title": "Dry Week",
		"description": "Jump to the driest 7-day stretch in the local weather archive. Keep potable water from running out for 168 hours. Rain catchments will not save you — size tanks and imports carefully.",
		"duration_hours": 168.0,
		"occupants": 1,
		"use_current_date": false,
		"use_driest_week": true,
		"fail_on_starvation": true,
		"require_no_starvation": true,
		"track_ac_availability": false,
		"fail_on_kinds": ["water"],
	})


static func close_the_loop() -> ChallengeDef:
	return ChallengeDef.from_dict({
		"id": "close_the_loop",
		"title": "Close the Loop",
		"description": "Run 48 hours with a habitat and greywater recycle path. Win if water closure reaches at least 60% and potable water never stocks out.",
		"duration_hours": 48.0,
		"occupants": 1,
		"use_current_date": true,
		"fail_on_starvation": true,
		"require_no_starvation": true,
		"track_ac_availability": false,
		"min_water_closure_pct": 0.60,
		"fail_on_kinds": ["water"],
	})
