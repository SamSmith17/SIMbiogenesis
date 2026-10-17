class_name GraphPortLabels
extends RefCounted

## Player-facing names for graph nodes and their ports. The port tooltip and
## the wire-drag hint used to print the raw model ids — "item_11.pvNegative
## [negative]", "Release to connect: item_1.negative" — which tell a player
## nothing. Pure static, so the selftests can pin the table.

## Handle id → label. Ids that repeat across types (positive/negative) are
## generic terminals; the node name in front says which box they are on.
const PORT_NAMES := {
	"positive": "+ terminal",
	"negative": "− terminal",
	"pvPositive": "PV +",
	"pvNegative": "PV −",
	"batteryPositive": "Battery +",
	"batteryNegative": "Battery −",
	"acOutput": "AC out",
	"acOutputLeft": "AC out",
	"acOutputTop": "AC out",
	"acOutputBottom": "AC out",
	"sunlight_in": "Sunlight in",
	"wind_in": "Wind in",
	"power_in": "Power in",
	"input": "Input",
	"inputRight": "Input",
	"inputTop": "Input",
	"inputBottom": "Input",
	"output": "Output",
	"input1": "Input 1",
	"input2": "Input 2",
	"input3": "Input 3",
}

## Type → generic noun when a node has no name of its own.
const TYPE_NOUNS := {
	"panel": "Solar panel", "wind": "Wind turbine", "hydro": "Hydro turbine",
	"battery": "Battery", "smartbattery": "Smart battery", "controller": "Controller",
	"appliance": "Appliance", "acload": "AC load", "processor": "Machine",
	"resource": "Tank", "catchment": "Catchment", "compound": "Group",
	"breaker": "Breaker", "combiner": "Combiner box", "acbreaker": "AC breaker",
	"acoutlet": "Outlet", "pbi": "Planetary input", "shelly4pm": "Smart relay",
}


static func node_name(item: Dictionary) -> String:
	var specs: Dictionary = item.get("specs", {}) if item.get("specs", {}) is Dictionary else {}
	var n := str(specs.get("name", item.get("label", ""))).strip_edges()
	if not n.is_empty():
		return n
	var t := str(item.get("type", ""))
	return str(TYPE_NOUNS.get(t, UiText.from_id(t) if not t.is_empty() else "Node"))


## "Input 2 · Water" style for resource ports, the table otherwise.
static func port_name(handle_id: String, resource_kind: String = "") -> String:
	if PORT_NAMES.has(handle_id):
		return str(PORT_NAMES[handle_id])
	var rk := ""
	if not resource_kind.is_empty():
		rk = ResourceKinds.display_name(resource_kind)
	for pre in ["res_in_", "res_out_"]:
		if handle_id.begins_with(pre):
			var idx := handle_id.trim_prefix(pre)
			var dir := "in" if pre == "res_in_" else "out"
			if not rk.is_empty():
				return "%s %s" % [rk, dir]
			return "%s %s" % ["Input" if dir == "in" else "Output", idx]
	if not rk.is_empty():
		return rk
	return UiText.from_id(handle_id)


## "Trainer MPPT 150V 30A · PV +" — the one label a port gets everywhere.
static func port_label(item: Dictionary, handle_id: String, resource_kind: String = "") -> String:
	return "%s · %s" % [node_name(item), port_name(handle_id, resource_kind)]
