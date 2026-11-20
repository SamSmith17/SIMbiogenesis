class_name BattSpec
extends RefCounted

## A battery pack design (record key `battery_spec`): which cell, how many in
## series (S) and in parallel (P), how they are arranged, joined, protected
## and boxed. 0 / "" / "auto" values are worked out by BattDesign.solve.
##
## Form factors:
##  - "automotive": a BCI group case (24, 27, 31, 4D, 8D, GC2). A lead-acid
##    monoblock IS the pack (S 1, P 1); a lithium "drop-in" puts cells in the
##    same case.
##  - "rack": a 19" server-rack pack (440 mm body, height in rack units).
##  - "wall": an upright wall-mount cabinet, shallow front to back.
##  - "rolling": a floor unit on casters with a handle.
##  - "diy": an open-top box or frame for a home-built pack.

const FORMS: Array = ["automotive", "rack", "wall", "rolling", "diy"]
const FORM_WORDS := {
	"automotive": "Automotive case", "rack": "19\" server rack", "wall": "Wall mount",
	"rolling": "Rolling floor unit", "diy": "DIY box",
}

## BCI group outer sizes, mm [length (x), height (y), width (z)] (BCI
## battery group specifications; heights include the posts).
const BCI_GROUPS := {
	"24": [260.0, 225.0, 173.0], "27": [306.0, 225.0, 173.0], "31": [330.0, 240.0, 173.0],
	"4D": [527.0, 254.0, 222.0], "8D": [527.0, 254.0, 279.0], "GC2": [264.0, 283.0, 181.0],
}

const INTERCONNECTS: Array = ["auto", "busbar", "nickel", "link"]
const MATERIALS: Array = ["steel", "aluminium", "abs"]
const RACK_U_MM := 44.45
const MAX_SERIES := 64
const MAX_PARALLEL := 200


static func empty(name: String = "New battery") -> Dictionary:
	return {
		"v": 1, "name": name, "form": "diy", "cell_id": "eve_lf280k",
		"series": 16, "parallel": 1,
		"arrange": {"cols": 0, "rows": 0, "layers": 0, "group_rows": 0, "face": "auto",
			"orient": "auto", "staggered": false},
		"interconnect": "auto",
		"busbar": {"material": "copper", "w_mm": 0.0, "t_mm": 0.0},
		"holders": true,
		"compression": {"on": true, "kgf": 0.0},
		"bms": {"id": "", "overrides": {}},
		"enclosure": {"w_mm": 0.0, "h_mm": 0.0, "d_mm": 0.0, "material": "",
			"group": "31", "u": 0, "handles": true, "wheels": false, "display": true,
			"breaker_a": 0.0, "ears": true},
		"colors": {"wrap": [], "case": []},
	}


## Defaults filled in, values clamped; never mutates `spec`.
static func resolve(spec: Dictionary) -> Dictionary:
	var out := empty(str(spec.get("name", "New battery")))
	_merge(out, spec)
	if not FORMS.has(str(out["form"])):
		out["form"] = "diy"
	if not BattCells.has(str(out["cell_id"])):
		out["cell_id"] = "eve_lf280k"
	out["series"] = clampi(int(out["series"]), 1, MAX_SERIES)
	out["parallel"] = clampi(int(out["parallel"]), 1, MAX_PARALLEL)
	if not INTERCONNECTS.has(str(out["interconnect"])):
		out["interconnect"] = "auto"
	var ar: Dictionary = out["arrange"]
	for k in ["cols", "rows", "layers", "group_rows"]:
		ar[k] = maxi(int(ar[k]), 0)
	if not ["auto", "x", "z"].has(str(ar["face"])):
		ar["face"] = "auto"
	if not ["auto", "up", "side"].has(str(ar["orient"])):
		ar["orient"] = "auto"
	var en: Dictionary = out["enclosure"]
	if not BCI_GROUPS.has(str(en["group"])):
		en["group"] = "31"
	en["u"] = clampi(int(en["u"]), 0, 12)
	return out


static func _merge(dst: Dictionary, src: Dictionary) -> void:
	for k in src:
		var v: Variant = src[k]
		if dst.has(k) and dst[k] is Dictionary and v is Dictionary and k != "overrides":
			_merge(dst[k], v)
		elif v is Dictionary or v is Array:
			dst[k] = v.duplicate(true)
		else:
			dst[k] = v


## Cache key: the resolved spec as JSON with floats rounded (JSON hands every
## number back as a float, so integral floats are written as ints).
static func key_of(spec: Dictionary) -> String:
	return JSON.stringify(_rounded(resolve(spec)))


static func _rounded(v: Variant) -> Variant:
	if v is Dictionary:
		var keys: Array = (v as Dictionary).keys()
		keys.sort()
		var out := {}
		for k in keys:
			out[k] = _rounded((v as Dictionary)[k])
		return out
	if v is Array:
		var a: Array = []
		for x in v:
			a.append(_rounded(x))
		return a
	if v is float or v is int:
		var f := snappedf(float(v), 0.001)
		return int(f) if is_equal_approx(f, roundf(f)) else f
	return v
