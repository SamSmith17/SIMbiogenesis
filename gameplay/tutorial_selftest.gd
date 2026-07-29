extends SceneTree

## Offline self-test for the Solar Bootcamp tutorial framework.
## Part 1 (Phase B): ProgressStore — grandfathering, unlock grants, level
## completion, disk round-trip. Extended by later phases with the level
## catalog + goal predicates.

const SCRATCH_PATH := "user://selftest_progress.json"


func _initialize() -> void:
	var fails := 0
	fails += _test_grandfathering()
	fails += _test_prompt_and_gating()
	fails += _test_grants()
	fails += _test_levels()
	fails += _test_disk_round_trip()
	fails += _test_unlock_all()
	_cleanup()
	if fails == 0:
		print("TUTORIAL SELFTEST PASS  (6 checks)")
		quit(0)
	else:
		print("TUTORIAL SELFTEST FAIL  (%d failed)" % fails)
		quit(1)


func _fresh() -> void:
	ProgressStore.path_override = SCRATCH_PATH
	ProgressStore.reset_cache()
	if FileAccess.file_exists(SCRATCH_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRATCH_PATH))


func _cleanup() -> void:
	if FileAccess.file_exists(SCRATCH_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRATCH_PATH))
	ProgressStore.path_override = ""
	ProgressStore.reset_cache()


## No progress file → existing installs keep their full library.
func _test_grandfathering() -> int:
	_fresh()
	if not ProgressStore.is_new_player():
		push_error("no file should read as new player")
		return 1
	if not ProgressStore.is_unlocked("category", "processors") \
			or not ProgressStore.is_unlocked("preset", "EG4 6000XP"):
		push_error("no file must leave everything unlocked (grandfathering)")
		return 1
	return 0


## Answering the prompt creates the file; gating then applies with baselines.
func _test_prompt_and_gating() -> int:
	_fresh()
	ProgressStore.mark_prompt_seen()
	if ProgressStore.is_new_player():
		push_error("prompt seen should clear new-player state")
		return 1
	if ProgressStore.is_unlocked("category", "controllers"):
		push_error("un-granted category should be locked once the file exists")
		return 1
	if not ProgressStore.is_unlocked("category", "batteries"):
		push_error("baseline 'batteries' category must always be unlocked")
		return 1
	if ProgressStore.is_unlocked("preset", "Victron 100/20"):
		push_error("un-granted preset should be locked once the file exists")
		return 1
	return 0


func _test_grants() -> int:
	_fresh()
	ProgressStore.mark_prompt_seen()
	ProgressStore.grant(["cat:controllers", "preset:Victron 100/20"])
	ProgressStore.grant(["cat:controllers"])  # duplicate — must not double
	if not ProgressStore.is_unlocked("category", "controllers"):
		push_error("granted category should unlock")
		return 1
	if not ProgressStore.is_unlocked("preset", "Victron 100/20"):
		push_error("granted preset should unlock")
		return 1
	if ProgressStore.is_unlocked("category", "processors"):
		push_error("ungranted category leaked open after grants")
		return 1
	return 0


func _test_levels() -> int:
	_fresh()
	ProgressStore.mark_prompt_seen()
	var order := ["bootcamp_01", "bootcamp_02", "bootcamp_03"]
	if ProgressStore.first_incomplete_level(order) != "bootcamp_01":
		push_error("first incomplete should be level 1")
		return 1
	ProgressStore.mark_level_complete("bootcamp_01", {"attempts": 2})
	if not ProgressStore.is_level_complete("bootcamp_01"):
		push_error("level completion did not stick")
		return 1
	if ProgressStore.first_incomplete_level(order) != "bootcamp_02":
		push_error("first incomplete should advance to level 2")
		return 1
	if int(ProgressStore.level_stats("bootcamp_01").get("attempts", 0)) != 2:
		push_error("level stats did not round-trip")
		return 1
	for lid in order:
		ProgressStore.mark_level_complete(lid)
	if ProgressStore.first_incomplete_level(order) != "":
		push_error("all-complete should return empty id")
		return 1
	return 0


## Values must survive a cache drop (fresh session reading the same file).
func _test_disk_round_trip() -> int:
	_fresh()
	ProgressStore.mark_prompt_seen()
	ProgressStore.grant(["cat:controllers"])
	ProgressStore.mark_level_complete("bootcamp_01")
	ProgressStore.reset_cache()
	if ProgressStore.is_new_player():
		push_error("prompt state lost across reload")
		return 1
	if not ProgressStore.is_unlocked("category", "controllers"):
		push_error("grant lost across reload")
		return 1
	if not ProgressStore.is_level_complete("bootcamp_01"):
		push_error("level completion lost across reload")
		return 1
	return 0


func _test_unlock_all() -> int:
	_fresh()
	ProgressStore.unlock_all()
	if ProgressStore.is_new_player():
		push_error("unlock_all should count as answering the prompt")
		return 1
	if not ProgressStore.is_unlocked("category", "processors") \
			or not ProgressStore.is_unlocked("preset", "EG4 6000XP"):
		push_error("unlock_all should open everything")
		return 1
	return 0
