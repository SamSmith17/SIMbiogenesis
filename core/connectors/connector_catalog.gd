class_name ConnectorCatalog
extends RefCounted

## The connector and terminal standards every designer can put on a unit:
## solar (MC4, H4), DC power (Powerpole, SB, XT, SAE, barrel, studs, lugs,
## fuses), mains (NEMA, Schuko, BS 1363, AS/NZS, IEC inlets, hard-wire
## blocks), data and I/O (RJ45, USB, DB9, VE.Direct, screw-terminal strips),
## wiring-bay parts (DIN rail, miniature breakers, N / PE bus bars) and
## enclosure fittings (glands, knockouts, ground lugs) plus front-panel bits
## (LED, LCD, button, DIP switch).
##
## Pure data. ConnectorParts draws them. Every entry is in a LOCAL frame in
## millimetres: the panel surface is z = 0, +Z points out of the panel (the
## way a mating plug comes in), +Y is up, +X is right. Parts behind the panel
## sit at z < 0. `body` is the size proud of the panel (w across, h up, d out).
##
## Ratings are the makers' published figures where a source is named, else
## "estimate". A connector's rating is what it carries continuously.

const DOMAINS := ["pv", "dc", "ac", "data", "io", "ground", "protection", "fitting", "ui"]
const DOMAIN_LABELS := {
	"pv": "Solar", "dc": "DC power", "ac": "AC mains", "data": "Data", "io": "Signals & I/O",
	"ground": "Ground", "protection": "Breakers & fuses", "fitting": "Enclosure fittings", "ui": "Front panel",
}
## A diagram colour per domain (dark-surface safe).
const DOMAIN_COLORS := {
	"pv": Color(0.96, 0.62, 0.18), "dc": Color(0.9, 0.3, 0.28), "ac": Color(0.95, 0.82, 0.3),
	"data": Color(0.35, 0.62, 0.98), "io": Color(0.3, 0.8, 0.74), "ground": Color(0.35, 0.78, 0.38),
	"protection": Color(0.55, 0.6, 0.95), "fitting": Color(0.62, 0.64, 0.68), "ui": Color(0.85, 0.86, 0.9),
}

const C_BLACK := Color(0.05, 0.05, 0.055)
const C_RED := Color(0.78, 0.09, 0.08)
const C_WHITE := Color(0.9, 0.9, 0.88)
const C_GREY := Color(0.55, 0.56, 0.58)
const C_BRASS := Color(0.84, 0.66, 0.36)
const C_STEEL := Color(0.74, 0.75, 0.77)
const C_ZINC := Color(0.66, 0.68, 0.7)
const C_GREEN_TB := Color(0.12, 0.45, 0.22)

## id → entry. `shape` picks the drawing in ConnectorParts. `pins` lists the
## places a wire lands, [id, label, role, pos, dir] (local mm, dir = the way
## the wire leaves). Parametric entries (poles, rating, length) take `opts`
## through resolve(), which fills their pins.
const ENTRIES := {
	# --- Solar -------------------------------------------------------------
	"mc4_panel": {"label": "MC4 bulkhead", "family": "MC4", "domain": "pv", "shape": "mc4", "mount": "panel",
		"body": Vector3(22, 22, 30), "rating": {"amps": 30.0, "volts": 1000.0},
		"source": "Stäubli MC4 PV-KBT4/KST4 data sheet (30 A, 1000 V IEC)",
		"opts": {"sex": "female", "evo": false}, "mates_with": ["mc4_inline"],
		"pins": [["w", "Wire", "", Vector3(0, 0, -22), Vector3(0, 0, -1)]]},
	"mc4_inline": {"label": "MC4 cable connector", "family": "MC4", "domain": "pv", "shape": "mc4", "mount": "inline",
		"body": Vector3(16, 16, 58), "rating": {"amps": 30.0, "volts": 1000.0},
		"source": "Stäubli MC4 data sheet", "opts": {"sex": "male", "evo": false}, "mates_with": ["mc4_panel", "mc4_inline"],
		"pins": [["w", "Cable", "", Vector3(0, 0, 0), Vector3(0, 0, -1)]]},
	"mc4_evo2_panel": {"label": "MC4-Evo 2 bulkhead", "family": "MC4", "domain": "pv", "shape": "mc4", "mount": "panel",
		"body": Vector3(24, 24, 32), "rating": {"amps": 50.0, "volts": 1500.0},
		"source": "Stäubli MC4-Evo 2 data sheet (up to 50 A on 10 mm², 1500 V)",
		"opts": {"sex": "female", "evo": true}, "mates_with": ["mc4_evo2_inline"],
		"pins": [["w", "Wire", "", Vector3(0, 0, -22), Vector3(0, 0, -1)]]},
	"mc4_evo2_inline": {"label": "MC4-Evo 2 cable connector", "family": "MC4", "domain": "pv", "shape": "mc4", "mount": "inline",
		"body": Vector3(18, 18, 62), "rating": {"amps": 50.0, "volts": 1500.0},
		"source": "Stäubli MC4-Evo 2 data sheet", "opts": {"sex": "male", "evo": true},
		"mates_with": ["mc4_evo2_panel", "mc4_evo2_inline"],
		"pins": [["w", "Cable", "", Vector3(0, 0, 0), Vector3(0, 0, -1)]]},
	"h4_panel": {"label": "Amphenol H4 bulkhead", "family": "H4", "domain": "pv", "shape": "mc4", "mount": "panel",
		"body": Vector3(24, 24, 32), "rating": {"amps": 30.0, "volts": 1500.0},
		"source": "Amphenol H4 UTX data sheet (30 A on 4 mm², 1500 V)", "opts": {"sex": "female", "evo": true},
		"mates_with": [], "pins": [["w", "Wire", "", Vector3(0, 0, -22), Vector3(0, 0, -1)]]},
	# --- DC power ----------------------------------------------------------
	"powerpole_15": {"label": "Anderson Powerpole PP15 pair", "family": "Powerpole", "domain": "dc", "shape": "powerpole",
		"mount": "inline", "body": Vector3(15.8, 7.9, 24.6), "rating": {"amps": 15.0, "volts": 600.0},
		"source": "Anderson Power Products PP15/30/45 data sheet", "opts": {"size": 15},
		"mates_with": ["powerpole_15", "powerpole_30", "powerpole_45"],
		"pins": [["pos", "+", "+", Vector3(-3.95, 0, 0), Vector3(0, 0, -1)], ["neg", "−", "-", Vector3(3.95, 0, 0), Vector3(0, 0, -1)]]},
	"powerpole_30": {"label": "Anderson Powerpole PP30 pair", "family": "Powerpole", "domain": "dc", "shape": "powerpole",
		"mount": "inline", "body": Vector3(15.8, 7.9, 24.6), "rating": {"amps": 30.0, "volts": 600.0},
		"source": "Anderson PP15/30/45 data sheet", "opts": {"size": 30},
		"mates_with": ["powerpole_15", "powerpole_30", "powerpole_45"],
		"pins": [["pos", "+", "+", Vector3(-3.95, 0, 0), Vector3(0, 0, -1)], ["neg", "−", "-", Vector3(3.95, 0, 0), Vector3(0, 0, -1)]]},
	"powerpole_45": {"label": "Anderson Powerpole PP45 pair", "family": "Powerpole", "domain": "dc", "shape": "powerpole",
		"mount": "inline", "body": Vector3(15.8, 7.9, 24.6), "rating": {"amps": 45.0, "volts": 600.0},
		"source": "Anderson PP15/30/45 data sheet", "opts": {"size": 45},
		"mates_with": ["powerpole_15", "powerpole_30", "powerpole_45"],
		"pins": [["pos", "+", "+", Vector3(-3.95, 0, 0), Vector3(0, 0, -1)], ["neg", "−", "-", Vector3(3.95, 0, 0), Vector3(0, 0, -1)]]},
	"sb50": {"label": "Anderson SB50", "family": "SB", "domain": "dc", "shape": "sb", "mount": "inline",
		"body": Vector3(21.5, 22.0, 48.0), "rating": {"amps": 50.0, "volts": 600.0},
		"source": "Anderson SB50 data sheet (body sizes estimate)", "opts": {"color": Color(0.5, 0.52, 0.54)},
		"mates_with": ["sb50"],
		"pins": [["pos", "+", "+", Vector3(-5, 0, 0), Vector3(0, 0, -1)], ["neg", "−", "-", Vector3(5, 0, 0), Vector3(0, 0, -1)]]},
	"sb120": {"label": "Anderson SB120", "family": "SB", "domain": "dc", "shape": "sb", "mount": "inline",
		"body": Vector3(37.0, 30.0, 75.0), "rating": {"amps": 120.0, "volts": 600.0},
		"source": "Anderson SB120 data sheet (body sizes estimate)", "opts": {"color": Color(0.5, 0.52, 0.54)},
		"mates_with": ["sb120"],
		"pins": [["pos", "+", "+", Vector3(-9, 0, 0), Vector3(0, 0, -1)], ["neg", "−", "-", Vector3(9, 0, 0), Vector3(0, 0, -1)]]},
	"sb175": {"label": "Anderson SB175", "family": "SB", "domain": "dc", "shape": "sb", "mount": "inline",
		"body": Vector3(44.0, 36.0, 92.0), "rating": {"amps": 175.0, "volts": 600.0},
		"source": "Anderson SB175 data sheet (body sizes estimate)", "opts": {"color": C_RED},
		"mates_with": ["sb175"],
		"pins": [["pos", "+", "+", Vector3(-11, 0, 0), Vector3(0, 0, -1)], ["neg", "−", "-", Vector3(11, 0, 0), Vector3(0, 0, -1)]]},
	"xt60": {"label": "XT60", "family": "XT", "domain": "dc", "shape": "xt", "mount": "inline",
		"body": Vector3(15.5, 8.0, 16.0), "rating": {"amps": 30.0, "volts": 500.0},
		"source": "Amass XT60 data sheet (30 A continuous)", "opts": {"color": Color(0.92, 0.76, 0.1)},
		"mates_with": ["xt60"],
		"pins": [["pos", "+", "+", Vector3(-3.6, 0, 0), Vector3(0, 0, -1)], ["neg", "−", "-", Vector3(3.6, 0, 0), Vector3(0, 0, -1)]]},
	"xt90": {"label": "XT90", "family": "XT", "domain": "dc", "shape": "xt", "mount": "inline",
		"body": Vector3(21.0, 10.5, 20.0), "rating": {"amps": 45.0, "volts": 500.0},
		"source": "Amass XT90 data sheet (45 A continuous)", "opts": {"color": Color(0.92, 0.76, 0.1)},
		"mates_with": ["xt90"],
		"pins": [["pos", "+", "+", Vector3(-5.0, 0, 0), Vector3(0, 0, -1)], ["neg", "−", "-", Vector3(5.0, 0, 0), Vector3(0, 0, -1)]]},
	"sae": {"label": "SAE 2-pin", "family": "SAE", "domain": "dc", "shape": "sae", "mount": "inline",
		"body": Vector3(13.0, 8.0, 22.0), "rating": {"amps": 15.0, "volts": 30.0}, "source": "estimate",
		"opts": {}, "mates_with": ["sae"],
		"pins": [["pos", "+", "+", Vector3(-2.5, 0, 0), Vector3(0, 0, -1)], ["neg", "−", "-", Vector3(2.5, 0, 0), Vector3(0, 0, -1)]]},
	"barrel_21": {"label": "DC barrel jack 5.5 × 2.1", "family": "Barrel", "domain": "dc", "shape": "barrel",
		"mount": "panel", "body": Vector3(11, 11, 10), "rating": {"amps": 5.0, "volts": 24.0}, "source": "estimate",
		"opts": {"pin_d": 2.1}, "mates_with": [],
		"pins": [["pos", "+ (centre)", "+", Vector3(0, 0, -12), Vector3(0, 0, -1)], ["neg", "− (sleeve)", "-", Vector3(3, 0, -12), Vector3(0, 0, -1)]]},
	"barrel_25": {"label": "DC barrel jack 5.5 × 2.5", "family": "Barrel", "domain": "dc", "shape": "barrel",
		"mount": "panel", "body": Vector3(11, 11, 10), "rating": {"amps": 5.0, "volts": 24.0}, "source": "estimate",
		"opts": {"pin_d": 2.5}, "mates_with": [],
		"pins": [["pos", "+ (centre)", "+", Vector3(0, 0, -12), Vector3(0, 0, -1)], ["neg", "− (sleeve)", "-", Vector3(3, 0, -12), Vector3(0, 0, -1)]]},
	"cig_socket": {"label": "12 V accessory socket", "family": "Cigarette", "domain": "dc", "shape": "cig",
		"mount": "panel", "body": Vector3(30, 30, 8), "rating": {"amps": 15.0, "volts": 24.0},
		"source": "ANSI/SAE J563 socket (rating estimate)", "opts": {},
		"mates_with": [],
		"pins": [["pos", "+", "+", Vector3(0, 0, -45), Vector3(0, 0, -1)], ["neg", "−", "-", Vector3(8, 0, -40), Vector3(0, 0, -1)]]},
	"stud": {"label": "Bolt terminal (stud)", "family": "Stud", "domain": "dc", "shape": "stud", "mount": "stud",
		"body": Vector3(22, 22, 26), "rating": {"amps": 250.0, "volts": 60.0},
		"source": "estimate (a stud carries what its lug and cable carry)",
		"opts": {"stud": 8.0, "boss_r": 9.0, "polarity": "+", "bare": false, "inner": false, "insulator": true},
		"mates_with": [], "pins": [["lug", "Lug", "", Vector3(0, 0, 14), Vector3(0, 1, 0)]]},
	"binding_post": {"label": "Binding post", "family": "Post", "domain": "dc", "shape": "binding", "mount": "panel",
		"body": Vector3(14, 14, 24), "rating": {"amps": 15.0, "volts": 60.0}, "source": "estimate",
		"opts": {"polarity": "+"}, "mates_with": [],
		"pins": [["w", "Wire", "", Vector3(0, 0, 10), Vector3(0, 1, 0)]]},
	"box_lug": {"label": "Box-clamp lug terminal", "family": "Lug", "domain": "dc", "shape": "box_lug", "mount": "stud",
		"body": Vector3(16, 22, 18), "rating": {"amps": 175.0, "volts": 600.0},
		"source": "estimate (a 2/0 box lug)", "opts": {"polarity": "+"}, "mates_with": [],
		"pins": [["w", "Wire", "", Vector3(0, -12, 9), Vector3(0, -1, 0)]]},
	"fuse_class_t": {"label": "Class T fuse block", "family": "Fuse", "domain": "protection", "shape": "fuse_t",
		"mount": "panel", "body": Vector3(130, 45, 50), "rating": {"amps": 300.0, "volts": 160.0},
		"source": "UL 248-15 Class T (fuse 300 A, 20 kA; block size estimate)", "opts": {"amps": 300},
		"mates_with": [],
		"pins": [["line", "Line", "", Vector3(-52, 0, 48), Vector3(0, 0, 1)], ["load", "Load", "", Vector3(52, 0, 48), Vector3(0, 0, 1)]]},
	"fuse_anl": {"label": "ANL fuse holder", "family": "Fuse", "domain": "protection", "shape": "fuse_anl",
		"mount": "panel", "body": Vector3(105, 36, 35), "rating": {"amps": 200.0, "volts": 32.0},
		"source": "ANL fuses, 32 V DC (holder size estimate)", "opts": {"amps": 200}, "mates_with": [],
		"pins": [["line", "Line", "", Vector3(-38, 0, 34), Vector3(0, 0, 1)], ["load", "Load", "", Vector3(38, 0, 34), Vector3(0, 0, 1)]]},
	# --- AC mains ------------------------------------------------------------
	"nema_5_15": {"label": "NEMA 5-15R outlet", "family": "NEMA", "domain": "ac", "shape": "nema", "mount": "panel",
		"body": Vector3(34, 40, 4), "rating": {"amps": 15.0, "volts": 125.0}, "source": "NEMA WD 6",
		"opts": {"variant": "5-15", "duplex": false, "gfci": false}, "mates_with": [],
		"pins": [["L", "Line (hot)", "L", Vector3(-6, 0, -20), Vector3(0, 0, -1)], ["N", "Neutral", "N", Vector3(6, 0, -20), Vector3(0, 0, -1)],
			["G", "Ground", "G", Vector3(0, -10, -20), Vector3(0, 0, -1)]]},
	"nema_5_20": {"label": "NEMA 5-20R outlet", "family": "NEMA", "domain": "ac", "shape": "nema", "mount": "panel",
		"body": Vector3(34, 40, 4), "rating": {"amps": 20.0, "volts": 125.0}, "source": "NEMA WD 6",
		"opts": {"variant": "5-20", "duplex": false, "gfci": false}, "mates_with": [],
		"pins": [["L", "Line (hot)", "L", Vector3(-6, 0, -20), Vector3(0, 0, -1)], ["N", "Neutral", "N", Vector3(6, 0, -20), Vector3(0, 0, -1)],
			["G", "Ground", "G", Vector3(0, -10, -20), Vector3(0, 0, -1)]]},
	"nema_5_15_duplex": {"label": "NEMA 5-15R duplex outlet", "family": "NEMA", "domain": "ac", "shape": "nema",
		"mount": "panel", "body": Vector3(46, 106, 5), "rating": {"amps": 15.0, "volts": 125.0}, "source": "NEMA WD 6",
		"opts": {"variant": "5-15", "duplex": true, "gfci": false}, "mates_with": [],
		"pins": [["L", "Line (hot)", "L", Vector3(-12, 0, -20), Vector3(0, 0, -1)], ["N", "Neutral", "N", Vector3(12, 0, -20), Vector3(0, 0, -1)],
			["G", "Ground", "G", Vector3(0, -40, -20), Vector3(0, 0, -1)]]},
	"nema_5_20_gfci": {"label": "NEMA 5-20R GFCI outlet", "family": "NEMA", "domain": "ac", "shape": "nema",
		"mount": "panel", "body": Vector3(46, 106, 6), "rating": {"amps": 20.0, "volts": 125.0},
		"source": "NEMA WD 6, UL 943", "opts": {"variant": "5-20", "duplex": true, "gfci": true}, "mates_with": [],
		"pins": [["L", "Line (hot)", "L", Vector3(-12, 0, -20), Vector3(0, 0, -1)], ["N", "Neutral", "N", Vector3(12, 0, -20), Vector3(0, 0, -1)],
			["G", "Ground", "G", Vector3(0, -40, -20), Vector3(0, 0, -1)]]},
	"nema_l14_30": {"label": "NEMA L14-30R twist-lock", "family": "NEMA", "domain": "ac", "shape": "round_ac",
		"mount": "panel", "body": Vector3(52, 52, 6), "rating": {"amps": 30.0, "volts": 250.0}, "source": "NEMA WD 6",
		"opts": {"variant": "l14_30"}, "mates_with": [],
		"pins": [["L1", "L1", "L1", Vector3(-10, 5, -25), Vector3(0, 0, -1)], ["L2", "L2", "L2", Vector3(10, 5, -25), Vector3(0, 0, -1)],
			["N", "Neutral", "N", Vector3(0, -10, -25), Vector3(0, 0, -1)], ["G", "Ground", "G", Vector3(0, 12, -25), Vector3(0, 0, -1)]]},
	"nema_tt_30": {"label": "NEMA TT-30R (RV 30 A)", "family": "NEMA", "domain": "ac", "shape": "round_ac",
		"mount": "panel", "body": Vector3(52, 52, 6), "rating": {"amps": 30.0, "volts": 125.0}, "source": "NEMA WD 6",
		"opts": {"variant": "tt_30"}, "mates_with": [],
		"pins": [["L", "Line (hot)", "L", Vector3(-8, 4, -25), Vector3(0, 0, -1)], ["N", "Neutral", "N", Vector3(8, 4, -25), Vector3(0, 0, -1)],
			["G", "Ground", "G", Vector3(0, -10, -25), Vector3(0, 0, -1)]]},
	"schuko": {"label": "Schuko (CEE 7/3) outlet", "family": "CEE", "domain": "ac", "shape": "round_ac", "mount": "panel",
		"body": Vector3(50, 50, 8), "rating": {"amps": 16.0, "volts": 250.0}, "source": "CEE 7/3",
		"opts": {"variant": "schuko"}, "mates_with": [],
		"pins": [["L", "Line", "L", Vector3(-9.5, 0, -25), Vector3(0, 0, -1)], ["N", "Neutral", "N", Vector3(9.5, 0, -25), Vector3(0, 0, -1)],
			["G", "Earth", "G", Vector3(0, 18, -25), Vector3(0, 0, -1)]]},
	"bs1363": {"label": "BS 1363 outlet", "family": "BS", "domain": "ac", "shape": "bs1363", "mount": "panel",
		"body": Vector3(46, 46, 6), "rating": {"amps": 13.0, "volts": 250.0}, "source": "BS 1363",
		"opts": {}, "mates_with": [],
		"pins": [["L", "Line", "L", Vector3(11, -6, -25), Vector3(0, 0, -1)], ["N", "Neutral", "N", Vector3(-11, -6, -25), Vector3(0, 0, -1)],
			["G", "Earth", "G", Vector3(0, 12, -25), Vector3(0, 0, -1)]]},
	"as_nzs": {"label": "AS/NZS 3112 outlet", "family": "AS", "domain": "ac", "shape": "asnzs", "mount": "panel",
		"body": Vector3(42, 42, 6), "rating": {"amps": 10.0, "volts": 250.0}, "source": "AS/NZS 3112",
		"opts": {}, "mates_with": [],
		"pins": [["L", "Active", "L", Vector3(-7, 3, -25), Vector3(0, 0, -1)], ["N", "Neutral", "N", Vector3(7, 3, -25), Vector3(0, 0, -1)],
			["G", "Earth", "G", Vector3(0, -8, -25), Vector3(0, 0, -1)]]},
	"iec_c14": {"label": "IEC C14 inlet", "family": "IEC", "domain": "ac", "shape": "iec", "mount": "panel",
		"body": Vector3(28, 20, 6), "rating": {"amps": 10.0, "volts": 250.0}, "source": "IEC 60320",
		"opts": {"variant": "c14"}, "mates_with": ["iec_c13"],
		"pins": [["L", "Line", "L", Vector3(-7, -2, -20), Vector3(0, 0, -1)], ["N", "Neutral", "N", Vector3(7, -2, -20), Vector3(0, 0, -1)],
			["G", "Earth", "G", Vector3(0, 4, -20), Vector3(0, 0, -1)]]},
	"iec_c13": {"label": "IEC C13 outlet", "family": "IEC", "domain": "ac", "shape": "iec", "mount": "panel",
		"body": Vector3(28, 20, 6), "rating": {"amps": 10.0, "volts": 250.0}, "source": "IEC 60320",
		"opts": {"variant": "c13"}, "mates_with": ["iec_c14"],
		"pins": [["L", "Line", "L", Vector3(-7, -2, -20), Vector3(0, 0, -1)], ["N", "Neutral", "N", Vector3(7, -2, -20), Vector3(0, 0, -1)],
			["G", "Earth", "G", Vector3(0, 4, -20), Vector3(0, 0, -1)]]},
	"iec_c20": {"label": "IEC C20 inlet", "family": "IEC", "domain": "ac", "shape": "iec", "mount": "panel",
		"body": Vector3(32, 24, 6), "rating": {"amps": 16.0, "volts": 250.0}, "source": "IEC 60320",
		"opts": {"variant": "c20"}, "mates_with": ["iec_c19"],
		"pins": [["L", "Line", "L", Vector3(-8, -3, -20), Vector3(0, 0, -1)], ["N", "Neutral", "N", Vector3(8, -3, -20), Vector3(0, 0, -1)],
			["G", "Earth", "G", Vector3(0, 5, -20), Vector3(0, 0, -1)]]},
	"iec_c19": {"label": "IEC C19 outlet", "family": "IEC", "domain": "ac", "shape": "iec", "mount": "panel",
		"body": Vector3(32, 24, 6), "rating": {"amps": 16.0, "volts": 250.0}, "source": "IEC 60320",
		"opts": {"variant": "c19"}, "mates_with": ["iec_c20"],
		"pins": [["L", "Line", "L", Vector3(-8, -3, -20), Vector3(0, 0, -1)], ["N", "Neutral", "N", Vector3(8, -3, -20), Vector3(0, 0, -1)],
			["G", "Earth", "G", Vector3(0, 5, -20), Vector3(0, 0, -1)]]},
	"rocker_switch": {"label": "Rocker switch", "family": "Switch", "domain": "ui", "shape": "rocker", "mount": "panel",
		"body": Vector3(15, 21, 8), "rating": {"amps": 16.0, "volts": 250.0}, "source": "estimate",
		"opts": {"color": Color(0.08, 0.08, 0.09)}, "mates_with": [], "pins": []},
	"breaker_push": {"label": "Push-button breaker", "family": "Breaker", "domain": "protection", "shape": "push_breaker",
		"mount": "panel", "body": Vector3(16, 16, 22), "rating": {"amps": 20.0, "volts": 250.0}, "source": "estimate",
		"opts": {"amps": 20}, "mates_with": [],
		"pins": [["line", "Line", "", Vector3(-4, 0, -30), Vector3(0, 0, -1)], ["load", "Load", "", Vector3(4, 0, -30), Vector3(0, 0, -1)]]},
	# --- Wiring bay (terminal strips and DIN gear) --------------------------
	"terminal_block": {"label": "Screw terminal strip", "family": "Terminal", "domain": "io", "shape": "terminal_block",
		"mount": "pcb", "body": Vector3(10.16, 14, 12), "rating": {"amps": 12.0, "volts": 300.0},
		"source": "typical 5.08 mm pitch PCB terminal block (UL 1059)",
		"opts": {"poles": 2, "pitch": 5.08, "color": C_GREEN_TB, "labels": []}, "mates_with": [], "pins": []},
	"terminal_block_35": {"label": "Screw terminal strip 3.5 mm", "family": "Terminal", "domain": "io",
		"shape": "terminal_block", "mount": "pcb", "body": Vector3(7.0, 10, 9), "rating": {"amps": 8.0, "volts": 300.0},
		"source": "typical 3.5 mm pitch PCB terminal block", "opts": {"poles": 2, "pitch": 3.5, "color": C_GREEN_TB, "labels": []},
		"mates_with": [], "pins": []},
	"power_terminal": {"label": "Power terminal block", "family": "Terminal", "domain": "dc", "shape": "terminal_block",
		"mount": "pcb", "body": Vector3(30, 22, 18), "rating": {"amps": 60.0, "volts": 600.0},
		"source": "estimate (a 15 mm pitch, 16 mm² power block)",
		"opts": {"poles": 2, "pitch": 15.0, "color": Color(0.1, 0.1, 0.11), "labels": []}, "mates_with": [], "pins": []},
	"ac_block": {"label": "Hard-wire AC terminals", "family": "Terminal", "domain": "ac", "shape": "terminal_block",
		"mount": "pcb", "body": Vector3(36, 22, 18), "rating": {"amps": 50.0, "volts": 600.0},
		"source": "estimate (a 12 mm pitch, 10 mm² mains block)",
		"opts": {"poles": 3, "pitch": 12.0, "color": Color(0.18, 0.18, 0.2), "labels": ["L", "N", "G"]}, "mates_with": [], "pins": []},
	"wago_lever": {"label": "WAGO 221 lever connector", "family": "Lever", "domain": "io", "shape": "wago", "mount": "inline",
		"body": Vector3(18.7, 8.3, 20.0), "rating": {"amps": 32.0, "volts": 450.0},
		"source": "WAGO 221-413 data sheet (4 mm², 32 A, 450 V)", "opts": {"poles": 3}, "mates_with": [], "pins": []},
	"din_rail": {"label": "DIN rail (35 mm top hat)", "family": "DIN", "domain": "protection", "shape": "din_rail",
		"mount": "panel", "body": Vector3(200, 35, 7.5), "rating": {}, "source": "IEC 60715",
		"opts": {"length": 200.0}, "mates_with": [], "pins": []},
	"din_breaker": {"label": "Miniature circuit breaker (DIN)", "family": "DIN", "domain": "protection", "shape": "din_breaker",
		"mount": "din", "body": Vector3(36, 85, 74), "rating": {"amps": 50.0, "volts": 480.0},
		"source": "IEC 60898 / UL 1077 module 17.5 mm a pole (e.g. CHNT NB1-63 C50)",
		"opts": {"poles": 2, "amps": 50, "curve": "C", "toggle": Color(0.16, 0.32, 0.82), "label": ""},
		"mates_with": [], "pins": []},
	"bus_bar": {"label": "Bus bar (N / PE)", "family": "Bus", "domain": "ground", "shape": "bus_bar", "mount": "panel",
		"body": Vector3(90, 10, 14), "rating": {"amps": 100.0, "volts": 600.0}, "source": "estimate",
		"opts": {"screws": 8, "pitch": 10.0, "label": "PE"}, "mates_with": [], "pins": []},
	"ground_lug": {"label": "Ground lug", "family": "Ground", "domain": "ground", "shape": "ground_lug", "mount": "panel",
		"body": Vector3(14, 12, 14), "rating": {"amps": 100.0, "volts": 600.0}, "source": "estimate (a lay-in lug)",
		"opts": {}, "mates_with": [], "pins": [["G", "Ground", "G", Vector3(0, 0, 8), Vector3(0, -1, 0)]]},
	# --- Data and I/O --------------------------------------------------------
	"rj45": {"label": "RJ45 jack", "family": "RJ", "domain": "data", "shape": "rj_jack", "mount": "panel",
		"body": Vector3(16, 13.5, 2), "rating": {"amps": 1.5, "volts": 60.0}, "source": "IEC 60603-7",
		"opts": {"size": "rj45", "leds": true}, "mates_with": ["rj45_plug"],
		"pins": [["cable", "Cable", "", Vector3(0, 0, 0), Vector3(0, 0, 1)]]},
	"rj45_plug": {"label": "RJ45 patch plug", "family": "RJ", "domain": "data", "shape": "rj_plug", "mount": "inline",
		"body": Vector3(13, 9.5, 28), "rating": {"amps": 1.5, "volts": 60.0}, "source": "IEC 60603-7",
		"opts": {"boot": Color(0.18, 0.42, 0.85)}, "mates_with": ["rj45"],
		"pins": [["cable", "Cable", "", Vector3(0, 0, 28), Vector3(0, 0, 1)]]},
	"rj11": {"label": "RJ11 / RJ12 jack", "family": "RJ", "domain": "data", "shape": "rj_jack", "mount": "panel",
		"body": Vector3(12, 10, 2), "rating": {"amps": 1.5, "volts": 60.0}, "source": "estimate",
		"opts": {"size": "rj11", "leds": false}, "mates_with": [],
		"pins": [["cable", "Cable", "", Vector3(0, 0, 0), Vector3(0, 0, 1)]]},
	"usb_a": {"label": "USB-A", "family": "USB", "domain": "data", "shape": "usb", "mount": "panel",
		"body": Vector3(14, 7, 1.5), "rating": {"amps": 2.4, "volts": 5.0}, "source": "USB 2.0 spec (charge 2.4 A typical)",
		"opts": {"kind": "a"}, "mates_with": [], "pins": []},
	"usb_c": {"label": "USB-C", "family": "USB", "domain": "data", "shape": "usb", "mount": "panel",
		"body": Vector3(10, 4.2, 1.5), "rating": {"amps": 3.0, "volts": 20.0}, "source": "USB Type-C spec (3 A default)",
		"opts": {"kind": "c"}, "mates_with": [], "pins": []},
	"db9": {"label": "DB9 (RS232)", "family": "D-sub", "domain": "data", "shape": "db9", "mount": "panel",
		"body": Vector3(31, 12.5, 6), "rating": {"amps": 1.0, "volts": 30.0}, "source": "estimate",
		"opts": {}, "mates_with": [], "pins": []},
	"ve_direct": {"label": "VE.Direct (JST-PH 4-pin)", "family": "VE", "domain": "data", "shape": "ve_direct",
		"mount": "panel", "body": Vector3(9, 6, 5), "rating": {"amps": 2.0, "volts": 30.0},
		"source": "Victron VE.Direct protocol (JST PH 2.0 mm)", "opts": {}, "mates_with": [], "pins": []},
	"antenna": {"label": "Antenna (SMA)", "family": "RF", "domain": "data", "shape": "antenna", "mount": "panel",
		"body": Vector3(10, 10, 100), "rating": {}, "source": "estimate", "opts": {"length": 100.0},
		"mates_with": [], "pins": []},
	# --- Enclosure fittings --------------------------------------------------
	"gland_m16": {"label": "Cable gland M16", "family": "Gland", "domain": "fitting", "shape": "gland", "mount": "panel",
		"body": Vector3(22, 22, 22), "rating": {}, "source": "EN 62444 (cable 4.5–10 mm)",
		"opts": {"thread": 16.0, "color": C_BLACK}, "mates_with": [],
		"pins": [["out", "Outside", "", Vector3(0, 0, 22), Vector3(0, 0, 1)], ["in", "Inside", "", Vector3(0, 0, -12), Vector3(0, 0, -1)]]},
	"gland_m20": {"label": "Cable gland M20", "family": "Gland", "domain": "fitting", "shape": "gland", "mount": "panel",
		"body": Vector3(27, 27, 25), "rating": {}, "source": "EN 62444 (cable 6–12 mm)",
		"opts": {"thread": 20.0, "color": C_BLACK}, "mates_with": [],
		"pins": [["out", "Outside", "", Vector3(0, 0, 25), Vector3(0, 0, 1)], ["in", "Inside", "", Vector3(0, 0, -12), Vector3(0, 0, -1)]]},
	"gland_m25": {"label": "Cable gland M25", "family": "Gland", "domain": "fitting", "shape": "gland", "mount": "panel",
		"body": Vector3(33, 33, 28), "rating": {}, "source": "EN 62444 (cable 9–17 mm)",
		"opts": {"thread": 25.0, "color": C_BLACK}, "mates_with": [],
		"pins": [["out", "Outside", "", Vector3(0, 0, 28), Vector3(0, 0, 1)], ["in", "Inside", "", Vector3(0, 0, -12), Vector3(0, 0, -1)]]},
	"gland_pg7": {"label": "Cable gland PG7", "family": "Gland", "domain": "fitting", "shape": "gland", "mount": "panel",
		"body": Vector3(19, 19, 20), "rating": {}, "source": "DIN 40430 (cable 3–6.5 mm)",
		"opts": {"thread": 12.5, "color": C_BLACK}, "mates_with": [],
		"pins": [["out", "Outside", "", Vector3(0, 0, 20), Vector3(0, 0, 1)], ["in", "Inside", "", Vector3(0, 0, -12), Vector3(0, 0, -1)]]},
	"knockout": {"label": "Conduit knockout", "family": "Knockout", "domain": "fitting", "shape": "knockout",
		"mount": "panel", "body": Vector3(36, 36, 12), "rating": {},
		"source": "NEMA trade sizes (½\" knockout 22.2 mm … 1¼\" 44.5 mm)",
		"opts": {"trade": "3/4", "conduit": false, "bushing": Color(0.62, 0.62, 0.64)}, "mates_with": [],
		"pins": [["out", "Outside", "", Vector3(0, 0, 12), Vector3(0, 0, 1)], ["in", "Inside", "", Vector3(0, 0, -8), Vector3(0, 0, -1)]]},
	# --- Front panel ----------------------------------------------------------
	"led": {"label": "Indicator LED", "family": "LED", "domain": "ui", "shape": "led", "mount": "panel",
		"body": Vector3(5, 5, 3), "rating": {}, "source": "", "opts": {"color": Color(0.2, 0.9, 0.3), "d": 5.0},
		"mates_with": [], "pins": []},
	"lcd": {"label": "LCD display", "family": "Display", "domain": "ui", "shape": "lcd", "mount": "panel",
		"body": Vector3(70, 45, 2), "rating": {}, "source": "",
		"opts": {"w": 70.0, "h": 45.0, "screen": Color(0.16, 0.32, 0.62), "bezel": C_BLACK, "round": false},
		"mates_with": [], "pins": []},
	"button": {"label": "Push button", "family": "Button", "domain": "ui", "shape": "button", "mount": "panel",
		"body": Vector3(8, 8, 3), "rating": {}, "source": "",
		"opts": {"d": 8.0, "color": Color(0.12, 0.12, 0.13), "round": true}, "mates_with": [], "pins": []},
	"dip_switch": {"label": "DIP switch", "family": "DIP", "domain": "io", "shape": "dip", "mount": "pcb",
		"body": Vector3(20, 10, 4), "rating": {}, "source": "", "opts": {"poles": 8}, "mates_with": [], "pins": []},
}

## Knockout trade size → hole diameter (mm), the NEMA standard punches.
const KNOCKOUT_MM := {"1/2": 22.2, "3/4": 28.6, "1": 34.9, "1-1/4": 44.5, "1-1/2": 50.8, "2": 63.5}
## Trade size → conduit OD (mm), EMT.
const CONDUIT_OD := {"1/2": 17.9, "3/4": 23.4, "1": 29.5, "1-1/4": 38.4, "1-1/2": 44.2, "2": 55.8}


static func ids() -> Array:
	return ENTRIES.keys()


static func has(id: String) -> bool:
	return ENTRIES.has(id)


static func entry(id: String) -> Dictionary:
	return ENTRIES.get(id, {})


static func ids_in(domain: String) -> Array:
	var out: Array = []
	for k in ENTRIES:
		if str((ENTRIES[k] as Dictionary)["domain"]) == domain:
			out.append(k)
	return out


static func label(id: String) -> String:
	return str(entry(id).get("label", id))


## Every word in `q` must appear in the label, family, domain or id.
static func search(q: String) -> Array:
	var words := q.to_lower().split(" ", false)
	var out: Array = []
	for k in ENTRIES:
		var e: Dictionary = ENTRIES[k]
		var hay := ("%s %s %s %s" % [k, e["label"], e["family"], DOMAIN_LABELS.get(e["domain"], "")]).to_lower()
		var ok := true
		for w in words:
			if not hay.contains(w):
				ok = false
				break
		if ok:
			out.append(k)
	return out


static func mates(a: String, b: String) -> bool:
	return (entry(a).get("mates_with", []) as Array).has(b) or (entry(b).get("mates_with", []) as Array).has(a)


## The entry with its opts filled (defaults, then `opts`), the body and pins
## worked out for parametric ones. Pins come back as dicts
## {id, label, role, pos, dir}.
static func resolve(id: String, opts: Dictionary = {}) -> Dictionary:
	var e: Dictionary = entry(id).duplicate(true)
	if e.is_empty():
		return {}
	e["id"] = id
	var o: Dictionary = (e.get("opts", {}) as Dictionary).duplicate(true)
	for k in opts:
		o[k] = opts[k]
	e["opts"] = o
	var pins: Array = []
	for p in (e.get("pins", []) as Array):
		pins.append({"id": str(p[0]), "label": str(p[1]), "role": str(p[2]), "pos": p[3], "dir": p[4]})
	var shape := str(e["shape"])
	match shape:
		"terminal_block", "wago":
			var n := clampi(int(o.get("poles", 2)), 1, 24)
			var pitch := float(o.get("pitch", 5.08)) if shape == "terminal_block" else 5.4
			var labels: Array = o.get("labels", [])
			var b: Vector3 = e["body"]
			if shape == "terminal_block":
				b = Vector3(b.x, float(o.get("h", b.y)), float(o.get("d", b.z)))
			e["body"] = Vector3(pitch * n, b.y, b.z)
			pins = []
			for i in n:
				var x := (float(i) - float(n - 1) * 0.5) * pitch
				var lb := str(labels[i]) if i < labels.size() else str(i + 1)
				if shape == "terminal_block":
					pins.append({"id": "p%d" % (i + 1), "label": lb, "role": lb, "pos": Vector3(x, -b.y * 0.5, b.z * 0.55),
						"dir": Vector3(0, -1, 0)})
				else:
					pins.append({"id": "p%d" % (i + 1), "label": lb, "role": lb, "pos": Vector3(x, 0, 0), "dir": Vector3(0, 0, -1)})
		"din_breaker":
			var n2 := clampi(int(o.get("poles", 2)), 1, 4)
			e["body"] = Vector3(17.5 * n2, 85, 74)
			e["rating"] = {"amps": float(o.get("amps", 50)), "volts": 480.0 if n2 > 1 else 277.0}
			pins = []
			for i in n2:
				var x2 := (float(i) - float(n2 - 1) * 0.5) * 17.5
				pins.append({"id": "line%d" % (i + 1), "label": "Line %d" % (i + 1), "role": "", "pos": Vector3(x2, 42.5, 40),
					"dir": Vector3(0, 1, 0)})
				pins.append({"id": "load%d" % (i + 1), "label": "Load %d" % (i + 1), "role": "", "pos": Vector3(x2, -42.5, 40),
					"dir": Vector3(0, -1, 0)})
		"bus_bar":
			var n3 := clampi(int(o.get("screws", 8)), 2, 24)
			var pitch3 := float(o.get("pitch", 10.0))
			e["body"] = Vector3(pitch3 * n3 + 10.0, 10, 14)
			pins = []
			for i in n3:
				var x3 := (float(i) - float(n3 - 1) * 0.5) * pitch3
				pins.append({"id": "s%d" % (i + 1), "label": str(o.get("label", "")), "role": str(o.get("label", "")),
					"pos": Vector3(x3, -5, 10), "dir": Vector3(0, -1, 0)})
		"din_rail":
			e["body"] = Vector3(float(o.get("length", 200.0)), 35, 7.5)
		"knockout":
			var hole := float(KNOCKOUT_MM.get(str(o.get("trade", "3/4")), 28.6))
			e["body"] = Vector3(hole + 8.0, hole + 8.0, 12.0)
		"lcd":
			e["body"] = Vector3(float(o.get("w", 70.0)) + 8.0, float(o.get("h", 45.0)) + 8.0, 2.0)
		"stud":
			var st := float(o.get("stud", 8.0))
			e["rating"] = {"amps": {6.0: 150.0, 8.0: 250.0, 10.0: 400.0, 12.0: 600.0}.get(st, 250.0), "volts": 60.0}
			var r := float(o.get("boss_r", st * 1.125))
			e["body"] = Vector3(r * 2.0 + 4.0, r * 2.0 + 4.0, 13.5 + st * 1.5)
			pins = [{"id": "lug", "label": str(o.get("polarity", "")), "role": str(o.get("polarity", "")),
				"pos": Vector3(0, 0, 13.5), "dir": Vector3(0, 1, 0)}]
	# A single-pin connector takes its polarity as its pin's role hint.
	if pins.size() == 1 and str(pins[0]["role"]) == "" and str(o.get("polarity", "")) != "":
		pins[0]["role"] = str(o["polarity"])
	e["pins"] = pins
	return e
