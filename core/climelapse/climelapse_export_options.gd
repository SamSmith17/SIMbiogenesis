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
##
## A video SECOND, not a real second: the export steps the world itself, so
## the time it takes to render has nothing to do with how fast the result plays.

const CFG_PATH := "user://climelapse_export.cfg"

## Speeds offered in the dialog: label, sim-hours per video second. The first
## seven are the timeline bar's own speeds (1× … Max), so "Max" means the same
## thing in both places; the last two are faster than any bar speed.
const TIME_PRESETS: Array = [
	["1× (real time)", 0.000278],
	["10×", 0.002778],
	["60× (1 min per second)", 0.016667],
	["300× (5 min per second)", 0.083333],
	["450×", 0.125],
	["1440× (24 min per second)", 0.4],
	["Max (2 h per second)", 2.0],
	["Day per second", 24.0],
	["Week per second", 168.0],
]
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
	}


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
	out["hours_per_second"] = maxf(float(out["hours_per_second"]), 1e-5)
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


## Frames the export renders: the range divided into steps, both ends included.
static func frame_count(o: Dictionary) -> int:
	var span := float(o.get("end_abs", 0.0)) - float(o.get("start_abs", 0.0))
	if span <= 0.0:
		return 0
	return int(floor(span / hours_per_frame(o) + 1e-6)) + 1


static func video_seconds(o: Dictionary) -> float:
	return float(frame_count(o)) / float(maxi(1, int(o.get("fps", 30))))


## Sim hour of frame i (frame 0 = the range start, the last frame <= the end).
static func frame_hours(o: Dictionary, i: int) -> float:
	return float(o.get("start_abs", 0.0)) + float(i) * hours_per_frame(o)


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
	"shadows", "msaa", "taa", "settle_frames", "timecode", "crf"]


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
