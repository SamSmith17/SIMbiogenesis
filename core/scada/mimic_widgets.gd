class_name MimicWidgets
extends RefCounted

## Dashboard widgets and screens for the Process lens (pure). SCADA plan,
## Phase 8. A WIDGET is a small thing on the picture bound to a tag: a dial,
## a bar, a number, a trend, a lamp, a push button, a slider, a line of text,
## or a button that goes to another screen. A SCREEN is one page of a scope:
## the first is the process picture with widgets over it; the others can be
## the picture again or a blank board of widgets.
##
## Per scope: {screens: [{id, name, picture: bool, widgets: [widget]}]}
## A widget = {id, kind, x, y, w, h, tag, label, lo, hi, text, screen}
##   x, y   the middle, in picture units (the mimic doc's own)
##   lo, hi the scale of a dial / bar / slider / trend (hi <= lo = from the tag)
##   text   a text widget's words; a nav widget's target screen is `screen`

const KINDS := ["gauge", "bar", "value", "trend", "lamp", "button", "slider", "text", "nav"]
const KIND_WORDS := {"gauge": "Dial gauge", "bar": "Bar", "value": "Number", "trend": "Trend", "lamp": "Lamp",
	"button": "Push button", "slider": "Slider", "text": "Text", "nav": "Go to a screen"}
const KIND_TIPS := {
	"gauge": "A needle over a scale: one reading at a glance.",
	"bar": "A bar that fills with a reading (a level, a percentage).",
	"value": "The reading as a number.",
	"trend": "The reading over the last hours.",
	"lamp": "Lit while a switch or a state is on.",
	"button": "Switches something on and off with one press.",
	"slider": "Sets a number: a valve's opening, a setpoint.",
	"text": "A title or a note on the picture.",
	"nav": "A button that opens another screen.",
}
## Default size, picture units.
const SIZES := {"gauge": Vector2(150, 120), "bar": Vector2(60, 150), "value": Vector2(150, 56), "trend": Vector2(240, 110),
	"lamp": Vector2(130, 44), "button": Vector2(150, 54), "slider": Vector2(220, 56), "text": Vector2(200, 36), "nav": Vector2(150, 44)}
const NEEDS_TAG := ["gauge", "bar", "value", "trend", "lamp", "button", "slider"]
## These write: their tag must be one the game can command.
const WRITES := ["button", "slider"]
const MAX_WIDGETS := 120
const MAX_SCREENS := 12
const ID_PREFIX := "w:"
const SIZE_MIN := 0.5
const SIZE_MAX := 6.0


static func default_data() -> Dictionary:
	return {"screens": [{"id": "s1", "name": "Overview", "picture": true, "widgets": []}]}


static func make(id: String, kind: String, at: Vector2) -> Dictionary:
	var k := kind if kind in KINDS else "value"
	var sz: Vector2 = SIZES[k]
	return {"id": id, "kind": k, "x": at.x, "y": at.y, "w": sz.x, "h": sz.y, "tag": "", "label": "",
		"lo": 0.0, "hi": 0.0, "text": "Text" if k == "text" else "", "screen": ""}


static func normalized(w: Dictionary) -> Dictionary:
	var k := str(w.get("kind", "value"))
	if not k in KINDS:
		k = "value"
	var base: Vector2 = SIZES[k]
	return {"id": str(w.get("id", "")), "kind": k, "x": float(w.get("x", 0.0)), "y": float(w.get("y", 0.0)),
		"w": clampf(float(w.get("w", base.x)), base.x * SIZE_MIN, base.x * SIZE_MAX),
		"h": clampf(float(w.get("h", base.y)), base.y * SIZE_MIN, base.y * SIZE_MAX),
		"tag": str(w.get("tag", "")), "label": str(w.get("label", "")).substr(0, 60),
		"lo": float(w.get("lo", 0.0)), "hi": float(w.get("hi", 0.0)),
		"text": str(w.get("text", "")).substr(0, 120), "screen": str(w.get("screen", ""))}


## A scope's screens, cleaned: at least one screen, unique ids, capped.
static func clean(data: Variant) -> Dictionary:
	var out := {"screens": []}
	var seen_s := {}
	var seen_w := {}
	var total := 0
	if data is Dictionary and (data as Dictionary).has("screens") and (data as Dictionary)["screens"] is Array:
		for s in (data as Dictionary)["screens"]:
			if not (s is Dictionary) or (out["screens"] as Array).size() >= MAX_SCREENS:
				continue
			var sid := str(s.get("id", ""))
			if sid.is_empty() or seen_s.has(sid):
				continue
			seen_s[sid] = true
			var ws: Array = []
			if s.get("widgets", []) is Array:
				for w in s["widgets"]:
					if not (w is Dictionary) or total >= MAX_WIDGETS:
						continue
					var n := normalized(w)
					if str(n["id"]).is_empty() or seen_w.has(n["id"]):
						continue
					seen_w[n["id"]] = true
					ws.append(n)
					total += 1
			var nm := str(s.get("name", "")).strip_edges().substr(0, 40)
			(out["screens"] as Array).append({"id": sid, "name": nm if not nm.is_empty() else "Screen", "picture": bool(s.get("picture", false)), "widgets": ws})
	if (out["screens"] as Array).is_empty():
		return default_data()
	return out


static func is_default(data: Dictionary) -> bool:
	var sc: Array = data.get("screens", [])
	return sc.size() == 1 and (sc[0]["widgets"] as Array).is_empty() and bool(sc[0]["picture"]) and str(sc[0]["name"]) == "Overview"


static func screen(data: Dictionary, sid: String) -> Dictionary:
	for s in data.get("screens", []):
		if str(s["id"]) == sid:
			return s
	var sc: Array = data.get("screens", [])
	return sc[0] if not sc.is_empty() else {}


static func new_screen_id(data: Dictionary) -> String:
	var used := {}
	for s in data.get("screens", []):
		used[str(s["id"])] = true
	var n := 1
	while used.has("s%d" % n):
		n += 1
	return "s%d" % n


static func new_widget_id(data: Dictionary) -> String:
	var used := {}
	for s in data.get("screens", []):
		for w in s["widgets"]:
			used[str(w["id"])] = true
	var n := 1
	while used.has("w%d" % n):
		n += 1
	return "w%d" % n


static func find(data: Dictionary, wid: String) -> Dictionary:
	for s in data.get("screens", []):
		for w in s["widgets"]:
			if str(w["id"]) == wid:
				return w
	return {}


static func remove(data: Dictionary, wid: String) -> void:
	for s in data.get("screens", []):
		var keep: Array = []
		for w in s["widgets"]:
			if str(w["id"]) != wid:
				keep.append(w)
		s["widgets"] = keep


## Remove a screen (never the last); nav widgets that pointed at it lose
## their target.
static func remove_screen(data: Dictionary, sid: String) -> bool:
	var sc: Array = data.get("screens", [])
	if sc.size() <= 1:
		return false
	var keep: Array = []
	for s in sc:
		if str(s["id"]) != sid:
			keep.append(s)
	if keep.size() == sc.size():
		return false
	data["screens"] = keep
	for s2 in keep:
		for w in s2["widgets"]:
			if str(w["screen"]) == sid:
				w["screen"] = ""
	return true


## The widget as a mimic doc element.
static func element(w: Dictionary) -> Dictionary:
	return {"id": ID_PREFIX + str(w["id"]), "kind": "widget", "wkind": str(w["kind"]), "cv": -1, "link": -1, "bnd": -1,
		"part": "", "pos": Vector2(float(w["x"]), float(w["y"])), "size": Vector2(float(w["w"]), float(w["h"])),
		"depth": -1.0e6, "label": str(w["label"])}


static func is_widget_id(id: String) -> bool:
	return id.begins_with(ID_PREFIX)


static func widget_id(element_id: String) -> String:
	return element_id.substr(ID_PREFIX.length())


## The scale a widget draws on: its own lo / hi, else from the tag's unit
## (% → 0..100, an on / off tag → 0..1), else a round span about the value.
static func scale_of(w: Dictionary, unit: String, binary: bool, value: float) -> Vector2:
	if float(w["hi"]) > float(w["lo"]):
		return Vector2(float(w["lo"]), float(w["hi"]))
	if binary:
		return Vector2(0.0, 1.0)
	if unit == "%":
		return Vector2(0.0, 100.0)
	if is_nan(value) or absf(value) < 1e-9:
		return Vector2(0.0, 100.0)
	var top := pow(10.0, ceil(log(absf(value) * 1.2) / log(10.0)))
	if absf(value) * 1.2 <= top * 0.5:
		top *= 0.5
	return Vector2(minf(0.0, -top if value < 0.0 else 0.0), top)


## What a widget shows now. `info(tag)` → {label, unit, binary, writable,
## available}; `read(tag)` → float (NAN = no reading); `trend(tag)` →
## PackedFloat32Array; `screen_name(id)` → String.
static func state(w: Dictionary, read: Callable, info: Callable, trend: Callable, screen_name: Callable) -> Dictionary:
	var kind := str(w["kind"])
	var tag := str(w["tag"])
	var out := {"kind": kind, "label": str(w["label"]), "value": NAN, "text": "", "unit": "", "on": false,
		"avail": false, "lo": 0.0, "hi": 100.0, "frac": 0.0, "bound": not tag.is_empty(), "writable": false}
	if kind == "text":
		out["text"] = str(w["text"])
		out["avail"] = true
		return out
	if kind == "nav":
		var nm := str(screen_name.call(str(w["screen"])))
		out["text"] = (str(w["label"]) if not str(w["label"]).is_empty() else nm) if not nm.is_empty() else "Pick a screen"
		out["avail"] = not nm.is_empty()
		return out
	if tag.is_empty():
		out["text"] = "Pick a tag"
		return out
	var ti: Dictionary = info.call(tag)
	var v := float(read.call(tag))
	var binary := bool(ti.get("binary", false))
	var unit := str(ti.get("unit", ""))
	if str(out["label"]).is_empty():
		out["label"] = str(ti.get("label", tag))
	out["unit"] = unit
	out["writable"] = bool(ti.get("writable", false))
	out["avail"] = not is_nan(v) and bool(ti.get("available", true))
	out["value"] = v
	out["on"] = not is_nan(v) and v > 0.5
	var sc := scale_of(w, unit, binary, v)
	if not (float(w["hi"]) > float(w["lo"])) and ti.has("hi") and float(ti["hi"]) > float(ti.get("lo", 0.0)):
		sc = Vector2(float(ti.get("lo", 0.0)), float(ti["hi"]))
	if kind == "trend":
		var tr: PackedFloat32Array = trend.call(tag)
		out["trend"] = tr
		if not (float(w["hi"]) > float(w["lo"])) and not binary:
			var mn := INF
			var mx := -INF
			for x in tr:
				if not is_nan(x):
					mn = minf(mn, x)
					mx = maxf(mx, x)
			if mx >= mn:
				var pad := maxf((mx - mn) * 0.12, maxf(absf(mx), 1.0) * 0.02)
				sc = Vector2(mn - pad, mx + pad)
	out["lo"] = sc.x
	out["hi"] = sc.y
	out["frac"] = clampf((v - sc.x) / maxf(sc.y - sc.x, 1e-9), 0.0, 1.0) if not is_nan(v) else 0.0
	if is_nan(v):
		out["text"] = "no reading"
	elif binary:
		out["text"] = "On" if v > 0.5 else "Off"
	else:
		out["text"] = "%s%s" % [fmt(v), (" " + unit) if not unit.is_empty() else ""]
	return out


static func fmt(v: float) -> String:
	if is_nan(v):
		return "?"
	var a := absf(v)
	if a >= 1000.0:
		return str(int(round(v)))
	if a >= 100.0:
		return "%.0f" % v
	if a >= 10.0:
		return "%.1f" % v
	return "%.2f" % v


## What pressing a widget does: {} (nothing), {tag, value} (a command) or
## {screen} (go there). `frac` = where along a slider it was pressed (0..1).
static func press(w: Dictionary, st: Dictionary, frac: float) -> Dictionary:
	match str(w["kind"]):
		"button":
			if str(w["tag"]).is_empty():
				return {}
			return {"tag": str(w["tag"]), "value": 0.0 if bool(st.get("on", false)) else 1.0}
		"slider":
			if str(w["tag"]).is_empty():
				return {}
			var lo := float(st.get("lo", 0.0))
			var hi := float(st.get("hi", 100.0))
			var v := lo + (hi - lo) * clampf(frac, 0.0, 1.0)
			# Whole steps on a wide scale, tenths on a narrow one.
			return {"tag": str(w["tag"]), "value": snappedf(v, 1.0 if hi - lo >= 20.0 else 0.1)}
		"nav":
			return {"screen": str(w["screen"])} if not str(w["screen"]).is_empty() else {}
	return {}
