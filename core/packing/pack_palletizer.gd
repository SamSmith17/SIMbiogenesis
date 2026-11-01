class_name PackPalletizer
extends RefCounted
## Builds pallets from loose handling units, the first level of the Packing
## Lab's palletize-then-stuff flow. Pure static: each pallet is a PackSolver
## pass over what is still loose onto one pallet entry (from
## IntermodalUnits), repeated until nothing more places. What can never go
## on a pallet (too big, too heavy) stays loose and is stuffed as it is.
##
## A pallet comes back as ONE item dict the container solve can take:
## its footprint, deck + load height, tare + contents mass, this side up,
## stackable only when every box on it is (and then only up to the pallet's
## static rating less what it carries), and a fork axis for a 2-way pallet.

const MAX_PALLETS := 200
const DEFAULT_LOAD_H_M := 1.6


## `units`: PackSolver item dicts. `opts.max_load_h_m` caps the load height
## (default the pallet's own stack height). Returns {pallets: [unit dict
## with `contents` (indices into `units`) and `placements` (pallet-local,
## on the deck)], loose: [indices]}.
static func palletize(units: Array, pallet: Dictionary, opts: Dictionary = {}) -> Dictionary:
	var out := {"pallets": [], "loose": []}
	if pallet.is_empty() or units.is_empty():
		for i in units.size():
			out["loose"].append(i)
		return out
	var interior: Dictionary = pallet.get("interior", {})
	var load_h := float(opts.get("max_load_h_m",
		float(interior.get("h_m", DEFAULT_LOAD_H_M))))
	var ext: Dictionary = pallet.get("exterior", {})
	var deck := float(pallet.get("deck_h_m", float(ext.get("h_m", 0.144))))
	var tare := float(pallet.get("tare_kg", 0.0))
	var static_kg := float(pallet.get("static_kg", -1.0))
	var two_way := str(pallet.get("fork_entry", "4-way")).begins_with("2")
	var remaining: Array = []
	for i in units.size():
		remaining.append(i)
	var n := 0
	while not remaining.is_empty() and n < MAX_PALLETS:
		var items: Array = []
		for idx in remaining:
			items.append(units[idx])
		var res := PackSolver.solve(pallet, items, {"max_fill_h_m": load_h})
		var placed: Array = res.get("placements", [])
		if placed.is_empty():
			break
		n += 1
		var contents: Array = []
		var local: Array = []
		var top := 0.0
		var load_kg := 0.0
		var all_stack := true
		var used: Dictionary = {}
		for p in placed:
			var src := int(remaining[int(p["item_index"])])
			used[src] = true
			contents.append(src)
			var u: Dictionary = units[src]
			var pos: Vector3 = p["pos"]
			var size: Vector3 = p["size"]
			top = maxf(top, pos.y + size.y)
			var m := float(u.get("mass_kg", -1.0))
			if m > 0.0:
				load_kg += m
			if not bool(u.get("stackable", true)) or bool(u.get("top_only", false)) \
					or bool(u.get("fragile", false)):
				all_stack = false
			local.append({"unit": src, "label": str(u.get("label", "")),
				"pos": pos + Vector3(0, deck, 0), "size": size})
		var unit := {
			"label": "Pallet %d" % n,
			"w_m": float(ext.get("w_m", 1.0)),
			"d_m": float(ext.get("l_m", 1.2)),
			"h_m": deck + top,
			"mass_kg": tare + load_kg,
			"this_side_up": true,
			"stackable": all_stack,
			"pallet": true,
			"pallet_id": str(pallet.get("id", "")),
			"contents": contents,
			"placements": local,
			"load_kg": load_kg,
			"overweight": float(pallet.get("payload_kg", -1.0)) > 0.0 \
				and load_kg > float(pallet.get("payload_kg", -1.0)),
		}
		if all_stack:
			if static_kg >= 0.0:
				unit["max_stack_kg"] = maxf(0.0, static_kg - load_kg)
		else:
			unit["top_only"] = true
		if two_way:
			unit["fork_axis"] = "d"
		out["pallets"].append(unit)
		var next: Array = []
		for idx in remaining:
			if not used.has(idx):
				next.append(idx)
		remaining = next
	out["loose"] = remaining
	return out


## Pallets + the loose units as one list for the container solve.
static func stuffing_items(units: Array, result: Dictionary) -> Array:
	var items: Array = []
	for p in result.get("pallets", []):
		items.append(p)
	for idx in result.get("loose", []):
		items.append(units[int(idx)])
	return items
