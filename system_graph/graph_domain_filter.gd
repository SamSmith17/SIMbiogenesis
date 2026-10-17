class_name GraphDomainFilter
extends RefCounted

## Show-only views for the systems graph: hide every node and wire that is not
## part of the chosen DOMAINS (power, water, food…) without removing anything
## from the model. Pure — the canvas asks it which of its scope's items and
## connections stay visible (`_compute_visible_items/_connections`), and that
## one cache already feeds the draw, every hit-test, the marquee and the wire
## bundles, so a hidden node can be neither seen nor clicked.
##
## A WIRE's domain comes from its polarity (every non-resource polarity —
## DC +/-, AC, PV, load, parallel, smart battery — is electrical) or, for a
## resource wire, from its `resource_type`. A NODE's domains are the domains of
## its ports (a compound adds every descendant's ports, so a power station
## shows under Power even though its promoted ports may be few). Ambient ports
## (sunlight, wind) never decide a node's visibility on their own: every panel
## has a sunlight port and would otherwise show under an "ambient" view only.

const POWER := "power"
const WATER := "water"
const FOOD := "food"
const FUEL := "fuel"
const MATERIALS := "materials"
const AMBIENT := "ambient"
const OTHER := "other"

## Display order + labels for the menu and the chip.
const DOMAINS := [POWER, WATER, FOOD, FUEL, MATERIALS, OTHER]
const LABELS := {
	POWER: "Power", WATER: "Water", FOOD: "Food & waste", FUEL: "Fuel & heat",
	MATERIALS: "Materials", AMBIENT: "Sun & wind", OTHER: "Other",
}

## Resource kind -> domain. Kinds not listed (user kinds, money, chore hours)
## are OTHER. Aliases are resolved through ResourceKinds.normalize_kind first.
const KIND_DOMAIN := {
	"electric": POWER, "dc_electricity": POWER,
	"water": WATER, "greywater": WATER, "blackwater": WATER, "hot_water": WATER,
	"stormwater": WATER,
	"food": FOOD, "meal": FOOD, "biomass": FOOD, "food_waste": FOOD, "manure": FOOD,
	"nutrients": FOOD, "liquid_fertilizer": FOOD, "soil": FOOD, "biochar": FOOD,
	"steam": FUEL, "woodgas": FUEL, "biogas": FUEL, "propane": FUEL, "thermal": FUEL,
	"plastic_waste": MATERIALS, "plastic_shred": MATERIALS, "plastic_flake": MATERIALS,
	"plastic_sheet": MATERIALS, "finished_part": MATERIALS, "mud": MATERIALS,
	"packaging_waste": MATERIALS,
	"sunlight": AMBIENT, "wind": AMBIENT,
}


static func kind_domain(kind: String) -> String:
	var k := ResourceKinds.normalize_kind(kind)
	return str(KIND_DOMAIN.get(k, KIND_DOMAIN.get(kind, OTHER)))


## A port's domain: electrical for every non-resource polarity.
static func handle_domain(h: Dictionary) -> String:
	if str(h.get("polarity", "")) == "resource":
		return kind_domain(str(h.get("resource_kind", "")))
	return POWER


static func conn_domain(conn: Dictionary) -> String:
	if str(conn.get("polarity", "")) == "resource":
		return kind_domain(str(conn.get("resource_type", "")))
	return POWER


## The set of domains a list of ports belongs to (ambient ports left out).
static func handles_domains(handles: Array) -> Dictionary:
	var out := {}
	for h in handles:
		if h is Dictionary:
			var d := handle_domain(h)
			if d != AMBIENT:
				out[d] = true
	return out


## True when `shown` hides nothing (empty = show everything).
static func is_all(shown: Dictionary) -> bool:
	if shown.is_empty():
		return true
	for d in DOMAINS:
		if not shown.get(d, false):
			return false
	return true


## Keep the connections whose domain is shown. An ambient wire (sun -> panel)
## shows when its OTHER end's node is shown, i.e. along with the panels.
static func filter_connections(conns: Array, shown: Dictionary, visible_ids: Dictionary = {}) -> Array:
	if is_all(shown):
		return conns
	var out: Array = []
	for c in conns:
		var cd: Dictionary = c
		var d := conn_domain(cd)
		if d == AMBIENT:
			if visible_ids.has(str(cd.get("source_item_id", ""))) \
					and visible_ids.has(str(cd.get("target_item_id", ""))):
				out.append(cd)
			continue
		if shown.get(d, false):
			out.append(cd)
	return out


## Keep the items that belong to a shown domain.
##   `item_domains`: Callable(item) -> Dictionary set of the item's port
##     domains (the canvas resolves ports and, for compounds, descendants).
##   `include_unwired`: false = a node must have a WIRE in a shown domain;
##     true = having a PORT in a shown domain is enough (a battery just
##     dropped on the canvas stays visible under Power).
##   Items with no ports at all (notes, labels) are hidden by any filter.
static func filter_items(items: Array, conns: Array, shown: Dictionary,
		item_domains: Callable, include_unwired: bool = true) -> Array:
	if is_all(shown):
		return items
	var wired := {}   # item id -> {domain: true}
	for c in conns:
		var cd: Dictionary = c
		var d := conn_domain(cd)
		for k in ["source_item_id", "target_item_id"]:
			var iid := str(cd.get(k, ""))
			if not wired.has(iid):
				wired[iid] = {}
			(wired[iid] as Dictionary)[d] = true
	var out: Array = []
	for it in items:
		var item: Dictionary = it
		var iid := str(item.get("id", ""))
		var keep := false
		var wd: Dictionary = wired.get(iid, {})
		for d in wd.keys():
			if shown.get(d, false):
				keep = true
				break
		if not keep and include_unwired:
			var doms: Dictionary = item_domains.call(item)
			for d in doms.keys():
				if shown.get(d, false):
					keep = true
					break
		if keep:
			out.append(item)
	return out


## "Power", "Power + Water", "All" — for the chip and menu check marks.
static func describe(shown: Dictionary) -> String:
	if is_all(shown):
		return "All"
	var parts := PackedStringArray()
	for d in DOMAINS:
		if shown.get(d, false):
			parts.append(str(LABELS[d]))
	return "Nothing" if parts.is_empty() else " + ".join(parts)


## Preset id -> domain set. "all" is the empty set.
static func preset(id: String) -> Dictionary:
	match id:
		"power":
			return {POWER: true}
		"water":
			return {WATER: true}
		"food":
			return {FOOD: true, MATERIALS: true}
		"fuel":
			return {FUEL: true}
	return {}


## Save-state round trip: an Array of domain ids (empty = all).
static func to_array(shown: Dictionary) -> Array:
	if is_all(shown):
		return []
	var out: Array = []
	for d in DOMAINS:
		if shown.get(d, false):
			out.append(d)
	return out


static func from_array(a: Variant) -> Dictionary:
	var out := {}
	if a is Array:
		for d in a:
			if str(d) in DOMAINS:
				out[str(d)] = true
	return out
