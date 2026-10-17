class_name ConduitLength
extends RefCounted

## How long a run is, said the way a person buying the cord or pipe needs it:
## metres and feet, and which stock length covers it with how much to spare.
## Pure. The NUMBER itself comes from ConduitManager.measure_route (the same
## rule the built run stamps as route_length_m); this file only reads it out.

const M_PER_FT := 0.3048

## Stock lengths a kind is sold in, in FEET (cords and hoses by the length,
## tubing by the coil, rigid pipe by the 10 ft / 20 ft stick). Kinds not
## listed have no stock (conceptual flow, lights, ducting).
const STOCK_FT := {
	"extension_cord": [25, 50, 100],
	"romex": [25, 50, 100, 250],
	"dc_solar": [25, 50, 100],
	"ethernet": [25, 50, 100, 200, 328],
	"garden_hose": [25, 50, 75, 100],
	"pex_red": [100, 300, 500],
	"pex_blue": [100, 300, 500],
	"pex_white": [100, 300, 500],
	"poly_penstock": [100, 300, 500],
}
## Rigid kinds sold by the stick: (stick length ft).
const STICK_FT := {
	"pvc_pipe": 10, "pvc_4in": 10, "pvc_6in": 10, "abs_dwv": 10, "culvert_pipe": 20,
}


static func feet(m: float) -> float:
	return m / M_PER_FT


## "23.4 m · 76.8 ft"
static func format(m: float) -> String:
	if m <= 0.0:
		return "—"
	return "%s m · %s ft" % [_num(m), _num(feet(m))]


static func _num(v: float) -> String:
	if v >= 100.0:
		return str(roundi(v))
	return "%.1f" % v


## What covers a `length_m` run of `type_id`. Returns {kind: "stock" | "sticks"
## | "none", text, stock_ft, count, spare_ft, ok}.
##   stock: the shortest single length that covers it; past the longest, how
##          many of the longest it takes (joined — cords and hoses couple).
##   sticks: how many rigid sticks (couplings between them).
static func stock_fit(length_m: float, type_id: String) -> Dictionary:
	var need_ft := feet(length_m)
	if length_m <= 0.0:
		return {"kind": "none", "text": "", "ok": true}
	if STICK_FT.has(type_id):
		var stick := float(STICK_FT[type_id])
		var n := int(ceil(need_ft / stick - 1e-6))
		var spare := float(n) * stick - need_ft
		return {"kind": "sticks", "count": n, "stock_ft": stick, "spare_ft": spare, "ok": true,
			"text": "%s of %d ft (%s ft spare)" % [UiText.count(n, "stick"), int(stick), _num(spare)]}
	if not STOCK_FT.has(type_id):
		return {"kind": "none", "text": "", "ok": true}
	var sizes: Array = STOCK_FT[type_id]
	var noun := "coil" if type_id.begins_with("pex") or type_id == "poly_penstock" else \
		("hose" if type_id == "garden_hose" else ("cable" if type_id in ["romex", "dc_solar", "ethernet"] else "cord"))
	for s in sizes:
		if float(s) >= need_ft:
			var spare_ft := float(s) - need_ft
			return {"kind": "stock", "count": 1, "stock_ft": float(s), "spare_ft": spare_ft, "ok": true,
				"text": "fits a %d ft %s (%s ft spare)" % [int(s), noun, _num(spare_ft)]}
	var longest := float(sizes[sizes.size() - 1])
	var n2 := int(ceil(need_ft / longest - 1e-6))
	var spare2 := float(n2) * longest - need_ft
	# Ethernet's 328 ft is the spec limit, not a coil size: past it, say so.
	var over := type_id == "ethernet"
	return {"kind": "stock", "count": n2, "stock_ft": longest, "spare_ft": spare2, "ok": not over,
		"text": ("over the 100 m Ethernet limit — needs a switch in between" if over else
			"needs %s × %d ft (%s ft spare)" % [n2, int(longest), _num(spare2)])}


## One line: "23.4 m · 76.8 ft — fits a 100 ft cord (23.2 ft spare)".
static func describe(length_m: float, type_id: String) -> String:
	if length_m <= 0.0:
		return "—"
	var fit := stock_fit(length_m, type_id)
	var t := format(length_m)
	if not str(fit.get("text", "")).is_empty():
		t += " — " + str(fit["text"])
	return t
