class_name HaTimeUtil
extends RefCounted
## Parse Home Assistant ISO-8601 timestamps (UTC) into Unix seconds.


## Convert an HA timestamp like "2026-05-23T21:00:00.000Z" to Unix time.
## Godot's Time.get_unix_time_from_datetime_string() treats bare datetimes as
## local wall time and ignores the "Z" suffix, so we strip to components and
## compensate using the system timezone bias when the source is UTC.
static func utc_iso_to_unix(raw: Variant) -> int:
	if raw is float or raw is int:
		return int(raw)
	if not (raw is String):
		return 0
	var s: String = (raw as String).strip_edges()
	if s.is_empty():
		return 0

	var is_utc := s.ends_with("Z") or s.ends_with("z")
	var offset_minutes := 0
	if not is_utc:
		offset_minutes = _parse_explicit_offset_minutes(s)

	var iso := _strip_tz_and_fraction(s)
	if iso.is_empty():
		return 0

	var t := Time.get_unix_time_from_datetime_string(iso)
	if t <= 0:
		return 0

	if is_utc:
		var tz := Time.get_time_zone_from_system()
		# Parsed as local wall clock; subtract local bias to recover UTC instant.
		t += int(tz.bias) * 60
	elif offset_minutes != 0:
		# Parsed as local wall clock; adjust to UTC instant using embedded offset.
		t -= offset_minutes * 60

	return int(t)


static func _strip_tz_and_fraction(s: String) -> String:
	var iso := s
	if iso.ends_with("Z") or iso.ends_with("z"):
		iso = iso.substr(0, iso.length() - 1)
	else:
		var plus_idx := iso.find("+", 10)
		var minus_idx := iso.rfind("-")
		if plus_idx > 10:
			iso = iso.substr(0, plus_idx)
		elif minus_idx > 10:
			iso = iso.substr(0, minus_idx)
	var dot_idx := iso.find(".")
	if dot_idx > 0:
		iso = iso.substr(0, dot_idx)
	return iso


static func _parse_explicit_offset_minutes(s: String) -> int:
	var plus_idx := s.find("+", 10)
	var minus_idx := s.rfind("-")
	var tz_part := ""
	if plus_idx > 10:
		tz_part = s.substr(plus_idx + 1)
	elif minus_idx > 10:
		tz_part = s.substr(minus_idx + 1)
	else:
		return 0
	if tz_part.is_empty():
		return 0
	var sign := 1 if plus_idx > 10 else -1
	var parts := tz_part.split(":")
	if parts.size() < 2:
		return 0
	var hours := parts[0].to_int()
	var mins := parts[1].to_int()
	return sign * (hours * 60 + mins)
