class_name CompositionTrack
extends RefCounted

## A tracked tank's make-up over time (resource composition plan Phase 10),
## so scrubbing back and the sim pre-render's replay read the make-up the
## tank had then. One sample per STRIDE_H bucket (the last write in a bucket
## wins), the newest MAX_SAMPLES kept (14 days at 15 min, the energy
## timeline's span). Pure.
##
##   record(abs_h, mu)       write the bucket abs_h falls in
##   at(abs_h)               the make-up at or before abs_h ({} = none yet)
##   truncate_after(abs_h)   forget everything after abs_h (an edit, a scrub)
##   to_dict / from_dict

const STRIDE_H := 0.25
const MAX_SAMPLES := 1344

var times := PackedFloat64Array()
var values := PackedFloat32Array()   # stride MakeUp.KEYS.size()


func record(abs_h: float, mu: Dictionary) -> void:
	var b := floorf(abs_h / STRIDE_H) * STRIDE_H
	var n := MakeUp.KEYS.size()
	var row := PackedFloat32Array()
	row.resize(n)
	for i in n:
		row[i] = float(mu.get(MakeUp.KEYS[i], 0.0))
	if not times.is_empty() and absf(times[times.size() - 1] - b) < 1e-9:
		for i2 in n:
			values[values.size() - n + i2] = row[i2]
		return
	if not times.is_empty() and b < times[times.size() - 1]:
		truncate_after(b - 1e-9)
	times.append(b)
	values.append_array(row)
	if times.size() > MAX_SAMPLES:
		var drop := times.size() - MAX_SAMPLES
		times = times.slice(drop)
		values = values.slice(drop * n)


func at(abs_h: float) -> Dictionary:
	if times.is_empty():
		return {}
	var i := times.bsearch(abs_h + 1e-9) - 1
	i = clampi(i, 0, times.size() - 1)
	var n := MakeUp.KEYS.size()
	var out: Dictionary = {}
	for k in n:
		out[MakeUp.KEYS[k]] = float(values[i * n + k])
	return out


func truncate_after(abs_h: float) -> void:
	var keep := times.bsearch(abs_h + 1e-9)
	if keep >= times.size():
		return
	times = times.slice(0, keep)
	values = values.slice(0, keep * MakeUp.KEYS.size())


func size() -> int:
	return times.size()


func to_dict() -> Dictionary:
	return {"t": Array(times), "v": Array(values)}


static func from_dict(d: Dictionary) -> CompositionTrack:
	var tr := CompositionTrack.new()
	for t in d.get("t", []):
		tr.times.append(float(t))
	for v in d.get("v", []):
		tr.values.append(float(v))
	return tr
