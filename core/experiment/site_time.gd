class_name SiteTime
extends RefCounted

## Unix time <-> the sim's own time axis (absolute hours in the SITE's zone).
##
## The sim clock is site local time: CelestialClock.zone_offset_hours (the
## rounded meridian plus the US DST rule) turns it into UTC for the sun, the
## weather and the stars. Real readings carry Unix times. Two older
## conversions existed and disagreed:
##   * CelestialClock.unix_to_abs_hours reads the UTC fields as if they were
##     local (no offset at all) — the CSV clip used it, so imported data sat
##     your UTC offset away from the sun that made it;
##   * HaObservedStore.abs_hours_local applies the COMPUTER's zone, which is
##     right only while the computer is at the site.
## This is the one the experiment uses: the clock's own zone at the instant.
##
## `clock` is any CelestialClock (Main's, or a bare one with longitude set);
## pure otherwise.

## Absolute hours on the site's clock of a Unix time.
static func unix_to_site_abs(clock: Object, t_unix: float) -> float:
	if clock == null:
		return NAN
	var whole := floorf(t_unix)
	var utc_abs := float(clock.call("unix_to_abs_hours", int(whole))) + (t_unix - whole) / 3600.0
	return utc_abs + offset_at_utc(clock, utc_abs)


## Unix time of an absolute hour on the site's clock.
static func site_abs_to_unix(clock: Object, abs_h: float) -> float:
	if clock == null:
		return NAN
	var off := offset_at_local(clock, abs_h)
	var epoch_abs := float(clock.call("unix_to_abs_hours", 0))
	return (abs_h - off - epoch_abs) * 3600.0


## Hours the site's clock is ahead of UTC at the UTC instant `utc_abs`.
static func offset_at_utc(clock: Object, utc_abs: float) -> float:
	var base := float(clock.call("zone_meridian_deg")) / 15.0
	# Standard time first, then the DST rule at that local date; one pass is
	# exact except inside the repeated hour of a DST change.
	return offset_at_local(clock, utc_abs + base)


## Hours the site's clock is ahead of UTC at the local instant `abs_h`.
static func offset_at_local(clock: Object, abs_h: float) -> float:
	var d: Dictionary = clock.call("abs_hours_to_date", abs_h)
	return float(clock.call("zone_offset_hours", int(d.get("year", 2026)),
		int(d.get("month", 1)), int(d.get("day", 1)), float(d.get("day_time", 0.0))))


## "2026-10-22 13:30" on the site clock.
static func format_abs(clock: Object, abs_h: float) -> String:
	if clock == null:
		return ""
	var d: Dictionary = clock.call("abs_hours_to_date", abs_h)
	var mins := int(round(float(d.get("day_time", 0.0)) * 60.0))
	if mins >= 1440:
		mins = 1439
	return "%04d-%02d-%02d %02d:%02d" % [int(d["year"]), int(d["month"]), int(d["day"]),
		mins / 60, mins % 60]


## Midnight (site clock) at or before `abs_h`.
static func day_start(abs_h: float) -> float:
	return floorf(abs_h / 24.0) * 24.0
