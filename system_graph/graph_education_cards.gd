class_name GraphEducationCards
extends RefCounted

## One-liner education cards for habitat / catchment / waste / import nodes.
## Shown in the inspector when a matching item is selected.

## Returns {title, body} or {} if no card applies.
static func card_for_item(item: Dictionary) -> Dictionary:
	var ty := str(item.get("type", ""))
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var role := str(specs.get("role", ""))
	match ty:
		"pbi":
			var pk := str(specs.get("resource_kind", ""))
			if pk == "water" or pk == "rain":
				return {
					"title": "Rain (Planetary Basic Income)",
					"body": "Local rain available over your Sphere of Influence. "
							+ "Wire this node into rain catchments — there is no rate dial; "
							+ "weather and catchment area set the flow. Not an external import.",
				}
			return {}
		"catchment":
			if str(specs.get("catchment_kind", "rain")) == "biomass":
				return {
					"title": "SoI Biomass PBI",
					"body": "Local dry biomass income from your Sphere of Influence "
							+ "(~1.2 kg/m²/yr, seasonally scaled). Wire output → Biomass Store. "
							+ "Expand the SoI in Snowglobe to raise daily yield.",
				}
			return {
				"title": "Rain Catchment",
				"body": "Wire Rain PBI → this catchment → a water tank. Capture rate is "
						+ "mm/h × catchment area × runoff (local Planetary Basic Income — "
						+ "does not count as an external import). When the tank is full, "
						+ "delivery stops so you are not flooded with overflow warnings.",
			}
		"processor":
			if role == "habitat":
				var occ := int(specs.get("occupants", 1))
				return {
					"title": "Habitat (%d person%s)" % [occ, "s" if occ != 1 else ""],
					"body": "Mouths to feed: water + food in, grey/black water + food scraps out. "
							+ "Starves when an input tank empties. Typical rates ~50 L and "
							+ "~1.5 kg food per person per day.",
				}
			if role == "import" or bool(specs.get("counts_as_import", false)):
				return {
					"title": "External Import",
					"body": "Counts against closure score — useful for bridging dry weeks, "
							+ "but the puzzle win condition rewards local supply. "
							+ "Wire only when tanks would otherwise hit empty.",
				}
			var name_l := str(specs.get("name", "")).to_lower()
			if "greywater" in name_l or "filter" in name_l:
				return {
					"title": "Greywater Recycle",
					"body": "Turns greywater back into usable water. Raises waste-channel "
							+ "closure. Needs power if watts > 0 — keep AC available.",
				}
			if "digest" in name_l or "compost" in name_l or "biodigest" in name_l:
				return {
					"title": "Organic Digester",
					"body": "Converts blackwater / biomass into nutrients, liquid fertilizer, "
							+ "or biogas. Wire habitat waste + food-scrap tanks to the inputs; "
							+ "IBC biodigester ≈ 5 gal/d + 1 kg/d + 300 Wh.",
				}
		"resource":
			var kind := str(specs.get("resource_kind", ""))
			match kind:
				"water":
					return {
						"title": "Water Store",
						"body": "Autonomy days = stock ÷ daily habitat demand. "
								+ "Fill from rain catchment or (costly) imports.",
					}
				"food":
					return {
						"title": "Food Store",
						"body": "Tracks edible mass. Habitat drains it; imports or local "
								+ "production refill it. Watch the Needs strip Food chip.",
					}
				"biomass":
					return {
						"title": "Biomass Store",
						"body": "Receives SoI PBI yield and habitat food scraps. Feed digesters "
								+ "or hold as a buffer for organic loops.",
					}
				"greywater", "blackwater":
					return {
						"title": "Waste Tank",
						"body": "Habitat effluent. Recycle it or it accumulates — "
								+ "waste closure falls when production outruns treatment. "
								+ "Drag one tank onto another of the same type to merge capacity.",
					}
				"biogas", "liquid_fertilizer":
					return {
						"title": ResourceKinds.display_name(kind) + " Store",
						"body": "Digester output buffer. Connect to the IBC biodigester out ports "
								+ "or merge tanks by dragging one onto another.",
					}
	return {}
