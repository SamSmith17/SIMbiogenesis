class_name BuildingPresets
extends RefCounted

## Six houses. Each spec solves with no errors. Cottage, ranch and the
## two-storey ship window glow on Auto and a sconce by the front door.
## Applying one to an OSM way keeps that footprint; fit_elements places
## the openings. Applying one with no building uses this footprint.


static func builtins() -> Array:
	return [
		{"id": "cabin", "name": "Cabin", "spec": cabin()},
		{"id": "cottage", "name": "Cottage", "spec": cottage()},
		{"id": "ranch", "name": "Ranch", "spec": ranch()},
		{"id": "two_storey", "name": "Two storey", "spec": two_storey()},
		{"id": "workshop", "name": "Workshop", "spec": workshop()},
		{"id": "trailer", "name": "Trailer", "spec": trailer()},
	]


static func by_id(id: String) -> Dictionary:
	match id:
		"cabin":
			return cabin()
		"cottage":
			return cottage()
		"ranch":
			return ranch()
		"two_storey":
			return two_storey()
		"workshop":
			return workshop()
		"trailer":
			return trailer()
		_:
			return cottage()


static func cabin() -> Dictionary:
	return _copy({
		"width_m": 5.0, "depth_m": 4.0, "height_m": 3.2,
		"roof_shape": "gabled", "roof_pitch_deg": 40.0,
		"foundation": "piers", "overhang_m": 0.3, "corner_trim": true,
		"light_windows": false, "wing": "none",
		"wall_color": [0.62, 0.48, 0.36], "roof_color": [0.32, 0.28, 0.26],
		"elements": [
			_el("door", {"edge": 0, "u_m": 2.5, "w_m": 0.9, "h_m": 2.05}),
			_el("window", {"edge": 0, "u_m": 1.15, "style": "picture"}),
			_el("window", {"edge": 1, "u_m": 2.0}),
		],
	})


static func cottage() -> Dictionary:
	return _copy({
		"width_m": 8.0, "depth_m": 6.0, "height_m": 4.2,
		"roof_shape": "gabled", "roof_pitch_deg": 35.0,
		"foundation": "stem", "overhang_m": 0.45, "corner_trim": true,
		"light_windows": true, "wing": "none",
		"wall_color": [0.86, 0.84, 0.78], "roof_color": [0.42, 0.22, 0.18],
		"elements": [
			_el("door", {"edge": 0, "u_m": 4.0, "w_m": 0.9, "h_m": 2.1}),
			_el("window", {"edge": 0, "u_m": 1.6, "lit": "auto"}),
			_el("window", {"edge": 0, "u_m": 6.4, "lit": "auto"}),
			_el("window", {"edge": 1, "u_m": 3.0, "lit": "auto"}),
			_el("window", {"edge": 3, "u_m": 3.0, "lit": "auto"}),
			_el("porch", {"edge": 0, "u_m": 4.0, "depth_m": 1.8, "w_m": 6.0}),
			_el("steps", {"edge": 0, "u_m": 4.0, "width_m": 1.1, "run_m": 1.2}),
			_el("light", {"edge": 0, "u_m": 4.7, "v_m": 1.8, "style": "sconce", "lit": "auto"}),
		],
	})


static func ranch() -> Dictionary:
	return _copy({
		"width_m": 14.0, "depth_m": 7.0, "height_m": 3.6,
		"roof_shape": "hipped", "roof_pitch_deg": 22.0,
		"foundation": "slab", "overhang_m": 0.6, "corner_trim": true,
		"light_windows": true, "wing": "none",
		"wall_color": [0.78, 0.74, 0.66], "roof_color": [0.45, 0.38, 0.32],
		"elements": [
			_el("door", {"edge": 0, "u_m": 5.0}),
			_el("window", {"edge": 0, "u_m": 2.2, "style": "picture", "w_m": 1.6, "lit": "auto"}),
			_el("window", {"edge": 0, "u_m": 8.2, "lit": "auto"}),
			_el("window", {"edge": 0, "u_m": 11.2, "lit": "auto"}),
			_el("door", {"edge": 1, "u_m": 3.5, "style": "garage", "w_m": 2.4, "h_m": 2.2}),
			_el("porch", {"edge": 0, "u_m": 5.0, "depth_m": 1.6, "w_m": 4.0}),
			_el("steps", {"edge": 0, "u_m": 5.0}),
			_el("light", {"edge": 0, "u_m": 5.8, "v_m": 1.8, "style": "sconce", "lit": "auto"}),
		],
	})


static func two_storey() -> Dictionary:
	return _copy({
		"width_m": 8.0, "depth_m": 7.0, "height_m": 5.6,
		"roof_shape": "gabled", "roof_pitch_deg": 38.0,
		"foundation": "stem", "overhang_m": 0.4, "corner_trim": true,
		"light_windows": true, "wing": "none",
		"wall_color": [0.72, 0.58, 0.48], "roof_color": [0.28, 0.30, 0.32],
		"elements": [
			_el("door", {"edge": 0, "u_m": 4.0}),
			_el("window", {"edge": 0, "u_m": 1.6, "v_m": 0.9, "lit": "auto"}),
			_el("window", {"edge": 0, "u_m": 6.4, "v_m": 0.9, "lit": "auto"}),
			_el("window", {"edge": 0, "u_m": 1.6, "v_m": 3.6, "lit": "auto"}),
			_el("window", {"edge": 0, "u_m": 4.0, "v_m": 3.6, "lit": "auto"}),
			_el("window", {"edge": 0, "u_m": 6.4, "v_m": 3.6, "lit": "auto"}),
			_el("porch", {"edge": 0, "u_m": 4.0, "depth_m": 1.5, "w_m": 3.2}),
			_el("steps", {"edge": 0, "u_m": 4.0}),
			_el("light", {"edge": 0, "u_m": 4.8, "v_m": 1.8, "style": "sconce", "lit": "auto"}),
		],
	})


static func workshop() -> Dictionary:
	return _copy({
		"width_m": 10.0, "depth_m": 6.0, "height_m": 4.0,
		"roof_shape": "skillion", "roof_pitch_deg": 12.0, "skillion_flip": false,
		"foundation": "slab", "overhang_m": 0.35, "corner_trim": true,
		"light_windows": false, "wall_mode": 2, "wing": "none",
		"wall_color": [0.55, 0.58, 0.60], "roof_color": [0.40, 0.42, 0.44],
		"elements": [
			_el("door", {"edge": 0, "u_m": 2.2, "style": "single"}),
			_el("door", {"edge": 0, "u_m": 6.5, "style": "garage", "w_m": 3.0, "h_m": 2.4}),
			_el("window", {"edge": 1, "u_m": 3.0, "style": "picture", "w_m": 1.8, "h_m": 1.0, "v_m": 1.4}),
		],
	})


static func trailer() -> Dictionary:
	return _copy({
		"width_m": 12.0, "depth_m": 3.5, "height_m": 2.6,
		"roof_shape": "flat", "roof_pitch_deg": 5.0,
		"foundation": "piers", "overhang_m": 0.15, "corner_trim": false,
		"light_windows": false, "wall_mode": 1, "wing": "none",
		"wall_color": [0.82, 0.80, 0.74], "roof_color": [0.70, 0.70, 0.68],
		"elements": [
			_el("door", {"edge": 0, "u_m": 3.0}),
			_el("window", {"edge": 0, "u_m": 6.0, "style": "picture", "w_m": 1.2, "h_m": 0.9, "v_m": 1.0}),
			_el("window", {"edge": 0, "u_m": 9.2, "style": "picture", "w_m": 1.2, "h_m": 0.9, "v_m": 1.0}),
			_el("steps", {"edge": 0, "u_m": 3.0, "width_m": 0.9, "run_m": 0.8}),
		],
	})


static func _el(typ: String, extra: Dictionary) -> Dictionary:
	var stamp := int(extra.get("edge", 0)) * 10000 \
		+ int(float(extra.get("u_m", 0.0)) * 100.0) \
		+ int(float(extra.get("v_m", 0.0)) * 10.0)
	var e := {"id": "el_%s_%d" % [typ, stamp]}
	e["type"] = typ
	for k in extra.keys():
		e[k] = extra[k]
	return e


static func _copy(spec: Dictionary) -> Dictionary:
	return spec.duplicate(true)
