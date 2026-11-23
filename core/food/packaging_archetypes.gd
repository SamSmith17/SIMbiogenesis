class_name PackagingArchetypes
extends RefCounted
## The game's packaging table: what a store-bought item's packaging IS —
## its mass, the bin volume it takes up loose and crushed, the waste kind
## it sorts into and the 3D mesh that draws it (plans/FOOD_WASTE_REALISM_PLAN.md
## Phase 1).
##
## OpenFoodFacts' structured `packagings` carries SHAPE and MATERIAL
## taxonomy tags but almost never a weight (`weight_measured` exists on a
## few products only), so this table is openly the ESTIMATE layer: every
## mass and volume is cited and flagged `est`. Item masses come from
## industry averages; loose / crushed bin volumes are each item's mass
## divided by the US EPA "Volume-to-Weight Conversion Factors" (April 2016)
## bulk densities for that material loose vs flattened / baled.
##
## `map_off(shape_tag, material_tag, qty_str, net_g)` turns one OFF
## packagings entry into an archetype id ("" = not a countable piece:
## caps, lids, labels and seals ride their parent container's mass).

## id -> {label, mass_g, loose_l, crushed_l, waste_kind, mesh_id, src, est}.
## waste_kind names the typed waste resource kinds (Phase 4).
const ARCHETYPES := {
	# --- plastic bottles and jugs (PET / HDPE) -----------------------------
	"pet_bottle_500": {"label": "500 ml PET bottle", "mass_g": 24.0, "loose_l": 1.15,
		"crushed_l": 0.10, "waste_kind": "pet_waste", "mesh_id": "pet_bottle",
		"src": "NAPCOR ~23.9 g avg single-serve PET; EPA VTW 2016 loose/baled", "est": true},
	"pet_bottle_1l": {"label": "1 L PET bottle", "mass_g": 38.0, "loose_l": 1.85,
		"crushed_l": 0.16, "waste_kind": "pet_waste", "mesh_id": "pet_bottle_large",
		"src": "1 L PET ~35-42 g, est; EPA VTW 2016", "est": true},
	"pet_bottle_2l": {"label": "2 L PET bottle", "mass_g": 52.0, "loose_l": 2.50,
		"crushed_l": 0.22, "waste_kind": "pet_waste", "mesh_id": "pet_bottle_large",
		"src": "2 L PET ~48-54 g, est; EPA VTW 2016", "est": true},
	"hdpe_jug_gal": {"label": "Gallon HDPE jug", "mass_g": 60.0, "loose_l": 4.20,
		"crushed_l": 0.24, "waste_kind": "hdpe_waste", "mesh_id": "hdpe_jug",
		"src": "US milk jug ~60 g, est; EPA VTW 2016 HDPE loose 24 lb/yd3", "est": true},
	"hdpe_bottle": {"label": "HDPE bottle", "mass_g": 28.0, "loose_l": 1.95,
		"crushed_l": 0.11, "waste_kind": "hdpe_waste", "mesh_id": "hdpe_bottle",
		"src": "small HDPE bottle ~25-30 g, est; EPA VTW 2016", "est": true},
	# --- metal cans --------------------------------------------------------
	"alu_can_355": {"label": "355 ml aluminium can", "mass_g": 14.9, "loose_l": 0.40,
		"crushed_l": 0.10, "waste_kind": "alu_waste", "mesh_id": "alu_can",
		"src": "Aluminum Assoc. ~31 cans/lb; EPA VTW 2016 whole 63 / flat 250 lb/yd3", "est": true},
	"steel_can_400": {"label": "400 g steel food can", "mass_g": 55.0, "loose_l": 0.62,
		"crushed_l": 0.11, "waste_kind": "steel_waste", "mesh_id": "steel_can",
		"src": "~#300 food can 50-60 g, est; EPA VTW 2016 whole 150 / flat 850 lb/yd3", "est": true},
	"steel_can_large": {"label": "800 g steel can", "mass_g": 90.0, "loose_l": 1.00,
		"crushed_l": 0.18, "waste_kind": "steel_waste", "mesh_id": "steel_can_large",
		"src": "large food can, est; EPA VTW 2016", "est": true},
	# --- glass -------------------------------------------------------------
	"glass_jar_400": {"label": "400 g glass jar", "mass_g": 220.0, "loose_l": 0.74,
		"crushed_l": 0.21, "waste_kind": "glass_waste", "mesh_id": "glass_jar",
		"src": "400 g jar ~200-240 g, est; EPA VTW 2016 whole 500 / cullet 1800 lb/yd3", "est": true},
	"glass_bottle_330": {"label": "330 ml glass bottle", "mass_g": 220.0, "loose_l": 0.74,
		"crushed_l": 0.21, "waste_kind": "glass_waste", "mesh_id": "glass_bottle",
		"src": "beer bottle ~200-240 g, est; EPA VTW 2016", "est": true},
	"glass_bottle_750": {"label": "750 ml glass bottle", "mass_g": 450.0, "loose_l": 1.51,
		"crushed_l": 0.42, "waste_kind": "glass_waste", "mesh_id": "glass_bottle",
		"src": "wine bottle ~400-500 g, est; EPA VTW 2016", "est": true},
	# --- fibre: cartons, boxes, paper ---------------------------------------
	# Aseptic / gable cartons are ~75 % paperboard with PE (and foil) layers;
	# they sort with card here and the composition carries the plastic share.
	"carton_1l": {"label": "1 L beverage carton", "mass_g": 40.4, "loose_l": 1.30,
		"crushed_l": 0.13, "waste_kind": "cardboard_waste", "mesh_id": "carton",
		"src": "OFF weight_measured, Tetra Brik 1 L (Oatly fixture); EPA VTW 2016", "est": true},
	"card_box_small": {"label": "Small cardboard box", "mass_g": 30.0, "loose_l": 0.50,
		"crushed_l": 0.07, "waste_kind": "cardboard_waste", "mesh_id": "card_flat",
		"src": "500 g pasta / cereal box ~25-35 g, est; EPA VTW 2016 loose 100 lb/yd3", "est": true},
	"card_box_large": {"label": "Large cardboard box", "mass_g": 120.0, "loose_l": 2.00,
		"crushed_l": 0.29, "waste_kind": "cardboard_waste", "mesh_id": "card_box",
		"src": "case / multipack box, est; EPA VTW 2016", "est": true},
	"paper_bag": {"label": "Paper bag", "mass_g": 55.0, "loose_l": 1.10,
		"crushed_l": 0.13, "waste_kind": "paper_waste", "mesh_id": "paper_wad",
		"src": "kraft grocery bag ~55 g, est; EPA VTW 2016", "est": true},
	"paper_wrap": {"label": "Paper wrapper", "mass_g": 5.0, "loose_l": 0.10,
		"crushed_l": 0.02, "waste_kind": "paper_waste", "mesh_id": "paper_wad",
		"src": "wrapper / liner, est", "est": true},
	# --- films and flexible plastic -----------------------------------------
	"film_bag": {"label": "Plastic bag / pouch", "mass_g": 8.0, "loose_l": 0.38,
		"crushed_l": 0.03, "waste_kind": "film_waste", "mesh_id": "film_wad",
		"src": "chip bag / pouch ~6-10 g (multilayer film), est; EPA VTW 2016 film 35 lb/yd3", "est": true},
	"film_wrap": {"label": "Film wrapper", "mass_g": 3.0, "loose_l": 0.15,
		"crushed_l": 0.01, "waste_kind": "film_waste", "mesh_id": "film_wad",
		"src": "overwrap / window film ~2-4 g, est", "est": true},
	# --- rigid tubs and trays (PP / PS, the mixed-plastic stream) -----------
	"plastic_tub": {"label": "Plastic tub", "mass_g": 25.0, "loose_l": 0.70,
		"crushed_l": 0.15, "waste_kind": "mixed_plastic_waste", "mesh_id": "plastic_tub",
		"src": "500 g PP yogurt / deli tub ~20-30 g, est; EPA VTW 2016", "est": true},
	"plastic_tray": {"label": "Plastic tray", "mass_g": 18.0, "loose_l": 0.55,
		"crushed_l": 0.10, "waste_kind": "mixed_plastic_waste", "mesh_id": "plastic_tub",
		"src": "PS / PP food tray ~15-20 g, est", "est": true},
}

## Shapes that are fragments of their parent container: their mass rides the
## container archetype's estimate, so they map to "" (not counted).
const _FRAGMENT_SHAPES := ["cap", "lid", "seal", "label", "sleeve", "straw", "tab"]


## A cap / lid / label is part of its container, never its own piece: the
## parser neither counts nor reports it.
static func is_fragment_shape(shape_tag: String) -> bool:
	var shape := strip_tag(shape_tag)
	for frag in _FRAGMENT_SHAPES:
		if shape.contains(frag):
			return true
	return false


static func ids() -> Array:
	var out: Array = ARCHETYPES.keys()
	out.sort()
	return out


static func get_archetype(aid: String) -> Dictionary:
	return ARCHETYPES.get(aid, {})


static func mass_g(aid: String) -> float:
	return float(ARCHETYPES.get(aid, {}).get("mass_g", 0.0))


static func loose_l(aid: String) -> float:
	return float(ARCHETYPES.get(aid, {}).get("loose_l", 0.0))


static func crushed_l(aid: String) -> float:
	return float(ARCHETYPES.get(aid, {}).get("crushed_l", 0.0))


static func waste_kind(aid: String) -> String:
	return str(ARCHETYPES.get(aid, {}).get("waste_kind", ""))


static func mesh_id(aid: String) -> String:
	return str(ARCHETYPES.get(aid, {}).get("mesh_id", ""))


static func label(aid: String) -> String:
	return str(ARCHETYPES.get(aid, {}).get("label", aid))


## Strip an OFF taxonomy tag's language prefix and separators:
## "en:pet-1-polyethylene-terephthalate" -> "pet 1 polyethylene terephthalate".
static func strip_tag(tag: String) -> String:
	var s := tag.strip_edges().to_lower()
	var colon := s.find(":")
	if colon >= 0 and colon <= 3:
		s = s.substr(colon + 1)
	return s.replace("-", " ").replace("_", " ")


## Parse a packaging / product quantity string ("415", "25 cl", "1 L",
## "1 oz (28.3 g)") into grams-or-millilitres (1 g ~ 1 ml here — packaging
## sizing only). Returns 0.0 when nothing parses.
static func parse_qty_g_ml(qty: String) -> float:
	var s := qty.strip_edges().to_lower()
	if s.is_empty():
		return 0.0
	# Prefer an explicit metric amount in parentheses ("1 oz (28.3 g)").
	var rx := RegEx.create_from_string(r"([0-9]+(?:[.,][0-9]+)?)\s*(kg|g|gr|l|cl|ml|oz|fl oz|lb)?")
	var best := 0.0
	for m in rx.search_all(s):
		var v := float(str(m.get_string(1)).replace(",", "."))
		var unit := str(m.get_string(2))
		var g := v
		match unit:
			"kg":
				g = v * 1000.0
			"l":
				g = v * 1000.0
			"cl":
				g = v * 10.0
			"oz":
				g = v * 28.3495
			"fl oz":
				g = v * 29.5735
			"lb":
				g = v * 453.592
			_:
				g = v
		if unit != "" or best <= 0.0:
			best = g
	return best


## What material family an OFF material tag names (keyword match, any
## language that shares the stem): "", "pet", "hdpe", "pp", "ps", "film",
## "plastic" (unspecified), "alu", "steel", "glass", "carton", "card",
## "paper".
static func material_family(material_tag: String) -> String:
	var m := strip_tag(material_tag)
	if m.is_empty():
		return ""
	if m.contains("tetra") or m.contains("brik") or m.contains("aseptic"):
		return "carton"
	if m.contains("pet") and not m.contains("paper"):
		return "pet"
	if m.contains("hdpe") or m.contains("high density"):
		return "hdpe"
	if m.contains("ldpe") or m.contains("low density") or m.contains("film"):
		return "film"
	if m.contains("polypropylene") or m == "pp" or m.begins_with("pp "):
		return "pp"
	if m.contains("polystyrene") or m == "ps" or m.begins_with("ps "):
		return "ps"
	if m.contains("plasti") or m.contains("polyethylene"):
		return "plastic"
	if m.contains("alumin"):
		return "alu"
	if m.contains("steel") or m.contains("tin") or m.contains("acier") or m.contains("metal"):
		return "steel"
	if m.contains("glass") or m.contains("verre") or m.contains("vidrio") or m.contains("glas"):
		return "glass"
	# "cart" also catches non-English tags OFF leaves untranslated
	# ("cartón", "cartone"); accented keywords ("plástico") do NOT match
	# their ASCII stems, so shapes carry those cases (a bag is film
	# whatever its material tag says).
	if m.contains("corrugated") or m.contains("cardboard") or m.contains("cart") or m.contains("paperboard"):
		return "card"
	if m.contains("paper") or m.contains("papier") or m.contains("papel"):
		return "paper"
	return ""


## One OFF packagings entry -> archetype id ("" = not a countable piece).
## `qty_str` is the entry's own quantity ("25 cl"); `net_g` the product's
## net content, the fallback when the entry carries no size.
static func map_off(shape_tag: String, material_tag: String, qty_str: String = "", net_g: float = 0.0) -> String:
	var shape := strip_tag(shape_tag)
	var fam := material_family(material_tag)
	if is_fragment_shape(shape_tag):
		return ""
	var size := parse_qty_g_ml(qty_str)
	if size <= 0.0:
		size = net_g
	# Material-only entries (a stray PP / HDPE row beside the bottle) are
	# caps and sleeves: not countable.
	if shape.is_empty():
		return ""
	if shape.contains("bottle") or shape.contains("vial") or shape.contains("flask"):
		match fam:
			"glass":
				return "glass_bottle_750" if size > 500.0 else "glass_bottle_330"
			"hdpe":
				return "hdpe_jug_gal" if size > 2000.0 else "hdpe_bottle"
			"pet", "plastic", "pp", "ps", "film", "":
				if size > 1400.0:
					return "pet_bottle_2l"
				return "pet_bottle_1l" if size > 700.0 else "pet_bottle_500"
	if shape.contains("jug"):
		return "hdpe_jug_gal"
	if shape.contains("jar") or shape.contains("pot de verre"):
		if fam == "glass" or fam == "":
			return "glass_jar_400"
		return "plastic_tub"
	if shape.contains("can") and not shape.contains("canister"):
		if fam == "alu":
			return "alu_can_355"
		return "steel_can_large" if size > 600.0 else "steel_can_400"
	if shape.contains("tin"):
		return "steel_can_400"
	if shape.contains("brick") or shape.contains("carton") or fam == "carton":
		return "carton_1l"
	if shape.contains("tub") or shape.contains("pot") or shape.contains("cup"):
		if fam == "card" or fam == "paper":
			return "card_box_small"
		return "plastic_tub"
	if shape.contains("tray"):
		return "card_box_small" if fam == "card" or fam == "paper" else "plastic_tray"
	if shape.contains("box") or shape.contains("packet") or shape.contains("case"):
		if fam == "plastic" or fam == "pet" or fam == "pp" or fam == "film":
			return "plastic_tub"
		return "card_box_large" if size > 800.0 else "card_box_small"
	if shape.contains("bag") or shape.contains("pouch") or shape.contains("sachet") or shape.contains("sleeve"):
		if fam == "paper" or fam == "card":
			return "paper_bag"
		return "film_bag"
	if shape.contains("film") or shape.contains("wrap"):
		return "film_wrap"
	if shape.contains("container") or shape.contains("packaging"):
		# Shape says nothing: let the material decide.
		match fam:
			"glass":
				return "glass_jar_400"
			"alu":
				return "alu_can_355"
			"steel":
				return "steel_can_400"
			"card", "paper":
				return "card_box_small"
			"carton":
				return "carton_1l"
			"pet", "hdpe", "pp", "ps", "plastic":
				return "plastic_tub"
			"film":
				return "film_bag"
	return ""
