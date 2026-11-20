class_name BankSpec
extends RefCounted

## A battery bank: one pack design (`pack`, a BattSpec) repeated `series` ×
## `parallel` times, how the packs are mounted, how they are joined to the
## bus, the fuses and the comms chain. Record key `battery_bank_spec` on a
## placed bank (model `batterylab_bank`).
##
##   mount   auto | cabinet (19" rack) | wall (brackets on studs) |
##           floor (standing side by side) | shelf (a battery rack, rows) |
##           cart (a rolling cart)
##   bus     auto | busbar (a pair of copper bars the strings land on) |
##           distributor (a Lynx-style box: each string's pair of cables)
##   wiring  diagonal (each string's + at one end of the bus and − at the
##           other: every string sees the same length — "reverse return") |
##           equal_len (every string's cables cut to the longest one, the
##           spare coiled: what a distributor needs) | same_end (both at one end: the nearest string does more work)
##   fuse    auto | class_t | mrbf | anl | none (one per string, at its +)

const MOUNTS := ["auto", "cabinet", "wall", "floor", "shelf", "cart"]
const MOUNT_WORDS := {"auto": "Chosen for the pack", "cabinet": "19\" cabinet", "wall": "On the wall",
	"floor": "Standing on the floor", "shelf": "Battery shelf", "cart": "Rolling cart"}
const BUSES := ["auto", "busbar", "distributor"]
const BUS_WORDS := {"auto": "Chosen for the bank", "busbar": "Busbar pair", "distributor": "Distributor box"}
const WIRINGS := ["diagonal", "equal_len", "same_end"]
const WIRING_WORDS := {"diagonal": "Diagonal take-off", "equal_len": "Every string's cables the same length", "same_end": "Both at one end"}
const FUSES := ["auto", "class_t", "mrbf", "anl", "none"]
const FUSE_WORDS := {"auto": "Chosen for the fault current", "class_t": "Class T", "mrbf": "MRBF (on the terminal)",
	"anl": "ANL", "none": "None"}
const MAX_SERIES := 16
const MAX_PARALLEL := 32


static func empty(name: String = "Battery bank") -> Dictionary:
	return {
		"v": 1, "name": name, "pack": BattSpec.empty("Pack"), "series": 1, "parallel": 2,
		"mount": "auto", "bus": "auto", "wiring": "diagonal", "fuse": "auto",
		"disconnect": true, "comms": true, "main_run_m": 2.0, "gap_mm": 0.0,
	}


## A bank of `parallel` strings of `series` packs of one pack spec.
static func of_pack(pack: Dictionary, series: int = 1, parallel: int = 1, name: String = "") -> Dictionary:
	var b := empty(name if not name.is_empty() else "%s × %d" % [str(pack.get("name", "Pack")), series * parallel])
	b["pack"] = pack.duplicate(true)
	b["series"] = series
	b["parallel"] = parallel
	return b


static func resolve(b: Dictionary) -> Dictionary:
	var out := empty(str(b.get("name", "Battery bank")))
	for k in b:
		out[k] = b[k]
	out["pack"] = BattSpec.resolve(b.get("pack", {}) if b.get("pack") is Dictionary else {})
	out["series"] = clampi(int(out["series"]), 1, MAX_SERIES)
	out["parallel"] = clampi(int(out["parallel"]), 1, MAX_PARALLEL)
	for pair in [["mount", MOUNTS], ["bus", BUSES], ["wiring", WIRINGS], ["fuse", FUSES]]:
		if not (pair[1] as Array).has(str(out[pair[0]])):
			out[pair[0]] = (pair[1] as Array)[0]
	out["main_run_m"] = clampf(float(out["main_run_m"]), 0.3, 30.0)
	out["gap_mm"] = clampf(float(out["gap_mm"]), 0.0, 500.0)
	out["disconnect"] = bool(out["disconnect"])
	out["comms"] = bool(out["comms"])
	out["v"] = int(out.get("v", 1))
	return out


static func key_of(b: Dictionary) -> String:
	var r := resolve(b)
	var flat := r.duplicate()
	flat["pack"] = BattSpec.key_of(r["pack"])
	return JSON.stringify(flat, "", true)
