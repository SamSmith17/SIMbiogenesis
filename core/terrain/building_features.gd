class_name BuildingFeatures
extends RefCounted

## One building is a resolved spec: massing keys plus an element list.
## OSM style JSON and a placed prop's building_spec are the same shape.
## Legacy door/window records (kind, edge, u_m, v_m, w_m, h_m) still resolve:
## missing keys are filled, numbers already on the record are left alone.

const MODEL_ID := "parametric_building"
const LIBRARY_PATH := "user://building_library.json"
const GAP_M := 0.5

const TYPES := ["door", "window", "porch", "steps", "column", "light"]

const DOOR_STYLES := ["single", "double", "sliding", "garage"]
const WINDOW_STYLES := ["double_hung", "picture", "pair"]
const LIGHT_STYLES := ["sconce", "hanging", "down"]
const LIT_MODES := ["auto", "on", "off"]
const FOUNDATIONS := ["slab", "stem", "piers"]
const WINGS := ["none", "l", "t"]

const ELEMENT_DEFAULTS := {
	"door": {
		"type": "door", "style": "single", "edge": 0, "u_m": 0.0, "v_m": 0.0,
		"w_m": 0.9, "h_m": 2.1,
	},
	"window": {
		"type": "window", "style": "double_hung", "edge": 0, "u_m": 0.0, "v_m": 0.9,
		"w_m": 0.9, "h_m": 1.4, "lit": "auto",
	},
	"porch": {
		"type": "porch", "edge": 0, "u_m": 0.0, "depth_m": 2.0, "w_m": 0.0,
		"roof": true, "rail": true, "post_spacing": 2.4,
	},
	"steps": {
		"type": "steps", "edge": 0, "u_m": 0.0, "width_m": 1.0, "run_m": 1.2,
	},
	"column": {
		"type": "column", "edge": 0, "u_m": 0.0, "h_m": 2.4,
	},
	"light": {
		"type": "light", "style": "sconce", "edge": 0, "u_m": 0.0, "v_m": 1.8,
		"energy": 1.0, "lit": "auto",
		"color": Color(1.0, 0.72, 0.42),
	},
}

const ELEMENT_FIELDS := {
	"door": [
		{"key": "style", "label": "Style", "kind": "option", "options": DOOR_STYLES},
		{"key": "w_m", "label": "Width", "kind": "float", "min": 0.6, "max": 5.0, "step": 0.05, "unit": "m"},
		{"key": "h_m", "label": "Height", "kind": "float", "min": 1.8, "max": 3.2, "step": 0.05, "unit": "m"},
	],
	"window": [
		{"key": "style", "label": "Style", "kind": "option", "options": WINDOW_STYLES},
		{"key": "w_m", "label": "Width", "kind": "float", "min": 0.4, "max": 4.0, "step": 0.05, "unit": "m"},
		{"key": "h_m", "label": "Height", "kind": "float", "min": 0.4, "max": 3.0, "step": 0.05, "unit": "m"},
		{"key": "v_m", "label": "Sill", "kind": "float", "min": 0.0, "max": 6.0, "step": 0.05, "unit": "m"},
		{"key": "lit", "label": "Lit", "kind": "option", "options": LIT_MODES,
			"tip": "Auto follows dusk. On stays lit. Off stays dark."},
	],
	"porch": [
		{"key": "depth_m", "label": "Depth", "kind": "float", "min": 0.9, "max": 4.0, "step": 0.1, "unit": "m"},
		{"key": "w_m", "label": "Width", "kind": "float", "min": 0.0, "max": 20.0, "step": 0.1, "unit": "m",
			"tip": "0 spans the wall, leaving a gap at each end"},
		{"key": "post_spacing", "label": "Post spacing", "kind": "float", "min": 1.2, "max": 4.0, "step": 0.1, "unit": "m"},
		{"key": "roof", "label": "Roof", "kind": "bool"},
		{"key": "rail", "label": "Railing", "kind": "bool"},
	],
	"steps": [
		{"key": "width_m", "label": "Width", "kind": "float", "min": 0.7, "max": 3.0, "step": 0.05, "unit": "m"},
		{"key": "run_m", "label": "Run", "kind": "float", "min": 0.6, "max": 3.0, "step": 0.05, "unit": "m"},
	],
	"column": [
		{"key": "h_m", "label": "Height", "kind": "float", "min": 1.8, "max": 6.0, "step": 0.05, "unit": "m"},
	],
	"light": [
		{"key": "style", "label": "Fixture", "kind": "option", "options": LIGHT_STYLES},
		{"key": "v_m", "label": "Height", "kind": "float", "min": 0.4, "max": 4.0, "step": 0.05, "unit": "m"},
		{"key": "energy", "label": "Energy", "kind": "float", "min": 0.2, "max": 4.0, "step": 0.1},
		{"key": "lit", "label": "Lit", "kind": "option", "options": LIT_MODES},
		{"key": "color", "label": "Colour", "kind": "color"},
	],
}

const TOOL_PRESETS := [
	{"id": "door", "type": "door", "label": "Door", "tip": "A door on the wall under the cursor",
		"template": {"type": "door", "style": "single"}},
	{"id": "window", "type": "window", "label": "Window", "tip": "A window on the wall under the cursor",
		"template": {"type": "window", "style": "double_hung"}},
	{"id": "porch", "type": "porch", "label": "Porch", "tip": "A deck along the face under the cursor",
		"template": {"type": "porch"}},
	{"id": "steps", "type": "steps", "label": "Steps", "tip": "A straight run in front of this face",
		"template": {"type": "steps"}},
	{"id": "column", "type": "column", "label": "Column", "tip": "A post on this face",
		"template": {"type": "column"}},
	{"id": "light", "type": "light", "label": "Light", "tip": "A porch light on this wall",
		"template": {"type": "light", "style": "sconce"}},
]


static func field_visible(f: Dictionary, el: Dictionary) -> bool:
	var cond: Variant = f.get("show_if")
	if not (cond is Dictionary):
		return true
	for k in (cond as Dictionary).keys():
		var want: Variant = cond[k]
		var key := str(k)
		if key == "_min":
			for mk in (want as Dictionary).keys():
				if float(el.get(mk, 0.0)) < float(want[mk]):
					return false
		elif key == "_solar":
			continue
		elif want is Array and not (want as Array).has(el.get(k)):
			return false
	return true


static func resolve_element(raw: Dictionary) -> Dictionary:
	var e := raw.duplicate(true)
	var typ := str(e.get("type", ""))
	if typ == "" and e.has("kind"):
		typ = str(e["kind"])
		if TYPES.has(typ):
			e["type"] = typ
	if not TYPES.has(typ):
		return e
	var defaults: Dictionary = ELEMENT_DEFAULTS[typ]
	for k in defaults.keys():
		if not e.has(k):
			e[k] = defaults[k]
	if typ == "door" or typ == "window":
		if not e.has("kind"):
			e["kind"] = typ
	return e


static func resolve_list(raw: Variant) -> Array:
	var out: Array = []
	if not raw is Array:
		return out
	var i := 0
	for item in raw:
		if not item is Dictionary:
			continue
		var src: Dictionary = item
		var e := resolve_element(src)
		if not src.has("id") or str(src.get("id", "")) == "":
			e["id"] = "el_%d" % i
		out.append(e)
		i += 1
	return out


static func fresh_id(elements: Array) -> String:
	var n := 0
	for e in elements:
		if not e is Dictionary:
			continue
		var id := str((e as Dictionary).get("id", ""))
		if id.begins_with("el_"):
			n = maxi(n, int(id.substr(3)) + 1)
	return "el_%d" % n


static func tool_template(tool_id: String) -> Dictionary:
	for t in TOOL_PRESETS:
		if str(t.get("id", "")) != tool_id:
			continue
		var e: Dictionary = (t["template"] as Dictionary).duplicate(true)
		e["type"] = str(t.get("type", tool_id))
		return resolve_element(e)
	return {}


static func element_type(e: Dictionary) -> String:
	var typ := str(e.get("type", ""))
	if typ == "":
		typ = str(e.get("kind", ""))
	return typ


static func overlaps(elements: Array, edge: int, u: float, w: float, skip_id: String = "") -> bool:
	var half := w * 0.5
	for item in elements:
		if not item is Dictionary:
			continue
		var e: Dictionary = item
		var typ := element_type(e)
		if typ != "door" and typ != "window":
			continue
		if int(e.get("edge", -1)) != edge:
			continue
		if skip_id != "" and str(e.get("id", "")) == skip_id:
			continue
		var hw := float(e.get("w_m", 0.9)) * 0.5
		if absf(float(e.get("u_m", 0.0)) - u) < hw + half + 0.05:
			return true
	return false


static func clamp_u(u: float, w: float, edge_len: float) -> float:
	var half := w * 0.5
	var lo := half + GAP_M
	var hi := edge_len - half - GAP_M
	if hi < lo:
		return edge_len * 0.5
	return clampf(u, lo, hi)


static func holes_on_edge(elements: Array, edge: int, edge_len: float, base_y: float) -> Array:
	var holes: Array = []
	for item in elements:
		if not item is Dictionary:
			continue
		var e: Dictionary = item
		var typ := element_type(e)
		if typ != "door" and typ != "window":
			continue
		if int(e.get("edge", -1)) != edge:
			continue
		var w := float(e.get("w_m", 0.9))
		var h := float(e.get("h_m", 1.4))
		var u := float(e.get("u_m", edge_len * 0.5))
		var v := 0.0 if typ == "door" else float(e.get("v_m", 0.9))
		holes.append({
			"u0": u - w * 0.5, "u1": u + w * 0.5,
			"y0": base_y + v, "y1": base_y + v + h,
		})
	return holes


## Auto follows dusk when the building wants its windows lit.
## On and off ignore the clock. A fixture passes windows_on true.
static func light_on(mode: String, windows_on: bool, is_night: bool) -> bool:
	if mode == "off":
		return false
	if mode == "on":
		return true
	return windows_on and is_night


static func footprint_of(spec: Dictionary) -> PackedVector2Array:
	var w := maxf(float(spec.get("width_m", 8.0)), 2.0)
	var d := maxf(float(spec.get("depth_m", 6.0)), 2.0)
	var wing := str(spec.get("wing", "none"))
	var ww := maxf(float(spec.get("wing_w_m", 4.0)), 1.0)
	var wd := maxf(float(spec.get("wing_d_m", 4.0)), 1.0)
	if wing == "l":
		ww = minf(ww, w)
		wd = minf(wd, d)
		return _center_poly(PackedVector2Array([
			Vector2(0, 0), Vector2(w, 0), Vector2(w, d - wd),
			Vector2(w + ww, d - wd), Vector2(w + ww, d), Vector2(0, d),
		]))
	if wing == "t":
		ww = minf(ww, w)
		return _center_poly(PackedVector2Array([
			Vector2(0, 0), Vector2(w, 0), Vector2(w, d),
			Vector2((w + ww) * 0.5, d),
			Vector2((w + ww) * 0.5, d + wd),
			Vector2((w - ww) * 0.5, d + wd),
			Vector2((w - ww) * 0.5, d), Vector2(0, d),
		]))
	return PackedVector2Array([
		Vector2(-w * 0.5, -d * 0.5), Vector2(w * 0.5, -d * 0.5),
		Vector2(w * 0.5, d * 0.5), Vector2(-w * 0.5, d * 0.5),
	])


static func record_for(spec: Dictionary) -> Dictionary:
	var h := float(spec.get("height_m", 4.0))
	return {
		"points": footprint_of(spec),
		"tags": {"building": "yes"},
		"height_m": h,
	}


## Scale openings onto another footprint. Depth of a porch stays put.
static func fit_elements(spec: Dictionary, dest: PackedVector2Array) -> Array:
	var src := footprint_of(spec)
	var out: Array = []
	var elems: Array = spec.get("elements", [])
	var dn := dest.size()
	var sn := src.size()
	for item in elems:
		if not item is Dictionary:
			continue
		var c: Dictionary = (item as Dictionary).duplicate(true)
		var ei := int(c.get("edge", 0))
		if ei < 0 or ei >= sn or ei >= dn:
			out.append(c)
			continue
		var sl := src[ei].distance_to(src[(ei + 1) % sn])
		var dl := dest[ei].distance_to(dest[(ei + 1) % dn])
		var scale := dl / maxf(sl, 0.01)
		c["edge"] = ei
		if c.has("u_m"):
			c["u_m"] = float(c["u_m"]) * scale
		if c.has("w_m"):
			c["w_m"] = float(c["w_m"]) * scale
		if element_type(c) == "steps" and c.has("width_m"):
			c["width_m"] = float(c["width_m"]) * scale
		out.append(c)
	return out


static func public_style(style: Dictionary) -> Dictionary:
	var out := {}
	for k in style.keys():
		var key := str(k)
		if key.begins_with("_") or key == "selected_element":
			continue
		out[key] = style[k]
	return out.duplicate(true)


static func load_library() -> Dictionary:
	if not FileAccess.file_exists(LIBRARY_PATH):
		return {"designs": [], "elements": []}
	var f := FileAccess.open(LIBRARY_PATH, FileAccess.READ)
	if f == null:
		return {"designs": [], "elements": []}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		return parsed
	return {"designs": [], "elements": []}


static func save_design(design_name: String, spec: Dictionary) -> void:
	var lib := load_library()
	var designs: Array = lib.get("designs", [])
	designs.append({"name": design_name, "spec": public_style(spec)})
	lib["designs"] = designs
	var f := FileAccess.open(LIBRARY_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(lib))


static func _center_poly(poly: PackedVector2Array) -> PackedVector2Array:
	if poly.is_empty():
		return poly
	var c := Vector2.ZERO
	for p in poly:
		c += p
	c /= float(poly.size())
	var out := PackedVector2Array()
	for p in poly:
		out.append(p - c)
	return out
