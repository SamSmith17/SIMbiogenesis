class_name LinkageEnclosure
extends RefCounted
## One structure's enclosure (A4): the raised-floor deck, the coverings
## (walls / fabric / tables) and the roof shade tarps, computed the way
## `buildLinkageGeometry` does — deck first (the walls can start on it), then
## the coverings, then the tarps (above the covering bands). The ONE place
## LinkagePartKeys.part_data, the builder and the BOM ask, so the parts they
## see cannot disagree.
##
## `beams` = the solved frame's beams + support beams + floor beams.


static func compute(beams: Array, p: LinkageParams) -> Dictionary:
	var deck := LinkageFloor.deck(beams, p)
	var floor_top := float(deck["y_top"]) if not deck.is_empty() else NAN
	var cov := {}
	if bool(LinkageCoverings.config(p)["enabled"]):
		cov = LinkageCoverings.compute(beams, p, floor_top)
	var cov_shapes: Array = cov.get("shapes", []) if bool(cov.get("supported", false)) else []
	var shade := {}
	if bool(LinkageShadeCloth.config(p)["enabled"]):
		shade = LinkageShadeCloth.compute(beams, p, band_top(cov_shapes))
	var shade_shapes: Array = shade.get("shapes", []) if bool(shade.get("supported", false)) else []
	# Collection order as the web's collectParts: coverings, deck, tarps.
	var walls: Array = cov_shapes.duplicate()
	if not deck.is_empty():
		walls.append(deck)
	walls.append_array(shade_shapes)
	return {"walls": walls, "coverings": cov, "covering_shapes": cov_shapes, "deck": deck,
		"shade": shade, "shade_shapes": shade_shapes}


## The top of the lower / upper wall bands (NAN = none): the tarps go above it.
static func band_top(cov_shapes: Array) -> float:
	var top := NAN
	for sh in cov_shapes:
		var band := str(sh.get("band", ""))
		if band == "upper" or band == "lower":
			top = float(sh["y_top"]) if is_nan(top) else maxf(top, float(sh["y_top"]))
	return top


## One structure's enclosure at the DEPLOYED pose (the BOM / cut plan).
static func deployed(p: LinkageParams) -> Dictionary:
	var closed := LinkageKinematics.optimal_closed_angle(p)
	var frame := LinkageSolver.solve(p, closed)
	var beams: Array = (frame["beams"] as Array).duplicate()
	beams.append_array(LinkageGeometry.support_beams(frame, p, closed))
	beams.append_array(LinkageFloor.floor_beams(frame["beams"], p, closed))
	return compute(beams, p)


## The cut plan + ENCLOSURE BOM rows of one structure: {plan, items, cost}.
static func bom(p: LinkageParams) -> Dictionary:
	var enc := deployed(p)
	var plan := LinkageCoveringPlan.compute(enc["covering_shapes"], LinkageCoverings.config(p), enc["deck"])
	var items := LinkageCoveringPlan.bom_items(plan, p)
	items.append_array(LinkageShadeCloth.bom_items(enc["shade"], p))
	var cost := 0.0
	for it in items:
		cost += float(it["total_cost"])
	return {"plan": plan, "items": items, "cost": cost, "enclosure": enc}
