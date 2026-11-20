class_name BattBom
extends RefCounted

## Bills of materials: a pack (cells, links, BMS, cables, case) and a bank
## (its packs, every cable by gauge and colour rounded up to what is sold,
## lugs and heat-shrink per end, fuses and holders, busbars or a
## distributor, a disconnect, the cabinet / brackets / shelf / cart, comms
## cables). Rows {group, item, qty, unit, each_usd, total_usd, mass_kg, note}.
## Prices are estimates (they say so); masses for copper from its density.

const CABLE_STOCK_M := 0.5
const LUG_USD := 2.0
const LUG_USD_PER_MM2 := 0.05
const SHRINK_USD := 0.5
const DISCONNECT_USD := 85.0
const DISTRIBUTOR_USD := 260.0
const COPPER_USD_KG := 25.0
const COMMS_USD := 7.0
const MOUNT_USD := {"cabinet_base": 450.0, "cabinet_per_u": 12.0, "bracket": 18.0, "shelf_level": 60.0,
	"shelf_frame": 120.0, "cart": 220.0, "mat": 25.0}
const MOUNT_KG := {"cabinet_base": 45.0, "cabinet_per_u": 1.6, "bracket": 1.2, "shelf_level": 8.0,
	"shelf_frame": 15.0, "cart": 30.0, "mat": 3.0}


static func _row(group: String, item: String, qty: float, unit: String, each: float, mass: float, note: String = "") -> Dictionary:
	return {"group": group, "item": item, "qty": qty, "unit": unit, "each_usd": each,
		"total_usd": each * qty, "mass_kg": mass, "note": note}


## One pack's parts.
static func pack(pd: Dictionary) -> Array:
	var out: Array = []
	var cell: Dictionary = pd["cell"]
	var sp: Dictionary = pd["spec"]
	var n := int(sp["series"]) * int(sp["parallel"])
	var c: Dictionary = pd["cost"]
	var m: Dictionary = pd["mass"]
	out.append(_row("Cells", str(cell["label"]), float(n), "cells", float(c["cells"]) / maxf(float(n), 1.0),
		float(m["cells"]), str(cell["source"])))
	var L: Dictionary = pd["layout"]
	var links := (L["links"] as Array).size() + (L["ends"] as Array).size()
	if links > 0:
		out.append(_row("Links", "%s links" % str(pd["interconnect"]).capitalize(), float(links), "pcs",
			float(c["links"]) / maxf(float(links), 1.0), float(m["links"])))
	if bool(pd["protected"]) or not (pd["bms"] as Dictionary).is_empty():
		out.append(_row("BMS", str((pd["bms"] as Dictionary).get("label", "")), 1.0, "pcs", float(c["bms"]), float(m["bms"])))
	if float(c["wires"]) > 0.0:
		out.append(_row("Wiring", "Leads and balance harness", 1.0, "set", float(c["wires"]), float(m["wires"])))
	if float(c["case"]) > 0.0:
		out.append(_row("Case", "%s case, breaker, terminals" % BattSpec.FORM_WORDS[str(sp["form"])], 1.0, "pcs",
			float(c["case"]), float(m.get("case", 0.0)) + float(m.get("frame", 0.0))))
	return out


## The bank: its packs as one row each kind, then everything that joins them.
static func bank(d: Dictionary) -> Dictionary:
	var rows: Array = []
	var pd: Dictionary = d["pack"]
	var e: Dictionary = d["electrical"]
	var count := int(e["packs"])
	rows.append(_row("Packs", str((pd["spec"] as Dictionary)["name"]), float(count), "packs",
		float(pd["cost_usd"]), float(pd["mass_kg"]) * float(count), BattPresets.size_line(pd["spec"])))
	# Cable by gauge and colour.
	var by: Dictionary = {}
	var lugs: Dictionary = {}
	for cb in (d["cables"] as Array):
		var key := "%s|%s" % [cb["gauge"], cb["color"]]
		if not by.has(key):
			by[key] = {"gauge": str(cb["gauge"]), "color": str(cb["color"]), "mm2": float(cb["mm2"]), "len": 0.0, "n": 0}
		by[key]["len"] = float(by[key]["len"]) + float(cb["len_mm"]) * 0.001
		by[key]["n"] = int(by[key]["n"]) + 1
		lugs[str(cb["gauge"])] = int(lugs.get(str(cb["gauge"]), 0)) + 2
	for k in by:
		var r: Dictionary = by[k]
		var metres := ceilf(float(r["len"]) / CABLE_STOCK_M - 1e-9) * CABLE_STOCK_M
		var mass := BattElectrical.mass_kg("copper", metres * 1000.0, float(r["mm2"])) * 1.3
		rows.append(_row("Cable", "%s %s battery cable" % [r["gauge"], r["color"]], metres, "m",
			BankDesign.CABLE_USD_PER_M_MM2 * float(r["mm2"]), mass,
			"%d cables, %.2f m measured, rounded up to %.1f m" % [int(r["n"]), float(r["len"]), CABLE_STOCK_M]))
	for g in lugs:
		var mm2 := 0.0
		for w in BattElectrical.WIRES:
			if str(w[0]) == g:
				mm2 = float(w[1])
		rows.append(_row("Cable", "Lugs for %s" % g, float(lugs[g]), "pcs", LUG_USD + LUG_USD_PER_MM2 * mm2, float(lugs[g]) * 0.02))
		rows.append(_row("Cable", "Heat-shrink for %s" % g, float(lugs[g]), "pcs", SHRINK_USD, 0.0))
	var fuse: Dictionary = d["fuse"]
	if not fuse.is_empty():
		rows.append(_row("Protection", "%s fuse %.0f A" % [fuse["label"], float(fuse["amps"])], float(d["parallel"]), "pcs",
			float(fuse["usd"]), 0.1 * float(d["parallel"])))
		rows.append(_row("Protection", "%s fuse holder" % fuse["label"], float(d["parallel"]), "pcs",
			float(fuse["holder_usd"]), 0.25 * float(d["parallel"])))
	if bool((d["spec"] as Dictionary)["disconnect"]):
		rows.append(_row("Protection", "Battery disconnect switch (%.0f A)" % float(e["cont_discharge_a"]), 1.0, "pcs",
			DISCONNECT_USD, 0.8))
	var bars: Dictionary = d["bars"]
	if str(bars["kind"]) == "distributor":
		rows.append(_row("Bus", "Distributor (Lynx class)", 1.0, "pcs", DISTRIBUTOR_USD, 3.0))
	else:
		var bl := absf(float(bars["hi"]) - float(bars["lo"])) + 120.0
		var area := float(bars["w"]) * float(bars["t"])
		var nb := int(bars.get("n", 1))
		var kg := BattElectrical.mass_kg("copper", bl, area) * 2.0 * float(nb)
		rows.append(_row("Bus", "Copper busbar %.0f × %.0f mm" % [float(bars["w"]), float(bars["t"])], 2.0 * float(nb), "bars",
			kg / (2.0 * float(nb)) * COPPER_USD_KG * 2.0, kg,
			"%.0f mm long each, drilled at every landing%s" % [bl, (", %d laid together a pole" % nb) if nb > 1 else ""]))
	var fr: Dictionary = d["frame"]
	match str(d["mount"]):
		"cabinet":
			var u := int(fr["u"])
			rows.append(_row("Mounting", "%dU 19\" cabinet" % u, 1.0, "pcs",
				MOUNT_USD["cabinet_base"] + MOUNT_USD["cabinet_per_u"] * float(u),
				MOUNT_KG["cabinet_base"] + MOUNT_KG["cabinet_per_u"] * float(u)))
		"wall":
			rows.append(_row("Mounting", "Wall brackets + lag bolts", float(count), "pairs", MOUNT_USD["bracket"],
				MOUNT_KG["bracket"] * float(count)))
		"shelf":
			var lv := 0
			for b in (fr["boxes"] as Array):
				if str(b["id"]).begins_with("shelf_"):
					lv += 1
			rows.append(_row("Mounting", "Battery shelf, %d levels" % lv, 1.0, "pcs",
				MOUNT_USD["shelf_frame"] + MOUNT_USD["shelf_level"] * float(lv),
				MOUNT_KG["shelf_frame"] + MOUNT_KG["shelf_level"] * float(lv)))
		"cart":
			rows.append(_row("Mounting", "Rolling cart", 1.0, "pcs", MOUNT_USD["cart"], MOUNT_KG["cart"]))
		_:
			rows.append(_row("Mounting", "Rubber floor mat", 1.0, "pcs", MOUNT_USD["mat"], MOUNT_KG["mat"]))
	var comms: Array = d["comms"]
	if not comms.is_empty():
		rows.append(_row("Comms", "Pack-to-pack comms cable (RJ45)", float(comms.size()), "pcs", COMMS_USD, 0.05 * float(comms.size()),
			"addresses 1–%d by the DIP switches, terminator on the last" % int(e["packs"])))
		rows.append(_row("Comms", "Terminator", 1.0, "pcs", 4.0, 0.01))
	var total := 0.0
	var mass_t := 0.0
	for r in rows:
		total += float(r["total_usd"])
		mass_t += float(r["mass_kg"])
	return {"rows": rows, "total_usd": total, "mass_kg": mass_t, "pack_rows": pack(pd), "est": true}


static func csv(bom: Dictionary) -> String:
	var lines := PackedStringArray(["group,item,qty,unit,each_usd,total_usd,mass_kg,note"])
	for r in (bom["rows"] as Array):
		lines.append("%s,%s,%s,%s,%.2f,%.2f,%.2f,%s" % [_q(str(r["group"])), _q(str(r["item"])), str(r["qty"]),
			str(r["unit"]), float(r["each_usd"]), float(r["total_usd"]), float(r["mass_kg"]), _q(str(r["note"]))])
	lines.append("")
	lines.append("In each pack,,,,,,,")
	for r in (bom["pack_rows"] as Array):
		lines.append("%s,%s,%s,%s,%.2f,%.2f,%.2f,%s" % [_q(str(r["group"])), _q(str(r["item"])), str(r["qty"]),
			str(r["unit"]), float(r["each_usd"]), float(r["total_usd"]), float(r["mass_kg"]), _q(str(r["note"]))])
	lines.append("")
	lines.append("Prices are estimates.,,,,,,,")
	return "\n".join(lines)


static func _q(s: String) -> String:
	if s.contains(",") or s.contains("\""):
		return "\"%s\"" % s.replace("\"", "\"\"")
	return s
