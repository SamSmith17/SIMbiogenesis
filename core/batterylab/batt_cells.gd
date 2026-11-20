class_name BattCells
extends RefCounted

## The cells (and lead-acid monoblocks) the Battery Lab builds packs from.
##
## Every number here is TRANSCRIBED from the maker's data sheet as remembered,
## not re-checked against the PDF; each entry's `est` lists the fields that are
## typical figures rather than data-sheet values, and `source` names the sheet.
## The selftest holds every entry to its own arithmetic (V × Ah = Wh) and to
## its chemistry's energy-density band, which catches typos, not wrong sheets.
##
## Shapes (mm):
##  - "cylindrical": `d_mm`, `h_mm` (height including the button).
##  - "prismatic" / "pouch" / "monoblock": `size_mm` = [x, y, z] = [width of
##    the terminal face, height incl. terminals, thickness]. A prismatic cell
##    stands with its terminals up; cells stack along z.
## Ratings: `ah` at the rated hours `rate_h` (lead: 20 h), `std_c` the
## standard charge rate, `charge_c` / `discharge_c` the continuous maxima,
## `peak_c` for `peak_s` seconds, `ir_mohm` AC internal resistance at 1 kHz.
## A monoblock carries `cells_inside` 2 V cells; its `nominal_v` is the block's.
## `compression_kgf`: the fixture force a prismatic LFP cell wants on its wide
## faces for its rated cycle life.

const FORMATS: Array = ["cylindrical", "prismatic", "pouch", "monoblock"]

const CELLS: Array = [
	# --- LFP prismatic (EVE and CALB) -------------------------------------
	{
		"id": "eve_lf280k", "label": "EVE LF280K 280 Ah", "maker": "EVE", "model": "LF280K",
		"chem": "LFP", "format": "prismatic", "size_mm": [173.7, 207.2, 71.7],
		"nominal_v": 3.2, "ah": 280.0, "rate_h": 2.0, "mass_kg": 5.49, "ir_mohm": 0.25,
		"std_c": 0.5, "charge_c": 1.0, "discharge_c": 1.0, "peak_c": 2.0, "peak_s": 30.0,
		"terminals": {"kind": "threaded", "size": "M6", "pitch_mm": 132.0},
		"compression_kgf": 300.0, "cycles": [[0.8, 6000]],
		"source": "EVE LF280K product specification",
		"est": ["peak_c", "pitch_mm", "compression_kgf"],
	},
	{
		"id": "eve_lf304", "label": "EVE LF304 304 Ah", "maker": "EVE", "model": "LF304",
		"chem": "LFP", "format": "prismatic", "size_mm": [173.7, 207.2, 71.7],
		"nominal_v": 3.2, "ah": 304.0, "rate_h": 2.0, "mass_kg": 5.50, "ir_mohm": 0.18,
		"std_c": 0.5, "charge_c": 1.0, "discharge_c": 1.0, "peak_c": 2.0, "peak_s": 30.0,
		"terminals": {"kind": "threaded", "size": "M6", "pitch_mm": 132.0},
		"compression_kgf": 300.0, "cycles": [[0.8, 6000]],
		"source": "EVE LF304 product specification",
		"est": ["mass_kg", "peak_c", "pitch_mm", "compression_kgf"],
	},
	{
		"id": "eve_mb31", "label": "EVE MB31 314 Ah", "maker": "EVE", "model": "MB31",
		"chem": "LFP", "format": "prismatic", "size_mm": [173.9, 207.0, 71.6],
		"nominal_v": 3.2, "ah": 314.0, "rate_h": 2.0, "mass_kg": 5.60, "ir_mohm": 0.18,
		"std_c": 0.5, "charge_c": 0.5, "discharge_c": 1.0, "peak_c": 2.0, "peak_s": 30.0,
		"terminals": {"kind": "threaded", "size": "M6", "pitch_mm": 132.0},
		"compression_kgf": 300.0, "cycles": [[0.8, 8000]],
		"source": "EVE MB31 product specification",
		"est": ["charge_c", "peak_c", "pitch_mm", "compression_kgf"],
	},
	{
		"id": "eve_lf230", "label": "EVE LF230 230 Ah", "maker": "EVE", "model": "LF230",
		"chem": "LFP", "format": "prismatic", "size_mm": [173.9, 207.2, 54.3],
		"nominal_v": 3.2, "ah": 230.0, "rate_h": 2.0, "mass_kg": 4.18, "ir_mohm": 0.25,
		"std_c": 0.5, "charge_c": 1.0, "discharge_c": 1.0, "peak_c": 2.0, "peak_s": 30.0,
		"terminals": {"kind": "threaded", "size": "M6", "pitch_mm": 132.0},
		"compression_kgf": 300.0, "cycles": [[0.8, 6000]],
		"source": "EVE LF230 product specification",
		"est": ["peak_c", "pitch_mm", "compression_kgf"],
	},
	{
		"id": "eve_lf105", "label": "EVE LF105 105 Ah", "maker": "EVE", "model": "LF105",
		"chem": "LFP", "format": "prismatic", "size_mm": [130.3, 200.5, 36.3],
		"nominal_v": 3.2, "ah": 105.0, "rate_h": 2.0, "mass_kg": 1.98, "ir_mohm": 0.5,
		"std_c": 0.5, "charge_c": 1.0, "discharge_c": 1.0, "peak_c": 2.0, "peak_s": 30.0,
		"terminals": {"kind": "threaded", "size": "M6", "pitch_mm": 90.0},
		"compression_kgf": 200.0, "cycles": [[0.8, 4000]],
		"source": "EVE LF105 product specification",
		"est": ["ir_mohm", "peak_c", "pitch_mm", "compression_kgf", "cycles"],
	},
	{
		"id": "eve_lf50k", "label": "EVE LF50K 50 Ah", "maker": "EVE", "model": "LF50K",
		"chem": "LFP", "format": "prismatic", "size_mm": [135.0, 185.0, 29.3],
		"nominal_v": 3.2, "ah": 50.0, "rate_h": 2.0, "mass_kg": 1.0, "ir_mohm": 0.8,
		"std_c": 0.5, "charge_c": 1.0, "discharge_c": 3.0, "peak_c": 5.0, "peak_s": 10.0,
		"terminals": {"kind": "threaded", "size": "M6", "pitch_mm": 95.0},
		"compression_kgf": 150.0, "cycles": [[0.8, 4000]],
		"source": "EVE LF50K product specification",
		"est": ["size_mm", "mass_kg", "ir_mohm", "discharge_c", "peak_c", "pitch_mm",
			"compression_kgf", "cycles"],
	},
	{
		"id": "calb_ca100", "label": "CALB CA100 100 Ah", "maker": "CALB", "model": "CA100FI",
		"chem": "LFP", "format": "prismatic", "size_mm": [142.0, 220.0, 67.0],
		"nominal_v": 3.2, "ah": 100.0, "rate_h": 3.0, "mass_kg": 3.2, "ir_mohm": 0.6,
		"std_c": 0.3, "charge_c": 1.0, "discharge_c": 2.0, "peak_c": 10.0, "peak_s": 10.0,
		"terminals": {"kind": "threaded", "size": "M8", "pitch_mm": 70.0},
		"compression_kgf": 0.0, "cycles": [[0.8, 2000]],
		"source": "CALB CA100FI data sheet (plastic-case cell)",
		"est": ["ir_mohm", "pitch_mm", "cycles"],
	},
	# --- LFP cylindrical ---------------------------------------------------
	{
		"id": "a123_anr26650", "label": "A123 ANR26650M1B 2.5 Ah", "maker": "A123 / Lithium Werks",
		"model": "ANR26650M1B", "chem": "LFP", "format": "cylindrical", "d_mm": 26.0, "h_mm": 65.0,
		"nominal_v": 3.3, "ah": 2.5, "rate_h": 1.0, "mass_kg": 0.076, "ir_mohm": 6.0,
		"std_c": 1.0, "charge_c": 4.0, "discharge_c": 20.0, "peak_c": 48.0, "peak_s": 10.0,
		"terminals": {"kind": "button"}, "compression_kgf": 0.0,
		"source": "Lithium Werks ANR26650M1B data sheet", "est": [],
	},
	{
		"id": "lfp_32700", "label": "32700 LFP 6 Ah", "maker": "Generic", "model": "IFR32700",
		"chem": "LFP", "format": "cylindrical", "d_mm": 32.0, "h_mm": 70.0,
		"nominal_v": 3.2, "ah": 6.0, "rate_h": 2.0, "mass_kg": 0.142, "ir_mohm": 8.0,
		"std_c": 0.5, "charge_c": 1.0, "discharge_c": 3.0, "peak_c": 5.0, "peak_s": 10.0,
		"terminals": {"kind": "button"}, "compression_kgf": 0.0,
		"source": "typical 32700 LFP cell (several makers)",
		"est": ["mass_kg", "ir_mohm", "charge_c", "discharge_c", "peak_c"],
	},
	# --- NMC cylindrical / pouch ------------------------------------------
	{
		"id": "samsung_30q", "label": "Samsung 30Q 18650 3.0 Ah", "maker": "Samsung SDI",
		"model": "INR18650-30Q", "chem": "NMC", "format": "cylindrical", "d_mm": 18.33, "h_mm": 65.0,
		"nominal_v": 3.6, "ah": 3.0, "rate_h": 5.0, "mass_kg": 0.048, "ir_mohm": 13.0,
		"std_c": 0.5, "charge_c": 1.33, "discharge_c": 5.0, "peak_c": 5.0, "peak_s": 60.0,
		"terminals": {"kind": "button"}, "compression_kgf": 0.0,
		"source": "Samsung SDI INR18650-30Q specification", "est": ["ir_mohm"],
	},
	{
		"id": "samsung_50e", "label": "Samsung 50E 21700 5.0 Ah", "maker": "Samsung SDI",
		"model": "INR21700-50E", "chem": "NMC", "format": "cylindrical", "d_mm": 21.25, "h_mm": 70.8,
		"nominal_v": 3.6, "ah": 5.0, "rate_h": 5.0, "mass_kg": 0.069, "ir_mohm": 14.0,
		"std_c": 0.3, "charge_c": 0.98, "discharge_c": 1.96, "peak_c": 1.96, "peak_s": 60.0,
		"terminals": {"kind": "button"}, "compression_kgf": 0.0,
		"source": "Samsung SDI INR21700-50E specification", "est": ["ir_mohm"],
	},
	{
		"id": "molicel_p42a", "label": "Molicel P42A 21700 4.2 Ah", "maker": "Molicel",
		"model": "INR-21700-P42A", "chem": "NMC", "format": "cylindrical", "d_mm": 21.7, "h_mm": 70.15,
		"nominal_v": 3.6, "ah": 4.2, "rate_h": 5.0, "mass_kg": 0.070, "ir_mohm": 15.0,
		"std_c": 1.0, "charge_c": 1.43, "discharge_c": 10.7, "peak_c": 10.7, "peak_s": 60.0,
		"terminals": {"kind": "button"}, "compression_kgf": 0.0,
		"source": "Molicel P42A product data sheet", "est": ["ir_mohm"],
	},
	{
		"id": "nca_4680", "label": "4680 NMC/NCA 23 Ah (automotive)", "maker": "Automotive",
		"model": "4680", "chem": "NMC", "format": "cylindrical", "d_mm": 46.0, "h_mm": 80.0,
		"nominal_v": 3.6, "ah": 23.0, "rate_h": 5.0, "mass_kg": 0.355, "ir_mohm": 2.5,
		"std_c": 0.5, "charge_c": 1.0, "discharge_c": 2.0, "peak_c": 4.0, "peak_s": 10.0,
		"terminals": {"kind": "button"}, "compression_kgf": 0.0,
		"source": "published teardown figures (no maker data sheet)",
		"est": ["ah", "mass_kg", "ir_mohm", "std_c", "charge_c", "discharge_c", "peak_c"],
	},
	{
		"id": "pouch_nmc_60", "label": "NMC pouch 60 Ah", "maker": "Generic", "model": "Pouch 60 Ah",
		"chem": "NMC", "format": "pouch", "size_mm": [300.0, 100.0, 13.0],
		"nominal_v": 3.6, "ah": 60.0, "rate_h": 3.0, "mass_kg": 0.9, "ir_mohm": 1.0,
		"std_c": 0.5, "charge_c": 1.0, "discharge_c": 2.0, "peak_c": 4.0, "peak_s": 10.0,
		"terminals": {"kind": "tab", "pitch_mm": 200.0}, "compression_kgf": 50.0,
		"source": "typical automotive / storage pouch cell",
		"est": ["size_mm", "mass_kg", "ir_mohm", "charge_c", "discharge_c", "peak_c",
			"compression_kgf"],
	},
	# --- Lead-acid monoblocks ----------------------------------------------
	{
		"id": "trojan_t105", "label": "Trojan T-105 6 V 225 Ah (flooded)", "maker": "Trojan",
		"model": "T-105", "chem": "FLA", "format": "monoblock", "size_mm": [264.0, 276.0, 181.0],
		"cells_inside": 3, "nominal_v": 6.0, "ah": 225.0, "rate_h": 20.0, "mass_kg": 28.0,
		"ir_mohm": 2.5, "std_c": 0.1, "charge_c": 0.2, "discharge_c": 1.0, "peak_c": 3.0,
		"peak_s": 30.0, "terminals": {"kind": "post", "size": "DT", "pitch_mm": 195.0},
		"compression_kgf": 0.0, "group": "GC2",
		"source": "Trojan T-105 data sheet",
		"est": ["ir_mohm", "discharge_c", "peak_c", "pitch_mm"],
	},
	{
		"id": "trojan_l16re_b", "label": "Trojan L16RE-B 6 V 370 Ah (flooded)", "maker": "Trojan",
		"model": "L16RE-B", "chem": "FLA", "format": "monoblock", "size_mm": [295.0, 406.0, 178.0],
		"cells_inside": 3, "nominal_v": 6.0, "ah": 370.0, "rate_h": 20.0, "mass_kg": 52.0,
		"ir_mohm": 2.0, "std_c": 0.1, "charge_c": 0.2, "discharge_c": 1.0, "peak_c": 3.0,
		"peak_s": 30.0, "terminals": {"kind": "post", "size": "LT", "pitch_mm": 230.0},
		"compression_kgf": 0.0, "group": "L16",
		"source": "Trojan L16RE-B data sheet",
		"est": ["size_mm", "ir_mohm", "discharge_c", "peak_c", "pitch_mm"],
	},
	{
		"id": "agm_gc2_220", "label": "AGM GC2 6 V 220 Ah", "maker": "Lifeline", "model": "GPL-4CT",
		"chem": "AGM", "format": "monoblock", "size_mm": [264.0, 283.0, 181.0],
		"cells_inside": 3, "nominal_v": 6.0, "ah": 220.0, "rate_h": 20.0, "mass_kg": 30.4,
		"ir_mohm": 2.0, "std_c": 0.2, "charge_c": 0.3, "discharge_c": 1.0, "peak_c": 4.0,
		"peak_s": 30.0, "terminals": {"kind": "post", "size": "M8", "pitch_mm": 195.0},
		"compression_kgf": 0.0, "group": "GC2",
		"source": "Lifeline GPL-4CT data sheet",
		"est": ["ir_mohm", "charge_c", "discharge_c", "peak_c", "pitch_mm"],
	},
	{
		"id": "agm_g31_100", "label": "AGM Group 31 12 V 100 Ah", "maker": "Generic",
		"model": "Group 31 AGM", "chem": "AGM", "format": "monoblock", "size_mm": [330.0, 240.0, 173.0],
		"cells_inside": 6, "nominal_v": 12.0, "ah": 100.0, "rate_h": 20.0, "mass_kg": 30.8,
		"ir_mohm": 4.0, "std_c": 0.2, "charge_c": 0.3, "discharge_c": 1.0, "peak_c": 8.0,
		"peak_s": 5.0, "terminals": {"kind": "post", "size": "M8", "pitch_mm": 250.0},
		"compression_kgf": 0.0, "group": "31",
		"source": "BCI group 31 case; typical 100 Ah AGM (VMAX / Renogy class)",
		"est": ["mass_kg", "ir_mohm", "charge_c", "discharge_c", "peak_c", "pitch_mm"],
	},
	{
		"id": "agm_g24_75", "label": "AGM Group 24 12 V 75 Ah", "maker": "Generic",
		"model": "Group 24 AGM", "chem": "AGM", "format": "monoblock", "size_mm": [260.0, 225.0, 173.0],
		"cells_inside": 6, "nominal_v": 12.0, "ah": 75.0, "rate_h": 20.0, "mass_kg": 22.0,
		"ir_mohm": 5.0, "std_c": 0.2, "charge_c": 0.3, "discharge_c": 1.0, "peak_c": 8.0,
		"peak_s": 5.0, "terminals": {"kind": "post", "size": "M8", "pitch_mm": 200.0},
		"compression_kgf": 0.0, "group": "24",
		"source": "BCI group 24 case; typical 75 Ah AGM",
		"est": ["mass_kg", "ir_mohm", "charge_c", "discharge_c", "peak_c", "pitch_mm"],
	},
	{
		"id": "agm_8d_255", "label": "AGM 8D 12 V 255 Ah", "maker": "Lifeline", "model": "GPL-8DL",
		"chem": "AGM", "format": "monoblock", "size_mm": [527.0, 254.0, 279.0],
		"cells_inside": 6, "nominal_v": 12.0, "ah": 255.0, "rate_h": 20.0, "mass_kg": 73.0,
		"ir_mohm": 2.0, "std_c": 0.2, "charge_c": 0.3, "discharge_c": 1.0, "peak_c": 5.0,
		"peak_s": 30.0, "terminals": {"kind": "post", "size": "M8", "pitch_mm": 420.0},
		"compression_kgf": 0.0, "group": "8D",
		"source": "Lifeline GPL-8DL data sheet",
		"est": ["ir_mohm", "charge_c", "discharge_c", "peak_c", "pitch_mm"],
	},
	{
		"id": "gel_12v_110", "label": "Gel 12 V 110 Ah", "maker": "Victron", "model": "Gel Deep Cycle 110 Ah",
		"chem": "GEL", "format": "monoblock", "size_mm": [330.0, 220.0, 171.0],
		"cells_inside": 6, "nominal_v": 12.0, "ah": 110.0, "rate_h": 20.0, "mass_kg": 33.0,
		"ir_mohm": 4.5, "std_c": 0.15, "charge_c": 0.2, "discharge_c": 1.0, "peak_c": 5.0,
		"peak_s": 5.0, "terminals": {"kind": "post", "size": "M8", "pitch_mm": 250.0},
		"compression_kgf": 0.0, "group": "31",
		"source": "Victron gel deep cycle battery data sheet",
		"est": ["ir_mohm", "discharge_c", "peak_c", "pitch_mm"],
	},
	{
		"id": "yuasa_np12_12", "label": "Yuasa NP12-12 12 V 12 Ah (SLA)", "maker": "Yuasa",
		"model": "NP12-12", "chem": "SLA", "format": "monoblock", "size_mm": [151.0, 97.5, 98.0],
		"cells_inside": 6, "nominal_v": 12.0, "ah": 12.0, "rate_h": 20.0, "mass_kg": 4.05,
		"ir_mohm": 14.0, "std_c": 0.1, "charge_c": 0.25, "discharge_c": 1.0, "peak_c": 10.0,
		"peak_s": 5.0, "terminals": {"kind": "tab", "size": "F2", "pitch_mm": 120.0},
		"compression_kgf": 0.0, "group": "",
		"source": "Yuasa NP12-12 data sheet", "est": ["ir_mohm", "pitch_mm"],
	},
]

static var _by_id: Dictionary = {}


static func _index() -> void:
	if not _by_id.is_empty():
		return
	for c in CELLS:
		_by_id[str((c as Dictionary)["id"])] = c


static func has(id: String) -> bool:
	_index()
	return _by_id.has(id)


## A cell by id ({} when unknown). The returned dict is shared: copy before
## changing it.
static func get_cell(id: String) -> Dictionary:
	_index()
	return _by_id.get(id, {}) as Dictionary


static func ids() -> Array:
	var out: Array = []
	for c in CELLS:
		out.append(str((c as Dictionary)["id"]))
	return out


static func by_chem(chem: String) -> Array:
	var out: Array = []
	for c in CELLS:
		if str((c as Dictionary)["chem"]) == chem:
			out.append(c)
	return out


static func by_format(fmt: String) -> Array:
	var out: Array = []
	for c in CELLS:
		if str((c as Dictionary)["format"]) == fmt:
			out.append(c)
	return out


## Words in `query` all found in a cell's label, maker, model, chemistry or
## format (the solar designer's search rule).
static func search(query: String) -> Array:
	var words := query.to_lower().split(" ", false)
	var out: Array = []
	for c in CELLS:
		var d: Dictionary = c
		var hay := ("%s %s %s %s %s" % [d["label"], d["maker"], d["model"], d["chem"],
				d["format"]]).to_lower()
		var all := true
		for w in words:
			if not hay.contains(w):
				all = false
				break
		if all:
			out.append(c)
	return out


static func wh(cell: Dictionary) -> float:
	return float(cell.get("nominal_v", 0.0)) * float(cell.get("ah", 0.0))


## Outer box of a cell in mm, [x, y, z] (y up). A cylinder's box is d × h × d.
static func box_mm(cell: Dictionary) -> Vector3:
	if str(cell.get("format", "")) == "cylindrical":
		var d := float(cell.get("d_mm", 0.0))
		return Vector3(d, float(cell.get("h_mm", 0.0)), d)
	var s: Array = cell.get("size_mm", [0.0, 0.0, 0.0]) as Array
	return Vector3(float(s[0]), float(s[1]), float(s[2]))


## The cell's own volume in litres (a cylinder's, not its box's).
static func volume_l(cell: Dictionary) -> float:
	if str(cell.get("format", "")) == "cylindrical":
		var r := float(cell.get("d_mm", 0.0)) * 0.5
		return PI * r * r * float(cell.get("h_mm", 0.0)) * 1e-6
	var b := box_mm(cell)
	return b.x * b.y * b.z * 1e-6


static func wh_per_kg(cell: Dictionary) -> float:
	var m := float(cell.get("mass_kg", 0.0))
	return 0.0 if m <= 0.0 else wh(cell) / m


static func wh_per_l(cell: Dictionary) -> float:
	var v := volume_l(cell)
	return 0.0 if v <= 0.0 else wh(cell) / v


static func max_charge_a(cell: Dictionary) -> float:
	return float(cell.get("charge_c", 0.0)) * float(cell.get("ah", 0.0))


static func max_discharge_a(cell: Dictionary) -> float:
	return float(cell.get("discharge_c", 0.0)) * float(cell.get("ah", 0.0))


static func peak_a(cell: Dictionary) -> float:
	return float(cell.get("peak_c", 0.0)) * float(cell.get("ah", 0.0))


## Electrochemical cells in series inside one unit (a 12 V monoblock: 6).
static func cells_inside(cell: Dictionary) -> int:
	return int(cell.get("cells_inside", 1))


## Voltage of the unit at a chemistry voltage per cell (charge, OCV …).
static func unit_v(cell: Dictionary, per_cell_v: float) -> float:
	return per_cell_v * float(cells_inside(cell))


## Cycle life at a DoD: the cell's own figure where it gives one at that
## DoD, scaled along its chemistry's curve otherwise.
static func cycles_at_dod(cell: Dictionary, dod: float) -> float:
	var chem := str(cell.get("chem", ""))
	var own: Array = cell.get("cycles", []) as Array
	if own.is_empty():
		return BattChem.cycles_at_dod(chem, dod)
	var p: Array = own[0]
	var base := BattChem.cycles_at_dod(chem, float(p[0]))
	if base <= 0.0:
		return float(p[1])
	return BattChem.cycles_at_dod(chem, dod) * float(p[1]) / base
