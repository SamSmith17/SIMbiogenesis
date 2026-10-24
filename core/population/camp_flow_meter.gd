class_name CampFlowMeter
extends RefCounted

## THE CALCULATOR: how much one camp actually took in and put out, over sim
## time — litres of water, kilos of food and firewood, litres of greywater and
## blackwater (and the pee / poo inside it), and person-hours lived.
##
## Fed once per ambient tick with the habitat's LIVE flow rates (what its
## people consumed and produced this step, whatever supplied it: the camp's
## own tanks, a shared depot, or the "infinite" import the calculator mode
## assumes), integrated into one-hour bins keyed on absolute sim hours. A
## scrub BACK truncates the bins after the playhead (the EnergyTimeline rule:
## the future is re-lived, not remembered); a jump past MAX_GAP_H is not
## metered (the coarse catch-up models coping, not a lived day). Pure and
## serializable: it rides the camp compound as `camp_meter`.

const BIN_H := 1.0
## Thirty days of hourly bins; older hours fold into `_folded`.
const MAX_BINS := 24 * 30
const MAX_GAP_H := 6.0
const PERSON_H := "person_h"
## What one person's blackwater is made of, per day (Rose et al. 2015, "The
## characterization of feces and urine", Crit. Rev. Env. Sci. Tech. 45:
## urine ~1.42 L, wet feces ~0.128 kg). The rest is flush / rinse water.
const URINE_L_PER_PERSON_DAY := 1.42
const FECES_KG_PER_PERSON_DAY := 0.128
const IN_KINDS: Array = ["water", "food", "biomass", "meal"]
const OUT_KINDS: Array = ["greywater", "blackwater", "biomass"]

var start_h := NAN     # absolute hour of bin 0 (a whole hour)
var last_h := NAN
var _bins: Dictionary = {}     # key -> Array[float]  ("in:water", "out:greywater", "person_h")
var _folded: Dictionary = {}   # key -> float, hours older than MAX_BINS


static func key_in(kind: String) -> String:
	return "in:" + kind


static func key_out(kind: String) -> String:
	return "out:" + kind


## One step. rates_in / rates_out: {kind: rate per hour}; present: people;
## imports / exports: the part of rates_in / rates_out brought in from / hauled
## off site (the "infinite" shortfall).
func record(abs_h: float, rates_in: Dictionary, rates_out: Dictionary, present: float,
		imports: Dictionary = {}, exports: Dictionary = {}) -> void:
	if is_nan(abs_h):
		return
	if is_nan(last_h):
		last_h = abs_h
		if is_nan(start_h):
			start_h = floorf(abs_h / BIN_H) * BIN_H
		return
	if abs_h < last_h - 1e-6:
		truncate_after(abs_h)
		last_h = abs_h
		return
	var dt := abs_h - last_h
	last_h = abs_h
	if dt <= 0.0 or dt > MAX_GAP_H:
		return
	var mid := abs_h - dt * 0.5
	for k in rates_in.keys():
		_add(key_in(str(k)), mid, maxf(float(rates_in[k]), 0.0) * dt)
	for k2 in rates_out.keys():
		_add(key_out(str(k2)), mid, maxf(float(rates_out[k2]), 0.0) * dt)
	_add(PERSON_H, mid, maxf(present, 0.0) * dt)
	for k3 in imports.keys():
		_add("imp:" + str(k3), mid, maxf(float(imports[k3]), 0.0) * dt)
	for k4 in exports.keys():
		_add("exp:" + str(k4), mid, maxf(float(exports[k4]), 0.0) * dt)


func _add(key: String, at_h: float, qty: float) -> void:
	if qty <= 0.0:
		return
	if is_nan(start_h):
		start_h = floorf(at_h / BIN_H) * BIN_H
	var i := int(floor((at_h - start_h) / BIN_H))
	if i < 0:
		return
	var arr: Array = _bins.get(key, [])
	while arr.size() <= i:
		arr.append(0.0)
	arr[i] = float(arr[i]) + qty
	_bins[key] = arr
	_fold_old()


func _fold_old() -> void:
	var longest := 0
	for k in _bins.keys():
		longest = maxi(longest, (_bins[k] as Array).size())
	var drop := longest - MAX_BINS
	if drop <= 0:
		return
	for k in _bins.keys():
		var arr: Array = _bins[k]
		var n := mini(drop, arr.size())
		var s := 0.0
		for j in n:
			s += float(arr[j])
		_folded[k] = float(_folded.get(k, 0.0)) + s
		_bins[k] = arr.slice(n)
	start_h += float(drop) * BIN_H


## Forget everything metered after `abs_h` (a scrub back).
func truncate_after(abs_h: float) -> void:
	if is_nan(start_h):
		return
	var keep := maxi(int(ceil((abs_h - start_h) / BIN_H)), 0)
	for k in _bins.keys():
		var arr: Array = _bins[k]
		if arr.size() > keep:
			_bins[k] = arr.slice(0, keep)


func clear() -> void:
	start_h = NAN
	last_h = NAN
	_bins = {}
	_folded = {}


## Everything metered for `key` so far.
func total(key: String) -> float:
	var s := float(_folded.get(key, 0.0))
	for v in (_bins.get(key, []) as Array):
		s += float(v)
	return s


## Hours of bins the meter holds (a camp of zero people still has a clock).
func hours() -> float:
	if is_nan(start_h) or is_nan(last_h):
		return 0.0
	return maxf(last_h - start_h, 0.0)


## Mean per DAY over the last `window_h` hours metered (or all of them).
func per_day(key: String, window_h: float = 24.0) -> float:
	var arr: Array = _bins.get(key, [])
	var h := minf(hours(), window_h)
	if h <= 1e-6 or arr.is_empty():
		return 0.0
	var n := mini(int(ceil(h / BIN_H)), arr.size())
	var s := 0.0
	for j in range(arr.size() - n, arr.size()):
		s += float(arr[j])
	return s / h * 24.0


## The last `n` hourly bins (oldest first), zero-padded on the left.
func series(key: String, n: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(n)
	var arr: Array = _bins.get(key, [])
	var off := n - arr.size()
	for j in arr.size():
		if j + off >= 0:
			out[j + off] = float(arr[j])
	return out


## Person-days lived (person_h / 24).
func person_days() -> float:
	return total(PERSON_H) / 24.0


## The calculator's rows: [{key, label, unit, total, per_day, per_person_day}].
func summary() -> Array:
	var out: Array = []
	var pd := person_days()
	var pdd := per_day(PERSON_H) / 24.0   # people present, averaged over the day
	for row in [["in:water", "Water in", "L"], ["in:food", "Food in", "kg"], ["in:meal", "Meals in", "meals"],
			["in:biomass", "Firewood in", "kg"], ["out:greywater", "Greywater out", "L"],
			["out:blackwater", "Blackwater out", "L"], ["out:biomass", "Food scraps out", "kg"]]:
		var k := str(row[0])
		var t := total(k)
		if t <= 0.0 and not (k == "in:water" or k == "in:food" or k == "out:greywater" or k == "out:blackwater"):
			continue
		var d := per_day(k)
		var kind := k.substr(k.find(":") + 1)
		var off_key := ("imp:" if k.begins_with("in:") else "exp:") + kind
		out.append({"key": k, "label": str(row[1]), "unit": str(row[2]), "total": t, "per_day": d,
			"per_person_day": d / pdd if pdd > 1e-6 else 0.0,
			# How much of it crossed the camp's boundary (imported / hauled off).
			"offsite_total": total(off_key), "offsite_per_day": per_day(off_key)})
	# Inside the blackwater: what the people themselves made.
	out.append({"key": "pee", "label": "  of which pee", "unit": "L", "total": pd * URINE_L_PER_PERSON_DAY,
		"per_day": pdd * URINE_L_PER_PERSON_DAY, "per_person_day": URINE_L_PER_PERSON_DAY})
	out.append({"key": "poo", "label": "  of which poo", "unit": "kg", "total": pd * FECES_KG_PER_PERSON_DAY,
		"per_day": pdd * FECES_KG_PER_PERSON_DAY, "per_person_day": FECES_KG_PER_PERSON_DAY})
	return out


func to_dict() -> Dictionary:
	return {"start_h": start_h if not is_nan(start_h) else -1.0, "last_h": last_h if not is_nan(last_h) else -1.0,
		"bins": _bins.duplicate(true), "folded": _folded.duplicate(true)}


static func from_dict(d: Dictionary) -> CampFlowMeter:
	var m := CampFlowMeter.new()
	var s := float(d.get("start_h", -1.0))
	var l := float(d.get("last_h", -1.0))
	m.start_h = s if s >= 0.0 else NAN
	m.last_h = l if l >= 0.0 else NAN
	var b: Variant = d.get("bins", {})
	if b is Dictionary:
		for k in (b as Dictionary).keys():
			var arr: Array = []
			for v in ((b as Dictionary)[k] as Array):
				arr.append(float(v))
			m._bins[str(k)] = arr
	var f: Variant = d.get("folded", {})
	if f is Dictionary:
		for k2 in (f as Dictionary).keys():
			m._folded[str(k2)] = float((f as Dictionary)[k2])
	return m
