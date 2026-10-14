class_name LinkageBom
extends RefCounted
## Bill of materials, costs, masses and assembly steps for a linkage design.
##
## Pure computation — no Control, Node, SubViewport or theme reference lives in
## this file. Every number the Build Guide shows originates here, which is what
## lets the whole BOM be asserted offline.
##
## Port of `js/linkage/build-guide.js:gatherBOMData` (:1687) plus the helpers it
## calls: `beam-bolt-helpers.js` (V-beam counts/costs/weights),
## `solver.js:calculateBeamCostByVolume` (:150) and `calculateActuatorStroke`
## (:194), `linkage-geometry.js:computeSupportBomContribution` (:1633), and
## `hardware-detail.js:getAssemblyHardwareItems` (:3403).
##
## [b]Masses are metric.[/b] The web app carries weights in pounds off a
## `woodDensity` of 0.018 lb/in³ (≈498 kg/m³) plus flat 0.5 lb/bracket and
## 0.01 lb/bolt constants. This port drops all three and uses the project's own
## density model — `PackedSpec.WOOD_KG_M3` (SPF 470 kg/m³, FPL Wood Handbook)
## and mild steel 7850 kg/m³ — so a design's shipping mass and its BOM mass are
## the same number. Expect roughly 6% lighter figures than the web app; lb is a
## display conversion only.
##
## [b]Copies.[/b] With a radial array and/or an arch tunnel array on, the
## design holds several identical structures (`bom.js:countStructureCopies`):
## everything is first computed for ONE structure (`per_structure`), then every
## count, cost and mass at the top level is that set times `copies.total`
## (unit prices unchanged). Panels come from assembled geometry, so the one
## structure's share is the base group (the solved frame carries every arch
## tunnel copy's panels). With one structure the result is exactly the old
## shape plus the `copies` / `per_structure` keys.
##
## Counts are derived analytically from the parameters, exactly as the web app
## does, NOT by walking the solved frame — the solver only emits bolt geometry
## when "show bolts" is on, while the hardware exists regardless. The selftest
## cross-checks the two against each other, which the web app never did.

const IN3_TO_M3 := 1.6387064e-5
const STEEL_KG_M3 := 7850.0
const LB_PER_KG := 2.20462262185
const INCHES_PER_FOOT := 12.0

## Bolt diameters that have a conventional fractional name
## (`unit-converter.js:formatBoltSpec` :569).
const BOLT_FRACTIONS := {
	0.25: "1/4", 0.3125: "5/16", 0.375: "3/8",
	0.5: "1/2", 0.625: "5/8", 0.75: "3/4",
}


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

## Full bill of materials for `p`.
##
## Solved internally at the DEPLOYED (closed) angle so the result never depends
## on where the fold slider happens to sit — a BOM that changed while you
## animated the structure would be worse than useless.
static func compute(p: LinkageParams) -> Dictionary:
	var copies := structure_copies(p)
	var one := _compute_one(p, int(copies["linear"]))
	one["copies"] = copies
	var k := int(copies["total"])
	if k <= 1:
		one["per_structure"] = _per_structure_view(one)
		return one
	var out := one.duplicate()
	out["per_structure"] = _per_structure_view(one)
	out["counts"] = _scale_numbers(one["counts"], k)
	out["structure_items"] = _scale_items(one["structure_items"], k)
	out["power_items"] = _scale_items(one["power_items"], k)
	out["enclosure_items"] = _scale_items(one["enclosure_items"], k)
	out["structure_cost"] = float(one["structure_cost"]) * k
	out["power_cost"] = float(one["power_cost"]) * k
	out["enclosure_cost"] = float(one["enclosure_cost"]) * k
	out["total_cost"] = float(one["total_cost"]) * k
	out["mass"] = _scale_numbers(one["mass"], k)
	var pw: Dictionary = (one["power"] as Dictionary).duplicate()
	for key in ["panel_count", "watts_total", "kw"]:
		pw[key] = pw[key] * k
	out["power"] = pw
	var rpl := LinkageRadialArray.deployed_plan(p)
	if not rpl.is_empty():
		# The whole pattern's footprint: the farthest part of any copy.
		var dims: Dictionary = (one["dims"] as Dictionary).duplicate()
		dims["pattern_diameter_in"] = 2.0 * (float(dims["diameter_in"]) / 2.0 + float(rpl["radius"]))
		dims["pattern_diameter_ft"] = float(dims["pattern_diameter_in"]) / INCHES_PER_FOOT
		out["dims"] = dims
	return out


## How many structures the design holds: visible radial copies x arch tunnel
## segments (`bom.js:countStructureCopies`).
static func structure_copies(p: LinkageParams) -> Dictionary:
	var pl := LinkageRadialArray.deployed_plan(p)
	var radial := maxi(1, int(pl.get("visible_count", 1))) if not pl.is_empty() else 1
	var linear := p.array_count if p.orientation == "vertical" and p.array_count > 1 else 1
	var total := radial * linear
	return {"radial": radial, "linear": linear, "total": total,
		"label": "1 structure" if total == 1 else "%d structures" % total}


static func _per_structure_view(one: Dictionary) -> Dictionary:
	return {"counts": one["counts"], "structure_items": one["structure_items"],
		"power_items": one["power_items"], "enclosure_items": one["enclosure_items"],
		"structure_cost": one["structure_cost"], "power_cost": one["power_cost"],
		"enclosure_cost": one["enclosure_cost"], "total_cost": one["total_cost"], "mass": one["mass"]}


## Every int/float scaled by k (bools and strings untouched) — `scaleNumbers`.
static func _scale_numbers(d: Dictionary, k: int) -> Dictionary:
	var out := {}
	for key in d:
		var v = d[key]
		if v is int:
			out[key] = v * k
		elif v is float:
			out[key] = v * float(k)
		else:
			out[key] = v
	return out


## Line items with qty / totals scaled by k (unit prices unchanged) — `scaleItems`.
static func _scale_items(items: Array, k: int) -> Array:
	var out: Array = []
	for it in items:
		var d: Dictionary = (it as Dictionary).duplicate()
		d["qty"] = int(d["qty"]) * k
		d["total_cost"] = float(d["total_cost"]) * k
		d["total_mass_kg"] = float(d["total_mass_kg"]) * k
		out.append(d)
	return out


## One structure's bill of materials. `linear` = arch tunnel copies the solved
## frame carries; its panels are divided back down to one structure's share.
static func _compute_one(p: LinkageParams, linear: int) -> Dictionary:
	var warnings: PackedStringArray = []
	var closed := LinkageKinematics.optimal_closed_angle(p)
	var frame := LinkageSolver.solve(p, closed)
	var supports := LinkageGeometry.support_beams(frame, p, closed)
	var panels := LinkageGeometry.solar_panels(frame, p) if bool(p.solar_panels["enabled"]) else []
	if linear > 1 and panels.size() >= linear:
		panels = panels.slice(0, panels.size() / linear)

	var counts := _counts(p, warnings)
	counts["panels"] = panels.size()

	var structure_items: Array = []
	var mass := {
		"h_beams_kg": 0.0, "v_beams_kg": 0.0, "brackets_kg": 0.0,
		"bolts_kg": 0.0, "washers_kg": 0.0, "support_kg": 0.0, "floor_kg": 0.0,
		"hardware_kg": 0.0, "structure_kg": 0.0, "panels_kg": 0.0, "total_kg": 0.0,
	}

	_add_beam_items(p, counts, structure_items, mass)
	_add_bracket_items(p, counts, structure_items, mass)
	_add_bolt_items(p, counts, structure_items, mass)
	_add_washer_items(p, counts, structure_items, mass)

	var support := support_contribution(p)
	for item in support["items"]:
		structure_items.append(item)
	mass["support_kg"] = float(support["mass_kg"])
	counts["support_radial"] = int(support["radial"])
	counts["support_rcp"] = int(support["reciprocal"])
	counts["support_bolts"] = int(support["bolts"])
	counts["support_through"] = int(support["through"])
	counts["support_washers"] = int(support["washers"])
	# The support-beam BOM is analytic (n radial + 2n reciprocal). If the solver
	# disagrees the design is in a state the web formula never modelled.
	if not supports.is_empty():
		var want := int(support["radial"]) + int(support["reciprocal"])
		if supports.size() != want:
			warnings.append(
				"Support beams: solver built %d, BOM prices %d — the analytic "
				% [supports.size(), want]
				+ "count assumes every module carries its full set.")

	# Raised floor beams (A4, floor-geometry.js computeFloorBomContribution).
	var floor_bom := LinkageFloor.bom_contribution(p)
	for item in floor_bom["items"]:
		structure_items.append(item)
	mass["floor_kg"] = float(floor_bom["mass_kg"])
	counts["floor_radial"] = int(floor_bom["radial"])
	counts["floor_rcp"] = int(floor_bom["reciprocal"])

	var hw_items := assembly_hardware_items(p)
	var hw_pieces := 0
	for item in hw_items:
		structure_items.append(item)
		mass["hardware_kg"] += float(item["total_mass_kg"])
		hw_pieces += int(item["qty"])
	counts["hw_pieces"] = hw_pieces

	mass["structure_kg"] = mass["h_beams_kg"] + mass["v_beams_kg"] \
		+ mass["brackets_kg"] + mass["bolts_kg"] + mass["washers_kg"] \
		+ mass["support_kg"] + mass["floor_kg"] + mass["hardware_kg"]

	var power_items: Array = []
	var power := _power_summary(p, panels)
	if panels.size() > 0:
		var sec := _active_panel_section(p)
		var panel_mass := panel_mass_kg(sec) * panels.size()
		mass["panels_kg"] = panel_mass
		power_items.append(_line(panels.size(),
			"Solar Panels (%dW — %s x %s)" % [
				int(round(float(sec["rated_watts"]))),
				_dim(float(sec["panel_length"])), _dim(float(sec["panel_width"]))],
			float(p.costs["solar_panel"]), panel_mass_kg(sec), "power", "solar_panel"))
	mass["total_kg"] = mass["structure_kg"] + mass["panels_kg"]

	var structure_cost := 0.0
	for item in structure_items:
		structure_cost += float(item["total_cost"])
	var power_cost := 0.0
	for item in power_items:
		power_cost += float(item["total_cost"])
	# ENCLOSURE (A4): plywood sheets / fabric / grommets from the cut plan,
	# plus the shade tarps (bom.js enclosureItems). Priced, not weighed —
	# the web's weights leave them out too.
	var enclosure := LinkageEnclosure.bom(p)
	var enclosure_items: Array = enclosure["items"]
	var enclosure_cost := float(enclosure["cost"])

	return {
		"counts": counts,
		"structure_items": structure_items,
		"power_items": power_items,
		"enclosure_items": enclosure_items,
		"structure_cost": structure_cost,
		"power_cost": power_cost,
		"enclosure_cost": enclosure_cost,
		"total_cost": structure_cost + power_cost + enclosure_cost,
		"covering_plan": enclosure["plan"],
		"mass": mass,
		"dims": _dims(p, frame),
		"actuator": actuator_stroke(p),
		"power": power,
		"assembly_steps": assembly_steps(p),
		"warnings": warnings,
	}


# ---------------------------------------------------------------------------
# Counts (gatherBOMData :1690-1703)
# ---------------------------------------------------------------------------

static func _counts(p: LinkageParams, warnings: PackedStringArray) -> Dictionary:
	var n := p.modules
	var vb := v_beam_counts(p)
	var c := {
		"modules": n,
		"h_beams": n * 2 * p.h_stack_count,
		"v_beams": int(vb["total"]),
		"v_beams_inner": int(vb["inner"]),
		"v_beams_outer": int(vb["outer"]),
		"v_beams_linked": bool(vb["linked"]),
		"brackets": n * 4,
		"bolts_v_inner": n * 2,
		"bolts_v_outer": n * 2,
		"bolts_v_center": n * 1,
		"bolts_h_center": n * 2,
		"bolts_h_pivot": n * 4,
		"split_bolts": p.needs_split_v_bolts(),
		"panels": 0,
		"hw_pieces": 0,
		"support_radial": 0, "support_rcp": 0, "support_bolts": 0,
		"support_through": 0, "support_washers": 0,
	}
	# Cap uprights add a fifth set of brackets and a cap V-stack that the web
	# app's BOM silently omits (gatherBOMData prices modules*4 unconditionally).
	# Pricing them is the correct behaviour, but it does mean this BOM will not
	# match a web-app export for a capped arch — say so rather than let someone
	# read the delta as a regression.
	if p.orientation == "vertical" and p.arch_cap_uprights:
		c["brackets"] += 4
		c["v_beams"] += p.v_stack_count
		if not bool(vb["linked"]):
			for i in p.v_stack_count:
				if p.is_v_stack_inner_beam_index(i):
					c["v_beams_inner"] += 1
				else:
					c["v_beams_outer"] += 1
		c["bolts_v_center"] += 1
		c["bolts_v_inner"] += 2
		c["bolts_v_outer"] += 2
		warnings.append(
			"Cap uprights priced: the LinkageLab web BOM omits the cap set, "
			+ "so totals here run higher than a web-app export of this design.")
	c["bolts_v_total"] = c["bolts_v_inner"] + c["bolts_v_outer"] + c["bolts_v_center"]
	c["bolts_h_total"] = c["bolts_h_center"] + c["bolts_h_pivot"]
	c["bolts_total"] = c["bolts_v_total"] + c["bolts_h_total"]
	# Washers sit between adjacent beams in a stack, so a 1-beam stack has none.
	var v_per_bolt := maxi(0, p.v_stack_count - 1)
	var h_per_bolt := maxi(0, p.h_stack_count - 1)
	c["washers_v"] = c["bolts_v_total"] * v_per_bolt if bool(p.washers["v_enabled"]) else 0
	c["washers_h"] = c["bolts_h_total"] * h_per_bolt if bool(p.washers["h_enabled"]) else 0
	return c


## `getVBeamCountsByType` (beam-bolt-helpers.js:139).
static func v_beam_counts(p: LinkageParams) -> Dictionary:
	var n := p.modules
	var stack := maxi(1, p.v_stack_count)
	if not p.needs_split_v_beam_dimensions() or p.is_v_beam_dimensions_linked():
		return {"inner": 0, "outer": 0, "total": n * stack, "linked": true}
	var inner_per := 0
	var outer_per := 0
	for i in stack:
		if p.is_v_stack_inner_beam_index(i):
			inner_per += 1
		else:
			outer_per += 1
	return {
		"inner": n * inner_per,
		"outer": n * outer_per,
		"total": n * stack,
		"linked": false,
	}


# ---------------------------------------------------------------------------
# Line items
# ---------------------------------------------------------------------------

static func _line(qty: int, item: String, unit_cost: float, unit_mass_kg: float,
		section: String, key: String) -> Dictionary:
	return {
		"qty": qty,
		"item": item,
		"unit_cost": unit_cost,
		"total_cost": qty * unit_cost,
		"unit_mass_kg": unit_mass_kg,
		"total_mass_kg": qty * unit_mass_kg,
		"section": section,
		"key": key,
	}


static func _add_beam_items(p: LinkageParams, c: Dictionary, items: Array, mass: Dictionary) -> void:
	var h_qty := int(c["h_beams"])
	var h_unit := h_beam_unit_cost(p)
	var h_mass := beam_mass_kg(p.h_beam_w, p.h_beam_t, p.h_length_ft)
	items.append(_line(h_qty,
		"H-Beams (%s)" % format_beam_spec(p.h_length_ft, p.h_beam_w, p.h_beam_t),
		h_unit, h_mass, "structure", "h_beam"))
	mass["h_beams_kg"] = h_qty * h_mass

	if bool(c["v_beams_linked"]):
		var v_unit := v_beam_unit_cost(p, p.v_beam_w, p.v_beam_t)
		var v_mass := beam_mass_kg(p.v_beam_w, p.v_beam_t, p.v_length_ft)
		items.append(_line(int(c["v_beams"]),
			"V-Beams (%s)" % format_beam_spec(p.v_length_ft, p.v_beam_w, p.v_beam_t),
			v_unit, v_mass, "structure", "v_beam"))
		mass["v_beams_kg"] = int(c["v_beams"]) * v_mass
		return
	var in_unit := v_beam_unit_cost(p, p.v_beam_inner_w, p.v_beam_inner_t)
	var out_unit := v_beam_unit_cost(p, p.v_beam_outer_w, p.v_beam_outer_t)
	var in_mass := beam_mass_kg(p.v_beam_inner_w, p.v_beam_inner_t, p.v_length_ft)
	var out_mass := beam_mass_kg(p.v_beam_outer_w, p.v_beam_outer_t, p.v_length_ft)
	items.append(_line(int(c["v_beams_inner"]),
		"V-Inner Beams (%s)" % format_beam_spec(p.v_length_ft, p.v_beam_inner_w, p.v_beam_inner_t),
		in_unit, in_mass, "structure", "v_beam_inner"))
	items.append(_line(int(c["v_beams_outer"]),
		"V-Outer Beams (%s)" % format_beam_spec(p.v_length_ft, p.v_beam_outer_w, p.v_beam_outer_t),
		out_unit, out_mass, "structure", "v_beam_outer"))
	mass["v_beams_kg"] = int(c["v_beams_inner"]) * in_mass + int(c["v_beams_outer"]) * out_mass


static func _add_bracket_items(p: LinkageParams, c: Dictionary, items: Array, mass: Dictionary) -> void:
	var qty := int(c["brackets"])
	var unit_mass := bracket_mass_kg(p.bracket_width, p.bracket_depth,
		p.bracket_height, p.bracket_wall_thickness)
	items.append(_line(qty, "U-Brackets", float(p.costs["bracket"]),
		unit_mass, "structure", "bracket"))
	mass["brackets_kg"] = qty * unit_mass


static func _add_bolt_items(p: LinkageParams, c: Dictionary, items: Array, mass: Dictionary) -> void:
	var dia := p.bolt_diameter
	var total := 0.0
	if bool(c["split_bolts"]):
		var inner := _line(int(c["bolts_v_inner"]),
			"Inner Bolts %s" % format_bolt_spec(dia, p.v_bolt_inner_length),
			float(p.costs["bolt_v_inner"]), bolt_mass_kg(dia, p.v_bolt_inner_length),
			"structure", "bolt_v_inner")
		var outer := _line(int(c["bolts_v_outer"]),
			"Outer Bolts %s" % format_bolt_spec(dia, p.v_bolt_outer_length),
			float(p.costs["bolt_v_outer"]), bolt_mass_kg(dia, p.v_bolt_outer_length),
			"structure", "bolt_v_outer")
		# The centre bolt spans the whole stack, so it is priced as an inner.
		var center := _line(int(c["bolts_v_center"]),
			"Center Bolts %s" % format_bolt_spec(dia, p.v_bolt_length),
			float(p.costs["bolt_v_inner"]), bolt_mass_kg(dia, p.v_bolt_length),
			"structure", "bolt_v_center")
		items.append(inner)
		items.append(outer)
		items.append(center)
		total += float(inner["total_mass_kg"]) + float(outer["total_mass_kg"]) \
			+ float(center["total_mass_kg"])
	else:
		var v := _line(int(c["bolts_v_total"]),
			"V-Stack Bolts %s" % format_bolt_spec(dia, p.v_bolt_length),
			float(p.costs["bolt_v_inner"]), bolt_mass_kg(dia, p.v_bolt_length),
			"structure", "bolt_v")
		items.append(v)
		total += float(v["total_mass_kg"])
	var hc := _line(int(c["bolts_h_center"]),
		"H-Center Bolts %s" % format_bolt_spec(dia, p.h_bolt_length),
		float(p.costs["bolt_h"]), bolt_mass_kg(dia, p.h_bolt_length),
		"structure", "bolt_h_center")
	var hp := _line(int(c["bolts_h_pivot"]),
		"H-Pivot Bolts %s" % format_bolt_spec(dia, p.h_pivot_bolt_length),
		float(p.costs["bolt_h_pivot"]), bolt_mass_kg(dia, p.h_pivot_bolt_length),
		"structure", "bolt_h_pivot")
	items.append(hc)
	items.append(hp)
	mass["bolts_kg"] = total + float(hc["total_mass_kg"]) + float(hp["total_mass_kg"])


static func _add_washer_items(p: LinkageParams, c: Dictionary, items: Array, mass: Dictionary) -> void:
	var total := 0.0
	var vt := washer_thickness(p, true)
	if int(c["washers_v"]) > 0:
		var v := _line(int(c["washers_v"]),
			"V-Stack Washers (ID:%s OD:%s T:%s)" % [
				_dim(float(p.washers["v_id"])), _dim(float(p.washers["v_od"])), _dim(vt)],
			float(p.costs["washer_v"]),
			washer_mass_kg(float(p.washers["v_id"]), float(p.washers["v_od"]), vt),
			"structure", "washer_v")
		items.append(v)
		total += float(v["total_mass_kg"])
	var ht := washer_thickness(p, false)
	if int(c["washers_h"]) > 0:
		var h := _line(int(c["washers_h"]),
			"H-Stack Washers (ID:%s OD:%s T:%s)" % [
				_dim(float(p.washers["h_id"])), _dim(float(p.washers["h_od"])), _dim(ht)],
			float(p.costs["washer_h"]),
			washer_mass_kg(float(p.washers["h_id"]), float(p.washers["h_od"]), ht),
			"structure", "washer_h")
		items.append(h)
		total += float(h["total_mass_kg"])
	mass["washers_kg"] = total


## Effective washer thickness. When "auto" is set the V washer fills whatever
## the bracket's inner width leaves over the beam stack, and the H washer
## simply matches the H stack gap (`beam-bolt-helpers.js:374-400`).
##
## NOTE the web app's auto path also WRITES `vStackGap` from this value, which
## moves real geometry. That side effect stays in the UI where it belongs — the
## BOM only reads.
static func washer_thickness(p: LinkageParams, vertical: bool) -> float:
	if not vertical:
		if bool(p.washers["h_auto"]):
			return maxf(0.0, p.h_stack_gap)
		return maxf(0.0, float(p.washers["h_thickness"]))
	if not bool(p.washers["v_auto"]):
		return maxf(0.0, float(p.washers["v_thickness"]))
	if p.v_stack_count <= 1:
		return 0.0
	var extra := p.bracket_inner_width - p.total_v_beam_width()
	var t := extra / float(p.v_stack_count - 1)
	return 0.125 if t < 0.0 else t


# ---------------------------------------------------------------------------
# Support beams (`computeSupportBomContribution`, linkage-geometry.js:1633)
# ---------------------------------------------------------------------------

static func support_contribution(p: LinkageParams) -> Dictionary:
	var empty := {
		"items": [], "cost": 0.0, "mass_kg": 0.0,
		"radial": 0, "reciprocal": 0, "bolts": 0, "through": 0, "washers": 0,
	}
	var cfg: Dictionary = p.support_beams
	if not bool(cfg["enabled"]) or p.orientation == "vertical":
		return empty
	var n := p.modules
	var items: Array = []
	var mass := 0.0

	var rad_ft := float(cfg["length"]) / INCHES_PER_FOOT
	var rw := float(cfg["width"])
	var rt := float(cfg["thickness"])
	var rad_mass := beam_mass_kg(rw, rt, rad_ft)
	items.append(_line(n, "Radial Support Beams (%s)" % format_beam_spec(rad_ft, rw, rt),
		h_beam_unit_cost(p), rad_mass, "structure", "support_radial"))
	mass += n * rad_mass

	var rcp_count := 0
	if bool(cfg["parallel_enabled"]):
		rcp_count = n * 2
		var rcp_ft := float(cfg["parallel_length"]) / INCHES_PER_FOOT
		var pw := float(cfg["parallel_width"])
		var pt := float(cfg["parallel_thickness"])
		var rcp_mass := beam_mass_kg(pw, pt, rcp_ft)
		items.append(_line(rcp_count,
			"Reciprocal Support Beams (%s)" % format_beam_spec(rcp_ft, pw, pt),
			v_beam_unit_cost(p, pw, pt), rcp_mass, "structure", "support_rcp"))
		mass += rcp_count * rcp_mass

	var bolts := n * 4
	var through := n * 2
	var washer_qty := n * 6
	var bolt_cost := float(p.costs["bolt_v_inner"])
	var bolt_mass := bolt_mass_kg(p.bolt_diameter, p.v_bolt_length)
	items.append(_line(bolts, "Radial Support Bolts (to top ring / outer pivot)",
		bolt_cost, bolt_mass, "structure", "support_bolt"))
	items.append(_line(through, "Radial Through-Bolts (through-beam tie)",
		bolt_cost, bolt_mass, "structure", "support_through"))
	var wt := washer_thickness(p, true)
	items.append(_line(washer_qty, "Radial Support Washers (same stack as V-bolts)",
		float(p.costs["washer_v"]),
		washer_mass_kg(float(p.washers["v_id"]), float(p.washers["v_od"]), wt),
		"structure", "support_washer"))
	mass += (bolts + through) * bolt_mass
	mass += washer_qty * washer_mass_kg(
		float(p.washers["v_id"]), float(p.washers["v_od"]), wt)

	var cost := 0.0
	for item in items:
		cost += float(item["total_cost"])
	return {
		"items": items, "cost": cost, "mass_kg": mass,
		"radial": n, "reciprocal": rcp_count,
		"bolts": bolts, "through": through, "washers": washer_qty,
	}


# ---------------------------------------------------------------------------
# Hardware assemblies (`getAssemblyHardwareItems`, hardware-detail.js:3403)
# ---------------------------------------------------------------------------

## Extra hardware introduced by the detailed assemblies — bushings, lock
## washers and nuts. Bolts and washers keep using the analytic rows above, so
## they are excluded here to avoid double-counting. Parts sharing a `presetId`
## or `bomKey` roll up into one line across every assembly.
static func assembly_hardware_items(p: LinkageParams) -> Array:
	var agg := {}
	var order: Array = []
	for asm_id in LinkageHardware.ASSEMBLY_IDS:
		var asm := LinkageHardware.assembly(p.hardware_assemblies, asm_id)
		if asm.is_empty() or not bool(asm.get("detailed", false)):
			continue
		for part in asm.get("parts", []):
			if not (part is Dictionary):
				continue
			var type := str(part.get("type", ""))
			if not LinkageHardware.BOM_EXTRA_TYPES.has(type):
				continue
			var per := int(part.get("perModule", 0))
			if per <= 0:
				continue
			var key := str(part.get("presetId", ""))
			if key == "":
				key = str(part.get("bomKey", ""))
			if key == "":
				key = "%s|%s" % [
					str(part.get("label", type)), str(part.get("cost", 0.0))]
			var qty := per * LinkageHardware.part_qty(part) * p.modules
			if not agg.has(key):
				agg[key] = {
					"label": str(part.get("label", LinkageHardware.TYPE_LABELS.get(type, type))),
					"qty": 0,
					"unit": float(part.get("cost", 0.0)),
					"mass": hardware_part_mass_kg(part),
				}
				order.append(key)
			(agg[key] as Dictionary)["qty"] += qty
	var out: Array = []
	for key in order:
		var a: Dictionary = agg[key]
		out.append(_line(int(a["qty"]), str(a["label"]), float(a["unit"]),
			float(a["mass"]), "structure", "hw_%s" % key))
	return out


## Steel mass of one hardware part, from its own parametric dimensions.
static func hardware_part_mass_kg(part: Dictionary) -> float:
	var pr: Dictionary = part.get("params", {})
	match str(part.get("type", "")):
		"bushing":
			var blen := float(pr.get("length", 0.0))
			var m := _annulus_mass_kg(float(pr.get("id", 0.0)), float(pr.get("od", 0.0)), blen)
			var flange_od := float(pr.get("flangeOd", 0.0))
			if flange_od > float(pr.get("od", 0.0)):
				m += _annulus_mass_kg(float(pr.get("od", 0.0)), flange_od,
					float(pr.get("flangeThickness", 0.0)))
			return m
		"washer", "lockWasher":
			return _annulus_mass_kg(float(pr.get("id", 0.0)), float(pr.get("od", 0.0)),
				float(pr.get("thickness", 0.0)))
		"nut":
			# Hex prism across the flats, less the threaded bore.
			var af := float(pr.get("widthAcrossFlats", 0.0))
			var height := float(pr.get("height", pr.get("length", 0.0)))
			if af <= 0.0:
				# Rivet nuts are a plain sleeve plus a flange.
				var m2 := _annulus_mass_kg(float(pr.get("id", 0.0)),
					float(pr.get("od", 0.0)), float(pr.get("length", 0.0)))
				m2 += _annulus_mass_kg(float(pr.get("od", 0.0)),
					float(pr.get("flangeOd", 0.0)), float(pr.get("flangeThickness", 0.0)))
				return m2
			var hex_area := 2.0 * sqrt(3.0) * pow(af / sqrt(3.0), 2.0)
			var bore := PI * pow(float(pr.get("id", 0.0)) / 2.0, 2.0)
			return maxf(0.0, hex_area - bore) * height * IN3_TO_M3 * STEEL_KG_M3
		"bolt":
			return bolt_mass_kg(float(pr.get("diameter", 0.0)), float(pr.get("length", 0.0)))
		"bracket":
			return bracket_mass_kg(float(pr.get("width", 0.0)), float(pr.get("depth", 0.0)),
				float(pr.get("height", 0.0)), float(pr.get("wallThickness", 0.0)))
		"beam":
			return beam_mass_kg(float(pr.get("width", 0.0)), float(pr.get("thickness", 0.0)),
				float(pr.get("length", 0.0)) / INCHES_PER_FOOT)
	return 0.0


static func _annulus_mass_kg(id_in: float, od_in: float, thickness_in: float) -> float:
	if od_in <= id_in or thickness_in <= 0.0:
		return 0.0
	var area := PI * (od_in * od_in - id_in * id_in) / 4.0
	return area * thickness_in * IN3_TO_M3 * STEEL_KG_M3


# ---------------------------------------------------------------------------
# Assembly steps — the physical order a person threads one pivot
# ---------------------------------------------------------------------------

## Per-assembly ordered part stacks. Each assembly's parts are grouped by axis
## and sorted by `seq`, which IS the threading order: this is what turns the
## hardware editor into build instructions and NPC fabrication chores.
static func assembly_steps(p: LinkageParams) -> Array:
	# Bracket first (it anchors the joint), then the centre slot, then outward
	# along each side — the order a pair of hands actually works in.
	var axis_order: PackedStringArray = ["center", "up", "down", "right", "left"]
	var out: Array = []
	for asm_id in LinkageHardware.ASSEMBLY_IDS:
		var asm := LinkageHardware.assembly(p.hardware_assemblies, asm_id)
		if asm.is_empty() or not bool(asm.get("detailed", false)):
			continue
		var steps: Array = []
		var pieces := 0
		var bracket := LinkageHardware.bracket_part(asm)
		if not bracket.is_empty():
			steps.append(_step(bracket))
			pieces += LinkageHardware.part_qty(bracket)
		for axis in axis_order:
			for part in LinkageHardware.parts_on_axis(asm, axis):
				steps.append(_step(part))
				pieces += LinkageHardware.part_qty(part)
		if steps.is_empty():
			continue
		out.append({
			"assembly_id": asm_id,
			"label": str(asm.get("label", asm_id)),
			"per_module_pieces": pieces,
			"steps": steps,
		})
	return out


static func _step(part: Dictionary) -> Dictionary:
	var type := str(part.get("type", ""))
	return {
		"part_id": str(part.get("id", "")),
		"label": str(part.get("label", LinkageHardware.TYPE_LABELS.get(type, type))),
		"type": type,
		"qty": LinkageHardware.part_qty(part),
		"per_module": int(part.get("perModule", 0)),
		"axis": str(part.get("axis", "right")),
		"seq": int(part.get("seq", 0)),
	}


# ---------------------------------------------------------------------------
# Mass primitives — shared with LinkageStructureBuilder.packed_spec_for
# ---------------------------------------------------------------------------

## Softwood beam mass. FPL Wood Handbook: SPF ~470 kg/m³ at 12% MC.
static func beam_mass_kg(width_in: float, thickness_in: float, length_ft: float) -> float:
	return width_in * thickness_in * (length_ft * INCHES_PER_FOOT) \
		* IN3_TO_M3 * PackedSpec.WOOD_KG_M3


## Simplified U-channel steel volume: two walls plus a base.
static func bracket_mass_kg(width_in: float, depth_in: float, height_in: float,
		wall_in: float) -> float:
	var in3 := 2.0 * (depth_in * height_in * wall_in) + (width_in * depth_in * wall_in)
	return in3 * IN3_TO_M3 * STEEL_KG_M3


## Bolt shaft volume x1.5 for the head, nut and washers that ride with it.
static func bolt_mass_kg(diameter_in: float, length_in: float) -> float:
	var r := diameter_in / 2.0
	return PI * r * r * length_in * 1.5 * IN3_TO_M3 * STEEL_KG_M3


## Flat washer annulus. BOM only — deliberately NOT added to the packed spec,
## which would move the pinned shipping masses in packing_selftest.
static func washer_mass_kg(id_in: float, od_in: float, thickness_in: float) -> float:
	return _annulus_mass_kg(id_in, od_in, thickness_in)


## Panel mass. The web app authors this in pounds per panel; convert once here
## so everything downstream stays metric.
static func panel_mass_kg(section: Dictionary) -> float:
	return maxf(0.0, float(section.get("weight", 0.0))) / LB_PER_KG


# ---------------------------------------------------------------------------
# Costs
# ---------------------------------------------------------------------------

## Volume-scaled beam price against the reference board
## (`solver.js:calculateBeamCostByVolume` :150).
static func beam_cost_by_volume(p: LinkageParams, width_in: float,
		thickness_in: float, length_ft: float) -> float:
	var ref: Dictionary = p.costs["ref_beam"]
	var ref_vol := float(ref["width"]) * float(ref["thickness"]) \
		* float(ref["length_ft"]) * INCHES_PER_FOOT
	if ref_vol <= 0.0:
		return 0.0
	var vol := width_in * thickness_in * length_ft * INCHES_PER_FOOT
	return vol * (float(ref["price"]) / ref_vol)


static func h_beam_unit_cost(p: LinkageParams) -> float:
	if bool(p.costs["auto_lumber"]):
		return beam_cost_by_volume(p, p.h_beam_w, p.h_beam_t, p.h_length_ft)
	return float(p.costs["h_beam"])


static func v_beam_unit_cost(p: LinkageParams, width_in: float, thickness_in: float) -> float:
	if bool(p.costs["auto_lumber"]):
		return beam_cost_by_volume(p, width_in, thickness_in, p.v_length_ft)
	return float(p.costs["v_beam"])


## `calculateVBeamsCost` (beam-bolt-helpers.js:199).
static func v_beams_cost(p: LinkageParams) -> float:
	var c := v_beam_counts(p)
	if bool(c["linked"]):
		return int(c["total"]) * v_beam_unit_cost(p, p.v_beam_w, p.v_beam_t)
	return int(c["inner"]) * v_beam_unit_cost(p, p.v_beam_inner_w, p.v_beam_inner_t) \
		+ int(c["outer"]) * v_beam_unit_cost(p, p.v_beam_outer_w, p.v_beam_outer_t)


## `calculateVBeamTotalWeight` (beam-bolt-helpers.js:180), in kg.
static func v_beam_total_mass_kg(p: LinkageParams) -> float:
	var c := v_beam_counts(p)
	if bool(c["linked"]):
		return int(c["total"]) * beam_mass_kg(p.v_beam_w, p.v_beam_t, p.v_length_ft)
	return int(c["inner"]) * beam_mass_kg(p.v_beam_inner_w, p.v_beam_inner_t, p.v_length_ft) \
		+ int(c["outer"]) * beam_mass_kg(p.v_beam_outer_w, p.v_beam_outer_t, p.v_length_ft)


# ---------------------------------------------------------------------------
# Derived dimensions / actuator / power
# ---------------------------------------------------------------------------

static func _dims(p: LinkageParams, frame: Dictionary) -> Dictionary:
	var h_tot := p.h_length_ft * INCHES_PER_FOOT
	var v_tot := p.v_length_ft * INCHES_PER_FOOT
	var v_bottom := p.vert_end_offset
	var v_top := v_tot - p.vert_end_offset
	var height := float(frame.get("max_height", 0.0))
	var diameter := float(frame.get("max_rad", 0.0)) * 2.0
	return {
		"height_in": height,
		"height_ft": height / INCHES_PER_FOOT,
		"diameter_in": diameter,
		"diameter_ft": diameter / INCHES_PER_FOOT,
		"h_tot_in": h_tot,
		"h_active_in": p.h_active_in(),
		"pivot_dist_from_bottom_in": p.offset_bot_in + p.h_active_in() * p.pivot_pct / 100.0,
		"v_tot_in": v_tot,
		"v_bottom_pivot_in": v_bottom,
		"v_center_pivot_in": (v_bottom + v_top) / 2.0,
		"v_top_pivot_in": v_top,
	}


## Linear-actuator travel: the change in pivot span between fully folded and
## fully deployed (`solver.js:calculateActuatorStroke` :194).
static func actuator_stroke(p: LinkageParams) -> Dictionary:
	var open_span := LinkageKinematics.pivot_span(p, LinkageKinematics.MIN_FOLD_ANGLE)
	var closed_angle := LinkageKinematics.optimal_closed_angle(p)
	var closed_span := LinkageKinematics.pivot_span(p, closed_angle)
	return {
		"open_in": open_span,
		"closed_in": closed_span,
		"stroke_in": absf(closed_span - open_span),
		"closed_angle_deg": rad_to_deg(closed_angle),
	}


## Arch mode wall-mounts the side section; cylinder mode fills the top canopy.
static func _active_panel_section(p: LinkageParams) -> Dictionary:
	var sp: Dictionary = p.solar_panels
	return sp["side_panels"] if p.orientation == "vertical" else sp["top_panels"]


static func _power_summary(p: LinkageParams, panels: Array) -> Dictionary:
	var sec := _active_panel_section(p)
	var watts := LinkageGeometry.total_watts(panels)
	return {
		"panel_count": panels.size(),
		"watts_total": watts,
		"kw": watts / 1000.0,
		"watts_per_panel": float(sec["rated_watts"]),
		"voc": float(sec["voc"]),
		"vmp": float(sec["vmp"]),
		"isc": float(sec["isc"]),
		"imp": float(sec["imp"]),
	}


# ---------------------------------------------------------------------------
# Adapters
# ---------------------------------------------------------------------------

## Counts in the shape `NpcCrewPlan.linkage_fab_tasks` consumes. Lives here so
## the crew scheduler keeps zero linkage dependencies — same layering rule as
## NpcHaulModel. `bom_bolt_count` replaces the scheduler's `modules * 6`
## estimate, and `assembly_steps` splits its one flat assemble task per joint.
static func fab_counts(bom: Dictionary, stats: Dictionary = {}) -> Dictionary:
	var c: Dictionary = bom.get("counts", {})
	var out := {
		"module_count": int(c.get("modules", 0)),
		"beam_count": int(c.get("h_beams", 0)) + int(c.get("v_beams", 0))
			+ int(c.get("support_radial", 0)) + int(c.get("support_rcp", 0))
			+ int(c.get("floor_radial", 0)) + int(c.get("floor_rcp", 0)),
		"bracket_count": int(c.get("brackets", 0)),
		"bolt_count": int(c.get("bolts_total", 0)),
		"bom_bolt_count": int(c.get("bolts_total", 0))
			+ int(c.get("support_bolts", 0)) + int(c.get("support_through", 0)),
		"panel_count": int(c.get("panels", 0)),
		"assembly_steps": bom.get("assembly_steps", []),
	}
	# A caller holding a live builder can pass get_stats() to keep the panel
	# count honest when the BOM was computed without panels enabled.
	if stats.has("panel_count"):
		out["panel_count"] = int(stats["panel_count"])
	return out


# ---------------------------------------------------------------------------
# Formatting / export
# ---------------------------------------------------------------------------

## Trim a dimension to at most 2 decimals with no trailing zeros — the web
## app's `trimTrailingZerosFromDecimalString` behaviour.
static func _dim(value: float, decimals: int = 2) -> String:
	var s := String.num(value, decimals)
	if s.contains("."):
		s = s.rstrip("0").rstrip(".")
	return "%s\"" % s


static func _trim(value: float, decimals: int = 2) -> String:
	var s := String.num(value, decimals)
	if s.contains("."):
		s = s.rstrip("0").rstrip(".")
	return s


## `8' x 3.5x1.5"` (`unit-converter.js:formatBeamSpecForCost` :600).
static func format_beam_spec(length_ft: float, width_in: float, thickness_in: float) -> String:
	return "%s' x %sx%s\"" % [_trim(length_ft), _trim(width_in), _trim(thickness_in)]


## `(1/2" x 3.00")` (`unit-converter.js:formatBoltSpec` :563).
static func format_bolt_spec(diameter_in: float, length_in: float) -> String:
	var frac := ""
	for key in BOLT_FRACTIONS:
		if absf(diameter_in - float(key)) < 1e-6:
			frac = str(BOLT_FRACTIONS[key])
			break
	if frac == "":
		# Fixed decimals, not String.num — it trims trailing zeros, and a spec
		# sheet reading 3/8" x 3" is ambiguous where 3.00" is not.
		frac = "%.3f" % diameter_in
	return "(%s\" x %.2f\")" % [frac, length_in]


## Mass for display. Metric is canonical; lb is the convenience conversion.
static func fmt_mass(kg: float, metric: bool = true) -> String:
	if metric:
		return "%s kg" % String.num(kg, 1)
	return "%s lbs" % String.num(kg * LB_PER_KG, 1)


## Spreadsheet export (`build-guide.js:exportBOMcsv` :2504).
static func to_csv(bom: Dictionary, metric: bool = true) -> String:
	var rows: Array = []
	rows.append(["LinkageLab Build Guide - Bill of Materials"])
	rows.append([])
	rows.append(["Section", "Qty", "Item", "Unit Price", "Line Total", "Line Mass"])
	rows.append([])
	rows.append(["STRUCTURE", "", "", "", "", ""])
	for item in bom.get("structure_items", []):
		rows.append(_csv_item_row(item, metric))
	rows.append(["", "", "", "Structure Subtotal:",
		"$%s" % String.num(float(bom.get("structure_cost", 0.0)), 2), ""])
	var power_items: Array = bom.get("power_items", [])
	if not power_items.is_empty():
		rows.append([])
		rows.append(["POWER", "", "", "", "", ""])
		for item in power_items:
			rows.append(_csv_item_row(item, metric))
		rows.append(["", "", "", "Power Subtotal:",
			"$%s" % String.num(float(bom.get("power_cost", 0.0)), 2), ""])
	var enclosure_items: Array = bom.get("enclosure_items", [])
	if not enclosure_items.is_empty():
		rows.append([])
		rows.append(["ENCLOSURE", "", "", "", "", ""])
		for item in enclosure_items:
			rows.append(_csv_item_row(item, metric))
		rows.append(["", "", "", "Enclosure Subtotal:",
			"$%s" % String.num(float(bom.get("enclosure_cost", 0.0)), 2), ""])
	rows.append([])
	rows.append(["", "", "", "ESTIMATED TOTAL:",
		"$%s" % String.num(float(bom.get("total_cost", 0.0)), 2), ""])

	var mass: Dictionary = bom.get("mass", {})
	rows.append([])
	rows.append(["WEIGHT BREAKDOWN", "", "", "", "", ""])
	for pair in [["Horizontal Beams", "h_beams_kg"], ["Vertical Beams", "v_beams_kg"],
			["Brackets", "brackets_kg"], ["Bolts", "bolts_kg"], ["Washers", "washers_kg"],
			["Support beams & hardware", "support_kg"], ["Floor beams", "floor_kg"],
			["Assembly hardware", "hardware_kg"], ["Solar Panels", "panels_kg"]]:
		var kg := float(mass.get(pair[1], 0.0))
		if kg > 0.0:
			rows.append(["", "", str(pair[0]), "", "", fmt_mass(kg, metric)])
	rows.append(["", "", "", "Total Weight:", "",
		fmt_mass(float(mass.get("total_kg", 0.0)), metric)])

	for warning in bom.get("warnings", []):
		rows.append([])
		rows.append(["NOTE", str(warning), "", "", "", ""])

	var lines: PackedStringArray = []
	for row in rows:
		var cells: PackedStringArray = []
		for cell in row:
			cells.append(_csv_cell(str(cell)))
		lines.append(",".join(cells))
	return "\r\n".join(lines)


static func _csv_item_row(item: Dictionary, metric: bool) -> Array:
	return [
		"", int(item["qty"]), str(item["item"]),
		"$%s" % String.num(float(item["unit_cost"]), 2),
		"$%s" % String.num(float(item["total_cost"]), 2),
		fmt_mass(float(item["total_mass_kg"]), metric),
	]


static func _csv_cell(s: String) -> String:
	if s.contains(",") or s.contains("\"") or s.contains("\n"):
		return "\"%s\"" % s.replace("\"", "\"\"")
	return s


## v30 config plus the derived `summary` block the web app writes on export.
## `LinkageParams.to_config()` deliberately omits `summary` (it would bust the
## packed-spec cache key); this is where it gets added back.
static func to_json(p: LinkageParams, bom: Dictionary) -> Dictionary:
	var cfg := p.to_config()
	var dims: Dictionary = bom.get("dims", {})
	var power: Dictionary = bom.get("power", {})
	cfg["summary"] = {
		"modules": p.modules,
		"mode": "arch" if p.orientation == "vertical" else "cylinder",
		"foldAngle": rad_to_deg(p.fold_angle),
		"panelCount": int(power.get("panel_count", 0)),
		"totalWatts": float(power.get("watts_total", 0.0)),
		"structureDimensions": {
			"maxRadius": float(dims.get("diameter_in", 0.0)) / 2.0,
			"maxHeight": float(dims.get("height_in", 0.0)),
		},
		"estimatedCost": float(bom.get("total_cost", 0.0)),
		"estimatedMassKg": float((bom.get("mass", {}) as Dictionary).get("total_kg", 0.0)),
	}
	return cfg
