class_name CtrlSpec
extends RefCounted

## A charge controller / inverter / hybrid design (record key
## `controller_spec`): its box, colours, heatsink, mounting, wiring bay,
## ports and electrical numbers.
##
## LOCAL frame, millimetres: origin on the mounting plane (the wall) at the
## bottom centre of the unit, +Y up, +Z out of the wall (the front faces
## +Z), +X to the right seen from the front. The body box is
## x ∈ [−w/2, w/2], y ∈ [0, h], z ∈ [z0, z0 + d] where z0 is what stands
## between the wall and the body (a back heatsink, a bracket). A unit that
## sits on a shelf (car-style inverter, power station) uses the same frame
## with "back" as its rear end.
##
## Ports: {id, connector (ConnectorCatalog id), face ("front" | "back" |
## "left" | "right" | "top" | "bottom" | "bay"), u, v (mm from the face's
## centre along its own x / y), rot (° about the face normal), dz (mm off
## the face), group (CtrlRoles group), roles ([] or a role per pin), label,
## opts (connector opts)}.
##
## Faces' own axes (x = y × normal): front x right, y up; back x left, y up;
## left x toward the front, right x toward the back, both y up; top x right,
## y toward the back; bottom x right, y toward the front. "bay" is the wiring
## bay's back plate, facing +Z, its origin the bay's middle.

const FORMS := ["mppt_box", "wall_hybrid", "inverter_box", "car_inverter", "power_station", "dc_dc"]
const FORM_WORDS := {
	"mppt_box": "Charge controller", "wall_hybrid": "Wall-mount hybrid inverter",
	"inverter_box": "Inverter / charger box", "car_inverter": "Car-style inverter",
	"power_station": "Portable power station", "dc_dc": "DC-DC charger",
}
const KINDS := ["mppt", "pwm", "inverter", "inverter_charger", "hybrid", "charger", "dc_dc", "power_station"]
const KIND_WORDS := {
	"mppt": "MPPT charge controller", "pwm": "PWM charge controller", "inverter": "Inverter",
	"inverter_charger": "Inverter / charger", "hybrid": "Hybrid (MPPT + inverter + charger)",
	"charger": "Battery charger", "dc_dc": "DC-DC charger", "power_station": "Power station",
}
const FACES := ["front", "back", "left", "right", "top", "bottom", "bay"]
const HEATSINKS := ["none", "back", "full", "sides", "top"]
const MOUNTS := ["none", "tabs", "flange", "side_feet", "bracket", "feet", "ears", "handles"]
const FINISHES := ["paint", "plastic", "alu"]


static func empty(name: String = "New controller") -> Dictionary:
	return {
		"v": 1, "name": name, "form": "mppt_box", "maker": "", "model": "", "source": "",
		"body": {"w": 160.0, "h": 220.0, "d": 70.0, "corner_r": 6.0, "edge_r": 3.0,
			"color": [0.12, 0.12, 0.13], "finish": "paint",
			"split": {"y": -1.0, "color": [0.05, 0.05, 0.055]},
			"plate": {"on": false, "t": 8.0, "inset": 10.0, "color": [0.9, 0.9, 0.9], "corner_r": -1.0},
			"standoff": 0.0},
		"bands": [],
		"panels": [],
		"heatsink": {"where": "none", "fins": 10, "fin_d": 18.0, "fin_t": 2.0, "base_t": 4.0,
			"extra_w": 0.0, "color": [0.72, 0.73, 0.75], "slots": false},
		"mount": {"style": "none", "where": "both", "n": 2, "w": 30.0, "h": 18.0, "color": [-1.0, 0, 0]},
		"caps": {"t": 0.0, "color": [0.08, 0.08, 0.09]},
		"bay": {"on": false, "y1": 120.0, "wall": 12.0, "depth": 60.0, "color": [0.05, 0.05, 0.055],
			"cover": {"show": true, "color": [-1.0, 0, 0], "window": {"on": false, "x0": 0.0, "x1": 0.0, "y0": 0.0, "y1": 0.0}}},
		"vents": [],
		"texts": [],
		"ports": [],
		"elec": {"kind": "mppt", "system_v": 12, "max_voc": 100.0, "mppt_count": 1,
			"mppt_min_v": 0.0, "mppt_max_v": 0.0, "startup_v": 0.0, "max_input_a": 0.0, "max_isc_a": 0.0,
			"max_pv_w": 0.0, "max_pv_w_per_mppt": 0.0, "max_charge_a": 30.0,
			"ac_out_w": 0.0, "surge_w": 0.0, "ac_v": 120.0, "split_phase": false, "ac_in_a": 0.0,
			"load_a": 0.0, "idle_w": 0.0, "eff": {}, "comms": [], "cost": 0.0, "mass_kg": 0.0},
		"library": "",
	}


## Defaults filled, values clamped; never mutates `spec`.
static func resolve(spec: Dictionary) -> Dictionary:
	var out := empty(str(spec.get("name", "New controller")))
	_merge(out, spec)
	if not FORMS.has(str(out["form"])):
		out["form"] = "mppt_box"
	var b: Dictionary = out["body"]
	b["w"] = clampf(float(b["w"]), 40.0, 2000.0)
	b["h"] = clampf(float(b["h"]), 20.0, 2000.0)
	b["d"] = clampf(float(b["d"]), 15.0, 1000.0)
	var lim := minf(float(b["w"]), float(b["h"])) * 0.5 - 0.5
	b["corner_r"] = clampf(float(b["corner_r"]), 0.0, lim)
	b["edge_r"] = clampf(float(b["edge_r"]), 0.0, minf(float(b["d"]) * 0.4, lim))
	if not FINISHES.has(str(b["finish"])):
		b["finish"] = "paint"
	var hs: Dictionary = out["heatsink"]
	if not HEATSINKS.has(str(hs["where"])):
		hs["where"] = "none"
	hs["fins"] = clampi(int(hs["fins"]), 0, 80)
	var mt: Dictionary = out["mount"]
	if not MOUNTS.has(str(mt["style"])):
		mt["style"] = "none"
	var e: Dictionary = out["elec"]
	if not KINDS.has(str(e["kind"])):
		e["kind"] = "mppt"
	e["mppt_count"] = clampi(int(e["mppt_count"]), 0, 4)
	var ports: Array = []
	var seen := {}
	for p in (out["ports"] as Array):
		if not (p is Dictionary) or not ConnectorCatalog.has(str(p.get("connector", ""))):
			continue
		var q: Dictionary = {"id": "", "connector": "", "face": "front", "u": 0.0, "v": 0.0, "rot": 0.0, "dz": 0.0,
			"group": "", "roles": [], "label": "", "opts": {}}
		_merge(q, p)
		if not FACES.has(str(q["face"])):
			q["face"] = "front"
		var pid := str(q["id"])
		if pid == "" or seen.has(pid):
			pid = "p%d" % ports.size()
			while seen.has(pid):
				pid += "_"
			q["id"] = pid
		seen[pid] = true
		ports.append(q)
	out["ports"] = ports
	return out


static func color_of(v: Variant, fallback: Color = Color.GRAY) -> Color:
	if v is Color:
		return v
	if v is Array and (v as Array).size() >= 3 and float(v[0]) >= 0.0:
		return Color(float(v[0]), float(v[1]), float(v[2]))
	return fallback


static func _merge(dst: Dictionary, src: Dictionary) -> void:
	for k in src:
		var v: Variant = src[k]
		if dst.has(k) and dst[k] is Dictionary and v is Dictionary and k != "opts":
			_merge(dst[k], v)
		elif v is Dictionary or v is Array:
			dst[k] = v.duplicate(true)
		else:
			dst[k] = v


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
	if v is float:
		var r := snappedf(v, 0.001)
		return int(r) if is_equal_approx(r, roundf(r)) else r
	if v is Color:
		return [snappedf(v.r, 0.001), snappedf(v.g, 0.001), snappedf(v.b, 0.001)]
	return v
