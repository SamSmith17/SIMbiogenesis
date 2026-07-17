class_name GraphEducationCards
extends RefCounted

## One-liner education cards for habitat / catchment / waste / import / solar nodes.
## Shown in the inspector when a matching item (or radiant wire) is selected.

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
			if pk == "sunlight" or pk == "solar":
				return {
					"title": "Sunlight (Planetary Basic Income)",
					"body": "Real irradiance (W/m²) × your Sphere of Influence area = total solar "
							+ "flux available right now. Cloud cover reduces this shared availability. "
							+ "Sunlight isn't piped like water — panels and grow beds draw from it "
							+ "ambiently even with no wire drawn; an optional radiant wire just "
							+ "visualizes the link. Place receivers on the Site Plan to get per-node "
							+ "3D shade (buildings/trees) written into each node's sunlight factor. "
							+ "Not an external import.",
				}
			if pk == "wind" or pk == "mechanical" or pk == "atmosphere" or pk == "air":
				return {
					"title": "Wind (Planetary Basic Income)",
					"body": "Atmosphere over your Sphere of Influence: wind speed, temperature, "
							+ "and relative humidity from live weather. Kinetic flux (½ρAv³ through "
							+ "an SoI-wide slab) is an educational total — turbines already feel "
							+ "the wind ambiently; an optional dashed wire only visualizes the link. "
							+ "Not an external import.",
				}
			return {}
		"panel":
			return {
				"title": "Solar panel (ambient light)",
				"body": "Array output comes from SolarUI physics, then each graph panel's "
						+ "share is multiplied by its sunlight factor (3D shade). "
						+ "The optional radiant wire from Sunlight PBI is documentary — "
						+ "omitting it does not cut power. Place the panel on the Site Plan "
						+ "for per-node shading.",
			}
		"catchment":
			# Legacy biomass catchments may still exist in old saves; grow beds
			# are the supported light-driven biomass path.
			if str(specs.get("catchment_kind", "rain")) == "biomass":
				return {
					"title": "Legacy SoI Biomass Catchment",
					"body": "Biomass is no longer a Planetary Basic Income — it is a "
							+ "downstream product of sunlight via Grow Bed nodes. "
							+ "Prefer a Grow Bed wired to a biomass store. This catchment "
							+ "remains for older saves only.",
				}
			return {
				"title": "Rain Catchment",
				"body": "Wire Rain PBI → this catchment → a water tank. Capture rate is "
						+ "mm/h × catchment area × runoff (local Planetary Basic Income — "
						+ "does not count as an external import). When the tank is full, "
						+ "delivery stops so you are not flooded with overflow warnings.",
			}
		"plant":
			return {
				"title": "Grow Bed (photosynthesis)",
				"body": "Monteith light-use efficiency: dry biomass ≈ LUE × PAR × area, "
						+ "limited by water (required) and nutrients (optional if wired). "
						+ "Sunlight is ambient — panels and beds work without a radiant wire "
						+ "from the Solar PBI; drawing one just visualizes the link. "
						+ "Wire water → grow bed → biomass tank. Place on the Site Plan "
						+ "for 3D shade on the sunlight factor.",
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
						"body": "Receives grow-bed harvest and habitat food scraps. Feed digesters "
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


## Education for a selected connection (radiant sunlight wires, etc.).
## Returns {title, body} or {}.
static func card_for_connection(conn: Dictionary) -> Dictionary:
	if str(conn.get("polarity", "")) != "resource":
		return {}
	var kind := ResourceKinds.normalize_kind(str(conn.get("resource_type", "")))
	if kind == "sunlight":
		return {
			"title": "Radiant sunlight wire",
			"body": "Dashed gold links are ambient documentation, not a pipe. "
					+ "Panels and grow beds still receive SoI sunlight with no wire drawn. "
					+ "Dash speed and glow scale with SoI flux (kW); removing the wire "
					+ "never gates output.",
		}
	if kind == "wind":
		return {
			"title": "Radiant atmosphere wire",
			"body": "Dashed teal links document ambient wind/atmosphere. "
					+ "Turbines already use WeatherService wind without this wire — "
					+ "drawing it never gates generation.",
		}
	return {}
