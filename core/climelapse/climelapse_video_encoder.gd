class_name ClimelapseVideoEncoder
extends RefCounted

## PNG frame sequence → H.264 MP4 via ffmpeg (Godot has no native MP4 writer).


static func find_ffmpeg() -> String:
	var from_path := _find_on_path()
	if not from_path.is_empty():
		return from_path
	if OS.get_name() == "Windows":
		var local_app := OS.get_environment("LOCALAPPDATA")
		if not local_app.is_empty():
			var winget := local_app.path_join("Microsoft/WinGet/Links/ffmpeg.exe")
			if FileAccess.file_exists(winget):
				return winget.replace("\\", "/")
		for candidate in [
			"C:/ProgramData/chocolatey/bin/ffmpeg.exe",
			"C:/Program Files/ffmpeg/bin/ffmpeg.exe",
		]:
			if FileAccess.file_exists(candidate):
				return candidate
	return _read_config_ffmpeg_path()


static func _find_on_path() -> String:
	var out: Array = []
	var err := -1
	if OS.get_name() == "Windows":
		err = OS.execute("where", ["ffmpeg"], out, true, false)
	else:
		err = OS.execute("which", ["ffmpeg"], out, true, false)
	if err != 0 or out.is_empty():
		return ""
	var line := str(out[0]).strip_edges()
	if line.contains("\n"):
		line = line.split("\n")[0]
	line = line.strip_edges()
	if line.is_empty() or not FileAccess.file_exists(line):
		return ""
	return line.replace("\\", "/")


static func _read_config_ffmpeg_path() -> String:
	var cfg := ConfigFile.new()
	if cfg.load("user://terrain_config.cfg") != OK:
		return ""
	var p := str(cfg.get_value("climelapse", "ffmpeg_path", "")).strip_edges()
	if p.is_empty() or not FileAccess.file_exists(p):
		return ""
	return p.replace("\\", "/")


static func encode_png_sequence(frames_dir: String, fps: int, output_mp4: String) -> Dictionary:
	var ffmpeg := find_ffmpeg()
	if ffmpeg.is_empty():
		return {
			"ok": false,
			"reason": (
				"ffmpeg not found — install ffmpeg, add it to PATH, or set "
				+ "[climelapse] ffmpeg_path= in user://terrain_config.cfg"
			),
		}
	var pattern := ProjectSettings.globalize_path(frames_dir.path_join("frame_%05d.png"))
	var out_path := ProjectSettings.globalize_path(output_mp4)
	pattern = pattern.replace("\\", "/")
	out_path = out_path.replace("\\", "/")
	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	var args := PackedStringArray([
		"-y", "-framerate", str(maxi(1, fps)), "-i", pattern,
		"-c:v", "libx264", "-preset", "medium", "-crf", "18",
		"-pix_fmt", "yuv420p", out_path,
	])
	var output: Array = []
	var err := OS.execute(ffmpeg, args, output, true, false)
	var log := ""
	for line in output:
		log += str(line)
	if err != 0:
		return {"ok": false, "reason": "ffmpeg failed (exit %d): %s" % [err, log]}
	if not FileAccess.file_exists(output_mp4):
		return {"ok": false, "reason": "ffmpeg reported success but MP4 missing: %s" % output_mp4}
	return {"ok": true, "reason": "", "path": output_mp4}
