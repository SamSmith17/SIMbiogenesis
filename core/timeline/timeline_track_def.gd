class_name TimelineTrackDef
extends RefCounted

## One row in the NLE track stack (clip strip or sensor waveform).

const KIND_CLIPS := "clips"
const KIND_WAVEFORM := "waveform"

const SOURCE_LIVE := "live"
const SOURCE_SIM := "sim"
const SOURCE_OBSERVED := "observed"

static func channel_catalog() -> Array:
	return [
		{
			"id": "solar_kw", "label": "Solar", "unit": "kW",
			"color": Color(0.961, 0.620, 0.043, 1.0),
			"mode": "peak",
			"sources": [SOURCE_LIVE, SOURCE_SIM, SOURCE_OBSERVED],
		},
		{
			"id": "load_kw", "label": "Load", "unit": "kW",
			"color": Color(0.95, 0.35, 0.30, 1.0),
			"mode": "peak",
			"sources": [SOURCE_LIVE, SOURCE_SIM, SOURCE_OBSERVED],
		},
		{
			"id": "aux_kw", "label": "Aux Gen", "unit": "kW",
			"color": Color(0.45, 0.85, 0.55, 1.0),
			"mode": "peak",
			"sources": [SOURCE_LIVE, SOURCE_SIM],
		},
		{
			"id": "net_kw", "label": "Net", "unit": "kW",
			"color": Color(0.133, 0.827, 0.933, 1.0),
			"mode": "peak",
			"sources": [SOURCE_LIVE, SOURCE_SIM, SOURCE_OBSERVED],
		},
		{
			"id": "soc_pct", "label": "Battery %", "unit": "%",
			"color": Color(0.149, 0.902, 0.467, 1.0),
			"mode": "avg",
			"sources": [SOURCE_LIVE, SOURCE_SIM, SOURCE_OBSERVED],
		},
		{
			"id": "soc_kwh", "label": "Battery", "unit": "kWh",
			"color": Color(0.149, 0.902, 0.467, 1.0),
			"mode": "avg",
			"sources": [SOURCE_LIVE, SOURCE_SIM, SOURCE_OBSERVED],
		},
	]

var id : String = ""
var kind : String = KIND_WAVEFORM
var label : String = "Track"
var channel : String = "solar_kw"
var source : String = SOURCE_LIVE
var height : float = 28.0
var enabled : bool = true
var color : Color = Color(0.5, 0.7, 0.9, 1.0)


static func lookup_channel(channel_id : String) -> Dictionary:
	for c in channel_catalog():
		if str(c.get("id", "")) == channel_id:
			return c
	return {}


func aggregate_mode() -> String:
	var meta : Dictionary = lookup_channel(channel)
	return str(meta.get("mode", "peak"))


static func default_tracks() -> Array:
	var out : Array = []
	var clips := TimelineTrackDef.new()
	clips.id = "clips"
	clips.kind = KIND_CLIPS
	clips.label = "Clips"
	clips.height = 11.0
	clips.enabled = true
	out.append(clips)
	for spec in [
		{"id": "solar_live", "channel": "solar_kw", "source": SOURCE_LIVE, "label": "Solar", "height": 28.0},
		{"id": "soc_live", "channel": "soc_pct", "source": SOURCE_LIVE, "label": "Battery", "height": 28.0},
		{"id": "load_live", "channel": "load_kw", "source": SOURCE_LIVE, "label": "Load", "height": 24.0},
	]:
		var t := TimelineTrackDef.new()
		t.id = str(spec["id"])
		t.kind = KIND_WAVEFORM
		t.channel = str(spec["channel"])
		t.source = str(spec["source"])
		t.label = str(spec["label"])
		t.height = float(spec["height"])
		var meta : Dictionary = lookup_channel(t.channel)
		t.color = meta.get("color", t.color) as Color
		t.enabled = true
		out.append(t)
	return out


func to_dict() -> Dictionary:
	return {
		"id": id,
		"kind": kind,
		"label": label,
		"channel": channel,
		"source": source,
		"height": height,
		"enabled": enabled,
		"color": [color.r, color.g, color.b, color.a],
	}


static func from_dict(d : Dictionary) -> TimelineTrackDef:
	var t := TimelineTrackDef.new()
	t.id = str(d.get("id", ""))
	t.kind = str(d.get("kind", KIND_WAVEFORM))
	t.label = str(d.get("label", "Track"))
	t.channel = str(d.get("channel", "solar_kw"))
	t.source = str(d.get("source", SOURCE_LIVE))
	t.height = float(d.get("height", 28.0))
	t.enabled = bool(d.get("enabled", true))
	var c : Variant = d.get("color", null)
	if c is Array and (c as Array).size() >= 3:
		var ca : Array = c as Array
		t.color = Color(float(ca[0]), float(ca[1]), float(ca[2]),
			float(ca[3]) if ca.size() >= 4 else 1.0)
	else:
		var meta : Dictionary = lookup_channel(t.channel)
		t.color = meta.get("color", t.color) as Color
	return t
