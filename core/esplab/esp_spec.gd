class_name EspSpec
extends RefCounted

## The board designer's record (key `esp_spec` on a placed prop, and the
## library entry):
##
##   {"version": 1, "name": "Garden probe", "board": "esp32_devkit_v1",
##    "diagnostics": true,
##    "parts": [{"iid": "p1", "part": "bme280", "label": "BME280",
##               "addr": -1,          (-1 = the solver picks)
##               "update_s": -1,      (-1 = the part's default)
##               "measures": {},      (entity k -> source id, overrides the part's)
##               "filters": {},       (entity k -> extra ESPHome filters, after the part's)
##               "opts": {},          (num_leds, inverted…)
##               "ents": {}}],        (entity k -> {name, unit, dc}: the exact
##                                     entity name / unit this instance's
##                                     entity carries; a controller board made
##                                     for a TC process names its entities
##                                     after the process's own, TcProcBoard)
##    "locks": {"p1:SDA": 21},        (pins wired by hand: kept by the solver)
##    "real": {},                     (entity k -> the real board's entity_id)
##    "layout": {"p1": [x, y]}}       (where the diagram draws each part; never
##                                     part of key_of, so moving a card does
##                                     not re-solve)
##
## `name` is the ESPHome friendly_name; the node name is derived from it.

const VERSION := 1
const DEFAULT_BOARD := "esp32_devkit_v1"


static func empty(name: String = "New board") -> Dictionary:
	return {"version": VERSION, "name": name, "board": DEFAULT_BOARD, "diagnostics": true,
		"parts": [], "locks": {}, "real": {}}


## Fill defaults, drop unknown parts, make instance ids and labels unique.
## Never throws.
static func resolve(spec: Dictionary) -> Dictionary:
	var out := empty(str(spec.get("name", "New board")).strip_edges())
	if str(out["name"]) == "":
		out["name"] = "New board"
	var b := str(spec.get("board", DEFAULT_BOARD))
	out["board"] = b if EspBoards.BOARDS.has(b) else DEFAULT_BOARD
	out["diagnostics"] = bool(spec.get("diagnostics", true))
	var seen_iid := {}
	var label_count := {}
	var n := 0
	for raw in spec.get("parts", []):
		if not (raw is Dictionary):
			continue
		var pid := str((raw as Dictionary).get("part", ""))
		var part := EspParts.get_part(pid)
		if part.is_empty():
			continue
		n += 1
		var iid := str(raw.get("iid", ""))
		if iid == "" or seen_iid.has(iid) or not _valid_id(iid):
			iid = "p%d" % n
			while seen_iid.has(iid):
				n += 1
				iid = "p%d" % n
		seen_iid[iid] = true
		var label := str(raw.get("label", "")).strip_edges()
		if label == "":
			label = EspParts.short_label(part)
		var lc := int(label_count.get(label, 0)) + 1
		label_count[label] = lc
		if lc > 1:
			label = "%s %d" % [label, lc]
		var inst := {
			"iid": iid, "part": pid, "label": label,
			"addr": int(raw.get("addr", -1)),
			"update_s": float(raw.get("update_s", -1.0)),
			"measures": (raw.get("measures", {}) as Dictionary).duplicate(true) if raw.get("measures", {}) is Dictionary else {},
			"filters": (raw.get("filters", {}) as Dictionary).duplicate(true) if raw.get("filters", {}) is Dictionary else {},
			"opts": (raw.get("opts", {}) as Dictionary).duplicate(true) if raw.get("opts", {}) is Dictionary else {},
		}
		if raw.has("ents") and raw["ents"] is Dictionary and not (raw["ents"] as Dictionary).is_empty():
			inst["ents"] = (raw["ents"] as Dictionary).duplicate(true)
		(out["parts"] as Array).append(inst)
	var locks: Dictionary = spec.get("locks", {}) if spec.get("locks", {}) is Dictionary else {}
	for k in locks:
		if str(k).find(":") > 0 and seen_iid.has(str(k).split(":")[0]):
			out["locks"][str(k)] = int(locks[k])
	var real: Dictionary = spec.get("real", {}) if spec.get("real", {}) is Dictionary else {}
	out["real"] = real.duplicate(true)
	var lay: Dictionary = spec.get("layout", {}) if spec.get("layout", {}) is Dictionary else {}
	var keep := {}
	for k in lay:
		var v: Variant = lay[k]
		if seen_iid.has(str(k)) and v is Array and (v as Array).size() == 2:
			keep[str(k)] = [float(v[0]), float(v[1])]
	if not keep.is_empty():
		out["layout"] = keep
	return out


## A C-identifier-safe instance id (it becomes part of ESPHome ids).
static func _valid_id(s: String) -> bool:
	if s == "" or not (s[0] >= "a" and s[0] <= "z"):
		return false
	for ch in s:
		if not ((ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "_"):
			return false
	return true


static func next_iid(spec: Dictionary) -> String:
	var used := {}
	for p in spec.get("parts", []):
		used[str(p.get("iid", ""))] = true
	var n := 1
	while used.has("p%d" % n):
		n += 1
	return "p%d" % n


## Add a part instance (returns the new spec, unresolved copy).
static func with_part(spec: Dictionary, part_id: String, extra: Dictionary = {}) -> Dictionary:
	var s := spec.duplicate(true)
	var inst := {"iid": next_iid(s), "part": part_id}
	inst.merge(extra, true)
	(s["parts"] as Array).append(inst)
	return s


## Remove a part instance and every lock on it.
static func without_part(spec: Dictionary, iid: String) -> Dictionary:
	var s := spec.duplicate(true)
	var keep: Array = []
	for p in s.get("parts", []):
		if str(p.get("iid", "")) != iid:
			keep.append(p)
	s["parts"] = keep
	var locks: Dictionary = s.get("locks", {})
	for k in locks.keys():
		if str(k).begins_with(iid + ":"):
			locks.erase(k)
	if s.has("layout") and s["layout"] is Dictionary:
		(s["layout"] as Dictionary).erase(iid)
	return s


## JSON of rounded values, integral floats as ints, sorted keys: a design
## saved and loaded hits its own cache.
static func key_of(spec: Dictionary) -> String:
	if spec.has("layout"):
		var g := spec.duplicate()
		g.erase("layout")
		return JSON.stringify(_round(g))
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
		var f := snappedf(float(v), 0.0001)
		if is_equal_approx(f, roundf(f)):
			return int(roundf(f))
		return f
	return v
