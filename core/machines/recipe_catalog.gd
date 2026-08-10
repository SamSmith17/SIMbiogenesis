class_name RecipeCatalog
extends RefCounted

## Crafting recipes that convert fabricated parts (trash printer / beam extruder
## inventory) into a placeable structure. Geodesic dome: print 3 hub types on the
## trash printer, cut A/B struts from extruded beams, then Assemble & place.
##
## A recipe with a `labour` block is CREW-ASSEMBLED: parts are debited when the
## project is queued (refunded on cancel), the structure stands as a ghost at
## the picked site, and the phases become real chore-board work through a site
## project (kind "assembly"). `graph_preset` names the ComponentPresets entry a
## finished structure binds into the 2D graph as (via
## create_bound_generator_node); null/absent = a purely physical structure.
## Phase rows are NpcCrewPlan/chore_specs-shaped: {id, label, work_s,
## min_workers, max_workers} — work_s is PERSON-seconds.

const RECIPES: Array = [
	{
		"id": "geodesic_dome",
		"label": "Recycled Plastic Geodesic Dome (2V)",
		"requires": {
			"dome_hub_4way": 10,
			"dome_hub_5way": 6,
			"dome_hub_6way": 10,
			"dome_strut_a": 35,
			"dome_strut_b": 30,
		},
		"output": {"model_id": "geodesic_dome", "label": "Geodesic Dome (2V)"},
		"labour": {"phases": [
			{"id": "layout", "label": "Lay out hubs and struts", "work_s": 1800.0,
				"min_workers": 1, "max_workers": 2},
			{"id": "frame", "label": "Raise the dome frame", "work_s": 14400.0,
				"min_workers": 2, "max_workers": 4},
			{"id": "skin", "label": "Fit and fasten the skin", "work_s": 7200.0,
				"min_workers": 1, "max_workers": 3},
		]},
		"note": "Pathways: print hubs on the trash printer; make A/B struts by (1) printing them on the trash printer, or (2) extruding recycled-plastic beams then milling them on the CNC router (Cut Dome A/B-Strut presets). Assemble into a standable 2V dome (~2.4 m radius).",
	},
	{
		# Wind turbine from the plastics loop: extruded beams for the tower and
		# frame, pressed sheets cut into blades. Both parts are producible
		# today (PP Beam Extruder / PP Sheet Press).
		"id": "vawt_turbine",
		"label": "Recycled Plastic VAWT (400 W)",
		"requires": {
			"pp_beam": 6,
			"pp_sheet_8mm": 3,
		},
		"output": {"model_id": "vawt", "label": "VAWT (400 W)"},
		"graph_preset": "VAWT 400W",
		"labour": {"phases": [
			{"id": "tower", "label": "Stand the tower", "work_s": 7200.0,
				"min_workers": 2, "max_workers": 3},
			{"id": "rotor", "label": "Build and hang the rotor", "work_s": 10800.0,
				"min_workers": 1, "max_workers": 3},
			{"id": "commission", "label": "Commission and guy off", "work_s": 3600.0,
				"min_workers": 2, "max_workers": 2},
		]},
		"note": "Extrude 6 beams (PP Beam Extruder) and press 3 sheets (PP Sheet Press), then assemble with a crew. Joins the 2D graph as a live 400 W wind generator when commissioned.",
	},
]


static func all_recipes() -> Array:
	return RECIPES.duplicate(true)


static func find(recipe_id: String) -> Dictionary:
	for r: Dictionary in RECIPES:
		if str(r.get("id", "")) == recipe_id:
			return (r as Dictionary).duplicate(true)
	return {}


static func can_craft(inventory: PartInventory, recipe_id: String) -> bool:
	if inventory == null:
		return false
	var r := find(recipe_id)
	if r.is_empty():
		return false
	var req: Dictionary = r.get("requires", {})
	for pid in req:
		if inventory.count(str(pid)) < int(req[pid]):
			return false
	return true


## Returns {part_id: shortfall_qty} for the parts still missing (empty when
## the recipe can be crafted).
static func missing(inventory: PartInventory, recipe_id: String) -> Dictionary:
	var out: Dictionary = {}
	var r := find(recipe_id)
	if r.is_empty():
		return out
	var req: Dictionary = r.get("requires", {})
	for pid in req:
		var need := int(req[pid])
		var have := inventory.count(str(pid)) if inventory != null else 0
		if have < need:
			out[str(pid)] = need - have
	return out


## Consumes the required parts if available. Returns true on success.
static func spend(inventory: PartInventory, recipe_id: String) -> bool:
	if not can_craft(inventory, recipe_id):
		return false
	var r := find(recipe_id)
	var req: Dictionary = r.get("requires", {})
	for pid in req:
		inventory.remove_part(str(pid), int(req[pid]))
	return true
