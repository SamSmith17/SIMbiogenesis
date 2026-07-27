class_name RecipeCatalog
extends RefCounted

## Crafting recipes that convert fabricated parts (trash printer / beam extruder
## inventory) into a placeable structure. Geodesic dome: print 3 hub types on the
## trash printer, cut A/B struts from extruded beams, then Assemble & place.

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
		"note": "Pathways: print hubs on the trash printer; make A/B struts by (1) printing them on the trash printer, or (2) extruding recycled-plastic beams then milling them on the CNC router (Cut Dome A/B-Strut presets). Assemble into a standable 2V dome (~2.4 m radius).",
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
