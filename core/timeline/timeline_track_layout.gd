class_name TimelineTrackLayout
extends RefCounted

## Vertical layout for the NLE track stack inside TimelineUI.

const RULER_HEIGHT := 14.0
const TRACK_GAP := 1.0
const RESIZE_HIT_PX := 5.0
const MIN_WAVE_HEIGHT := 18.0
const MAX_WAVE_HEIGHT := 96.0

var tracks : Array = []   # TimelineTrackDef


func reset_defaults() -> void:
	tracks = TimelineTrackDef.default_tracks()


func load_from_array(raw : Array) -> void:
	tracks.clear()
	for item in raw:
		if item is Dictionary:
			tracks.append(TimelineTrackDef.from_dict(item))
	if tracks.is_empty():
		reset_defaults()


func to_array() -> Array:
	var out : Array = []
	for t in tracks:
		if t is TimelineTrackDef:
			out.append((t as TimelineTrackDef).to_dict())
	return out


func enabled_tracks() -> Array:
	var out : Array = []
	for t in tracks:
		if t is TimelineTrackDef and (t as TimelineTrackDef).enabled:
			out.append(t)
	return out


func content_height() -> float:
	var h := RULER_HEIGHT
	for t in enabled_tracks():
		if t is TimelineTrackDef:
			h += TRACK_GAP + (t as TimelineTrackDef).height
	return h


func lane_at_y(local_y : float) -> Dictionary:
	var y := RULER_HEIGHT
	for t in enabled_tracks():
		if not (t is TimelineTrackDef):
			continue
		var td : TimelineTrackDef = t as TimelineTrackDef
		y += TRACK_GAP
		var rect := Rect2(0.0, y, 1.0, td.height)
		if local_y >= rect.position.y and local_y < rect.end.y:
			return {"track": td, "rect": rect}
		y += td.height
	return {}


func resize_hit_at(local_y : float) -> int:
	var y := RULER_HEIGHT
	for i in tracks.size():
		var t : Variant = tracks[i]
		if not (t is TimelineTrackDef):
			continue
		var td : TimelineTrackDef = t as TimelineTrackDef
		if not td.enabled:
			continue
		y += TRACK_GAP + td.height
		if td.kind != TimelineTrackDef.KIND_CLIPS:
			if absf(local_y - y) <= RESIZE_HIT_PX:
				return i
	return -1


func apply_resize(track_index : int, delta_y : float) -> void:
	if track_index < 0 or track_index >= tracks.size():
		return
	var t : Variant = tracks[track_index]
	if not (t is TimelineTrackDef):
		return
	var td : TimelineTrackDef = t as TimelineTrackDef
	if td.kind == TimelineTrackDef.KIND_CLIPS:
		return
	td.height = clampf(td.height + delta_y, MIN_WAVE_HEIGHT, MAX_WAVE_HEIGHT)


func find_track(track_id : String) -> TimelineTrackDef:
	for t in tracks:
		if t is TimelineTrackDef and (t as TimelineTrackDef).id == track_id:
			return t as TimelineTrackDef
	return null


## A track drawn by something other than the power channel catalog (a Live
## link's recorded readings: source "ha"; any Home Assistant entity:
## "ha_entity"; a weather variable: "weather"). Re-adding an existing one
## shows it again instead of duplicating it.
func add_custom_track(source : String, channel : String, label : String, color : Color) -> TimelineTrackDef:
	for t in tracks:
		if t is TimelineTrackDef and (t as TimelineTrackDef).source == source and (t as TimelineTrackDef).channel == channel:
			(t as TimelineTrackDef).enabled = true
			return t
	var t := TimelineTrackDef.new()
	t.id = "%s_%s_%d" % [source, channel.replace(".", "_"), Time.get_ticks_msec()]
	t.kind = TimelineTrackDef.KIND_WAVEFORM
	t.channel = channel
	t.source = source
	t.label = label
	t.color = color
	t.height = 28.0
	t.enabled = true
	tracks.append(t)
	return t


## A Live link's recorded readings (`target_id` = an HaTargets id).
func add_ha_track(target_id : String, label : String) -> TimelineTrackDef:
	return add_custom_track("ha", target_id, "HA: %s" % label, Color(0.40, 0.85, 0.95, 1.0))


## Any Home Assistant entity, in its own unit.
func add_ha_entity_track(entity_id : String, label : String) -> TimelineTrackDef:
	return add_custom_track("ha_entity", entity_id, "HA: %s" % label, Color(0.55, 0.80, 1.00, 1.0))


## A weather variable (TimelineWeatherChannels id).
func add_weather_track(channel_id : String) -> TimelineTrackDef:
	var ch := TimelineWeatherChannels.find(channel_id)
	if ch.is_empty():
		return null
	return add_custom_track(TimelineWeatherChannels.SOURCE, channel_id, str(ch["label"]), ch["color"] as Color)


func remove_track(track_id : String) -> bool:
	for i in tracks.size():
		var t: Variant = tracks[i]
		if t is TimelineTrackDef and (t as TimelineTrackDef).id == track_id \
				and (t as TimelineTrackDef).kind != TimelineTrackDef.KIND_CLIPS:
			tracks.remove_at(i)
			return true
	return false


func add_waveform_track(channel_id : String, source : String) -> TimelineTrackDef:
	var meta : Dictionary = TimelineTrackDef.lookup_channel(channel_id)
	if meta.is_empty():
		return null
	var t := TimelineTrackDef.new()
	t.id = "%s_%s_%d" % [channel_id, source, Time.get_ticks_msec()]
	t.kind = TimelineTrackDef.KIND_WAVEFORM
	t.channel = channel_id
	t.source = source
	t.label = "%s (%s)" % [str(meta.get("label", channel_id)), source.substr(0, 3).to_upper()]
	t.color = meta.get("color", t.color) as Color
	t.height = 28.0
	t.enabled = true
	tracks.append(t)
	return t
