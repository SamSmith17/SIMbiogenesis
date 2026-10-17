class_name RunLengthLabels
extends Node3D

## Optional length tags on 3D runs — "23.4 m · 76.8 ft" floating at each run's
## arc-length midpoint — for mapping out a whole distribution system (how much
## cord, how much hose). Owned by ConduitManager as a child, so a tag shows
## exactly when its run does (x-ray in the lenses, hidden in first person while
## 3D wires are off). One Label3D per run, rewritten only when the run
## rebuilds; distance-faded so a site full of runs is not a wall of text.
##
## The switch is a player pref (user://ui_prefs.cfg [conduits] show_lengths),
## read through `enabled()` / `set_enabled()`; the manager polls `generation`.

const PREFS_PATH := "user://ui_prefs.cfg"
const FADE_END_M := 70.0
static var _enabled := -1
static var generation := 0

var _tags: Dictionary = {}   ## conn_id -> Label3D


static func enabled() -> bool:
	if _enabled < 0:
		var cfg := ConfigFile.new()
		_enabled = 0
		if cfg.load(PREFS_PATH) == OK and bool(cfg.get_value("conduits", "show_lengths", false)):
			_enabled = 1
	return _enabled == 1


static func set_enabled(on: bool) -> void:
	_enabled = 1 if on else 0
	generation += 1
	var cfg := ConfigFile.new()
	cfg.load(PREFS_PATH)
	cfg.set_value("conduits", "show_lengths", on)
	cfg.save(PREFS_PATH)


## The point half way along `samples` by arc length.
static func midpoint(samples: PackedVector3Array) -> Vector3:
	if samples.is_empty():
		return Vector3.INF
	if samples.size() == 1:
		return samples[0]
	var total := 0.0
	for i in range(1, samples.size()):
		total += samples[i - 1].distance_to(samples[i])
	var half := total * 0.5
	var acc := 0.0
	for i in range(1, samples.size()):
		var seg := samples[i - 1].distance_to(samples[i])
		if acc + seg >= half and seg > 0.0:
			return samples[i - 1].lerp(samples[i], (half - acc) / seg)
		acc += seg
	return samples[samples.size() - 1]


func set_run(conn_id: String, samples: PackedVector3Array, length_m: float, type_id: String) -> void:
	if not enabled() or length_m <= 0.01 or samples.size() < 2:
		clear_run(conn_id)
		return
	var tag: Label3D = _tags.get(conn_id, null)
	if tag == null or not is_instance_valid(tag):
		tag = Label3D.new()
		tag.name = "Len_%s" % conn_id
		tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		tag.no_depth_test = true
		tag.fixed_size = false
		tag.pixel_size = 0.004
		tag.font_size = 40
		tag.outline_size = 10
		tag.outline_modulate = Color(0, 0, 0, 0.85)
		tag.modulate = Color(1.0, 0.86, 0.45)
		tag.visibility_range_end = FADE_END_M
		tag.visibility_range_end_margin = 10.0
		tag.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		tag.top_level = true
		add_child(tag)
		_tags[conn_id] = tag
	var m := midpoint(samples)
	tag.global_position = m + Vector3(0.0, 0.35, 0.0)
	tag.text = "%s\n%s" % [ConduitLength.format(length_m), ConduitKinds.display_name(type_id)]


func clear_run(conn_id: String) -> void:
	var tag: Label3D = _tags.get(conn_id, null)
	if tag != null and is_instance_valid(tag):
		tag.queue_free()
	_tags.erase(conn_id)


func clear_all() -> void:
	for cid in _tags.keys():
		clear_run(str(cid))


func has_run(conn_id: String) -> bool:
	return _tags.has(conn_id) and is_instance_valid(_tags[conn_id])


func tag_for(conn_id: String) -> Label3D:
	return _tags.get(conn_id, null) as Label3D
