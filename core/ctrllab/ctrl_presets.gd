class_name CtrlPresets
extends RefCounted

## Built-in controller designs: every controller in the graph library
## (`library` = its label there, and its graph numbers are exactly the
## library's) plus the common units it was missing. Looks follow the
## reference photos (2026-11-19): Victron blue with an orange stripe, the
## SmartSolar's raised centre panel and black finned side wings, Growatt's
## white plate on a black shell with a round display, PowMR grey with an
## orange lower band, EG4 silver over black with a window onto its DIN
## breakers and the wiring bay from the 6000XP photo.
##
## Electrical numbers are from the makers' data sheets where `source` names
## one; sizes and anything marked "estimate" are read off photos.

const VICTRON := [0.16, 0.5, 0.84]
const VICTRON_LIGHT := [0.27, 0.6, 0.9]
const V_ORANGE := [0.93, 0.42, 0.12]
const WHITE := [0.93, 0.93, 0.93]
const BLACK := [0.07, 0.07, 0.075]
const NEAR_BLACK := [0.04, 0.04, 0.045]
const FIN_BLACK := [0.13, 0.13, 0.14]
const ALU := [0.74, 0.75, 0.77]
const ALU_DARK := [0.2, 0.21, 0.22]
const GROWATT_GREEN := [0.45, 0.72, 0.12]
const POWMR_GREY := [0.27, 0.29, 0.31]
const POWMR_ORANGE := [0.98, 0.45, 0.08]
const EG4_SILVER := [0.64, 0.65, 0.67]
const LCD_BLUE := [0.18, 0.36, 0.7]
const LCD_GREY := [0.55, 0.62, 0.55]
const RED_LED := [0.95, 0.15, 0.1]
const GREEN_LED := [0.2, 0.9, 0.3]
const AMBER_LED := [0.98, 0.65, 0.1]

const LIBRARY_FILE := "user://ctrllab_library.json"

static var _all: Array = []


# ---------------------------------------------------------------------------
# The player's library (every world)
# ---------------------------------------------------------------------------

static func load_library(path: String = LIBRARY_FILE) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if v is Dictionary and (v as Dictionary).get("designs") is Dictionary:
		return v["designs"]
	return {}


static func save_to_library(id: String, spec: Dictionary, path: String = LIBRARY_FILE) -> bool:
	var lib := load_library(path)
	lib[id] = CtrlSpec.resolve(spec)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({"designs": lib}, "	"))
	return true


static func forget(id: String, path: String = LIBRARY_FILE) -> void:
	var lib := load_library(path)
	if not lib.has(id):
		return
	lib.erase(id)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"designs": lib}, "	"))


static func builtins() -> Array:
	if _all.is_empty():
		_all = _build_all()
	return _all


static func ids() -> Array:
	return builtins().map(func(s): return s["id"])


static func builtin(id: String) -> Dictionary:
	for s in builtins():
		if str(s["id"]) == id:
			return (s as Dictionary).duplicate(true)
	return {}


## The design for a graph library label ("EG4 6000XP") or {}.
static func for_library_label(label: String) -> Dictionary:
	if label.strip_edges() == "":
		return {}
	for s in builtins():
		if str(s.get("library", "")) == label:
			return (s as Dictionary).duplicate(true)
	return {}


## The built-in whose own name is this one (a graph node named after a
## unit, e.g. "EG4 6000XP Hybrid"), case-insensitive.
static func for_name(nm: String) -> Dictionary:
	var k := nm.strip_edges().to_lower()
	if k == "":
		return {}
	for s in builtins():
		if str(s.get("name", "")).to_lower() == k:
			return (s as Dictionary).duplicate(true)
	return {}


## Every word must match the name, maker, model, kind or form.
static func search(q: String) -> Array:
	var words := q.to_lower().split(" ", false)
	var out: Array = []
	for s in builtins():
		var e: Dictionary = s["elec"]
		var hay := ("%s %s %s %s %s %s %dv %.0fw" % [s["id"], s["name"], s["maker"], s["model"],
			CtrlSpec.KIND_WORDS.get(e["kind"], ""), CtrlSpec.FORM_WORDS.get(s["form"], ""), int(e["system_v"]),
			float(e["ac_out_w"])]).to_lower()
		var ok := true
		for w in words:
			if not hay.contains(w):
				ok = false
				break
		if ok:
			out.append(s["id"])
	return out


## One line for a gallery card ("48 V · 6 kW · 2 MPPT").
static func size_line(s: Dictionary) -> String:
	var e: Dictionary = s["elec"]
	var bits: Array = ["%d V" % int(e["system_v"])]
	if float(e.get("pack_wh", 0.0)) > 0.0:
		bits.append(UiText.num(float(e["pack_wh"]), "Wh"))
	if float(e["ac_out_w"]) > 0.0:
		bits.append(UiText.num(float(e["ac_out_w"]), "W") + " AC")
	if float(e["max_pv_w"]) > 0.0:
		bits.append(UiText.num(float(e["max_pv_w"]), "W") + " PV")
	if int(e["mppt_count"]) > 1:
		bits.append("%d MPPT" % int(e["mppt_count"]))
	elif float(e["max_charge_a"]) > 0.0 and str(e["kind"]) in ["mppt", "pwm", "dc_dc"]:
		bits.append("%.0f A" % float(e["max_charge_a"]))
	var line := " · ".join(bits)
	if float(e.get("cost", 0.0)) > 0.0:
		line = "$%s · %s" % [UiText.thousands(int(round(float(e["cost"])))), line]
	return line


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

static func _base(id: String, name: String, form: String, w: float, h: float, d: float) -> Dictionary:
	var s := CtrlSpec.empty(name)
	s["id"] = id
	s["form"] = form
	s["body"]["w"] = w
	s["body"]["h"] = h
	s["body"]["d"] = d
	return s


static func _p(id: String, conn: String, face: String, u: float, v: float, group: String = "", label: String = "",
		opts: Dictionary = {}, roles: Array = [], rot: float = 0.0, dz: float = 0.0) -> Dictionary:
	return {"id": id, "connector": conn, "face": face, "u": u, "v": v, "group": group, "label": label,
		"opts": opts, "roles": roles, "rot": rot, "dz": dz}


static func _t(face: String, u: float, v: float, text: String, size: float, color: Array = WHITE, bold: bool = false,
		dz: float = 0.0, rot: float = 0.0, align: String = "center", max_w: float = 0.0) -> Dictionary:
	return {"face": face, "u": u, "v": v, "text": text, "size": size, "color": color, "bold": bold, "dz": dz, "rot": rot,
		"align": align, "max_w": max_w}


static func _elec(s: Dictionary, e: Dictionary) -> void:
	for k in e:
		s["elec"][k] = e[k]


# ---------------------------------------------------------------------------
# Families
# ---------------------------------------------------------------------------

## A Victron moulded MPPT (SmartSolar / BlueSolar): blue body with a raised
## centre panel and an orange stripe on black finned wings; the terminal
## insert at the bottom front (BAT + −, PV − +), three LEDs, VE.Direct
## underneath. `w` is the data sheet's width (wings included).
static func _victron_mppt(id: String, name: String, model: String, w: float, h: float, d: float, e: Dictionary,
		big_terminals: bool = false) -> Dictionary:
	var fin_d := d * 0.22
	var ex := w * 0.1
	var wb := w - 2.0 * ex
	var s := _base(id, name, "mppt_box", wb, h, d - fin_d - 3.0)
	s["maker"] = "Victron Energy"
	s["model"] = model
	s["body"]["color"] = VICTRON
	s["body"]["finish"] = "plastic"
	s["body"]["corner_r"] = h * 0.08
	s["body"]["edge_r"] = minf(d * 0.12, 7.0)
	s["heatsink"] = {"where": "back", "fins": 14, "fin_d": fin_d, "fin_t": 1.6, "base_t": 3.0, "extra_w": ex,
		"color": FIN_BLACK, "slots": true}
	var pw := wb * 0.66
	s["panels"] = [
		{"x0": -pw * 0.5, "x1": pw * 0.5, "y0": -h * 0.44, "y1": h * 0.43, "raise": 3.0, "r": 6.0, "e": 2.0, "color": VICTRON_LIGHT},
		{"x0": -pw * 0.42, "x1": pw * 0.42, "y0": -h * 0.1, "y1": -h * 0.05, "raise": 3.3, "r": 0.0, "e": 0.0, "color": V_ORANGE},
	]
	var top := 3.3
	var px0 := -pw * 0.46
	s["texts"] = [
		_t("front", px0, h * 0.345, "victron energy", h * 0.04, WHITE, true, top, 0.0, "left", pw * 0.6),
		_t("front", 0.0, h * 0.2, name.replace("Victron ", "").split(" ")[0] + " charge controller", h * 0.05, WHITE, false, top,
			0.0, "center", pw * 0.9),
		_t("front", 0.0, h * 0.06, model, h * 0.11, WHITE, true, top, 0.0, "center", pw * 0.9),
		_t("front", px0, -h * 0.17, "Battery  %d/%d V | %.0f A" % [int(e["system_v"]), int(e["system_v"]) * 2, float(e["max_charge_a"])],
			h * 0.03, WHITE, false, top, 0.0, "left", pw * 0.55),
		_t("front", px0, -h * 0.225, "PV  %.0f V max | %.0f A" % [float(e["max_voc"]), float(e["max_input_a"])],
			h * 0.03, WHITE, false, top, 0.0, "left", pw * 0.55),
	]
	var tw := pw * 0.42
	if big_terminals:
		s["bay"] = {"on": true, "y1": h * 0.3, "wall": 8.0, "depth": s["body"]["d"] * 0.55, "color": NEAR_BLACK,
			"cover": {"show": true, "color": VICTRON, "window": {"on": false}}}
		var bw := wb - 16.0
		s["ports"] = [
			_p("bat_p", "box_lug", "bay", -bw * 0.36, 0.0, "bat", "BAT +", {"polarity": "+"}),
			_p("bat_n", "box_lug", "bay", -bw * 0.13, 0.0, "bat", "BAT −", {"polarity": "-"}),
			_p("pv_n", "box_lug", "bay", bw * 0.13, 0.0, "pv1", "PV −", {"polarity": "-"}),
			_p("pv_p", "box_lug", "bay", bw * 0.36, 0.0, "pv1", "PV +", {"polarity": "+"}),
			_p("vedirect", "ve_direct", "bottom", wb * 0.3, 0.0, "ve_direct", "VE.Direct"),
		]
	else:
		s["panels"].append({"x0": -tw * 0.5, "x1": tw * 0.5, "y0": -h * 0.45, "y1": -h * 0.3, "raise": 5.0, "r": 3.0, "e": 1.0,
			"color": NEAR_BLACK})
		var pitch := tw / 4.0
		s["ports"] = [
			_p("terms", "power_terminal", "front", 0.0, -h * 0.375, "", "Battery / PV",
				{"poles": 4, "pitch": pitch, "color": NEAR_BLACK, "labels": ["+", "−", "−", "+"], "h": h * 0.12, "d": 8.0},
				["bat+", "bat-", "pv1-", "pv1+"], 0.0, 5.0),
			_p("vedirect", "ve_direct", "bottom", wb * 0.3, 0.0, "ve_direct", "VE.Direct"),
		]
		s["texts"].append(_t("front", -pitch, -h * 0.315, "BATTERY", h * 0.026, WHITE, true, 5.0))
		s["texts"].append(_t("front", pitch, -h * 0.315, "PV", h * 0.026, WHITE, true, 5.0))
	for i in 3:
		var nm: String = ["Bulk", "Absorption", "Float"][i]
		var l0 := tw * 0.5 + 5.0
		var lsp := minf(7.0, (pw * 0.5 - 3.0 - l0) * 0.5)
		var lx2 := l0 + lsp * float(i)
		s["ports"].append(_p("led_%d" % i, "led", "front", lx2, -h * 0.4, "ui", nm, {"color": [0.08, 0.08, 0.09], "d": minf(4.0, lsp - 0.4)},
			[], 0.0, 3.0))
		s["texts"].append(_t("front", lx2, -h * 0.29, nm, h * 0.026, WHITE, false, 3.3, 90.0))
	_elec(s, e)
	return s


## A Victron box (MultiPlus, Phoenix): sheet-steel blue, sharp, an orange
## band with the logo, an LED panel, side plates folded into feet, glands
## underneath, the DC studs and AC terminals behind the front cover.
static func _victron_box(id: String, name: String, model: String, w: float, h: float, d: float, e: Dictionary,
		charger: bool) -> Dictionary:
	var s := _base(id, name, "inverter_box", w, h, d)
	s["maker"] = "Victron Energy"
	s["model"] = model
	s["body"]["color"] = VICTRON
	s["body"]["corner_r"] = 2.0
	s["body"]["edge_r"] = 3.0
	s["mount"] = {"style": "side_feet", "where": "both", "n": 2, "w": 22.0, "h": 50.0, "color": VICTRON}
	s["bands"] = [{"y0": h * 0.66, "y1": h * 0.72, "color": V_ORANGE}]
	s["vents"] = [{"face": "left", "u": 0.0, "v": h * 0.42, "w": d * 0.35, "h": 12.0, "n": 1},
		{"face": "right", "u": 0.0, "v": h * 0.42, "w": d * 0.35, "h": 12.0, "n": 1}]
	s["bay"] = {"on": true, "y1": h * 0.36, "wall": 10.0, "depth": d * 0.5, "color": [0.12, 0.12, 0.13],
		"cover": {"show": true, "color": VICTRON, "window": {"on": false}}}
	s["panels"] = [{"x0": w * 0.04, "x1": w * 0.46, "y0": h * 0.0, "y1": h * 0.14, "raise": 0.6, "r": 2.0, "e": 0.3,
		"color": [0.14, 0.15, 0.17]}]
	var tx0 := -w * 0.44
	s["texts"] = [
		_t("front", tx0, h * 0.19, "victron energy", h * 0.026, WHITE, true, 0.5, 0.0, "left", w * 0.4),
		_t("front", tx0, h * 0.085, model.split(" ")[0], h * 0.045, WHITE, true, 0.0, 0.0, "left", w * 0.44),
		_t("front", tx0, h * 0.035, " ".join(Array(model.split(" ")).slice(1)), h * 0.028, WHITE, false, 0.0, 0.0, "left", w * 0.44),
		_t("front", w * 0.12, h * 0.14 - 3.0, "charger", h * 0.018, [0.85, 0.86, 0.88], false, 0.9),
		_t("front", w * 0.34, h * 0.14 - 3.0, "inverter", h * 0.018, [0.85, 0.86, 0.88], false, 0.9),
	]
	var bw := w - 20.0
	var bh := h * 0.36 - 10.0
	var ports: Array = []
	var stud := 10.0 if float(e["ac_out_w"]) / maxf(float(e["system_v"]), 1.0) > 200.0 else 8.0
	ports.append(_p("bat_p", "stud", "bay", -bw * 0.32, -bh * 0.1, "bat", "BAT +", {"stud": stud, "boss_r": 11.0, "polarity": "+"}))
	ports.append(_p("bat_n", "stud", "bay", -bw * 0.12, -bh * 0.1, "bat", "BAT −", {"stud": stud, "boss_r": 11.0, "polarity": "-"}))
	if charger:
		ports.append(_p("ac_in", "ac_block", "bay", bw * 0.12, bh * 0.15, "ac_in", "AC in", {"labels": ["L", "N", "G"]}))
	ports.append(_p("ac_out", "ac_block", "bay", bw * 0.34, bh * 0.15, "ac_out", "AC out", {"labels": ["L", "N", "G"]}))
	ports.append(_p("vebus_1", "rj45", "bay", bw * 0.12, -bh * 0.3, "ve_bus", "VE.Bus"))
	ports.append(_p("vebus_2", "rj45", "bay", bw * 0.22, -bh * 0.3, "ve_bus", "VE.Bus"))
	ports.append(_p("temp", "terminal_block", "bay", bw * 0.38, -bh * 0.3, "temp", "Temp", {"poles": 2, "labels": ["T+", "T−"]}))
	# LED panel: charger column and inverter column.
	var names := ["mains on", "bulk", "absorption", "float", "inverter on", "overload", "low battery", "temperature"]
	for i in 8:
		var col := 0 if i < 4 else 1
		var row := i % 4
		var lx := w * (0.12 + 0.22 * col)
		var ly := h * (0.11 - 0.028 * row)
		ports.append(_p("led_%d" % i, "led", "front", lx, ly, "ui", names[i],
			{"color": (GREEN_LED if row == 0 or col == 0 else (RED_LED if row > 0 else AMBER_LED)), "d": 3.0}, [], 0.0, 0.6))
		s["texts"].append(_t("front", lx + 3.0, ly, names[i], h * 0.014, [0.85, 0.86, 0.88], false, 0.9, 0.0, "left", w * 0.17))
	ports.append(_p("switch", "button", "front", w * 0.23, h * 0.07, "ui", "On / off / charger only",
		{"d": 12.0, "color": [0.15, 0.15, 0.16]}, [], 0.0, 0.6))
	var gl := ["gland_m25", "gland_m25", "gland_m20"] if charger else ["gland_m25", "gland_m20"]
	for i in gl.size():
		ports.append(_p("gland_%d" % i, gl[i], "bottom", -w * 0.3 + w * 0.2 * float(i), d * 0.3))
	s["ports"] = ports
	_elec(s, e)
	return s


## A wall-mount hybrid: `look` picks the maker's face (growatt, powmr, eg4,
## solark, ecoworthy).
static func _wall_hybrid(id: String, name: String, model: String, maker: String, w: float, h: float, d: float,
		look: String, e: Dictionary) -> Dictionary:
	var s := _base(id, name, "wall_hybrid", w, h, d)
	s["maker"] = maker
	s["model"] = model
	var mppts := maxi(int(e.get("mppt_count", 1)), 1)
	var sys_v := float(e.get("system_v", 48))
	var bat_a := maxf(float(e.get("max_charge_a", 0.0)), float(e.get("ac_out_w", 0.0)) / (sys_v * 0.85))
	var stud := 10.0 if bat_a > 245.0 else 8.0
	var split := bool(e.get("split_phase", false))
	var ac_labels := ["L1", "L2", "N", "G"] if split else ["L", "N", "G"]
	var ports: Array = []
	var texts: Array = []
	match look:
		"growatt":
			s["body"]["color"] = [0.08, 0.08, 0.09]
			s["body"]["corner_r"] = w * 0.1
			s["body"]["edge_r"] = 3.0
			s["body"]["plate"] = {"on": true, "t": 12.0, "inset": 7.0, "color": WHITE, "corner_r": w * 0.11}
			s["bands"] = [{"y0": h * 0.155, "y1": h * 0.162, "color": GROWATT_GREEN, "t": 0.4}]
			s["mount"] = {"style": "bracket", "where": "top", "n": 1, "w": 0.0, "h": 0.0, "color": [-1.0, 0, 0]}
			texts.append(_t("front", -w * 0.36, h * 0.38, "G", h * 0.05, GROWATT_GREEN, true, 0.0, 0.0, "left"))
			texts.append(_t("front", -w * 0.36 + h * 0.038, h * 0.378, "ROWATT", h * 0.042, [0.2, 0.2, 0.21], true, 0.0, 0.0, "left"))
			ports.append(_p("lcd", "lcd", "front", 0.0, -h * 0.08, "ui", "Display",
				{"w": w * 0.2, "h": w * 0.13, "round": true, "screen": LCD_BLUE}))
			for i in 4:
				ports.append(_p("btn_%d" % i, "button", "front", -w * 0.075 + w * 0.05 * float(i), -h * 0.165, "ui",
					["ESC", "UP", "DOWN", "ENTER"][i], {"d": 7.0, "color": [0.15, 0.15, 0.16]}, [], 0.0, 1.5))
			for i in 3:
				ports.append(_p("led_%d" % i, "led", "front", -w * 0.06 + w * 0.06 * float(i), h * 0.03, "ui",
					["AC/INV", "CHG", "FAULT"][i], {"color": [GREEN_LED, AMBER_LED, RED_LED][i], "d": 3.0}, [], 0.0, 1.5))
		"powmr":
			s["body"]["color"] = POWMR_GREY
			s["body"]["corner_r"] = 3.0
			s["body"]["edge_r"] = 2.0
			s["bands"] = [{"y0": 0.0, "y1": h * 0.2, "color": POWMR_ORANGE}]
			s["mount"] = {"style": "tabs", "where": "top", "n": 2, "w": 34.0, "h": 16.0, "color": [0.55, 0.56, 0.58]}
			s["vents"] = [{"face": "right", "u": 0.0, "v": h * 0.25, "w": d * 0.55, "h": h * 0.18, "n": 10},
				{"face": "left", "u": 0.0, "v": h * 0.25, "w": d * 0.55, "h": h * 0.18, "n": 10}]
			texts.append(_t("front", 0.0, -h * 0.38, "PowMr", h * 0.06, BLACK, true, 0.6))
			texts.append(_t("front", 0.0, -h * 0.435, "HYBRID SOLAR INVERTER", h * 0.018, BLACK, false, 0.6))
			ports.append(_p("lcd", "lcd", "front", 0.0, h * 0.2, "ui", "Display",
				{"w": w * 0.24, "h": w * 0.13, "round": true, "screen": LCD_GREY, "ring": POWMR_ORANGE}))
			for i in 4:
				ports.append(_p("btn_%d" % i, "button", "front", -w * 0.075 + w * 0.05 * float(i), h * 0.105, "ui",
					["ESC", "UP", "DOWN", "ENTER"][i], {"d": 5.0, "color": [0.2, 0.2, 0.22]}, [], 0.0, 1.5))
		"eg4":
			s["body"]["color"] = EG4_SILVER
			s["body"]["corner_r"] = w * 0.05
			s["body"]["edge_r"] = 4.0
			s["body"]["split"] = {"y": h * 0.47, "color": [0.06, 0.06, 0.065]}
			s["mount"] = {"style": "bracket", "where": "top", "n": 1, "w": 0.0, "h": 0.0, "color": [-1.0, 0, 0]}
			texts.append(_t("front", -w * 0.33, h * 0.42, "EG4", h * 0.035, [0.1, 0.1, 0.11], true))
			texts.append(_t("front", 0.0, -h * 0.07, model, h * 0.05, WHITE, true))
			texts.append(_t("front", w * 0.3, -h * 0.47, "LUX POWER", h * 0.012, WHITE))
			ports.append(_p("lcd", "lcd", "front", 0.0, h * 0.3, "ui", "Display",
				{"w": w * 0.16, "h": w * 0.1, "round": false, "screen": [0.08, 0.1, 0.12], "bezel": NEAR_BLACK}))
			for i in 3:
				ports.append(_p("led_%d" % i, "led", "front", -w * 0.06 + w * 0.06 * float(i), h * 0.2, "ui",
					["NORMAL", "ALARM", "FAULT"][i], {"color": [GREEN_LED, AMBER_LED, RED_LED][i], "d": 3.0}))
		"solark":
			s["body"]["color"] = [0.16, 0.16, 0.17]
			s["body"]["corner_r"] = 6.0
			s["body"]["edge_r"] = 3.0
			s["bands"] = [{"y0": h * 0.55, "y1": h, "color": WHITE, "t": 0.5}]
			s["mount"] = {"style": "bracket", "where": "top", "n": 1, "w": 0.0, "h": 0.0, "color": [-1.0, 0, 0]}
			texts.append(_t("front", -w * 0.25, h * 0.4, "SOL-ARK", h * 0.03, [0.85, 0.35, 0.1], true, 0.5))
			ports.append(_p("lcd", "lcd", "front", 0.0, h * 0.22, "ui", "Touch screen",
				{"w": w * 0.32, "h": w * 0.2, "screen": LCD_BLUE}, [], 0.0, 0.5))
		_:
			s["body"]["color"] = WHITE
			s["body"]["corner_r"] = w * 0.04
			s["body"]["edge_r"] = 3.0
			s["bands"] = [{"y0": h * 0.12, "y1": h * 0.16, "color": [0.1, 0.45, 0.8]}]
			s["mount"] = {"style": "tabs", "where": "both", "n": 1, "w": 40.0, "h": 16.0, "color": [0.6, 0.6, 0.62]}
			texts.append(_t("front", 0.0, h * 0.38, maker.to_upper(), h * 0.035, [0.1, 0.45, 0.8], true))
			ports.append(_p("lcd", "lcd", "front", 0.0, h * 0.18, "ui", "Display", {"w": w * 0.3, "h": w * 0.14, "screen": LCD_BLUE}))
	if look in ["eg4", "solark"]:
		# The wiring bay (the EG4 photo): battery studs, DIN breakers for
		# load / grid / gen with their L terminals, N and PE bars, the PV
		# terminal block, RSD and comms; knockouts in the floor.
		var bay_h := h * (0.42 if look == "eg4" else 0.4)
		s["bay"] = {"on": true, "y1": bay_h, "wall": 14.0, "depth": d * 0.6, "color": [0.05, 0.05, 0.055],
			"cover": {"show": true, "color": [-1.0, 0, 0],
				"window": {"on": look == "eg4", "x0": -w * 0.4, "x1": w * 0.26, "y0": bay_h * 0.06, "y1": bay_h * 0.36}}}
		var bw := w - 28.0
		var bh := bay_h - 14.0
		ports.append(_p("bat_p", "stud", "bay", -bw * 0.4, -bh * 0.05, "bat", "BAT +", {"stud": stud, "boss_r": 13.0, "polarity": "+", "insulator": false, "color": [0.1, 0.4, 0.2]}, [], 90.0))
		ports.append(_p("bat_n", "stud", "bay", -bw * 0.26, -bh * 0.05, "bat", "BAT −", {"stud": stud, "boss_r": 13.0, "polarity": "-", "insulator": false, "color": [0.1, 0.4, 0.2]}, [], 90.0))
		ports.append(_p("rsd", "terminal_block_35", "bay", -bw * 0.4, -bh * 0.32, "rsd", "RSD", {"poles": 2, "labels": ["12V", "SW"]}))
		ports.append(_p("rail", "din_rail", "bay", bw * 0.13, bh * 0.22, "", "DIN rail", {"length": bw * 0.48}))
		var names := ["LOAD", "GRID", "GEN"]
		var groups := ["ac_out", "ac_in", "gen"]
		for i in 3:
			var bx := bw * (-0.04 + 0.12 * float(i))
			ports.append(_p("brk_%s" % names[i].to_lower(), "din_breaker", "bay", bx, bh * 0.22, "", names[i],
				{"poles": 2, "amps": 50, "curve": "C", "label": "", "toggle": [0.15, 0.3, 0.8]}, [], 0.0, 7.5))
			ports.append(_p("term_%s" % names[i].to_lower(), "power_terminal", "bay", bx, -bh * 0.12, groups[i], names[i],
				{"poles": 2, "pitch": 12.0, "color": [0.12, 0.25, 0.65], "labels": ["L1", "L2"] if split else ["L", "N"]},
				[groups[i] + "_L1", groups[i] + "_L2"] if split else [groups[i] + "_L", groups[i] + "_N"]))
			texts.append(_t("bay", bx, -bh * 0.27, names[i], 6.0, WHITE, true))
		ports.append(_p("n_bar", "bus_bar", "bay", -bw * 0.05, -bh * 0.38, "", "N",
			{"screws": 8, "label": "N"}, ["ac_out_N", "ac_in_N", "gen_N", "", "", "", "", ""] if split else []))
		ports.append(_p("pe_bar", "bus_bar", "bay", bw * 0.3, -bh * 0.38, "ground", "PE",
			{"screws": 8, "label": "PE"}, ["ac_out_G", "ac_in_G", "gen_G", "ground", "", "", "", ""]))
		var pv_labels: Array = []
		var pv_roles: Array = []
		for m in mppts:
			pv_labels.append_array(["%d+" % (m + 1), "%d−" % (m + 1)])
			pv_roles.append_array(["pv%d+" % (m + 1), "pv%d-" % (m + 1)])
		ports.append(_p("pv_in", "power_terminal", "bay", bw * 0.38, -bh * 0.12, "", "PV INPUT",
			{"poles": mppts * 2, "pitch": 11.0, "color": [0.12, 0.12, 0.13], "labels": pv_labels}, pv_roles))
		texts.append(_t("bay", bw * 0.38, -bh * 0.27, "PV INPUT", 6.0, WHITE, true))
		var kos := [["1-1/4", -w * 0.33], ["1", -w * 0.12], ["1", w * 0.08], ["3/4", w * 0.28]]
		for i in kos.size():
			ports.append(_p("ko_%d" % i, "knockout", "bottom", kos[i][1], d * 0.25, "", "Knockout %s\"" % kos[i][0],
				{"trade": kos[i][0], "conduit": i == 2}))
		ports.append(_p("bms", "rj45", "left", d * 0.2, -h * 0.2, "comm_bms", "BMS (CAN / RS485)"))
		ports.append(_p("rs485", "rj45", "left", d * 0.2, -h * 0.27, "rs485", "RS485 / meter"))
		ports.append(_p("wifi", "usb_a", "left", d * 0.2, -h * 0.33, "wifi", "Wi-Fi dongle"))
		# The battery breaker: a DC breaker on the rail's left, its handle
		# up to the cover.
		ports.append(_p("bat_brk", "din_breaker", "bay", -bw * 0.3, bh * 0.22, "", "Battery breaker",
			{"poles": 2, "amps": 125 if stud < 9.0 else 250, "curve": "DC", "toggle": [0.08, 0.08, 0.09]}, [], 0.0, 7.5))
	else:
		# Terminals on the underside: PV MC4 pairs, battery studs, AC blocks,
		# comms; glands for the AC cables.
		var row: Array = []
		for m in mppts:
			row.append([_p("pv%d_p" % (m + 1), "mc4_panel", "bottom", 0.0, d * 0.12, "pv%d" % (m + 1), "PV%d +" % (m + 1),
				{"sex": "female", "polarity": "+"}), 22.0])
			row.append([_p("pv%d_n" % (m + 1), "mc4_panel", "bottom", 0.0, d * 0.12, "pv%d" % (m + 1), "PV%d −" % (m + 1),
				{"sex": "male", "polarity": "-"}), 22.0])
		row.append([_p("bat_p", "stud", "bottom", 0.0, d * 0.08, "bat", "BAT +", {"stud": stud, "boss_r": 12.0, "polarity": "+"}), 30.0])
		row.append([_p("bat_n", "stud", "bottom", 0.0, d * 0.08, "bat", "BAT −", {"stud": stud, "boss_r": 12.0, "polarity": "-"}), 30.0])
		if float(e.get("ac_in_a", 0.0)) > 0.0:
			row.append([_p("ac_in", "ac_block", "bottom", 0.0, d * 0.08, "ac_in", "AC in", {"labels": ac_labels.slice(0, 3)}), 36.0])
		row.append([_p("ac_out", "ac_block", "bottom", 0.0, d * 0.08, "ac_out", "AC out", {"labels": ac_labels.slice(0, 3)}), 36.0])
		var span := w - 2.0 * float(s["body"]["corner_r"]) - 24.0
		var total := 0.0
		for it in row:
			total += float(it[1])
		var gap := maxf((span - total) / float(maxi(row.size() - 1, 1)), 2.0)
		var x := -(total + gap * float(row.size() - 1)) * 0.5
		for it in row:
			var pp: Dictionary = it[0]
			pp["u"] = x + float(it[1]) * 0.5
			x += float(it[1]) + gap
			ports.append(pp)
		ports.append(_p("bms", "rj45", "bottom", w * 0.12, -d * 0.28, "comm_bms", "BMS"))
		ports.append(_p("rs485", "rj45", "bottom", w * 0.2, -d * 0.28, "rs485", "RS485"))
		ports.append(_p("wifi", "usb_a", "bottom", w * 0.04, -d * 0.28, "wifi", "Wi-Fi / USB"))
	s["ports"] = ports
	s["texts"] = texts
	_elec(s, e)
	return s


## A generic MPPT box: a plastic front over an aluminium finned back with
## slotted wings; six screw terminals across the bottom of the front.
static func _mppt_box(id: String, name: String, maker: String, model: String, w: float, h: float, d: float,
		front_col: Array, fin_col: Array, lcd: bool, e: Dictionary) -> Dictionary:
	var fin_d := d * 0.3
	var ex := 14.0
	var s := _base(id, name, "mppt_box", w - 2.0 * ex, h, d - fin_d - 3.0)
	s["maker"] = maker
	s["model"] = model
	s["body"]["color"] = front_col
	s["body"]["corner_r"] = 6.0
	s["body"]["edge_r"] = 4.0
	s["heatsink"] = {"where": "back", "fins": 12, "fin_d": fin_d, "fin_t": 2.0, "base_t": 3.0, "extra_w": ex,
		"color": fin_col, "slots": true}
	var wb := w - 2.0 * ex
	var ports: Array = []
	var pitch := minf(wb * 0.13, 12.0)
	ports.append(_p("terms", "power_terminal", "front", 0.0, -h * 0.4, "", "PV / BATTERY / LOAD",
		{"poles": 6, "pitch": pitch, "color": [0.1, 0.1, 0.11], "labels": ["+", "−", "+", "−", "+", "−"]},
		["pv1+", "pv1-", "bat+", "bat-", "load+", "load-"]))
	var gl := minf(h * 0.03, pitch * 0.42)
	var texts: Array = [
		_t("front", -pitch * 2.0, -h * 0.28, "PV", gl, WHITE, true, 0.0, 0.0, "center", pitch * 1.8),
		_t("front", 0.0, -h * 0.28, "BATTERY", gl, WHITE, true, 0.0, 0.0, "center", pitch * 1.8),
		_t("front", pitch * 2.0, -h * 0.28, "LOAD", gl, WHITE, true, 0.0, 0.0, "center", pitch * 1.8),
		_t("front", 0.0, h * 0.4, maker.to_upper(), h * 0.04, WHITE, true),
		_t("front", 0.0, h * 0.33, model, h * 0.035, [0.8, 0.82, 0.85]),
	]
	if lcd:
		ports.append(_p("lcd", "lcd", "front", 0.0, h * 0.12, "ui", "Display", {"w": wb * 0.42, "h": wb * 0.22, "screen": LCD_GREY}))
		for i in 2:
			ports.append(_p("btn_%d" % i, "button", "front", -wb * 0.08 + wb * 0.16 * float(i), -h * 0.05, "ui",
				["MENU", "ENTER"][i], {"d": 8.0, "color": [0.2, 0.2, 0.22], "round": false}))
	else:
		for i in 3:
			ports.append(_p("led_%d" % i, "led", "front", -wb * 0.12 + wb * 0.12 * float(i), h * 0.1, "ui",
				["PV", "BATTERY", "LOAD"][i], {"color": [GREEN_LED, AMBER_LED, GREEN_LED][i], "d": 4.0}))
	ports.append(_p("rs485", "rj45", "bottom", wb * 0.25, 0.0, "rs485", "RS485 / comms"))
	ports.append(_p("temp", "terminal_block_35", "bottom", -wb * 0.25, 0.0, "temp", "Temp sensor", {"poles": 2, "labels": ["T", "T"]}))
	s["ports"] = ports
	s["texts"] = texts
	_elec(s, e)
	return s


## A small PWM controller: a plastic box with corner screw holes, LEDs,
## six terminals and a USB port.
static func _pwm_box(id: String, name: String, maker: String, model: String, w: float, h: float, d: float,
		col: Array, e: Dictionary) -> Dictionary:
	var s := _base(id, name, "mppt_box", w, h, d)
	s["maker"] = maker
	s["model"] = model
	s["body"]["color"] = col
	s["body"]["corner_r"] = 5.0
	s["body"]["edge_r"] = 4.0
	s["mount"] = {"style": "tabs", "where": "both", "n": 2, "w": 14.0, "h": 10.0, "color": col}
	var pitch := minf(w * 0.12, 9.0)
	s["ports"] = [
		_p("terms", "power_terminal", "front", 0.0, -h * 0.33, "", "PV / BATTERY / LOAD",
			{"poles": 6, "pitch": pitch, "color": [0.08, 0.08, 0.09], "labels": ["+", "−", "+", "−", "+", "−"], "h": h * 0.2, "d": 10.0},
			["pv1+", "pv1-", "bat+", "bat-", "load+", "load-"]),
		_p("lcd", "lcd", "front", 0.0, h * 0.16, "ui", "Display", {"w": w * 0.45, "h": w * 0.16, "screen": LCD_GREY}),
		_p("usb", "usb_a", "front", w * 0.3, -h * 0.12, "usb", "USB 5 V"),
		_p("btn", "button", "front", -w * 0.3, -h * 0.12, "ui", "Mode", {"d": 7.0}),
	]
	s["texts"] = [_t("front", 0.0, h * 0.41, maker.to_upper() + "  " + model, h * 0.045, WHITE, true)]
	_elec(s, e)
	return s


## A car-style inverter: a finned aluminium extrusion between plastic end
## caps; AC outlets, USB, switch and LEDs on the front end, the battery
## posts, fan grille and ground lug on the back end; mounting ears.
static func _car_inverter(id: String, name: String, maker: String, model: String, length: float, width: float,
		height: float, body_col: Array, cap_col: Array, outlets: String, e: Dictionary) -> Dictionary:
	var s := _base(id, name, "car_inverter", width, height, length)
	s["maker"] = maker
	s["model"] = model
	s["body"]["color"] = body_col
	s["body"]["finish"] = "alu"
	s["body"]["corner_r"] = 6.0
	s["body"]["edge_r"] = 0.0
	s["heatsink"] = {"where": "full", "fins": maxi(int(width / 12.0), 6), "fin_d": 9.0, "fin_t": 2.2, "base_t": 0.0,
		"extra_w": 0.0, "color": body_col, "slots": false}
	s["caps"] = {"t": 14.0, "color": cap_col}
	s["mount"] = {"style": "ears", "where": "both", "n": 2, "w": 18.0, "h": 0.0, "color": body_col}
	var sys_v := float(e.get("system_v", 12))
	var stud := 10.0 if float(e.get("ac_out_w", 0.0)) / (sys_v * 0.85) > 245.0 else 8.0
	var ports: Array = []
	match outlets:
		"duplex":
			ports.append(_p("ac_out", "nema_5_15_duplex", "front", -width * 0.18, 0.0, "ac_out", "AC out",
				{"color": [0.12, 0.12, 0.13]}, [], 90.0))
		"gfci":
			ports.append(_p("ac_out", "nema_5_20_gfci", "front", -width * 0.15, 0.0, "ac_out", "AC out (GFCI)",
				{"color": [0.9, 0.9, 0.88]}, [], 90.0))
			ports.append(_p("ac_hw", "ac_block", "front", width * 0.18, -height * 0.2, "ac_out", "Hard-wire",
				{"labels": ["L", "N", "G"]}))
		_:
			ports.append(_p("ac_out", "nema_5_15", "front", -width * 0.25, 0.0, "ac_out", "AC out", {"color": [0.12, 0.12, 0.13]}))
			ports.append(_p("ac_out_b", "nema_5_15", "front", -width * 0.05, 0.0, "ac_out", "AC out", {"color": [0.12, 0.12, 0.13]}))
	ports.append(_p("usb", "usb_a", "front", width * 0.18, height * 0.22, "usb", "USB 5 V"))
	ports.append(_p("power", "rocker_switch", "front", width * 0.33, height * 0.1, "ui", "Power"))
	ports.append(_p("led_ok", "led", "front", width * 0.33, -height * 0.18, "ui", "Power", {"color": GREEN_LED, "d": 3.0}))
	ports.append(_p("led_fault", "led", "front", width * 0.39, -height * 0.18, "ui", "Fault", {"color": RED_LED, "d": 3.0}))
	ports.append(_p("bat_n", "stud", "back", width * 0.25, -height * 0.05, "bat", "BAT −",
		{"stud": stud, "boss_r": 10.0, "polarity": "-"}))
	ports.append(_p("bat_p", "stud", "back", -width * 0.25, -height * 0.05, "bat", "BAT +",
		{"stud": stud, "boss_r": 10.0, "polarity": "+"}))
	ports.append(_p("gnd", "ground_lug", "back", 0.0, -height * 0.25, "ground", "Chassis ground"))
	s["ports"] = ports
	s["vents"] = [{"face": "back", "u": 0.0, "v": height * 0.12, "w": width * 0.3, "h": height * 0.45, "n": 6}]
	s["texts"] = [_t("top", 0.0, 0.0, maker.to_upper() + "  " + model, height * 0.12, WHITE, true, 9.5)]
	_elec(s, e)
	return s


# ---------------------------------------------------------------------------
# The built-ins
# ---------------------------------------------------------------------------

static func _build_all() -> Array:
	var out: Array = []
	# --- Library units ------------------------------------------------------
	var s := _wall_hybrid("ecoworthy_sl3500", "EcoWorthy SL3500 Hybrid", "SL3500", "EcoWorthy", 300.0, 400.0, 115.0, "ecoworthy",
		{"kind": "hybrid", "system_v": 24, "max_voc": 450.0, "max_charge_a": 80.0, "max_pv_w": 3500.0, "max_input_a": 18.0,
		"ac_out_w": 3500.0, "ac_in_a": 30.0, "cost": 900.0, "mass_kg": 9.5})
	s["library"] = "EcoWorthy SL3500"
	s["source"] = "electrical: the library preset; size and look estimate"
	out.append(s)
	s = _mppt_box("generic_mppt_150_50", "Generic MPPT 150/50", "Generic", "MPPT 150/50", 230.0, 260.0, 95.0,
		[0.1, 0.1, 0.11], ALU_DARK, true,
		{"kind": "mppt", "system_v": 24, "max_voc": 150.0, "max_charge_a": 50.0, "max_pv_w": 2400.0, "max_input_a": 40.0, "cost": 250.0})
	s["library"] = "Generic MPPT 150/50"
	s["source"] = "estimate"
	out.append(s)
	s = _victron_mppt("victron_ss_150_35", "Victron SmartSolar 150/35", "MPPT 150 | 35", 186.0, 130.0, 70.0,
		{"kind": "mppt", "system_v": 12, "max_voc": 150.0, "max_charge_a": 35.0, "max_pv_w": 2000.0, "max_input_a": 40.0,
		"cost": 207.0, "mass_kg": 1.3, "comms": ["VE.Direct", "Bluetooth"]})
	s["library"] = "Victron 150/35"
	s["source"] = "Victron SmartSolar MPPT 150/35 (130 × 186 × 70 mm, 1.3 kg). $207 is the 2026 Q4 USD list price, ex VAT"
	out.append(s)
	s = _victron_mppt("victron_ss_100_20", "Victron SmartSolar 100/20", "MPPT 100 | 20", 113.0, 100.0, 50.0,
		{"kind": "mppt", "system_v": 12, "max_voc": 100.0, "max_charge_a": 20.0, "max_pv_w": 580.0, "max_input_a": 20.0,
		"cost": 100.0, "mass_kg": 0.7, "comms": ["VE.Direct", "Bluetooth"]})
	s["library"] = "Victron 100/20"
	s["source"] = "Victron SmartSolar MPPT 100/20 up to 48 V (100 × 113 × 50 mm, 0.7 kg). 580 W is the 24 V array limit. $100 is the 2026 Q4 USD list price, ex VAT"
	out.append(s)
	s = _mppt_box("renogy_rover_40", "Renogy Rover 40A MPPT", "Renogy", "Rover 40A", 210.0, 285.0, 92.0,
		[0.12, 0.12, 0.13], ALU, true,
		{"kind": "mppt", "system_v": 12, "max_voc": 100.0, "max_charge_a": 40.0, "max_pv_w": 1040.0, "max_input_a": 40.0,
		"cost": 160.0, "mass_kg": 2.8, "comms": ["RS232"]})
	s["library"] = "Renogy Rover 40A"
	s["source"] = "electrical: the library preset; size estimate"
	out.append(s)
	s = _wall_hybrid("powmr_5000", "PowMR 5000W Hybrid Inv.", "POW-HVM5.5K-48V", "PowMR", 330.0, 450.0, 125.0, "powmr",
		{"kind": "hybrid", "system_v": 48, "max_voc": 500.0, "max_charge_a": 80.0, "max_pv_w": 5500.0, "max_input_a": 22.0,
		"mppt_min_v": 0.0, "ac_out_w": 5000.0, "ac_in_a": 40.0, "cost": 650.0, "mass_kg": 10.5,
		"comms": ["RS485", "CAN", "Wi-Fi"]})
	s["library"] = "PowMR 5000W Hybrid"
	s["source"] = "electrical: the library preset; size estimate from the photo"
	out.append(s)
	s = _power_station()
	out.append(s)
	s = _wall_hybrid("eg4_6000xp", "EG4 6000XP Hybrid", "6000XP", "EG4 Electronics", 457.0, 648.0, 132.0, "eg4",
		{"kind": "hybrid", "system_v": 48, "max_voc": 480.0, "max_charge_a": 125.0, "max_pv_w": 8000.0,
		"max_pv_w_per_mppt": 4000.0, "mppt_count": 2, "mppt_min_v": 120.0, "mppt_max_v": 385.0, "startup_v": 100.0,
		"max_input_a": 17.0, "max_isc_a": 25.0, "ac_out_w": 6000.0, "surge_w": 12000.0, "ac_in_a": 50.0,
		"split_phase": true, "ac_v": 240.0,
		"idle_w": 50.0, "eff": {"mppt": 0.99, "charge": 0.93}, "cost": 1500.0, "mass_kg": 24.0,
		"comms": ["CAN", "RS485", "Wi-Fi"]})
	s["library"] = "EG4 6000XP"
	s["source"] = "EG4 6000XP data sheet v1.4.4: 457 × 648 × 132 mm, 24 kg, 6 kW AC, 12 kW surge, 8 kW PV. About $1,500 US street (2026)"
	out.append(s)
	s = _pwm_box("trainer_pwm_10", "Trainer PWM 12V 10A", "Trainer", "PWM 10A", 133.0, 70.0, 35.0, [0.12, 0.3, 0.6],
		{"kind": "pwm", "system_v": 12, "max_voc": 50.0, "max_charge_a": 10.0, "max_pv_w": 300.0, "max_input_a": 10.0, "cost": 30.0})
	s["library"] = "Trainer PWM 10A"
	s["source"] = "Solar Bootcamp trainer (estimate)"
	out.append(s)
	s = _mppt_box("trainer_mppt_150_30", "Trainer MPPT 150V 30A", "Trainer", "MPPT 150/30", 180.0, 200.0, 80.0,
		[0.12, 0.3, 0.6], ALU_DARK, false,
		{"kind": "mppt", "system_v": 12, "max_voc": 150.0, "max_charge_a": 30.0, "max_pv_w": 2000.0, "max_input_a": 30.0, "cost": 180.0})
	s["library"] = "Trainer MPPT 150/30"
	s["source"] = "Solar Bootcamp trainer (estimate)"
	out.append(s)
	# --- Common units the library was missing --------------------------------
	s = _victron_box("victron_multiplus_12_3000", "Victron MultiPlus 12/3000/120", "MultiPlus 12 | 3000 | 120",
		258.0, 362.0, 218.0,
		{"kind": "inverter_charger", "system_v": 12, "max_voc": 0.0, "max_charge_a": 120.0, "max_pv_w": 0.0,
		"ac_out_w": 2400.0, "surge_w": 6000.0, "ac_in_a": 50.0, "idle_w": 20.0, "eff": {"inverter": 0.93},
		"cost": 1179.0, "mass_kg": 18.0, "comms": ["VE.Bus"]}, true)
	s["source"] = "Victron MultiPlus 12/3000/120-50 120 V UL (PMP122301102): 3000 VA / 2400 W, 120 A charge, 50 A transfer, 362 × 258 × 218 mm, 18 kg. $1,179 is the 2026 Q4 USD list price, ex VAT"
	out.append(s)
	s = _victron_box("victron_multiplus_ii_48_3000", "Victron MultiPlus-II 48/3000/35-50", "MultiPlus-II 48 | 3000 | 35-50",
		277.0, 572.0, 147.0,
		{"kind": "inverter_charger", "system_v": 48, "max_voc": 0.0, "max_charge_a": 35.0, "max_pv_w": 0.0,
		"ac_out_w": 2400.0, "surge_w": 5500.0, "ac_in_a": 50.0, "ac_v": 120.0, "idle_w": 11.0, "eff": {"inverter": 0.95},
		"cost": 658.0, "mass_kg": 19.0, "comms": ["VE.Bus"]}, true)
	s["source"] = "Victron MultiPlus-II 48/3000/35-50 120 V UL (PMP482305102): 3000 VA / 2400 W, 35 A charge, 50 A transfer, peak 5500 W, 572 × 277 × 147 mm, 19 kg. $658 is the 2026 Q4 USD list price, ex VAT"
	s["body"]["corner_r"] = 6.0
	out.append(s)
	s = _victron_box("victron_phoenix_12_1200", "Victron Phoenix 12/1200", "Phoenix 12 | 1200", 232.0, 362.0, 117.0,
		{"kind": "inverter", "system_v": 12, "max_voc": 0.0, "max_charge_a": 0.0, "max_pv_w": 0.0, "ac_out_w": 1000.0,
		"surge_w": 2200.0, "idle_w": 8.0, "eff": {"inverter": 0.91}, "cost": 292.0, "mass_kg": 8.5, "comms": ["VE.Direct"]}, false)
	s["source"] = "Victron Inverter 12/1200 VE.Direct NEMA GFCI (PIN122122510): 1200 VA / 1000 W, 117 × 232 × 362 mm (H×W×D), 8.5 kg. Drawn with the 362 mm side vertical so the terminal bay fits; the three edge lengths are the sheet's. $292 is the 2026 Q4 USD list price, ex VAT"
	s["mount"]["style"] = "flange"
	s["mount"]["h"] = 10.0
	out.append(s)
	s = _victron_mppt("victron_ss_100_30", "Victron SmartSolar 100/30", "MPPT 100 | 30", 186.0, 130.0, 70.0,
		{"kind": "mppt", "system_v": 12, "max_voc": 100.0, "max_charge_a": 30.0, "max_pv_w": 440.0, "max_input_a": 30.0,
		"cost": 144.0, "mass_kg": 1.3, "comms": ["VE.Direct", "Bluetooth"]})
	s["source"] = "Victron SmartSolar MPPT 100/30 (130 × 186 × 70 mm, 1.3 kg). $144 is the 2026 Q4 USD list price, ex VAT"
	out.append(s)
	s = _victron_mppt("victron_ss_250_100", "Victron SmartSolar 250/100-Tr", "MPPT 250 | 100", 295.0, 216.0, 103.0,
		{"kind": "mppt", "system_v": 48, "max_voc": 250.0, "max_charge_a": 100.0, "max_pv_w": 5800.0, "max_input_a": 70.0,
		"cost": 686.0, "mass_kg": 4.5, "comms": ["VE.Direct", "Bluetooth"]}, true)
	s["source"] = "Victron SmartSolar MPPT 250/100-Tr VE.Can (216 × 295 × 103 mm, 4.5 kg). $686 is the 2026 Q4 USD list price, ex VAT"
	out.append(s)
	s = _victron_mppt("victron_bs_75_15", "Victron BlueSolar 75/15", "MPPT 75 | 15", 113.0, 100.0, 40.0,
		{"kind": "mppt", "system_v": 12, "max_voc": 75.0, "max_charge_a": 15.0, "max_pv_w": 220.0, "max_input_a": 15.0,
		"cost": 54.0, "mass_kg": 0.5, "comms": ["VE.Direct"]})
	s["source"] = "Victron BlueSolar MPPT 75/15 (100 × 113 × 40 mm, 0.5 kg). $54 is the 2026 Q4 USD list price, ex VAT"
	out.append(s)
	s = _dc_dc()
	out.append(s)
	s = _wall_hybrid("eg4_12kpv", "EG4 12kPV Hybrid", "12kPV", "EG4 Electronics", 520.0, 760.0, 230.0, "eg4",
		{"kind": "hybrid", "system_v": 48, "max_voc": 600.0, "max_charge_a": 200.0, "max_pv_w": 12000.0,
		"max_pv_w_per_mppt": 6000.0, "mppt_count": 2, "mppt_min_v": 120.0, "mppt_max_v": 500.0, "startup_v": 140.0,
		"max_input_a": 25.0, "ac_out_w": 8000.0, "ac_in_a": 63.0, "split_phase": true, "ac_v": 240.0, "cost": 3000.0,
		"mass_kg": 46.0, "comms": ["CAN", "RS485", "Wi-Fi"]})
	s["source"] = "estimate (EG4 12kPV: 8 kW AC, 12 kW PV, 2 MPPT)"
	out.append(s)
	s = _wall_hybrid("eg4_18kpv", "EG4 18kPV Hybrid", "18kPV", "EG4 Electronics", 520.0, 800.0, 240.0, "eg4",
		{"kind": "hybrid", "system_v": 48, "max_voc": 500.0, "max_charge_a": 250.0, "max_pv_w": 18000.0,
		"max_pv_w_per_mppt": 6000.0, "mppt_count": 3, "mppt_min_v": 100.0, "mppt_max_v": 480.0, "startup_v": 100.0,
		"max_input_a": 25.0, "ac_out_w": 12000.0, "ac_in_a": 90.0, "split_phase": true, "ac_v": 240.0, "cost": 4500.0,
		"mass_kg": 59.0, "comms": ["CAN", "RS485", "Wi-Fi"]})
	s["source"] = "estimate (EG4 18kPV: 12 kW AC, 18 kW PV, 3 MPPT, 250 A charge)"
	out.append(s)
	s = _wall_hybrid("eg4_12000xp", "EG4 12000XP", "12000XP", "EG4 Electronics", 500.0, 760.0, 200.0, "eg4",
		{"kind": "hybrid", "system_v": 48, "max_voc": 480.0, "max_charge_a": 250.0, "max_pv_w": 16000.0,
		"max_pv_w_per_mppt": 6000.0, "mppt_count": 3, "mppt_min_v": 120.0, "mppt_max_v": 385.0, "startup_v": 100.0,
		"max_input_a": 25.0, "ac_out_w": 12000.0, "ac_in_a": 90.0, "split_phase": true, "ac_v": 240.0, "cost": 3300.0,
		"mass_kg": 50.0, "comms": ["CAN", "RS485", "Wi-Fi"]})
	s["source"] = "estimate (EG4 12000XP: 12 kW off-grid, 3 MPPT)"
	out.append(s)
	s = _wall_hybrid("growatt_spf_5000es", "Growatt SPF 5000 ES", "SPF 5000 ES", "Growatt", 330.0, 455.0, 130.0, "growatt",
		{"kind": "hybrid", "system_v": 48, "max_voc": 450.0, "max_charge_a": 100.0, "max_pv_w": 6000.0, "mppt_min_v": 120.0,
		"mppt_max_v": 430.0, "max_input_a": 27.0, "ac_out_w": 5000.0, "ac_v": 230.0, "ac_in_a": 40.0, "idle_w": 40.0,
		"cost": 900.0, "mass_kg": 11.5, "comms": ["RS485", "CAN", "USB", "Wi-Fi"]})
	s["source"] = "Growatt SPF 5000 ES data sheet (6 kW PV, 450 V, 120–430 V MPPT, 100 A charge; 330 × 455 × 130 mm, 11.5 kg); the reference photo"
	out.append(s)
	s = _wall_hybrid("growatt_spf_6000es_plus", "Growatt SPF 6000 ES Plus", "SPF 6000 ES Plus", "Growatt", 360.0, 530.0, 145.0, "growatt",
		{"kind": "hybrid", "system_v": 48, "max_voc": 500.0, "max_charge_a": 140.0, "max_pv_w": 8000.0,
		"max_pv_w_per_mppt": 4000.0, "mppt_count": 2, "mppt_min_v": 90.0, "mppt_max_v": 450.0, "max_input_a": 18.0,
		"ac_out_w": 6000.0, "ac_v": 230.0, "ac_in_a": 50.0, "cost": 1300.0, "mass_kg": 15.0,
		"comms": ["RS485", "CAN", "Wi-Fi"]})
	s["source"] = "estimate (Growatt SPF 6000 ES Plus: 2 × 4 kW MPPT, 500 V)"
	out.append(s)
	s = _wall_hybrid("powmr_3000", "PowMR 3000W Hybrid", "POW-HVM3.2H-24V", "PowMR", 290.0, 380.0, 110.0, "powmr",
		{"kind": "hybrid", "system_v": 24, "max_voc": 500.0, "max_charge_a": 100.0, "max_pv_w": 4000.0, "max_input_a": 18.0,
		"ac_out_w": 3200.0, "ac_in_a": 30.0, "cost": 420.0, "mass_kg": 7.5, "comms": ["RS485", "Wi-Fi"]})
	s["source"] = "estimate (PowMR 3.2 kW 24 V)"
	out.append(s)
	s = _wall_hybrid("solark_15k", "Sol-Ark 15K", "15K-2P", "Sol-Ark", 546.0, 826.0, 267.0, "solark",
		{"kind": "hybrid", "system_v": 48, "max_voc": 500.0, "max_charge_a": 275.0, "max_pv_w": 19500.0,
		"max_pv_w_per_mppt": 6500.0, "mppt_count": 3, "mppt_min_v": 150.0, "mppt_max_v": 425.0, "startup_v": 125.0,
		"max_input_a": 26.0, "ac_out_w": 12000.0, "ac_in_a": 200.0, "split_phase": true, "ac_v": 240.0, "cost": 9500.0,
		"mass_kg": 61.0, "comms": ["CAN", "RS485", "Wi-Fi"]})
	s["source"] = "estimate (Sol-Ark 15K: 12 kW AC, 19.5 kW PV, 3 MPPT, 275 A charge)"
	out.append(s)
	s = _mppt_box("epever_tracer_4210an", "EPEver Tracer 4210AN", "EPEver", "Tracer 4210AN", 190.0, 241.0, 66.0,
		[0.1, 0.18, 0.32], NEAR_BLACK, false,
		{"kind": "mppt", "system_v": 12, "max_voc": 100.0, "max_charge_a": 40.0, "max_pv_w": 1040.0, "max_input_a": 40.0,
		"cost": 150.0, "mass_kg": 1.9, "comms": ["RS485"]})
	s["source"] = "EPEver Tracer-AN data sheet (40 A, 100 V); size estimate"
	out.append(s)
	s = _pwm_box("renogy_wanderer_30", "Renogy Wanderer PWM 30A", "Renogy", "Wanderer 30A", 160.0, 102.0, 57.0,
		[0.1, 0.1, 0.11],
		{"kind": "pwm", "system_v": 12, "max_voc": 25.0, "max_charge_a": 30.0, "max_pv_w": 400.0, "max_input_a": 30.0,
		"cost": 35.0, "mass_kg": 0.3})
	s["source"] = "estimate (Renogy Wanderer 30 A PWM)"
	out.append(s)
	s = _car_inverter("car_inverter_1000", "Generic 1000 W inverter (12 V)", "Generic", "1000 W pure sine",
		260.0, 180.0, 75.0, ALU, [0.08, 0.08, 0.09], "pair",
		{"kind": "inverter", "system_v": 12, "max_voc": 0.0, "max_charge_a": 0.0, "max_pv_w": 0.0, "ac_out_w": 1000.0,
		"surge_w": 2000.0, "idle_w": 12.0, "cost": 140.0, "mass_kg": 2.6})
	s["source"] = "estimate (a generic 1 kW car-style pure-sine inverter)"
	out.append(s)
	s = _car_inverter("car_inverter_2000", "Generic 2000 W inverter (12 V)", "Generic", "2000 W pure sine",
		400.0, 240.0, 90.0, [0.18, 0.18, 0.2], [0.08, 0.08, 0.09], "duplex",
		{"kind": "inverter", "system_v": 12, "max_voc": 0.0, "max_charge_a": 0.0, "max_pv_w": 0.0, "ac_out_w": 2000.0,
		"surge_w": 4000.0, "idle_w": 18.0, "cost": 260.0, "mass_kg": 5.4})
	s["source"] = "estimate (a generic 2 kW car-style pure-sine inverter)"
	out.append(s)
	s = _car_inverter("aims_3000", "AIMS 3000 W inverter (12 V)", "AIMS Power", "PWRI300012120S", 549.0, 241.0, 97.0,
		[0.15, 0.35, 0.62], [0.12, 0.12, 0.13], "gfci",
		{"kind": "inverter", "system_v": 12, "max_voc": 0.0, "max_charge_a": 0.0, "max_pv_w": 0.0, "ac_out_w": 3000.0,
		"surge_w": 6000.0, "idle_w": 12.0, "eff": {"inverter": 0.90}, "cost": 549.0, "mass_kg": 7.3})
	s["source"] = "AIMS PWRI300012120S manual (May 2018): 3000 W, 6000 W surge, 21.6 × 9.5 × 3.8 in, 16 lb, 1 A no-load. About $549 US street"
	out.append(s)
	s = _victron_box("victron_multiplus_ii_48_5000", "Victron MultiPlus-II 48/5000/70-95", "MultiPlus-II 48 | 5000 | 70-95",
		330.0, 676.0, 164.0,
		{"kind": "inverter_charger", "system_v": 48, "max_voc": 0.0, "max_charge_a": 70.0, "max_pv_w": 0.0,
		"ac_out_w": 4000.0, "surge_w": 9000.0, "ac_in_a": 95.0, "ac_v": 120.0, "idle_w": 18.0, "eff": {"inverter": 0.96},
		"cost": 1114.0, "mass_kg": 32.0, "comms": ["VE.Bus"]}, true)
	s["source"] = "Victron MultiPlus-II 48/5000/70-95 120 V UL (PMP482505120): 5000 VA / 4000 W, 70 A charge, 95 A transfer, 9000 W peak, 676 × 330 × 164 mm, 32 kg. $1,114 is the 2026 Q4 USD list price, ex VAT"
	s["body"]["corner_r"] = 6.0
	out.append(s)
	s = _victron_mppt("victron_ss_150_60", "Victron SmartSolar 150/60", "MPPT 150 | 60", 250.0, 200.0, 95.0,
		{"kind": "mppt", "system_v": 48, "max_voc": 150.0, "max_charge_a": 60.0, "max_pv_w": 3440.0, "max_input_a": 35.0,
		"cost": 393.0, "mass_kg": 3.0, "comms": ["VE.Direct", "Bluetooth"]})
	s["source"] = "Victron SmartSolar MPPT 150/60-Tr: 200 × 250 × 95 mm, 3.0 kg, 150 V, 60 A. 3440 W is the 48 V array limit (860 W at 12 V, 1720 W at 24 V). $393 is the 2026 Q4 USD list price, ex VAT"
	out.append(s)
	s = _victron_mppt("victron_ss_150_85", "Victron SmartSolar 150/85", "MPPT 150 | 85", 295.0, 216.0, 103.0,
		{"kind": "mppt", "system_v": 48, "max_voc": 150.0, "max_charge_a": 85.0, "max_pv_w": 4900.0, "max_input_a": 70.0,
		"cost": 508.0, "mass_kg": 4.5, "comms": ["VE.Direct", "VE.Can", "Bluetooth"]}, true)
	s["source"] = "Victron SmartSolar MPPT 150/85-Tr VE.Can: 216 × 295 × 103 mm, 4.5 kg, 70 A PV. 4900 W is the 48 V array limit. $508 is the 2026 Q4 USD list price, ex VAT"
	out.append(s)
	s = _victron_mppt("victron_ss_250_70", "Victron SmartSolar 250/70", "MPPT 250 | 70", 250.0, 200.0, 95.0,
		{"kind": "mppt", "system_v": 48, "max_voc": 250.0, "max_charge_a": 70.0, "max_pv_w": 4000.0, "max_input_a": 35.0,
		"cost": 536.0, "mass_kg": 3.0, "comms": ["VE.Direct", "Bluetooth"]}, true)
	s["source"] = "Victron SmartSolar MPPT 250/70-Tr: 200 × 250 × 95 mm, 3.0 kg, 70 A. 4000 W is the 48 V array limit. $536 is the 2026 Q4 USD list price, ex VAT"
	out.append(s)
	s = _mppt_box("renogy_rover_60", "Renogy Rover 60A MPPT", "Renogy", "Rover 60A", 205.0, 285.0, 102.0,
		[0.12, 0.12, 0.13], ALU, true,
		{"kind": "mppt", "system_v": 48, "max_voc": 140.0, "max_charge_a": 60.0, "max_pv_w": 3200.0, "max_input_a": 60.0,
		"cost": 400.0, "mass_kg": 3.6, "comms": ["RS485", "Bluetooth"]})
	s["source"] = "Renogy Rover 60 A sheet: 285 × 205 × 102 mm, 3.6 kg, 140 V, 60 A. 3200 W is the 48 V limit (800 / 1600 / 2400 W at 12 / 24 / 36 V). $400 US street (2026)"
	out.append(s)
	s = _wall_hybrid("eg4_flexboss18", "EG4 FlexBOSS18", "FlexBOSS18", "EG4 Electronics", 566.0, 773.0, 285.0, "eg4",
		{"kind": "hybrid", "system_v": 48, "max_voc": 600.0, "max_charge_a": 208.0, "max_pv_w": 18000.0,
		"max_pv_w_per_mppt": 9000.0, "mppt_count": 2, "mppt_min_v": 120.0, "mppt_max_v": 440.0, "startup_v": 200.0,
		"max_input_a": 26.0, "max_isc_a": 31.0, "ac_out_w": 10000.0, "surge_w": 20000.0, "ac_in_a": 90.0,
		"split_phase": true, "ac_v": 240.0, "idle_w": 50.0, "cost": 3200.0, "mass_kg": 52.0,
		"comms": ["CAN", "RS485", "Wi-Fi"]})
	s["source"] = "EG4 FlexBOSS18 spec sheet v1.0.9: 566 × 773 × 285 mm, 52 kg, 10 kW from the battery (13 kW with PV), 18 kW PV on 2 MPPTs, 208 A charge, 90 A pass-through. $3,200 US street (2026). Idle is under 60 W"
	out.append(s)
	s = _wall_hybrid("ecoworthy_5000_48", "EcoWorthy 5000W 48V Hybrid", "ECO5000W(SR)", "EcoWorthy", 350.0, 447.0, 133.0, "ecoworthy",
		{"kind": "hybrid", "system_v": 48, "max_voc": 500.0, "max_charge_a": 100.0, "max_pv_w": 5500.0,
		"mppt_count": 2, "mppt_min_v": 120.0, "mppt_max_v": 450.0, "max_input_a": 22.0,
		"ac_out_w": 5000.0, "surge_w": 10000.0, "ac_in_a": 40.0, "ac_v": 120.0, "cost": 760.0, "mass_kg": 14.0,
		"comms": ["RS485", "USB", "Wi-Fi"]})
	s["source"] = "Eco-Worthy ECO5000W(SR) sheet: one unit is 120 V, 5 kW (10 kW peak), 5.5 kW PV, 2 MPPTs at 22 A, 100 A PV charge, 447 × 350 × 133 mm, 14 kg. Two units in parallel make 240 V. $760 on Eco-Worthy's site (2026)"
	out.append(s)
	s = _station("ecoflow_delta_2", "EcoFlow DELTA 2", "DELTA 2", "EcoFlow", 400.0, 281.0, 211.0,
		[0.5, 0.52, 0.55], "ECOFLOW", 6, 4, 2, "iec_c14",
		{"kind": "power_station", "system_v": 48, "pack_wh": 1024.0, "max_voc": 60.0, "mppt_min_v": 11.0,
		"mppt_max_v": 60.0, "max_charge_a": 15.0, "max_pv_w": 500.0, "max_input_a": 15.0,
		"ac_out_w": 1800.0, "surge_w": 2700.0, "ac_v": 120.0, "cost": 499.0, "mass_kg": 12.0,
		"comms": ["Wi-Fi", "Bluetooth"]})
	s["source"] = "EcoFlow DELTA 2 manual: 1,024 Wh, 1,800 W (2,700 W surge), solar 11–60 V at 15 A / 500 W, 400 × 281 × 211 mm, 12 kg. Last EcoFlow list about $499; still sold used and refurbished"
	out.append(s)
	s = _station("anker_f3800", "Anker SOLIX F3800", "SOLIX F3800", "Anker", 702.0, 395.0, 388.0,
		[0.14, 0.15, 0.16], "ANKER", 6, 2, 3, "iec_c20",
		{"kind": "power_station", "system_v": 48, "pack_wh": 3840.0, "max_voc": 60.0, "mppt_count": 2,
		"mppt_min_v": 11.0, "mppt_max_v": 60.0, "max_charge_a": 25.0, "max_pv_w": 2400.0,
		"max_pv_w_per_mppt": 1200.0, "max_input_a": 25.0, "ac_out_w": 6000.0, "surge_w": 9000.0,
		"ac_v": 120.0, "cost": 2200.0, "mass_kg": 60.0, "comms": ["Wi-Fi", "Bluetooth"]})
	s["source"] = "Anker SOLIX F3800: 3,840 Wh, 6,000 W (9,000 W surge), 120/240 V, solar 2 × 1,200 W at 25 A / 60 V. 702 × 395 × 388 mm with the wheels, 60 kg. $2,200 was the US list in October 2026"
	out.append(s)
	s = _station("bluetti_ac200l", "Bluetti AC200L", "AC200L", "Bluetti", 420.0, 367.0, 280.0,
		[0.12, 0.18, 0.28], "BLUETTI", 4, 2, 2, "iec_c20",
		{"kind": "power_station", "system_v": 48, "pack_wh": 2048.0, "max_voc": 145.0, "mppt_min_v": 12.0,
		"mppt_max_v": 145.0, "max_charge_a": 15.0, "max_pv_w": 1200.0, "max_input_a": 15.0,
		"ac_out_w": 2400.0, "surge_w": 3600.0, "ac_v": 120.0, "cost": 899.0, "mass_kg": 28.3,
		"comms": ["Wi-Fi", "Bluetooth"]})
	s["source"] = "Bluetti AC200L manual: 2,048 Wh, 2,400 W (3,600 W for 5 s), solar 12–145 V at 15 A / 1,200 W. 420 × 367 × 280 mm, 28.3 kg. The sheet's DC inlet is a 2-pin aviation plug, drawn here as XT60. About $899 on Bluetti's US page (2026); kits cost more"
	out.append(s)
	for x in out:
		x["elec"]["cost"] = float(x["elec"]["cost"])
	return out


## A portable all-in-one: a handled case, a screen, USB along the lower front,
## NEMA outlets on the back, a solar inlet on the right and an AC inlet on
## the left. `mppt_count` 2 draws a second solar inlet. The internal pack is
## `pack_wh` (shown on the card); there is no external battery terminal.
static func _station(id: String, name: String, model: String, maker: String, w: float, h: float, d: float,
		color: Array, word: String, ac_n: int, usb_a: int, usb_c: int, inlet: String, e: Dictionary) -> Dictionary:
	var s := _base(id, name, "power_station", w, h, d)
	s["maker"] = maker
	s["model"] = model
	s["body"]["color"] = color
	s["body"]["corner_r"] = minf(22.0, minf(w, h) * 0.06)
	s["body"]["edge_r"] = 10.0
	s["body"]["split"] = {"y": h * 0.28, "color": [0.12, 0.12, 0.13]}
	s["mount"] = {"style": "handles", "where": "top", "n": 2, "w": minf(120.0, w * 0.22), "h": 40.0,
		"color": [0.1, 0.1, 0.11]}
	var lcd_w := minf(110.0, w * 0.26)
	var ports: Array = [
		_p("lcd", "lcd", "front", -w * 0.22, h * 0.16, "ui", "Display",
			{"w": lcd_w, "h": minf(70.0, h * 0.26), "screen": [0.05, 0.06, 0.07]}),
		_p("power", "button", "front", -w * 0.22 + lcd_w * 0.72, h * 0.16, "ui", "Power",
			{"d": 14.0, "color": [0.85, 0.86, 0.88]}),
	]
	var usb_y := -h * 0.30
	var ux := -w * 0.34
	for i in usb_a:
		ports.append(_p("usb_a_%d" % i, "usb_a", "front", ux, usb_y, "usb", "USB-A"))
		ux += 20.0
	ux += 8.0
	for i in usb_c:
		ports.append(_p("usb_c_%d" % i, "usb_c", "front", ux, usb_y, "usb", "USB-C"))
		ux += 22.0
	var span := w * 0.72
	var step := span / float(maxi(ac_n - 1, 1))
	for i in ac_n:
		ports.append(_p("ac_%d" % i, "nema_5_20", "back", -span * 0.5 + step * float(i), h * 0.02, "ac_out",
			"AC out", {"color": [0.12, 0.12, 0.13]}))
	var trackers := maxi(int(e.get("mppt_count", 1)), 1)
	for m in trackers:
		ports.append(_p("pv_%d" % (m + 1), "xt60", "right", 0.0, -h * (0.08 + 0.16 * float(m)),
			"pv%d" % (m + 1), "Solar %d" % (m + 1)))
	ports.append(_p("ac_in", inlet, "left", 0.0, -h * 0.1, "ac_in", "AC charging"))
	s["ports"] = ports
	s["texts"] = [_t("front", w * 0.22, h * 0.28, word, minf(h * 0.055, 16.0), [0.9, 0.9, 0.9], true)]
	_elec(s, e)
	return s


static func _power_station() -> Dictionary:
	var s := _station("ecoflow_delta_pro", "EcoFlow DELTA Pro", "DELTA Pro", "EcoFlow", 635.0, 416.0, 285.0,
		[0.5, 0.52, 0.55], "ECOFLOW", 4, 4, 2, "iec_c20",
		{"kind": "power_station", "system_v": 48, "pack_wh": 3600.0, "max_voc": 150.0, "max_charge_a": 15.0,
		"max_pv_w": 1600.0, "max_input_a": 15.0, "ac_out_w": 3600.0, "surge_w": 7200.0, "ac_in_a": 15.0,
		"cost": 3000.0, "mass_kg": 45.0})
	s["library"] = "EcoFlow DELTA Pro"
	s["source"] = "EcoFlow DELTA Pro: 3,600 Wh, 3,600 W (7,200 W surge), 1,600 W PV. 635 × 416 × 285 mm, 45 kg. $3,000 is the library price"
	return s


static func _dc_dc() -> Dictionary:
	var s := _base("victron_orion_12_12_30", "Victron Orion-Tr Smart 12/12-30", "dc_dc", 130.0, 186.0, 80.0)
	s["maker"] = "Victron Energy"
	s["model"] = "Orion-Tr Smart 12/12-30"
	s["source"] = "Victron Orion-Tr Smart 12/12-30 isolated (130 × 186 × 80 mm, 1.8 kg). Drawn with the 186 mm side vertical. $246 is the 2026 Q4 USD list price, ex VAT"
	s["body"]["color"] = VICTRON
	s["body"]["corner_r"] = 8.0
	s["body"]["edge_r"] = 5.0
	s["mount"] = {"style": "flange", "where": "both", "n": 4, "w": 0.0, "h": 10.0, "color": [0.15, 0.15, 0.16]}
	s["bands"] = [{"y0": 186.0 * 0.43, "y1": 186.0 * 0.47, "color": V_ORANGE}]
	s["ports"] = [
		_p("terms", "power_terminal", "front", 0.0, -186.0 * 0.38, "", "IN / OUT",
			{"poles": 4, "pitch": 18.0, "color": [0.08, 0.08, 0.09], "labels": ["IN+", "IN−", "OUT+", "OUT−"]},
			["dcin+", "dcin-", "bat+", "bat-"]),
		_p("remote", "terminal_block", "front", 0.0, -186.0 * 0.24, "remote", "Remote", {"poles": 2, "labels": ["H", "L"]}),
	]
	s["texts"] = [_t("front", 0.0, 186.0 * 0.32, "victron energy", 9.0, WHITE, true),
		_t("front", 0.0, 186.0 * 0.12, "Orion-Tr Smart", 11.0, WHITE, true),
		_t("front", 0.0, 186.0 * 0.03, "12 | 12 - 30", 10.0, WHITE)]
	_elec(s, {"kind": "dc_dc", "system_v": 12, "max_voc": 0.0, "max_charge_a": 30.0, "max_pv_w": 0.0, "cost": 246.0,
		"mass_kg": 1.8})
	return s
