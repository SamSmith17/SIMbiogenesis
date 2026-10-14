extends SceneTree

## Offline deterministic selftest for ClockClaims (core/clock_claims.gd) and its
## integration with CelestialClock's base/effective time_scale split.
##
## Run: Godot.exe.exe --headless --path . --script core/clock_claims_selftest.gd

const ClockScript := preload("res://core/celestial_clock.gd")

var _fails := 0
var _checks := 0


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [name, detail])


func _initialize() -> void:
	_test_basic_stack()
	_test_reclaim_does_not_stack()
	_test_release_is_order_independent()
	_test_the_snowglobe_over_csv_bug()
	_test_exclusive()
	_test_value_falls_through()
	_test_owner_of()
	_test_signal()
	_test_clock_integration()
	if _fails == 0:
		print("CLOCK CLAIMS SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("CLOCK CLAIMS SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(1 if _fails > 0 else 0)


func _test_basic_stack() -> void:
	var c := ClockClaims.new()
	_check("empty at start", c.is_empty())
	_check("base shows through", float(c.value_or("time_scale", 0.01)) == 0.01)
	c.claim("a", {"time_scale": 0.0})
	_check("claim wins over base", float(c.value_or("time_scale", 0.01)) == 0.0)
	_check("has_claim true", c.has_claim("a"))
	c.release("a")
	_check("base restored", float(c.value_or("time_scale", 0.01)) == 0.01)
	_check("empty after release", c.is_empty())


func _test_reclaim_does_not_stack() -> void:
	var c := ClockClaims.new()
	c.claim("a", {"time_scale": 1.0})
	c.claim("a", {"time_scale": 2.0})
	c.claim("a", {"time_scale": 3.0})
	_check("re-claim replaces in place", c.owners().size() == 1)
	_check("latest value wins", float(c.value_or("time_scale", 0.01)) == 3.0)
	# One release must fully clear it — otherwise a repeated claim leaks a claim
	# that nothing will ever release.
	c.release("a")
	_check("single release clears a re-claimed owner", c.is_empty())


func _test_release_is_order_independent() -> void:
	# Releasing the BOTTOM claim while a higher one is live must not disturb the
	# higher one. The old save/restore pattern could not express this at all.
	var c := ClockClaims.new()
	c.claim("bottom", {"time_scale": 1.0})
	c.claim("top", {"time_scale": 2.0})
	c.release("bottom")
	_check("top survives bottom's release", float(c.value_or("time_scale", 0.01)) == 2.0)
	c.release("top")
	_check("base after both released", float(c.value_or("time_scale", 0.01)) == 0.01)
	# Releasing an owner that holds nothing is a no-op, so every exit path can
	# call it unconditionally (including twice).
	c.release("never_claimed")
	c.release("top")
	_check("redundant release is harmless", c.is_empty())


## The exact reported failure: CSV playback pauses the clock, the SoI snowglobe
## opens on top, and under the old private-_saved_time_scale pattern the
## snowglobe stored CSV's 0.0 as "the previous value" — so after both exited the
## clock stayed paused with nothing left to unpause it.
func _test_the_snowglobe_over_csv_bug() -> void:
	var c := ClockClaims.new()
	var user_scale := 0.01
	c.claim("csv_playback", {"time_scale": 0.0})
	_check("csv paused the clock", float(c.value_or("time_scale", user_scale)) == 0.0)
	c.claim("soi_snowglobe", {"time_scale": 0.0})
	c.release("soi_snowglobe")
	_check("csv's pause still stands after snowglobe exits",
		float(c.value_or("time_scale", user_scale)) == 0.0)
	c.release("csv_playback")
	_check("clock returns to the USER's scale, not a stale 0.0",
		float(c.value_or("time_scale", user_scale)) == user_scale)


func _test_exclusive() -> void:
	var c := ClockClaims.new()
	_check("no exclusive owner at start", c.exclusive_owner().is_empty())
	_check("exclusive claim granted", c.claim("export", {"time_scale": 0.0}, true))
	_check("exclusive_owner reports it", c.exclusive_owner() == "export")
	_check("competing claim refused", not c.claim("ui", {"time_scale": 5.0}))
	_check("refused claim did not land", not c.has_claim("ui"))
	_check("exclusive value holds", float(c.value_or("time_scale", 0.01)) == 0.0)
	# The holder may still update its own claim while exclusive.
	_check("holder can re-claim", c.claim("export", {"time_scale": 0.5}, true))
	_check("holder's update applied", float(c.value_or("time_scale", 0.01)) == 0.5)
	c.release("export")
	_check("exclusive cleared on release", c.exclusive_owner().is_empty())
	_check("claims work again", c.claim("ui", {"time_scale": 5.0}))


func _test_owner_of() -> void:
	# The timeline's "held by …" pill reads this; it must name the claim whose
	# value value_or() actually returns — falling through partial claims.
	var c := ClockClaims.new()
	_check("owner_of empty stack is ''", c.owner_of("time_scale").is_empty())
	c.claim("csv_history", {"time_scale": 0.0})
	c.claim("analemma_ui", {"analemma_mode": true})
	_check("owner_of falls through a partial claim",
		c.owner_of("time_scale") == "csv_history")
	_check("owner_of reads the top claim for its key",
		c.owner_of("analemma_mode") == "analemma_ui")
	c.claim("video_export", {"time_scale": 0.5}, true)
	_check("owner_of follows the top-most claim", c.owner_of("time_scale") == "video_export")
	c.release("video_export")
	c.release("csv_history")
	_check("owner_of clears on release", c.owner_of("time_scale").is_empty())


func _test_value_falls_through() -> void:
	# A claim carrying only analemma_mode must not blank out a lower claim's
	# time_scale — otherwise one subsystem's partial claim silently unpauses
	# another's.
	var c := ClockClaims.new()
	c.claim("low", {"time_scale": 2.0})
	c.claim("high", {"analemma_mode": true})
	_check("time_scale falls through partial claim",
		float(c.value_or("time_scale", 0.01)) == 2.0)
	_check("analemma read from top", bool(c.value_or("analemma_mode", false)))
	_check("undefined key returns base",
		str(c.value_or("nothing_defines_this", "base")) == "base")


func _test_signal() -> void:
	var c := ClockClaims.new()
	var seen: Array = []
	c.effective_changed.connect(func(v: Dictionary) -> void: seen.append(v))
	c.claim("a", {"time_scale": 1.0})
	_check("signal on claim", seen.size() == 1)
	c.claim("a", {"time_scale": 1.0})
	_check("no signal when nothing changed", seen.size() == 1)
	c.claim("a", {"time_scale": 2.0})
	_check("signal on value change", seen.size() == 2)
	c.release("a")
	_check("signal on release back to base", seen.size() == 3)
	_check("release payload is empty", (seen[2] as Dictionary).is_empty())


## The clock keeps the user's intent in base_time_scale and reports the claimed
## value from time_scale, so save/load, TimelineUI and the multiplayer clock RPC
## keep writing the same property they always did and need no changes.
func _test_clock_integration() -> void:
	var clock = ClockScript.new()
	clock.time_scale = 0.05
	_check("plain write reads back", is_equal_approx(clock.time_scale, 0.05))
	_check("plain write went to base", is_equal_approx(clock.base_time_scale, 0.05))

	clock.claim_clock("lab", {"time_scale": 0.0})
	_check("claim overrides reported time_scale", is_equal_approx(clock.time_scale, 0.0))
	_check("base is untouched by the claim", is_equal_approx(clock.base_time_scale, 0.05))

	# A user speed change DURING a claim must be remembered, not lost — it is
	# their intent for when the claim ends.
	clock.time_scale = 0.2
	_check("user intent still lands on base while claimed",
		is_equal_approx(clock.base_time_scale, 0.2))
	_check("claim still wins while held", is_equal_approx(clock.time_scale, 0.0))

	clock.release_clock("lab")
	_check("release reveals the newer user intent", is_equal_approx(clock.time_scale, 0.2))

	# advance() must integrate the EFFECTIVE scale, or a claimed pause would not
	# actually stop the world.
	clock.claim_clock("pause", {"time_scale": 0.0})
	var before := clock.get_absolute_hours()
	clock.advance(1.0)
	_check("advance honours a claimed pause",
		is_equal_approx(clock.get_absolute_hours(), before))
	clock.release_clock("pause")
	clock.advance(1.0)
	_check("advance resumes after release", clock.get_absolute_hours() > before)
