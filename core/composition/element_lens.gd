class_name ElementLens
extends RefCounted

## "Colour by element" for the systems graph (resource composition plan
## Phase 4). Pure: which quantity a lens follows, how much of it an embodied
## flow carries, its colour and its words. The canvas reads it to colour and
## size wires, the Sankey and the timeline tracks to label amounts.
##
## A lens id is an element symbol (C H O N P K), "water" (all the water a
## flow carries, free and bound) or "energy" (chemical + sensible energy, MJ).
## Amounts are kg (MJ for energy); a rate is per hour.

const LENSES := [
	{"id": "C", "label": "Carbon", "color": Color(0.62, 0.66, 0.70)},
	{"id": "H", "label": "Hydrogen", "color": Color(0.55, 0.85, 1.00)},
	{"id": "O", "label": "Oxygen", "color": Color(1.00, 0.45, 0.42)},
	{"id": "N", "label": "Nitrogen", "color": Color(0.45, 0.58, 1.00)},
	{"id": "P", "label": "Phosphorus", "color": Color(1.00, 0.68, 0.30)},
	{"id": "K", "label": "Potassium", "color": Color(0.78, 0.50, 1.00)},
	{"id": "water", "label": "Water", "color": Color(0.22, 0.78, 0.95)},
	{"id": "energy", "label": "Chemical energy", "color": Color(1.00, 0.82, 0.25)},
]
## Index of each lens in a vector of amounts (ElementHistory stores eight).
const INDEX := {"C": 0, "H": 1, "O": 2, "N": 3, "P": 4, "K": 5, "water": 6, "energy": 7}
const SIZE := 8
## Wire width range on the canvas, px at zoom 1.
const WIDTH_MIN := 1.5
const WIDTH_MAX := 9.0


static func find(id: String) -> Dictionary:
	for l in LENSES:
		if str(l["id"]) == id:
			return l
	return {}


static func is_lens(id: String) -> bool:
	return INDEX.has(id)


static func label(id: String) -> String:
	return str(find(id).get("label", id))


static func color(id: String) -> Color:
	return find(id).get("color", Color(0.8, 0.8, 0.8)) as Color


## How much of the lens an embodied amount carries (CompositionCatalog
## embodied / embodied_kg / a ledger side: {elements, water_kg | water_kg_h,
## energy_mj | energy_mj_h}).
static func amount(emb: Dictionary, id: String) -> float:
	match id:
		"water":
			return float(emb.get("water_kg", emb.get("water_kg_h", 0.0)))
		"energy":
			return float(emb.get("energy_mj", emb.get("energy_mj_h", 0.0)))
		_:
			return float((emb.get("elements", {}) as Dictionary).get(id, 0.0))


## The lens amount of `qty` of `kind` (its unit), 0 for an unknown kind.
static func amount_of(kind: String, qty: float, id: String) -> float:
	if qty <= 0.0 or not CompositionCatalog.is_material(kind):
		return 0.0
	var emb := CompositionCatalog.embodied(kind, qty)
	return amount(emb, id) if bool(emb["known"]) else 0.0


## The eight lens amounts of an embodied amount, in INDEX order.
static func vector(emb: Dictionary) -> PackedFloat64Array:
	var v := PackedFloat64Array()
	v.resize(SIZE)
	for k in INDEX.keys():
		v[int(INDEX[k])] = amount(emb, str(k))
	return v


## "0.12 kg N/h", "3.4 L water/h", "1.2 kW" (energy per hour is power).
static func fmt_rate(v: float, id: String) -> String:
	if id == "energy":
		return UiText.num(v / 3.6 * 1000.0, "W")
	if id == "water":
		return "%s water/h" % UiText.num(v, "L")
	var kg := ElementLedger.fmt_kg_h(v)
	# "1.2 kg/h" → "1.2 kg N/h"; "30 g/day" → "30 g N/day"
	var parts := kg.split("/", true, 1)
	return "%s %s/%s" % [parts[0], id, parts[1]] if parts.size() == 2 else kg


## "4.3 kg N", "120 L water", "2.1 kWh" for an amount over a window.
static func fmt_amount(v: float, id: String) -> String:
	if id == "energy":
		return UiText.num(v / 3.6 * 1000.0, "Wh")
	if id == "water":
		return "%s water" % UiText.num(v, "L")
	return "%s %s" % [ElementLedger.fmt_kg(v), id]


## Wire width for a flux against the largest flux on screen: log-scaled so
## a trickle is still visible beside a river.
static func width_for(v: float, max_v: float) -> float:
	if v <= 0.0 or max_v <= 0.0:
		return 0.0
	var f := clampf(log(1.0 + 9.0 * v / max_v) / log(10.0), 0.0, 1.0)
	return lerpf(WIDTH_MIN, WIDTH_MAX, f)
