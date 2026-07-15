class_name ChallengeCatalog
extends RefCounted

## Built-in challenge definitions for the playable puzzle loop.


static func all_challenges() -> Array:
	return [
		keep_the_lights_on(),
		dry_week(),
		close_the_loop(),
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
		"description": "Survive 72 hours on local solar + battery. Fail if AC is unavailable for more than 30 minutes while the habitat needs power, or if the habitat starves.",
		"duration_hours": 72.0,
		"occupants": 1,
		"use_current_date": true,
		"fail_on_starvation": true,
		"require_no_starvation": true,
		"track_ac_availability": true,
		"max_ac_down_hours": 0.5,
		"fail_on_kinds": ["water", "food"],
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
