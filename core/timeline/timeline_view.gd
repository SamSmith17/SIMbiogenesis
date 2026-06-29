class_name TimelineView
extends RefCounted

## Maps absolute sim hours ↔ track pixels and picks adaptive ruler ticks.
## Owned by TimelineUI; keeps view state (start, span) separate from playhead time.

const HOURS_PER_DAY := 24.0
const HOURS_PER_YEAR := 8766.0  # mean Gregorian year length in hours

const DEFAULT_SPAN_HOURS := 7.0 * HOURS_PER_DAY
const MIN_SPAN_HOURS := 1.0
const MAX_SPAN_HOURS := 50.0 * HOURS_PER_YEAR

const ZOOM_IN_FACTOR := 0.85
const ZOOM_OUT_FACTOR := 1.0 / ZOOM_IN_FACTOR

const MIN_MAJOR_SPACING_PX := 56.0
const MIN_MINOR_SPACING_PX := 14.0

const FOLLOW_DEADZONE_LOW := 0.2
const FOLLOW_DEADZONE_HIGH := 0.8
const FOLLOW_POSITION_LOW := 0.2
const FOLLOW_POSITION_HIGH := 0.8

## Major tick intervals (hours). Month/year entries use calendar alignment when a clock is supplied.
const TICK_LADDER_MAJOR : Array = [
	1.0, 2.0, 3.0, 6.0, 12.0,
	HOURS_PER_DAY, 2.0 * HOURS_PER_DAY, 7.0 * HOURS_PER_DAY,
	30.0 * HOURS_PER_DAY, 90.0 * HOURS_PER_DAY,
	HOURS_PER_YEAR, 5.0 * HOURS_PER_YEAR, 10.0 * HOURS_PER_YEAR,
]

const MONTH_NAMES : Array = [
	"Jan", "Feb", "Mar", "Apr", "May", "Jun",
	"Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
]

var start : float = NAN
var span : float = DEFAULT_SPAN_HOURS
var width_px : float = 1.0
var follow_playhead : bool = true


func reset_to_playhead(playhead_abs : float) -> void:
	start = playhead_abs - span * 0.5
	follow_playhead = true


func clamp_span(hours : float) -> float:
	return clampf(hours, MIN_SPAN_HOURS, MAX_SPAN_HOURS)


func set_span(hours : float) -> void:
	span = clamp_span(hours)


func end() -> float:
	return start + span


func pixels_per_hour() -> float:
	if span <= 0.0 or width_px <= 1.0:
		return 1.0
	return width_px / span


func time_to_x(t : float) -> float:
	if span <= 0.0 or width_px <= 1.0:
		return 0.0
	return (t - start) / span * width_px


func x_to_time(x : float) -> float:
	if span <= 0.0 or width_px <= 1.0:
		return start
	var frac := clampf(x / width_px, 0.0, 1.0)
	return start + frac * span


func apply_playhead_follow(playhead_abs : float) -> void:
	if not follow_playhead:
		return
	if is_nan(start):
		reset_to_playhead(playhead_abs)
		return
	var rel := (playhead_abs - start) / span
	if rel < FOLLOW_DEADZONE_LOW:
		start = playhead_abs - span * FOLLOW_POSITION_LOW
	elif rel > FOLLOW_DEADZONE_HIGH:
		start = playhead_abs - span * FOLLOW_POSITION_HIGH


func zoom_at_cursor(factor : float, cursor_x : float) -> void:
	if width_px <= 1.0:
		return
	var t_anchor := x_to_time(cursor_x)
	var new_span := clamp_span(span * factor)
	if is_equal_approx(new_span, span):
		return
	var frac := clampf(cursor_x / width_px, 0.0, 1.0)
	start = t_anchor - frac * new_span
	span = new_span
	follow_playhead = false


func pan_by_pixels(delta_px : float) -> void:
	if width_px <= 1.0 or span <= 0.0:
		return
	start -= delta_px / width_px * span
	follow_playhead = false


func pan_by_hours(delta_hours : float) -> void:
	start -= delta_hours
	follow_playhead = false


func choose_major_interval_hours() -> float:
	var px_per_h := pixels_per_hour()
	if px_per_h <= 0.0:
		return HOURS_PER_DAY
	var min_spacing := _effective_major_spacing_px()
	var target_majors := clampf(width_px / min_spacing, 4.0, 30.0)
	var ideal := span / target_majors
	var best := float(TICK_LADDER_MAJOR[0])
	var best_score := INF
	for interval in TICK_LADDER_MAJOR:
		var ih := float(interval)
		if ih * px_per_h < min_spacing:
			continue
		var score := absf(log(maxf(ih, 0.01)) - log(maxf(ideal, 0.01)))
		if score < best_score:
			best_score = score
			best = ih
	return best


func _effective_major_spacing_px() -> float:
	if span <= HOURS_PER_DAY:
		# Up to ~28 major labels across a single-day view.
		return maxf(16.0, width_px / 28.0)
	return MIN_MAJOR_SPACING_PX


func choose_minor_interval_hours(major : float) -> float:
	if major <= 1.0:
		return 0.0
	var px_per_h := pixels_per_hour()
	var candidates : Array = []
	if major >= HOURS_PER_DAY:
		candidates = [6.0, 12.0]
	elif major >= 12.0:
		candidates = [3.0, 6.0]
	elif major >= 6.0:
		candidates = [1.0, 2.0]
	elif major >= 3.0:
		candidates = [1.0]
	elif major >= 2.0:
		candidates = [0.5]
	else:
		return 0.0
	for c in candidates:
		if float(c) * px_per_h >= MIN_MINOR_SPACING_PX and major / float(c) <= 12.0:
			return float(c)
	return 0.0


func collect_ticks(clock : Variant = null) -> Dictionary:
	var major := choose_major_interval_hours()
	var minor := choose_minor_interval_hours(major)
	var win_end := start + span
	return {
		"major": _collect_aligned_ticks(start, win_end, major, clock),
		"minor": _collect_aligned_ticks(start, win_end, minor, clock) if minor > 0.0 else [],
		"major_interval": major,
		"minor_interval": minor,
	}


func format_tick_label(abs_hours : float, interval_hours : float, clock : Variant = null) -> String:
	var dd := _date_dict(abs_hours, clock)
	if dd.is_empty():
		return _format_tick_fallback(abs_hours, interval_hours)
	var y : int = int(dd.get("year", 1))
	var mo : int = int(dd.get("month", 1))
	var day : int = int(dd.get("day", 1))
	var tod : float = float(dd.get("day_time", 0.0))
	if interval_hours >= HOURS_PER_YEAR * 0.9:
		return str(y)
	if interval_hours >= 25.0 * HOURS_PER_DAY:
		return "%s %d" % [MONTH_NAMES[clampi(mo - 1, 0, 11)], y]
	if interval_hours >= HOURS_PER_DAY * 0.9:
		return "%s %d" % [MONTH_NAMES[clampi(mo - 1, 0, 11)], day]
	if interval_hours >= 1.0:
		var hour : int = int(floor(tod)) % 24
		var minute : int = int(round(fmod(tod, 1.0) * 60.0))
		if minute >= 60:
			minute = 0
			hour = (hour + 1) % 24
		if interval_hours >= 12.0:
			if hour == 0:
				return "12 AM"
			if hour == 12:
				return "12 PM"
			return "%d %s" % [hour if hour <= 12 else hour - 12, "AM" if hour < 12 else "PM"]
		return "%02d:%02d" % [hour, minute]
	return "%02d:%02d" % [int(floor(tod)) % 24, int(round(fmod(tod, 1.0) * 60.0)) % 60]


func format_edge_label(abs_hours : float, view_span : float, clock : Variant = null) -> String:
	if view_span <= 2.0 * HOURS_PER_DAY:
		return format_tick_label(abs_hours, 1.0, clock)
	if view_span <= 120.0 * HOURS_PER_DAY:
		return format_tick_label(abs_hours, HOURS_PER_DAY, clock)
	if view_span <= 3.0 * HOURS_PER_YEAR:
		return format_tick_label(abs_hours, 30.0 * HOURS_PER_DAY, clock)
	return format_tick_label(abs_hours, HOURS_PER_YEAR, clock)


static func span_label(view_span : float) -> String:
	if view_span <= 2.0 * HOURS_PER_DAY:
		return "1 day"
	if view_span <= 14.0 * HOURS_PER_DAY:
		return "%d days" % int(round(view_span / HOURS_PER_DAY))
	if view_span <= 45.0 * HOURS_PER_DAY:
		return "1 month"
	if view_span <= 120.0 * HOURS_PER_DAY:
		return "%d mo" % int(round(view_span / (30.0 * HOURS_PER_DAY)))
	if view_span <= 2.5 * HOURS_PER_YEAR:
		return "1 year"
	if view_span <= 15.0 * HOURS_PER_YEAR:
		return "%d yrs" % int(round(view_span / HOURS_PER_YEAR))
	return "%d yrs" % int(round(view_span / HOURS_PER_YEAR))


func _collect_aligned_ticks(win_start : float, win_end : float, interval : float, clock : Variant) -> Array:
	if interval <= 0.0:
		return []
	if interval >= HOURS_PER_YEAR * 0.9 and clock != null:
		return _year_ticks(win_start, win_end, clock)
	if interval >= 25.0 * HOURS_PER_DAY and clock != null:
		return _month_ticks(win_start, win_end, clock)
	var aligned := _align_floor(win_start, interval)
	var out : Array = []
	var t := aligned
	var guard := 0
	while t <= win_end + interval * 0.001 and guard < 10000:
		if t >= win_start - interval * 0.001:
			out.append(t)
		t += interval
		guard += 1
	return out


func _align_floor(t : float, interval : float) -> float:
	if interval >= HOURS_PER_DAY * 0.9 and interval < HOURS_PER_DAY * 1.1:
		return floor(t / HOURS_PER_DAY) * HOURS_PER_DAY
	return floor(t / interval) * interval


func _year_ticks(win_start : float, win_end : float, clock : Variant) -> Array:
	var out : Array = []
	var dd := _date_dict(win_start, clock)
	if dd.is_empty():
		return out
	var y : int = int(dd.get("year", 1))
	var t := _abs_for_ymd(clock, y, 1, 1, 0.0)
	if t < win_start:
		y += 1
		t = _abs_for_ymd(clock, y, 1, 1, 0.0)
	var guard := 0
	while t <= win_end + 1.0 and guard < 500:
		if t >= win_start - 1.0:
			out.append(t)
		y += 1
		t = _abs_for_ymd(clock, y, 1, 1, 0.0)
		guard += 1
	return out


func _month_ticks(win_start : float, win_end : float, clock : Variant) -> Array:
	var out : Array = []
	var dd := _date_dict(win_start, clock)
	if dd.is_empty():
		return out
	var y : int = int(dd.get("year", 1))
	var mo : int = int(dd.get("month", 1))
	var t := _abs_for_ymd(clock, y, mo, 1, 0.0)
	if t < win_start:
		mo += 1
		if mo > 12:
			mo = 1
			y += 1
		t = _abs_for_ymd(clock, y, mo, 1, 0.0)
	var guard := 0
	while t <= win_end + 1.0 and guard < 2000:
		if t >= win_start - 1.0:
			out.append(t)
		mo += 1
		if mo > 12:
			mo = 1
			y += 1
		t = _abs_for_ymd(clock, y, mo, 1, 0.0)
		guard += 1
	return out


func _date_dict(abs_hours : float, clock : Variant) -> Dictionary:
	if clock != null and clock.has_method("abs_hours_to_date"):
		return clock.call("abs_hours_to_date", abs_hours)
	return {}


func _abs_for_ymd(clock : Variant, y : int, mo : int, d : int, tod : float) -> float:
	if clock == null:
		return NAN
	if clock.has_method("_calculate_day_of_year") and clock.has_method("_days_before_year"):
		var doy : int = clock.call("_calculate_day_of_year", mo, d, y)
		return float(clock.call("_days_before_year", y) + (doy - 1)) * HOURS_PER_DAY + tod
	return NAN


func _format_tick_fallback(abs_hours : float, interval_hours : float) -> String:
	var day_idx := int(floor(abs_hours / HOURS_PER_DAY))
	var tod := fmod(abs_hours, HOURS_PER_DAY)
	if interval_hours >= HOURS_PER_YEAR * 0.9:
		return "Y%d" % int(round(float(day_idx) / 365.25))
	if interval_hours >= HOURS_PER_DAY * 0.9:
		return "D%d" % day_idx
	if interval_hours >= 1.0:
		var hour : int = int(floor(tod)) % 24
		var minute : int = int(round(fmod(tod, 1.0) * 60.0)) % 60
		return "%02d:%02d" % [hour, minute]
	return "%.1fh" % tod
