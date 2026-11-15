class_name IcsWriter
extends RefCounted

## iCalendar (RFC 5545) files from ScheduledEvents lists. Pure: the time zone,
## the calendar's name and "now" are passed in, so the same events always make
## the same text (the selftest round-trips it through `parse`).
##
## Times: events carry absolute sim hours on the SITE's clock, which is local
## wall-clock time. They are written as local times with a TZID, and the file
## carries a VTIMEZONE for that zone: the standard offset of the zone meridian
## and, when the site's clock observes it, the US daylight rule the game's
## clock uses (CelestialClock._calculate_dst_for_date: 2nd Sunday of March to
## the 1st Sunday of November at 02:00). Importing the file therefore puts each
## event at the hour the game shows it.
##
## UIDs are "<calendar key>-<event id>@simbiogenesis", stable across exports,
## so importing a re-export into the same calendar UPDATES events instead of
## adding a second copy (RFC 5545 §3.8.4.7).

const PRODID := "-//SIMbiogenesis//Community schedule//EN"
const TZID := "SIMbiogenesis-Site"
const LINE_OCTETS := 75
## Days from 0001-01-01 (the clock's epoch, proleptic Gregorian) to 1970-01-01.
const EPOCH_DAYS_TO_UNIX := 719162


## Calendar fields of an absolute sim hour: {year, month, day, hour, minute, second}.
static func date_of(abs_h: float) -> Dictionary:
	var days := int(floor(abs_h / 24.0))
	var secs := int(round((abs_h - float(days) * 24.0) * 3600.0))
	if secs >= 86400:
		days += 1
		secs -= 86400
	var unix := (days - EPOCH_DAYS_TO_UNIX) * 86400 + secs
	var dt := Time.get_datetime_dict_from_unix_time(unix)
	return {"year": int(dt["year"]), "month": int(dt["month"]), "day": int(dt["day"]),
		"hour": int(dt["hour"]), "minute": int(dt["minute"]), "second": int(dt["second"])}


## The absolute sim hour of a calendar date-time (the inverse of date_of).
static func abs_of(y: int, mo: int, d: int, h: int = 0, mi: int = 0, s: int = 0) -> float:
	var unix := Time.get_unix_time_from_datetime_dict({"year": y, "month": mo, "day": d,
		"hour": 0, "minute": 0, "second": 0})
	var days := int(floor(float(unix) / 86400.0)) + EPOCH_DAYS_TO_UNIX
	return float(days) * 24.0 + float(h) + float(mi) / 60.0 + float(s) / 3600.0


static func local_stamp(abs_h: float) -> String:
	var d := date_of(abs_h)
	return "%04d%02d%02dT%02d%02d%02d" % [d.year, d.month, d.day, d.hour, d.minute, d.second]


static func utc_stamp(unix: int) -> String:
	var d := Time.get_datetime_dict_from_unix_time(unix)
	return "%04d%02d%02dT%02d%02d%02dZ" % [d.year, d.month, d.day, d.hour, d.minute, d.second]


## TEXT value escaping (RFC 5545 §3.3.11).
static func escape_text(s: String) -> String:
	return s.replace("\\", "\\\\").replace(";", "\\;").replace(",", "\\,") \
		.replace("\r\n", "\\n").replace("\n", "\\n").replace("\r", "\\n")


static func unescape_text(s: String) -> String:
	var out := ""
	var i := 0
	while i < s.length():
		var c := s[i]
		if c == "\\" and i + 1 < s.length():
			var n := s[i + 1]
			out += "\n" if (n == "n" or n == "N") else n
			i += 2
			continue
		out += c
		i += 1
	return out


## Fold one content line at 75 octets, never inside a UTF-8 character
## (RFC 5545 §3.1). Continuation lines start with a space.
static func fold(line: String) -> String:
	if line.to_utf8_buffer().size() <= LINE_OCTETS:
		return line
	var out: Array = []
	var cur := ""
	var cur_n := 0
	var limit := LINE_OCTETS
	for ch in line:
		var n := ch.to_utf8_buffer().size()
		if cur_n + n > limit:
			out.append(cur)
			cur = ""
			cur_n = 0
			limit = LINE_OCTETS - 1   # the leading space counts
		cur += ch
		cur_n += n
	out.append(cur)
	return "\r\n ".join(out)


static func _std_offset_text(off_h: float) -> String:
	var m := int(round(off_h * 60.0))
	var sgn := "+" if m >= 0 else "-"
	m = absi(m)
	return "%s%02d%02d" % [sgn, m / 60, m % 60]


## The VTIMEZONE block. `tz` = {std_offset_h, dst: bool}.
static func vtimezone(tz: Dictionary) -> Array:
	var std := float(tz.get("std_offset_h", 0.0))
	var dst := bool(tz.get("dst", false))
	var lines: Array = ["BEGIN:VTIMEZONE", "TZID:%s" % TZID]
	if dst:
		lines.append_array(["BEGIN:DAYLIGHT", "DTSTART:19700308T020000",
			"RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU",
			"TZOFFSETFROM:%s" % _std_offset_text(std), "TZOFFSETTO:%s" % _std_offset_text(std + 1.0),
			"TZNAME:Site daylight", "END:DAYLIGHT"])
		lines.append_array(["BEGIN:STANDARD", "DTSTART:19701101T020000",
			"RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU",
			"TZOFFSETFROM:%s" % _std_offset_text(std + 1.0), "TZOFFSETTO:%s" % _std_offset_text(std),
			"TZNAME:Site standard", "END:STANDARD"])
	else:
		lines.append_array(["BEGIN:STANDARD", "DTSTART:19700101T000000",
			"TZOFFSETFROM:%s" % _std_offset_text(std), "TZOFFSETTO:%s" % _std_offset_text(std),
			"TZNAME:Site time", "END:STANDARD"])
	lines.append("END:VTIMEZONE")
	return lines


static func uid_for(cal_key: String, ev_id: String) -> String:
	var safe := ev_id.replace(" ", "_").replace(";", "_").replace(",", "_")
	return "%s-%s@simbiogenesis" % [cal_key, safe]


## One calendar. `opts` = {name, key (UID prefix), tz: {std_offset_h, dst},
## now_unix (DTSTAMP), desc_of: Callable(ev) -> String (optional)}.
static func calendar(evs: Array, opts: Dictionary) -> String:
	var key := str(opts.get("key", "site"))
	var stamp := utc_stamp(int(opts.get("now_unix", 0)))
	var lines: Array = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:%s" % PRODID,
		"CALSCALE:GREGORIAN", "METHOD:PUBLISH"]
	var name := str(opts.get("name", ""))
	if not name.is_empty():
		lines.append("X-WR-CALNAME:%s" % escape_text(name))
	lines.append_array(vtimezone(opts.get("tz", {})))
	var desc_of: Callable = opts.get("desc_of", Callable())
	for e in ScheduledEvents.sort(evs):
		var ev: Dictionary = e
		var a := float(ev.get("at_h", 0.0))
		var b := float(ev.get("end_h", a))
		if b <= a:
			b = a + 0.25   # an instant shows as a quarter hour
		lines.append("BEGIN:VEVENT")
		lines.append("UID:%s" % uid_for(key, str(ev.get("id", ""))))
		lines.append("DTSTAMP:%s" % stamp)
		lines.append("DTSTART;TZID=%s:%s" % [TZID, local_stamp(a)])
		lines.append("DTEND;TZID=%s:%s" % [TZID, local_stamp(b)])
		lines.append("SUMMARY:%s" % escape_text(str(ev.get("label", ""))))
		lines.append("CATEGORIES:%s" % escape_text(ScheduledEvents.word_of(str(ev.get("kind", "")))))
		var desc := ""
		if desc_of.is_valid():
			desc = str(desc_of.call(ev))
		if not desc.is_empty():
			lines.append("DESCRIPTION:%s" % escape_text(desc))
		lines.append("TRANSP:%s" % ("OPAQUE" if str(ev.get("kind", "")) == ScheduledEvents.KIND_SHIFT else "TRANSPARENT"))
		lines.append("END:VEVENT")
	lines.append("END:VCALENDAR")
	var out := ""
	for l in lines:
		out += fold(str(l)) + "\r\n"
	return out


## A minimal reader, enough to round-trip what `calendar` writes: unfolds
## lines and returns {name, tzid, events: [{UID, DTSTART, DTEND, SUMMARY, ...}]}
## with TEXT values unescaped and DTSTART/DTEND as their raw local stamps.
static func parse(text: String) -> Dictionary:
	var raw := text.replace("\r\n", "\n").split("\n")
	var lines: Array = []
	for l in raw:
		if l.begins_with(" ") or l.begins_with("\t"):
			if not lines.is_empty():
				lines[lines.size() - 1] = str(lines[lines.size() - 1]) + l.substr(1)
			continue
		if not l.is_empty():
			lines.append(l)
	var out := {"name": "", "tzid": "", "events": []}
	var cur: Dictionary = {}
	var in_ev := false
	for l in lines:
		var s := str(l)
		var c := s.find(":")
		if c < 0:
			continue
		var head := s.substr(0, c)
		var val := s.substr(c + 1)
		var prop := head.split(";")[0]
		if s == "BEGIN:VEVENT":
			in_ev = true
			cur = {}
			continue
		if s == "END:VEVENT":
			in_ev = false
			(out["events"] as Array).append(cur)
			continue
		if in_ev:
			cur[prop] = unescape_text(val) if prop in ["SUMMARY", "DESCRIPTION", "CATEGORIES"] else val
		elif prop == "X-WR-CALNAME":
			out["name"] = unescape_text(val)
		elif prop == "TZID" and str(out["tzid"]).is_empty():
			out["tzid"] = val
	return out


## A file-system-safe name for a calendar file.
static func file_name(s: String) -> String:
	var out := ""
	for ch in s.strip_edges():
		if (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9") \
				or ch == "-" or ch == "_":
			out += ch
		elif ch == " " or ch == ".":
			out += "_"
	return out if not out.is_empty() else "calendar"
