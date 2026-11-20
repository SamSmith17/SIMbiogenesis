class_name ServicePalette
extends RefCounted

## What a run carries, as a colour. The Process lens and the 3D lens views
## (Globe, Site Plan, Elevation) colour runs by service so a plant reads at a
## glance, like an as-built drawing: hot water red, cold water blue, drains
## grey, power yellow, data green. First person keeps each material's own
## colour (white PVC, yellow cord). Pure static.
##
## The families follow ANSI/ASME A13.1 pipe marking where it has one
## (reclaimed water purple, flammable gas yellow-brown); the player chose the
## hot / cold / drain / power / data colours.

const SERVICES: Dictionary = {
	"hot_water": {"label": "Hot water", "color": Color(0.90, 0.24, 0.20)},
	"cold_water": {"label": "Water", "color": Color(0.20, 0.52, 0.95)},
	"reclaimed": {"label": "Reclaimed water", "color": Color(0.60, 0.38, 0.88)},
	"drain": {"label": "Drain / waste", "color": Color(0.56, 0.54, 0.50)},
	"fuel": {"label": "Fuel / gas", "color": Color(0.86, 0.58, 0.16)},
	"steam": {"label": "Steam / heat", "color": Color(1.0, 0.50, 0.36)},
	"air": {"label": "Air", "color": Color(0.58, 0.82, 0.96)},
	"solids": {"label": "Material", "color": Color(0.62, 0.44, 0.26)},
	"power_ac": {"label": "AC power", "color": Color(0.98, 0.82, 0.18)},
	"power_dc": {"label": "DC power", "color": Color(0.98, 0.52, 0.12)},
	"data": {"label": "Data", "color": Color(0.30, 0.84, 0.46)},
	"other": {"label": "Other", "color": Color(0.70, 0.71, 0.74)},
}

const _KIND_SERVICE: Dictionary = {
	"hot_water": "hot_water", "thermal": "steam", "steam": "steam",
	"water": "cold_water", "rainwater": "cold_water", "distilled_water": "cold_water",
	"seawater": "cold_water", "irrigation_water": "reclaimed", "wash_water": "drain",
	"greywater": "drain", "blackwater": "drain", "brownwater": "drain",
	"urine": "drain", "brine": "drain", "stormwater": "drain", "runoff": "drain",
	"liquid_fertilizer": "reclaimed", "nutrients": "reclaimed",
	"woodgas": "fuel", "biogas": "fuel", "propane": "fuel", "gasoline": "fuel",
	"diesel": "fuel", "plastic_oil": "fuel", "wood_vinegar": "fuel", "wood_acid": "fuel", "tar": "fuel",
	"electric": "power_ac", "dc_electricity": "power_dc",
}

const _CONDUIT_SERVICE: Dictionary = {
	"pex_red": "hot_water", "pex_blue": "cold_water", "ethernet": "data",
	"ducting": "air", "dc_solar": "power_dc", "abs_dwv": "drain",
	"culvert_pipe": "drain",
}


## The service a connection carries: data wires, then its resource kind, then
## its polarity, then what its conduit kind implies.
static func service_for(conn: Dictionary) -> String:
	var pol := str(conn.get("polarity", ""))
	if pol == "data":
		return "data"
	var kind := str(conn.get("resource_kind", ""))
	if not kind.is_empty():
		var norm := ResourceKinds.normalize_kind(kind)
		if _KIND_SERVICE.has(norm):
			return str(_KIND_SERVICE[norm])
		if pol == "resource" or pol.is_empty():
			return "solids"
	if pol in ["positive", "negative", "pv", "parallel", "smart_battery"]:
		return "power_dc"
	if pol in ["ac", "ac_240", "load"]:
		return "power_ac"
	var ct := str(conn.get("conduit_type", ""))
	if _CONDUIT_SERVICE.has(ct):
		return str(_CONDUIT_SERVICE[ct])
	if ConduitKinds.is_electrical_type(ct):
		return "power_ac"
	return "other"


static func color_for(conn: Dictionary) -> Color:
	return color_of(service_for(conn))


static func color_of(service: String) -> Color:
	return (SERVICES.get(service, SERVICES["other"]) as Dictionary)["color"] as Color


static func label_of(service: String) -> String:
	return str((SERVICES.get(service, SERVICES["other"]) as Dictionary)["label"])


## Lane order inside a bundle: power and data apart from water, hot above cold.
static func lane_rank(service: String) -> int:
	var order := ["data", "power_dc", "power_ac", "steam", "hot_water", "cold_water",
		"reclaimed", "air", "fuel", "solids", "drain", "other"]
	var i := order.find(service)
	return i if i >= 0 else order.size()
