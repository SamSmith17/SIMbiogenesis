class_name TcSpec
extends RefCounted

## The TC designer's spec (record key `tc_spec`): a list of parts, the joints
## between their ports, labels on open ports, and a few design inputs.
##
##   {"version": 1, "name": "...", "standard": "asme_bpe", "material": "ss304",
##    "design_bar": 0.0, "design_c": 0.0,
##    "parts": [{"id": "p1", "type": "elbow90", "size": "1.5", "params": {},
##               "xf": [12 floats, mm: basis x, y, z columns then origin]}],
##    "joints": [{"a": "p1:b", "b": "p2:a", "roll_deg": 0.0,
##                "gasket": "epdm", "clamp": "single_pin"}],
##    "labels": {"p3:c": {"text": "Steam in", "kind": "steam"}},
##    "binds": "Biochar Reactor"}   (a graph preset label, "" = none)
##
## Only one part per connected group carries `xf` (its root); the others
## hang off joints, so moving a root carries everything attached. Mm
## throughout. `key_of` = JSON of rounded values with integral floats as
## ints, so a design saved and loaded hits its own cache.

const VERSION := 1
const STANDARDS := ["asme_bpe"]
const MATERIALS := {"ss304": "304 stainless", "ss316": "316L stainless"}


static func empty(name: String = "New assembly") -> Dictionary:
	return {"version": VERSION, "name": name, "standard": "asme_bpe", "material": "ss304",
		"design_bar": 0.0, "design_c": 0.0, "parts": [], "joints": [], "labels": {}, "binds": ""}


## Fill defaults, drop what cannot be built: unknown types / sizes, joints
## naming a missing part or port, a port used by two joints. Never throws.
static func resolve(spec: Dictionary) -> Dictionary:
	var out := empty(str(spec.get("name", "New assembly")))
	for k in ["standard", "material"]:
		if spec.has(k):
			out[k] = str(spec[k])
	if not str(out["standard"]) in STANDARDS:
		out["standard"] = "asme_bpe"
	if not MATERIALS.has(str(out["material"])):
		out["material"] = "ss304"
	out["design_bar"] = maxf(float(spec.get("design_bar", 0.0)), 0.0)
	out["design_c"] = float(spec.get("design_c", 0.0))
	out["binds"] = str(spec.get("binds", ""))
	var ids := {}
	var parts: Array = []
	for raw in spec.get("parts", []):
		if not (raw is Dictionary):
			continue
		var pr: Dictionary = raw
		var type := str(pr.get("type", ""))
		var size := str(pr.get("size", ""))
		if not TcParts.TYPES.has(type) or not TcStandards.has_size(size):
			continue
		var id := str(pr.get("id", ""))
		if id.is_empty() or ids.has(id):
			id = new_id(ids)
		ids[id] = true
		var p := {"id": id, "type": type, "size": size,
			"params": TcParts.resolve_params(type, size, pr.get("params", {}) as Dictionary)}
		if pr.has("xf"):
			var xf: Array = pr["xf"]
			if xf.size() == 12:
				p["xf"] = xf.duplicate()
		parts.append(p)
	out["parts"] = parts
	# Every "part:port" that exists, once (a linear search per joint made a
	# 200-part resolve ~8 ms).
	var refs := {}
	for p in parts:
		var built := TcParts.build(str(p["type"]), str(p["size"]), p["params"])
		for q in built["ports"]:
			refs["%s:%s" % [p["id"], q["id"]]] = true
	var used := {}
	var joints: Array = []
	for raw in spec.get("joints", []):
		if not (raw is Dictionary):
			continue
		var j: Dictionary = raw
		var a := str(j.get("a", ""))
		var b := str(j.get("b", ""))
		if a == b or used.has(a) or used.has(b):
			continue
		if not refs.has(a) or not refs.has(b):
			continue
		if a.get_slice(":", 0) == b.get_slice(":", 0):
			continue
		used[a] = true
		used[b] = true
		joints.append({"a": a, "b": b, "roll_deg": float(j.get("roll_deg", 0.0)),
			"gasket": str(j.get("gasket", "epdm")) if TcStandards.GASKETS.has(str(j.get("gasket", "epdm"))) else "epdm",
			"clamp": str(j.get("clamp", "single_pin")) if TcStandards.CLAMPS.has(str(j.get("clamp", "single_pin"))) else "single_pin"})
	out["joints"] = joints
	var labels := {}
	var raw_l: Variant = spec.get("labels", {})
	if raw_l is Dictionary:
		for k in raw_l:
			if refs.has(str(k)) and raw_l[k] is Dictionary:
				labels[str(k)] = {"text": str(raw_l[k].get("text", "")), "kind": str(raw_l[k].get("kind", ""))}
	out["labels"] = labels
	return out


static func _port_exists(parts: Array, ref: String) -> bool:
	var pid := ref.get_slice(":", 0)
	var port := ref.get_slice(":", 1)
	for p in parts:
		if str(p["id"]) == pid:
			var built := TcParts.build(str(p["type"]), str(p["size"]), p["params"])
			for q in built["ports"]:
				if str(q["id"]) == port:
					return true
	return false


static func new_id(taken: Dictionary) -> String:
	var i := taken.size() + 1
	while taken.has("p%d" % i):
		i += 1
	return "p%d" % i


static func ids_of(spec: Dictionary) -> Dictionary:
	var out := {}
	for p in spec.get("parts", []):
		out[str(p["id"])] = true
	return out


static func part_of(spec: Dictionary, id: String) -> Dictionary:
	for p in spec.get("parts", []):
		if str(p["id"]) == id:
			return p
	return {}


static func xf_to_array(t: Transform3D) -> Array:
	var b := t.basis
	return [b.x.x, b.x.y, b.x.z, b.y.x, b.y.y, b.y.z, b.z.x, b.z.y, b.z.z, t.origin.x, t.origin.y, t.origin.z]


static func xf_from_array(a: Array) -> Transform3D:
	if a.size() != 12:
		return Transform3D.IDENTITY
	return Transform3D(Basis(Vector3(a[0], a[1], a[2]), Vector3(a[3], a[4], a[5]), Vector3(a[6], a[7], a[8])),
		Vector3(a[9], a[10], a[11]))


static func key_of(spec: Dictionary) -> String:
	return JSON.stringify(_round(spec))


static func _round(v: Variant) -> Variant:
	if v is Dictionary:
		var out := {}
		var keys: Array = (v as Dictionary).keys()
		keys.sort()
		for k in keys:
			out[str(k)] = _round(v[k])
		return out
	if v is Array:
		var a: Array = []
		for x in v:
			a.append(_round(x))
		return a
	if v is float:
		var r := snappedf(float(v), 0.001)
		return int(r) if is_equal_approx(r, roundf(r)) and absf(r) < 1e12 else r
	return v
