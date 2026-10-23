class_name ClimelapseExportOptions
extends RefCounted

## Everything a video export is asked to do, as one Dictionary, plus the pure
## maths the export dialog, the capture and the selftest all share.
##
## Keys (`defaults()`):
##   start_abs, end_abs   the range, absolute sim hours (Ctrl-drag selection)
##   hours_per_second     sim-hours that pass per second of VIDEO
##   fps                  video frame rate
##   width, height        video size in pixels (always even: yuv420p needs it)
##   folder, file_name    where the .mp4 goes
##   quality              graphics preset for the export, -1 = keep the current
##   shadows              shadow preset for the export, -1 = keep the current
##   msaa                 0 / 2 / 4 / 8, -1 = the game's own setting
##   taa                  -1 = the game's own, 0 off, 1 on
##   settle_frames        frames rendered per video frame before the grab
##                        (lets TAA and the volumetric fog catch up)
##   timecode             draw the date/time strip along the bottom
##   crf                  x264 quality (lower = bigger, sharper)
##   analemma             0 off, 1 the sun's analemma, 2 the moon's: one frame
##                        per day (at the same solar time / at the moon's
##                        transit), with the figure drawn on the sky
##   analemma_days_per_second  analemma calendar days per second of VIDEO
##                        (any value: below the frame rate a day is held for
##                        several frames, above it days are skipped — the
##                        figure on the sky still gets every day)
##   clouds               false = a clear sky for the export (no clouds, no
##                        cloud shadows, full sunlight); the weather otherwise
##   star_trails          -1 as set in the game, 0 off, 1 grow through each
##                        night (a long exposure that starts at dusk)
##   camera_timing        "auto" | "pinned" | "spread": keyframes play at
##                        their moments on the timeline, or their path is
##                        spread over the whole video (key_timing resolves
##                        "auto")
##   follow               "none" | "sun" | "moon" | "stars": the camera turns
##                        to keep the sun / moon centred, or turns with the
##                        sky so the stars hold still and the ground wheels
##
## A video SECOND, not a real second: the export steps the world itself, so
## the time it takes to render has nothing to do with how fast the result plays.

const CFG_PATH := "user://climelapse_export.cfg"

## Speeds offered in the dialog: label, sim-hours per video second. The first
## seven are the timeline bar's own speeds (1× … Max), so "Max" means the same
## thing in both places; the rest are faster than any bar speed (any value can
## also be typed, or the video length set instead).
const TIME_PRESETS: Array = [
	["1× (real time)", 0.000278],
	["10×", 0.002778],
	["60× (1 min per second)", 0.016667],
	["300× (5 min per second)", 0.083333],
	["450×", 0.125],
	["1440× (24 min per second)", 0.4],
	["Max (2 h per second)", 2.0],
	["Day per second", 24.0],
	["3 days per second", 72.0],
	["Week per second", 168.0],
	["Month per second", 730.5],
	["Season per second", 2191.5],
	["Year per second", 8766.0],
]
## Fastest speed the dialog accepts (sim-hours per video second).
const MAX_RATE := 100000.0

## Analemma speeds: label, calendar days per video second. The game's ∞ is one
## day per rendered frame, so at 60 fps it plays 60 days a second.
const ANALEMMA_PRESETS: Array = [
	["A day per second", 1.0],
	["A week per second", 7.0],
	["A month per second", 30.4375],
	["60 days per second (∞ in the game)", 60.0],
	["A season per second", 91.3125],
	["A year per second", 365.25],
]
## An analemma needs most of a year to show its figure: a shorter range is
## widened to this many days when analemma is chosen (analemma_range).
const ANALEMMA_YEAR_DAYS := 365
const ANALEMMA_MIN_DAYS := 30
## Index of "Max" in TIME_PRESETS.
const MAX_PRESET := 6

const RES_PRESETS: Array = [
	["3840 × 2160 (4K)", 3840, 2160],
	["2560 × 1440", 2560, 1440],
	["1920 × 1080 (HD)", 1920, 1080],
	["1280 × 720", 1280, 720],
	["854 × 480", 854, 480],
]
const FPS_CHOICES: Array = [24, 25, 30, 50, 60]
const MSAA_CHOICES: Array = [-1, 0, 2, 4, 8]

const MIN_SIDE := 64
const MAX_SIDE := 7680
## Hard ceiling on frames in one export (an hour of 60 fps video).
const MAX_FRAMES := 216000


static func defaults() -> Dictionary:
	return {
		"start_abs": 0.0,
		"end_abs": 24.0,
		"hours_per_second": 2.0,
		"fps": 30,
		"width": 1920,
		"height": 1080,
		"folder": default_folder(),
		"file_name": "climelapse.mp4",
		"quality": -1,
		"shadows": -1,
		"msaa": -1,
		"taa": -1,
		"settle_frames": 2,
		"timecode": true,
		"crf": 18,
		"analemma": 0,
		"analemma_days_per_second": 30.4375,
		"clouds": true,
		"star_trails": -1,
		"follow": "none",
		"camera_timing": "auto",
	}


## Keyframe timing choices: id, label.
const CAMERA_TIMING_CHOICES: Array = [
	["auto", "Automatic"],
	["pinned", "At their moments on the timeline"],
	["spread", "Spread over the whole video"],
]


## How the keyframes play in this export: "pinned" (each key at its moment on
## the timeline) or "spread" (the path from the first key to the last fills
## the video, the keys keeping their spacing). "auto" pins when the keys
## belong to this range — two or more inside it, or their span covering at
## least half of it — and spreads otherwise; an analemma always spreads (its
## clock jumps a day a frame, so pinned keys would play in its first frames
## and then hold). Keys a few hours apart and a year-long export used to give
## a camera that moved once and then sat still.
static func key_timing(o: Dictionary, keys: ClimelapseKeyframes) -> String:
	var want := str(o.get("camera_timing", "auto"))
	if want == "pinned" or want == "spread":
		return want
	if keys == null or keys.size() < 2:
		return "pinned"
	if int(o.get("analemma", 0)) > 0:
		return "spread"
	var s := float(o.get("start_abs", 0.0))
	var e := float(o.get("end_abs", 0.0))
	if e <= s:
		return "pinned"
	var ts := keys.times()
	var inside := 0
	for t in ts:
		if t >= s and t <= e:
			inside += 1
	var overlap := minf(e, ts[ts.size() - 1]) - maxf(s, ts[0])
	return "pinned" if inside >= 2 or overlap >= 0.5 * (e - s) else "spread"


## Camera follow choices: id, label.
const FOLLOW_CHOICES: Array = [
	["none", "Keyframes only"],
	["sun", "Follow the sun"],
	["moon", "Follow the moon"],
	["stars", "Follow the stars (sky holds still)"],
]


static func default_folder() -> String:
	var d := OS.get_system_dir(OS.SYSTEM_DIR_MOVIES)
	if d.is_empty():
		d = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	return d.replace("\\", "/")


## Clamp every value into range and round the size to even numbers. Unknown
## keys are kept (callers may carry their own).
static func normalize(o: Dictionary) -> Dictionary:
	var d := defaults()
	var out := o.duplicate(true)
	for k in d.keys():
		if not out.has(k):
			out[k] = d[k]
	out["hours_per_second"] = clampf(float(out["hours_per_second"]), 1e-5, MAX_RATE)
	out["fps"] = clampi(int(out["fps"]), 1, 120)
	out["width"] = even_size(int(out["width"]))
	out["height"] = even_size(int(out["height"]))
	out["quality"] = clampi(int(out["quality"]), -1, 3)
	out["shadows"] = clampi(int(out["shadows"]), -1, 3)
	var m := int(out["msaa"])
	out["msaa"] = m if MSAA_CHOICES.has(m) else -1
	out["taa"] = clampi(int(out["taa"]), -1, 1)
	out["settle_frames"] = clampi(int(out["settle_frames"]), 1, 8)
	out["crf"] = clampi(int(out["crf"]), 0, 51)
	out["timecode"] = bool(out["timecode"])
	out["analemma"] = clampi(int(out["analemma"]), 0, 2)
	out["analemma_days_per_second"] = clampf(float(out["analemma_days_per_second"]), 0.01, 100000.0)
	out["clouds"] = bool(out["clouds"])
	out["star_trails"] = clampi(int(out["star_trails"]), -1, 1)
	var fol := str(out["follow"])
	out["follow"] = fol if ["none", "sun", "moon", "stars"].has(fol) else "none"
	var tim := str(out["camera_timing"])
	out["camera_timing"] = tim if ["auto", "pinned", "spread"].has(tim) else "auto"
	out["file_name"] = clean_file_name(str(out["file_name"]))
	out["folder"] = str(out["folder"]).replace("\\", "/")
	return out


static func even_size(px: int) -> int:
	var v := clampi(px, MIN_SIDE, MAX_SIDE)
	return v - (v % 2)


## A file name with no folder parts, no characters Windows refuses, ending .mp4.
static func clean_file_name(name: String) -> String:
	var n := name.strip_edges().replace("\\", "/").get_file()
	for c in ["<", ">", ":", "\"", "|", "?", "*"]:
		n = n.replace(c, "_")
	if n.is_empty() or n == ".mp4":
		n = "climelapse.mp4"
	if not n.to_lower().ends_with(".mp4"):
		n += ".mp4"
	return n


static func output_path(o: Dictionary) -> String:
	var folder := str(o.get("folder", "")).replace("\\", "/")
	var file := clean_file_name(str(o.get("file_name", "")))
	if folder.is_empty():
		return file
	return folder.path_join(file)


## Sim-hours advanced between two video frames.
static func hours_per_frame(o: Dictionary) -> float:
	return maxf(float(o.get("hours_per_second", 2.0)), 1e-5) / float(maxi(1, int(o.get("fps", 30))))


## Frames the export renders: the range divided into steps, both ends
## included. An analemma export walks the calendar days of the range at
## `analemma_days_per_second` instead (first day to last day, both included).
static func frame_count(o: Dictionary) -> int:
	var span := float(o.get("end_abs", 0.0)) - float(o.get("start_abs", 0.0))
	if span <= 0.0:
		return 0
	if int(o.get("analemma", 0)) > 0:
		var last := analemma_days_in(o) - 1.0
		return int(floor(last * float(_fps(o)) / analemma_dps(o) + 1e-6)) + 1
	return int(floor(span / hours_per_frame(o) + 1e-6)) + 1


static func _fps(o: Dictionary) -> int:
	return maxi(1, int(o.get("fps", 30)))


static func analemma_dps(o: Dictionary) -> float:
	return clampf(float(o.get("analemma_days_per_second", 30.4375)), 0.01, 100000.0)


## The calendar day (0 = the range's first) analemma frame i shows. Below the
## frame rate a day repeats over several frames; above it days are skipped
## (the export still steps through them, so the figure gets every day).
static func analemma_day_of_frame(o: Dictionary, i: int) -> int:
	var last := int(analemma_days_in(o)) - 1
	return clampi(int(floor(float(i) * analemma_dps(o) / float(_fps(o)) + 1e-6)), 0, last)


## The range an analemma export should cover: kept when it spans at least
## ANALEMMA_MIN_DAYS, else widened to a year from the start day. Returns a
## copy of `o` (unchanged when analemma is off).
static func analemma_range(o: Dictionary) -> Dictionary:
	var out := o.duplicate()
	if int(out.get("analemma", 0)) <= 0:
		return out
	var s := float(out.get("start_abs", 0.0))
	if float(out.get("end_abs", 0.0)) - s >= float(ANALEMMA_MIN_DAYS) * 24.0:
		return out
	out["end_abs"] = year_end(s)
	return out


## Noon of the last day of a year that starts on `start_abs`'s day (so the
## export has exactly ANALEMMA_YEAR_DAYS frames at one day per frame).
static func year_end(start_abs: float) -> float:
	return (floorf(start_abs / 24.0) + float(ANALEMMA_YEAR_DAYS - 1)) * 24.0 + 12.0


## The speed (sim-hours per second, or analemma days per second) that makes
## the video `seconds` long. NAN when the range is empty.
static func speed_for_length(o: Dictionary, seconds: float) -> float:
	var fps := float(_fps(o))
	var frames := maxf(roundf(seconds * fps), 2.0)
	if int(o.get("analemma", 0)) > 0:
		var last := analemma_days_in(o) - 1.0
		if last <= 0.0:
			return NAN
		return clampf(last * fps / (frames - 1.0), 0.01, 100000.0)
	var span := float(o.get("end_abs", 0.0)) - float(o.get("start_abs", 0.0))
	if span <= 0.0:
		return NAN
	return clampf(span * fps / (frames - 1.0), 1e-5, MAX_RATE)


## Calendar days an analemma export covers (the start day through the end day).
static func analemma_days_in(o: Dictionary) -> float:
	var d0 := floorf(float(o.get("start_abs", 0.0)) / 24.0)
	var d1 := floorf(float(o.get("end_abs", 0.0)) / 24.0)
	return maxf(d1 - d0 + 1.0, 1.0)


static func video_seconds(o: Dictionary) -> float:
	return float(frame_count(o)) / float(maxi(1, int(o.get("fps", 30))))


## Sim hour of frame i (frame 0 = the range start, the last frame <= the end).
## For an analemma export: noon of the frame's day (the exact instant is the
## sun's / moon's own, set by ClimelapseSkyDirector).
static func frame_hours(o: Dictionary, i: int) -> float:
	if int(o.get("analemma", 0)) > 0:
		var d0 := floorf(float(o.get("start_abs", 0.0)) / 24.0)
		return (d0 + float(analemma_day_of_frame(o, i))) * 24.0 + 12.0
	return float(o.get("start_abs", 0.0)) + float(i) * hours_per_frame(o)


## Index into ANALEMMA_PRESETS matching `dps`, else -1.
static func analemma_preset_for(dps: float) -> int:
	for i in ANALEMMA_PRESETS.size():
		var r := float(ANALEMMA_PRESETS[i][1])
		if absf(r - dps) <= r * 0.01:
			return i
	return -1


## Index into TIME_PRESETS whose rate is closest to `h_per_s`, else -1.
static func preset_for_rate(h_per_s: float) -> int:
	for i in TIME_PRESETS.size():
		var r := float(TIME_PRESETS[i][1])
		if absf(r - h_per_s) <= r * 0.01:
			return i
	return -1


## Default file name for a range: climelapse_2024_04_18.mp4
static func default_file_name(start_abs: float) -> String:
	var dt: Dictionary = CelestialClock.new().abs_hours_to_date(start_abs)
	return "climelapse_%d_%02d_%02d.mp4" % [
		int(dt.get("year", 1)), int(dt.get("month", 1)), int(dt.get("day", 1))]


static func format_timecode(year: int, month: int, day: int, day_time: float = 12.0) -> String:
	var mins := int(round(fposmod(day_time, 24.0) * 60.0)) % (24 * 60)
	return "%04d-%02d-%02d   %02d:%02d" % [year, month, day, mins / 60, mins % 60]


static func timecode_at(abs_h: float) -> String:
	var dt: Dictionary = CelestialClock.new().abs_hours_to_date(abs_h)
	return format_timecode(int(dt.get("year", 1)), int(dt.get("month", 1)), int(dt.get("day", 1)),
		float(dt.get("day_time", fposmod(abs_h, 24.0))))


## ffmpeg arguments for raw RGB frames arriving on stdin.
static func ffmpeg_pipe_args(o: Dictionary, out_path: String) -> PackedStringArray:
	return PackedStringArray([
		"-y", "-hide_banner", "-loglevel", "error", "-nostats",
		"-f", "rawvideo", "-pix_fmt", "rgb24",
		"-s", "%dx%d" % [int(o["width"]), int(o["height"])],
		"-framerate", str(int(o["fps"])),
		"-i", "-",
		"-c:v", "libx264", "-preset", "medium", "-crf", str(int(o.get("crf", 18))),
		"-pix_fmt", "yuv420p", "-movflags", "+faststart",
		out_path.replace("\\", "/"),
	])


## One-line summary for the dialog and the confirm text.
static func summary(o: Dictionary) -> String:
	var n := frame_count(o)
	return "%s · %s of video at %d fps · %d × %d" % [
		UiText.count(n, "frame"), duration_label(video_seconds(o)), int(o["fps"]),
		int(o["width"]), int(o["height"])]


static func duration_label(secs: float) -> String:
	var s := int(round(secs))
	if secs < 10.0:
		return "%.1f s" % secs
	if s < 60:
		return "%d s" % s
	if s < 3600:
		return "%d min %02d s" % [s / 60, s % 60]
	return "%d h %02d min" % [s / 3600, (s % 3600) / 60]


static func span_label(hours: float) -> String:
	if hours < 48.0:
		return "%.1f h" % hours
	return "%.1f days" % (hours / 24.0)


# --- remembered choices -------------------------------------------------------

const _PERSIST_KEYS := ["hours_per_second", "fps", "width", "height", "folder", "quality",
	"shadows", "msaa", "taa", "settle_frames", "timecode", "crf", "analemma", "analemma_days_per_second",
	"clouds", "star_trails", "follow", "camera_timing"]


static func load_prefs(path: String = CFG_PATH) -> Dictionary:
	var out := defaults()
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return out
	for k in _PERSIST_KEYS:
		if cfg.has_section_key("export", k):
			out[k] = cfg.get_value("export", k)
	return normalize(out)


static func save_prefs(o: Dictionary, path: String = CFG_PATH) -> void:
	var cfg := ConfigFile.new()
	for k in _PERSIST_KEYS:
		if o.has(k):
			cfg.set_value("export", k, o[k])
	cfg.save(path)
