class_name HighScoreStore
extends RefCounted

## Local high-score persistence under user://scores/.
## Keyed by map lat/lon (+ optional challenge id). Never committed.

const SCORES_DIR := "user://scores"
const FREEPLAY_CHALLENGE := "freeplay"


static func map_key(lat: float, lon: float) -> String:
	return "%.4f_%.4f" % [lat, lon]


static func path_for(lat: float, lon: float) -> String:
	return "%s/%s.json" % [SCORES_DIR, map_key(lat, lon).replace(".", "p").replace("-", "m")]


static func load_scores(lat: float, lon: float) -> Dictionary:
	var path := path_for(lat, lon)
	if not FileAccess.file_exists(path):
		return {"lat": lat, "lon": lon, "entries": {}}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"lat": lat, "lon": lon, "entries": {}}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		var d: Dictionary = parsed
		if not d.has("entries"):
			d["entries"] = {}
		return d
	return {"lat": lat, "lon": lon, "entries": {}}


static func best_score(lat: float, lon: float, challenge_id: String = "") -> float:
	var cid := challenge_id if not challenge_id.is_empty() else FREEPLAY_CHALLENGE
	var data := load_scores(lat, lon)
	var entries: Dictionary = data.get("entries", {}) as Dictionary
	var e: Variant = entries.get(cid, {})
	if e is Dictionary:
		return float((e as Dictionary).get("score", 0.0))
	return 0.0


## Record score if it beats the previous best. Returns the new best, or 0 if not improved.
static func record_if_best(lat: float, lon: float, challenge_id: String, score: float,
		extra: Dictionary = {}) -> float:
	if score <= 0.0:
		return 0.0
	var cid := challenge_id if not challenge_id.is_empty() else FREEPLAY_CHALLENGE
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SCORES_DIR))
	var data := load_scores(lat, lon)
	var entries: Dictionary = (data.get("entries", {}) as Dictionary).duplicate(true)
	var prev := 0.0
	if entries.has(cid) and entries[cid] is Dictionary:
		prev = float((entries[cid] as Dictionary).get("score", 0.0))
	if score <= prev:
		return 0.0
	var entry: Dictionary = {
		"score": score,
		"unix": int(Time.get_unix_time_from_system()),
		"iso": Time.get_datetime_string_from_system(true, true),
	}
	for k: String in extra.keys():
		entry[k] = extra[k]
	entries[cid] = entry
	data["lat"] = lat
	data["lon"] = lon
	data["entries"] = entries
	var path := path_for(lat, lon)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return 0.0
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	return score
