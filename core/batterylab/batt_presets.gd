class_name BattPresets
extends RefCounted

## Built-in battery designs, each built FROM ITS CELLS so its numbers come out
## of the design. They match the batteries in the graph library
## (`library_label` = ComponentPresets.BATTERIES' label) and the common
## forms: drop-ins, lead-acid blocks, server-rack packs, wall and rolling
## units, a DIY prismatic box and a DIY cylindrical pack.
##
## Real products are named by class ("EG4 200 Ah class"), not as copies: the
## cells and BMSs are catalog entries transcribed from data sheets, not
## teardowns of those products. A named product whose cell is the nearest
## catalog cell says so in its blurb.
##
## `price_usd` is the shopping price on the preset card. A cited list or
## dealer price is named in the blurb. A class build with no single SKU uses
## a typical 2026 US street price for that class.

const LIBRARY_FILE := "user://batterylab_library.json"


static func _spec(name: String, form: String, cell: String, s: int, p: int,
		extra: Dictionary = {}) -> Dictionary:
	var sp := BattSpec.empty(name)
	sp["form"] = form
	sp["cell_id"] = cell
	sp["series"] = s
	sp["parallel"] = p
	BattSpec._merge(sp, extra)
	return sp


static func builtins() -> Array:
	return [
		{"id": "dropin_12v_105", "label": "12 V 105 Ah LFP drop-in (group 31)",
			"library_label": "12V 100Ah LiFePO4", "price_usd": 349.0,
			"blurb": "Four 105 Ah prismatic cells in a group-31 case: a lead-acid replacement for vans and boats. About $349, a typical 2026 US street price for a no-name 12 V 100 Ah class pack.",
			"spec": _spec("12 V 105 Ah LFP drop-in", "automotive", "eve_lf105", 4, 1,
				{"enclosure": {"group": "31"}, "compression": {"on": false}, "bms": {"id": "builtin_dropin_100"}})},
		{"id": "dropin_12v_210", "label": "12 V 210 Ah LFP drop-in (8D)",
			"library_label": "12V 200Ah LiFePO4", "price_usd": 599.0,
			"blurb": "Two strings of four 105 Ah cells in parallel (4S2P) in an 8D case. About $599, typical 2026 US street for a 12 V 200 Ah class pack.",
			"spec": _spec("12 V 210 Ah LFP drop-in", "automotive", "eve_lf105", 4, 2,
				{"enclosure": {"group": "8D"}, "compression": {"on": false},
					"bms": {"id": "jbd_4s_100a"}})},
		{"id": "agm_12v_100", "label": "12 V 100 Ah AGM (group 31)",
			"library_label": "12V 100Ah AGM", "price_usd": 249.0,
			"blurb": "One sealed AGM block: six 2 V cells in series inside the case. About $249, typical 2026 US street for a group-31 100 Ah AGM (VMAX / Renogy class).",
			"spec": _spec("12 V 100 Ah AGM", "automotive", "agm_g31_100", 1, 1)},
		{"id": "fla_6v_225", "label": "Trojan T-105 (6 V 225 Ah)",
			"library_label": "", "price_usd": 189.0,
			"blurb": "Trojan T-105: three flooded cells, vent caps, top up with water. About $189 at a US dealer in 2026.",
			"spec": _spec("Trojan T-105", "automotive", "trojan_t105", 1, 1,
				{"enclosure": {"group": "GC2"}})},
		{"id": "rack_48v_105", "label": "48 V 105 Ah server-rack pack",
			"library_label": "Server Rack 48V 100Ah", "price_usd": 1099.0,
			"blurb": "Sixteen 105 Ah cells in series (16S) in a 19\" rack case with a breaker, display and CAN / RS485. About $1,099, typical 2026 US street for a generic 48 V 100 Ah rack battery.",
			"spec": _spec("48 V 105 Ah rack pack", "rack", "eve_lf105", 16, 1,
				{"bms": {"id": "builtin_rack_100"}})},
		{"id": "rack_48v_50", "label": "48 V 50 Ah server-rack pack",
			"library_label": "48V 50Ah LiFePO4", "price_usd": 549.0,
			"blurb": "A short 16S pack of 50 Ah cells: a 2.5 kWh starter rack battery. About $549, typical 2026 US street.",
			"spec": _spec("48 V 50 Ah rack pack", "rack", "eve_lf50k", 16, 1,
				{"bms": {"id": "builtin_rack_100"}})},
		{"id": "rack_48v_230", "label": "48 V 230 Ah rack pack (EG4 200 Ah class)",
			"library_label": "EG4 48V 200Ah", "price_usd": 2199.0,
			"blurb": "Sixteen 230 Ah cells, 11.8 kWh, a 200 A BMS. About $2,199, typical 2026 US street for an EG4-class 48 V 200 Ah rack battery.",
			"spec": _spec("48 V 230 Ah rack pack", "rack", "eve_lf230", 16, 1,
				{"bms": {"id": "builtin_rack_200"}})},
		{"id": "wall_48v_314", "label": "48 V 314 Ah wall-mount (16 kWh)",
			"library_label": "", "price_usd": 3399.0,
			"blurb": "Sixteen 314 Ah cells upright on the wall: 16 kWh in a shallow cabinet. About $3,399, typical 2026 US street for a 16 kWh wall battery.",
			"spec": _spec("48 V 314 Ah wall-mount", "wall", "eve_mb31", 16, 1,
				{"bms": {"id": "builtin_rack_200"}})},
		{"id": "rolling_48v_314", "label": "48 V 314 Ah rolling unit (16 kWh)",
			"library_label": "", "price_usd": 3799.0,
			"blurb": "The same 16 kWh on casters with a handle, to wheel where it is needed. About $3,799, typical 2026 US street.",
			"spec": _spec("48 V 314 Ah rolling", "rolling", "eve_mb31", 16, 1,
				{"bms": {"id": "builtin_rack_200"}, "enclosure": {"wheels": true}})},
		{"id": "diy_16s_280", "label": "YIXIANG DIY V3 16S 280 Ah",
			"library_label": "", "price_usd": 1650.0,
			"blurb": "YIXIANG V3 stacked kit: two rows of prismatic cells, green series boards and orange flexible busbars in a black steel case, with the P+ / P− panel and a Jikong BMS the manual configures. The kit is sold for 280–320 Ah; this one is sixteen 280 Ah cells. About $1,650 in cells, BMS and the case.",
			"spec": _spec("YIXIANG V3 16S 280 Ah", "diy", "eve_lf280k", 16, 1,
				{"bms": {"id": "jk_pb2a16s20p"}, "enclosure": {"material": "steel"}})},
		{"id": "diy_13s4p_21700", "label": "DIY 13S4P 21700 NMC pack",
			"library_label": "", "price_usd": 280.0,
			"blurb": "Fifty-two 21700 cells in holders with nickel strip: a 48 V e-bike or tool pack. About $280 in cells and a small BMS.",
			"spec": _spec("DIY 13S4P 21700", "diy", "samsung_50e", 13, 4,
				{"bms": {"id": "jbd_16s_100a"}})},
		{"id": "eg4_lifepower4", "label": "EG4 LifePower4 48 V rack",
			"library_label": "", "price_usd": 1495.0,
			"blurb": "EG4 LifePower4 v2 is 51.2 V, 100 Ah, 5.12 kWh, 100 A BMS, 45.2 kg, 155 × 442 × 470 mm, about $1,495 at a dealer (2026). Drawn as sixteen 105 Ah cells in a 4U rack, the closest catalog cell, so the card reads 105 Ah.",
			"spec": _spec("EG4 LifePower4 48 V", "rack", "eve_lf105", 16, 1,
				{"bms": {"id": "builtin_rack_100"}, "colors": {"case": [0.12, 0.12, 0.13]}})},
		{"id": "eg4_wall_280", "label": "EG4 WallMount Indoor 280 Ah",
			"library_label": "", "price_usd": 2700.0,
			"blurb": "EG4 WallMount Indoor 280 Ah: 51.2 V, 280 Ah, 14.3 kWh, 140 A continuous (200 A for 30 min), 130 kg, 865 × 460 × 264 mm. $2,700 at US dealers in November 2026. Sixteen EVE LF280K cells and that BMS.",
			"spec": _spec("EG4 WallMount Indoor 280 Ah", "wall", "eve_lf280k", 16, 1,
				{"bms": {"id": "eg4_wall_140"}, "colors": {"case": [0.14, 0.14, 0.15]}})},
		{"id": "victron_superpack_100", "label": "Victron SuperPack 12.8/100",
			"library_label": "", "price_usd": 572.0,
			"blurb": "Victron Lithium SuperPack 12.8/100 (2026 Q4 list): 12.8 V 100 Ah, 14 kg, 330 × 172 × 220 mm, $572 ex VAT. Drawn as four 105 Ah cells in a group-31 case, the nearest catalog build, so the card reads 105 Ah and the case is 20 mm taller.",
			"spec": _spec("Victron SuperPack 12.8/100", "automotive", "eve_lf105", 4, 1,
				{"enclosure": {"group": "31"}, "compression": {"on": false},
					"bms": {"id": "builtin_dropin_100"}, "colors": {"case": [0.16, 0.50, 0.84]}})},
		{"id": "victron_superpack_200", "label": "Victron SuperPack 12.8/200",
			"library_label": "", "price_usd": 1008.0,
			"blurb": "Victron Lithium SuperPack 12.8/200 (2026 Q4 list): 12.8 V 200 Ah, 21 kg, 520 × 269 × 208 mm, $1,008 ex VAT. Drawn as 4S2P of 105 Ah cells in an 8D case, so the card reads 210 Ah.",
			"spec": _spec("Victron SuperPack 12.8/200", "automotive", "eve_lf105", 4, 2,
				{"enclosure": {"group": "8D"}, "compression": {"on": false},
					"bms": {"id": "jbd_4s_100a"}, "colors": {"case": [0.16, 0.50, 0.84]}})},
		{"id": "renogy_core_100", "label": "Renogy Core 12.8 V 100 Ah",
			"library_label": "", "price_usd": 450.0,
			"blurb": "Renogy Core RBT12100LFP (manual, May 2024): 12.8 V, 100 Ah, 100 A continuous, 300 A for 10 s, 10.5 kg, 260 × 169 × 211 mm. Renogy lists it at $450; refurbished units were about $295 in November 2026. Drawn as four 105 Ah cells in a group-31 case, so the card reads 105 Ah and the case is the group-31 mould.",
			"spec": _spec("Renogy Core 12.8/100", "automotive", "eve_lf105", 4, 1,
				{"enclosure": {"group": "31"}, "compression": {"on": false},
					"bms": {"id": "builtin_dropin_100"}, "colors": {"case": [0.10, 0.10, 0.11]}})},
		{"id": "eg4_ll_s_100", "label": "EG4 LL-S 48 V 100 Ah rack",
			"library_label": "", "price_usd": 1537.0,
			"blurb": "EG4 LL-S (manual v2.3.3): 51.2 V, 100 Ah, 5.12 kWh, 100 A continuous, 45.2 kg, 155 × 442 × 490 mm. $1,537 at Signature Solar and several US dealers in November 2026. Drawn as sixteen 105 Ah cells in a rack, so the card reads 105 Ah.",
			"spec": _spec("EG4 LL-S 48 V", "rack", "eve_lf105", 16, 1,
				{"bms": {"id": "builtin_rack_100"}, "colors": {"case": [0.08, 0.08, 0.09]}})},
		{"id": "growatt_ark_25", "label": "Growatt ARK 2.5L-A1",
			"library_label": "", "price_usd": 650.0,
			"blurb": "Growatt ARK 2.5L-A1: 51.2 V, 50 Ah, 2.56 kWh, 25 A rated (48 A max), 28 kg, 650 × 260 × 185 mm, wall or floor. Sixteen 50 Ah cells, so the card matches the nameplate. About $650 (the €595 Dutch street price in 2026); US dealers vary.",
			"spec": _spec("Growatt ARK 2.5L-A1", "wall", "eve_lf50k", 16, 1,
				{"bms": {"id": "growatt_ark_25"}, "colors": {"case": [0.16, 0.22, 0.14]}})},
		{"id": "powmr_wall_100", "label": "PowMr 51.2 V 100 Ah wall",
			"library_label": "", "price_usd": 781.0,
			"blurb": "PowMr POW-LIO48100-16S manual: 51.2 V, 100 Ah, 5.12 kWh, 100 A, 44 kg, 550 × 470 × 202 mm. $781 is the PowMr sale price in November 2026 (list $1,499). Drawn as sixteen 105 Ah cells, so the card reads 105 Ah.",
			"spec": _spec("PowMr POW-LIO48100", "wall", "eve_lf105", 16, 1,
				{"bms": {"id": "builtin_rack_100"}, "colors": {"case": [0.32, 0.33, 0.34]}})},
		{"id": "ecoworthy_cubix100", "label": "EcoWorthy Cubix100 rack",
			"library_label": "", "price_usd": 860.0,
			"blurb": "Eco-Worthy Cubix100: 51.2 V, 100 Ah, 5.12 kWh, 100 A continuous, 47 kg, 143 × 483 × 561 mm. $860 on Amazon in November 2026 (list $1,000). Drawn as sixteen 105 Ah cells in a rack, so the card reads 105 Ah.",
			"spec": _spec("EcoWorthy Cubix100", "rack", "eve_lf105", 16, 1,
				{"bms": {"id": "builtin_rack_100"}, "colors": {"case": [0.90, 0.91, 0.92]}})},
	]


static func builtin(id: String) -> Dictionary:
	for b in builtins():
		if str((b as Dictionary)["id"]) == id:
			return ((b as Dictionary)["spec"] as Dictionary).duplicate(true)
	return {}


## The built-in that stands for a graph library preset ({} when none).
static func for_library_label(label: String) -> Dictionary:
	for b in builtins():
		if str((b as Dictionary)["library_label"]) == label:
			return b
	return {}


# ---------------------------------------------------------------------------
# The player's library (every world)
# ---------------------------------------------------------------------------

static func load_library(path: String = LIBRARY_FILE) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var v: Variant = JSON.parse_string(f.get_as_text())
	if v is Dictionary and (v as Dictionary).get("designs") is Dictionary:
		return v["designs"]
	return {}


## The bank fields (series, parallel, mount, bus, fuse …) saved with each
## design, by id; {} for a design saved before banks were kept.
static func load_library_banks(path: String = LIBRARY_FILE) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var v: Variant = JSON.parse_string(f.get_as_text())
	if v is Dictionary and (v as Dictionary).get("banks") is Dictionary:
		return v["banks"]
	return {}


## Save a design (and, when given, the bank round it: everything but the
## pack) under `id`. Designs saved before banks were kept are unchanged.
static func save_to_library(id: String, spec: Dictionary, path: String = LIBRARY_FILE, bank: Dictionary = {}) -> bool:
	var lib := load_library(path)
	var banks := load_library_banks(path)
	lib[id] = BattSpec.resolve(spec)
	if not bank.is_empty():
		var b := bank.duplicate(true)
		b.erase("pack")
		banks[id] = b
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({"designs": lib, "banks": banks}, "\t"))
	return true


static func forget(id: String, path: String = LIBRARY_FILE) -> void:
	var lib := load_library(path)
	var banks := load_library_banks(path)
	if not lib.has(id) and not banks.has(id):
		return
	lib.erase(id)
	banks.erase(id)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"designs": lib, "banks": banks}, "\t"))


## "51.2 V · 105 Ah · 5.4 kWh" for a gallery row.
static func size_line(spec: Dictionary) -> String:
	return str(shop_facts(spec)["detail"])


## Price, $/kWh and the size line for one pack. A positive `price_usd` is the
## street price; 0 uses the design's parts estimate and is marked `about`.
## `per_kwh` is that price divided by the nameplate kilowatt-hours.
static func shop_facts(spec: Dictionary, price_usd: float = 0.0) -> Dictionary:
	var d := BattDesign.solve(spec)
	var e: Dictionary = d["electrical"]
	var kwh := float(e["wh"]) * 0.001
	var listed := price_usd > 0.0
	var usd := price_usd if listed else float(d["cost_usd"])
	var per := usd / maxf(kwh, 1e-9)
	var dollars := "$%s" % UiText.thousands(int(round(usd))) if usd > 0.0 else ""
	if not listed and usd > 0.0:
		dollars = "about " + dollars
	return {
		"usd": usd, "per_kwh": per, "kwh": kwh, "about": not listed and usd > 0.0,
		"price": dollars,
		"per": ("$%s/kWh" % UiText.thousands(int(round(per)))) if usd > 0.0 else "",
		"detail": "%.1f V · %.0f Ah · %.1f kWh" % [float(e["v_nom"]), float(e["ah"]), kwh],
	}


## One line: "$1,495 · $278/kWh · 51.2 V · 105 Ah · 5.4 kWh".
static func shop_line(spec: Dictionary, price_usd: float = 0.0) -> String:
	var f := shop_facts(spec, price_usd)
	if float(f["usd"]) <= 0.0:
		return str(f["detail"])
	return "%s · %s · %s" % [f["price"], f["per"], f["detail"]]
